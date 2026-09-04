import Foundation

/// The search bar's state: what was typed, every hit, and which one the user is standing on.
///
/// `BufferSearch` answers "where is this text"; this answers the questions a *bar* asks -- which
/// hit becomes current when the query changes, where stepping goes from here, what the "3 of 47"
/// readout says. Those are the parts a user notices when they are wrong (typing another character
/// throwing you back to the top of the buffer, ⏎ skipping a hit), and none of them need AppKit,
/// so they live here where a test can drive them.
public struct SearchSession: Equatable {
    public private(set) var search = BufferSearch()
    /// The hit being shown, or nil when there are none. Always one of `matches`.
    public private(set) var current: SearchMatch?

    public init() {}

    public var query: String { search.query }
    public var matches: [SearchMatch] { search.matches }
    public var isEmpty: Bool { search.matches.isEmpty }

    /// Re-runs the search for a new query and picks the hit to stand on.
    ///
    /// The next hit at or after the one already current, so extending a query keeps the user where
    /// they were reading rather than teleporting them back to the top of the screen; the first hit
    /// at or after the top of the viewport when there is nothing current yet, which is what ⌘F on a
    /// scrolled-back buffer should find.
    public mutating func update(query: String, in terminal: Terminal, viewportTop: Int) {
        let anchor = current.map { AbsolutePosition(row: $0.row, col: $0.columns.lowerBound - 1) }
            ?? AbsolutePosition(row: viewportTop, col: -1)
        search.search(query, in: terminal)
        current = search.next(from: anchor)
    }

    /// Re-runs the current query against a buffer that has changed under us, keeping the current
    /// hit if the same text is still matched there. Output arriving while the bar is open must not
    /// silently leave the highlights pointing at rows that have moved.
    public mutating func refresh(in terminal: Terminal, viewportTop: Int) {
        guard !search.query.isEmpty else { return }
        let previous = current
        var fresh = BufferSearch()
        fresh.search(search.query, in: terminal)
        search = fresh
        if let previous, search.index(of: previous) != nil {
            current = previous
        } else {
            let anchor = previous.map { AbsolutePosition(row: $0.row, col: $0.columns.lowerBound - 1) }
                ?? AbsolutePosition(row: viewportTop, col: -1)
            current = search.next(from: anchor)
        }
    }

    /// Drops or repairs matches that no longer describe the buffer they were found in.
    ///
    /// Matches are absolute rows, and clearing the screen, a reset or an alternate-screen swap
    /// moves every row out from under them. Left alone, the highlights get painted over unrelated
    /// text, the readout goes on claiming a count, and stepping selects -- and then copies -- text
    /// the user never searched for. The check is a single comparison, so this belongs on the render
    /// path rather than on a timer that only runs while the bar happens to be open.
    @discardableResult
    public mutating func invalidateIfStale(in terminal: Terminal, viewportTop: Int) -> Bool {
        if search.isStale(terminal) {
            refresh(in: terminal, viewportTop: viewportTop)
            return true
        }
        // The gentler shift: the ring dropped rows off the top, so the same text now lives that
        // many rows lower. The hit the user is standing on moves with the rest of them, and is
        // dropped only when the row it was on has itself been evicted.
        let dropped = search.rebase(terminal)
        guard dropped > 0 else { return false }
        if let hit = current {
            let moved = SearchMatch(row: hit.row - dropped, columns: hit.columns)
            current = search.index(of: moved) != nil ? moved : search.matches.first
        }
        return true
    }

    /// Moves to the next or previous hit, wrapping at either end. nil when there are none.
    @discardableResult
    public mutating func step(forward: Bool) -> SearchMatch? {
        guard !search.matches.isEmpty else {
            current = nil
            return nil
        }
        let from = current.map { AbsolutePosition(row: $0.row, col: $0.columns.lowerBound) }
            ?? AbsolutePosition(row: 0, col: -1)
        current = forward ? search.next(from: from) : search.previous(from: from)
        return current
    }

    public mutating func clear() {
        search.clear()
        current = nil
    }

    /// What the bar shows beside the field: position and total, or why there is neither.
    ///
    /// Empty for an empty query, because a bar that has just opened has nothing to report and
    /// "0 of 0" reads like a failure.
    public var readout: String {
        guard !search.query.isEmpty else { return "" }
        guard !search.matches.isEmpty else { return "no results" }
        let position = current.flatMap { search.index(of: $0) }.map { $0 + 1 } ?? 0
        return "\(position) of \(search.matches.count)"
    }
}
