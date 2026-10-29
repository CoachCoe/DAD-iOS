import Foundation

// Settings view model + service seam. The model owns load/ready/failed state, toggle-and-save
// (optimistic version bump), and the delete-account flow (confirm gate -> server delete -> local
// wipe), so it is unit-tested without a network or UI — the iOS counterpart of Android Phase 7.

public struct AccountSettingsSnapshot: Sendable, Equatable {
    public let profile: AccountProfileSummary
    public let preferences: AccountPreferences
    public init(profile: AccountProfileSummary, preferences: AccountPreferences) {
        self.profile = profile
        self.preferences = preferences
    }
}

public protocol AccountSettingsService: Sendable {
    func load() async throws -> AccountSettingsSnapshot
    /// Save the preference block; returns the new snapshot (bumped version).
    func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot
    /// Delete the account server-side (personal data removed, gift records kept).
    func deleteAccount() async throws
    /// Clear the local session (sign out / post-delete wipe).
    func signOut() async throws
}

@MainActor
@Observable
public final class AccountSettingsModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var snapshot: AccountSettingsSnapshot?
    /// True once deleted or signed out — the UI leaves the settings shell.
    public private(set) var signedOut = false
    public private(set) var actionError: String?

    private let service: any AccountSettingsService

    public init(service: any AccountSettingsService) { self.service = service }

    public func load() async {
        phase = .loading
        do {
            snapshot = try await service.load()
            phase = .ready
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// Flip one preference toggle and persist; the snapshot is replaced in place on success.
    public func toggle(_ key: String, _ value: Bool) async {
        guard let current = snapshot else { return }
        actionError = nil
        do {
            snapshot = try await service.savePreferences(current.preferences.with(key, value))
        } catch {
            actionError = Self.message(error)
        }
    }

    /// Delete only when the confirm gate is satisfied, then wipe the local session.
    public func deleteAccount(_ gate: DeleteAccountGate) async {
        guard gate.isConfirmed else {
            actionError = "Type \(DeleteAccountGate.confirmWord) to confirm."
            return
        }
        actionError = nil
        do {
            try await service.deleteAccount()
            try await service.signOut()
            signedOut = true
        } catch {
            actionError = Self.message(error)
        }
    }

    public func signOut() async {
        do {
            try await service.signOut()
            signedOut = true
        } catch {
            actionError = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        if let account = error as? AccountError, account == .signedOut { return "Please sign in again." }
        return "Something went wrong. Please try again."
    }
}
