import Foundation

/// One hit, in absolute (scrollback-relative) coordinates so it keeps meaning the same text while
/// the buffer scrolls underneath -- the same reason `Selection` is absolute.
public struct SearchMatch: Equatable {
    public let row: Int
    public let columns: Range<Int>

    public init(row: Int, columns: Range<Int>) {
        self.row = row
        self.columns = columns
    }

    public var selection: Selection {
        Selection(anchor: AbsolutePosition(row: row, col: columns.lowerBound),
                  head: AbsolutePosition(row: row, col: columns.upperBound),
                  mode: .character)
    }
}

/// Searching the screen and the scrollback.
///
/// Held as a value with its results, rather than a function called per keystroke, for one reason:
/// typing extends a query one character at a time, and each extension can only ever *narrow* the
/// previous result set. Rescanning a 10,000-line buffer on every keypress is the difference
/// between a search bar that feels instant and one that stutters on a long session.
public struct BufferSearch: Equatable {
    public private(set) var query: String
    public private(set) var matches: [SearchMatch]
    /// The buffer generation these matches were found in; a `clear` invalidates them the same way
    /// it invalidates a selection.
    private var generation: UInt64
    /// Rows the ring had evicted when these matches were found; see `rebase`.
    private var evictedRows = 0
    /// The buffer's content version when they were found. Narrowing filters the matches already in
    /// hand, so it can only be right when nothing has been written since.
    private var contentVersion: UInt64 = 0
    private var caseSensitive: Bool

    public init() {
        query = ""
        matches = []
        generation = 0
        caseSensitive = false
    }

    public var isEmpty: Bool { matches.isEmpty }

    /// Runs a search, reusing the previous result set when the new query extends the old one.
    ///
    /// A query is case-insensitive until the user types a capital, which is the behaviour every
    /// editor has settled on: it does what you meant without a switch to find.
    public mutating func search(_ newQuery: String, in terminal: Terminal) {
        // Before anything else: the matches being narrowed hold absolute rows, and the ring may
        // have trimmed since the last keystroke. `canNarrow` only asks about the generation, which
        // an eviction never bumps -- so narrowing over stale numbers re-read rows that had moved
        // and silently dropped the matches that moved with them, on the path every keystroke takes.
        rebase(terminal)
        let sensitive = newQuery.contains(where: \.isUppercase)
        // Narrowing filters what was already found; it never looks at a row that was not a match
        // before. That is only sound while the buffer has not changed -- with output arriving
        // between two keystrokes, the matches in the new rows would never be found and the readout
        // would quietly under-count as you typed.
        let canNarrow = !query.isEmpty
            && newQuery.hasPrefix(query)
            && sensitive == caseSensitive
            && generation == terminal.scrollbackGeneration
            && contentVersion == terminal.contentVersion
            && !matches.isEmpty

        query = newQuery
        caseSensitive = sensitive
        generation = terminal.scrollbackGeneration
        evictedRows = terminal.evictedRows
        contentVersion = terminal.contentVersion

        guard !newQuery.isEmpty else {
            matches = []
            return
        }
        matches = canNarrow
            ? narrow(to: newQuery, in: terminal)
            : scanEverything(for: newQuery, in: terminal)
    }

    /// Drops results without forgetting nothing else -- what closing the search bar does.
    public mutating func clear() {
        query = ""
        matches = []
    }

    /// True when the buffer has been cleared or reset under us, so the matches point at text that
    /// is no longer there.
    public func isStale(_ terminal: Terminal) -> Bool {
        !matches.isEmpty && generation != terminal.scrollbackGeneration
    }

    /// Moves every match up by the rows the scrollback ring has dropped since the search ran,
    /// discarding the ones whose text has gone with them. Returns how many rows they moved by, so
    /// the caller can move whatever else it holds in the same coordinates.
    ///
    /// Rebasing rather than re-scanning, because nothing about the matches has changed except
    /// their numbering. `SearchSession.refresh` does re-scan, on a timer, when the buffer's content
    /// actually changes; this is what keeps the highlights on their text in the frames between
    /// those, and it is what the incremental narrowing path needs to be given correct row numbers.
    @discardableResult
    public mutating func rebase(_ terminal: Terminal) -> Int {
        let dropped = terminal.evictedRows - evictedRows
        guard dropped > 0 else { return 0 }
        evictedRows = terminal.evictedRows
        matches = matches.compactMap { match in
            match.row - dropped < 0 ? nil
                : SearchMatch(row: match.row - dropped, columns: match.columns)
        }
        return dropped
    }

    // MARK: - Stepping

    /// The first match at or after `position`, wrapping to the top. nil only when there are none.
    public func next(from position: AbsolutePosition) -> SearchMatch? {
        guard !matches.isEmpty else { return nil }
        return matches.first { match in
            match.row > position.row
                || (match.row == position.row && match.columns.lowerBound > position.col)
        } ?? matches.first
    }

    /// The last match before `position`, wrapping to the bottom.
    public func previous(from position: AbsolutePosition) -> SearchMatch? {
        guard !matches.isEmpty else { return nil }
        return matches.last { match in
            match.row < position.row
                || (match.row == position.row && match.columns.lowerBound < position.col)
        } ?? matches.last
    }

    /// Where a match sits in the list, for a "3 of 47" readout.
    public func index(of match: SearchMatch) -> Int? {
        matches.firstIndex(of: match)
    }

    // MARK: - Scanning

    private func scanEverything(for query: String, in terminal: Terminal) -> [SearchMatch] {
        (0..<terminal.totalRows).flatMap { row in
            self.matches(of: query, onRow: row, in: terminal)
        }
    }

    /// Only the rows that already matched can still match a longer query, so a narrowing search
    /// touches those rows and nothing else.
    private func narrow(to query: String, in terminal: Terminal) -> [SearchMatch] {
        var seen = Set<Int>()
        var rows: [Int] = []
        for match in matches where !seen.contains(match.row) {
            seen.insert(match.row)
            rows.append(match.row)
        }
        return rows.flatMap { self.matches(of: query, onRow: $0, in: terminal) }
    }

    private func matches(of query: String, onRow row: Int, in terminal: Terminal) -> [SearchMatch] {
        let line = terminal.rowText(absoluteRow: row)
        guard !line.text.isEmpty else { return [] }
        let haystack = Array(caseSensitive ? line.text : line.text.lowercased())
        let needle = Array(caseSensitive ? query : query.lowercased())
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }

        var found: [SearchMatch] = []
        var start = 0
        while start + needle.count <= haystack.count {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                found.append(SearchMatch(row: row,
                                         columns: line.columns(for: start..<(start + needle.count))))
                // Overlapping hits would highlight the same text twice, so `aa` in `aaa` is one
                // match then another starting after it -- what every editor's find does.
                start += needle.count
            } else {
                start += 1
            }
        }
        return found
    }
}
