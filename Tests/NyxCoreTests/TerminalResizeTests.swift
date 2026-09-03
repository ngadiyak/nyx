import Testing
@testable import NyxCore

private let ESC = "\u{1B}"

@Test func widenRejoinsWrappedLine() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdefghijklmno")
    #expect(t.text() == ["abcdefghij", "klmno", ""])
    t.resize(cols: 20, rows: 3)
    #expect(t.text() == ["abcdefghijklmno", "", ""])
    #expect(!t.screen.rows[0].wrapped)
    #expect(t.cur == (15, 0))
}

@Test func narrowRewrapsAndTracksCursor() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdefghijklmno")
    t.resize(cols: 5, rows: 3)
    #expect(t.text() == ["abcde", "fghij", "klmno"])
    #expect(t.screen.rows[0].wrapped && t.screen.rows[1].wrapped && !t.screen.rows[2].wrapped)
    #expect(t.cur == (4, 2))
    #expect(t.screen.pendingWrap)
    t.run("p")
    #expect(t.text() == ["fghij", "klmno", "p"])
}

@Test func cursorInsideLineFollowsReflow() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdefghijkl" + ESC + "[1;8H")
    t.resize(cols: 5, rows: 3)
    #expect(t.cur == (2, 1))   // 'h' is index 7 -> row 1, col 2
}

@Test func shrinkHeightPushesTopRowsToScrollback() {
    let t = makeTerminal(cols: 5, rows: 5).run("a\r\nb\r\nc\r\nd\r\ne")
    t.resize(cols: 5, rows: 3)
    #expect(t.text() == ["c", "d", "e"])
    #expect(t.scrollback.count == 2)
    #expect(t.scrollbackLine(0) == "a")
    #expect(t.cur == (1, 2))
}

@Test func growHeightPullsRowsBackFromScrollback() {
    let t = makeTerminal(cols: 5, rows: 3).run("a\r\nb\r\nc\r\nd\r\ne")
    #expect(t.scrollback.count == 2)
    t.resize(cols: 5, rows: 5)
    #expect(t.text() == ["a", "b", "c", "d", "e"])
    #expect(t.scrollback.count == 0)
    #expect(t.cur == (1, 4))
}

@Test func blankRowsBelowCursorAreNotPreserved() {
    let t = makeTerminal(cols: 5, rows: 5).run("a\r\nb")
    t.resize(cols: 5, rows: 2)
    #expect(t.text() == ["a", "b"])
    #expect(t.scrollback.count == 0)
}

@Test func wideCharacterMovesWholeToNextRow() {
    let t = makeTerminal(cols: 4, rows: 3).run("ab漢")
    t.resize(cols: 3, rows: 3)
    #expect(t.text() == ["ab", "漢", ""])
    #expect(t.cell(0, 1).attrs.contains(.wide) && t.cell(1, 1).attrs.contains(.wideSpacer))
}

@Test func alternateScreenDoesNotReflow() {
    let t = makeTerminal(cols: 10, rows: 3).run("primary-line-long" + ESC + "[?1049h" + "abcdefghijklmno")
    // Entering the alt screen keeps the primary cursor position (x=7, y=1; see
    // TerminalModesTests.alternateScreen1049SavesAndRestores), so "abcdefghijklmno"
    // is printed starting at column 7 of row 1, not from the origin.
    t.resize(cols: 20, rows: 3)
    #expect(t.text() == ["       abc", "defghijklm", "no"])
    t.run(ESC + "[?1049l")
    #expect(t.line(0) == "primary-line-long")
}

@Test func resizeResetsMarginsAndTabs() {
    let t = makeTerminal(cols: 10, rows: 5).run(ESC + "[2;3r")
    t.resize(cols: 20, rows: 6)
    #expect(t.screen.scrollTop == 0 && t.screen.scrollBottom == 5)
    #expect(t.screen.tabStops.count == 20 && t.screen.tabStops[16])
}

@Test func viewportScrollingShowsScrollback() {
    let t = makeTerminal(cols: 5, rows: 2).run("a\r\nb\r\nc\r\nd")
    #expect(t.scrollback.count == 2)
    #expect(t.viewportRow(0).cells[0].scalar == "c")
    t.scrollViewport(by: 1)
    #expect(t.viewportOffset == 1)
    #expect(t.viewportRow(0).cells[0].scalar == "b")
    #expect(t.viewportRow(1).cells[0].scalar == "c")
    t.scrollViewport(by: 10)
    #expect(t.viewportOffset == 2)
    #expect(t.viewportRow(0).cells[0].scalar == "a")
    t.run("\r\ne")                       // new output keeps the view anchored
    #expect(t.viewportOffset == 3)
    #expect(t.viewportRow(0).cells[0].scalar == "a")
    t.scrollViewportToBottom()
    #expect(t.viewportOffset == 0)
    #expect(t.viewportRow(1).cells[0].scalar == "e")
    t.scrollViewport(by: -5)
    #expect(t.viewportOffset == 0)
}

@Test func resizeClampsViewportOffset() {
    let t = makeTerminal(cols: 5, rows: 2).run("a\r\nb\r\nc\r\nd")
    t.scrollViewport(by: 2)
    t.resize(cols: 5, rows: 4)
    #expect(t.viewportOffset == 0)
    #expect(t.scrollback.count == 0)
}

@Test func promptMarkOnWrappedRowSurvivesReflow() {
    let t = makeTerminal(cols: 5, rows: 3).run("abcdefgh" + "\u{1B}]133;A\u{07}")   // mark lands on the wrapped continuation row
    #expect(t.screen.rows[1].promptMark == 1)
    t.resize(cols: 20, rows: 3)
    #expect(t.screen.rows[0].promptMark == 1)
    t.resize(cols: 5, rows: 3)
    #expect(t.screen.rows[0].promptMark == 1)
}

@Test func noOpResizeKeepsState() {
    let t = makeTerminal(cols: 10, rows: 3).run("abc")
    let g = t.generation
    t.resize(cols: 10, rows: 3)
    #expect(t.generation == g)
}

/// Regression: the split between scrollback and screen used to lower `first` to the cursor row
/// unconditionally, so every row past `first + newRows` was thrown away. With the cursor parked
/// near the top and a width reduction that grows the row count, that silently ate real content.
@Test func reflowKeepsContentBelowACursorParkedAtTheTop() {
    let t = makeTerminal(cols: 20, rows: 5)
    for (i, ch) in ["a", "b", "c", "d", "e"].enumerated() {
        t.run(String(repeating: ch, count: 20))
        if i < 4 { t.run("\r\n") }
    }
    t.run(ESC + "[1;1H")            // cursor parked at the top-left
    t.resize(cols: 10, rows: 5)     // 5 logical lines -> 10 physical rows, only 5 of them visible

    var all: [String] = []
    for i in 0..<t.scrollback.count { all.append(t.scrollbackLine(i)) }
    all += t.text()
    let joined = all.joined()
    for ch in ["a", "b", "c", "d", "e"] {
        #expect(joined.contains(String(repeating: ch, count: 20)), "line of '\(ch)' should survive reflow")
    }
    #expect(t.cur.1 >= 0 && t.cur.1 < t.rows)
}
