import Testing
@testable import NyxCore

// MARK: - Parsing

@Test func allThreeFieldsAreParsed() {
    let a = try! #require(QuickAction.parse("Caffeine | toggle | caffeinate -d"))
    #expect(a.name == "Caffeine")
    #expect(a.kind == .toggle)
    #expect(a.command == "caffeinate -d")
}

/// The common case is "type this into the pane", so it should cost the least typing to configure.
@Test func theKindMayBeLeftOutAndDefaultsToSend() {
    let a = try! #require(QuickAction.parse("Deploy | ./deploy.sh"))
    #expect(a.kind == .send)
    #expect(a.command == "./deploy.sh")
}

/// A command with a pipe in it is an ordinary thing to want, and splitting on every separator would
/// quietly cut it in half.
@Test func aCommandMayContainPipes() {
    let a = try! #require(QuickAction.parse("Logs | run | tail -f /var/log/system.log | grep err"))
    #expect(a.command == "tail -f /var/log/system.log | grep err")
    #expect(a.kind == .run)
}

@Test func surroundingWhitespaceIsTrimmed() {
    let a = try! #require(QuickAction.parse("  Caffeine  |  toggle  |  caffeinate -d  "))
    #expect(a.name == "Caffeine")
    #expect(a.command == "caffeinate -d")
}

@Test func theKindIsCaseInsensitive() {
    #expect(QuickAction.parse("A | TOGGLE | x")?.kind == .toggle)
    #expect(QuickAction.parse("A | Run | x")?.kind == .run)
}

@Test func malformedLinesAreRejectedRatherThanGuessedAt() {
    #expect(QuickAction.parse("just a name") == nil)          // no command at all
    #expect(QuickAction.parse("A | fly | x") == nil)          // not a kind we have
    #expect(QuickAction.parse(" | toggle | x") == nil)        // nameless
    #expect(QuickAction.parse("A | toggle | ") == nil)        // no command
    #expect(QuickAction.parse("") == nil)
}

// MARK: - Sending

/// The newline is the point: a command left sitting on the prompt has not been run, and a button
/// that half-does its job is worse than no button.
@Test func aSendActionEndsWithANewlineSoItActuallyRuns() {
    let a = try! #require(QuickAction.parse("Deploy | send | ./deploy.sh"))
    #expect(String(decoding: a.bytesToSend, as: UTF8.self) == "./deploy.sh\n")
}

// MARK: - Splitting into arguments

/// A background command runs detached rather than through a shell, so it has to be split up.
@Test func aToggleCommandSplitsIntoAnExecutableAndArguments() {
    #expect(QuickAction.parse("C | toggle | caffeinate -d")?.argv == ["caffeinate", "-d"])
    #expect(QuickAction.parse("C | toggle | caffeinate")?.argv == ["caffeinate"])
}

@Test func runsOfWhitespaceDoNotProduceEmptyArguments() {
    #expect(QuickAction.parse("C | toggle | caffeinate   -d  -i")?.argv == ["caffeinate", "-d", "-i"])
}

/// Paths with spaces in them are normal on macOS, and passing `/Applications/My` and `App` as two
/// arguments would be a puzzling failure.
@Test func quotedArgumentsStayWhole() {
    #expect(QuickAction.parse("C | toggle | say \"hello there\"")?.argv == ["say", "hello there"])
    #expect(QuickAction.parse("C | toggle | ls '/Users/me/My Files'")?.argv == ["ls", "/Users/me/My Files"])
}

@Test func anEmptyQuotedArgumentIsStillAnArgument() {
    #expect(QuickAction.parse("C | toggle | grep \"\" file")?.argv == ["grep", "", "file"])
}

@Test func aQuoteInsideAWordJoinsRatherThanSplits() {
    #expect(QuickAction.parse("C | toggle | echo abc\"def ghi\"")?.argv == ["echo", "abcdef ghi"])
}
