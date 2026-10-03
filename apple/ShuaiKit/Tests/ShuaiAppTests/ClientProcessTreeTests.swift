import Testing
@testable import ShuaiApp

@Suite struct ClientProcessTreeTests {
    let parents = ClientProcessTree.parse(psOutput: "1 0\n800 1\n900 800\n777 800\n4242 900\n200 900\n100 777\n")

    @Test func parsesPidPpidPairsAndSkipsGarbage() {
        let p = ClientProcessTree.parse(psOutput: "  PID PPID\n 5 1\nwat\n 6 5 extra\n7 6\n")
        #expect(p == [5: 1, 7: 6])
    }

    @Test func keepsTheCandidatesSharingTheDeepestAncestorWithTheControlClient() {
        #expect(ClientProcessTree.closest(to: 4242, among: [100, 200], parents: parents) == [200])
    }

    @Test func tiesKeepEveryCandidate() {
        #expect(Set(ClientProcessTree.closest(to: 4242, among: [200, 100, 300], parents: parents)) == [200])
        let both = ClientProcessTree.parse(psOutput: "1 0\n800 1\n900 800\n4242 900\n200 900\n201 900\n")
        #expect(Set(ClientProcessTree.closest(to: 4242, among: [200, 201], parents: both)) == [200, 201])
    }

    @Test func unknownControlProcessDoesNotNarrowDown() {
        #expect(ClientProcessTree.closest(to: 31337, among: [100, 200], parents: parents) == [100, 200])
    }

    @Test func parentLoopsTerminate() {
        let loop = [1: 2, 2: 1, 3: 1]
        #expect(!ClientProcessTree.closest(to: 3, among: [1, 2], parents: loop).isEmpty)
    }
}
