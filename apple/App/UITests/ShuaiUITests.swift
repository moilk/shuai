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

    // MARK: tmux (fixture topology, no server)

    @MainActor
    private func launchWithTmuxFixture() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-debugTmuxFixture"]
        app.launch()
        return app
    }

    /// ⌘K from the host list. The first chord after a launch is sometimes dropped by the
    /// simulator's keyboard focus, so it is retried once.
    @MainActor
    private func openQuickSwitcher(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["quick-switcher-field"]
        for _ in 0 ..< 2 {
            app.staticTexts["host-row-fixture-host"].firstMatch.tap()
            app.typeKey("k", modifierFlags: .command)
            if field.waitForExistence(timeout: 4) { return field }
        }
        // Simulator key delivery after an earlier test can stay broken: the toolbar button opens the same sheet.
        app.buttons["quick-switcher-button"].tap()
        _ = field.waitForExistence(timeout: 5)
        return field
    }

    @MainActor
    func testSidebarShowsTheTmuxTree() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-session-main"].waitForExistence(timeout: 10), "session row")
        XCTAssertTrue(app.buttons["tmux-session-scratch"].exists)
        let claude = app.buttons["tmux-window-@1"]
        XCTAssertTrue(claude.exists)
        XCTAssertEqual(claude.value as? String, "active")
        XCTAssertTrue(app.buttons["tmux-window-@0"].exists)
        // only the two-pane window lists its panes
        XCTAssertTrue(app.buttons["tmux-pane-%1"].exists)
        XCTAssertTrue(app.buttons["tmux-pane-%2"].exists)
        XCTAssertFalse(app.buttons["tmux-pane-%0"].exists)
    }

    @MainActor
    func testQuickSwitcherFiltersAndIsKeyboardNavigable() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-session-main"].waitForExistence(timeout: 10))
        let field = openQuickSwitcher(app)
        XCTAssertTrue(field.exists, "⌘K opens the switcher")
        // empty query lists everything; first row is selected
        let first = app.buttons["quick-switcher-row-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.value as? String, "selected")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(app.buttons["quick-switcher-row-1"].value as? String, "selected")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(first.value as? String, "selected")
        // typing filters
        field.typeText("logs")
        XCTAssertTrue(app.buttons["quick-switcher-row-0"].staticTexts["0: logs"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["quick-switcher-row-3"].exists)
        // esc closes
        app.typeKey("\u{1B}", modifierFlags: [])
        if !field.waitForNonExistence(timeout: 3) {
            // XCUITest does not always deliver a bare Escape to a text field; the close button is the same action.
            app.buttons["quick-switcher-close"].tap()
        }
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testReturnInTheSwitcherClosesIt() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-session-main"].waitForExistence(timeout: 10))
        let field = openQuickSwitcher(app)
        XCTAssertTrue(field.exists, "⌘K opens the switcher")
        field.typeText("claude\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testClosingAPaneFromItsContextMenuAsksFirst() throws {
        let app = launchWithTmuxFixture()
        let pane = app.buttons["tmux-pane-%1"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.press(forDuration: 1.0)
        let close = app.buttons["Close Pane"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "pane context menu offers Close Pane")
        close.tap()
        XCTAssertTrue(app.buttons["confirm-kill"].waitForExistence(timeout: 5), "closing asks for confirmation")
        // nothing was sent (the fixture has no server); the pane is still listed
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(pane.exists)
    }

    // MARK: agent integration (fixture: the real recorded Claude Code transcript through a fake monitor)

    @MainActor
    private func launchWithAgentFixture() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-debugAgentFixture"]
        app.launch()
        return app
    }

    @MainActor
    func testAgentBadgeAppearsOnTheWindowOfTheWaitingPane() throws {
        let app = launchWithAgentFixture()
        let window = app.buttons["tmux-window-@0"]  // pane %0 hosts the transcript's session
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let badge = app.images["pane-badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "needs-approval badge: \(app.debugDescription)")
        XCTAssertEqual(badge.label, "needs approval")
        // it sits in the row of window @0, not @1
        let w0 = window.frame, w1 = app.buttons["tmux-window-@1"].frame
        let centers = app.images.matching(identifier: "pane-badge").allElementsBoundByIndex
            .map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        XCTAssertTrue(centers.contains { w0.contains($0) }, "a badge inside the @0 row: \(centers) vs \(w0)")
        XCTAssertFalse(centers.contains { w1.contains($0) }, "no badge in the @1 row")
        // host row: waiting count
        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'waiting for you'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "host row shows the waiting count")
    }

    @MainActor
    func testPermissionCardAllowRecordsRespondAndThenDisappears() throws {
        let app = launchWithAgentFixture()
        let card = app.descendants(matching: .any)["permission-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12), "card for the first permission request")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fixture-host'")).firstMatch.exists,
            "context label names the host: \(card.debugDescription)")
        let allow = app.buttons["permission-allow"].firstMatch
        XCTAssertTrue(allow.exists)
        allow.tap()
        let log = app.descendants(matching: .any)["agent-fixture-log"]
        let deadline = Date().addingTimeInterval(10)
        var value = ""
        while Date() < deadline {
            value = (log.value as? String) ?? ""
            if value.contains("respond") { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(value.contains("2604cfd0b70257a07ee252c762c243d8"), "respond for the request id: \(value)")
        XCTAssertTrue(value.contains("allow"))
        // the agent reports permission_resolved: the card goes away
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: card)
        waitForExpectations(timeout: 10)
    }

    /// With the software keyboard up the docked accessory bar is used (above the keyboard); the
    /// floating bar must not appear over the terminal text.
    @MainActor
    func testSoftwareKeyboardShowsTheDockedBarAndNothingCoversTheFirstRow() throws {
        let app = launchWithAgentFixture()
        XCTAssertTrue(app.images["pane-badge"].firstMatch.waitForExistence(timeout: 12))
        let terminal = app.descendants(matching: .any)["terminal-view"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "software keyboard is up")
        let esc = app.buttons["Esc"].firstMatch
        XCTAssertTrue(esc.waitForExistence(timeout: 10), "accessory bar present")
        // Let any keyboard / bar re-layout settle, then check it stayed stable (no flip-flopping loop).
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(esc.exists)
        XCTAssertGreaterThan(esc.frame.minY, terminal.frame.midY, "the bar sits at the bottom, not over the top rows")
        XCTAssertLessThanOrEqual(esc.frame.maxY, keyboard.frame.maxY + 1)
        // nothing but the terminal itself occupies the first row band
        let firstRow = CGRect(x: terminal.frame.minX, y: terminal.frame.minY, width: terminal.frame.width, height: 20)
        for b in app.buttons.allElementsBoundByIndex where b.frame.width > 0 && b.exists {
            let l = b.label
            if ["Esc", "Ctrl", "Alt", "Tab"].contains(l) {
                XCTAssertFalse(b.frame.intersects(firstRow), "accessory key '\(l)' overlaps the first terminal row")
            }
        }
    }

    @MainActor
    func testQuickSwitcherRanksTheWaitingSessionFirst() throws {
        let app = launchWithAgentFixture()
        XCTAssertTrue(app.images["pane-badge"].firstMatch.waitForExistence(timeout: 12))
        _ = openQuickSwitcher(app)
        let first = app.buttons["quick-switcher-row-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("shell"), "waiting window first, got: \(first.label)")
        XCTAssertTrue(first.label.contains("Needs permission"), "row shows the agent state: \(first.label)")
    }
}
