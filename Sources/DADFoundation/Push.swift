import Foundation

/// The APNs environment that issued a device token: development-signed builds get sandbox tokens.
public enum PushEnvironment: Sendable, Equatable {
    case sandbox, production
}

/// An APNs device token as the server takes it: lowercase hex.
public func pushTokenHex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

public protocol DonorPushService: Sendable {
    func register(token: String, environment: PushEnvironment) async throws
    func unregister() async throws
}

/// Donor push over the donor session (`registerPushDevice` / `unregisterPushDevice`). The server drops the token
/// itself when the session ends, so sign-out needs no unregister.
public struct WireDonorPush: DonorPushService {
    private let product: ProductClient

    public init(origin: URL, session: AccountSession) throws { product = try ProductClient(origin: origin, session: session) }
    init(product: ProductClient) { self.product = product }

    public func register(token: String, environment: PushEnvironment) async throws {
        try await product.perform { client in
            let body = Operations.registerPushDevice.Input.Body.jsonPayload(
                platform: .IOS, token: token, environment: environment == .sandbox ? .SANDBOX : .PRODUCTION)
            switch try await client.registerPushDevice(body: .json(body)) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            default: throw AccountError.unavailable
            }
        }
    }

    public func unregister() async throws {
        try await product.perform { client in
            switch try await client.unregisterPushDevice(.init()) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            default: throw AccountError.unavailable
            }
        }
    }
}

/// A tapped notification, from the data the server sends with it: a `category` (`REFERRAL_CONVERTED`,
/// `STREAK_AT_RISK`, ...) and an app `path` to open. Notifications never carry names or amounts.
public struct PushTap: Sendable, Equatable {
    public let category: String
    public let path: String?

    public init?(category: String?, path: String?) {
        guard let category, category.wholeMatch(of: /[A-Z][A-Z_]{0,63}/) != nil else { return nil }
        self.category = category
        self.path = path.flatMap { $0.count <= 256 ? $0 : nil }
    }

    /// A notification's `userInfo`, whose custom keys sit beside `aps`.
    public init?(userInfo: [AnyHashable: Any]) {
        self.init(category: userInfo["category"] as? String, path: userInfo["path"] as? String)
    }
}
