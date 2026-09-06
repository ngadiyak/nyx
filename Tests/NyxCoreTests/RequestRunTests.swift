import Testing
@testable import NyxCore

@Test func plainGetGetsAllThree() throws {
    let command = try #require(CurlCommand.parse("curl https://example.com"))
    let add = RequestRun.additions(for: command)
    #expect(add == RequestRun.Additions(silent: true, include: true, writeOut: true))

    let line = RequestRun.commandLine(for: command)
    // The `-w` argument must be curl's own escapes, quoted exactly as a person would type them --
    // not Swift's actual newline -- or curl never expands them into the sentinel line.
    #expect(line.contains("-w '\\n--nyx-http-- %{http_code} %{time_total} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{size_download} %{num_redirects} %{content_type}\\n'"), "\(line)")
    #expect(line.hasSuffix("https://example.com"), "URL should still be last: \(line)")

    let reparsed = try #require(CurlCommand.parse(line))
    #expect(reparsed.flags.contains(.silent))
    #expect(reparsed.flags.contains(.showError))
    #expect(reparsed.flags.contains(.include))
    #expect(reparsed.output.writeOut?.text == RequestRun.writeOutArgument)

    // The word `-w` hands the shell is the exact value curl will expand -- not something a quoting
    // bug turned into two words, or curl's argv[1] would already be wrong before it ever runs.
    let words = try #require(ShellWords.split(line))
    let flagIndex = try #require(words.firstIndex { $0.text == "-w" })
    #expect(words[flagIndex + 1].text == RequestRun.writeOutArgument)
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

// MARK: - Taking the additions back off

/// The law, over the whole fixture corpus: a command that has been through a run and back is the
/// same request, carries none of Nyx's markers, and would run to exactly the same line again.
///
/// This is what stops `-sSi -w '<sentinel>'` leaking out of a workbench-run block into the button
/// somebody saves, the HTTPie they paste into a ticket, or the form they reopen.
///
/// Not `stripped == command`, because that law is unsatisfiable and saying so is the point:
/// `curl -sS URL` and `curl URL` produce the *same* run line, so the `-sS` a fixture typed itself
/// cannot be told from the one Nyx added. Four of the twelve fixtures (06 `-sS`, 09 `-i`,
/// 10 `-s`, 12 `-sS`) are in exactly that position. Everything that is recoverable is asserted
/// here, and the one thing that is not is bounded: the difference can only ever be flags out of
/// Nyx's own set, and never something added.
@Test func everyFixtureSurvivesARunAndBack() throws {
    for name in CurlFixtures.all {
        let command = try CurlFixtures.command(name)
        let ran = try #require(CurlCommand.parse(RequestRun.commandLine(for: command)), "\(name)")
        let stripped = RequestRun.stripAdditions(from: ran)

        #expect(stripped.output.writeOut?.text != RequestRun.writeOutArgument, "\(name)")
        // Every part of the request that is not a flag comes back exactly as it was.
        var withoutFlags = stripped
        withoutFlags.flags = command.flags
        #expect(withoutFlags == command, "\(name)")
        // And it is still the same request to run: the line Nyx would build from it is identical.
        #expect(RequestRun.commandLine(for: stripped) == RequestRun.commandLine(for: command), "\(name)")
        // Nothing was invented, and nothing outside Nyx's own three flags was lost.
        let lost = command.flags.subtracting(stripped.flags)
        #expect(stripped.flags.isSubset(of: command.flags), "\(name)")
        #expect(lost.isSubset(of: [.include, .silent, .showError]), "\(name)")
    }
}

/// A line nobody ran through the workbench comes back untouched. `-sS` alone is not the set the
/// additions would produce for `curl https://example.com` -- that set also carries `-i` and the
/// sentinel -- so it is the user's and it stays.
@Test func aUsersOwnFlagsAreNotMistakenForNyxs() throws {
    let command = try #require(CurlCommand.parse("curl -sS https://example.com"))
    #expect(RequestRun.stripAdditions(from: command) == command)
    let withInclude = try #require(CurlCommand.parse("curl -i https://example.com"))
    #expect(RequestRun.stripAdditions(from: withInclude) == withInclude)
    let plain = try #require(CurlCommand.parse("curl https://example.com"))
    #expect(RequestRun.stripAdditions(from: plain) == plain)
}

/// A `-w` somebody wrote themselves is data the command needs and survives; the run flags around
/// it do not, because `-sSi` in front of a user's own `-w` is exactly what a run of it looks like.
@Test func someoneElsesWriteOutSurvivesTheStrip() throws {
    let command = try #require(CurlCommand.parse("curl -sSi -w '%{http_code}' https://example.com"))
    let stripped = RequestRun.stripAdditions(from: command)
    #expect(stripped.output.writeOut?.text == "%{http_code}")
    #expect(stripped.flags.isEmpty)
}

/// What a workbench-run block's command line actually looks like, taken apart: no `-i`, no `-sS`,
/// no `-w`, and every header the user added still there.
@Test func aWorkbenchRunLineComesBackAsWhatWasTyped() throws {
    let typed = try #require(CurlCommand.parse("curl -H 'x-nyx: 1' https://api.example.com/v1/users"))
    let ran = try #require(CurlCommand.parse(RequestRun.commandLine(for: typed)))
    #expect(ran.flags.contains(.include))
    #expect(ran.output.writeOut != nil)
    let stripped = RequestRun.stripAdditions(from: ran)
    #expect(stripped == typed)
    let line = stripped.shellLine(masking: .none, layout: .oneLine)
    #expect(line == "curl -H 'x-nyx: 1' https://api.example.com/v1/users", "\(line)")
}
