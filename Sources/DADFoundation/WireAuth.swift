import Foundation
import OpenAPIRuntime

/// Real phone + SMS sign-in against the generated client (`beginPhoneSignIn`, `finishPhoneSignIn`).
///
/// The contract is stateless: the server issues no challenge id, so the "handle" `SignInService`
/// threads between the two steps is the E.164 phone number itself (not a secret; the SMS code is
/// the proof). `verifyPhone` returns credentials but never stores them: the caller passes it to
/// `AccountSession.establish { ... }` so the session owns the await and its epoch guard.
public struct WireAuth: SignInService {
    private let origin: URL
    private let transport: any ClientTransport
    private let deviceName: String?

    public init(origin: URL, deviceName: String? = nil) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(), deviceName: deviceName)
    }

    init(origin: URL, transport: any ClientTransport, deviceName: String? = nil) {
        self.origin = origin; self.transport = transport
        self.deviceName = deviceName.map { String($0.prefix(64)) }
    }

    private var client: Client {
        Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { nil })])
    }

    public func requestPhoneCode(phone: String) async throws -> String {
        switch try await client.beginPhoneSignIn(.init(body: .json(.init(phone: phone)))) {
        case .ok: return phone
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    public func verifyPhone(handle: String, code: String) async throws -> Credentials {
        let body = Operations.finishPhoneSignIn.Input.Body.jsonPayload(phone: handle, code: code, device_name: deviceName, platform: .IOS)
        switch try await client.finishPhoneSignIn(.init(body: .json(body))) {
        case .ok(let response):
            // A browser-shaped `{signed_in:true}` body carries no tokens; never treat it as a session.
            guard case .NativeSession(let session) = try response.body.json else { throw AccountError.invalidResponse }
            return try nativeCredentials(session)
        case .unauthorized: throw AccountError.signedOut
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }
}

func nativeCredentials(_ value: Components.Schemas.NativeSession) throws -> Credentials {
    guard !value.access_token.isEmpty, !value.refresh_token.isEmpty, value.expires_in > 0 else { throw AccountError.invalidResponse }
    return Credentials(access: value.access_token, refresh: value.refresh_token, expiresAt: Date().addingTimeInterval(Double(value.expires_in)))
}
