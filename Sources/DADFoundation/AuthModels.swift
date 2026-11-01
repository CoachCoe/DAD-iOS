import Foundation

/// The sign-in methods offered on the auth screen (PRD §5.1). Email+password and phone+SMS
/// are credential flows; Apple/Google are OIDC token exchanges; passkey is WebAuthn. Order is
/// the display order. The admin console is web-only and never appears here.
public enum SignInMethod: String, Sendable, Equatable, CaseIterable, Identifiable {
    case passkey
    case phone
    case emailLink
    case apple
    case google
    case password
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .passkey: "Sign in with a passkey"
        case .phone: "Sign in with your phone"
        case .emailLink: "Email me a sign-in link"
        case .apple: "Sign in with Apple"
        case .google: "Sign in with Google"
        case .password: "Sign in with email & password"
        }
    }
}

/// Transport seam for the sign-in flows, so view models are unit-testable without a network.
/// `WireAuth` implements this against the generated client; tests substitute a fake.
public protocol SignInService: Sendable {
    /// Request a one-time SMS code for `phone` (E.164). Returns a handle that `verifyPhone`
    /// consumes — opaque so the wire layer can carry a server challenge/session id.
    func requestPhoneCode(phone: String) async throws -> String
    /// Verify the SMS `code` against the handle from `requestPhoneCode`, returning credentials.
    func verifyPhone(handle: String, code: String) async throws -> Credentials
}

/// Drives the phone + SMS one-time-code journey: pick number → request code → enter code → done.
/// Explicit state machine so every transition is unit-testable; the view binds to `phase`.
@MainActor @Observable
public final class PhoneSignInModel {
    public enum Phase: Equatable {
        case enterPhone
        case requestingCode
        case enterCode(handle: String)
        case verifying(handle: String)
        case failed(String)
        case signedIn(Credentials)
    }

    public private(set) var phase: Phase = .enterPhone
    public var phone: String = ""
    public var code: String = ""

    /// The SMS challenge handle, retained across `verifying`/`failed` so a retry re-uses it
    /// instead of requesting a fresh code. Cleared only when returning to the phone screen.
    private var activeHandle: String?

    /// True once a code has been sent and not abandoned, including after a wrong code: the
    /// screen stays on code entry so the donor retries without requesting a fresh SMS.
    public var isAwaitingCode: Bool {
        switch phase {
        case .enterCode, .verifying: true
        case .failed: activeHandle != nil
        default: false
        }
    }

    /// Runs the credential-producing work inside the session (`AccountSession.establish`) so the
    /// session owns the await and its epoch guard: a sign-in that resolves after a sign-out is
    /// discarded instead of clobbering state. Returns the credentials that were installed.
    public typealias Establish = @Sendable (@Sendable () async throws -> Credentials) async throws -> Credentials

    private let service: any SignInService
    private let establish: Establish

    public init(service: any SignInService, establish: @escaping Establish) {
        self.service = service
        self.establish = establish
    }

    /// Back-compat shape: the model verifies first, then hands the finished credentials over.
    /// Prefer `init(service:establish:)`, which keeps the network await inside the session.
    public init(service: any SignInService, onEstablish: @escaping @Sendable (Credentials) async -> Void) {
        self.service = service
        self.establish = { produce in
            let credentials = try await produce()
            await onEstablish(credentials)
            return credentials
        }
    }

    /// E.164-ish: a leading + and 8–15 digits. Keeps obviously-bad input off the wire.
    public var canRequestCode: Bool {
        phone.range(of: "^\\+[1-9][0-9]{7,14}$", options: .regularExpression) != nil
    }

    /// The server issues 6-digit codes; enable verify only when the field is complete.
    public var canVerify: Bool {
        code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }

    public func requestCode() async {
        guard canRequestCode else { return }
        if case .requestingCode = phase { return }
        phase = .requestingCode
        do {
            let handle = try await service.requestPhoneCode(phone: phone)
            activeHandle = handle
            phase = .enterCode(handle: handle)
        } catch {
            activeHandle = nil
            phase = .failed(Self.message(for: error))
        }
    }

    public func verify() async {
        guard canVerify, let handle = activeHandle else { return }
        if case .verifying = phase { return }
        phase = .verifying(handle: handle)
        do {
            let service = self.service
            let credentials = try await establish { try await service.verifyPhone(handle: handle, code: code) }
            phase = .signedIn(credentials)
        } catch {
            // Keep the handle so the user can re-enter the code without re-requesting.
            phase = .failed(Self.message(for: error))
        }
    }

    /// Return to the code screen after a recoverable failure, preserving the handle.
    public func retryCodeEntry() {
        guard let handle = activeHandle else { phase = .enterPhone; return }
        phase = .enterCode(handle: handle)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AccountError.signedOut: "That code didn’t match. Check it and try again."
        case AccountError.unavailable: "We couldn’t reach DAD. Please try again in a moment."
        case AccountError.invalidInput: "That phone number doesn’t look right. Check it and try again."
        case AccountError.rateLimited: "Too many attempts. Please wait a moment and try again."
        default: "Something went wrong. Please try again."
        }
    }
}
