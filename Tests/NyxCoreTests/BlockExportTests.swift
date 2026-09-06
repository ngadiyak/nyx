import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

@Test func markdownIsOneFenceWithThePromptedCommandAndTheOutput() {
    let md = BlockExport.markdown(command: "curl -s https://x.test/v1", output: "{\"ok\":true}")
    #expect(md == "```\n$ curl -s https://x.test/v1\n{\"ok\":true}\n```\n")
}

@Test func aCommandThatAlreadyStartsWithAPromptIsNotDoubled() {
    #expect(BlockExport.markdown(command: "$ ls", output: "a").hasPrefix("```\n$ ls\n"))
    #expect(BlockExport.markdown(command: "% ls", output: "a").hasPrefix("```\n% ls\n"))
}

@Test func emptyOutputLeavesOnlyTheCommand() {
    #expect(BlockExport.markdown(command: "true", output: "") == "```\n$ true\n```\n")
}

@Test func outputTextTrimsTrailingBlankLines() {
    let t = makeTerminal(cols: 20, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo hi\r\n" + mark("C") + "hi\r\n\r\n\r\n" + mark("D", 0)
           + mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)!
    #expect(t.outputText(of: region) == "hi")
}

/// The export is fed `commandLine`, not `commandText`: a real `PS1` put
/// `$ nik@host ~ % make test` inside the fence, which is not a command anyone can paste back.
@Test func markdownFromARealPromptCarriesOnlyTheCommand() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    t.feed(mark("A") + "nik@host ~ % " + mark("B") + "make test\r\n" + mark("C") + "ok\r\n" + mark("D", 0))
    let region = t.command(containingAbsoluteRow: 0)!
    let md = BlockExport.markdown(command: t.commandLine(of: region), output: t.outputText(of: region))
    #expect(md == "```\n$ make test\nok\n```\n")
}

// MARK: - Logical lines

/// The reason `outputLines` exists: a JSON body is one line however narrow the pane is, and the
/// pretty lens reads it as data rather than as a picture of the screen. Split at the column the
/// terminal wrapped at, the newline lands inside a string literal and the parse fails.
@Test func outputLinesJoinsRowsTheTerminalWrapped() {
    let t = makeTerminal(cols: 20, rows: 8, scrollback: 100)
    let body = "{\"name\":\"a value long enough to wrap twice\",\"n\":1}"
    t.feed(mark("A") + "$ " + mark("B") + "curl -s https://x.test\r\n" + mark("C")
           + body + "\r\n" + mark("D", 0) + mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)!
    #expect(t.outputLines(of: region) == [body])
    // The visual transcript still shows the rows as they are on the screen.
    #expect(t.outputText(of: region).contains("\n"))
}

/// A row the *program* ended is a line of its own, wrapped or not: two `echo`s are two lines.
@Test func outputLinesKeepsLinesTheProgramEnded() {
    let t = makeTerminal(cols: 20, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "two\r\n" + mark("C") + "first\r\nsecond\r\n"
           + mark("D", 0) + mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)!
    #expect(t.outputLines(of: region) == ["first", "second"])
}

/// Padding comes off the row the program ended and stays on the one the terminal wrapped, where a
/// trailing space is a space that was printed.
@Test func outputLinesTrimsOnlyTheRowThatEndsALine() {
    let t = makeTerminal(cols: 10, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "pad\r\n" + mark("C") + "ab\r\n" + mark("D", 0)
           + mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)!
    #expect(t.outputLines(of: region) == ["ab"])
}

@Test func outputLinesDropsTrailingBlankLines() {
    let t = makeTerminal(cols: 20, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo hi\r\n" + mark("C") + "hi\r\n\r\n\r\n"
           + mark("D", 0) + mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)!
    #expect(t.outputLines(of: region) == ["hi"])
}
