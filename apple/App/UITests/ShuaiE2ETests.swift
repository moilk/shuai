import XCTest

/// Real end-to-end phases against a live server. Never runs in CI: every test skips unless
/// `SHUAI_E2E_HOST_FILE` is set (pass it to xcodebuild as `TEST_RUNNER_SHUAI_E2E_HOST_FILE`).
/// The host file is the `-debugHostFile` JSON and must live outside the repo. Phases are separate
/// tests so a driver can inspect the server between them:
///   testE2EInstall, testE2ETypeAndEnter (SHUAI_E2E_TEXT), testE2EPermissionCard (SHUAI_E2E_TEXT,
///   SHUAI_E2E_DECISION=allow|deny, optional SHUAI_E2E_OUT_DIR for a full screenshot),
///   testE2EQuickSwitcher, testE2EUninstall.
final class ShuaiE2ETests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Accessibility identifier of the host row: `host-row-<name>` with `name` from the host file.
    private var hostRowID: String {
        struct HostFile: Decodable { var name: String }
        let url = URL(fileURLWithPath: env["SHUAI_E2E_HOST_FILE"] ?? "")
        let name = (try? JSONDecoder().decode(HostFile.self, from: Data(contentsOf: url)))?.name ?? ""
        return "host-row-\(name)"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(env["SHUAI_E2E_HOST_FILE"] == nil, "SHUAI_E2E_HOST_FILE not set")
    }

    @MainActor
    private func launchConnected() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-debugHostFile", env["SHUAI_E2E_HOST_FILE"]!, "-debugAutoAcceptHostKey", "-debugByteTap"]
        app.launch()
        let terminal = app.descendants(matching: .any)["terminal-view"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 40), "connected and attached to tmux")
        sleep(4)  // let the attach settle before the first keystroke
        return app
    }

    /// Focus the terminal (retrying: the first tap can land before the view is first responder) and type.
    @MainActor
    private func typeIntoTerminal(_ app: XCUIApplication, _ text: String) {
        let terminal = app.descendants(matching: .any)["terminal-view"].firstMatch
        for _ in 0 ..< 6 {
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
            if terminal.value(forKey: "hasKeyboardFocus") as? Bool == true { break }
        }
        app.typeText(text)
        app.typeText("\n")
    }

    @MainActor
    private func openHostMenu(_ app: XCUIApplication, item: String) {
        let row = app.staticTexts.matching(identifier: hostRowID).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(item) in host menu")
        button.tap()
    }

    @MainActor
    func testE2EInstall() throws {
        let app = launchConnected()
        openHostMenu(app, item: "Enable AI integration…")
        let install = app.buttons["agent-install-button"]
        XCTAssertTrue(install.waitForExistence(timeout: 30), "probe + plan shown")
        attach(app, "plan")
        install.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 240), "install finished")
        attach(app, "result")
        done.tap()
        // The row's texts share one identifier; the status line carries the agent version.
        let status = app.staticTexts.matching(identifier: hostRowID)
            .matching(NSPredicate(format: "label MATCHES '.*AI integration [0-9]+\\\\.[0-9]+.*'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20), "host row shows the installed AI integration version")
    }

    @MainActor
    func testE2ETypeAndEnter() throws {
        let app = launchConnected()
        typeIntoTerminal(app, env["SHUAI_E2E_TEXT"] ?? "")
        sleep(3)
    }

    @MainActor
    func testE2EPermissionCard() throws {
        let app = launchConnected()
        typeIntoTerminal(app, env["SHUAI_E2E_TEXT"] ?? "")
        let card = app.descendants(matching: .any)["permission-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 90), "permission card appears")
        // The notification opt-in is a deferred banner (not an alert): it must never cover the card.
        XCTAssertFalse(app.descendants(matching: .any)["notify-optin"].firstMatch.exists, "opt-in waits for the card")
        sleep(1)
        let shot = app.screenshot()
        if let dir = env["SHUAI_E2E_OUT_DIR"] {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("card-full.png"))
        }
        let allow = (env["SHUAI_E2E_DECISION"] ?? "allow") == "allow"
        app.buttons[allow ? "permission-allow" : "permission-deny"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 30), "card gone after answering")
        sleep(5)
    }

    @MainActor
    func testE2EQuickSwitcher() throws {
        let app = launchConnected()
        app.descendants(matching: .any)["terminal-view"].firstMatch.tap()
        app.typeKey("k", modifierFlags: .command)
        var field = app.textFields["quick-switcher-field"]
        if !field.waitForExistence(timeout: 4) {
            app.buttons["quick-switcher-button"].tap()
            field = app.textFields["quick-switcher-field"]
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "quick switcher opens")
        XCTAssertTrue(app.buttons["quick-switcher-row-0"].waitForExistence(timeout: 5))
        attach(app, "switcher")
    }

    @MainActor
    func testE2EUninstall() throws {
        let app = launchConnected()
        openHostMenu(app, item: "Remove AI integration…")
        let remove = app.buttons["agent-remove-button"]
        XCTAssertTrue(remove.waitForExistence(timeout: 30))
        remove.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 120), "uninstall finished")
        attach(app, "uninstall-result")
        done.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
