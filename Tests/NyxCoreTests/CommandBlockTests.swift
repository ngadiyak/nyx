import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
}

/// Two finished commands and a running one:
///   0  $ echo one      1 one      2 $ build      3..5 output      6 $ (typing)
private func session() -> Terminal {
    let t = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    var clock = 0.0
    t.now = { clock }
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n")
    clock = 0.2
    t.feed(mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C") + "a\r\nb\r\nc\r\n")
    clock = 9
    t.feed(mark("D", 1))
    t.feed(mark("A") + "$ ")
    return t
}

// MARK: - Which blocks are on screen

@Test func everyCommandOnScreenIsABlock() {
    let blocks = session().visibleBlocks(rows: 8)
    #expect(blocks.count == 3)
    #expect(blocks[0].region.promptRow == 0)
    #expect(blocks[1].region.promptRow == 2)
}

/// A block covers every row it owns, so the spine runs the height of the output rather than
/// stopping at the command line.
@Test func aBlockCoversItsOutputAsWellAsItsCommand() {
    let blocks = session().visibleBlocks(rows: 8)
    #expect(blocks[1].visibleRows.count >= 4)   // the command plus three rows of output
}

@Test func aShellWithoutMarksHasNoBlocks() {
    let t = makeTerminal(cols: 40, rows: 8).run("$ build\r\noutput\r\n")
    #expect(t.visibleBlocks(rows: 8).isEmpty)
}

/// Scrolled so a block starts above the viewport, only the visible part is reported -- and its
/// header is not drawn, because the command it names is off screen.
@Test func aBlockScrolledPastTheTopKeepsItsSpineAndLosesItsHeader() {
    // A screen small enough that the build's command line really is above it: a viewport that
    // already shows everything cannot demonstrate anything about scrolling.
    let t = makeTerminal(cols: 40, rows: 3, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C"))
    for i in 1...10 { t.feed("output \(i)\r\n") }
    t.feed(mark("D", 0))

    guard let block = t.visibleBlocks(rows: 3).first(where: { $0.region.promptRow == 0 }) else {
        Issue.record("expected the build block to still be visible")
        return
    }
    #expect(!block.showsHeader)          // its command line is above the viewport
    #expect(!block.visibleRows.isEmpty)  // but its spine still runs down the rows on screen
}

@Test func aClickResolvesToTheBlockItLandedIn() {
    let t = session()
    let block = try! #require(t.block(atAbsoluteRow: 4, rows: 8))
    #expect(block.region.promptRow == 2)      // a row of the build's output belongs to the build
}

// MARK: - What the header says

@Test func aFailedCommandSaysSoAndSaysHowLongItTook() {
    let blocks = session().visibleBlocks(rows: 8)
    let build = try! #require(blocks.first { $0.region.promptRow == 2 })
    #expect(build.summary() == "exit 1 · 8.8s")
    #expect(build.failed)
}

/// A command that succeeded quickly has nothing worth saying: `exit 0` is the expected case and
/// `0.2s` is noise. A header full of nothing trains people to stop reading headers.
@Test func aQuickSuccessSaysNothing() {
    let blocks = session().visibleBlocks(rows: 8)
    let echo = try! #require(blocks.first { $0.region.promptRow == 0 })
    #expect(echo.summary().isEmpty)
}

/// The prompt you are typing at is not a running command. It has no output and no status, and
/// treating that as "in progress" leaves an amber marker beside an idle cursor for as long as the
/// terminal is open. This test used to assert the opposite and enshrined the bug.
@Test func anIdlePromptIsNotRunning() {
    let blocks = session().visibleBlocks(rows: 8)
    let current = try! #require(blocks.first { $0.region.promptRow == 6 })
    #expect(!current.isRunning)
    #expect(!current.failed)
}

/// A command that has begun producing output and has not finished is the real running case.
@Test func aCommandProducingOutputIsRunning() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C") + "working\r\n")
    let block = try! #require(t.visibleBlocks(rows: 6).first)
    #expect(block.isRunning)
}

// MARK: - When chrome must stay out of the way

/// The rule Warp's blocks do not have, and the reason theirs break in tmux and over ssh: a
/// full-screen program is drawing its own interface across every cell, and a spine down the side
/// of it is a bug.
@Test func noChromeOverAFullScreenProgram() {
    #expect(!CommandBlockChrome.isAllowed(altScreen: true, mouseReporting: false, hasMarks: true))
    #expect(!CommandBlockChrome.isAllowed(altScreen: false, mouseReporting: true, hasMarks: true))
    #expect(!CommandBlockChrome.isAllowed(altScreen: false, mouseReporting: false, hasMarks: false))
    #expect(CommandBlockChrome.isAllowed(altScreen: false, mouseReporting: false, hasMarks: true))
}

// MARK: - Where the summary may be drawn
//
// One rule for both the renderer (should it draw the summary) and the pane (did a click land on
// it) -- so a long command line or a narrow pane can never leave one of them thinking the summary
// is there when the other does not.

@Test func theSummaryFitsBesideAShortCommand() {
    #expect(CommandBlockChrome.summaryColumns(textCount: 5, cols: 40, lastUsedColumn: 10) == 35..<40)
}

/// The command line reaches all the way to where the summary would start: drawing it there would
/// overwrite the more important of the two, so there is no summary at all rather than one on top
/// of the text.
@Test func noSummaryWhenTheCommandLineWouldTouchIt() {
    #expect(CommandBlockChrome.summaryColumns(textCount: 5, cols: 40, lastUsedColumn: 34) == nil)
}

/// A pane too narrow for the summary to fit at all -- the click target must not exist either, or
/// the pane would record a negative range nobody can click.
@Test func noSummaryWhenThePaneIsTooNarrow() {
    #expect(CommandBlockChrome.summaryColumns(textCount: 5, cols: 4, lastUsedColumn: -1) == nil)
}

@Test func noSummaryColumnsForEmptyText() {
    #expect(CommandBlockChrome.summaryColumns(textCount: 0, cols: 40, lastUsedColumn: -1) == nil)
}

// MARK: - Chrome for the rows a fold pushed onto the screen

/// Five commands, the first with 30 rows of output. A tail fold keeping 3 of them hides 27, so the
/// ten slots on screen reach absolute row 35 -- far past `viewportTop + rows`.
private func foldedSession() -> (terminal: Terminal, folding: OutputFolding) {
    let t = makeTerminal(cols: 40, rows: 10, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C"))
    for i in 1...30 { t.feed("out \(i)\r\n") }
    t.feed(mark("D", 0))
    for i in 2...5 {
        t.feed(mark("A") + "$ " + mark("B") + "cmd \(i)\r\n" + mark("C") + "line\r\n" + mark("D", 0))
    }
    t.feed(mark("A") + "$ ")
    _ = t.scrollToAbsoluteRow(0, margin: 0)
    var folding = OutputFolding()
    folding.toggle(t.command(containingAbsoluteRow: 0)!.id, keep: 3)
    return (t, folding)
}

/// The reviewer's probe: with a fold on screen, a window of `rows` absolute rows stops well above
/// the last row actually displayed, and every block below the placeholder lost its spine, its
/// summary and its gutter mark.
@Test func aFoldPushesBlocksPastTheRowsWindowAndTheyStillGetChrome() {
    let (t, folding) = foldedSession()
    let display = t.displayRows(from: 0, count: 10, folding: folding)
    let lastDisplayed = display.compactMap { if case .row(let r) = $0 { return r } else { return nil } }.max()!
    #expect(lastDisplayed > 9)   // the whole point: past `viewportTop + rows`

    let wide = t.visibleBlocks(from: 0, through: lastDisplayed)
    let promptsOnScreen = display.compactMap { entry -> Int? in
        guard case .row(let r) = entry,
              t.promptMarks(atAbsoluteRow: r).contains(.promptStart) else { return nil }
        return r
    }
    #expect(promptsOnScreen.count > 1)
    for prompt in promptsOnScreen {
        #expect(wide.contains { $0.region.promptRow == prompt && $0.showsHeader },
                "no block header for the prompt displayed at absolute row \(prompt)")
    }
    // The unwindowed wrapper is what the pane used to call, and it sees only the first command.
    #expect(t.visibleBlocks(rows: 10).count == 1)
}

/// The same for the gutter, which is answered per display slot rather than per absolute row: a
/// window reaching the last displayed row would be a scan of the whole fold on every frame.
@Test func aFoldPushesGutterMarksPastTheRowsWindowToo() {
    let (t, folding) = foldedSession()
    let display = t.displayRows(from: 0, count: 10, folding: folding)

    let placed = t.gutterMarks(onDisplayRows: display)
    #expect(placed.count == display.count)
    var marked = 0
    for (slot, entry) in display.enumerated() {
        guard case .row(let absolute) = entry else {
            #expect(placed[slot] == nil, "a fold placeholder has no prompt of its own")
            continue
        }
        if t.promptMarks(atAbsoluteRow: absolute).contains(.promptStart) {
            #expect(placed[slot] != nil, "no gutter mark for the prompt in slot \(slot)")
            marked += 1
        }
    }
    #expect(marked > 1)   // the reviewer's probe: prompts below the placeholder, all marked
    // The unwindowed form is what the pane used to call for a folded viewport, and it sees one.
    #expect(t.gutterMarks(rows: 10).compactMap { $0 }.count == 1)
    // The same slots carry their durations.
    #expect(t.durationNotes(onDisplayRows: display).count == display.count)
}

// MARK: - Where the summary actually goes

// A command line long enough to reach the summary's columns used to mean no summary at all, so a
// pasted `curl` in a 100-column pane lost the one control that folds it. These decide which of the
// command's rows carries it, and what fits there.

@Test func theSummaryGoesOnTheCommandRowWhenItFits() {
    let placement = CommandBlockChrome.summaryPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 9)], textCount: 10, chevronCount: 1, cols: 40)
    #expect(placement == SummaryPlacement(row: 4, columns: 30..<40, text: .full))
}

/// One row, filled to the last column: there is nowhere for the summary and nowhere for the
/// chevron either, and the gutter mark is what folds the block.
@Test func aCommandFillingItsOnlyRowLeavesNowhereForTheSummary() {
    let placement = CommandBlockChrome.summaryPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 39)], textCount: 10, chevronCount: 1, cols: 40)
    #expect(placement == nil)
}

/// A wrapped command line has several rows and the last is usually the shortest, so that is where
/// the summary goes rather than nowhere.
@Test func aWrappedCommandPutsTheSummaryOnItsLastRow() {
    let placement = CommandBlockChrome.summaryPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 39), (absoluteRow: 5, lastUsedColumn: 12)],
        textCount: 10, chevronCount: 1, cols: 40)
    #expect(placement == SummaryPlacement(row: 5, columns: 30..<40, text: .full))
}

/// Both rows reach into the summary's columns, but the last leaves one free cell: the user's rule
/// is that the chevron is always visible, so the status is what gives way.
@Test func aLongCommandKeepsItsChevronWhenTheStatusNoLongerFits() {
    let placement = CommandBlockChrome.summaryPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 39), (absoluteRow: 5, lastUsedColumn: 37)],
        textCount: 10, chevronCount: 1, cols: 40)
    #expect(placement == SummaryPlacement(row: 5, columns: 39..<40, text: .chevronOnly))
}

/// The overlay belongs on the row the summary was actually placed on -- a wrapped command line puts
/// that below the prompt row -- and nowhere at all when no row had room for it.
@Test func aHoversOverlayFollowsWhereTheSummaryWasPlaced() {
    let hover = BlockHover(id: 7, rows: 2..<6, headerRow: 2)
    #expect(hover.attachingHeader(to: 3) == BlockHover(id: 7, rows: 2..<6, headerRow: 3))
    #expect(hover.attachingHeader(to: nil).headerRow == nil)
    #expect(hover.attachingHeader(to: nil).rows == 2..<6)
}

// MARK: - Where the hover strip goes, and how much of it there is room for

// The strip is opaque and 20-odd columns wide. Placed from the summary's row and sized only from
// its own content, it painted over the end of the command it describes: in a 28-column split,
// hovering `git status --short` showed `~ % git status`, a different, real command.

private let stripColumns: [OverlayControls: Int] = [.full: 20, .noCopy: 8, .minimal: 4]

@Test func aWideRowCarriesTheWholeStrip() {
    let placement = CommandBlockChrome.overlayPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 9)], stripColumns: stripColumns, cols: 40)
    #expect(placement == OverlayPlacement(row: 4, controls: .full))
}

/// Eight free columns: Copy is what goes, because the ⋯ menu still copies -- while the summary is
/// the only place the exit status is left, the strip having suppressed the Metal one and the note.
@Test func aCrowdedRowDropsCopyBeforeTheSummary() {
    let placement = CommandBlockChrome.overlayPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 31)], stripColumns: stripColumns, cols: 40)
    #expect(placement == OverlayPlacement(row: 4, controls: .noCopy))
}

/// Four free columns: only the ⋯ menu and the chevron, which between them still reach every action.
@Test func aVeryCrowdedRowKeepsOnlyTheMenuAndTheChevron() {
    let placement = CommandBlockChrome.overlayPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 35)], stripColumns: stripColumns, cols: 40)
    #expect(placement == OverlayPlacement(row: 4, controls: .minimal))
}

/// One free column fits no strip anywhere, and the strip goes over the tail of the last row
/// anyway: hovering is a deliberate act, four covered cells last only while the pointer is there,
/// and a command with *no* free column is exactly the long pasted `curl` whose ⋯ menu carries the
/// whole Request group. The static summary still gives way rather than painting over the text.
@Test func aRowWithNoRoomGetsTheMinimalStripOverItsTail() {
    let placement = CommandBlockChrome.overlayPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 38)], stripColumns: stripColumns, cols: 40)
    #expect(placement == OverlayPlacement(row: 4, controls: .minimal))
}

/// The last row of the command, not the first: that is where the eye is, and it is the row the
/// summary would have used if there had been room.
@Test func theOverlayFallsBackOntoTheLastRowOfALongCommand() {
    let placement = CommandBlockChrome.overlayPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 39), (absoluteRow: 5, lastUsedColumn: 39),
                      (absoluteRow: 6, lastUsedColumn: 37)],
        stripColumns: stripColumns, cols: 40)
    #expect(placement == OverlayPlacement(row: 6, controls: .minimal))
}

/// A pane narrower than the smallest strip is the one case that still gets nothing: a strip wider
/// than the pane would hang off the left edge, and the gutter mark, ⌘⇧↑ and the right-click menu
/// all still reach the block.
@Test func aPaneNarrowerThanTheStripGetsNoStrip() {
    let placement = CommandBlockChrome.overlayPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 2)], stripColumns: stripColumns, cols: 3)
    #expect(placement == nil)
}

/// And a command with no rows on screen has nowhere to put one.
@Test func noCommandRowsMeansNoStrip() {
    #expect(CommandBlockChrome.overlayPlacement(commandRows: [], stripColumns: stripColumns,
                                                cols: 40) == nil)
}

/// A wrapped command whose last row is full: the strip goes up to the row that has room rather than
/// over the text of the one that has not.
@Test func aStripMovesToWhicheverRowOfTheCommandHasRoom() {
    let placement = CommandBlockChrome.overlayPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 9), (absoluteRow: 5, lastUsedColumn: 38)],
        stripColumns: stripColumns, cols: 40)
    #expect(placement == OverlayPlacement(row: 4, controls: .full))
}

/// The chevron and the gutter mark answer to one rule. `OSC 133;C` arrives when a command *begins*,
/// so a `sleep 10` one second in has an output region made of the blank rows below it; a chevron
/// there folds nothing but empty lines.
@Test func aJustStartedCommandHasNoChevron() throws {
    let t = makeTerminal(cols: 40, rows: 24, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "sleep 10\r\n" + mark("C"))
    let region = try #require(t.command(containingAbsoluteRow: 0))
    let block = CommandBlock(region: region, visibleRows: 0..<24, showsHeader: true)
    let quiet = block.header(now: 5, folding: OutputFolding(), notifyArmed: false, anyFolds: false,
                             hasOutput: t.commandHasOutput(atAbsoluteRow: region.promptRow))
    #expect(quiet.isRunning)
    #expect(!quiet.hasOutput)
    #expect(quiet.chevron == "")
    #expect(quiet.actions.first { $0.action == .toggleFold }?.enabled == false)

    t.feed("compiling...\r\n")
    let loud = block.header(now: 5, folding: OutputFolding(), notifyArmed: false, anyFolds: false,
                            hasOutput: t.commandHasOutput(atAbsoluteRow: region.promptRow))
    #expect(loud.chevron == "\u{25BE}")
}
