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

@Test func aRunningCommandIsMarkedRunningRatherThanFailed() {
    let blocks = session().visibleBlocks(rows: 8)
    let current = try! #require(blocks.first { $0.region.promptRow == 6 })
    #expect(current.isRunning)
    #expect(!current.failed)
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
