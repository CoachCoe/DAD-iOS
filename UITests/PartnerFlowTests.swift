import XCTest

/// Phase F — the partner portal. Launches straight into the signed-in partner shell via dedicated
/// preview args (admin / viewer / pending), without disturbing the donor tests. Covers the DoD
/// cases: verified-or-hidden Overview figures (§7.3), admin-vs-viewer capability gating (§7.2),
/// the <5 suppression path (EM-3 — exercised in unit tests; here the unsuppressed preview shows
/// figures), and the pending-approval gate (P-2).
@MainActor final class PartnerFlowTests: XCTestCase {
    func testAdminPortalRendersVerifiedFiguresAndCanManage() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-partner"]
        app.launch()

        let portal = app.otherElements["partner-portal"]
        XCTAssertTrue(portal.waitForExistence(timeout: 5), "partner portal should appear")

        // Verified figures render; the unverified "deployed" figure is intentionally ABSENT (§7.3).
        XCTAssertTrue(app.staticTexts["partner-committed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["partner-reached"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["partner-deployed"].exists, "unverified figure must be hidden, not estimated")
        // The "Verified by DAD" assurance line is present (§11).
        XCTAssertTrue(app.staticTexts["partner-verified-line"].exists)
        // Admin can manage users.
        XCTAssertTrue(app.buttons["partner-invite"].waitForExistence(timeout: 3))
    }

    func testInviteNeedsValidEmailAndRemoveNeedsConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-partner"]
        app.launch()

        let invite = app.buttons["partner-invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        XCTAssertFalse(invite.isEnabled, "invite stays disabled until the email is plausible")
        let field = app.textFields["partner-invite-email"]
        field.tap()
        field.typeText("not-an-email")
        XCTAssertFalse(invite.isEnabled)
        field.typeText("@acme.com")
        field.clearAndType("new@acme.com")
        XCTAssertTrue(invite.isEnabled)

        XCTAssertFalse(app.buttons["partner-remove-u1"].exists, "an admin cannot remove themselves")
        let remove = app.buttons["partner-remove-u2"]
        XCTAssertTrue(remove.exists)
        remove.tap()
        XCTAssertTrue(app.otherElements["partner-remove-prompt"].waitForExistence(timeout: 3))
        app.buttons["partner-remove-cancel"].tap()
        XCTAssertFalse(app.buttons["partner-remove-confirm"].exists)
        XCTAssertTrue(remove.exists, "cancelling keeps the user")
        remove.tap()
        app.buttons["partner-remove-confirm"].tap()
        XCTAssertFalse(app.buttons["partner-remove-u2"].waitForExistence(timeout: 2), "confirmed removal drops the row")
    }

    func testViewerIsReadOnly() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-partner-viewer"]
        app.launch()

        XCTAssertTrue(app.otherElements["partner-portal"].waitForExistence(timeout: 5))
        // A viewer sees the read-only notice and NO invite button (§7.2 gating).
        XCTAssertTrue(app.staticTexts["partner-readonly"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["partner-invite"].exists, "a viewer must not get the invite action")
    }

    func testPendingApprovalShowsOnlyTheGate() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-partner-pending"]
        app.launch()

        XCTAssertTrue(app.otherElements["partner-portal"].waitForExistence(timeout: 5))
        // P-2: pending account shows the pending notice and nothing else — no overview figures.
        XCTAssertTrue(app.otherElements["partner-pending"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["partner-committed"].exists, "pending must not render portal data")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        guard let current = value as? String, !current.isEmpty else { typeText(text); return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        typeText(text)
    }
}
