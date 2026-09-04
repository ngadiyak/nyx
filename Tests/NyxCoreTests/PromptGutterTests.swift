import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

/// Three commands in a six-row terminal: one that succeeded, one that failed, and the prompt the
/// user is typing at.
///
///     row 0  $ echo one
///     row 1  one
///     row 2  $ false
///     row 3  $ |
private func session() -> Terminal {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "false\r\n" + mark("C") + mark("D", 1))
    t.feed(mark("A") + "$ ")
    return t
}

// MARK: - Marks

@Test func aFinishedCommandIsGreenAndAFailedOneIsRed() {
    let marks = session().gutterMarks(rows: 6)
    #expect(marks[0] == .succeeded)
    #expect(marks[2] == .failed)
}

/// The prompt the user is typing at has not run anything, so there is nothing to say about it yet.
@Test func aPromptWithNoStatusYetIsRunning() {
    let marks = session().gutterMarks(rows: 6)
    #expect(marks[3] == .running)
}

@Test func rowsWithoutAPromptCarryNoMark() {
    let marks = session().gutterMarks(rows: 6)
    #expect(marks[1] == nil)
    #expect(marks[4] == nil)
}

@Test func aBufferWithNoShellIntegrationHasAnEmptyGutter() {
    let t = makeTerminal(cols: 20, rows: 4).run("hello\r\nworld")
    let marks = t.gutterMarks(rows: 4)
    let empty = marks.allSatisfy { $0 == nil }
    #expect(empty)
}

@Test func thereIsOneMarkPerVisibleRowAndNoMore() {
    #expect(session().gutterMarks(rows: 3).count == 3)
    #expect(session().gutterMarks(rows: 0).isEmpty)
}

/// The `D` closing a command lands on the row the *next* prompt occupies, so a prompt on the last
/// visible row still has to find its status below the fold.
@Test func aPromptOnTheLastVisibleRowStillFindsItsStatus() {
    let marks = session().gutterMarks(rows: 3)
    #expect(marks[2] == .failed)
}

/// A fresh prompt must not inherit the failure of the command before it.
@Test func aNewPromptDoesNotInheritTheStatusAboveIt() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed(mark("A") + "$ " + mark("B") + "false\r\n" + mark("C") + mark("D", 1))
    t.feed(mark("A") + "$ ")
    let marks = t.gutterMarks(rows: 4)
    #expect(marks[0] == .failed)
    #expect(marks[1] == .running)
}

/// A shell that emits `D` with no status is saying the command ended, not that it failed -- the
/// same rule `CommandRegion.failed` follows.
@Test func anEndMarkWithNoStatusCountsAsSuccess() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed(mark("A") + "$ " + mark("B") + "x\r\n" + mark("C") + mark("D"))
    t.feed(mark("A") + "$ ")
    #expect(t.gutterMarks(rows: 4)[0] == .succeeded)
}

// MARK: - Geometry

/// The gutter lives inside the pane's own padding, so it costs no columns and never touches a
/// glyph -- which means a pane with no padding gets no gutter rather than one over its text.
@Test func theGutterFitsInsideThePadding() {
    #expect(PromptGutter.width(padding: 8) == PromptGutter.maximumWidth)
    #expect(PromptGutter.width(padding: 5) == 5)
    #expect(PromptGutter.width(padding: 0) == 0)
    #expect(PromptGutter.width(padding: 2) == 0)
}

@Test func aPointMapsToTheRowItIsOver() {
    #expect(PromptGutter.row(atY: 8, cellHeight: 16, padding: 8, rows: 4) == 0)
    #expect(PromptGutter.row(atY: 25, cellHeight: 16, padding: 8, rows: 4) == 1)
}

@Test func aPointInThePaddingOrPastTheLastRowIsOverNothing() {
    #expect(PromptGutter.row(atY: 2, cellHeight: 16, padding: 8, rows: 4) == nil)
    #expect(PromptGutter.row(atY: 400, cellHeight: 16, padding: 8, rows: 4) == nil)
}
