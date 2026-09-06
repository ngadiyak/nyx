import Testing
@testable import NyxCore

@Test func plainGetGetsAllThree() throws {
    let command = try #require(CurlCommand.parse("curl https://example.com"))
    let add = RequestRun.additions(for: command)
    #expect(add == RequestRun.Additions(silent: true, include: true, writeOut: true))

    let line = RequestRun.commandLine(for: command)
    // The `-w` argument must be curl's own escapes, quoted exactly as a person would type them --
    // not Swift's actual newline -- or curl never expands them into the sentinel line.
    #expect(line.contains("-w '\\n--nyx-http-- %{json}\\n'"), "\(line)")
    #expect(line.hasSuffix("https://example.com"), "URL should still be last: \(line)")

    let reparsed = try #require(CurlCommand.parse(line))
    #expect(reparsed.flags.contains(.silent))
    #expect(reparsed.flags.contains(.showError))
    #expect(reparsed.flags.contains(.include))
    #expect(reparsed.output.writeOut?.text == RequestRun.writeOutArgument)
}

@Test func verboseSkipsSilent() throws {
    let command = try #require(CurlCommand.parse("curl -v https://example.com"))
    let add = RequestRun.additions(for: command)
    #expect(!add.silent)
    #expect(add.include)
    #expect(add.writeOut)

    let line = RequestRun.commandLine(for: command)
    let reparsed = try #require(CurlCommand.parse(line))
    #expect(!reparsed.flags.contains(.silent))
    #expect(!reparsed.flags.contains(.showError))
    #expect(reparsed.flags.contains(.verbose))
}

@Test func headSkipsInclude() throws {
    let command = try CurlFixtures.command("12-head-and-timeouts")
    #expect(command.head)
    let add = RequestRun.additions(for: command)
    #expect(!add.include)

    let line = RequestRun.commandLine(for: command)
    let reparsed = try #require(CurlCommand.parse(line))
    #expect(!reparsed.flags.contains(.include))
}

@Test func outputFileSkipsInclude() throws {
    let command = try #require(CurlCommand.parse("curl -o out.json https://example.com"))
    let add = RequestRun.additions(for: command)
    #expect(!add.include)

    let line = RequestRun.commandLine(for: command)
    let reparsed = try #require(CurlCommand.parse(line))
    #expect(!reparsed.flags.contains(.include))
}

@Test func pipelineSkipsIncludeAndWriteOut() throws {
    let command = try CurlFixtures.command("10-pipeline")
    #expect(!command.trailingPipeline.isEmpty)
    let add = RequestRun.additions(for: command)
    #expect(!add.include)
    #expect(!add.writeOut)

    #expect(RequestRun.note(for: command) == "Pipeline present: headers and timing unavailable")
}

@Test func aRedirectedCommandGetsTheRedirectionNote() throws {
    let command = try #require(CurlCommand.parse("curl https://example.com > out.json"))
    #expect(!command.trailingPipeline.isEmpty)
    let add = RequestRun.additions(for: command)
    #expect(!add.include)
    #expect(!add.writeOut)

    #expect(RequestRun.note(for: command) == "Output redirected: headers and timing unavailable")
}

@Test func aStandaloneCommandHasNoNote() throws {
    let command = try #require(CurlCommand.parse("curl https://example.com"))
    #expect(RequestRun.note(for: command) == nil)
}

@Test func userWriteOutIsKept() throws {
    let command = try #require(CurlCommand.parse("curl -w '%{http_code}' https://example.com"))
    let add = RequestRun.additions(for: command)
    #expect(!add.writeOut)

    let line = RequestRun.commandLine(for: command)
    let reparsed = try #require(CurlCommand.parse(line))
    #expect(reparsed.output.writeOut?.text == "%{http_code}")
}

@Test func silentWithoutShowErrorAddsS() throws {
    let command = try #require(CurlCommand.parse("curl -s https://example.com"))
    let add = RequestRun.additions(for: command)
    #expect(add.silent)

    let line = RequestRun.commandLine(for: command)
    let reparsed = try #require(CurlCommand.parse(line))
    #expect(reparsed.flags.contains(.silent))
    #expect(reparsed.flags.contains(.showError))
}

@Test func addedFlagsJoinAnExistingShortFlagGroup() throws {
    // 03-github-api is `curl -L ...`; the silent addition must land in the same short-flag group
    // as the `-L` that was already there, not open a second one.
    let command = try CurlFixtures.command("03-github-api")
    let line = RequestRun.commandLine(for: command)
    let reparsed = try #require(CurlCommand.parse(line))
    #expect(reparsed.flags.contains(.location))
    #expect(reparsed.flags.contains(.silent))
    #expect(reparsed.flags.contains(.showError))
    #expect(line.hasPrefix("curl -sSL"), "\(line)")
}

@Test func additionsDoNotMutateTheModel() throws {
    // `command` is a `let`: if `additions(for:)` or `commandLine(for:)` ever needed `inout`, this
    // test would fail to compile rather than silently pass on a copy.
    let command = try #require(CurlCommand.parse("curl -s https://example.com"))
    _ = RequestRun.additions(for: command)
    let line = RequestRun.commandLine(for: command)
    let unchanged = try #require(CurlCommand.parse("curl -s https://example.com"))
    #expect(command == unchanged)
    #expect(!line.isEmpty)
}
