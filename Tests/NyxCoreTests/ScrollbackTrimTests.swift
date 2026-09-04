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

    /// The same shift, handled: a fold is an absolute prompt row, and `prune` drops one whose row
    /// no longer carries a prompt mark. This is the behaviour the selection is missing.
    @Test func foldsAreDroppedWhenTheirPromptRowMovesAway() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 5)
        var folding = OutputFolding()
        folding.toggle(promptRow: 2)
        #expect(!folding.isEmpty)
        for i in 0..<10 { t.feed("row\(i)\r\n") }
        folding.prune(in: t)
        #expect(folding.isEmpty)
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
