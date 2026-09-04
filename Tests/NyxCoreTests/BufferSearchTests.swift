import Testing
@testable import NyxCore

private func buffer() -> Terminal {
    makeTerminal(cols: 30, rows: 6, scrollback: 100)
        .run("alpha beta\r\ngamma alpha\r\nALPHA delta\r\nnothing here\r\nalpha alpha")
}

private func pos(_ r: Int, _ c: Int) -> AbsolutePosition { AbsolutePosition(row: r, col: c) }

// MARK: - Finding

@Test func aSearchFindsEveryOccurrenceInOrder() {
    var s = BufferSearch()
    s.search("alpha", in: buffer())
    #expect(s.matches.map(\.row) == [0, 1, 2, 4, 4])
    #expect(s.matches[0].columns == 0..<5)
    #expect(s.matches[1].columns == 6..<11)
}

/// Case-insensitive until the user types a capital, which is what every editor settled on: it does
/// what you meant without a switch to find first.
@Test func aLowercaseQueryMatchesRegardlessOfCase() {
    var s = BufferSearch()
    s.search("alpha", in: buffer())
    #expect(s.matches.contains { $0.row == 2 })   // the ALPHA line
}

@Test func aQueryWithACapitalBecomesCaseSensitive() {
    var s = BufferSearch()
    s.search("ALPHA", in: buffer())
    #expect(s.matches.map(\.row) == [2])
}

@Test func anEmptyQueryMatchesNothingRatherThanEverything() {
    var s = BufferSearch()
    s.search("alpha", in: buffer())
    s.search("", in: buffer())
    #expect(s.matches.isEmpty)
}

@Test func aQueryWithNoHitsFindsNothing() {
    var s = BufferSearch()
    s.search("zebra", in: buffer())
    #expect(s.isEmpty)
    #expect(s.next(from: pos(0, 0)) == nil)
    #expect(s.previous(from: pos(0, 0)) == nil)
}

/// Two matches must not share cells, or the highlight paints the same text twice and stepping
/// through gets stuck on it.
@Test func overlappingOccurrencesAreCountedOnce() {
    var s = BufferSearch()
    s.search("aa", in: makeTerminal(cols: 20, rows: 3).run("aaaa"))
    #expect(s.matches.count == 2)
    #expect(s.matches[0].columns == 0..<2)
    #expect(s.matches[1].columns == 2..<4)
}

@Test func aSearchReachesIntoTheScrollback() {
    let t = makeTerminal(cols: 20, rows: 2, scrollback: 50)
    t.run("needle\r\nfiller one\r\nfiller two\r\nfiller three")
    var s = BufferSearch()
    s.search("needle", in: t)
    #expect(s.matches.count == 1)
    #expect(s.matches[0].row == 0)      // scrolled off the screen, still found
}

// MARK: - Stepping

@Test func steppingForwardVisitsMatchesInOrderAndWraps() {
    var s = BufferSearch()
    s.search("alpha", in: buffer())
    let first = try! #require(s.next(from: pos(0, 0)))
    #expect(first.row == 1)             // strictly after the caret
    let last = try! #require(s.previous(from: pos(0, 0)))
    #expect(last.row == 4)              // wrapped to the bottom
}

@Test func steppingBackwardWrapsToTheEnd() {
    var s = BufferSearch()
    s.search("alpha", in: buffer())
    let m = try! #require(s.previous(from: pos(5, 0)))
    #expect(m.row == 4)
}

/// Two matches on one row have to be distinguishable by column, or stepping through a line with
/// several hits stops on the first forever.
@Test func steppingDistinguishesMatchesOnTheSameRow() {
    var s = BufferSearch()
    s.search("alpha", in: buffer())
    let second = try! #require(s.next(from: pos(4, 0)))
    #expect(second.row == 4)
    #expect(second.columns.lowerBound == 6)
}

@Test func aMatchConvertsToASelectionCoveringExactlyIt() {
    var s = BufferSearch()
    s.search("beta", in: buffer())
    let selection = s.matches[0].selection
    #expect(buffer().text(in: selection) == "beta")
}

// MARK: - Narrowing

/// Typing extends the query one character at a time, and each extension can only narrow the
/// previous results. The answer has to be identical to a full rescan -- a faster search that
/// disagrees with the slow one is worse than the slow one.
@Test func narrowingGivesTheSameAnswerAsAFullRescan() {
    let t = buffer()
    var incremental = BufferSearch()
    for prefix in ["a", "al", "alp", "alph", "alpha"] {
        incremental.search(prefix, in: t)
    }
    var fresh = BufferSearch()
    fresh.search("alpha", in: t)
    #expect(incremental.matches == fresh.matches)
}

/// Backspacing widens the query, which cannot narrow -- it has to rescan, or matches that were
/// filtered out never come back.
@Test func shorteningTheQueryFindsMatchesAgain() {
    let t = buffer()
    var s = BufferSearch()
    s.search("alpha b", in: t)
    #expect(s.matches.count == 1)
    s.search("alpha", in: t)
    #expect(s.matches.count == 5)
}

@Test func changingCaseSensitivityMidTypingRescans() {
    let t = buffer()
    var s = BufferSearch()
    s.search("alpha", in: t)
    s.search("alphaA", in: t)   // now case-sensitive, and matches nothing
    #expect(s.matches.isEmpty)
    s.search("alpha", in: t)
    #expect(s.matches.count == 5)
}

// MARK: - Staleness

/// Matches point at absolute rows. Clearing the buffer moves every row out from under them, so
/// they have to be recognised as stale rather than highlighting whatever now sits there.
@Test func clearingTheBufferMakesMatchesStale() {
    let t = buffer()
    var s = BufferSearch()
    s.search("alpha", in: t)
    #expect(!s.isStale(t))
    t.feed("\u{1b}[3J")
    #expect(s.isStale(t))
}

/// `ESC[3J` alone drops the scrollback and leaves the screen, so the text a search found is often
/// still there afterwards. Wiping both is what actually moves rows out from under the matches.
@Test func aStaleSearchRescansRatherThanNarrowing() {
    let t = buffer()
    var s = BufferSearch()
    s.search("alp", in: t)
    #expect(!s.matches.isEmpty)
    t.feed("\u{1b}[2J\u{1b}[3J")
    s.search("alph", in: t)
    #expect(s.matches.isEmpty)   // the text is gone; narrowing would have kept stale rows
}
