import Testing
@testable import ShuaiApp

@Suite struct TmuxLaunchTests {
    @Test func attachOrCreateCommandQuotesTheName() {
        #expect(TmuxLaunch.command(sessionName: "shuai") == "tmux new -A -s 'shuai'")
        #expect(TmuxLaunch.command(sessionName: "it's me") == #"tmux new -A -s 'it'\''s me'"#)
        #expect(TmuxLaunch.command(sessionName: "a b; rm -rf /") == "tmux new -A -s 'a b; rm -rf /'")
    }

    @Test func startupCommandRunsOnlyOnCreateAndThenHandsOverToTheShell() {
        let c = TmuxLaunch.command(sessionName: "s", startupCommand: " claude ")
        #expect(c == #"tmux new -A -s 's' 'claude; exec "${SHELL:-/bin/sh}"'"#)
        #expect(TmuxLaunch.command(sessionName: "s", startupCommand: "  ") == "tmux new -A -s 's'")
    }

    @Test func sessionNameValidation() {
        #expect(TmuxLaunch.isValidSessionName("shuai-sim_test 1"))
        for bad in ["", " x", "a:b", "a.b", "a\nb", "x "] {
            #expect(!TmuxLaunch.isValidSessionName(bad), "\(bad.debugDescription)")
        }
    }
}
