import Foundation

/// Which product surface the signed-in person is using. Donor and partner are
/// distinct journeys (PRD §6 vs §7) with separate tab stacks; the admin console
/// is web-only and intentionally absent here.
public enum AppRole: String, Sendable, Equatable, Codable {
    case donor
    case partner
}

/// Top-level navigation state for the app shell. Drives which root stack is shown:
/// an unauthenticated stack (role select + auth), or the donor/partner stack once
/// a session exists. Value type + explicit transitions so it is unit-testable without UI.
public struct RoleRouter: Sendable {
    public enum Root: Sendable, Equatable {
        /// No session yet; the person has not chosen (or we have not restored) a role.
        case unauthenticated(selectedRole: AppRole?)
        /// A session exists for this role; show its tab stack.
        case authenticated(AppRole)
        /// Session state is being restored on launch.
        case restoring
    }

    public private(set) var root: Root
    /// A deep-link destination deferred until the person is signed in (mirrors NavigationGate).
    public private(set) var gate = NavigationGate()

    public init(root: Root = .restoring) { self.root = root }

    /// The person picked a role on the unauthenticated splash before signing in.
    public mutating func selectRole(_ role: AppRole) {
        if case .authenticated = root { return }
        root = .unauthenticated(selectedRole: role)
    }

    /// A session was established for `role` (sign-in, claim link, or restored on launch).
    public mutating func signedIn(as role: AppRole) {
        root = .authenticated(role)
    }

    /// The session ended — drop any deferred destination and return to the splash.
    public mutating func signedOut() {
        gate.signedOut()
        root = .unauthenticated(selectedRole: nil)
    }

    /// Restore finished with no usable session.
    public mutating func restoredSignedOut() {
        if case .authenticated = root { return }
        root = .unauthenticated(selectedRole: nil)
    }

    /// Receive a deep-link account destination, deferring it until signed in.
    public mutating func receive(_ destination: AccountDestination) -> AccountDestination? {
        let signedIn: Bool
        if case .authenticated = root { signedIn = true } else { signedIn = false }
        return gate.receive(destination, signedIn: signedIn)
    }

    /// Flush a deferred destination once signed in (call right after `signedIn(as:)`).
    public mutating func flushPendingDestination() -> AccountDestination? {
        gate.signedIn()
    }

    public var currentRole: AppRole? {
        if case .authenticated(let role) = root { return role }
        return nil
    }
}
