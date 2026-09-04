import Foundation

/// One searchable buffer, named well enough for a person to pick it out of a list.
public struct SearchScope: Equatable {
    /// Identifies the pane to the app; opaque here.
    public let paneID: Int
    /// Which tab it is in, for grouping the results.
    public let tabIndex: Int
    /// What to show above its hits: the tab's title, and the pane when a tab has more than one.
    public let title: String

    public init(paneID: Int, tabIndex: Int, title: String) {
        self.paneID = paneID
        self.tabIndex = tabIndex
        self.title = title
    }
}

/// A hit, and enough context to show it in a list without opening the tab it lives in.
public struct GlobalSearchHit: Equatable {
    public let scope: SearchScope
    public let match: SearchMatch
    /// The line the hit sits on, trimmed, with the hit's own columns marked so it can be
    /// highlighted in the list.
    public let line: String
    public let highlight: Range<Int>

    public init(scope: SearchScope, match: SearchMatch, line: String, highlight: Range<Int>) {
        self.scope = scope
        self.match = match
        self.line = line
        self.highlight = highlight
    }
}

/// Searching every open buffer at once.
///
/// The question a person actually has is "which of my eight tabs had that error in it", and a
/// per-pane search cannot answer it -- you have to visit each tab and ask again. This runs the same
/// `BufferSearch` over every buffer and groups what it finds.
public enum GlobalSearch {
    /// How many hits to keep per pane, so one pane full of matches cannot bury the others.
    ///
    /// A global search is for finding *where* something is, not for reading every occurrence: once
    /// you know which tab it is in, the pane's own ⌘F is the better tool. Capping keeps the list
    /// legible and keeps a `yes` running in one pane from producing ten thousand rows.
    public static let hitsPerPane = 20

    /// Runs `query` over every scope. `terminalFor` hands back the buffer for a pane; returning nil
    /// skips it, which is what a pane closing mid-search looks like.
    public static func run(query: String, scopes: [SearchScope],
                           terminalFor: (SearchScope) -> Terminal?) -> [GlobalSearchHit] {
        guard !query.isEmpty else { return [] }
        var hits: [GlobalSearchHit] = []

        for scope in scopes {
            guard let terminal = terminalFor(scope) else { continue }
            var search = BufferSearch()
            search.search(query, in: terminal)
            for match in search.matches.prefix(hitsPerPane) {
                let row = terminal.rowText(absoluteRow: match.row)
                let (line, highlight) = context(of: match, in: row)
                hits.append(GlobalSearchHit(scope: scope, match: match, line: line, highlight: highlight))
            }
        }
        return hits
    }

    /// Hits grouped by pane, in the order the scopes were given, so the list mirrors the tab bar
    /// rather than whatever order the buffers happened to be searched in.
    public static func grouped(_ hits: [GlobalSearchHit],
                               scopes: [SearchScope]) -> [(scope: SearchScope, hits: [GlobalSearchHit])] {
        scopes.compactMap { scope in
            let mine = hits.filter { $0.scope == scope }
            return mine.isEmpty ? nil : (scope: scope, hits: mine)
        }
    }

    /// How many panes matched -- what a "3 tabs, 47 matches" readout needs.
    public static func paneCount(_ hits: [GlobalSearchHit]) -> Int {
        var seen: Set<Int> = []
        for hit in hits { seen.insert(hit.scope.paneID) }
        return seen.count
    }

    /// The line a hit sits on, with leading blanks removed and the hit's columns adjusted to match.
    ///
    /// Trailing blanks go too, and the highlight is clamped: a hit that ran to the end of the row
    /// would otherwise point past the end of the trimmed string and crash whatever draws it.
    static func context(of match: SearchMatch, in row: RowText) -> (String, Range<Int>) {
        let characters = Array(row.text)
        var start = 0
        while start < characters.count, characters[start] == " " { start += 1 }
        var end = characters.count
        while end > start, characters[end - 1] == " " { end -= 1 }
        guard start < end else { return ("", 0..<0) }

        let line = String(characters[start..<end])
        let lower = max(0, match.columns.lowerBound - start)
        let upper = min(line.count, max(lower, match.columns.upperBound - start))
        return (line, lower..<upper)
    }
}
