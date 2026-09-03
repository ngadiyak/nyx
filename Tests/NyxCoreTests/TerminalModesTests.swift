import Testing
@testable import NyxCore

private let ESC = "\u{1B}"

@Test func sgrBasicAttributes() {
    let t = makeTerminal().run(ESC + "[1;3;4;7;9;31;42mX")
    let c = t.cell(0, 0)
    #expect(c.attrs.contains(.bold) && c.attrs.contains(.italic) && c.attrs.contains(.inverse) && c.attrs.contains(.strike))
    #expect(c.underline == .single)
    #expect(c.fg == .indexed(1))
    #expect(c.bg == .indexed(2))
    t.run(ESC + "[0mY")
    #expect(t.cell(1, 0) == { var e = Cell(); e.content = 0x59; return e }())
}

@Test func sgrResetSubsets() {
    let t = makeTerminal().run(ESC + "[1;2;4;5;8m" + ESC + "[22;24;25;28mX")
    let c = t.cell(0, 0)
    #expect(c.attrs == [])
    #expect(c.underline == .none)
}

@Test func sgrExtendedColors() {
    let t = makeTerminal().run(ESC + "[38;2;10;20;30m" + ESC + "[48;5;100mA")
    #expect(t.cell(0, 0).fg == .rgb(10, 20, 30))
    #expect(t.cell(0, 0).bg == .indexed(100))
    t.run(ESC + "[38:5:7m" + ESC + "[48:2::1:2:3m" + ESC + "[58:2:4:5:6mB")
    #expect(t.cell(1, 0).fg == .indexed(7))
    #expect(t.cell(1, 0).bg == .rgb(1, 2, 3))
    #expect(t.cell(1, 0).ul == .rgb(4, 5, 6))
    t.run(ESC + "[39;49;59mC")
    #expect(t.cell(2, 0).fg == .default && t.cell(2, 0).bg == .default && t.cell(2, 0).ul == .default)
}

@Test func sgrBrightAndUnderlineStyles() {
    let t = makeTerminal().run(ESC + "[91;104mA" + ESC + "[4:3mB" + ESC + "[21mC" + ESC + "[4:0mD")
    #expect(t.cell(0, 0).fg == .indexed(9) && t.cell(0, 0).bg == .indexed(12))
    #expect(t.cell(1, 0).underline == .curly)
    #expect(t.cell(2, 0).underline == .double)
    #expect(t.cell(3, 0).underline == .none)
}

@Test func sgrEmptyIsReset() {
    let t = makeTerminal().run(ESC + "[1m" + ESC + "[mX")
    #expect(t.cell(0, 0).attrs == [])
}

@Test func privateModesToggle() {
    let t = makeTerminal().run(ESC + "[?1h" + ESC + "[?7l" + ESC + "[?25l" + ESC + "[?1002h" + ESC + "[?1006h" + ESC + "[?2004h" + ESC + "[?1004h" + ESC + "[?2026h")
    #expect(t.modes.cursorKeysApp && !t.modes.autoWrap && !t.modes.showCursor)
    #expect(t.modes.mouse == .button && t.modes.mouseSGR && t.modes.bracketedPaste && t.modes.focusEvents && t.modes.syncOutput)
    t.run(ESC + "[?1l" + ESC + "[?7h" + ESC + "[?25h" + ESC + "[?1002l")
    #expect(!t.modes.cursorKeysApp && t.modes.autoWrap && t.modes.showCursor && t.modes.mouse == .none)
}

@Test func ansiModesToggle() {
    let t = makeTerminal().run(ESC + "[4h" + ESC + "[20h")
    #expect(t.modes.insertMode && t.modes.lineFeedNewLine)
    t.run("a\nb")
    #expect(t.line(1) == "b")
}

@Test func autoWrapOffOverwritesLastColumn() {
    let t = makeTerminal(cols: 3).run(ESC + "[?7l" + "abcdef")
    #expect(t.text() == ["abf", "", ""])
}

@Test func originModeConfinesCursor() {
    let t = makeTerminal(rows: 5).run(ESC + "[2;4r" + ESC + "[?6h" + ESC + "[Hx")
    #expect(t.cell(0, 1).scalar == "x")
    t.run(ESC + "[9;1Hy")
    #expect(t.cell(0, 3).scalar == "y")
    t.run(ESC + "[6n")
    #expect(t.responseText == ESC + "[3;2R")
}

@Test func alternateScreen1049SavesAndRestores() {
    let t = makeTerminal().run("primary" + ESC + "[?1049h")
    #expect(t.modes.altScreen)
    #expect(t.text() == ["", "", ""])
    t.run("alt")
    #expect(t.line(0) == "       alt")
    #expect(t.cur == (9, 0))
    t.run(ESC + "[?1049l")
    #expect(!t.modes.altScreen)
    #expect(t.line(0) == "primary")
    #expect(t.cur == (7, 0))
}

@Test func alternateScreenHasNoScrollback() {
    let t = makeTerminal(rows: 2).run(ESC + "[?1049h" + "a\r\nb\r\nc")
    #expect(t.scrollback.count == 0)
}

@Test func mode1047And1048() {
    let t = makeTerminal().run("p" + ESC + "[?1048h" + ESC + "[?1047h" + "x" + ESC + "[?1047l" + ESC + "[?1048l")
    #expect(t.line(0) == "p")
    #expect(t.cur == (1, 0))
}

@Test func saveRestoreCursorWithAttributes() {
    let t = makeTerminal().run(ESC + "[2;2H" + ESC + "[1m" + ESC + "7" + ESC + "[H" + ESC + "[0m" + ESC + "8X")
    #expect(t.cell(1, 1).attrs.contains(.bold))
}

@Test func deviceAttributesAndStatus() {
    let t = makeTerminal().run(ESC + "[c")
    #expect(t.responseText == ESC + "[?62;22c")
    t.responses = []
    t.run(ESC + "[>c")
    #expect(t.responseText == ESC + "[>1;10;0c")
    t.responses = []
    t.run(ESC + "[5n")
    #expect(t.responseText == ESC + "[0n")
    t.responses = []
    t.run(ESC + "[2;3H" + ESC + "[6n")
    #expect(t.responseText == ESC + "[2;3R")
}

@Test func requestModeReports() {
    let t = makeTerminal().run(ESC + "[?25$p")
    #expect(t.responseText == ESC + "[?25;1$y")
    t.responses = []
    t.run(ESC + "[?2004$p")
    #expect(t.responseText == ESC + "[?2004;2$y")
    t.responses = []
    t.run(ESC + "[?9999$p")
    #expect(t.responseText == ESC + "[?9999;0$y")
    t.responses = []
    t.run(ESC + "[4$p")
    #expect(t.responseText == ESC + "[4;2$y")
}

@Test func saveAndRestorePrivateModes() {
    let t = makeTerminal().run(ESC + "[?1s" + ESC + "[?1h" + ESC + "[?1r")
    #expect(!t.modes.cursorKeysApp)
}

@Test func cursorShapeSequence() {
    let t = makeTerminal().run(ESC + "[6 q")
    #expect(t.cursorShape == .bar && !t.modes.cursorBlink)
    t.run(ESC + "[3 q")
    #expect(t.cursorShape == .underline && t.modes.cursorBlink)
    t.run(ESC + "[0 q")
    #expect(t.cursorShape == .block && t.modes.cursorBlink)
}

@Test func windowOpsReportSizes() {
    let t = makeTerminal(cols: 80, rows: 24)
    t.pixelSize = (800, 480)
    t.run(ESC + "[18t" + ESC + "[14t" + ESC + "[16t")
    #expect(t.responseText == ESC + "[8;24;80t" + ESC + "[4;480;800t" + ESC + "[6;20;10t")
}

@Test func xtversionResponds() {
    let t = makeTerminal().run(ESC + "[>q")
    #expect(t.responseText == ESC + "P>|Nyx 0.1.0" + ESC + "\\")
}

@Test func oscTitle() {
    let t = makeTerminal().run(ESC + "]0;My Title\u{07}")
    #expect(t.title == "My Title")
    #expect(t.events == [.titleChanged("My Title")])
    t.run(ESC + "]2;Other" + ESC + "\\")
    #expect(t.title == "Other")
}

@Test func oscCwd() {
    let t = makeTerminal().run(ESC + "]7;file://host/Users/nik/my%20dir\u{07}")
    #expect(t.cwd == "/Users/nik/my dir")
    #expect(t.events == [.cwdChanged("/Users/nik/my dir")])
}

@Test func oscHyperlink() {
    let t = makeTerminal().run(ESC + "]8;;https://example.com\u{07}link" + ESC + "]8;;\u{07}plain")
    #expect(t.cell(0, 0).hyperlink == 1)
    #expect(t.cell(4, 0).hyperlink == 0)
    #expect(t.hyperlinks == ["https://example.com"])
    t.run(ESC + "]8;id=x;https://example.com\u{07}again")
    #expect(t.cell(9, 0).hyperlink == 1)
    #expect(t.hyperlinks.count == 1)
}

@Test func oscClipboardWrite() {
    let t = makeTerminal().run(ESC + "]52;c;aGVsbG8=\u{07}")
    #expect(t.events == [.clipboardWrite("hello")])
    t.events = []
    t.run(ESC + "]52;c;?\u{07}")
    #expect(t.events.isEmpty)
}

@Test func oscPaletteSetAndQuery() {
    let t = makeTerminal().run(ESC + "]4;1;#ff0000\u{07}")
    #expect(t.palette.colors[1] == RGB(255, 0, 0))
    #expect(t.events == [.colorsChanged])
    t.run(ESC + "]4;1;?\u{07}")
    #expect(t.responseText == ESC + "]4;1;rgb:ffff/0000/0000" + ESC + "\\")
    t.run(ESC + "]104;1\u{07}")
    #expect(t.palette.colors[1] == RGB(hex: 0xCD0000))
}

@Test func oscForegroundBackgroundQueries() {
    let t = makeTerminal().run(ESC + "]10;?\u{07}" + ESC + "]11;?\u{07}")
    #expect(t.responseText == ESC + "]10;rgb:e5e5/e5e5/e5e5" + ESC + "\\" + ESC + "]11;rgb:0000/0000/0000" + ESC + "\\")
    t.run(ESC + "]11;#102030\u{07}")
    #expect(t.palette.background == RGB(0x10, 0x20, 0x30))
    t.run(ESC + "]111\u{07}")
    #expect(t.palette.background == RGB(0, 0, 0))
}

@Test func oscNotifications() {
    let t = makeTerminal().run(ESC + "]9;done\u{07}" + ESC + "]777;notify;Title;Body;more\u{07}")
    #expect(t.events == [.notification(title: "", body: "done"), .notification(title: "Title", body: "Body;more")])
}

@Test func oscPromptMarks() {
    let t = makeTerminal().run(ESC + "]133;A\u{07}$ " + ESC + "]133;B\u{07}ls\r\n" + ESC + "]133;C\u{07}out\r\n" + ESC + "]133;D;0\u{07}")
    #expect(t.screen.rows[0].promptMark == 2)   // B overwrote A on the same row
    #expect(t.screen.rows[1].promptMark == 3)
    #expect(t.screen.rows[2].promptMark == 4)
}

@Test func decrqssReportsSgrAndMargins() {
    let t = makeTerminal(rows: 10).run(ESC + "[1;31m" + ESC + "[2;5r" + ESC + "P$qm" + ESC + "\\" + ESC + "P$qr" + ESC + "\\" + ESC + "P$qz" + ESC + "\\")
    #expect(t.responseText == ESC + "P1$r0;1;31m" + ESC + "\\" + ESC + "P1$r2;5r" + ESC + "\\" + ESC + "P0$r" + ESC + "\\")
}

@Test func fullResetRestoresDefaults() {
    let t = makeTerminal().run(ESC + "[?1049h" + ESC + "[1m" + ESC + "[?25l" + "x" + ESC + "c")
    #expect(!t.modes.altScreen && t.modes.showCursor && t.pen == Pen())
    #expect(t.text() == ["", "", ""])
}

@Test func mouseModeSwitchesAreExclusive() {
    let t = makeTerminal().run(ESC + "[?1000h" + ESC + "[?1003h")
    #expect(t.modes.mouse == .any)
    t.run(ESC + "[?1003l")
    #expect(t.modes.mouse == .none)
}

@Test func sgrParameterOverflowDropsTailInsteadOfResettingPen() {
    // 16 parameters of 4 sub-values fill the value cap exactly; the next parameter overflows it.
    // Admitting that parameter empty would make it read as SGR 0 and reset the pen, and admitting
    // it half-parsed would pick the wrong slots out of a colour parameter. It must be dropped.
    let full = Array(repeating: "1:2:3:4", count: 16).joined(separator: ";")   // code 1 = bold
    let t = makeTerminal().run(ESC + "[3m" + ESC + "[" + full + ";7m")
    #expect(t.pen.attrs.contains(.italic))     // pen survives: no phantom SGR 0
    #expect(t.pen.attrs.contains(.bold))       // the fully parsed prefix still applies
    #expect(!t.pen.attrs.contains(.inverse))   // the overflowing parameter is dropped, not applied
}
