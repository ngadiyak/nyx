import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

/// Two finished commands and a prompt being typed at:
///   0 $ echo one   1 one   2 $ false   3 $ (typing)
private func session() -> Terminal {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "false\r\n" + mark("C") + mark("D", 1))
    t.feed(mark("A") + "$ ")
    return t
}

@Test func everyPromptGetsItsOwnIncreasingID() {
    let t = session()
    let ids = [0, 2, 3].map { t.absoluteRow($0)!.commandID }
    #expect(ids == [1, 2, 3])
    #expect(t.absoluteRow(1)!.commandID == 0)   // output rows carry none
}

@Test func theRegionCarriesItsPromptID() {
    let t = session()
    #expect(t.command(containingAbsoluteRow: 1)?.id == 1)
    #expect(t.command(containingAbsoluteRow: 2)?.id == 2)
}

/// A prompt redrawn on the same row -- zsh after a resize, or after `^L` -- is the same command.
@Test func aSecondAOnTheSameRowKeepsTheID() {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "\r" + mark("A") + "$ " + mark("B"))
    #expect(t.absoluteRow(0)!.commandID == 1)
    t.feed("x\r\n" + mark("A") + "$ ")
    #expect(t.absoluteRow(1)!.commandID == 2)
}

@Test func theIDSurvivesReflow() {
    let t = session()
    t.resize(cols: 8, rows: 6)
    let ids = (0..<t.totalRows).compactMap { row -> UInt32? in
        let id = t.absoluteRow(row)!.commandID
        return id == 0 ? nil : id
    }
    #expect(ids == [1, 2, 3])
}

@Test func theRunningCommandIsKnownWhileItRuns() {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    var clock = 5.0
    t.now = { clock }
    t.feed(mark("A") + "$ " + mark("B") + "sleep\r\n")
    #expect(t.runningCommand == nil)          // typed, not yet running
    t.feed(mark("C"))
    #expect(t.runningCommand?.id == 1)
    #expect(t.runningCommand?.startedAt == 5.0)
    clock = 7
    t.feed(mark("D", 0) + mark("A") + "$ ")
    #expect(t.runningCommand == nil)
}

@Test func theOldestIDFollowsTheRing() {
    let t = makeTerminal(cols: 20, rows: 3, scrollback: 4)
    for i in 1...6 {
        t.feed(mark("A") + "$ " + mark("B") + "c\(i)\r\n" + mark("C") + "out\r\n" + mark("D", 0))
    }
    t.feed(mark("A") + "$ ")
    // Seven prompts, two rows each, in a buffer of 4 + 3 rows: the first ones are gone.
    #expect(t.oldestCommandID > 1)
    #expect(t.oldestCommandID <= 7)
    #expect(t.absoluteRow(t.promptRow(ofCommand: t.oldestCommandID)!)!.commandID == t.oldestCommandID)
    #expect(t.promptRow(ofCommand: 1) == nil)
}

@Test func anEmptyBufferHasNoOldestCommand() {
    #expect(makeTerminal().oldestCommandID == 0)
}
