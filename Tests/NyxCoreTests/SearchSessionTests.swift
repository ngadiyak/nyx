import Testing
@testable import NyxCore

/// Five rows, `alpha` on rows 0, 1, 2 (uppercase) and twice on row 4.
private func buffer() -> Terminal {
    makeTerminal(cols: 30, rows: 6, scrollback: 100)
        .run("alpha beta\r\ngamma alpha\r\nALPHA delta\r\nnothing here\r\nalpha alpha")
}

@Test func openingOnAQueryStandsOnTheFirstHitFromTheViewport() {
    var s = SearchSession()
    s.update(query: "alpha", in: buffer(), viewportTop: 0)
    #expect(s.current == SearchMatch(row: 0, columns: 0..<5))
    #expect(s.readout == "1 of 5")
}

/// A user who has scrolled back is looking at a particular part of the buffer; the first hit on
/// screen is the one they meant, not the first in a ten-thousand-line scrollback.
@Test func theFirstHitAtOrAfterTheViewportTopWins() {
    var s = SearchSession()
    s.update(query: "alpha", in: buffer(), viewportTop: 2)
    #expect(s.current?.row == 2)
    #expect(s.readout == "3 of 5")
}

/// Typing another character must not throw the user back to the top of the buffer: the hit they
/// were reading is where the next search starts from.
@Test func extendingTheQueryKeepsTheUserWhereTheyWere() {
    let t = buffer()
    var s = SearchSession()
    s.update(query: "alph", in: t, viewportTop: 0)
    s.step(forward: true)
    s.step(forward: true)
    #expect(s.current?.row == 2)
    s.update(query: "alpha", in: t, viewportTop: 0)
    #expect(s.current?.row == 2)
}

@Test func steppingForwardWalksTheHitsAndWrapsAtTheEnd() {
    var s = SearchSession()
    s.update(query: "alpha", in: buffer(), viewportTop: 0)
    #expect(s.step(forward: true)?.row == 1)
    #expect(s.step(forward: true)?.row == 2)
    #expect(s.step(forward: true)?.row == 4)
    #expect(s.step(forward: true)?.columns == 6..<11)
    let wrapped = s.step(forward: true)
    #expect(wrapped == SearchMatch(row: 0, columns: 0..<5))
}

@Test func steppingBackwardsWrapsToTheLastHit() {
    var s = SearchSession()
    s.update(query: "alpha", in: buffer(), viewportTop: 0)
    let last = s.step(forward: false)
    #expect(last == SearchMatch(row: 4, columns: 6..<11))
    #expect(s.readout == "5 of 5")
}

@Test func aQueryThatMatchesNothingSaysSo() {
    var s = SearchSession()
    s.update(query: "zzz", in: buffer(), viewportTop: 0)
    #expect(s.current == nil)
    #expect(s.readout == "no results")
    #expect(s.step(forward: true) == nil)
}

/// A bar that has just opened has nothing to report, and "0 of 0" reads like a failure.
@Test func anEmptyQueryReadsOutNothing() {
    var s = SearchSession()
    s.update(query: "", in: buffer(), viewportTop: 0)
    #expect(s.readout == "")
    #expect(s.current == nil)
}

@Test func clearingDropsTheHitsAndTheCurrentOne() {
    var s = SearchSession()
    s.update(query: "alpha", in: buffer(), viewportTop: 0)
    s.clear()
    #expect(s.current == nil)
    #expect(s.matches.isEmpty)
    #expect(s.query == "")
}

/// Output arriving while the bar is open must not leave the highlights pointing at nothing; the
/// hit the user is standing on survives when the text under it has not moved.
@Test func refreshingAfterOutputKeepsTheCurrentHit() {
    let t = buffer()
    var s = SearchSession()
    s.update(query: "alpha", in: t, viewportTop: 0)
    s.step(forward: true)
    let before = s.current
    t.feed("\r\nalpha again")
    s.refresh(in: t, viewportTop: 0)
    #expect(s.current == before)
    #expect(s.matches.count == 6)
}

@Test func refreshingPastAVanishedHitPicksTheNextOne() {
    let t = buffer()
    var s = SearchSession()
    s.update(query: "delta", in: t, viewportTop: 0)
    #expect(s.current?.row == 2)
    t.feed("\u{1b}[H\u{1b}[2J\u{1b}[3J")   // clear screen and scrollback
    s.refresh(in: t, viewportTop: 0)
    #expect(s.current == nil)
    #expect(s.readout == "no results")
}

@Test func refreshingAnEmptyQueryDoesNothing() {
    var s = SearchSession()
    s.refresh(in: buffer(), viewportTop: 0)
    #expect(s.matches.isEmpty)
    #expect(s.readout == "")
}

// MARK: - Bringing a hit on screen

/// Twenty lines in a six-row terminal: fourteen in the scrollback, the last six on screen.
private func scrolledBuffer() -> Terminal {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    for i in 0..<20 { t.feed("line \(i)\r\n") }
    return t
}

/// Stepping between three hits already on screen must not slide the text under the reader.
@Test func revealingARowAlreadyOnScreenDoesNotScroll() {
    let t = scrolledBuffer()
    let top = t.viewportTopRow
    let moved = t.revealAbsoluteRow(top + 1)
    #expect(!moved)
    #expect(t.viewportTopRow == top)
}

@Test func revealingARowAboveTheViewportScrollsToIt() {
    let t = scrolledBuffer()
    let moved = t.revealAbsoluteRow(0)
    #expect(moved)
    #expect(t.viewportTopRow == 0)
}

@Test func revealingARowBelowTheViewportScrollsBackDown() {
    let t = scrolledBuffer()
    _ = t.revealAbsoluteRow(0)
    let moved = t.revealAbsoluteRow(t.totalRows - 1)
    #expect(moved)
    #expect(t.viewportTopRow > 0)
}
