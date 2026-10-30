#if DEBUG
import Foundation
import HTTPTypes
import OpenAPIRuntime

/// DEBUG-only scripted backend for the simulator UITests. It is NOT a preview double: the app
/// runs the REAL `WireAuth`, `WireAccountSettings`, `WireAPI`, `AccountSession` and keychain-shaped
/// store on top of it, so a UITest drives the same code a release build uses, with only the
/// network replaced by this transport. Compiled out of release builds.
///
/// Script: phone sign-in accepts code `123456`; `000000` is throttled (429); anything else is a
/// 401. Profile/preferences/logout/refresh behave like a live account; account deletion succeeds
/// (200) unless `deletionBlocked` (409), after which the account is gone (profile -> 401).
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    public init(_ value: Credentials? = nil) { self.value = value }
    public func load() throws -> Credentials? { lock.withLock { value } }
    public func save(_ credentials: Credentials) throws { lock.withLock { value = credentials } }
    public func clear() throws { lock.withLock { value = nil } }
}

public enum StubBackend {
    public static let origin = URL(string: "https://stub.invalid")!

    public struct Services: Sendable {
        public let session: AccountSession
        public let signIn: any SignInService
        public let settings: any AccountSettingsService
    }

    public static func make(deletionBlocked: Bool = false, onLocalWipe: @escaping @Sendable () -> Void = {}) throws -> Services {
        let transport = StubTransport(deletionBlocked: deletionBlocked)
        let session = try AccountSession(api: WireAPI(origin: origin, transport: transport), store: InMemoryCredentialStore())
        return Services(
            session: session,
            signIn: WireAuth(origin: origin, transport: transport),
            settings: WireAccountSettings(product: ProductClient(origin: origin, transport: transport, session: session), onLocalWipe: onLocalWipe))
    }
}

private final class StubTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let deletionBlocked: Bool
    private var generation = 0
    private var deleted = false
    private var version = 3
    private var prefs: [String: Bool] = [
        "referral_emails": true, "marketing_emails": false, "push_referral_converted": true, "push_streak_at_risk": true,
        "push_streak_milestone": true, "push_streak_lapsed": true, "push_badge_earned": true, "push_event_nearby": false,
        "push_event_reminder": true, "push_event_promoted": false, "push_gift_processed": true,
        "rankings_opted_out": false, "network_visible": true, "volunteer": true,
    ]

    init(deletionBlocked: Bool) { self.deletionBlocked = deletionBlocked }

    private func session() -> String {
        lock.withLock { generation += 1; return """
        {"access_token":"stub-access-\(generation)","expires_in":900,"refresh_token":"stub-refresh-\(generation)-xxxxxxxxxxxxxxxxxxxxxxxxxxxx","refresh_expires_in":5184000}
        """ }
    }

    private func profile() -> String {
        lock.withLock {
            let flags = prefs.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",")
            return "{\"email\":\"alex@example.org\",\"public_name\":\"Alex\",\"account_role\":\"DONOR\",\"zip\":\"78701\",\"city\":\"Austin\",\"timezone\":null,\"phone\":null,\(flags),\"volunteer_interests\":[],\"version\":\(version),\"consent_version\":\"stub-v1\"}"
        }
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var payload = ""
        if let body { payload = try await String(collecting: body, upTo: 8192) }
        let authorized = request.headerFields[.authorization].map { $0.hasPrefix("Bearer stub-access-") } ?? false
        let isDeleted = lock.withLock { deleted }
        func reply(_ status: HTTPResponse.Status, _ json: String = "{}") -> (HTTPResponse, HTTPBody?) {
            (HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(json))
        }
        switch (request.method, request.path ?? "") {
        case (.post, "/donor/phone/sign-in/options"): return reply(.ok, #"{"sent":true}"#)
        case (.post, "/donor/phone/sign-in"):
            if payload.contains("\"123456\"") { return reply(.ok, session()) }
            if payload.contains("\"000000\"") { return reply(.tooManyRequests) }
            return reply(.unauthorized)
        case (.post, "/donor/refresh"): return isDeleted ? reply(.unauthorized) : reply(.ok, session())
        case (.get, "/donor/me/profile"): return authorized && !isDeleted ? reply(.ok, profile()) : reply(.unauthorized)
        case (.post, "/donor/me/preferences"):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return reply(.unprocessableContent)
            }
            lock.withLock {
                for (key, value) in object { if let flag = value as? Bool { prefs[key] = flag } }
                version += 1
            }
            return reply(.ok, profile())
        case (.post, "/donor/me/delete"):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            if deletionBlocked { return reply(.conflict) }
            lock.withLock { deleted = true }
            return reply(.ok, #"{"deleted":true}"#)
        case (.post, "/donor/logout"): return reply(.ok, #"{"signed_out":true}"#)
        default: return reply(.notFound)
        }
    }
}
#endif
