import Testing
@testable import NyxCore

private func scope(_ id: Int, tab: Int, _ title: String) -> SearchScope {
    SearchScope(paneID: id, tabIndex: tab, title: title)
}

/// Three panes across two tabs; the error the user is hunting is in the third.
private func panes() -> ([SearchScope], [Int: Terminal]) {
    let scopes = [scope(1, tab: 0, "zsh"), scope(2, tab: 0, "vim"), scope(3, tab: 1, "build")]
    let terminals = [
        1: makeTerminal(cols: 40, rows: 6, scrollback: 50).run("nothing to see\r\nhere either"),
        2: makeTerminal(cols: 40, rows: 6, scrollback: 50).run("some code\r\nno problems"),
        3: makeTerminal(cols: 40, rows: 6, scrollback: 50)
            .run("compiling\r\n  error: undefined symbol  \r\nerror: linker failed"),
    ]
    return (scopes, terminals)
}

private func search(_ query: String) -> [GlobalSearchHit] {
    let (scopes, terminals) = panes()
    return GlobalSearch.run(query: query, scopes: scopes) { terminals[$0.paneID] }
}

// MARK: - Finding

/// The question this exists for: which of my tabs had that error in it.
@Test func aSearchReachesEveryOpenPane() {
    let hits = search("error")
    #expect(hits.count == 2)
    #expect(hits.allSatisfy { $0.scope.paneID == 3 })
    #expect(GlobalSearch.paneCount(hits) == 1)
}

@Test func aQueryPresentInSeveralPanesReportsEachOfThem() {
    let hits = search("e")
    #expect(GlobalSearch.paneCount(hits) > 1)
}

@Test func aQueryNobodyHasFindsNothing() {
    #expect(search("zebra").isEmpty)
    #expect(search("").isEmpty)
}

/// A pane closing while the search runs is ordinary, not an error.
@Test func aPaneThatCannotBeReadIsSkipped() {
    let (scopes, terminals) = panes()
    let hits = GlobalSearch.run(query: "error", scopes: scopes) {
        $0.paneID == 3 ? nil : terminals[$0.paneID]
    }
    #expect(hits.isEmpty)
}

/// One pane running `yes` must not bury every other result.
@Test func onePaneFullOfMatchesCannotSwampTheList() {
    let noisy = makeTerminal(cols: 20, rows: 4, scrollback: 500)
    for _ in 0..<200 { noisy.feed("match\r\n") }
    let hits = GlobalSearch.run(query: "match", scopes: [scope(9, tab: 0, "yes")]) { _ in noisy }
    #expect(hits.count == GlobalSearch.hitsPerPane)
}

// MARK: - Grouping

/// The list should mirror the tab bar, not the order the buffers happened to be searched in.
@Test func resultsAreGroupedInTheOrderTheScopesWereGiven() {
    let (scopes, terminals) = panes()
    let hits = GlobalSearch.run(query: "e", scopes: scopes) { terminals[$0.paneID] }
    let groups = GlobalSearch.grouped(hits, scopes: scopes)
    #expect(groups.map(\.scope.paneID) == groups.map(\.scope.paneID).sorted())
    #expect(groups.allSatisfy { !$0.hits.isEmpty })
}

@Test func groupingDropsPanesWithNothingInThem() {
    let (scopes, terminals) = panes()
    let hits = GlobalSearch.run(query: "error", scopes: scopes) { terminals[$0.paneID] }
    #expect(GlobalSearch.grouped(hits, scopes: scopes).count == 1)
}

// MARK: - Context lines

/// The list shows the line, so leading padding has to go -- and the highlight has to move with it,
/// or it points at the wrong characters.
@Test func theContextLineIsTrimmedAndTheHighlightFollows() {
    let hits = search("error")
    let indented = try! #require(hits.first { $0.line.hasPrefix("error: undefined") })
    #expect(!indented.line.hasPrefix(" "))
    #expect(!indented.line.hasSuffix(" "))
    let characters = Array(indented.line)
    #expect(String(characters[indented.highlight]) == "error")
}

/// A highlight that ran to the end of a padded row would point past the end of the trimmed string
/// and crash whatever draws it.
@Test func aHighlightIsClampedToTheTrimmedLine() {
    let row = RowText(text: "  abc   ", columnOf: Array(0..<8))
    let match = SearchMatch(row: 0, columns: 2..<8)
    let (line, highlight) = GlobalSearch.context(of: match, in: row)
    #expect(line == "abc")
    #expect(highlight.upperBound <= line.count)
    #expect(highlight.lowerBound <= highlight.upperBound)
}

@Test func aBlankRowProducesAnEmptyContextRatherThanNonsense() {
    let row = RowText(text: "     ", columnOf: Array(0..<5))
    let (line, highlight) = GlobalSearch.context(of: SearchMatch(row: 0, columns: 1..<3), in: row)
    #expect(line.isEmpty)
    #expect(highlight.isEmpty)
}
