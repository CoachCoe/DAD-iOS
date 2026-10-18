import XCTest

final class AccountPreviewTests: XCTestCase {
    func testAccountPreviewLoads() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome, Alex"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Preview · Sample account"].exists)
    }
    func testUnavailableStateCanRecover() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-unavailable"]
        app.launch()
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["Welcome, Alex"].waitForExistence(timeout: 10))
    }
}
