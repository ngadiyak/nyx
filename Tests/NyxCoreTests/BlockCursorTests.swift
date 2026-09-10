import Testing
@testable import NyxCore

private let ids: [UInt32] = [10, 20, 30, 40]

@Test func movingStepsOneBlockAtATime() {
    let start = BlockCursor(commandID: 30)
    #expect(BlockCursor.moved(start, by: .previous, among: ids).commandID == 20)
    #expect(BlockCursor.moved(start, by: .next, among: ids).commandID == 40)
}

/// Clamps rather than wraps: ⌘↑ at the oldest block must not jump to the newest, which is the
/// other end of a thousand rows of scrollback.
@Test func movingClampsAtBothEnds() {
    #expect(BlockCursor.moved(BlockCursor(commandID: 10), by: .previous, among: ids).commandID == 10)
    #expect(BlockCursor.moved(BlockCursor(commandID: 40), by: .next, among: ids).commandID == 40)
}

@Test func fromAClearedCursorPreviousTakesTheNewestAndNextTheOldest() {
    #expect(BlockCursor.moved(BlockCursor(), by: .previous, among: ids).commandID == 40)
    #expect(BlockCursor.moved(BlockCursor(), by: .next, among: ids).commandID == 10)
}

/// A block trimmed out of the buffer by scrollback is gone. The move re-anchors on the nearest
/// survivor in the direction of travel rather than stepping from a block that no longer exists --
/// stepping would silently skip whichever block took its place.
@Test func aTrimmedBlockReAnchorsOnTheNearestSurvivorInTheDirectionOfTravel() {
    let gone = BlockCursor(commandID: 25)
    #expect(BlockCursor.moved(gone, by: .previous, among: ids).commandID == 20)
    #expect(BlockCursor.moved(gone, by: .next, among: ids).commandID == 30)
}

@Test func aTrimmedBlockPastTheEndsClampsToTheEnds() {
    #expect(BlockCursor.moved(BlockCursor(commandID: 5), by: .previous, among: ids).commandID == 10)
    #expect(BlockCursor.moved(BlockCursor(commandID: 99), by: .next, among: ids).commandID == 40)
}

@Test func movingInAPaneWithNoBlocksClearsTheCursor() {
    #expect(BlockCursor.moved(BlockCursor(commandID: 30), by: .previous, among: []).commandID == nil)
}

// MARK: - Where a press starts from

/// ⌘↑ in a pane scrolled back two thousand rows must go up *from where the reader is*, not from
/// the bottom of the session. A cursor that is cleared -- or on a block that has scrolled away --
/// is seeded from the viewport's own block, and the press lands on that seed rather than stepping
/// over the output filling the screen. The second press steps.
@Test func cursorSeedsFromTheViewportWhenCleared() {
    #expect(BlockCursor.seed(BlockCursor(), visible: [20, 30], viewportBlock: 20)?.commandID == 20)
}

@Test func aCursorAlreadyOnScreenIsNotSeeded() {
    #expect(BlockCursor.seed(BlockCursor(commandID: 30), visible: [20, 30], viewportBlock: 20) == nil)
}

@Test func aCursorScrolledOffTheScreenSeedsFromTheViewport() {
    #expect(BlockCursor.seed(BlockCursor(commandID: 99), visible: [20, 30], viewportBlock: 30)?.commandID == 30)
}

/// Seeding onto the block the cursor already names would be a press that does nothing, so it is
/// declined and the press steps instead.
@Test func seedingIsDeclinedWhenItWouldNotMoveTheCursor() {
    #expect(BlockCursor.seed(BlockCursor(commandID: 20), visible: [30], viewportBlock: 20) == nil)
}

@Test func thereIsNothingToSeedFromInAPaneWithNoBlocks() {
    #expect(BlockCursor.seed(BlockCursor(), visible: [], viewportBlock: nil) == nil)
}

@Test func afterAViewportMoveTheCursorKeepsAVisibleBlock() {
    let kept = BlockCursor.afterViewportMove(BlockCursor(commandID: 20), visible: [20, 30], fallback: 30)
    #expect(kept.commandID == 20)
}

@Test func afterAViewportMoveABlockOffScreenTakesTheFallback() {
    let moved = BlockCursor.afterViewportMove(BlockCursor(commandID: 20), visible: [30, 40], fallback: 40)
    #expect(moved.commandID == 40)
}

@Test func afterAViewportMoveWithNoFallbackTheCursorClears() {
    let cleared = BlockCursor.afterViewportMove(BlockCursor(commandID: 20), visible: [30], fallback: nil)
    #expect(cleared.commandID == nil)
}

/// A pane nobody has pressed ⌘↑ in has no cursor, and scrolling must not give it one: the cursor
/// is drawn, so growing one on a scroll would light a block the user never asked about.
@Test func aClearedCursorStaysClearedThroughAViewportMove() {
    let still = BlockCursor.afterViewportMove(BlockCursor(), visible: [10, 20], fallback: 20)
    #expect(still.commandID == nil)
}

// MARK: - Which blocks the cursor may sit on

private func session(_ script: [(command: String, output: [String], status: Int32)]) -> Terminal {
    let t = Terminal(cols: 40, rows: 10, scrollbackLimit: 500)
    func mark(_ letter: String, _ status: Int32? = nil) -> String {
        "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
    }
    for step in script {
        t.feed(mark("A") + "$ " + mark("B") + step.command + "\r\n" + mark("C"))
        for line in step.output { t.feed(line + "\r\n") }
        t.feed(mark("D", step.status))
    }
    t.feed(mark("A") + "$ ")   // the prompt being typed at: no output, no status, not a block
    return t
}

/// The prompt you are typing at has an id and has run nothing. Landing ⌘↑ on it would raise a
/// strip with no summary and no Copy -- the first thing anybody pressing ⌘↑ would see.
@Test func theBlocksTheCursorMaySitOnExcludeThePromptBeingTypedAt() {
    let t = session([(command: "echo one", output: ["one"], status: 0),
                     (command: "make lint", output: ["Error 1"], status: 1),
                     (command: "echo three", output: ["three"], status: 0)])
    let cursorIDs = t.blockCursorIDs
    #expect(cursorIDs.count == 3)
    let promptID = t.command(containingAbsoluteRow: t.totalRows - 1)?.id
    #expect(promptID != nil && !cursorIDs.contains(promptID!))
    #expect(cursorIDs == cursorIDs.sorted())
}

@Test func aShellWithNoIntegrationOffersNoBlocksToSitOn() {
    let t = Terminal(cols: 40, rows: 10, scrollbackLimit: 100)
    t.feed("hello\r\nworld\r\n")
    #expect(t.blockCursorIDs.isEmpty)
}

/// Block id 0 is "no command" everywhere in this codebase -- `command(containingAbsoluteRow:)`
/// answers a region with id 0 for rows above the first prompt -- so `commandToFold()` can hand back
/// a seed that names nothing. Seeding on it would put the cursor on a block that cannot be found
/// again, and every reader downstream (`BlockHover.resolve`, `BlockTarget.resolve`) would answer nil
/// while the cursor claimed to be somewhere.
@Test func aViewportBlockOfZeroIsNotASeed() {
    #expect(BlockCursor.seed(BlockCursor(), visible: [20, 30], viewportBlock: 0) == nil)
    #expect(BlockCursor.seed(BlockCursor(commandID: 99), visible: [20], viewportBlock: 0) == nil)
}
