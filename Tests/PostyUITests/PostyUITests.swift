import XCTest

final class PostyUITests: XCTestCase {
    @MainActor
    func testConnectionManagerLaunches() {
        let app = XCUIApplication()
        app.launchEnvironment["POSTY_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Connections"].exists || app.buttons["New Connection"].exists)
    }

    @MainActor
    func testConnectionEditorAndNewWindowCommand() {
        let app = XCUIApplication()
        app.launchEnvironment["POSTY_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))

        let add = app.buttons["newConnection"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        XCTAssertTrue(app.textFields["connectionURL"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["connectConnection"].exists)
        XCTAssertFalse(app.buttons["Save"].exists)
        app.buttons["Cancel"].click()

        let initialWindowCount = app.windows.count
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: initialWindowCount).waitForExistence(timeout: 5))
    }
}
