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
