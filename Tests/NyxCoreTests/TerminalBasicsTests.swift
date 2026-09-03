import Testing
@testable import NyxCore

private let ESC = "\u{1B}"

@Test func printsText() {
    let t = makeTerminal().run("hello")
    #expect(t.line(0) == "hello")
    #expect(t.cur == (5, 0))
}

@Test func autoWrapsAndMarksRow() {
    let t = makeTerminal(cols: 5).run("abcdefg")
    #expect(t.text() == ["abcde", "fg", ""])
    #expect(t.screen.rows[0].wrapped)
    #expect(!t.screen.rows[1].wrapped)
}

@Test func pendingWrapClearedByCursorMoves() {
    let t = makeTerminal(cols: 5).run("abcde")
    #expect(t.cur == (4, 0))
    #expect(t.screen.pendingWrap)
    t.run("\nx")
    #expect(t.line(1) == "    x")   // LF keeps column 4, clears the wrap flag
    let u = makeTerminal(cols: 5).run("abcde\r\nx")
    #expect(u.line(1) == "x")
}

@Test func lineFeedAtBottomScrollsIntoScrollback() {
    let t = makeTerminal(rows: 2).run("a\r\nb\r\nc")
    #expect(t.text() == ["b", "c"])
    #expect(t.scrollback.count == 1)
    #expect(t.scrollbackLine(0) == "a")
}

@Test func cursorPositioning() {
    let t = makeTerminal().run(ESC + "[2;3Hx")
    #expect(t.cell(2, 1).scalar == "x")
    t.run(ESC + "[H")
    #expect(t.cur == (0, 0))
    t.run(ESC + "[99;99H")
    #expect(t.cur == (9, 2))
}

@Test func relativeCursorMovesClamp() {
    let t = makeTerminal().run(ESC + "[5C")
    #expect(t.cur == (5, 0))
    t.run(ESC + "[2B" + ESC + "[3D")
    #expect(t.cur == (2, 2))
    t.run(ESC + "[9A" + ESC + "[9D")
    #expect(t.cur == (0, 0))
    t.run(ESC + "[2E")
    #expect(t.cur == (0, 2))
    t.run(ESC + "[5G" + ESC + "[2d")
    #expect(t.cur == (4, 1))
}

@Test func eraseDisplay() {
    let t = makeTerminal(cols: 4).run("aaaa\r\nbbbb\r\ncccc" + ESC + "[2;2H")
    t.run(ESC + "[J")
    #expect(t.text() == ["aaaa", "b", ""])
    let u = makeTerminal(cols: 4).run("aaaa\r\nbbbb\r\ncccc" + ESC + "[2;2H")
    u.run(ESC + "[1J")
    #expect(u.text() == ["", "  bb", "cccc"])
    u.run(ESC + "[2J")
    #expect(u.text() == ["", "", ""])
}

@Test func eraseDisplay3ClearsScrollback() {
    let t = makeTerminal(rows: 1).run("a\r\nb" + ESC + "[3J")
    #expect(t.scrollback.count == 0)
}

@Test func eraseLine() {
    let t = makeTerminal(cols: 5).run("abcde" + ESC + "[3G")
    t.run(ESC + "[K")
    #expect(t.line(0) == "ab")
    let u = makeTerminal(cols: 5).run("abcde" + ESC + "[3G" + ESC + "[1K")
    #expect(u.line(0) == "   de")
    u.run(ESC + "[2K")
    #expect(u.line(0) == "")
}

@Test func eraseUsesPenBackground() {
    let t = makeTerminal(cols: 3).run(ESC + "[44m" + ESC + "[2J")
    #expect(t.cell(2, 2).bg == .indexed(4))
    #expect(t.cell(2, 2).content == 0)
}

@Test func insertAndDeleteChars() {
    let t = makeTerminal(cols: 5).run("abcde" + ESC + "[2G" + ESC + "[2@")
    #expect(t.line(0) == "a  bc")
    t.run(ESC + "[2P")
    #expect(t.line(0) == "abc")
    t.run(ESC + "[H" + ESC + "[2X")
    #expect(t.line(0) == "  c")
}

@Test func insertAndDeleteLines() {
    let t = makeTerminal(cols: 1, rows: 4).run("a\r\nb\r\nc\r\nd" + ESC + "[2;1H" + ESC + "[L")
    #expect(t.text() == ["a", "", "b", "c"])
    t.run(ESC + "[2M")
    #expect(t.text() == ["a", "c", "", ""])
}

@Test func scrollRegionKeepsLinesOutside() {
    let t = makeTerminal(cols: 1, rows: 4).run("a\r\nb\r\nc\r\nd")
    t.run(ESC + "[2;3r")           // region rows 2-3, cursor homes
    #expect(t.cur == (0, 0))
    t.run(ESC + "[3;1H\n")         // LF at bottom of region scrolls only the region
    #expect(t.text() == ["a", "c", "", "d"])
    #expect(t.scrollback.count == 0)
}

@Test func scrollRegionFromTopFeedsScrollback() {
    let t = makeTerminal(cols: 1, rows: 3).run(ESC + "[1;2r" + "a\r\nb\r\nc")
    #expect(t.text() == ["b", "c", ""])
    #expect(t.scrollback.count == 1)
    #expect(t.scrollbackLine(0) == "a")
}

@Test func scrollUpAndDownCommands() {
    let t = makeTerminal(cols: 1, rows: 3).run("a\r\nb\r\nc")
    t.run(ESC + "[S")
    #expect(t.text() == ["b", "c", ""])
    t.run(ESC + "[T")
    #expect(t.text() == ["", "b", "c"])
}

@Test func tabsAndTabStops() {
    let t = makeTerminal(cols: 20).run("\tx")
    #expect(t.cur == (9, 0))
    t.run("\t")
    #expect(t.cur == (16, 0))
    t.run("\t")
    #expect(t.cur == (19, 0))
    t.run(ESC + "[H" + ESC + "[5G" + ESC + "H" + ESC + "[H\t")
    #expect(t.cur == (4, 0))
    t.run(ESC + "[3g\r\t")
    #expect(t.cur == (19, 0))
    t.run(ESC + "[Z")
    #expect(t.cur == (0, 0))
}

@Test func backspaceAndCarriageReturn() {
    let t = makeTerminal().run("abc\u{08}x")
    #expect(t.line(0) == "abx")
    t.run("\rz")
    #expect(t.line(0) == "zbx")
}

@Test func repeatLastCharacter() {
    let t = makeTerminal().run("a" + ESC + "[3b")
    #expect(t.line(0) == "aaaa")
}

@Test func reverseIndexAtTopScrollsDown() {
    let t = makeTerminal(cols: 1, rows: 3).run("a\r\nb" + ESC + "[H" + ESC + "M")
    #expect(t.text() == ["", "a", "b"])
}

@Test func nextLineAndIndex() {
    let t = makeTerminal().run("ab" + ESC + "E" + "c" + ESC + "D" + "d")
    #expect(t.text() == ["ab", "c", " d"])
}

@Test func decAlignmentPattern() {
    let t = makeTerminal(cols: 3, rows: 2).run(ESC + "#8")
    #expect(t.text() == ["EEE", "EEE"])
}

@Test func wideCharacterOccupiesTwoCells() {
    let t = makeTerminal().run("漢a")
    #expect(t.cell(0, 0).attrs.contains(.wide))
    #expect(t.cell(1, 0).attrs.contains(.wideSpacer))
    #expect(t.cell(2, 0).scalar == "a")
    #expect(t.line(0) == "漢a")
    #expect(t.cur == (3, 0))
}

@Test func wideCharacterWrapsWhenItDoesNotFit() {
    let t = makeTerminal(cols: 4).run("abc漢")
    #expect(t.text() == ["abc", "漢", ""])
}

@Test func overwritingHalfOfWideClearsIt() {
    let t = makeTerminal().run("漢" + ESC + "[2Gb")
    #expect(t.line(0) == " b")
    #expect(!t.cell(0, 0).attrs.contains(.wide))
}

@Test func combiningMarkAttachesToPreviousCell() {
    let t = makeTerminal().run("e\u{0301}x")
    #expect(t.cur == (2, 0))
    #expect(t.cell(0, 0).graphemeIndex != nil)
    #expect(t.line(0) == "e\u{0301}x")
}

@Test func variationSelectorMakesEmojiWide() {
    let t = makeTerminal().run("\u{2764}\u{FE0F}x")
    #expect(t.cell(0, 0).attrs.contains(.wide))
    #expect(t.cell(2, 0).scalar == "x")
}

@Test func decSpecialGraphicsCharset() {
    let t = makeTerminal().run(ESC + "(0lqk" + ESC + "(Bx")
    #expect(t.line(0) == "┌─┐x")
    let u = makeTerminal().run(ESC + ")0\u{0E}q\u{0F}q")
    #expect(u.line(0) == "─q")
}

@Test func insertModeShiftsExistingText() {
    let t = makeTerminal(cols: 5).run("abc" + ESC + "[H" + ESC + "[4hX" + ESC + "[4l")
    #expect(t.line(0) == "Xabc")
}

@Test func bellProducesEvent() {
    let t = makeTerminal().run("\u{07}")
    #expect(t.events == [.bell])
}

@Test func generationChangesOnOutput() {
    let t = makeTerminal()
    let g = t.generation
    t.run("a")
    #expect(t.generation != g)
}
