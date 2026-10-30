import Foundation

// Partner portal view models + the service seam. The models own explicit load/ready/failed state
// and the pending-approval gate, role-gated actions, and push register/unregister, so they are
// unit-tested without a network or UI — the same shape as the donor models (C/D/E).

/// The seam the partner models call. A conformer maps to the generated client (WireAPI, under the
/// 12-hour partner session) or a preview/test double; all value types so the models stay testable.
public protocol PartnerService: Sendable {
    /// The portal snapshot after sign-in. Throws `.signedOut` (401) or a pending-approval signal.
    func overview() async throws -> PartnerOverview
    func initiatives() async throws -> [PartnerInitiative]
    func spend() async throws -> [PartnerSpendCategory]
    func people() async throws -> PartnerPeople
    func users() async throws -> [PartnerUser]
    /// Admin-only (P-13). The model gates on role before calling, but the server re-checks.
    func inviteUser(email: String, role: PartnerRole) async throws
    func removeUser(id: String) async throws
    /// Partner push (§7.5, v2.2). Register on sign-in, clear on sign-out; both native-only.
    func registerPushDevice(token: String) async throws
    func unregisterPushDevice() async throws
}

/// Thrown by a conformer when the signed-in partner account is still awaiting approval (P-2):
/// the portal must show the pending screen and nothing else.
public struct PartnerPendingApproval: Error, Sendable { public init() {} }

// MARK: - Partner portal model (P-1, P-2, P-10..P-14)

@MainActor
@Observable
public final class PartnerModel {
    public enum Phase: Sendable, Equatable {
        case loading
        /// Signed in but awaiting approval — show the pending screen and nothing else (P-2).
        case pending
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var overview: PartnerOverview?
    public private(set) var initiatives: [PartnerInitiative] = []
    public private(set) var spend: [PartnerSpendCategory] = []
    public private(set) var people: PartnerPeople?
    public private(set) var users: [PartnerUser] = []
    /// A transient action error (invite/remove) shown inline without losing the portal.
    public private(set) var actionError: String?
    /// True when the overview loaded but at least one secondary section failed to load.
    public private(set) var sectionsUnavailable = false

    /// The user awaiting an inline remove confirmation, if any.
    public private(set) var pendingRemoval: PartnerUser?

    private let service: any PartnerService
    /// The signed-in partner user's id, so an admin can never remove themselves.
    public let currentUserID: String?

    public init(service: any PartnerService, currentUserID: String? = nil) {
        self.service = service
        self.currentUserID = currentUserID
    }

    /// Plausible-address check for the invite field: one `@`, a non-empty local part and a dotted
    /// domain, no whitespace. The server remains the authority on deliverability.
    public static func isPlausibleEmail(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(where: \.isWhitespace) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }

    public func canRemove(_ user: PartnerUser) -> Bool { role.canManageUsers && user.id != currentUserID }

    /// The current role, defaulting to the least-privileged VIEWER until the overview loads, so
    /// capability gates never open early.
    public var role: PartnerRole { overview?.role ?? .viewer }

    /// Runs one secondary section load. A lost session still fails the whole load; any other
    /// failure degrades just that section and raises `sectionsUnavailable`, so a failed fetch is
    /// never shown as a genuinely empty section.
    private func optional<T: Sendable>(_ call: @Sendable () async throws -> T) async throws -> T? {
        do { return try await call() }
        catch AccountError.signedOut { throw AccountError.signedOut }
        catch where error.isCancellation { throw CancellationError() }
        catch {
            sectionsUnavailable = true
            return nil
        }
    }

    public func load() async {
        let prior = phase
        phase = .loading
        do {
            // Overview first — it carries the role and is the gate for everything else. A
            // pending-approval account throws before any portal data is fetched (P-2).
            let overview = try await service.overview()
            self.overview = overview
            sectionsUnavailable = false
            async let initiatives = optional { try await self.service.initiatives() }
            async let spend = optional { try await self.service.spend() }
            async let people = optional { try await self.service.people() }
            // Users are admin-managed but readable by both roles; load them with the rest.
            async let users = optional { try await self.service.users() }
            self.initiatives = try await initiatives ?? []
            self.spend = try await spend ?? []
            self.people = try await people
            self.users = try await users ?? []
            phase = .ready
        } catch is PartnerPendingApproval {
            phase = .pending
        } catch where error.isCancellation {
            phase = prior
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    /// Invite a user (P-13), admin-only. Gated client-side; the server re-checks. A viewer call
    /// is a no-op that surfaces the gate rather than hitting the network.
    public func inviteUser(email: String, role: PartnerRole) async {
        guard self.role.canManageUsers else { actionError = "Only an admin can invite users."; return }
        guard Self.isPlausibleEmail(email) else { actionError = "Enter a valid email address."; return }
        actionError = nil
        do {
            try await service.inviteUser(email: email.trimmingCharacters(in: .whitespacesAndNewlines), role: role)
            users = (try? await service.users()) ?? users
        } catch where error.isCancellation {
            return
        } catch {
            actionError = error.userMessage
        }
    }

    /// Step one of removal: stage the user for the inline confirmation. Nothing is sent yet.
    public func requestRemoval(id: String) {
        guard role.canManageUsers else { actionError = "Only an admin can remove users."; return }
        guard id != currentUserID else { actionError = "You can’t remove yourself."; return }
        actionError = nil
        pendingRemoval = users.first { $0.id == id }
    }

    public func cancelRemoval() { pendingRemoval = nil }

    public func confirmRemoval() async {
        guard let user = pendingRemoval else { return }
        pendingRemoval = nil
        await removeUser(id: user.id)
    }

    public func removeUser(id: String) async {
        guard role.canManageUsers else { actionError = "Only an admin can remove users."; return }
        guard id != currentUserID else { actionError = "You can’t remove yourself."; return }
        actionError = nil
        do {
            try await service.removeUser(id: id)
            users.removeAll { $0.id == id }
        } catch where error.isCancellation {
            return
        } catch {
            actionError = error.userMessage
        }
    }

    /// Register this device for partner push after sign-in (§7.5). Best-effort — a push failure
    /// never blocks the portal.
    public func registerPush(token: String) async {
        try? await service.registerPushDevice(token: token)
    }

    /// Clear the push registration on sign-out (§7.5).
    public func unregisterPush() async {
        try? await service.unregisterPushDevice()
    }
}
