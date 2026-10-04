import Testing
@testable import ShuaiTerminal

@Suite("AccessoryBarPlacement")
struct AccessoryBarPlacementTests {
    @Test func softwareKeyboardUpAlwaysGetsTheDockedBar() {
        // A hardware keyboard is attached (the simulator always reports one) but the software
        // keyboard is showing: the docked bar must be used.
        #expect(AccessoryBarPlacement.decide(hardwareKeyboard: true, preferFloating: false, softwareKeyboardVisible: true) == .docked)
        #expect(AccessoryBarPlacement.decide(hardwareKeyboard: false, preferFloating: false, softwareKeyboardVisible: true) == .docked)
    }

    @Test func hardwareKeyboardWithoutSoftwareKeyboardFloats() {
        #expect(AccessoryBarPlacement.decide(hardwareKeyboard: true, preferFloating: false, softwareKeyboardVisible: false) == .floating)
    }

    @Test func noHardwareKeyboardIsDocked() {
        #expect(AccessoryBarPlacement.decide(hardwareKeyboard: false, preferFloating: false, softwareKeyboardVisible: false) == .docked)
    }

    @Test func thePreferenceForcesFloating() {
        #expect(AccessoryBarPlacement.decide(hardwareKeyboard: false, preferFloating: true, softwareKeyboardVisible: true) == .floating)
    }

    @Test func onlyATallKeyboardFrameCountsAsTheSoftwareKeyboard() {
        // The docked accessory bar alone (hardware keyboard) and the shortcut bar are short: they must
        // not read as a software keyboard, or showing our own bar would change the decision (a loop).
        #expect(!AccessoryBarPlacement.isSoftwareKeyboard(frameHeight: 0))
        #expect(!AccessoryBarPlacement.isSoftwareKeyboard(frameHeight: 44))
        #expect(!AccessoryBarPlacement.isSoftwareKeyboard(frameHeight: 96))
        #expect(AccessoryBarPlacement.isSoftwareKeyboard(frameHeight: 300))
        #expect(AccessoryBarPlacement.isSoftwareKeyboard(frameHeight: 420))
    }
}
