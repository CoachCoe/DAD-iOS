import XCTest

@MainActor final class AuthFlowTests: XCTestCase {
    /// A session-less launch lands on role-select; choosing a role reaches the sign-in
    /// methods, and the phone method opens the SMS-code journey (PRD §5.1, D-1).
    func testSignedOutLaunchReachesPhoneSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-signed-out"]
        app.launch()

        // Role select is the unauthenticated entry point.
        XCTAssertTrue(app.buttons["I’m a donor"].waitForExistence(timeout: 10))
        app.buttons["I’m a donor"].tap()

        // Sign-in method picker.
        XCTAssertTrue(app.buttons["Sign in with your phone"].waitForExistence(timeout: 10))
        app.buttons["Sign in with your phone"].tap()

        // Phone + SMS code screen renders with its phone field.
        XCTAssertTrue(app.staticTexts["Sign in with your phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Phone number"].exists)
    }

    /// A valid phone number advances to code entry, and Send code stays disabled for junk input.
    func testPhoneNumberAdvancesToCodeEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-signed-out"]
        app.launch()

        app.buttons["I’m a donor"].tap()
        XCTAssertTrue(app.buttons["Sign in with your phone"].waitForExistence(timeout: 10))
        app.buttons["Sign in with your phone"].tap()

        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send code"].isEnabled)
        phone.tap()
        phone.typeText("+14155551234")
        XCTAssertTrue(app.buttons["Send code"].isEnabled)
        app.buttons["Send code"].tap()

        let code = app.textFields["Verification code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Verify"].isEnabled)
        code.tap()
        code.typeText("123456")
        XCTAssertTrue(app.buttons["Verify"].isEnabled)
    }

    /// Methods without a wired transport are visibly unavailable rather than silently inert.
    func testUnwiredMethodsAreDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-signed-out"]
        app.launch()

        app.buttons["I’m a donor"].tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Sign in with Apple"].isEnabled)
        XCTAssertTrue(app.buttons["Sign in with your phone"].isEnabled)
    }
}
