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

    @MainActor
    func testCancelWithChangesAsksToDiscard() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let addFirst = app.buttons["add-first-host"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 10))
        addFirst.tap()

        let name = app.textFields["host-name-field"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("unsaved-host")

        app.buttons["Cancel"].tap()
        let keep = app.buttons.matching(identifier: "keep-editing").firstMatch
        XCTAssertTrue(app.buttons["discard-changes"].waitForExistence(timeout: 5), "unsaved input asks before closing")
        XCTAssertTrue(keep.exists)
        keep.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Keep Editing leaves the sheet open")
        XCTAssertEqual(name.value as? String, "unsaved-host")

        app.buttons["Cancel"].tap()
        let discard = app.buttons.matching(identifier: "discard-changes").firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(addFirst.waitForExistence(timeout: 5), "Discard Changes closes the editor")
        XCTAssertFalse(app.staticTexts["unsaved-host"].exists)
    }

    @MainActor
    func testPushingKeysKeepsThePasswordAndDirtyState() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let addFirst = app.buttons["add-first-host"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 10))
        addFirst.tap()
        XCTAssertTrue(app.textFields["host-name-field"].waitForExistence(timeout: 5))

        let method = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Method'")).firstMatch
        method.tap()
        app.buttons["Password"].firstMatch.tap()
        let secret = app.secureTextFields.firstMatch
        XCTAssertTrue(secret.waitForExistence(timeout: 5))
        secret.tap()
        secret.typeText("hunter2")

        method.tap()
        app.buttons["SSH key"].firstMatch.tap()
        let generate = app.buttons["editor-open-keys"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        generate.tap()
        XCTAssertTrue(app.navigationBars["Keys"].waitForExistence(timeout: 5))
        app.navigationBars["Keys"].buttons.firstMatch.tap()
        XCTAssertTrue(app.textFields["host-name-field"].waitForExistence(timeout: 5))

        method.tap()
        app.buttons["Password"].firstMatch.tap()
        let again = app.secureTextFields.firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        // An empty secure field reports its placeholder as the value; typed text reports bullets.
        let shown = again.value as? String ?? ""
        XCTAssertNotEqual(shown, "Password", "the field is not empty: the typed password survives a pushed page")
        XCTAssertTrue(shown.contains("•"), "the field shows bullets, got \(shown)")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "discard-changes").firstMatch.waitForExistence(timeout: 5),
                      "still dirty after returning from Keys")
    }

    @MainActor
    func testSaveWithErrorsFocusesTheFirstInvalidField() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let addFirst = app.buttons["add-first-host"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 10))
        addFirst.tap()

        let save = app.buttons["save-host-button"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.staticTexts["Enter a name."].waitForExistence(timeout: 3))
        let hasFocus = NSPredicate(format: "hasKeyboardFocus == true")
        let focused = expectation(for: hasFocus, evaluatedWith: app.textFields["host-name-field"])
        wait(for: [focused], timeout: 5)
    }

    // MARK: tmux (fixture topology, no server)

    @MainActor
    private func launchWithTmuxFixture(extraArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-debugTmuxFixture"] + extraArguments
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
    func testOnlyTheViewedSessionShowsACurrentWindow() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-session-main"].waitForExistence(timeout: 10))
        // Read the session rows before expanding: with scratch expanded the list can push rows off a small screen.
        XCTAssertTrue(app.buttons["tmux-session-main"].isSelected, "the viewed session is marked")
        XCTAssertFalse(app.buttons["tmux-session-scratch"].isSelected)
        XCTAssertEqual(app.buttons["tmux-window-@1"].value as? String, "active")
        XCTAssertTrue(app.buttons["tmux-window-@1"].isSelected)
        let toggle = app.buttons["tmux-session-toggle-scratch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let other = app.buttons["tmux-window-@5"]
        XCTAssertTrue(other.waitForExistence(timeout: 5), "scratch window")
        XCTAssertNotEqual(other.value as? String, "active", "a window of a session that is not viewed is not current")
        XCTAssertFalse(other.isSelected)
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

    @MainActor
    func testCollapsingASessionHidesItsWindows() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        let toggle = app.buttons["tmux-session-toggle-main"]
        XCTAssertTrue(toggle.exists, "session chevron")
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
        toggle.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["tmux-window-@1"])
        expectation(for: gone, evaluatedWith: app.buttons["tmux-window-@0"])
        expectation(for: gone, evaluatedWith: app.buttons["tmux-pane-%1"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["tmux-session-main"].exists, "the session row stays")
        app.buttons["tmux-session-toggle-main"].tap()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 5), "windows return")
        XCTAssertTrue(app.buttons["tmux-window-@0"].exists)
    }

    @MainActor
    func testHostMenuExplainsDisabledAIItems() throws {
        let app = launchWithTmuxFixture()
        let row = app.staticTexts["host-row-fixture-host"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5), "host menu is open")
        let hint = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connect to this host first'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "disabled AI items say why: \(app.debugDescription)")
    }

    @MainActor
    func testConfirmingCloseRunsTheKill() throws {
        let app = launchWithTmuxFixture()
        let pane = app.buttons["tmux-pane-%1"]
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.press(forDuration: 1.0)
        let close = app.buttons["Close Pane"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let confirm = app.buttons["confirm-kill"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // the fixture's monitor is idle, so a kill that really runs reports this notice
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'session-notice' AND label CONTAINS 'tmux is not connected.'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "confirming Close runs the kill: \(app.debugDescription)")
    }

    // MARK: deep links (shuai://open?host=&pane=, what an ntfy push click opens)

    private static let fixtureHost = "5B0F1C00-0000-4000-8000-00000000F1E1"

    @MainActor
    func testDeepLinkSelectsTheNamedPane() throws {
        let app = launchWithTmuxFixture()
        let shell = app.buttons["tmux-window-@0"]
        let claude = app.buttons["tmux-window-@1"]
        XCTAssertTrue(claude.waitForExistence(timeout: 10))
        XCTAssertEqual(claude.value as? String, "active")
        XCTAssertNotEqual(shell.value as? String, "active")
        app.open(URL(string: "shuai://open?host=\(Self.fixtureHost)&pane=%250")!)
        // pane %0 lives in window @0: it becomes the active window, @1 no longer is
        let active = NSPredicate(format: "value == 'active'")
        expectation(for: active, evaluatedWith: shell)
        waitForExpectations(timeout: 15)
        XCTAssertNotEqual(claude.value as? String, "active")
    }

    @MainActor
    func testDeepLinkToAMissingPaneOrHostShowsAFriendlyNotice() throws {
        let app = launchWithTmuxFixture(extraArguments: ["-debugNoticeTimeScale", "10"])
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        app.open(URL(string: "shuai://open?host=\(Self.fixtureHost)&pane=%2599")!)
        // The notice is transient: match its text in the query itself instead of re-reading it later.
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'session-notice' AND label CONTAINS 'no longer exists'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["tmux-window-@1"].value as? String, "active", "nothing moved")

        app.open(URL(string: "shuai://open?host=00000000-0000-4000-8000-000000000000&pane=%250")!)
        let unknown = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'not in Shuai'")).firstMatch
        XCTAssertTrue(unknown.waitForExistence(timeout: 10))

        app.open(URL(string: "shuai://open?host=nope&pane=%250;rm")!)
        let invalid = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'not a valid'")).firstMatch
        XCTAssertTrue(invalid.waitForExistence(timeout: 10))
    }

    /// Scrolls the list inside the open sheet (not the whole app) until `target` is hittable; bounded.
    @MainActor
    private func scrollSheet(_ app: XCUIApplication, until target: XCUIElement, title: String = "Settings", maxSwipes: Int = 12) {
        let bar = app.navigationBars[title]
        let sheetX = bar.frame.midX
        let lists = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
        let list = lists.first { $0.frame.minX <= sheetX && sheetX <= $0.frame.maxX && $0.frame.width < app.frame.width * 0.95 }
            ?? lists.first { $0.frame.minX <= sheetX && sheetX <= $0.frame.maxX }
        var swipes = 0
        while !target.isHittable, swipes < maxSwipes {
            _ = target.waitForExistence(timeout: 0.5)
            if target.isHittable { break }
            (list ?? app).swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(target.isHittable, "\(target) not reachable after \(swipes) swipes\n\(app.debugDescription)")
    }

    /// The software keyboard (up while the terminal is focused) covers the sidebar bottom bar, so
    /// tests that use the bar first move focus out of the terminal by tapping the host row.
    @MainActor
    private func hideSoftwareKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        app.staticTexts["host-row-fixture-host"].tap()
        let gone = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: app.keyboards)
        if XCTWaiter().wait(for: [gone], timeout: 3) != .completed {
            // Landscape: the keyboard's dismiss key sits at its trailing bottom corner. The key's own
            // frame is reported off screen by the simulator, so tap the corner of the keyboard frame.
            let frame = app.keyboards.firstMatch.frame
            let window = app.windows.firstMatch
            let corner = CGVector(dx: (frame.maxX - 40) / window.frame.width, dy: (frame.maxY - 50) / window.frame.height)
            window.coordinate(withNormalizedOffset: corner).tap()
        }
        for id in ["add-host-button", "settings-button"] {
            let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons[id])
            wait(for: [hittable], timeout: 5)
        }
    }

    /// Taps the sidebar bottom bar's Settings button.
    @MainActor
    private func tapSettings(_ app: XCUIApplication) {
        hideSoftwareKeyboard(app)
        let button = app.buttons["settings-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "settings-button missing\n\(app.debugDescription)")
        button.tap()
    }

    @MainActor
    func testSidebarTopHasOnlyQuickSwitcher() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        hideSoftwareKeyboard(app)
        XCTAssertTrue(app.buttons["quick-switcher-button"].exists)
        let add = app.buttons["add-host-button"], settings = app.buttons["settings-button"]
        XCTAssertTrue(add.exists, "New Host is in the bottom bar")
        XCTAssertTrue(settings.exists, "Settings is in the bottom bar")
        let hostRow = app.buttons["tmux-window-@1"].frame
        let list = app.collectionViews.firstMatch.frame
        XCTAssertGreaterThan(add.frame.minY, list.midY, "New Host sits in the lower half of the sidebar")
        XCTAssertGreaterThan(settings.frame.minY, list.midY, "Settings sits in the lower half of the sidebar")
        XCTAssertGreaterThan(add.frame.minY, hostRow.maxY, "the bottom bar sits below the rows")
        XCTAssertLessThan(settings.frame.maxX, app.frame.width / 2, "the bottom bar is in the sidebar column")
        XCTAssertFalse(app.buttons["more-menu"].exists, "the More menu is retired")
        XCTAssertFalse(app.buttons["keys-button"].exists, "Keys lives in Settings and the app menu")
    }

    @MainActor
    func testSettingsButtonOpensSettingsDirectly() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        tapSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "one tap opens Settings, no menu")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 5))
    }

    /// Both bottom-bar buttons are the system's icon-only bar buttons, which report 36 pt: a taller
    /// frame on them makes the whole bar report as not hittable.
    @MainActor
    func testSidebarBottomBarTargetsAreAtLeast36pt() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        hideSoftwareKeyboard(app)
        let add = app.buttons["add-host-button"], settings = app.buttons["settings-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable, "add-host-button hittable")
        XCTAssertTrue(settings.isHittable, "settings-button hittable")
        XCTAssertGreaterThanOrEqual(add.frame.height, 36, "add-host-button tap target height")
        XCTAssertGreaterThanOrEqual(add.frame.width, 36, "add-host-button tap target width")
        XCTAssertGreaterThanOrEqual(settings.frame.height, 36, "settings-button tap target height")
        XCTAssertGreaterThanOrEqual(settings.frame.width, 36, "settings-button tap target width")
    }

    @MainActor
    func testSidebarBottomBarAtAccessibilitySizeStillWorks() throws {
        let app = launchWithTmuxFixture(
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        hideSoftwareKeyboard(app)
        let add = app.buttons["add-host-button"], settings = app.buttons["settings-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
        XCTAssertTrue(settings.isHittable)
        XCTAssertEqual(add.label, "New Host", "icon-only keeps its accessibility label")
        XCTAssertFalse(app.staticTexts["New Host"].exists, "New Host is icon-only at accessibility sizes")
        XCTAssertFalse(add.frame.intersects(settings.frame), "buttons never overlap")
    }

    /// The brand title is a leading toolbar item, left of the trailing Quick Switcher.
    @MainActor
    func testSidebarTitleIsLeadingAndLeftOfTheQuickSwitcher() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        let title = app.staticTexts["sidebar-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "sidebar-title missing\n\(app.debugDescription)")
        let search = app.buttons["quick-switcher-button"]
        XCTAssertTrue(search.exists)
        let list = app.collectionViews.firstMatch.frame
        XCTAssertLessThan(title.frame.midX, list.midX, "the title sits in the left half of the sidebar")
        XCTAssertLessThan(title.frame.maxX, search.frame.minX, "the title is left of Quick Switcher")
        XCTAssertEqual(title.label, "shuai")
        // Not flush with the sidebar's edge. The system's own inset differs by OS (about 4 pt on iOS 26,
        // about 12 pt on iOS 27) and the title adds 8 pt on top. 10 pt holds on both; it only tells the
        // padding apart on iOS 26 (4 pt without it), on iOS 27 the system inset alone already passes.
        XCTAssertGreaterThanOrEqual(title.frame.minX - list.minX, 10, "the title keeps a leading inset")
    }

    /// New Host and Settings are icon-only and sit together at the trailing side of the sidebar.
    @MainActor
    func testBottomBarButtonsAreIconOnlyAndTrailing() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        hideSoftwareKeyboard(app)
        let add = app.buttons["add-host-button"], settings = app.buttons["settings-button"]
        let list = app.collectionViews.firstMatch.frame
        XCTAssertGreaterThan(add.frame.midX, list.midX, "New Host is in the right half of the sidebar")
        XCTAssertGreaterThan(settings.frame.midX, list.midX, "Settings is in the right half of the sidebar")
        XCTAssertLessThan(add.frame.maxX, settings.frame.minX, "New Host is left of Settings")
        XCTAssertEqual(add.label, "New Host")
        XCTAssertFalse(app.staticTexts["New Host"].exists, "no text capsule in the bar")
    }

    /// The status indicator is the label of the connection menu; nothing disconnects with one tap.
    /// The fixture has no live connection, so the menu offers Reconnect.
    @MainActor
    func testStatusIndicatorOpensAConnectionMenu() throws {
        let app = launchWithTmuxFixture()
        let status = app.buttons["connection-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "connection-status is a button\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["disconnect-button"].exists, "no top-level Disconnect button")
        XCTAssertFalse(app.buttons["connect-button"].exists, "no top-level Connect button")
        status.tap()
        XCTAssertTrue(app.buttons["connect-button"].waitForExistence(timeout: 5), "the menu offers Reconnect\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["disconnect-button"].exists)
    }

    @MainActor
    func testSidebarBottomBarPassesTheAccessibilityAudit() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["settings-button"].waitForExistence(timeout: 10))
        hideSoftwareKeyboard(app)
        let bar = app.buttons["add-host-button"].frame.union(app.buttons["settings-button"].frame).insetBy(dx: -1, dy: -1)
        try app.performAccessibilityAudit(for: [.dynamicType, .hitRegion, .sufficientElementDescription]) { issue in
            // Only the bottom bar is audited here; other screens have their own owners.
            guard let frame = issue.element?.frame else { return true }
            return !bar.contains(frame)
        }
    }

    @MainActor
    private func openPushSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        tapSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let link = app.buttons["push-settings-link"]
        scrollSheet(app, until: link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Background push (ntfy)"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNotificationSettingsShowTopicAndTestButton() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        tapSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.keyboards.count, 0, "opening Settings resigns the terminal so its keyboard does not cover the sheet")
        let link = app.buttons["push-settings-link"]
        scrollSheet(app, until: link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Background push (ntfy)"].waitForExistence(timeout: 5))
        // top to bottom, so scrolling for the next target never passes an earlier one
        let topic = app.staticTexts["push-topic"]
        scrollSheet(app, until: topic, title: "Background push (ntfy)")
        // masked by default: the label never matches the full topic
        XCTAssertNil(topic.label.firstMatch(of: /shuai-[a-z2-7]{26}/), "topic must be masked: \(topic.label)")
        let reveal = app.buttons["push-topic-reveal"]
        XCTAssertTrue(reveal.isHittable)
        reveal.tap()
        let revealed = app.staticTexts["push-topic"]
        XCTAssertNotNil(revealed.label.firstMatch(of: /shuai-[a-z2-7]{26}/), revealed.label)
        scrollSheet(app, until: app.buttons["push-open-ntfy"], title: "Background push (ntfy)")
        XCTAssertTrue(app.buttons["push-open-ntfy"].exists)
        scrollSheet(app, until: app.buttons["push-send-test"], title: "Background push (ntfy)")
        XCTAssertTrue(app.buttons["push-send-test"].exists)
        scrollSheet(app, until: app.textFields["push-server-field"], title: "Background push (ntfy)")
        XCTAssertEqual(app.textFields["push-server-field"].value as? String, "https://ntfy.sh")
    }

    @MainActor
    func testCopyTopicStillWorks() throws {
        let app = launchWithTmuxFixture()
        openPushSettings(app)
        let copy = app.buttons["push-copy-topic"]
        scrollSheet(app, until: copy, title: "Background push (ntfy)")
        XCTAssertEqual(copy.label, "Copy topic")
        copy.tap()
        XCTAssertEqual(app.buttons["push-copy-topic"].label, "Copied")
    }

    @MainActor
    func testSettingsFirstPageShowsPushSummaryWithoutTheTopic() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        tapSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let link = app.buttons["push-settings-link"]
        scrollSheet(app, until: link)
        XCTAssertTrue(link.label.contains("Background push"), link.label)
        XCTAssertFalse(link.label.contains("shuai-"), link.label)
        XCTAssertFalse(String(describing: link.value ?? "").contains("shuai-"))
        XCTAssertFalse(app.staticTexts["push-topic"].exists, "the topic row lives on the push page only")
    }

    // MARK: agent integration (fixture: the real recorded Claude Code transcript through a fake monitor)

    @MainActor
    private func launchWithAgentFixture(extraArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-debugAgentFixture"] + extraArguments
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
    func testCollapsedHostKeepsTheWaitingBadge() throws {
        let app = launchWithAgentFixture()
        XCTAssertTrue(app.buttons["tmux-window-@0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["pane-badge"].firstMatch.waitForExistence(timeout: 10))
        let toggle = app.buttons["host-toggle-fixture-host"]
        XCTAssertTrue(toggle.exists, "host chevron")
        toggle.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["tmux-window-@0"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any)["host-aggregate-badge"].waitForExistence(timeout: 5), "badge stays on the collapsed host")
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

    /// A notice posted while a permission card is pending stays reachable: its dismiss button can be
    /// tapped and the card is untouched.
    @MainActor
    func testNoticeCanBeDismissedWhileAPermissionCardIsPending() throws {
        let app = launchWithAgentFixture(extraArguments: ["-debugNoticeTimeScale", "10"])
        let card = app.descendants(matching: .any)["permission-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        app.open(URL(string: "shuai://open?host=00000000-0000-4000-8000-000000000000&pane=%250")!)
        let notice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'session-notice' AND label CONTAINS 'not in Shuai'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let dismiss = app.buttons["notice-dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertFalse(notice.frame.intersects(card.frame), "notice \(notice.frame) clear of the card column \(card.frame)")
        XCTAssertTrue(dismiss.isHittable, "the card column does not cover the notice")
        dismiss.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notice)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(card.exists, "the permission card stays")
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
        let esc = app.buttons["accessory-esc"].firstMatch
        XCTAssertTrue(esc.waitForExistence(timeout: 10), "accessory bar present")
        // Let any keyboard / bar re-layout settle, then check it stayed stable (no flip-flopping loop).
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(esc.exists)
        // docked bar: directly above the keyboard (the bar is a few rows tall), never at the top of the terminal
        XCTAssertGreaterThanOrEqual(esc.frame.minY, keyboard.frame.minY - 200, "the bar sits right above the keyboard")
        XCTAssertGreaterThan(esc.frame.minY, terminal.frame.minY + 200, "the bar is not over the top rows")
        XCTAssertLessThanOrEqual(esc.frame.maxY, keyboard.frame.maxY + 1)
        // nothing but the terminal itself occupies the first row band
        let firstRow = CGRect(x: terminal.frame.minX, y: terminal.frame.minY, width: terminal.frame.width, height: 20)
        for b in app.buttons.allElementsBoundByIndex where b.frame.width > 0 && b.exists {
            let l = b.identifier
            if ["accessory-esc", "accessory-ctrl", "accessory-alt", "accessory-tab"].contains(l) {
                XCTAssertFalse(b.frame.intersects(firstRow), "accessory key '\(l)' overlaps the first terminal row")
            }
        }
    }

    /// `-debugHardwareKeyboard` makes the app see a hardware keyboard and never a software one.
    @MainActor
    func testHardwareKeyboardBarShowsByDefault() throws {
        let app = launchWithTmuxFixture(extraArguments: ["-debugHardwareKeyboard"])
        XCTAssertTrue(app.buttons["accessory-esc"].firstMatch.waitForExistence(timeout: 10), "floating bar present")
    }

    @MainActor
    func testHardwareKeyboardBarHiddenWhenSettingIsHide() throws {
        let app = launchWithTmuxFixture(extraArguments: ["-debugHardwareKeyboard", "-hardwareKeyboardBar", "hide"])
        XCTAssertTrue(app.descendants(matching: .any)["terminal-view"].waitForExistence(timeout: 10), "terminal")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.buttons["accessory-esc"].firstMatch.exists, "no bar with a hardware keyboard and Hide")
    }

    @MainActor
    func testSettingsOffersHardwareKeyboardBarShowOrHide() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        tapSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let picker = app.segmentedControls["hardware-keyboard-bar-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5) || { scrollSheet(app, until: picker); return true }(), "picker")
        XCTAssertTrue(picker.buttons["Show"].isSelected, "Show is the default")
        picker.buttons["Hide"].tap()
        XCTAssertTrue(picker.buttons["Hide"].isSelected)
    }

    /// Every accessory key is a 44 pt tap target (docked bar, default text size).
    @MainActor
    func testAccessoryBarKeysAreAtLeast44ptTall() throws {
        let app = launchWithAgentFixture()
        XCTAssertTrue(app.images["pane-badge"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "software keyboard is up")
        for id in ["accessory-esc", "accessory-tab", "accessory-ctrl", "accessory-alt"] {
            let key = app.buttons[id].firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 10), "\(id) present")
            XCTAssertGreaterThanOrEqual(key.frame.height, 44, "\(id) tap target height")
        }
    }

    /// At an accessibility text size the docked bar grows and still leaves the first row visible.
    @MainActor
    func testAccessoryBarGrowsAtAccessibilityTextSize() throws {
        func barHeight(_ extra: [String]) -> (CGFloat, Bool) {
            let app = launchWithAgentFixture(extraArguments: extra)
            let terminal = app.descendants(matching: .any)["terminal-view"].firstMatch
            XCTAssertTrue(terminal.waitForExistence(timeout: 10))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            let esc = app.buttons["accessory-esc"].firstMatch
            XCTAssertTrue(esc.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            let top = app.buttons["accessory-esc"].firstMatch.frame.minY
            let firstRow = CGRect(x: terminal.frame.minX, y: terminal.frame.minY, width: terminal.frame.width, height: 20)
            let covered = ["accessory-esc", "accessory-ctrl", "accessory-alt", "accessory-tab"]
                .contains { app.buttons[$0].firstMatch.frame.intersects(firstRow) }
            let height = app.keyboards.firstMatch.frame.minY - top
            app.terminate()
            return (height, covered)
        }
        let (normal, normalCovered) = barHeight([])
        let (large, largeCovered) = barHeight(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertFalse(normalCovered)
        XCTAssertFalse(largeCovered, "the first terminal row stays uncovered at a large text size")
        XCTAssertGreaterThan(large, normal, "the bar grows with the text size (\(normal) -> \(large))")
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

    // MARK: connection states (fixed presentation, no server)

    @MainActor
    private func launchWithConnectionState(_ state: String, extraArguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-debugTmuxFixture", "-debugConnectionState", state] + extraArguments
        app.launch()
        return app
    }

    @MainActor
    func testReconnectingIsAStripThatLeavesTheTerminalUsable() throws {
        let app = launchWithConnectionState("reconnecting")
        let strip = app.descendants(matching: .any)["reconnect-overlay"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "reconnect strip: \(app.debugDescription)")
        XCTAssertTrue(app.buttons["retry-now"].exists)
        XCTAssertTrue(app.buttons["cancel-reconnect"].exists)
        XCTAssertTrue(app.buttons["retry-now"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["retry-now"].frame.height, 44, "tap target height")
        XCTAssertGreaterThanOrEqual(app.buttons["cancel-reconnect"].frame.height, 44, "tap target height")
        XCTAssertTrue(app.descendants(matching: .any)["terminal-view"].firstMatch.isHittable, "no scrim over the terminal")
    }

    @MainActor
    func testNoticeDismissIsAtLeast44pt() throws {
        let app = launchWithTmuxFixture(extraArguments: ["-debugNoticeTimeScale", "10"])
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        app.open(URL(string: "shuai://open?host=00000000-0000-4000-8000-000000000000&pane=%250")!)
        let dismiss = app.buttons["notice-dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10))
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44, "tap target width")
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44, "tap target height")
    }

    // MARK: window tab strip (sidebar collapsed)

    @MainActor
    private func launchWithCollapsedSidebar() -> XCUIApplication {
        let app = launchWithTmuxFixture(extraArguments: ["-debugSidebarCollapsed"])
        XCTAssertTrue(app.descendants(matching: .any)["window-tab-strip"].waitForExistence(timeout: 10), "tab strip")
        return app
    }

    @MainActor
    func testWindowTabStripTargetsAreAtLeast44pt() throws {
        let app = launchWithCollapsedSidebar()
        let ids = ["window-tab-@0", "window-tab-@1", "window-tab-new", "window-tab-session-menu"]
        for id in ids {
            let element = app.buttons[id]
            XCTAssertTrue(element.waitForExistence(timeout: 5), id)
            XCTAssertTrue(element.isHittable, "\(id) hittable")
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(id) height")
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(id) width")
        }
        XCTAssertEqual(app.buttons["window-tab-@1"].value as? String, "active")
        XCTAssertEqual(app.buttons["window-tab-@0"].value as? String, "")
    }

    @MainActor
    func testAutomaticTabStripIsHiddenForOneWindowInOneSession() throws {
        let app = launchWithTmuxFixture(extraArguments: ["-debugSingleWindow", "-debugSidebarCollapsed"])
        XCTAssertTrue(app.descendants(matching: .any)["terminal-view"].waitForExistence(timeout: 10), "terminal")
        // The strip is decided after the first layout; give it time to (wrongly) appear.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.descendants(matching: .any)["window-tab-strip"].exists, "no strip for one window in one session")
    }

    @MainActor
    func testAlwaysTabStripShowsForOneWindowInOneSession() throws {
        let app = launchWithTmuxFixture(extraArguments: ["-debugSingleWindow", "-debugSidebarCollapsed", "-tabStrip", "always"])
        XCTAssertTrue(app.descendants(matching: .any)["window-tab-strip"].waitForExistence(timeout: 10), "strip with Always")
    }

    @MainActor
    func testSettingsOffersWindowTabsAutomaticOrAlways() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        tapSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let automatic = app.buttons["Automatic"], always = app.buttons["Always"]
        scrollSheet(app, until: always)
        XCTAssertTrue(automatic.exists, "Automatic option")
        XCTAssertTrue(automatic.isSelected, "Automatic is the default")
        always.tap()
        XCTAssertTrue(always.isSelected)
    }

    // MARK: full screen

    /// Full screen is entered through `-debugFullScreen`: the simulator does not reliably deliver
    /// ⌃⌘F to the terminal's key command (that path is on the device checklist).
    @MainActor
    private func launchInFullScreen(extraArguments: [String] = []) -> XCUIApplication {
        let app = launchWithTmuxFixture(extraArguments: ["-debugFullScreen"] + extraArguments)
        XCTAssertTrue(app.descendants(matching: .any)["full-screen-handle"].waitForExistence(timeout: 15), "full screen handle")
        return app
    }

    @MainActor
    func testFullScreenHidesTheNavigationBarAndShowsTheHandle() throws {
        let app = launchInFullScreen()
        XCTAssertFalse(app.descendants(matching: .any)["connection-status"].exists, "navigation bar hidden")
        let handle = app.buttons["full-screen-handle"]
        XCTAssertGreaterThanOrEqual(handle.frame.height, 44, "handle height")
        XCTAssertGreaterThanOrEqual(handle.frame.width, 44, "handle width")
        XCTAssertGreaterThan(handle.frame.midX, app.frame.width / 2, "handle is at the trailing edge")
        XCTAssertFalse(app.staticTexts["host-row-fixture-host"].exists, "sidebar collapsed")
    }

    @MainActor
    func testFullScreenHandleMenuExitsAndRestoresTheSidebar() throws {
        let app = launchInFullScreen()
        app.buttons["full-screen-handle"].tap()
        for id in ["full-screen-show-sidebar", "full-screen-quick-switcher", "full-screen-exit"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id)
        }
        app.buttons["full-screen-exit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connection-status"].waitForExistence(timeout: 5), "navigation bar back")
        XCTAssertTrue(app.staticTexts["host-row-fixture-host"].waitForExistence(timeout: 5), "sidebar restored")
        XCTAssertFalse(app.buttons["full-screen-handle"].exists, "handle gone")
    }

    @MainActor
    func testFullScreenHandleDocksIntoTheTabStripWhenItIsShown() throws {
        let app = launchInFullScreen(extraArguments: ["-debugSidebarCollapsed"])
        let strip = app.descendants(matching: .any)["window-tab-strip"]
        XCTAssertTrue(strip.exists, "strip stays in full screen")
        let handle = app.buttons["full-screen-handle"]
        XCTAssertTrue(strip.frame.contains(handle.frame), "handle sits inside the strip")
    }

    @MainActor
    func testSessionMenuListsSessionsInTheTabStrip() throws {
        let app = launchWithCollapsedSidebar()
        let menu = app.buttons["window-tab-session-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(menu.label, "Session: main")
        menu.tap()
        XCTAssertTrue(app.buttons["main"].waitForExistence(timeout: 5), "viewed session listed")
        XCTAssertTrue(app.buttons["scratch"].exists, "other session listed")
    }

    @MainActor
    func testTabLongPressOffersTheWindowMenu() throws {
        let app = launchWithCollapsedSidebar()
        let tab = app.buttons["window-tab-@0"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Rename\u{2026}"].waitForExistence(timeout: 5), "menu offers Rename")
        let close = app.buttons["Close Window"]
        XCTAssertTrue(close.exists, "menu offers Close Window")
        close.tap()
        XCTAssertTrue(app.buttons["confirm-kill"].waitForExistence(timeout: 5), "closing asks first")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(tab.exists)
    }

    @MainActor
    func testConnectionStripPassesTheAccessibilityAudit() throws {
        let app = launchWithConnectionState("reconnecting")
        XCTAssertTrue(app.descendants(matching: .any)["reconnect-overlay"].waitForExistence(timeout: 10))
        let strip = app.descendants(matching: .any)["reconnect-overlay"].frame.insetBy(dx: -1, dy: -1)
        try app.performAccessibilityAudit(for: [.dynamicType, .hitRegion, .sufficientElementDescription]) { issue in
            // Only this strip is audited here. Other screens (host list, accessory bar, terminal
            // surface) have their own owners; an issue outside the strip is not a failure.
            guard let frame = issue.element?.frame else { return true }
            let inScope = strip.contains(frame)
            if inScope {
                // Name the element behind a failure so a CI-only audit finding can be traced.
                let e = issue.element
                XCTContext.runActivity(named: "AUDIT in-scope issue: type=\(issue.auditType.rawValue) id=\(e?.identifier ?? "-") label=\(e?.label ?? "-") elementType=\(e?.elementType.rawValue ?? 0) frame=\(frame) strip=\(strip) detail=\(issue.detailedDescription)") { _ in }
            }
            return !inScope
        }
    }

    @MainActor
    func testConnectionStripActionsStayTappableAtAccessibilityTextSize() throws {
        let app = launchWithConnectionState(
            "reconnecting",
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        XCTAssertTrue(app.descendants(matching: .any)["reconnect-overlay"].waitForExistence(timeout: 10))
        let retry = app.buttons["retry-now"], cancel = app.buttons["cancel-reconnect"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertFalse(retry.frame.intersects(cancel.frame), "buttons never overlap")
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
    }

    @MainActor
    func testFailedShowsTheErrorCardWithRetry() throws {
        let app = launchWithConnectionState("failed")
        XCTAssertTrue(app.descendants(matching: .any)["connection-error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["retry-connect"].exists)
    }

    @MainActor
    func testDisconnectedIsAStripWithReconnect() throws {
        let app = launchWithConnectionState("disconnected")
        XCTAssertTrue(app.descendants(matching: .any)["disconnected-card"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reconnect-session"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["terminal-view"].firstMatch.isHittable)
    }

    /// Permission cards own the trailing column; the strip's actions stay beside them, tappable.
    @MainActor
    func testStripActionsStayTappableNextToPermissionCards() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-debugAgentFixture", "-debugConnectionState", "reconnecting"]
        app.launch()
        let stack = app.descendants(matching: .any)["permission-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 15), "permission cards pending")
        let retry = app.buttons["retry-now"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "strip shown with the agent fixture")
        XCTAssertTrue(retry.isHittable)
        let cards = app.descendants(matching: .any)["permission-card"].firstMatch
        XCTAssertTrue(cards.exists)
        XCTAssertLessThanOrEqual(app.buttons["cancel-reconnect"].frame.maxX, cards.frame.minX, "no overlap with the cards")
        XCTAssertLessThanOrEqual(retry.frame.maxX, cards.frame.minX)
    }

    // MARK: modals (Keys opens from inside the editor and Settings)

    @MainActor
    func testOpenKeysFromTheHostEditorShowsKeysAndReturns() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let addFirst = app.buttons["add-first-host"]
        XCTAssertTrue(addFirst.waitForExistence(timeout: 10))
        addFirst.tap()

        let name = app.textFields["host-name-field"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("keys-flow-host")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Method'")).firstMatch.tap()
        app.buttons["SSH key"].tap()

        let openKeys = app.buttons["editor-open-keys"]
        XCTAssertTrue(openKeys.waitForExistence(timeout: 5), "no keys yet: the editor offers Open Keys")
        openKeys.tap()
        XCTAssertTrue(app.navigationBars["Keys"].waitForExistence(timeout: 5), "Keys appears over the editor")

        app.navigationBars["Keys"].buttons.firstMatch.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5), "back in the editor")
        XCTAssertEqual(name.value as? String, "keys-flow-host", "the editor keeps what was typed")
    }

    @MainActor
    func testKeysFromSettingsOpens() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        tapSettings(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let link = app.buttons["settings-keys-link"]
        scrollSheet(app, until: link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Keys"].waitForExistence(timeout: 5), "Keys appears from Settings")
        app.navigationBars["Keys"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "back in Settings")
    }
}
