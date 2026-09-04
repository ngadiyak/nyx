import Testing
@testable import NyxCore

private func enc(_ button: MouseButton, _ action: MouseAction, _ col: Int, _ row: Int,
                 _ mods: KeyModifiers = [], mode: MouseMode = .normal, sgr: Bool = true) -> String? {
    MouseEncoder.encode(MouseEvent(button: button, action: action, col: col, row: row, modifiers: mods),
                        mode: mode, sgr: sgr).map { String(decoding: $0, as: UTF8.self) }
}
private let ESC = "\u{1B}"

@Test func mouseOffReportsNothing() {
    #expect(enc(.left, .press, 0, 0, mode: .none) == nil)
}

@Test func sgrPressAndRelease() {
    #expect(enc(.left, .press, 3, 5) == ESC + "[<0;4;6M")
    #expect(enc(.left, .release, 3, 5) == ESC + "[<0;4;6m")
    #expect(enc(.right, .press, 0, 0) == ESC + "[<2;1;1M")
    #expect(enc(.middle, .press, 0, 0) == ESC + "[<1;1;1M")
}

@Test func sgrModifiersAddTheirBits() {
    #expect(enc(.left, .press, 0, 0, [.shift]) == ESC + "[<4;1;1M")
    #expect(enc(.left, .press, 0, 0, [.alt]) == ESC + "[<8;1;1M")
    #expect(enc(.left, .press, 0, 0, [.ctrl]) == ESC + "[<16;1;1M")
    #expect(enc(.left, .press, 0, 0, [.shift, .ctrl]) == ESC + "[<20;1;1M")
}

@Test func wheelReportsAsButtons64And65() {
    #expect(enc(.wheelUp, .press, 2, 2) == ESC + "[<64;3;3M")
    #expect(enc(.wheelDown, .press, 2, 2) == ESC + "[<65;3;3M")
}

@Test func dragAddsTheMotionBit() {
    #expect(enc(.left, .drag, 1, 1, mode: .button) == ESC + "[<32;2;2M")
    #expect(enc(.right, .drag, 1, 1, mode: .button) == ESC + "[<34;2;2M")
}

@Test func bareMotionOnlyInAnyEventMode() {
    #expect(enc(.left, .move, 1, 1, mode: .button) == nil)
    #expect(enc(.left, .move, 1, 1, mode: .normal) == nil)
    #expect(enc(.left, .move, 1, 1, mode: .any) == ESC + "[<35;2;2M")
}

@Test func dragOnlyInButtonAndAnyModes() {
    #expect(enc(.left, .drag, 1, 1, mode: .normal) == nil)
    #expect(enc(.left, .drag, 1, 1, mode: .x10) == nil)
    #expect(enc(.left, .drag, 1, 1, mode: .any) == ESC + "[<32;2;2M")
}

@Test func x10ModeIsPressOnlyAndIgnoresModifiers() {
    #expect(enc(.left, .press, 1, 1, [.ctrl], mode: .x10, sgr: false) == ESC + "[M\u{20}\u{22}\u{22}")
    #expect(enc(.left, .release, 1, 1, mode: .x10, sgr: false) == nil)
}

@Test func legacyEncodingOffsetsBy32() {
    #expect(enc(.left, .press, 0, 0, sgr: false) == ESC + "[M\u{20}\u{21}\u{21}")
    #expect(enc(.left, .press, 3, 5, sgr: false) == ESC + "[M\u{20}\u{24}\u{26}")
}

@Test func legacyReleaseReportsButtonThree() {
    #expect(enc(.left, .release, 0, 0, sgr: false) == ESC + "[M\u{23}\u{21}\u{21}")
    #expect(enc(.right, .release, 0, 0, sgr: false) == ESC + "[M\u{23}\u{21}\u{21}")
}

@Test func legacyEncodingRefusesCoordinatesItCannotRepresent() {
    #expect(enc(.left, .press, 222, 0, sgr: false) != nil)
    #expect(enc(.left, .press, 223, 0, sgr: false) == nil)
    #expect(enc(.left, .press, 0, 223, sgr: false) == nil)
    #expect(enc(.left, .press, 223, 0, sgr: true) == ESC + "[<0;224;1M")
}

@Test func negativeCoordinatesAreRefused() {
    #expect(enc(.left, .press, -1, 0) == nil)
    #expect(enc(.left, .press, 0, -1) == nil)
}
