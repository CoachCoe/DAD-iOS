import XCTest

/// Runs the REAL sign-in, session and account-deletion conformers (WireAuth, AccountSession,
/// WireAccountSettings) against the DEBUG-only scripted transport (`--stub-backend`), so the
/// release code path is exercised in the simulator with no network.
@MainActor final class StubBackendFlowTests: XCTestCase {
    private func signIn(_ app: XCUIApplication, code: String) {
        XCTAssertTrue(app.buttons["I’m a donor"].waitForExistence(timeout: 15))
        app.buttons["I’m a donor"].tap()
        app.buttons["Sign in with your phone"].tap()
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        phone.tap()
        phone.typeText("+14155551234")
        app.buttons["Send code"].tap()
        let field = app.textFields["Verification code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(code)
        app.buttons["Verify"].tap()
    }

    func testSignInThenDeleteAccountReturnsToSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"]
        app.launch()
        signIn(app, code: "123456")

        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["delete-start"].waitForExistence(timeout: 10))
        app.buttons["delete-start"].tap()
        let input = app.textFields["delete-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("DELETE")
        app.buttons["delete-confirm"].tap()

        XCTAssertTrue(app.buttons["I’m a donor"].waitForExistence(timeout: 15), "deletion must end the session")
    }

    func testWrongCodeKeepsPersonSignedOut() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"]
        app.launch()
        signIn(app, code: "654321")
        XCTAssertFalse(app.buttons["open-settings"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["Verification code"].exists)
    }

    func testTheAnalyticsQuestionIsAskedOnceAndRemembered() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-analytics-unset"]
        app.launch()
        XCTAssertTrue(app.buttons["analytics-allow"].waitForExistence(timeout: 15))
        app.buttons["analytics-allow"].tap()
        XCTAssertFalse(app.buttons["analytics-allow"].waitForExistence(timeout: 2), "an answered question is not asked again")
        XCTAssertTrue(app.buttons["I’m a donor"].exists)
    }

    func testATappedNotificationOpensItsScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-signed-in", "--stub-push-tap-gifts"]
        app.launch()
        XCTAssertTrue(app.buttons["gift-row-0"].waitForExistence(timeout: 20), "the gifts notification opens gift history")
    }

    func testAnInviteLinkNamesTheReferrerBeforeSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-open-invite"]
        app.launch()
        let invitation = app.staticTexts["auth-invitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 20), "the opened invite link is captured natively")
        XCTAssertEqual(invitation.label, "Alex R invited you to give with DAD.")
    }
}
