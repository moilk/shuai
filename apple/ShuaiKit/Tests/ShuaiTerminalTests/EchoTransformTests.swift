import Foundation
import Testing
@testable import ShuaiTerminal

@Suite("EchoTransform")
struct EchoTransformTests {
    private func echo(_ bytes: [UInt8]) -> String {
        String(decoding: EchoTransform.transform(Data(bytes)), as: UTF8.self)
    }

    @Test func printableAndUnicodePassThrough() {
        #expect(echo(Array("abc 你好".utf8)) == "abc 你好")
    }

    @Test func enterBecomesCRLF() {
        #expect(echo([0x0D]) == "\r\n")
    }

    @Test func backspaceErasesPreviousCell() {
        #expect(echo([0x7F]) == "\u{8} \u{8}")
    }

    @Test func tabPassesThrough() {
        #expect(echo([0x09]) == "\t")
    }

    @Test func controlBytesAreShownAsCaretNotation() {
        #expect(echo([0x03]) == "^C")
        #expect(echo([0x1B]) == "^[")
        #expect(echo([0x1B, 0x5B, 0x41]) == "^[[A")
        #expect(echo([0x00]) == "^@")
    }
}
