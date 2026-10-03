import Testing
@testable import ShuaiCore

@Test func pingReturnsPong() {
    #expect(ShuaiCore.ping() == "pong")
}

@Test func coreVersionIsNotEmpty() {
    #expect(!ShuaiCore.coreVersion().isEmpty)
}
