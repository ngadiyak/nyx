import Foundation

/// Where the top of the viewport sits in the **display** sequence, which is not the row sequence.
///
/// A fold takes rows out of the middle of the buffer and a lens puts lines in that were never rows
/// at all, so "the viewport starts at absolute row N" stopped being enough to say what is on
/// screen. It is now a row *and* how far into that row's lens the top is.
///
/// The failure this replaces was silent and total: viewport arithmetic in absolute rows meant a
/// lensed block showed its lens from line `top - outputStart`, so the only lines a reader could ever
/// scroll to were `0 ..< outputRows.count + viewportRows`. An ordinary 20-user JSON response --
/// fourteen rows of transcript, a hundred and twenty-six lines pretty-printed -- had ninety-odd
/// lines that no amount of scrolling would show, with nothing on screen to say so.
///
/// `line` is meaningful only when `row` is inside a lensed command's output rows; everywhere else it
/// is 0, and every function here returns cursors in that canonical form: for a lens, `row` is the
/// block's first output row and `line` indexes its buffer; for a fold, `row` is the first hidden
/// row; otherwise the row itself.
public struct DisplayCursor: Equatable {
    /// An absolute row of the buffer.
    public var row: Int
    /// Which line of that row's lens, or 0.
    public var line: Int

    public init(row: Int, line: Int = 0) {
        self.row = row
        self.line = line
    }
}

public extension DisplayCursor {
    /// The same anchor after the scrollback ring has thrown `evictedAfter - evictedBefore` rows
    /// away, or nil when it cannot be kept.
    ///
    /// Past capacity every printed row drops the oldest one and absolute row *n* comes to mean the
    /// row below the one it used to mean -- silently, because the indices stay in range. The pane
    /// used to answer that by forgetting where the reader was, which is once per row for as long as
    /// anything is printing into a full buffer: a reader seventy lines into a pretty-printed
    /// response was put back to line thirteen of it (the row offset is all a bare row can carry)
    /// continuously, while a build scrolled past in another block.
    ///
    /// The rows moved by a known amount, so the anchor moves by the same amount. `line` does not
    /// move at all: it indexes a lens buffer, which is Nyx's own text and has not been renumbered
    /// by anything.
    ///
    /// The **row** is the only thing that needs arithmetic. `anchorTop` comes back as the
    /// terminal's current `viewportTopRow`, because the terminal has already done its own half of
    /// this: a scrolled-back viewport grows `viewportOffset` as rows leave the ring, so
    /// `scrollback.count - viewportOffset` follows the same content down by the same amount. Taking
    /// the current value is right in both regimes -- scrolled back, where the top moved with the
    /// rows; and at the live bottom, where nothing moved and it is the number it already was.
    ///
    /// Deriving it instead (`anchorTop - delta`, or leaving it alone) is wrong in one regime or the
    /// other, and both mistakes look identical from here: the staleness check fails, the fallback
    /// takes over, and the reader is thrown out of the lens by the very function that exists to
    /// keep them in it. Both were tried; the second is what a built-app probe caught.
    ///
    /// nil in the two cases where there is nothing to keep: no anchor at all (`anchorTop` below
    /// zero is the pane's "none yet" marker), or the anchor's own row has left the ring, which
    /// means the block it pointed at is gone.
    ///
    /// A counter that appears to go backwards -- `Terminal.evictedRows` never does, but a caller
    /// can read the two numbers in the wrong order -- shifts nothing rather than moving rows
    /// upwards into indices that were never theirs.
    static func shifted(anchor: DisplayCursor?, anchorTop: Int,
                        evictedBefore: Int, evictedAfter: Int, viewportTopRow: Int)
        -> (anchor: DisplayCursor, anchorTop: Int)? {
        guard let anchor, anchorTop >= 0 else { return nil }
        let delta = max(0, evictedAfter - evictedBefore)
        guard delta > 0 else { return (anchor, anchorTop) }
        let row = anchor.row - delta
        guard row >= 0 else { return nil }
        return (DisplayCursor(row: row, line: anchor.line), max(0, viewportTopRow))
    }
}

public extension Terminal {
    /// What the display shows at `cursor`, and where the next display line begins. nil past the end
    /// of the buffer.
    ///
    /// Stateless, so a cursor anywhere -- the middle of a lens, a wrapped command line, a fold --
    /// answers the same way. That costs a `command(containingAbsoluteRow:)`, which scans back to the
    /// block's prompt, so this is for stepping (a wheel click is three of them) and for entering a
    /// block. `displayRows` hands over to a prompt-gated loop as soon as it is out of the block it
    /// started in: paying the scan per row of a five-thousand-row block is the 3 ms frame the
    /// gutter's own comment in `Pane` warns about.
    func displayEntry(at cursor: DisplayCursor, folding: OutputFolding,
                      lenses: LensChoices = LensChoices(),
                      buffers: (UInt32) -> LensBuffer? = { _ in nil },
                      memo: CommandRegionMemo? = nil)
        -> (row: DisplayRow, next: DisplayCursor)? {
        let memo = memo ?? CommandRegionMemo()
        let row = cursor.row
        guard row >= 0, row < totalRows else { return nil }
        let plain = (DisplayRow.row(row), DisplayCursor(row: row + 1))
        guard !folding.isEmpty || !lenses.isEmpty else { return plain }
        // A folded block shows its fold, not its lens: both say "show me less", and the fold is the
        // one whose placeholder the reader can click to undo.
        if let (region, hidden) = foldedCommand(containingOutputRow: row, folding: folding,
                                                memo: memo) {
            return (.fold(commandID: region.id, hiddenRows: hidden.count, status: region.status),
                    DisplayCursor(row: hidden.upperBound))
        }
        if let (region, buffer) = lensedCommand(containingOutputRow: row, lenses: lenses,
                                                buffers: buffers, memo: memo) {
            // Clamped rather than trusted: the buffer is rebuilt on another queue and can be
            // shorter than it was when this cursor was made.
            let line = min(max(0, cursor.line), buffer.lineCount - 1)
            let next = line + 1 < buffer.lineCount
                ? DisplayCursor(row: region.outputRows.lowerBound, line: line + 1)
                : DisplayCursor(row: region.endRow + 1)
            return (.lens(commandID: region.id, line: line), next)
        }
        return plain
    }

    /// The display line immediately above `cursor`, or nil when it is already the first.
    ///
    /// Backwards is its own walk rather than a search: a fold hiding two thousand rows is one
    /// display line, and finding it by stepping forwards from row zero would cost the whole
    /// scrollback on every wheel click.
    func previousDisplayCursor(before cursor: DisplayCursor, folding: OutputFolding,
                               lenses: LensChoices = LensChoices(),
                               buffers: (UInt32) -> LensBuffer? = { _ in nil },
                               memo: CommandRegionMemo? = nil) -> DisplayCursor? {
        let memo = memo ?? CommandRegionMemo()
        if cursor.line > 0,
           lensedCommand(containingOutputRow: cursor.row, lenses: lenses, buffers: buffers,
                         memo: memo) != nil {
            return DisplayCursor(row: cursor.row, line: cursor.line - 1)
        }
        let above = cursor.row - 1
        guard above >= 0 else { return nil }
        guard !folding.isEmpty || !lenses.isEmpty else { return DisplayCursor(row: above) }
        if let (_, hidden) = foldedCommand(containingOutputRow: above, folding: folding,
                                           memo: memo) {
            return DisplayCursor(row: hidden.lowerBound)
        }
        if let (region, buffer) = lensedCommand(containingOutputRow: above, lenses: lenses,
                                                buffers: buffers, memo: memo) {
            // Entering a lens from below lands on its *last* line, which is what "the line above
            // the row after the block" means.
            return DisplayCursor(row: region.outputRows.lowerBound, line: buffer.lineCount - 1)
        }
        return DisplayCursor(row: above)
    }

    /// The cursor an absolute row names: the first display line that shows any part of it.
    ///
    /// This is the bridge for everything that still scrolls by row -- a search match, the sticky
    /// prompt, a jump to a prompt mark, and above all `viewportCursor` when the anchor has been
    /// forgotten. A row inside a lens keeps its offset into the block rather than snapping to the
    /// top of it: answering `DisplayCursor(row: top)` there meant line 0, so a reader parked inside
    /// a pretty-printed response was thrown back to the first line of it every time the ring
    /// evicted a row -- continuously, for as long as anything else was printing.
    func displayCursor(atAbsoluteRow row: Int, folding: OutputFolding,
                       lenses: LensChoices = LensChoices(),
                       buffers: (UInt32) -> LensBuffer? = { _ in nil },
                       memo: CommandRegionMemo? = nil) -> DisplayCursor {
        guard !folding.isEmpty || !lenses.isEmpty else { return DisplayCursor(row: row) }
        let memo = memo ?? CommandRegionMemo()
        if let (_, hidden) = foldedCommand(containingOutputRow: row, folding: folding, memo: memo) {
            return DisplayCursor(row: hidden.lowerBound)
        }
        if let (region, buffer) = lensedCommand(containingOutputRow: row, lenses: lenses,
                                                buffers: buffers, memo: memo) {
            let offset = row - region.outputRows.lowerBound
            return DisplayCursor(row: region.outputRows.lowerBound,
                                 line: min(max(0, offset), buffer.lineCount - 1))
        }
        return DisplayCursor(row: row)
    }

    /// The same cursor with its line where this buffer says it can be: the block's first output row
    /// and a line index inside the lens, or the row and 0. A cursor kept across a rebuild, a resize
    /// or a lens being closed can name a line that no longer exists.
    func canonicalised(_ cursor: DisplayCursor, folding: OutputFolding,
                       lenses: LensChoices = LensChoices(),
                       buffers: (UInt32) -> LensBuffer? = { _ in nil },
                       memo: CommandRegionMemo? = nil) -> DisplayCursor {
        guard let (region, buffer) = lensedCommand(containingOutputRow: cursor.row, lenses: lenses,
                                                   buffers: buffers, memo: memo) else {
            return DisplayCursor(row: cursor.row)
        }
        return DisplayCursor(row: region.outputRows.lowerBound,
                             line: min(max(0, cursor.line), buffer.lineCount - 1))
    }

    /// `cursor` moved `delta` **display lines**: positive towards newer content, negative towards
    /// older. Clamped at both ends of the buffer.
    ///
    /// This is what the wheel, and anything else that scrolls by an amount rather than to a place,
    /// goes through. Stepping one display line at a time is deliberate: a fold and a whole lens are
    /// each traversed in a single step, so the cost is the number of lines asked for and not the
    /// number of rows they span.
    ///
    /// The forward clamp is the scrollback size, the same limit `viewportOffset` has, so the cursor
    /// this returns is one the terminal can actually be set to. Note that the display is *not* the
    /// same height as the buffer once a lens is open -- anything that wants a proportion of the
    /// whole, a scrollbar thumb for instance, cannot get it from the row count and does not get it
    /// from here either.
    func advance(_ cursor: DisplayCursor, by delta: Int, folding: OutputFolding,
                 lenses: LensChoices = LensChoices(),
                 viewportRows: Int? = nil,
                 buffers: (UInt32) -> LensBuffer? = { _ in nil },
                 memo: CommandRegionMemo? = nil) -> DisplayCursor {
        let memo = memo ?? CommandRegionMemo()
        var current = canonicalised(cursor, folding: folding, lenses: lenses, buffers: buffers,
                                    memo: memo)
        guard delta != 0 else { return current }
        let limit = max(0, scrollback.count)
        // Nothing replaced anywhere means the display is the rows, and a scroll is arithmetic: the
        // path every ordinary session takes must not walk anything.
        guard !folding.isEmpty || !lenses.isEmpty else {
            return DisplayCursor(row: min(limit, max(0, current.row + delta)))
        }
        let screenful = max(1, viewportRows ?? rows)
        if delta > 0 {
            for _ in 0..<delta {
                guard let (_, next) = displayEntry(at: current, folding: folding, lenses: lenses,
                                                   buffers: buffers, memo: memo) else { break }
                // Below the terminal's own bottom this is exactly the clamp `viewportOffset` has,
                // and it is free.
                if next.row > limit {
                    // Past it. That happens when a lens on the *live screen* is longer than the rows
                    // it replaced: the display has more lines below than the buffer has rows, and
                    // stopping here would leave the tail of a response permanently off the bottom of
                    // the window. Keep going while a full screen of display lines is still below,
                    // which is the same thing the offset clamp guarantees everywhere else.
                    guard hasDisplayLines(from: next, atLeast: screenful, folding: folding,
                                          lenses: lenses, buffers: buffers,
                                          memo: memo) else { break }
                }
                current = next
            }
        } else {
            for _ in 0..<(-delta) {
                guard let previous = previousDisplayCursor(before: current, folding: folding,
                                                           lenses: lenses, buffers: buffers,
                                                           memo: memo) else { break }
                current = previous
            }
        }
        return current
    }

    /// The display cursor that puts the **last** display line on the last row of the window: what
    /// "scroll to the bottom" means once the display is not the rows.
    ///
    /// `viewportOffset = 0` used to be the whole answer, and it is still the answer whenever nothing
    /// is replaced. It stops being one when a lens is taller than the rows it stands in for and
    /// those rows are on the *live screen*: the display from the terminal's own bottom is then the
    /// prompt, the command, and a hundred and twenty-six lines of response, and the shell prompt
    /// underneath the block falls off the end of the window. Typing went to a caret nobody could
    /// see, and the echo arrived somewhere below the glass.
    ///
    /// **The prompt wins.** A freshly finished `curl` shows its prompt at the bottom with the tail
    /// of the response above it, and the reader scrolls up for the head of it. The other choice --
    /// the response from its first line, prompt off-screen -- reads better for exactly one second
    /// and then stops being a terminal: you cannot see what you are typing.
    func displayBottomCursor(folding: OutputFolding, lenses: LensChoices = LensChoices(),
                             viewportRows: Int? = nil,
                             buffers: (UInt32) -> LensBuffer? = { _ in nil },
                             memo: CommandRegionMemo? = nil) -> DisplayCursor {
        let screenful = max(1, viewportRows ?? rows)
        // Nothing replaced: the display is the rows and the bottom is where it always was, with no
        // walk at all. This is the path every ordinary frame takes.
        guard !folding.isEmpty || !lenses.isEmpty else {
            return DisplayCursor(row: max(0, scrollback.count))
        }
        // The display line the very last row of the buffer produces, whatever stands in for it.
        let memo = memo ?? CommandRegionMemo()
        var cursor = previousDisplayCursor(before: DisplayCursor(row: totalRows), folding: folding,
                                           lenses: lenses, buffers: buffers, memo: memo)
            ?? DisplayCursor(row: 0)
        for _ in 1..<screenful {
            guard let previous = previousDisplayCursor(before: cursor, folding: folding,
                                                       lenses: lenses, buffers: buffers,
                                                       memo: memo) else { break }
            cursor = previous
        }
        return cursor
    }

    /// Whether `cursor` *is* the display bottom -- what a scroll that reached the live edge landed
    /// on, whoever asked for it.
    ///
    /// The distinction `viewportCursor` needs is about the **position**, not about which gesture
    /// produced it. Tagging by gesture missed the commonest case there is: a reader who has scrolled
    /// back and then wheels down again lands exactly here, through `advance`'s own clamp, and was
    /// tagged "a place the reader chose". Once the ring filled, `viewportTopRow` froze, the
    /// staleness check stopped saving it, and the window walked backwards through the buffer while
    /// output arrived below it -- with no lens and no fold anywhere, on any pane where somebody
    /// scrolls up and back down during a long build.
    ///
    /// Asked once per scroll rather than once per frame: a wheel click can afford a walk of a
    /// screenful, and the answer is stored with the anchor.
    func isDisplayBottom(_ cursor: DisplayCursor, folding: OutputFolding,
                         lenses: LensChoices = LensChoices(), viewportRows: Int? = nil,
                         buffers: (UInt32) -> LensBuffer? = { _ in nil },
                         memo: CommandRegionMemo? = nil) -> Bool {
        cursor == displayBottomCursor(folding: folding, lenses: lenses, viewportRows: viewportRows,
                                      buffers: buffers, memo: memo)
    }

    /// Which display cursor a viewport should be drawn from, given the position its owner last
    /// chose and the row that position was chosen against.
    ///
    /// Three answers, in the order that makes the ordinary session free:
    ///
    /// - the anchor, when it still describes this viewport (`anchorTop == viewportTopRow`) *and* it
    ///   is a place the reader chose rather than the live bottom, clamped to what the buffers hold
    ///   now;
    /// - the **display** bottom, when there is no usable anchor and the terminal is already at its
    ///   own bottom -- which is every frame after new output arrives while the reader is pinned to
    ///   the live screen, and the frame a finished request opens its lens on. Without it a response
    ///   taller than the window pushed the shell's prompt past the last row and the caret with it;
    /// - the display cursor that top row names otherwise, which is what a viewport scrolled up into
    ///   the scrollback wants. It is the row itself everywhere except inside a fold or a lens, where
    ///   it is that block's own display position -- see `displayCursor(atAbsoluteRow:)` for what
    ///   answering the bare row cost a reader inside a lens.
    ///
    /// Lenses only for the middle case: a fold can only make the display *shorter* than the rows it
    /// stands in for, so the terminal's own bottom is still the display's.
    ///
    /// `anchorIsDisplayBottom` says the anchor *is* the display bottom -- `isDisplayBottom`, asked
    /// when the anchor was recorded. That is what "go to the live screen" records on every
    /// keystroke, and it is also where a reader who wheels down to the live edge lands. Such an
    /// anchor is **ignored**
    /// and the bottom recomputed, because the bottom moves whenever anything prints and the
    /// staleness check cannot see that: once the ring is at capacity `viewportTopRow` stops moving
    /// -- `scrollback.count` is pinned at the cap and `viewportOffset` is zero -- so `anchorTop ==
    /// top` goes on saying "still yours" while the content underneath scrolls away. With a lens or
    /// a fold open that froze the pane: `make build` printed below the window, the screen stopped
    /// changing, the caret had no slot, and one keystroke resynced it for exactly one frame.
    ///
    /// Recomputing is cheap and cannot go stale -- `displayBottomCursor` is a pure function of the
    /// buffer, and one walk of a screenful with `CommandRegionMemo` in hand.
    /// `anchorIsDisplayBottom` has no default on purpose: every call site has to say which of the
    /// two kinds of anchor it is holding, because getting it wrong is silent and only shows up once
    /// the ring is full.
    func viewportCursor(anchor: DisplayCursor?, anchorTop: Int,
                        anchorIsDisplayBottom: Bool, folding: OutputFolding,
                        lenses: LensChoices = LensChoices(), viewportRows: Int? = nil,
                        buffers: (UInt32) -> LensBuffer? = { _ in nil },
                        memo: CommandRegionMemo? = nil) -> DisplayCursor {
        let memo = memo ?? CommandRegionMemo()
        let top = max(0, viewportTopRow)
        if let anchor, anchorTop == top, !anchorIsDisplayBottom {
            return canonicalised(anchor, folding: folding, lenses: lenses, buffers: buffers,
                                 memo: memo)
        }
        guard viewportOffset == 0, !lenses.isEmpty else {
            return displayCursor(atAbsoluteRow: top, folding: folding, lenses: lenses,
                                 buffers: buffers, memo: memo)
        }
        return displayBottomCursor(folding: folding, lenses: lenses, viewportRows: viewportRows,
                                   buffers: buffers, memo: memo)
    }

    /// Whether `n` display lines start at `cursor`. Walks at most `n` of them, so it costs what it
    /// is asked about and not the size of the buffer.
    internal func hasDisplayLines(from cursor: DisplayCursor, atLeast n: Int,
                                  folding: OutputFolding, lenses: LensChoices,
                                  buffers: (UInt32) -> LensBuffer?,
                                  memo: CommandRegionMemo? = nil) -> Bool {
        var position = cursor
        let memo = memo ?? CommandRegionMemo()
        for _ in 0..<n {
            guard let (_, next) = displayEntry(at: position, folding: folding, lenses: lenses,
                                               buffers: buffers, memo: memo) else { return false }
            position = next
        }
        return true
    }
}
