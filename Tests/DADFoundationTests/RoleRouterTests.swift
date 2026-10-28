import Foundation
import XCTest
@testable import DADFoundation

final class RoleRouterTests: XCTestCase {
    func testStartsRestoringThenResolvesToUnauthenticated() {
        var router = RoleRouter()
        XCTAssertEqual(router.root, .restoring)
        router.restoredSignedOut()
        XCTAssertEqual(router.root, .unauthenticated(selectedRole: nil))
        XCTAssertNil(router.currentRole)
    }

    func testRoleSelectionThenSignInEntersAuthenticatedStack() {
        var router = RoleRouter(root: .unauthenticated(selectedRole: nil))
        router.selectRole(.partner)
        XCTAssertEqual(router.root, .unauthenticated(selectedRole: .partner))
        router.signedIn(as: .partner)
        XCTAssertEqual(router.root, .authenticated(.partner))
        XCTAssertEqual(router.currentRole, .partner)
    }

    func testSignOutClearsRoleAndPendingDestination() {
        var router = RoleRouter(root: .authenticated(.donor))
        _ = router.receive(.gifts) // signed in → not deferred
        router.signedOut()
        XCTAssertEqual(router.root, .unauthenticated(selectedRole: nil))
        XCTAssertNil(router.flushPendingDestination())
    }

    func testDeepLinkDeferredUntilSignedInThenFlushed() {
        var router = RoleRouter(root: .unauthenticated(selectedRole: .donor))
        // Not signed in: destination is deferred, nothing returned to navigate now.
        XCTAssertNil(router.receive(.dashboard))
        router.signedIn(as: .donor)
        XCTAssertEqual(router.flushPendingDestination(), .dashboard)
        // Flushed once.
        XCTAssertNil(router.flushPendingDestination())
    }

    func testDeepLinkWhileSignedInNavigatesImmediately() {
        var router = RoleRouter(root: .authenticated(.donor))
        XCTAssertEqual(router.receive(.profile), .profile)
    }

    func testRestoredSignedOutDoesNotClobberActiveSession() {
        var router = RoleRouter(root: .authenticated(.donor))
        router.restoredSignedOut()
        XCTAssertEqual(router.root, .authenticated(.donor))
    }
}

final class AccessTokenTests: XCTestCase {
    func testAccessTokenReturnsCurrentWhenValid() async throws {
        let store = MemoryStore(Credentials(access: "live", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: StaticAPI(), store: store)
        let token = try await session.accessToken()
        XCTAssertEqual(token, "live")
    }

    func testAccessTokenThrowsSignedOutWithNoCredentials() async {
        let store = MemoryStore(nil)
        do {
            let session = try AccountSession(api: StaticAPI(), store: store)
            _ = try await session.accessToken()
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? AccountError, .signedOut)
        }
    }
}

private struct StaticAPI: AccountAPI {
    func profile(access: String) async throws -> AccountProfile { AccountProfile(email: "a@b.org", publicName: "A") }
    func refresh(token: String) async throws -> Credentials { Credentials(access: "refreshed", refresh: token, expiresAt: .distantFuture) }
    func claim(token: String) async throws -> Credentials { throw AccountError.unavailable }
    func logout(access: String) async throws {}
}

final class ComponentTokenTests: XCTestCase {
    func testKnownTokenResolvesAndUnknownFallsBack() {
        XCTAssertNotNil(DADTokens.color["brand"])
        XCTAssertEqual(CGFloat.dadSpace("4"), 16)
        XCTAssertEqual(CGFloat.dadRadius("pill"), 100)
        // Unknown token name yields 0 spacing rather than a crash.
        XCTAssertEqual(CGFloat.dadSpace("nope"), 0)
    }
}
