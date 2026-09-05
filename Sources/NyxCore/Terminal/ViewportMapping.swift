import Foundation

/// Which viewport slot is filled from which row, described by the few numbers that can change it.
///
/// The renderer keeps each visible row's built instances and reuses them while `Row.dirty` says the
/// row has not changed. That is only sound while slot *y* keeps being filled from the same row:
/// scrolled back into the scrollback, with a fold open, after a `clear` renumbered every absolute
/// row, or once the ring has evicted rows out from under the numbering, slot *y* is filled from
/// somewhere else and a row nothing has touched can be showing text it was not showing last frame.
///
/// This lives here rather than in the view because the failure it prevents is invisible: getting it
/// wrong leaves a stale row on screen, which no test of the drawing can catch and no user reports
/// as anything but "sometimes the terminal is wrong". Pure and comparable, it can be tested for the
/// property that matters — that every way of moving the mapping produces a different value.
public struct ViewportMapping: Equatable {
    /// The absolute row the top of the viewport shows.
    public let top: Int
    public let cols: Int
    public let rows: Int
    /// Bumped when absolute rows stop meaning what they meant: `ED 3`, a reset, an alternate-screen
    /// swap, a re-wrap.
    public let scrollbackGeneration: UInt64
    /// Rows the ring has thrown away, which shifts every absolute row without touching the
    /// generation.
    public let evictedRows: Int
    /// Whether any output is folded, which takes rows out of the middle of the mapping.
    public let folded: Bool
    /// Whether the viewport is scrolled up from the live screen.
    public let scrolledBack: Bool

    public init(top: Int, cols: Int, rows: Int, scrollbackGeneration: UInt64, evictedRows: Int,
                folded: Bool, scrolledBack: Bool) {
        self.top = top
        self.cols = cols
        self.rows = rows
        self.scrollbackGeneration = scrollbackGeneration
        self.evictedRows = evictedRows
        self.folded = folded
        self.scrolledBack = scrolledBack
    }

    /// The mapping a terminal is showing right now. `folded` is the view's own state, so it is the
    /// one thing that has to be passed in.
    public init(of terminal: Terminal, top: Int, folded: Bool) {
        self.init(top: top, cols: terminal.cols, rows: terminal.rows,
                  scrollbackGeneration: terminal.scrollbackGeneration,
                  evictedRows: terminal.evictedRows, folded: folded,
                  scrolledBack: terminal.viewportOffset != 0)
    }

    /// Whether per-row dirty flags may be trusted for a frame drawn with this mapping, given the
    /// one the last presented frame used.
    ///
    /// Anything but "the same mapping, live, unfolded" answers no, and the caller draws every row —
    /// one full frame, at exactly the moments where every row was going to change anyway.
    public func trustsDirtyFlags(after previous: ViewportMapping?) -> Bool {
        self == previous && !folded && !scrolledBack
    }
}
