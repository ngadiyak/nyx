import Testing
@testable import NyxCore

private func best(_ query: String, _ candidates: [String]) -> String? {
    FuzzySearch.rank(query, candidates) { $0 }.first?.item
}

// MARK: - Matching at all

@Test func aQueryMustBeASubsequenceOfTheCandidate() {
    #expect(FuzzySearch.match("nt", "New Tab") != nil)
    #expect(FuzzySearch.match("tn", "New Tab") == nil)   // wrong order
    #expect(FuzzySearch.match("xyz", "New Tab") == nil)
}

@Test func matchingIgnoresCase() {
    #expect(FuzzySearch.match("NEWTAB", "New Tab") != nil)
    #expect(FuzzySearch.match("newtab", "New Tab") != nil)
}

/// An empty field means "show me the list", not "show me nothing".
@Test func anEmptyQueryMatchesEverything() {
    let m = try! #require(FuzzySearch.match("", "anything"))
    #expect(m.score == 0)
    #expect(FuzzySearch.rank("", ["a", "b", "c"]) { $0 }.count == 3)
}

@Test func aQueryLongerThanTheCandidateCannotMatch() {
    #expect(FuzzySearch.match("aaaaaaa", "aa") == nil)
}

@Test func theMatchedPositionsAreReportedForHighlighting() {
    let m = try! #require(FuzzySearch.match("nt", "New Tab"))
    #expect(m.positions == [0, 4])   // the two word initials
}

// MARK: - Ranking

/// The whole point. Plain subsequence matching scores these the same and offers the wrong one
/// first; the initials of the words are what the user typed.
@Test func initialsOfWordsBeatLettersBuriedMidWord() {
    #expect(best("nt", ["Font Smaller", "New Tab"]) == "New Tab")
    #expect(best("st", ["Set Theme", "Font Smaller"]) == "Set Theme")
}

@Test func aRunOfAdjacentCharactersBeatsAScatteredMatch() {
    #expect(best("tab", ["The Absolute Best", "New Tab"]) == "New Tab")
}

@Test func anExactPrefixWinsOverAMatchStartingLater() {
    #expect(best("new", ["Rename Window", "New Tab"]) == "New Tab")
}

/// `newTab` and `New Tab` should both give the `T` its word-start bonus, so a palette listing
/// config names and menu titles ranks them consistently.
@Test func aCapitalInsideAWordCountsAsAWordStart() {
    #expect(best("nt", ["nonsense text here", "newTab"]) == "newTab")
}

@Test func separatorsOtherThanSpacesStartWordsToo() {
    #expect(best("nt", ["container", "new_tab"]) == "new_tab")
    #expect(best("nt", ["container", "new-tab"]) == "new-tab")
}

/// A match buried deep in a long string is usually not what was meant.
@Test func anEarlierMatchOutranksALaterOne() {
    #expect(best("a", ["zzzzzzzzzzzzzza", "abc"]) == "abc")
}

/// Ties must keep the caller's order: the palette hands over the menu's ordering, and scrambling
/// equally-good candidates would make the list jump around as you type.
@Test func equalScoresKeepTheOrderTheyWereGivenIn() {
    // Same length as well as same score, so this pins insertion order rather than the length rule.
    let ranked = FuzzySearch.rank("ab", ["ab one", "ab two", "ab six"]) { $0 }
    #expect(ranked.map(\.item) == ["ab one", "ab two", "ab six"])
}

/// The same query filling more of a candidate is the better answer.
@Test func anEqualScoreBreaksTowardsTheShorterCandidate() {
    #expect(best("nt", ["nonsense text here", "newTab"]) == "newTab")
}

@Test func rankingDropsCandidatesThatDoNotMatch() {
    let ranked = FuzzySearch.rank("tab", ["New Tab", "Copy", "Close Tab"]) { $0 }
    #expect(ranked.map(\.item) == ["New Tab", "Close Tab"])
}

// MARK: - Against the real action list

/// The list this actually runs against. If typing the obvious abbreviation for an action does not
/// put that action first, the palette is a worse way to reach it than the menu.
@Test func theObviousAbbreviationFindsTheRightAction() {
    let titles = ActionCatalog.allMenuActions.map(\.title)
    #expect(best("nt", titles) == "New Tab")
    #expect(best("sr", titles) == "Split Right")
    #expect(best("sd", titles) == "Split Down")
    #expect(best("cp", titles) == "Close Pane")
    #expect(best("cs", titles) == "Clear Screen")
    #expect(best("zp", titles) == "Zoom Pane")
}

@Test func typingAFullTitleFindsExactlyIt() {
    let titles = ActionCatalog.allMenuActions.map(\.title)
    for title in titles {
        #expect(best(title, titles) == title, "typing \(title) should find itself")
    }
}

/// With nothing typed, the list is the list it was given.
///
/// Every candidate scores the same on an empty query, so the tie-break decided the whole order --
/// and it was "shortest first", which shuffled `PaletteSource`'s documented sections (actions,
/// quick actions, themes, tabs, then remote) into an arbitrary order the moment ⌘⇧P opened. It
/// showed up as the Remote *section* not being a section at all: an offline Mac sorted above a live
/// session two rows from the top. Length still breaks ties once something is typed, where it does
/// what it is for -- preferring the shorter of two equally good matches.
@Test func anEmptyQueryKeepsTheOrderItWasGiven() {
    let items = ["a very long action name", "ab", "another long one", "b"]
    #expect(FuzzySearch.rank("", items) { $0 }.map(\.item) == items)
}

@Test func aTypedQueryStillPrefersTheShorterOfTwoEqualMatches() {
    let ranked = FuzzySearch.rank("ab", ["abracadabra", "ab"]) { $0 }
    #expect(ranked.map(\.item) == ["ab", "abracadabra"])
}
