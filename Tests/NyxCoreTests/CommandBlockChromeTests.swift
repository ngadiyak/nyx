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
    #expect(pills(h, .w3) == [.lens(name: "Pretty", on: false), .fold(.fold),
                              .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.lens(name: "Pretty", on: false), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
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
    #expect(pills(h, .w3) == [.stop, .copy(enabled: true), .actions(.labelled)])
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
    #expect(pills(h, .w3) == [.copy(enabled: true), .actions(.labelled)])
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
                                                         chevronCount: 1, cols: 80)?.row
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
/// §2.6 puts the timeline, the sentence, `Stop`, `Copy` and `Actions` on a W3 watched block, and
/// measured that is sixty to eighty columns of strip -- while W3 begins at thirty-four free ones.
/// Refusing the row outright took `Stop`, the one control the table says is present at *every*
/// width, off the screen entirely; the composites named after the watch and the lens had no strip
/// in them at all. So a row walks down its own ladder until the strip fits, which is what the two
/// ladders are for.
@Test func aRowTooNarrowForItsClassStepsDownTheLadder() {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.success, .running], showsStop: true,
                                             tone: .success))
    var tried: [Int] = []
    let placement = CommandBlockChrome.stripPlacement(
        watching, commandRows: [(absoluteRow: 4, lastUsedColumn: 30)], cols: 80, summary: nil,
        measure: { content in
            tried.append(content.pills.count)
            return content.pills.count == 3 ? 70 : 12
        })
    // W3 (49 free) is asked first and does not fit after the last glyph; W2 does.
    #expect(tried == [3, 2])
    #expect(placement?.plan.pills == [.stop, .actions(.labelled)])
    #expect(placement?.plan.firstColumn == 68)
    // Stepping down never reaches W0 from a roomier row: the lone Stop over the command's tail is
    // the W0 row's own exception, not a fallback every crowded block gets.
    #expect(placement?.plan.overlapsCommand == false)
    let noRoomAtAll = CommandBlockChrome.stripPlacement(
        watching, commandRows: [(absoluteRow: 4, lastUsedColumn: 30)], cols: 80, summary: nil,
        measure: { _ in 60 })
    #expect(noRoomAtAll == nil)
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
    #expect(free.plan.pills == [.lens(name: "Pretty", on: false), .actions(.labelled)])
}

/// The 30-run watch row: the sentence plus even the narrowest pills is wider than the row, so there
/// is **no strip** and `run 31 · 200 · 170 ms · every 5 s` stays exactly where it was. Hovering a
/// block may cost the pills; it may never cost a fact.
@Test func aStripThatCannotCarryTheSentenceIsNotDrawn() {
    let sentence = "run 31 · 200 · 170 ms · every 5 s"
    let h = header(summary: "", http: HTTPSummary(text: "200 · 170 ms", tone: .success),
                   isHTTP: true, json: true,
                   watch: WatchHeader(text: sentence, dots: Array(repeating: .success, count: 30),
                                      showsStop: true, tone: .success))
    let placement = CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 44)], cols: 84,
        summary: (row: 4, text: sentence), measure: columns)
    #expect(placement == nil)
    // Without the sentence to protect -- the summary went on another row -- the ladder shortens as
    // before, and `Stop` survives.
    let elsewhere = CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 44)], cols: 84,
        summary: (row: 9, text: sentence), measure: columns)
    #expect(elsewhere?.plan.pills == [.stop, .actions(.labelled)])
    #expect(elsewhere?.plan.readout == "run 31 · 200")
}

/// A summary that only had room for its chevron is not a sentence anybody can read, so there is
/// nothing for the strip to repeat -- and nothing it can speak for either.
@Test func aChevronOnlySummaryProtectsNothingAndIsNotSpokenFor() throws {
    let h = header(summary: "8.8s")
    let placement = try #require(CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 40)], cols: 84,
        summary: (row: 4, text: ""), measure: columns))
    #expect(placement.plan.readout == "8.8s")
    #expect(!CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                  summary: (row: 4, text: "")))
}
