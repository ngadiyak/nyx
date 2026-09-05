import Testing
@testable import NyxCore

/// What happens to state addressed in *absolute rows* once the scrollback ring is full.
///
/// `Scrollback` is a fixed-capacity ring: past capacity, every `push` evicts the oldest row and
/// every absolute index silently comes to mean the row below the one it used to mean. Nothing is
/// told by the generation counter -- `scrollbackGeneration` is bumped only by `ED 3`, a reset and
/// an alternate-screen swap, never by an eviction, because the content is still there and has only
/// moved. `OutputFolding.prune` and `CommandWatcher` handle the shift by dropping what moved away;
/// the selection and the search hits follow their text down instead, using `Terminal.evictedRows`.
@Suite("Absolute rows after the scrollback trims")
struct ScrollbackTrimTests {

    /// The mechanism, pinned: two lines past capacity and absolute row *n* holds different text,
    /// with the generation unchanged.
    @Test func absoluteRowsShiftOnceTheRingIsFull() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        for i in 0..<5 { t.feed("row\(i)\r\n") }
        let generation = t.scrollbackGeneration
        let row = t.rowText(absoluteRow: 1).text.trimmingCharacters(in: .whitespaces)
        #expect(row == "row1")

        t.feed("row5\r\nrow6\r\n")
        #expect(t.scrollbackGeneration == generation)
        let after = t.rowText(absoluteRow: 1).text.trimmingCharacters(in: .whitespaces)
        #expect(after != row)   // same index, different content, no generation bump
    }

    /// A selection is stored in absolute rows "so a selection survives scrolling and new output"
    /// (`AbsolutePosition`'s own doc). It has to survive the ring trimming too: the text is still
    /// there, two rows lower down, and a highlight that stayed where it was covered whatever had
    /// slid into it -- which is what ⌘C then copied.
    @Test func aSelectionKeepsItsTextWhenTheRingTrims() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        for i in 0..<5 { t.feed("row\(i)\r\n") }

        var target = -1
        for r in 0..<t.totalRows where t.rowText(absoluteRow: r).text.hasPrefix("row1") { target = r }
        let selection = Selection(anchor: AbsolutePosition(row: target, col: 0),
                                  head: AbsolutePosition(row: target, col: 4), mode: .character)
        #expect(t.text(in: selection) == "row1")

        var controller = SelectionController()
        _ = controller.replace(with: selection, in: t)
        let before = t.evictedRows
        t.feed("row5\r\nrow6\r\n")
        let dropped = t.evictedRows - before
        #expect(dropped > 0)   // the ring did trim; otherwise this test proves nothing
        _ = controller.invalidateIfStale(t)

        let moved = try? #require(controller.selection)
        #expect(moved?.start.row == target - dropped)    // down by exactly what was evicted
        #expect(moved.map { t.text(in: $0) } == "row1")  // still the text it was made on
    }

    /// The other end of the same rule: a selection whose text has itself been evicted has nothing
    /// left to point at, so it goes rather than sliding up to row 0 and highlighting a stranger.
    @Test func aSelectionIsDroppedOnceItsTextIsEvicted() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        for i in 0..<5 { t.feed("row\(i)\r\n") }

        var controller = SelectionController()
        _ = controller.replace(with: Selection(anchor: AbsolutePosition(row: 0, col: 0),
                                               head: AbsolutePosition(row: 0, col: 4),
                                               mode: .character), in: t)
        for i in 5..<20 { t.feed("row\(i)\r\n") }
        _ = controller.invalidateIfStale(t)
        #expect(controller.selection == nil)
    }

    /// Search matches are absolute rows as well, and the highlights are drawn from them every
    /// frame. Rebased, not re-scanned: the bar stays open while a build streams past, and
    /// re-running the query over the whole buffer on every eviction is the stutter that causes.
    @Test func searchHitsFollowTheirTextWhenTheRingTrims() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        for i in 0..<5 { t.feed("row\(i)\r\n") }

        var session = SearchSession()
        session.update(query: "row3", in: t, viewportTop: t.viewportTopRow)
        let found = try? #require(session.matches.first)
        #expect(found.map { t.rowText(absoluteRow: $0.row).text.hasPrefix("row3") } == true)

        let before = t.evictedRows
        t.feed("row5\r\nrow6\r\n")
        let dropped = t.evictedRows - before
        #expect(dropped > 0)
        #expect(session.invalidateIfStale(in: t, viewportTop: t.viewportTopRow) == true)
        let after = try? #require(session.matches.first)
        #expect(after?.row == (found?.row ?? -1) - dropped)
        #expect(after.map { t.rowText(absoluteRow: $0.row).text.hasPrefix("row3") } == true)
        #expect(session.current == after)
    }

    /// **The keystroke path.** Typing another character narrows the previous matches instead of
    /// re-scanning -- and those matches are absolute rows, which the ring may have moved since.
    /// Narrowing over the old numbers re-read rows that had shifted and silently dropped the
    /// matches that shifted with them, so the readout under-counted as you typed.
    @Test func narrowingAfterATrimFindsWhatAFreshSearchFinds() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        for i in 0..<5 { t.feed("error \(i)\r\n") }

        var narrowed = BufferSearch()
        narrowed.search("err", in: t)          // the first three characters
        let before = t.evictedRows
        t.feed("error 5\r\nerror 6\r\n")     // the ring trims under the open bar
        #expect(t.evictedRows > before)

        narrowed.search("erro", in: t)         // ...and the user types the fourth
        var fresh = BufferSearch()
        fresh.search("erro", in: t)
        #expect(narrowed.matches == fresh.matches)
    }

    /// A block selection is the same column span on every row it covers, so an endpoint whose row
    /// is evicted may not have its column thrown away: doing that widened a five-column block to
    /// fifteen, and ⌘C then copied three times what was highlighted.
    @Test func aBlockSelectionKeepsItsWidthWhenItsTopRowIsEvicted() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        for i in 0..<5 { t.feed("row\(i) xxxxxxxxxxxx\r\n") }

        var controller = SelectionController()
        _ = controller.replace(with: Selection(anchor: AbsolutePosition(row: 0, col: 10),
                                               head: AbsolutePosition(row: 3, col: 15),
                                               mode: .block), in: t)
        let width = controller.selection?.columnRange(onRow: 2, cols: t.cols)?.count
        t.feed("row5\r\nrow6\r\n")
        _ = controller.invalidateIfStale(t)

        let moved = try? #require(controller.selection)
        #expect(moved?.columnRange(onRow: 1, cols: t.cols)?.count == width)
        #expect(moved?.start.col == 10)
    }

    /// A character selection is the other way round: it runs to the end of every row but its last,
    /// so a start whose row has gone becomes the start of what is left, column and all.
    @Test func aCharacterSelectionClampsToTheStartOfWhatSurvives() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        for i in 0..<5 { t.feed("row\(i)\r\n") }

        var controller = SelectionController()
        _ = controller.replace(with: Selection(anchor: AbsolutePosition(row: 0, col: 3),
                                               head: AbsolutePosition(row: 3, col: 4),
                                               mode: .character), in: t)
        t.feed("row5\r\nrow6\r\n")
        _ = controller.invalidateIfStale(t)
        #expect(controller.selection?.start == AbsolutePosition(row: 0, col: 0))
    }

    /// Reflow is the *other* way absolute rows stop meaning what they meant, and the two halves
    /// need different answers. A narrower window re-wraps: content moves between rows by no offset
    /// anything could be corrected by, so holders are told to drop.
    @Test func rewrappingInvalidatesAbsoluteRows() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 50)
        for i in 0..<6 { t.feed("marker\(i) and some more text here\r\n") }
        let generation = t.scrollbackGeneration
        t.resize(cols: 10, rows: 4)
        #expect(t.scrollbackGeneration != generation)
    }

    /// Changing only the height does not: the rows are the same rows in the same order, and a
    /// selection has to survive dragging the bottom edge of the window.
    @Test func resizingTheHeightAloneKeepsTheSelection() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 50)
        for i in 0..<6 { t.feed("marker\(i)\r\n") }

        var target = -1
        for r in 0..<t.totalRows where t.rowText(absoluteRow: r).text.hasPrefix("marker2") { target = r }
        var controller = SelectionController()
        _ = controller.replace(with: Selection(anchor: AbsolutePosition(row: target, col: 0),
                                               head: AbsolutePosition(row: target, col: 7),
                                               mode: .character), in: t)
        t.resize(cols: 20, rows: 8)
        _ = controller.invalidateIfStale(t)
        let kept = try? #require(controller.selection)
        #expect(kept.map { t.text(in: $0) } == "marker2")
    }

    /// A reflow whose result no longer fits the ring drops its oldest rows -- an eviction by
    /// another name, and counted as one, so what survives goes on covering its own text.
    @Test func aReflowThatOverflowsTheRingCountsAsEviction() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 6)
        for i in 0..<8 { t.feed("line\(i) abcdefghijkl\r\n") }
        let before = t.evictedRows
        // Eighteen characters at six columns is three rows apiece: the rewrapped buffer is far
        // longer than the six rows the ring can hold.
        t.resize(cols: 6, rows: 4)
        #expect(t.evictedRows > before)
    }

    /// The same shift, handled: a fold is keyed by command id rather than by row, so `prune` only
    /// has to compare ids against the oldest one still in the buffer -- no row read needed, and no
    /// chance of a fold surviving onto whatever text slid into its old index.
    @Test func aFoldOnAnEvictedCommandIsDropped() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 4)
        func markSeq(_ letter: String, _ status: Int32? = nil) -> String {
            "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
        }
        t.feed(markSeq("A") + "$" + markSeq("B") + "one\r\n" + markSeq("C") + "1\r\n" + markSeq("D", 0))
        t.feed(markSeq("A") + "$" + markSeq("B") + "two\r\n" + markSeq("C") + "2\r\n" + markSeq("D", 0))
        var folding = OutputFolding()
        folding.fold(1, .all)
        folding.fold(2, .all)
        // Two more lines push the ring past capacity, evicting the first command's prompt row for
        // good -- the second command's is still held.
        t.feed("row0\r\nrow1\r\n")
        #expect(t.oldestCommandID == 2)
        folding.prune(olderThan: t.oldestCommandID)
        #expect(!folding.isFolded(1))
        #expect(folding.isFolded(2))
    }

    /// `scrollback-lines = 0` is a value the parser accepts, and `Scrollback`'s subscript divides
    /// by `buffer.count`. Nothing that reads the buffer may reach it with an empty ring.
    @Test func zeroScrollbackLinesIsSurvivable() {
        let t = Terminal(cols: 10, rows: 3, scrollbackLimit: 0)
        for i in 0..<50 { t.feed("line \(i)\r\n") }
        #expect(t.scrollback.count == 0)
        #expect(t.totalRows == 3)
        t.scrollViewport(by: 5)
        #expect(t.viewportTopRow == 0)

        var selection = SelectionController()
        _ = selection.selectAll(in: t)
        if let made = selection.selection { _ = t.text(in: made) }
        var search = BufferSearch()
        search.search("line", in: t)
        _ = t.transcript(options: .plainText)
    }

    /// A one-column, one-row terminal fed a wide glyph: the smallest grid anything can be asked to
    /// draw, and `Terminal` clamps it to two columns rather than dividing by a zero-width cell.
    @Test func theSmallestPossibleGrid() {
        let t = Terminal(cols: 1, rows: 1, scrollbackLimit: 5)
        t.feed("abc\r\ndef\r\n")
        t.feed("\u{1b}[H\u{1b}[2J")
        t.feed("\u{1F600}")
        _ = t.transcript(options: .plainText)
        t.resize(cols: 1, rows: 1)
        #expect(t.cols == 2)
        #expect(t.rows == 1)
    }
}
