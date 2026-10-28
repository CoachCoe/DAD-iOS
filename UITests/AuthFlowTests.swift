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
}
