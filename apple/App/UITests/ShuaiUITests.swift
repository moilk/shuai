import XCTest

final class ShuaiUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Launch, add a host through the editor, see it in the sidebar.
    @MainActor
    func testAddHostAppearsInSidebar() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let addFirst = app.buttons["add-first-host"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 10), "empty state with 'Add your first host'")
        addFirst.tap()

        // Saving an empty form shows validation instead of closing the sheet.
        let save = app.buttons["save-host-button"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.staticTexts["Enter a name."].waitForExistence(timeout: 3))

        let name = app.textFields["host-name-field"]
        name.tap()
        name.typeText("ui-test-host")
        let host = app.textFields["host-address-field"]
        host.tap()
        host.typeText("example.invalid")
        let user = app.textFields["host-user-field"]
        user.tap()
        user.typeText("alice")
        save.tap()

        let row = app.staticTexts["ui-test-host"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "new host listed in the sidebar")
        XCTAssertTrue(app.staticTexts["alice@example.invalid"].exists)
    }
}
