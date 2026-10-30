import XCTest

/// Phase H (automatable slice) — the account & settings screen, the App-Store-mandated in-app
/// account-deletion flow iOS was missing. Launches straight into the signed-in settings screen
/// via a dedicated preview arg. Covers: renders profile + toggles, the delete-account confirm
/// gate stays disabled until the exact word is typed (§6.12), and sign-out leaves the shell.
@MainActor final class AccountSettingsFlowTests: XCTestCase {
    func testSettingsRendersProfileAndToggles() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-settings"]
        app.launch()

        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings-email"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["ranking-toggle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["pref-push_streak_at_risk"].exists)
    }

    func testDeleteGateDisabledUntilConfirmWordTyped() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-settings"]
        app.launch()

        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        let start = app.buttons["delete-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.tap()

        let confirm = app.buttons["delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        // Disabled with no / wrong text.
        XCTAssertFalse(confirm.isEnabled)
        let field = app.textFields["delete-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("DELETE")
        // Enabled once the exact word is present.
        XCTAssertTrue(confirm.isEnabled)
    }

    func testSignOutLeavesTheShell() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-settings"]
        app.launch()

        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        let signout = app.buttons["settings-signout"]
        XCTAssertTrue(signout.waitForExistence(timeout: 3))
        signout.tap()
        XCTAssertTrue(app.staticTexts["settings-signed-out"].waitForExistence(timeout: 3))
    }
}
