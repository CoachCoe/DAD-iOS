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
/// 401. Email signup answers 200 `{"sent":true}` like the live server (the emailed link is claimed
/// with a token starting `stubclaim`); password sign-in accepts `correct horse battery` (the
/// stored password, replaceable via set-password), `throttled password` is 429, anything else is
/// the server's 401 "email or password is incorrect". Set-password rejects a wrong `current_password`
/// with 422 `CURRENT_PASSWORD_INCORRECT` and a new password outside 12...72 bytes with 422. Profile/preferences/
/// logout/refresh behave like a live account; the donor-home reads (dashboard, today's initiative, 120 gifts
/// paged 50 at a time, receipts, the annual summary) follow `Scenario`; account deletion succeeds (200) unless
/// `deletionBlocked` (409) or while a monthly gift is still set to renew (`GiftScenario`), after which the
/// account is gone (profile -> 401). The giving reads/commands (recurring, amount, cancel, payment method)
/// follow a stateful gift: the hosted Stripe pages are stubbed by the UI (`completeHandoff` plays the
/// "payment finished" webhook), so the REAL `WireGiving` conformer runs end to end.
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

    /// What the scripted donor-home reads answer. `populated`: a ready dashboard, an initiative and 120
    /// gifts. `empty`: dashboard still preparing, no initiative in rotation, no gifts. `failFirst`: the
    /// first dashboard/gifts read of each kind is a 503, then it behaves like `populated`. `unranked`:
    /// like `populated` but the donor opted out of rankings and has no streak figure yet.
    public enum Scenario: Sendable { case populated, empty, failFirst, unranked }

    /// The donor's recurring gift at launch. `none`: no gift yet. `active`: $5/day ($150/month) renewing.
    /// `activeFailFirst`: like `active`, but the first recurring read is a 503 (the error + retry path).
    public enum GiftScenario: Sendable { case none, active, activeFailFirst }

    public struct Services: Sendable {
        public let session: AccountSession
        public let signIn: any SignInService
        public let settings: any AccountSettingsService
        public let credentialAuth: WireCredentialAuth
        public let passwords: any PasswordSettingsService
        public let dashboard: any DashboardService
        public let giving: any GivingService
        /// Plays the Stripe webhook after the stubbed hosted page "finishes" (a gift starts, a card is applied).
        public let completeHandoff: @Sendable (HostedHandoff.Purpose) -> Void
    }

    /// `signedIn` starts with a stored session (as after a relaunch), skipping the phone sign-in dance.
    public static func make(deletionBlocked: Bool = false, scenario: Scenario = .populated, gift: GiftScenario = .none,
                            signedIn: Bool = false, onLocalWipe: @escaping @Sendable () -> Void = {}) throws -> Services {
        let transport = StubTransport(deletionBlocked: deletionBlocked, scenario: scenario, gift: gift)
        let session = try AccountSession(api: WireAPI(origin: origin, transport: transport), store: InMemoryCredentialStore(signedIn ? Credentials(
            access: "stub-access-0", refresh: "stub-refresh-0-xxxxxxxxxxxxxxxxxxxxxxxxxxxx", expiresAt: Date().addingTimeInterval(900)) : nil))
        let product = ProductClient(origin: origin, transport: transport, session: session)
        return Services(
            session: session,
            signIn: WireAuth(origin: origin, transport: transport),
            settings: WireAccountSettings(product: product, onLocalWipe: onLocalWipe),
            credentialAuth: WireCredentialAuth(origin: origin, transport: transport),
            passwords: WirePasswordSettings(product: product),
            dashboard: WireDashboard(product: product),
            giving: WireGiving(product: product),
            completeHandoff: { transport.completeHandoff($0) })
    }
}

private final class StubTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let deletionBlocked: Bool
    private let scenario: StubBackend.Scenario
    private var failuresServed = Set<String>()
    private var generation = 0
    private var deleted = false
    private var version = 3
    private var storedPassword = "correct horse battery"
    private var prefs: [String: Bool] = [
        "referral_emails": true, "marketing_emails": false, "push_referral_converted": true, "push_streak_at_risk": true,
        "push_streak_milestone": true, "push_streak_lapsed": true, "push_badge_earned": true, "push_event_nearby": false,
        "push_event_reminder": true, "push_event_promoted": false, "push_gift_processed": true,
        "rankings_opted_out": false, "network_visible": true, "volunteer": true,
    ]

    // Giving: one stateful gift. `giftAmount` is the integer-cent monthly charge; nil means no gift.
    private enum Payment: String { case none = "NONE", open = "OPEN", applied = "APPLIED" }
    private var giftAmount: Int?
    private var giftEnding = false
    /// The amount the last `startRecurringCheckout` was created for: what the "paid" webhook activates.
    private var checkoutAmount: Int?
    private var payment = Payment.none
    private var recurringFailureServed = false
    private let failFirstRecurring: Bool
    private static let subscriptionID = "5d6f1d9e-0a5b-4e6f-8d0f-3f1c2a9b7c10"
    private static let periodEnd = "2026-11-20T15:00:00Z"

    init(deletionBlocked: Bool, scenario: StubBackend.Scenario, gift: StubBackend.GiftScenario) {
        self.deletionBlocked = deletionBlocked; self.scenario = scenario
        giftAmount = gift == .none ? nil : 15000
        failFirstRecurring = gift == .activeFailFirst
    }

    /// The "payment finished" webhook: what the server would hold once the hosted page completed.
    func completeHandoff(_ purpose: HostedHandoff.Purpose) {
        lock.withLock {
            switch purpose {
            case .startGift: giftAmount = checkoutAmount ?? 3000; giftEnding = false
            case .updatePayment: payment = .applied
            }
        }
    }

    private func recurringJSON() -> String {
        lock.withLock {
            guard let amount = giftAmount else { return #"{"mode":"test","state":"ready","subscription":null}"# }
            let stops = giftEnding ? "\"" + Self.periodEnd + "\"" : "null"
            return #"{"mode":"test","state":"ready","observed_at":"2026-10-31T12:00:00Z","subscription":{"amount_minor":\#(amount),"currency":"USD","id":"\#(Self.subscriptionID)","period_end":"\#(Self.periodEnd)","status":"active","stops_at":\#(stops)}}"#
        }
    }

    /// Giving routes. Commands need a version 4 Idempotency-Key and echo the values the matching GET returned.
    private func giving(_ request: HTTPRequest, _ payload: String, authorized: Bool,
                        _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?)? {
        guard let path = request.path, path.hasPrefix("/donor/me/recurring") || path == "/donor/me/payment-method" || path == "/donor/me/payment-method/setup" else { return nil }
        guard authorized, !lock.withLock({ deleted }) else { return reply(.unauthorized, "{}") }
        let key = request.headerFields[HTTPField.Name("Idempotency-Key")!]
        let fields = Self.object(payload)
        func validKey() -> Bool { key.flatMap(UUID.init(uuidString:)) != nil }
        switch (request.method, path) {
        case (.get, "/donor/me/recurring"):
            let fail = lock.withLock { () -> Bool in
                guard failFirstRecurring, !recurringFailureServed else { return false }
                recurringFailureServed = true
                return true
            }
            return fail ? reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) : reply(.ok, recurringJSON())
        case (.get, "/donor/me/recurring/amount"):
            guard let amount = lock.withLock({ giftAmount }) else { return reply(.ok, #"{"state":"unavailable"}"#) }
            return reply(.ok, #"{"state":"ready","subscription_id":"\#(Self.subscriptionID)","amount_minor":\#(amount),"effective_at":"\#(Self.periodEnd)","change":null}"#)
        case (.post, "/donor/me/recurring/checkout"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard let amount = fields["amount_minor"] as? Int, amount >= 3000, amount <= 90000, amount % 3000 == 0 else { return reply(.unprocessableContent, "{}") }
            guard lock.withLock({ giftAmount }) == nil else { return reply(.conflict, "{}") }
            lock.withLock { checkoutAmount = amount }
            return reply(.created, #"{"url":"https://stub.invalid/pay/checkout","session_id":"cs_stub_1","expires_at":"2026-11-01T12:00:00Z"}"#)
        case (.post, "/donor/me/recurring/amount"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard let new = fields["amount_minor"] as? Int, new >= 3000, new <= 90000, new % 3000 == 0 else { return reply(.unprocessableContent, "{}") }
            let current = lock.withLock { giftAmount }
            guard let current, fields["subscription_id"] as? String == Self.subscriptionID, fields["previous_minor"] as? Int == current,
                  fields["effective_at"] as? String == Self.periodEnd else { return reply(.conflict, "{}") }
            lock.withLock { giftAmount = new }
            return reply(.ok, #"{"amount_minor":\#(new),"previous_minor":\#(current),"confirmed":true,"effective_at":"\#(Self.periodEnd)","request_id":"11111111-2222-4333-8444-555555555555"}"#)
        case (.post, "/donor/me/recurring/cancel"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard lock.withLock({ giftAmount }) != nil, fields["subscription_id"] as? String == Self.subscriptionID,
                  fields["period_end"] as? String == Self.periodEnd else { return reply(.conflict, "{}") }
            lock.withLock { giftEnding = true }
            return reply(.ok, recurringJSON())
        case (.get, "/donor/me/payment-method"):
            let status = lock.withLock { payment.rawValue }
            let completed = status == "APPLIED" ? "\"2026-10-31T12:00:00Z\"" : "null"
            return reply(.ok, #"{"mode":"test","status":"\#(status)","completed_at":\#(completed)}"#)
        case (.post, "/donor/me/payment-method/setup"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard lock.withLock({ giftAmount }) != nil else { return reply(.conflict, "{}") }
            lock.withLock { payment = .open }
            return reply(.ok, #"{"url":"https://stub.invalid/pay/setup"}"#)
        default: return nil
        }
    }

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

    private static let wrongCurrent = #"{"detail":"Current password is incorrect","code":"CURRENT_PASSWORD_INCORRECT"}"#
    private static let rejected = #"{"detail":"The email or password is incorrect"}"#

    private static func object(_ payload: String) -> [String: Any] {
        (payload.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    // MARK: donor-home reads

    private static let reads = ["/donor/me/dashboard", "/donor/me/today-initiative", "/donor/me/gifts", "/donor/me/receipts/", "/donor/me/annual-summary/"]
    private static let giftTotal = 120
    private static let ready = #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":true,"referrals":{"currency":"USD","irl":1,"irl_minor":3000,"link":2,"link_minor":9000,"total_minor":12000},"streak":{"at_risk":false,"current":18,"grace_ends_at":null,"ladder":{"days":18,"last_milestone":7,"next_milestone":30,"days_to_next":12,"bar":[true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,false,false,false,false,false,false,false,false,false,false,false,false]}},"rank":{"national_percentile":2,"city":"Austin","city_rank":4,"computed_at":"2026-10-30T00:00:00Z"},"rankings_opted_out":false,"network":{"active_count":3,"annualized_minor":474500,"currency":"USD"},"impact":{"given_minor":124000,"currency":"USD","initiatives_funded":4,"events_volunteered":2}}"#
    private static let unranked = #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":false,"referrals":null,"streak":null,"rank":null,"rankings_opted_out":true,"network":null,"impact":{"given_minor":null,"currency":"USD","initiatives_funded":0,"events_volunteered":0}}"#
    private static let today = #"{"initiative_id":"11111111-1111-4111-8111-111111111111","slug":"meals-on-wheels","title":"Meals on Wheels","summary":"Hot meals delivered to neighbours who cannot cook for themselves.","region":"TX","location":"Austin, TX","type":"PROGRAM","started_on":"2025-01-02","metrics":[{"label":"Meals this week","value":1200,"unit":"PEOPLE","verified_on":"2026-10-28"},{"label":"Cost per meal","value":425,"unit":"USD_CENTS","verified_on":"2026-10-28"},{"label":"Partners","value":1,"unit":"PARTNERS","verified_on":"2026-10-28"}],"distinct_shown":4}"#

    private static func giftID(_ index: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", index) }
    private static func giftRecord(_ index: Int) -> String {
        let refunded = index % 7 == 0 ? 500 : 0
        let day = 28 - (index % 28)
        return #"{"id":"\#(giftID(index))","amount_minor":3000,"currency":"USD","paid_at":"2026-09-\#(String(format: "%02d", day))T10:00:00Z","frequency":"MONTHLY","refunded_minor":\#(refunded),"net_minor":\#(3000 - refunded),"refunds":[\#(refunded > 0 ? #"{"id":"re_\#(index)","amount_minor":500,"status":"succeeded","observed_at":"2026-09-29T10:00:00Z"}"# : "")]}"#
    }

    /// The first read of each kind fails under `.failFirst`, so the UITest sees the error and its retry.
    private func failsThisTime(_ key: String) -> Bool {
        lock.withLock { scenario == .failFirst && failuresServed.insert(key).inserted }
    }

    private func read(_ target: String, _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?) {
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts[0]
        switch path {
        case "/donor/me/dashboard":
            if failsThisTime("dashboard") { return reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) }
            switch scenario {
            case .empty: return reply(.ok, #"{"state":"preparing","mode":"test"}"#)
            case .unranked: return reply(.ok, Self.unranked)
            default: return reply(.ok, Self.ready)
            }
        case "/donor/me/today-initiative":
            return scenario == .empty ? reply(.notFound, #"{"detail":"nothing in rotation"}"#) : reply(.ok, Self.today)
        case "/donor/me/gifts":
            if failsThisTime("gifts") { return reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) }
            let offset = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: "offset=", with: "")) ?? 0 : 0
            return reply(.ok, page(total: scenario == .empty ? 0 : Self.giftTotal, offset: offset))
        case _ where path.hasPrefix("/donor/me/receipts/"):
            let id = String(path.dropFirst("/donor/me/receipts/".count))
            guard scenario != .empty, let index = Self.giftIndex(id) else { return reply(.notFound, #"{"detail":"not found"}"#) }
            return reply(.ok, #"{"mode":"test","tax_receipt":false,"as_of":"2026-10-30T00:00:00Z","receipt_id":"rcpt-\#(index)","gift":\#(Self.giftRecord(index))}"#)
        case _ where path.hasPrefix("/donor/me/annual-summary/"):
            if scenario == .empty { return reply(.notFound, #"{"detail":"no gifts"}"#) }
            return reply(.ok, #"{"mode":"test","tax_receipt":false,"year":2026,"timezone":"America/Chicago","as_of":"2026-10-30T00:00:00Z","gifts":[\#(Self.giftRecord(0))],"amount_minor":360000,"refunded_minor":8500,"net_minor":351500,"currency":"USD"}"#)
        default:
            return reply(.notFound, #"{"detail":"not found"}"#)
        }
    }

    private func page(total: Int, offset: Int) -> String {
        let end = min(offset + 50, total)
        let rows = (offset..<max(offset, end)).map(Self.giftRecordSummary).joined(separator: ",")
        return #"{"email":"alex@example.org","mode":"test","gifts":[\#(rows)],"next_offset":\#(end < total ? String(end) : "null")}"#
    }

    private static func giftIndex(_ id: String) -> Int? {
        guard id.hasPrefix("00000000-0000-4000-8000-"), let n = Int(id.suffix(12)), n >= 0, n < giftTotal else { return nil }
        return n
    }

    private static func giftRecordSummary(_ index: Int) -> String {
        let refunded = index % 7 == 0 ? 500 : 0
        let day = 28 - (index % 28)
        return #"{"id":"\#(giftID(index))","amount_minor":3000,"currency":"USD","frequency":"MONTHLY","paid_at":"2026-09-\#(String(format: "%02d", day))T10:00:00Z","refunded_minor":\#(refunded),"net_minor":\#(3000 - refunded)}"#
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var payload = ""
        if let body { payload = try await String(collecting: body, upTo: 8192) }
        let authorized = request.headerFields[.authorization].map { $0.hasPrefix("Bearer stub-access-") } ?? false
        let isDeleted = lock.withLock { deleted }
        func reply(_ status: HTTPResponse.Status, _ json: String = "{}") -> (HTTPResponse, HTTPBody?) {
            // Every non-2xx body is the contract's Problem object, which requires `detail`.
            let body = status.code >= 400 && json == "{}" ? #"{"detail":"stub"}"# : json
            return (HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        if let response = giving(request, payload, authorized: authorized, reply) { return response }
        switch (request.method, request.path ?? "") {
        case (.post, "/donor/phone/sign-in/options"): return reply(.ok, #"{"sent":true}"#)
        case (.post, "/donor/phone/sign-in"):
            if payload.contains("\"123456\"") { return reply(.ok, session()) }
            if payload.contains("\"000000\"") { return reply(.tooManyRequests) }
            return reply(.unauthorized)
        case (.post, "/donor/signup"):
            let fields = Self.object(payload)
            guard let email = fields["email"] as? String, email.contains("@"), (fields["name"] as? String)?.isEmpty == false else {
                return reply(.unprocessableContent)
            }
            return email.hasPrefix("throttled") ? reply(.tooManyRequests) : reply(.ok, #"{"sent":true}"#)
        case (.post, "/donor/claim"):
            let token = Self.object(payload)["token"] as? String ?? ""
            return token.hasPrefix("stubclaim") ? reply(.ok, session()) : reply(.unauthorized)
        case (.post, "/donor/password/sign-in"):
            let password = Self.object(payload)["password"] as? String ?? ""
            if password == "throttled password" { return reply(.tooManyRequests) }
            return password == lock.withLock({ storedPassword }) ? reply(.ok, session()) : reply(.unauthorized, Self.rejected)
        case (.post, "/donor/me/password"):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            let fields = Self.object(payload)
            let new = fields["password"] as? String ?? ""
            guard (12...72).contains(new.utf8.count) else { return reply(.unprocessableContent) }
            if let current = fields["current_password"] as? String, current != lock.withLock({ storedPassword }) {
                return reply(.unprocessableContent, Self.wrongCurrent)
            }
            lock.withLock { storedPassword = new }
            return reply(.ok, #"{"saved":true}"#)
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
            // 409 while a checkout is open (`deletionBlocked`) or a monthly gift is still set to renew.
            if deletionBlocked || lock.withLock({ giftAmount != nil && !giftEnding }) { return reply(.conflict) }
            lock.withLock { deleted = true }
            return reply(.ok, #"{"deleted":true}"#)
        case (.post, "/donor/logout"): return reply(.ok, #"{"signed_out":true}"#)
        case (.get, let path) where path.hasPrefix("/donor/me/") && Self.reads.contains(where: { path.hasPrefix($0) }):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            return read(path, reply)
        default: return reply(.notFound)
        }
    }
}
#endif
