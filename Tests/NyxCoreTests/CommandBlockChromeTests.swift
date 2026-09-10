import Testing
@testable import NyxCore

private func header(summary: String = "8.8s", state: BlockHeader.State = .finished,
                    folded: Bool = false, hasOutput: Bool = true,
                    http: HTTPSummary? = nil, isHTTP: Bool = false,
                    lens: ResponseLens? = nil, lensTooLarge: Bool = false, json: Bool = false,
                    watch: WatchHeader? = nil) -> BlockHeader {
    BlockHeader(id: 7, state: state, folded: folded, hasOutput: hasOutput, anyFolds: false,
                notifyArmed: false, summary: summary, httpSummary: http, isHTTP: isHTTP,
                lens: lens, lensTooLarge: lensTooLarge, bodyIsJSON: json, watch: watch)
}

private func pills(_ h: BlockHeader, _ w: CommandBlockChrome.WidthClass) -> [CommandBlockChrome.Pill] {
    CommandBlockChrome.stripContent(h, at: w)?.pills ?? []
}

private func readout(_ h: BlockHeader, _ w: CommandBlockChrome.WidthClass) -> String {
    CommandBlockChrome.stripContent(h, at: w)?.readout ?? ""
}

// MARK: - Width classes

/// The four boundaries of §2.6, from both sides. A free-column count is what the whole table is
/// indexed by, so an off-by-one here silently draws the wrong strip on every block in the pane.
@Test func theWidthClassBoundariesAreExact() {
    #expect(CommandBlockChrome.widthClass(freeColumns: 34) == .w3)
    #expect(CommandBlockChrome.widthClass(freeColumns: 33) == .w2)
    #expect(CommandBlockChrome.widthClass(freeColumns: 18) == .w2)
    #expect(CommandBlockChrome.widthClass(freeColumns: 17) == .w1)
    #expect(CommandBlockChrome.widthClass(freeColumns: 8) == .w1)
    #expect(CommandBlockChrome.widthClass(freeColumns: 7) == .w0)
    #expect(CommandBlockChrome.widthClass(freeColumns: 0) == .w0)
    #expect(CommandBlockChrome.widthClass(freeColumns: -3) == .w0)
}

/// D19: `Renderer.lastUsed` stops at the last cell with content, and the second half of a wide
/// glyph has none -- so a command line ending in 世 was counted one column short and the strip
/// began on top of it.
@Test func aTrailingWideCellCountsItsSpacer() {
    var row = Row(cols: 10)
    var lead = Cell(); lead.content = 0x4E16; lead.attrs.insert(.wide)
    var spacer = Cell(); spacer.attrs.insert(.wideSpacer)
    row.cells[4] = lead
    row.cells[5] = spacer
    #expect(CommandBlockChrome.lastUsedColumn(of: row) == 5)
    #expect(CommandBlockChrome.freeColumns(cols: 10, lastUsedColumn: 5) == 4)
    #expect(CommandBlockChrome.lastUsedColumn(of: Row(cols: 10)) == -1)
    #expect(CommandBlockChrome.freeColumns(cols: 10, lastUsedColumn: -1) == 10)
}

// MARK: - §2.6's table, row by row
//
// Every cell of the table in the spec, asserted here. These are the tests the two ladders exist to
// pass: the ladder text in `findings-design` §3.3 contradicts its own table, and the ruling is that
// the table is what ships.

@Test func theTableHoveredFinished() {
    let h = header(summary: "8.8s")
    #expect(pills(h, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(CommandBlockChrome.stripContent(h, at: .w0) == nil)
    #expect(readout(h, .w3) == "8.8s")
    #expect(readout(h, .w1) == "8.8s")
}

@Test func theTableHoveredFailed() {
    let h = header(summary: "exit 1 · 8.8s", state: .failed(status: 1))
    #expect(pills(h, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(readout(h, .w3) == "exit 1 · 8.8s")
    #expect(readout(h, .w2) == "exit 1 · 8.8s")
    #expect(readout(h, .w1) == "exit 1")
    #expect(CommandBlockChrome.stripContent(h, at: .w1)?.readoutTone == .failure)
}

@Test func theTableHoveredRunning() {
    let h = header(summary: "12s", state: .running(elapsed: 12))
    #expect(pills(h, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(readout(h, .w1) == "12s")
}

/// Folded keeps `Unfold` past `Copy`: the pill says what the block currently is, and Copy is the
/// one control the ⋯ menu certainly still carries.
@Test func theTableFolded() {
    let h = header(summary: "8.8s", folded: true)
    #expect(pills(h, .w3) == [.fold(.unfold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.fold(.unfold), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
}

@Test func theTableHTTP() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms · 1.2 KB · json", tone: .success),
                   isHTTP: true, json: true)
    #expect(pills(h, .w3) == [.lens(name: "Raw", on: false), .fold(.fold),
                              .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.lens(name: "Raw", on: false), .actions(.labelled)])
    // The chip outlives `Fold` and `Copy`, so it is still on the strip at W1: it is the lens's only
    // visible state, and `Copy Output` is a row of the ⋯ menu. Before this ruling W1 was `[⋯]` and
    // the chip appeared in no composite of the whole set -- the strip a person actually gets on a
    // pasted `curl` is a rung or two down from W3, and the chip was always the first thing to go.
    #expect(pills(h, .w1) == [.lens(name: "Raw", on: false), .actions(.glyph)])
    #expect(pills(h, .w0) == [])
    #expect(readout(h, .w3) == "200 · 142 ms · 1.2 KB · json")
    #expect(readout(h, .w2) == "200 · 142 ms")
    #expect(readout(h, .w1) == "200")
}

/// A lens already open lights the chip and names itself; the body no longer has to be JSON, because
/// the chip is also how the reader gets back out.
@Test func theTableLensed() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                   isHTTP: true, lens: .pretty, json: true)
    #expect(pills(h, .w3).first == .lens(name: "Pretty", on: true))
    let raw = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                     isHTTP: true, lens: .raw, json: false)
    #expect(pills(raw, .w3).first == .lens(name: "Raw", on: true))
    // Nothing a lens can do anything with, and none open: no chip at all rather than an inert one.
    let big = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                     isHTTP: true, lensTooLarge: true, json: true)
    #expect(pills(big, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
}

/// Stop is present at every width, and a watched block never takes the lens chip -- the two would
/// be competing for the one rung under Actions, and the lens stays in the menu.
@Test func theTableWatchedRunning() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 100 ms", tone: .success),
                   isHTTP: true, json: true,
                   watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                      dots: [.success, .success, .success, .running],
                                      showsStop: true, tone: .success))
    // No `Copy` on a watched block at any width: the dots outlive it. A timeline is the series'
    // whole shape and `Copy Output` is a row of the ⋯ menu, so the strip spends its columns on the
    // reading rather than on a second route to the pasteboard.
    #expect(pills(h, .w3) == [.stop, .actions(.labelled)])
    #expect(pills(h, .w2) == [.stop, .actions(.labelled)])
    #expect(pills(h, .w1) == [.stop, .actions(.glyph)])
    #expect(pills(h, .w0) == [.stop])
    // "Stop" alone collides with ⌘.'s differently-scoped Stop (a11y 6.9): VoiceOver has to hear
    // what this one stops, the same words as the tooltip.
    #expect(CommandBlockChrome.Pill.stop.accessibilityLabel == "Stop watching this request")
    #expect(CommandBlockChrome.Pill.stop.accessibilityLabel == CommandBlockChrome.Pill.stop.help)
    #expect(readout(h, .w3) == "run 12 · 200 · 100 ms · every 5 s")
    #expect(readout(h, .w2) == "run 12 · 200")
    #expect(readout(h, .w1) == "run 12")
    #expect(readout(h, .w0) == "")
    // The timeline is the widest thing here and goes at the first squeeze.
    #expect(CommandBlockChrome.stripContent(h, at: .w3)?.dots.count == 4)
    #expect(CommandBlockChrome.stripContent(h, at: .w2)?.dots.isEmpty == true)
}

/// `+N` replaces the leading dot rather than sitting beside a full thirty: the timeline is capped
/// at thirty marks, not thirty-one.
@Test func theOverflowMarkReplacesTheLeadingDotRatherThanJoiningIt() {
    let dots: [WatchSeries.Dot] = Array(repeating: .success, count: 30)
    let h = header(summary: "", isHTTP: true,
                   watch: WatchHeader(text: "run 48 · 200 · 100 ms · every 1 s", dots: dots,
                                      showsStop: true, tone: .success, hiddenRuns: 18))
    let content = CommandBlockChrome.stripContent(h, at: .w3)
    #expect(content?.dots.count == 29)
    #expect(content?.overflowDot == "+18")
    // No cap, no replacement: all thirty stay.
    let uncapped = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 4 · 200 · 100 ms · every 1 s", dots: dots,
                                             showsStop: true, tone: .success))
    #expect(CommandBlockChrome.stripContent(uncapped, at: .w3)?.dots.count == 30)
    #expect(CommandBlockChrome.stripContent(uncapped, at: .w3)?.overflowDot == nil)
}

/// A finished series keeps its failure count when it drops its percentiles: "11 runs" alone reads
/// as a series that went fine.
@Test func theTableWatchedFinished() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                   isHTTP: true, json: true,
                   watch: WatchHeader(text: "11 runs · p50 140 ms · p95 190 ms · 2 failures",
                                      dots: [.success, .failure], showsStop: false, tone: .failure))
    // `Copy` drops before the dots here too, so a finished series' W3 strip is its timeline, its
    // sentence and `Actions ▾`.
    #expect(pills(h, .w3) == [.actions(.labelled)])
    #expect(pills(h, .w2) == [.actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(CommandBlockChrome.stripContent(h, at: .w0) == nil)
    #expect(readout(h, .w2) == "11 runs · 2 failures")
    #expect(readout(h, .w1) == "11 runs")
}

@Test func theTableNoOutput() {
    let h = header(summary: "8.8s", hasOutput: false)
    #expect(pills(h, .w3) == [.actions(.labelled)])
    #expect(pills(h, .w2) == [.actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(CommandBlockChrome.stripContent(h, at: .w0) == nil)
}

/// The two invariants §2.6 states in words, over every row of the table at every width.
@Test func stopAndActionsAndTheStatusAreNeverDropped() {
    let watched = header(summary: "", http: HTTPSummary(text: "200", tone: .success), isHTTP: true,
                         json: true,
                         watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                            dots: [.running], showsStop: true, tone: .success))
    for width in [CommandBlockChrome.WidthClass.w3, .w2, .w1, .w0] {
        #expect(pills(watched, width).contains(.stop), "\(width)")
    }
    for h in [header(summary: "exit 1 · 8.8s", state: .failed(status: 1)),
              header(summary: "8.8s"), header(summary: "8.8s", folded: true),
              header(summary: "8.8s", hasOutput: false)] {
        for width in [CommandBlockChrome.WidthClass.w3, .w2, .w1] {
            let list = pills(h, width)
            #expect(list.contains(.actions(.labelled)) || list.contains(.actions(.glyph)), "\(width)")
            // Whatever the strip says, it says the status: the summary it suppresses said no more.
            #expect(!readout(h, width).isEmpty, "\(width)")
        }
    }
}

/// `Actions ▾` stays labelled through the W3→W2 boundary -- where `Fold` is already dropped, per
/// `theTableHoveredFinished` -- and only collapses to `⋯` at the later W2→W1 boundary.
@Test func actionsOnlyCollapsesAtTheW1Boundary() {
    let h = header(summary: "8.8s")
    #expect(pills(h, .w3).last == .actions(.labelled))
    #expect(pills(h, .w2).last == .actions(.labelled))
    #expect(pills(h, .w1).last == .actions(.glyph))
}

// MARK: - Where the strip begins

@Test func theStripIsRightAlignedAfterTheLastGlyph() throws {
    let content = try #require(CommandBlockChrome.stripContent(header(summary: "8.8s"), at: .w3))
    let plan = CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 20,
                                            cols: 80, stripColumns: 30)
    #expect(plan?.firstColumn == 50)
    #expect(plan?.overlapsCommand == false)
}

/// Never inside a word: a strip whose leading column would land on the command's own text is no
/// strip at all, and the gutter still folds.
@Test func aStripThatWouldBeginInsideAWordIsRefused() throws {
    let content = try #require(CommandBlockChrome.stripContent(header(summary: "8.8s"), at: .w3))
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 55,
                                         cols: 80, stripColumns: 30) == nil)
    // Touching is still colliding: the first free column is `lastUsedColumn + 1`.
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 50,
                                         cols: 80, stripColumns: 30) == nil)
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 49,
                                         cols: 80, stripColumns: 30)?.firstColumn == 50)
}

/// The one exception: the lone Stop of the W0 row, over the tail of the command, on an opaque pill.
@Test func onlyTheW0StopOverlapsTheCommand() throws {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.running], showsStop: true, tone: .success))
    let content = try #require(CommandBlockChrome.stripContent(watching, at: .w0))
    let plan = CommandBlockChrome.stripPlan(content, widthClass: .w0, lastUsedColumn: 79,
                                            cols: 80, stripColumns: 8)
    #expect(plan?.overlapsCommand == true)
    #expect(plan?.firstColumn == 72)
    #expect(plan?.pills == [.stop])
}

/// A strip wider than the pane hangs off the left edge: no strip, at any width class.
@Test func aStripWiderThanThePaneIsRefused() throws {
    let content = try #require(CommandBlockChrome.stripContent(header(summary: "8.8s"), at: .w3))
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: -1,
                                         cols: 20, stripColumns: 21) == nil)
}

/// The placement walks the command's rows from the last upwards, the way the summary does: a
/// wrapped `curl` fills its first rows and leaves room on its last.
@Test func thePlacementTakesTheLowestRowWithRoom() {
    let h = header(summary: "8.8s")
    let placement = CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 9), (absoluteRow: 5, lastUsedColumn: 78)],
        cols: 80, summary: nil, measure: { _ in 20 })
    #expect(placement?.row == 4)
    #expect(placement?.plan.firstColumn == 60)
}

/// §2.5's hard case: a wrapped watched command whose last row is full puts its lone `Stop` there,
/// and the summary belongs on the row above -- so the strip does **not** speak for it, and hovering
/// must not take `run 12 · 200 · 100 ms · every 5 s` off the screen.
@Test func aW0StopDoesNotSpeakForTheSummaryOnAnotherRow() throws {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.running], showsStop: true, tone: .success))
    let rows = [(absoluteRow: 4, lastUsedColumn: 10), (absoluteRow: 5, lastUsedColumn: 79)]
    let placement = try #require(CommandBlockChrome.stripPlacement(
        watching, commandRows: rows, cols: 80, summary: nil,
        measure: { $0.pills == [.stop] ? 8 : 60 }))
    #expect(placement.row == 5)
    #expect(placement.plan.pills == [.stop])
    let summaryRow = CommandBlockChrome.summaryPlacement(commandRows: rows, textCount: 32,
                                                         cols: 80)?.row
    #expect(summaryRow == 4)
    #expect(!CommandBlockChrome.suppressesSummary(
        placement.plan, stripRow: placement.row,
        summary: summaryRow.map { (row: $0, text: watching.summary) }))
    // …and a strip that did land on the summary's own row, with something to say, speaks for it:
    // two sentences on one row is the row saying the same thing twice.
    let onTheRow = try #require(CommandBlockChrome.stripPlacement(
        watching, commandRows: [rows[0]], cols: 80, summary: nil, measure: { _ in 60 }))
    #expect(CommandBlockChrome.suppressesSummary(onTheRow.plan, stripRow: onTheRow.row,
                                                 summary: (row: 4, text: watching.summary)))
}

/// No row with room and nothing to stop: no strip anywhere, which is what keeps the in-grid summary
/// on screen (§2.5).
@Test func noRoomAnywhereMeansNoStrip() {
    let h = header(summary: "8.8s")
    #expect(CommandBlockChrome.stripPlacement(h,
        commandRows: [(absoluteRow: 4, lastUsedColumn: 79)], cols: 80, summary: nil,
        measure: { _ in 20 }) == nil)
    #expect(CommandBlockChrome.stripPlacement(h, commandRows: [], cols: 80, summary: nil,
                                              measure: { _ in 20 }) == nil)
}

// MARK: - The spine's rows

/// The prompt row belongs to the cap, and the spine begins under it.
///
/// The spine used to be painted over the prompt row as well. It is the same colour, the same width
/// and at the same x as the cap that goes there, so it filled in `.hollow`'s ring and `.faded`'s
/// 40 % and both read as a solid bar: the *shape* that §2.2 makes carry the state survived only in
/// the isolated `gutter-marks-*` picture, and in the pane -- the only place anyone sees it -- a
/// running command looked exactly like a finished one.
@Test func theSpineBeginsBelowTheCapsOwnRow() {
    #expect(CommandBlockChrome.spineRows(placed: 3..<8, headOnScreen: true) == 4..<8)
    // A one-row block is nothing but its prompt row: the cap is the whole mark, and there is no
    // spine to draw. A `.bar` failure still shows a full-row mark, because the cap draws that.
    #expect(CommandBlockChrome.spineRows(placed: 3..<4, headOnScreen: true) == nil)
    // Scrolled until the prompt row is above the viewport: the first row on screen is ordinary
    // output with no cap over it, so it keeps its spine -- otherwise a block loses its left edge
    // exactly when it is long enough to need one.
    #expect(CommandBlockChrome.spineRows(placed: 0..<8, headOnScreen: false) == 0..<8)
    #expect(CommandBlockChrome.spineRows(placed: 5..<5, headOnScreen: false) == nil)
}

// MARK: - The gutter cap

@Test func theCapShapesCarryTheState() {
    let done = CommandBlockChrome.gutterCap(header(summary: "8.8s"), hasStarted: true, hovered: false)
    #expect(done?.shape == .solid)
    #expect(done?.tone == .success)
    #expect(done?.isPressable == true)
    let failed = CommandBlockChrome.gutterCap(header(summary: "exit 1", state: .failed(status: 1)),
                                              hasStarted: true, hovered: false)
    #expect(failed?.shape == .bar)
    #expect(failed?.tone == .failure)
    let running = CommandBlockChrome.gutterCap(header(summary: "12s", state: .running(elapsed: 12)),
                                               hasStarted: true, hovered: false)
    #expect(running?.shape == .hollow)
    #expect(running?.tone == .running)
    // A command that printed nothing: a record, at 40 % alpha, and not a button.
    let quiet = CommandBlockChrome.gutterCap(header(summary: "8.8s", hasOutput: false),
                                             hasStarted: true, hovered: false)
    #expect(quiet?.shape == .faded)
    #expect(quiet?.isPressable == false)
    // `hasOutput` must not erase what the command is *doing*: a `sleep 10` one second in, or a
    // failure that printed nothing before it died, are still news -- only a block that finished
    // cleanly with nothing to fold gets the quiet `.faded` record above.
    let runningQuiet = CommandBlockChrome.gutterCap(header(summary: "1s", state: .running(elapsed: 1),
                                                           hasOutput: false),
                                                    hasStarted: true, hovered: false)
    #expect(runningQuiet?.shape == .hollow)
    #expect(runningQuiet?.isPressable == false)
    let failedQuiet = CommandBlockChrome.gutterCap(header(summary: "exit 1", state: .failed(status: 1),
                                                          hasOutput: false),
                                                   hasStarted: true, hovered: false)
    #expect(failedQuiet?.shape == .bar)
    #expect(failedQuiet?.isPressable == false)
    // The prompt being typed at has a prompt mark and has run nothing: no cap at all.
    #expect(CommandBlockChrome.gutterCap(header(summary: "", hasOutput: false),
                                         hasStarted: false, hovered: false) == nil)
}

@Test func hoveringTurnsTheCapIntoAChevron() {
    let open = CommandBlockChrome.gutterCap(header(summary: "8.8s"), hasStarted: true, hovered: true)
    #expect(open?.shape == .chevronDown)
    let folded = CommandBlockChrome.gutterCap(header(summary: "8.8s", folded: true),
                                              hasStarted: true, hovered: true)
    #expect(folded?.shape == .chevronRight)
    // Nothing to fold, nothing to promise: hovering a no-output mark changes nothing.
    let quiet = CommandBlockChrome.gutterCap(header(summary: "8.8s", hasOutput: false),
                                             hasStarted: true, hovered: true)
    #expect(quiet?.shape == .faded)
}

// MARK: - Geometry

/// The mark leaves the window's resize margin at the shipping padding and never leaves the window
/// at `padding = 0`, where it draws over the first text column's leading 3 points instead.
@Test func theSpineInsetMovesOffTheWindowEdge() {
    #expect(CommandBlockChrome.spineWidth == 3)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 0) == 0)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 3) == 0)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 8) == 4)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 64) == 4)
}

/// §8.4: every hit target that is one text row tall is 13 pt at `line-height = 0.8`. The floor is
/// on the target, never on the drawn mark.
@Test func theHitHeightIsFlooredAndTheDrawnMarkIsNot() {
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: 13) == 16)
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: 16) == 16)
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: 24) == 24)
    // Addendum 2: the strip's frame clears both floors; its painted ground stays one row tall, so
    // a 20 pt band cannot cover three rows of a `line-height 0.8` grid.
    #expect(CommandBlockChrome.stripFrameHeight(cellHeight: 13) == 20)
    #expect(CommandBlockChrome.stripFrameHeight(cellHeight: 24) == 24)
    #expect(CommandBlockChrome.stripGroundHeight(cellHeight: 13) == 13)
}

/// Column 0's triangle gets the same 20 pt the gutter gets, for the same reason: it is one cell
/// wide (about 8 pt) and one row tall (13 pt at `line-height 0.8`), which is not a target.
@Test func theFoldTriangleGetsTheSameTargetTheGutterHas() {
    #expect(CommandBlockChrome.foldColumnWidth == 20)
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: 13) == (width: 20, height: 16))
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: 24) == (width: 20, height: 24))
}

// MARK: - The two-stage placement, as the pane calls it

/// The whole point of the two-stage placement: the strip that is measured is the strip that is
/// drawn, and the row it lands on is chosen from the *measured* width rather than from a guess.
@Test func thePlacementMeasuresTheContentItPlaces() {
    let h = header(summary: "8.8s")
    var measured: [Int] = []
    let placement = CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 20)], cols: 80, summary: nil,
        measure: { content in measured.append(content.pills.count); return 24 })
    #expect(placement?.plan.firstColumn == 56)
    #expect(measured == [3])          // W3: Fold, Copy, Actions -- measured once
}

/// A watch on a full command line still gets its Stop, and only its Stop.
@Test func aFullCommandLineStillStopsAWatch() {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.running], showsStop: true, tone: .success))
    let placement = CommandBlockChrome.stripPlacement(
        watching, commandRows: [(absoluteRow: 4, lastUsedColumn: 79)], cols: 80, summary: nil,
        measure: { _ in 8 })
    #expect(placement?.plan.pills == [.stop])
    #expect(placement?.plan.overlapsCommand == true)
}

/// A width class is a budget, not a promise.
///
/// §2.6 puts the timeline, the sentence, `Stop` and `Actions` on a W3 watched block, and measured
/// that is sixty to seventy columns of strip -- while W3 begins at thirty-four free ones. Refusing
/// the row outright took `Stop`, the one control the table says is present at *every* width, off the
/// screen entirely; the composites named after the watch and the lens had no strip in them at all.
/// So a row walks down its own ladder until the strip fits, which is what the two ladders are for.
@Test func aRowTooNarrowForItsClassStepsDownTheLadder() {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.success, .running], showsStop: true,
                                             tone: .success))
    // Keyed on the timeline rather than the pill count: the dots are what makes a W3 watch strip
    // the widest thing this chrome draws, and since the F4 ruling took `Copy` off a watched block
    // the W3 and W2 rungs carry the same two pills.
    var tried: [Int] = []
    let placement = CommandBlockChrome.stripPlacement(
        watching, commandRows: [(absoluteRow: 4, lastUsedColumn: 30)], cols: 80, summary: nil,
        measure: { content in
            tried.append(content.dots.count)
            return content.dots.isEmpty ? 12 : 70
        })
    // W3 (49 free) is asked first and its timeline does not fit after the last glyph; W2 does.
    #expect(tried == [2, 0])
    #expect(placement?.plan.pills == [.stop, .actions(.labelled)])
    #expect(placement?.plan.firstColumn == 68)
    // A rung that fits keeps its own class's placement: the strip sits after the last glyph rather
    // than on it, because there was room for it there.
    #expect(placement?.plan.overlapsCommand == false)
    // With no rung fitting at all the ladder reaches the overlap rung, which carries the two pills
    // §2.6 never drops -- `Stop` while a watch runs and `Actions` collapsed to the glyph -- on the
    // command's own tail. Asserted in full by `theLastRungIsOverTheCommandsTailAtAnyWidth`.
    let noRoomAtAll = CommandBlockChrome.stripPlacement(
        watching, commandRows: [(absoluteRow: 4, lastUsedColumn: 30)], cols: 80, summary: nil,
        measure: { _ in 60 })
    #expect(noRoomAtAll?.plan.pills == [.stop, .actions(.glyph)])
    #expect(noRoomAtAll?.plan.overlapsCommand == true)
}


// MARK: - §2.5: a strip may only replace a summary it repeats word for word

/// A column count in the shape the view really measures: the sentence at one column a character,
/// the dots at one each, a labelled pill at eight and a glyph pill at four, plus the insets.
private func columns(_ content: CommandBlockChrome.StripContent) -> Int {
    3 + content.readout.count + content.dots.count
        + content.pills.reduce(0) { $0 + ($1.glyph == nil ? 8 : 4) }
}

/// The lens row of the composites. `200 · 142 ms · 1.2 KB · json` fits in the grid, so the strip may
/// not put `200 · 142 ms` there instead: on a row that is already showing the sentence the readout
/// stops at the sentence and the *pills* give way, down to the one that reaches every action.
@Test func aStripOnTheSummarysRowKeepsTheWholeSentence() throws {
    let sentence = "200 · 142 ms · 1.2 KB · json"
    let h = header(summary: "", http: HTTPSummary(text: sentence, tone: .success),
                   isHTTP: true, json: true)
    let placement = try #require(CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 44)], cols: 84,
        summary: (row: 4, text: sentence), measure: columns))
    #expect(placement.plan.readout == sentence)
    #expect(placement.plan.pills == [.actions(.glyph)])
    #expect(placement.plan.firstColumn == 49)
    // …and only then may it take the summary's place.
    let placed = CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                      summary: (row: 4, text: sentence))
    #expect(placed)
    // The same row with no summary on it is free to shorten: nothing is being replaced.
    let free = try #require(CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 44)], cols: 84, summary: nil,
        measure: columns))
    #expect(free.plan.readout == "200 · 142 ms")
    #expect(free.plan.pills == [.lens(name: "Raw", on: false), .actions(.labelled)])
}

/// The 30-run watch row: the sentence plus even the narrowest pills is wider than the row, and
/// wider still than the gap the sentence leaves, so the strip is the last rung -- `Stop` alone over
/// the command's tail -- and `run 31 · 200 · 170 ms · every 5 s` stays exactly where it was.
///
/// Hovering a block may cost the pills; it may never cost a fact, and it may never cost the `Stop`
/// either. Before the F1 ruling this row got no strip at all, and a running watch on a command line
/// of this length could not be stopped with the mouse from anywhere.
@Test func aStripThatCannotCarryTheSentenceKeepsBothTheSentenceAndTheStop() throws {
    let sentence = "run 31 · 200 · 170 ms · every 5 s"
    let h = header(summary: "", http: HTTPSummary(text: "200 · 170 ms", tone: .success),
                   isHTTP: true, json: true,
                   watch: WatchHeader(text: sentence, dots: Array(repeating: .success, count: 30),
                                      showsStop: true, tone: .success))
    let placement = try #require(CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 44)], cols: 84,
        summary: (row: 4, text: sentence), measure: columns))
    #expect(placement.plan.pills == [.stop, .actions(.glyph)])
    #expect(placement.plan.overlapsCommand)
    // The readout is dropped *because* the grid is carrying the sentence on this very row; the
    // rung that fires where it is not keeps it (design D2, `aWatchedBlockAtW1KeepsItsReadout`).
    #expect(placement.plan.readout == "")
    // The sentence is not spoken for, so the in-grid summary stays on the row.
    #expect(!CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                  summary: (row: 4, text: sentence)))
    // Without the sentence to protect -- the summary went on another row -- the ladder shortens as
    // before, and `Stop` survives.
    let elsewhere = CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 44)], cols: 84,
        summary: (row: 9, text: sentence), measure: columns)
    #expect(elsewhere?.plan.pills == [.stop, .actions(.labelled)])
    #expect(elsewhere?.plan.readout == "run 31 · 200")
}

/// A row that had no space for the whole sentence carries none of it, so there is nothing for the
/// strip to repeat -- and nothing it can speak for either. (`suppressesSummary` keeps the empty-text
/// guard because a `PlacedSummary` is a tuple any caller can build, not because a placement can be
/// empty: `summaryPlacement` refuses a row rather than shortening the sentence on it.)
@Test func aSummaryThatDidNotFitProtectsNothingAndIsNotSpokenFor() throws {
    let h = header(summary: "8.8s")
    let placement = try #require(CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 40)], cols: 84,
        summary: (row: 4, text: ""), measure: columns))
    #expect(placement.plan.readout == "8.8s")
    #expect(!CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                  summary: (row: 4, text: "")))
}

// MARK: - The lens chip

/// The chip names the lens rather than drawing `{ }`, and it names the one that is *on* -- a chip
/// reading `Pretty` beside a response being read through `Headers` is the control lying about the
/// thing it controls.
/// Review round 1 (I3): the chip is a state readout whose `▾` opens choices, not a suggestion of
/// what pressing it would switch to -- an unlensed response is *already* showing raw, so the chip
/// reads `Raw` unlit, not `Pretty`.
@Test func theChipNamesTheLensThatIsOn() {
    func chip(_ lens: ResponseLens?) -> CommandBlockChrome.Pill? {
        let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                       isHTTP: true, lens: lens, json: true)
        return CommandBlockChrome.pills(h, at: .w3).first
    }
    #expect(chip(nil) == .lens(name: "Raw", on: false))
    #expect(chip(.raw) == .lens(name: "Raw", on: true))
    #expect(chip(.pretty) == .lens(name: "Pretty", on: true))
    #expect(chip(.headers) == .lens(name: "Headers", on: true))
    #expect(chip(.body) == .lens(name: "Body", on: true))
    #expect(chip(.grep("alpha")) == .lens(name: "Find", on: true))
    // The chevron says a menu opens; every chip carries one, because every lens has neighbours.
    #expect(CommandBlockChrome.Pill.lens(name: "Raw", on: false).trailingChevron)
}

/// The 16 pt floor has to be real on the *click*, not only on the pointing hand.
///
/// The band is the whole point of the floor: at `line-height = 0.8` a row is 13 pt and the target is
/// 16, so it overhangs its row by 1.5 pt top and bottom. A click path that divided the point by the
/// cell height instead -- which is what `Pane.visibleRow(at:)` does, correctly, for text -- put the
/// hand and the click in different places in that band: the pointer said "control" and the click
/// moved the caret on the row above.
@Test func aFoldTargetIsHitThroughoutItsSixteenPointBand() {
    // Rows of 13 pt from a padding of 8: row 2 spans y 34…47 and its target y 32.5…48.5.
    func hit(_ y: Double) -> Int? {
        CommandBlockChrome.hitRow(atY: y, cellHeight: 13, padding: 8, hitHeight: 16, rows: [2, 5])
    }
    #expect(hit(40.5) == 2)          // the centre
    #expect(hit(33) == 2)            // 1 pt above the row's own top edge
    #expect(hit(48) == 2)            // 1 pt below its own bottom edge
    #expect(hit(32) == nil)          // past the target
    #expect(hit(49) == nil)
    // Two targets whose bands overlap -- adjacent rows -- go to the nearer centre, and an exact tie
    // to the upper row, so the answer never depends on the order the rows arrive in.
    func adjacent(_ y: Double) -> Int? {
        CommandBlockChrome.hitRow(atY: y, cellHeight: 13, padding: 8, hitHeight: 16, rows: [3, 2])
    }
    // Centres are 40.5 and 53.5, so 47 is the exact tie and 48 is nearer the lower row's centre.
    #expect(adjacent(47) == 2)
    #expect(adjacent(48) == 3)
    #expect(CommandBlockChrome.hitRow(atY: 40, cellHeight: 0, padding: 8, hitHeight: 16, rows: [2]) == nil)
    #expect(CommandBlockChrome.hitRow(atY: 40, cellHeight: 13, padding: 8, hitHeight: 16, rows: []) == nil)
}

// MARK: - §8.4 and Addendum 2: the floor, in one place

/// §8.4, in one place: at `line-height = 0.8` every one-row target is 13 pt, and every one of them
/// goes through the same clamp. A config value cannot take the floor away.
@Test func everyOneRowTargetClearsSixteenPointsAtTheSmallestRow() {
    let cell = 13.0                 // 13 pt is a 16 pt font at `line-height = 0.8`
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: cell) == 16)
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: cell).height == 16)
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: cell).width == 20)
    #expect(CommandBlockChrome.stripFrameHeight(cellHeight: cell) == 20)
    #expect(PromptGutter.hitWidth == 20)
    // …and the *drawn* things are not clamped, or the marks go lumpy and two blocks' marks collide
    // (the ruling in §2.2 against `findings-design` §3.2).
    #expect(CommandBlockChrome.stripGroundHeight(cellHeight: cell) == 13)
}

/// Addendum 2: a 20 pt opaque band on a 13 pt grid covers three rows of somebody's output. The
/// frame may be 20 pt -- `hitTest` rejects anything outside it -- but what it *paints* is one row.
/// **D3/F6.** The pinned band obeys the same pair, and it is the same two functions: what it paints
/// is one terminal row, what it catches is `hitRowHeight`.
///
/// Its ground and its divider used to fill the *frame*, which is 16 pt over a 13 pt row at
/// `line-height = 0.8` -- so the band overhung its own row by 1.5 pt at each end and the divider,
/// pinned to the frame's bottom, was drawn **through** the row below: at 10× the design review
/// watched it cross the top-left of a `[` and the upper strokes of `日本語`. §2.2 had already ruled
/// on this shape for the gutter mark two sections earlier in the spec, so no new decision was
/// needed -- only the same one, applied.
@Test func theStickyBandPaintsOneRowAndCatchesTheHitFloor() {
    for cell in [13.0, 15.5, 17, 22] {
        #expect(CommandBlockChrome.stripGroundHeight(cellHeight: cell) == cell)
        #expect(CommandBlockChrome.hitRowHeight(cellHeight: cell) >= 16)
        #expect(CommandBlockChrome.hitRowHeight(cellHeight: cell) >= cell)
    }
    // The overhang the floor buys, at the configuration §8.4 was written for: 1.5 pt at each end,
    // which the band may be *clicked* in and must not *paint* in.
    #expect((CommandBlockChrome.hitRowHeight(cellHeight: 13)
             - CommandBlockChrome.stripGroundHeight(cellHeight: 13)) / 2 == 1.5)
}

@Test func theStripPaintsOneRowHoweverTallItsFrameIs() {
    for cell in [13.0, 16, 17, 24] {
        #expect(CommandBlockChrome.stripGroundHeight(cellHeight: cell) == cell, "\(cell)")
        #expect(CommandBlockChrome.stripFrameHeight(cellHeight: cell) >= 20, "\(cell)")
    }
}

/// `padding = 0` is a shipped setting. The gutter's target does not depend on the padding at all,
/// and the mark moves onto the first text column's leading edge rather than off the window.
@Test func zeroPaddingKeepsBothTheTargetAndTheMark() {
    #expect(PromptGutter.hitWidth == 20)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 0) == 0)
    #expect(CommandBlockChrome.spineWidth == 3)
}

// MARK: - F1: a watch is always stoppable, and a strip that cannot carry the sentence carries pills

/// The invariant, and the sentence §2.6 writes it in: "`Stop` and `Actions` are present at every
/// width", because a watch you cannot stop from the strip is the one control here with a running
/// side effect.
///
/// It was not true. Refusing a row whose sentence-plus-pills does not fit left a running watch with
/// no strip at all across a wide middle band of command-line lengths -- measured in the built app at
/// 24 and 12 free columns, and in the composites at 40 and 12. So the placement gained the two rungs
/// this ruling names: pills alone in the gap the in-grid summary leaves, and then `Stop` alone over
/// the command's tail, which is the W0 exception granted at any width for the one pill that has to
/// be one click away.
@Test func aRunningWatchAlwaysHasAStopPillAtEveryWidth() throws {
    let sentence = "run 12 · 200 · 100 ms · every 5 s"
    let watching = header(summary: sentence, isHTTP: true,
                          watch: WatchHeader(text: sentence, dots: [.success, .running],
                                             showsStop: true, tone: .success))
    let cols = 84
    // Comfortably inside each band (W3 ≥ 34, W2 18-33, W1 8-17, W0 < 8), never on a boundary.
    for free in [40, 24, 12, 4] {
        let rows = [(absoluteRow: 4, lastUsedColumn: cols - free - 1)]
        let summary = CommandBlockChrome.summaryPlacement(commandRows: rows,
                                                          textCount: sentence.count, cols: cols)
        let placement = try #require(CommandBlockChrome.stripPlacement(
            watching, commandRows: rows, cols: cols,
            summary: summary.map { (row: $0.row, text: sentence) },
            measure: columns), "free=\(free)")
        #expect(placement.plan.pills.contains(.stop),
                "free=\(free) drew \(placement.plan.pills)")
        // And whatever rung it landed on, the sentence is still somewhere: either the strip carries
        // it word for word, or the in-grid summary was left alone.
        #expect(placement.plan.readout == sentence
                || !CommandBlockChrome.suppressesSummary(
                    placement.plan, stripRow: placement.row,
                    summary: summary.map { (row: $0.row, text: sentence) }),
                "free=\(free) removed the sentence")
    }
}

/// The middle rung: the sentence plus the pills does not fit, so the strip carries the **pills
/// alone** and the in-grid summary stays exactly where it was. Nothing on the row moves when the
/// pointer arrives; controls simply appear in the gap between the command and the sentence.
///
/// Right-aligned against the *summary's* first column rather than the pane's edge, which is what
/// `trailingColumn` is for -- a pills-only strip drawn to the pane's edge would sit on the sentence
/// it exists to preserve.
@Test func aStripThatCannotCarryTheSentenceCarriesThePillsAlone() throws {
    let h = header(summary: "8.8s")
    let cols = 84
    let rows = [(absoluteRow: 4, lastUsedColumn: 60)]
    let summaryRow = try #require(CommandBlockChrome.summaryPlacement(commandRows: rows,
                                                                      textCount: 4, cols: cols))
    // The sentence and the pills together are wider than the row's 23 free columns; the pills
    // alone are not.
    let placement = try #require(CommandBlockChrome.stripPlacement(
        h, commandRows: rows, cols: cols, summary: (row: summaryRow.row, text: "8.8s"),
        measure: { $0.readout.isEmpty ? 15 : 30 }))
    #expect(placement.plan.readout == "")
    #expect(placement.plan.pills == [.copy(enabled: true), .actions(.labelled)])
    // The strip ends where the summary begins, and begins clear of the command's last glyph.
    #expect(placement.plan.trailingColumn == summaryRow.columns.lowerBound)
    #expect(placement.plan.firstColumn == summaryRow.columns.lowerBound - 15)
    #expect(placement.plan.firstColumn > 60)
    #expect(!placement.plan.overlapsCommand)
    // And it does not speak for the summary, so the sentence is not removed by hovering (§2.5).
    #expect(!CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                  summary: (row: summaryRow.row, text: "8.8s")))
}

/// With **no** summary on the row, dropping the readout would put the fact nowhere at all: the
/// pills-only rung is only safe because the grid is carrying the sentence beside it, and a row that
/// is not carrying it falls through to the overlap rung, which keeps the narrowest readout *and*
/// both pills and pays for them in columns of the command's own tail.
///
/// This is design D2. At 16 free columns `run 12 [Stop] [⋯]` measures 19, so three columns of the
/// command line go under an opaque ground -- the trade §2.6's W1 cell asks for in as many words
/// (`run 12 [Stop] [⋯]`), and the one the pictures showed as `[Stop] [⋯]` with no readout at all.
@Test func aWatchedRowWithNoSummaryKeepsItsReadoutOverTheCommandsTail() throws {
    let sentence = "run 12 · 200 · 100 ms · every 5 s"
    let watching = header(summary: sentence, isHTTP: true,
                          watch: WatchHeader(text: sentence, dots: [.running], showsStop: true,
                                             tone: .success))
    let cols = 84
    let rows = [(absoluteRow: 4, lastUsedColumn: cols - 16 - 1)]
    // The sentence needs 33 columns and this row has 16, so the summary went to another row.
    #expect(CommandBlockChrome.summaryPlacement(commandRows: rows, textCount: sentence.count,
                                                cols: cols) == nil)
    let placement = try #require(CommandBlockChrome.stripPlacement(
        watching, commandRows: rows, cols: cols, summary: nil, measure: columns))
    #expect(placement.plan.readout == "run 12")
    #expect(placement.plan.pills == [.stop, .actions(.glyph)])
    #expect(placement.plan.trailingColumn == cols)
    #expect(placement.plan.overlapsCommand)
    #expect(placement.plan.firstColumn <= rows[0].lastUsedColumn)
}

/// The last rung: nothing fits beside the command, so the strip goes over the command's tail on an
/// opaque ground, carrying the two pills §2.6 never drops and the narrowest readout.
///
/// §2.3 granted the tail to `Stop` and to nothing else, and the PM's P1 measured what that cost: a
/// hovered block whose leftover gap is smaller than a lone `⋯` drew **no controls at all** -- a
/// failed block at 14-18 free columns of 84, one in sixteen of them. A lone `⋯` is the route to
/// every action on the block, so it earns the same exception. A W0 row still gets nothing but
/// `Stop`, because `rungs` offers a W0 row no fallback at all.
@Test func theLastRungIsOverTheCommandsTailAtAnyWidth() throws {
    let sentence = "run 12 · 200 · 100 ms · every 5 s"
    let watching = header(summary: sentence, isHTTP: true,
                          watch: WatchHeader(text: sentence, dots: [.success, .running],
                                             showsStop: true, tone: .success))
    let rows = [(absoluteRow: 4, lastUsedColumn: 30)]     // 49 free: a W3 row
    let placement = try #require(CommandBlockChrome.stripPlacement(
        watching, commandRows: rows, cols: 80, summary: nil, measure: { _ in 60 }))
    #expect(placement.plan.pills == [.stop, .actions(.glyph)])
    #expect(placement.plan.overlapsCommand)
    // A finished block in the same spot gets its `⋯`, and only its `⋯`: the block still has a menu
    // of eight things to do to it, and the alternative measured in the pictures is a hovered block
    // with nothing on it (P1).
    let finished = try #require(CommandBlockChrome.stripPlacement(
        header(summary: "8.8s"), commandRows: rows, cols: 80, summary: nil, measure: { _ in 60 }))
    #expect(finished.plan.pills == [.actions(.glyph)])
    #expect(finished.plan.overlapsCommand)
    // A W0 row is the one place the table really does draw nothing: `pills(_:at: .w0)` is empty for
    // every state but a running watch, and `rungs` gives a W0 row no wider rung to fall back to.
    #expect(CommandBlockChrome.stripPlacement(header(summary: "8.8s"),
                                              commandRows: [(absoluteRow: 4, lastUsedColumn: 75)],
                                              cols: 80, summary: nil, measure: { _ in 60 }) == nil)
}

/// The last rung may sit on the *command's* tail and never on the sentence's. Placed at the pane's
/// own edge instead, the opaque `Stop` covered the end of the in-grid summary it was leaving in
/// place -- `run 12 · 200 · 100 ms · every 5 s` came out reading `run 12 · 200 · 100 ms · ev` with a
/// pill on top of it, which is precisely the fact-removal §2.5 exists to forbid, and the first take
/// of `composite-strip-w3-watch-running` is where it showed up.
@Test func theOverlappingStopSitsOnTheCommandAndNotOnTheSummary() throws {
    let sentence = "run 12 · 200 · 100 ms · every 5 s"
    let watching = header(summary: sentence, isHTTP: true,
                          watch: WatchHeader(text: sentence, dots: [.success, .running],
                                             showsStop: true, tone: .success))
    let cols = 84
    let rows = [(absoluteRow: 4, lastUsedColumn: 43)]          // 40 free: a W3 row
    let summary = try #require(CommandBlockChrome.summaryPlacement(commandRows: rows,
                                                                   textCount: sentence.count,
                                                                   cols: cols))
    let placement = try #require(CommandBlockChrome.stripPlacement(
        watching, commandRows: rows, cols: cols, summary: (row: summary.row, text: sentence),
        measure: columns))
    #expect(placement.plan.pills == [.stop, .actions(.glyph)])
    #expect(placement.plan.overlapsCommand)
    // It ends where the sentence begins, so no column of the sentence is covered…
    #expect(placement.plan.trailingColumn == summary.columns.lowerBound)
    // …and it does begin inside the command's own text, which is what it is allowed to overlap.
    #expect(placement.plan.firstColumn <= 43)
    #expect(!CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                  summary: (row: summary.row, text: sentence)))
}

// MARK: - D2/P1/P6: a hovered block always has a control, and never loses the fact

/// **P1.** Every tail position, every state: a hovered block that is wide enough for a strip at all
/// gets one, with at least one pill on it.
///
/// The PM measured the hole from the pictures: once the in-grid summary fits, §2.5 forces the strip
/// to repeat the sentence word for word, and the gap the sentence leaves (free − summary) is 1-5
/// columns -- smaller than a lone `⋯` at 40 pt. A failed block at 14-18 free columns of 84 got
/// `nil`: hovered, tinted, chevroned, and with nothing to press. One failed block in sixteen.
///
/// W0 is the deliberate hole and stays one: §2.6's W0 column is "no strip, the gutter cap alone",
/// and the only pill that may ever cost a column of somebody's command there is `Stop`.
@Test func everyTailPositionWideEnoughForAStripGetsOne() {
    let cols = 84
    let cases: [(String, BlockHeader)] = [
        ("finished", header(summary: "2.4s")),
        ("failed", header(summary: "exit 1 · 8.8s", state: .failed(status: 1))),
        ("running", header(summary: "12s", state: .running(elapsed: 12))),
        ("folded", header(summary: "8.8s", folded: true)),
        ("no output", header(summary: "", hasOutput: false)),
        ("http", header(summary: "", http: HTTPSummary(text: "200 · 142 ms · 1.2 KB · json",
                                                       tone: .success), isHTTP: true, json: true)),
        ("watched running", header(summary: "", isHTTP: true,
                                   watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                                      dots: [.success, .running], showsStop: true,
                                                      tone: .success))),
        ("watched finished", header(summary: "", isHTTP: true,
                                    watch: WatchHeader(text: "11 runs · p50 140 ms · 2 failures",
                                                       dots: [.success, .failure], showsStop: false,
                                                       tone: .failure))),
    ]
    for (name, h) in cases {
        for last in -1..<cols {
            let free = CommandBlockChrome.freeColumns(cols: cols, lastUsedColumn: last)
            guard free >= 8 else { continue }
            let rows = [(absoluteRow: 4, lastUsedColumn: last)]
            let summary = h.summary.isEmpty ? nil : CommandBlockChrome.summaryPlacement(
                commandRows: rows, textCount: h.summary.count, cols: cols)
            let placement = CommandBlockChrome.stripPlacement(
                h, commandRows: rows, cols: cols,
                summary: summary.map { (row: $0.row, text: h.summary) }, measure: columns)
            #expect(placement != nil, "\(name) at free=\(free) drew no strip")
            #expect(placement?.plan.pills.isEmpty == false, "\(name) at free=\(free) drew no pills")
            // And whatever rung it landed on, the sentence is still on the screen: either the strip
            // repeats it, or the strip carries its own readout, or the in-grid summary was left
            // alone (design D2 -- the three are exhaustive, and the strip never has none of them).
            guard let plan = placement?.plan, !h.summary.isEmpty else { continue }
            let keptInGrid = !CommandBlockChrome.suppressesSummary(
                plan, stripRow: placement!.row,
                summary: summary.map { (row: $0.row, text: h.summary) })
            #expect(!plan.readout.isEmpty || keptInGrid, "\(name) at free=\(free) lost the fact")
        }
    }
}

/// **D2.** A watched block at W1 keeps its readout. §2.6's W1 cells are `run 12 [Stop] [⋯]` and
/// `11 runs [⋯]`; the pictures rendered `[Stop] [⋯]` and `[⋯]` with no readout at all, which is
/// exactly the inversion the wave exists to remove -- a control outliving the fact.
///
/// The watch sentence is 32-33 columns, so a W1 row (8-17 free) can never have the in-grid summary
/// on it: the readout is the only place the run number can be, and §2.6's floor is "the status or
/// exit code alone, never dropped while a strip is drawn at all".
@Test func aWatchedBlockAtW1KeepsItsReadout() throws {
    let running = header(summary: "", isHTTP: true,
                         watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                            dots: [.success, .running], showsStop: true,
                                            tone: .success))
    let finished = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "11 runs · p50 140 ms · 2 failures",
                                             dots: [.success, .failure], showsStop: false,
                                             tone: .failure))
    let cols = 84
    for free in 8...17 {
        let rows = [(absoluteRow: 4, lastUsedColumn: cols - free - 1)]
        // The sentence does not fit on this row, so nothing but the strip can carry it.
        #expect(CommandBlockChrome.summaryPlacement(commandRows: rows,
                                                    textCount: running.summary.count,
                                                    cols: cols) == nil)
        let live = try #require(CommandBlockChrome.stripPlacement(running, commandRows: rows,
                                                                  cols: cols, summary: nil,
                                                                  measure: columns),
                                "running, free=\(free)")
        #expect(live.plan.readout == "run 12", "running, free=\(free)")
        #expect(live.plan.pills == [.stop, .actions(.glyph)], "running, free=\(free)")
        let done = try #require(CommandBlockChrome.stripPlacement(finished, commandRows: rows,
                                                                  cols: cols, summary: nil,
                                                                  measure: columns),
                                "finished, free=\(free)")
        #expect(done.plan.readout == "11 runs", "finished, free=\(free)")
        #expect(done.plan.pills == [.actions(.glyph)], "finished, free=\(free)")
    }
}

/// **P6.** The window where the lens chip blinks out, decided and pinned: free 29-33 on an
/// 84-column pane, where `200 · 142 ms · 1.2 KB · json` has just started fitting in the grid.
///
/// The sentence wins and the chip does not come back. The gap the sentence leaves is 1-5 columns;
/// the chip plus a glyph pill is thirteen, and putting *those* on the command's tail would cost
/// thirteen columns of somebody's command line for a control that **says** something rather than
/// doing it -- §2.3 grants the tail only to a control with a running side effect, and the lone `⋯`
/// is granted it because it is the route to every action including the lens rows themselves.
@Test func theLensChipGivesWayToTheSentenceInTheWindowWhereBothCannotFit() throws {
    let sentence = "200 · 142 ms · 1.2 KB · json"
    let h = header(summary: "", http: HTTPSummary(text: sentence, tone: .success),
                   isHTTP: true, json: true)
    let cols = 84
    for free in 29...33 {
        let rows = [(absoluteRow: 4, lastUsedColumn: cols - free - 1)]
        let summary = try #require(CommandBlockChrome.summaryPlacement(
            commandRows: rows, textCount: sentence.count, cols: cols), "free=\(free)")
        let placement = try #require(CommandBlockChrome.stripPlacement(
            h, commandRows: rows, cols: cols, summary: (row: summary.row, text: sentence),
            measure: columns), "free=\(free)")
        #expect(placement.plan.pills == [.actions(.glyph)], "free=\(free)")
        #expect(placement.plan.readout == "", "free=\(free)")
        #expect(placement.plan.overlapsCommand, "free=\(free)")
        // Ending where the sentence begins, so the whole of it stays readable in the grid.
        #expect(placement.plan.trailingColumn == summary.columns.lowerBound, "free=\(free)")
        #expect(!CommandBlockChrome.suppressesSummary(
            placement.plan, stripRow: placement.row,
            summary: (row: summary.row, text: sentence)), "free=\(free)")
    }
    // One column wider and the chip is back beside the glyph, in the gap, with no overlap at all.
    let roomy = [(absoluteRow: 4, lastUsedColumn: cols - 45 - 1)]
    let placement = try #require(CommandBlockChrome.stripPlacement(
        h, commandRows: roomy, cols: cols,
        summary: CommandBlockChrome.summaryPlacement(commandRows: roomy, textCount: sentence.count,
                                                     cols: cols).map { (row: $0.row, text: sentence) },
        measure: columns))
    #expect(placement.plan.pills.contains(.lens(name: "Raw", on: false)))
}

// MARK: - D5/D6/P2: the cap is the head of the spine, and the chevron stays in the padding

/// **D5.** One rect for every mark shape, and it is the spine's own: same x, same 3 pt, the whole
/// row. The cap was `y + 2` tall by `cellHeight - 4` with a 1.5 pt corner radius, which the design
/// review measured at 10× as a soft capsule on a half-pixel boundary over a crisp stick, with a
/// break above *and* below every head -- and `.bar` had neither inset nor radius, so a **failed**
/// block's spine was continuous and a succeeded one's was not.
@Test func everyMarkShapeIsTheSpinesOwnRect() {
    let cell = 17.0
    let rect = CommandBlockChrome.markRect(row: 3, cellHeight: cell, topPadding: 8, padding: 8)
    #expect(rect.x == CommandBlockChrome.spineLeadingInset(padding: 8))
    #expect(rect.width == CommandBlockChrome.spineWidth)
    // The mark's **bottom** is the row's bottom, so the cap meets the first row of its own spine
    // exactly and a block reads as one continuous 3 pt column from its head to its last row.
    #expect(rect.y + rect.height == 8 + 4 * cell)
    // The one surviving inset is at the top, and it is what holds one block apart from the next:
    // a command's last output row and the next command's prompt row are adjacent, so dropping it
    // outright would run two successive successes into one unbroken line.
    #expect(rect.y == 8 + 3 * cell + CommandBlockChrome.markTopInset)
    #expect(rect.height == cell - CommandBlockChrome.markTopInset)
    // A row shorter than the inset still gets a mark rather than an inverted rect.
    let tiny = CommandBlockChrome.markRect(row: 0, cellHeight: 1.5, topPadding: 0, padding: 8)
    #expect(tiny.height > 0)
}

/// **D6, P2.** The chevron never reaches column 0's ink. It is 6 pt, right-aligned to the mark's own
/// trailing edge, and extended only leftward into the padding -- so its right edge is at or before
/// `padding` for every padding the mark itself is inside of.
///
/// At 8 pt across `markX` it spanned 4-12 pt while column 0 begins at `padding` = 8, so its right
/// vertex sat inside the `$`'s bowl and the tint's edge cut the triangle in half.
@Test func theHoverChevronStaysInsideThePadding() {
    let cell = 17.0
    for padding in [0.0, 1, 2, 3, 4, 6, 8, 12, 20] {
        let box = CommandBlockChrome.hoverChevronRect(row: 2, cellHeight: cell, topPadding: 0,
                                                      padding: padding)
        #expect(box.x >= 0, "padding \(padding)")
        #expect(box.width == box.height, "padding \(padding)")
        // Never past the mark's own trailing edge…
        let mark = CommandBlockChrome.markRect(row: 2, cellHeight: cell, topPadding: 0,
                                               padding: padding)
        #expect(box.x + box.width <= mark.x + mark.width + 0.001, "padding \(padding)")
        // …and therefore never over column 0's ink, wherever the padding leaves the mark room for
        // itself. Below 3 pt the mark is already drawing over column 0 (Addendum 2's trade), and
        // between 3 and 6 the chevron **shrinks** to what the padding holds rather than reaching
        // further across the first glyph: at `padding = 4` it is 4 pt, at 3 it is the mark's own
        // 3 pt column. Only from 6 pt up is it the full 6.
        if padding >= CommandBlockChrome.spineWidth {
            #expect(box.x + box.width <= padding + 0.001, "padding \(padding)")
        }
        if padding >= CommandBlockChrome.hoverChevronSize {
            #expect(box.width == CommandBlockChrome.hoverChevronSize, "padding \(padding)")
        } else {
            #expect(box.width == max(CommandBlockChrome.spineWidth, min(padding, 6)),
                    "padding \(padding)")
        }
        // Centred on the row, so it is the head of the mark and not a bead beside it.
        #expect(box.y + box.height / 2 == 2.5 * cell, "padding \(padding)")
    }
    // The shipping padding, spelled out: 1 pt to 7 pt, inside eight points of padding.
    let shipping = CommandBlockChrome.hoverChevronRect(row: 0, cellHeight: cell, topPadding: 0,
                                                       padding: 8)
    #expect(shipping.x == 1)
    #expect(shipping.width == 6)
}
