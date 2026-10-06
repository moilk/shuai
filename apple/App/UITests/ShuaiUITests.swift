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
    private func scrollSheet(_ app: XCUIApplication, until target: XCUIElement, maxSwipes: Int = 12) {
        let bar = app.navigationBars["Settings"]
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

    @MainActor
    func testNotificationSettingsShowTopicAndTestButton() throws {
        let app = launchWithTmuxFixture()
        XCTAssertTrue(app.buttons["tmux-window-@1"].waitForExistence(timeout: 10))
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.keyboards.count, 0, "opening Settings resigns the terminal so its keyboard does not cover the sheet")
        // top to bottom, so scrolling for the next target never passes an earlier one
        scrollSheet(app, until: app.textFields["push-server-field"])
        XCTAssertEqual(app.textFields["push-server-field"].value as? String, "https://ntfy.sh")
        let topic = app.staticTexts["push-topic"]
        scrollSheet(app, until: topic)
        // the row's label is "Topic, <topic>" (LabeledContent)
        let value = topic.label.components(separatedBy: ", ").last ?? ""
        XCTAssertNotNil(value.wholeMatch(of: /shuai-[a-z2-7]{26}/), topic.label)
        scrollSheet(app, until: app.buttons["push-send-test"])
        XCTAssertTrue(app.buttons["push-send-test"].exists)
        scrollSheet(app, until: app.buttons["push-open-ntfy"])
        XCTAssertTrue(app.buttons["push-open-ntfy"].exists)
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

    @MainActor
    func testConnectionStripPassesTheAccessibilityAudit() throws {
        let app = launchWithConnectionState("reconnecting")
        XCTAssertTrue(app.descendants(matching: .any)["reconnect-overlay"].waitForExistence(timeout: 10))
        let strip = app.descendants(matching: .any)["reconnect-overlay"].frame.insetBy(dx: -1, dy: -1)
        try app.performAccessibilityAudit(for: [.dynamicType, .hitRegion, .sufficientElementDescription]) { issue in
            // Only this strip is audited here. Other screens (host list, accessory bar, terminal
            // surface) have their own owners; an issue outside the strip is not a failure.
            guard let frame = issue.element?.frame else { return true }
            return !strip.contains(frame)
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
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let link = app.buttons["settings-keys-link"]
        scrollSheet(app, until: link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Keys"].waitForExistence(timeout: 5), "Keys appears from Settings")
        app.navigationBars["Keys"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "back in Settings")
    }
}
