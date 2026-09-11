import Testing
@testable import NyxCore

private func write(_ key: String, _ value: String, into text: String) -> String {
    ConfigWriter.setting(key, to: value, in: text)
}

/// The round trip that matters: whatever the writer produces, the parser has to read back as the
/// value that was written. Everything else here is about *how* the file survives that.
private func roundTrip(_ key: String, _ value: String, in text: String) -> Config {
    ConfigParser.parse(write(key, value, into: text)).config
}

@Test func settingAnExistingLineReplacesItsValue() {
    let out = write("font-size", "18", into: "font-family = Menlo\nfont-size = 13\n")
    #expect(out.contains("font-size = 18"))
    #expect(!out.contains("font-size = 13"))
    #expect(roundTrip("font-size", "18", in: "font-size = 13").fontSize == 18)
}

/// The shipped default file has every setting present but commented out. Uncommenting that line in
/// place keeps the setting under the heading the file put it under, instead of orphaning a copy at
/// the bottom while the commented original still sits above it looking authoritative.
@Test func settingACommentedDefaultUncommentsThatLineInPlace() {
    let text = """
    # --- Font ---
    # font-family = Menlo
    # font-size = 13
    # line-height = 1.0
    """
    let out = write("font-size", "18", into: text)
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines[2] == "font-size = 18")
    #expect(lines[0] == "# --- Font ---")       // the heading survives
    #expect(lines[1] == "# font-family = Menlo") // its neighbours stay commented
    #expect(lines[3] == "# line-height = 1.0")
}

@Test func settingAnAbsentKeyAppendsIt() {
    let out = write("padding", "16", into: "font-size = 13")
    #expect(out.hasSuffix("padding = 16\n"))
    #expect(out.contains("font-size = 13"))
    #expect(ConfigParser.parse(out).config.padding == 16)
}

/// Comments a human wrote are the reason this is not just "rewrite the file from `Config`".
@Test func commentsBlankLinesAndUnknownKeysAllSurvive() {
    let text = """
    # my notes, please keep
    font-size = 13

    # something Nyx does not know about
    experimental-thing = 7
    """
    let out = write("font-size", "18", into: text)
    #expect(out.contains("# my notes, please keep"))
    #expect(out.contains("experimental-thing = 7"))
    #expect(out.contains("\n\n"))               // the blank line is still there
    #expect(out.contains("font-size = 18"))
}

@Test func aTrailingCommentOnTheEditedLineIsKept() {
    let out = write("font-size", "18", into: "font-size = 13  # bumped for the big monitor")
    #expect(out.contains("18"))
    #expect(out.contains("# bumped for the big monitor"))
    #expect(ConfigParser.parse(out).config.fontSize == 18)
}

/// `ConfigParser` lets a later line win, so the later line is the one in force and the one an edit
/// has to change. Rewriting the first would look like the edit did nothing.
@Test func aKeyPresentTwiceIsEditedWhereItTakesEffect() {
    let out = write("font-size", "18", into: "font-size = 13\nfont-size = 15")
    let lines = out.split(separator: "\n").map(String.init)
    #expect(lines[0] == "font-size = 13")
    #expect(lines[1] == "font-size = 18")
    #expect(ConfigParser.parse(out).config.fontSize == 18)
}

/// A line the user deliberately double-commented is theirs, not the shipped default line.
@Test func aDoubleCommentedLineIsNotTreatedAsTheDefaultLine() {
    let out = write("font-size", "18", into: "## font-size = 13")
    #expect(out.contains("## font-size = 13"))   // untouched
    #expect(out.contains("\nfont-size = 18"))    // appended instead
}

@Test func indentationAndSpacingAroundTheEqualsAreLeftAlone() {
    #expect(write("font-size", "18", into: "  font-size = 13").hasPrefix("  font-size = 18"))
    #expect(write("font-size", "18", into: "font-size=13") == "font-size=18\n")
}

@Test func writingIntoAnEmptyFileProducesAParseableLine() {
    #expect(ConfigParser.parse(write("font-size", "18", into: "")).config.fontSize == 18)
}

@Test func severalSettingsCanBeWrittenInOnePass() {
    let out = ConfigWriter.settings([("font-size", "18"), ("padding", "16"), ("cursor-style", "bar")],
                                    in: Config.defaultFileText)
    let (config, diagnostics) = ConfigParser.parse(out)
    #expect(diagnostics.isEmpty)
    #expect(config.fontSize == 18)
    #expect(config.padding == 16)
    #expect(config.cursorStyle == .bar)
}

/// Writing every scalar setting into the shipped file must leave a file that still parses cleanly.
/// This is the test that catches a value spelled one way by the window and another by the parser.
@Test func everySettingWrittenIntoTheShippedFileStillParsesCleanly() {
    let values: [(String, String)] = [
        ("font-family", "Menlo"), ("font-size", "15"), ("line-height", "1.2"),
        ("font-thicken", "true"), ("theme", "nyx-light"), ("cursor-style", "underline"),
        ("cursor-blink", "false"), ("scrollback-lines", "5000"), ("padding", "12"),
        ("background-opacity", "0.9"), ("background-blur", "20"), ("copy-on-select", "true"),
        ("middle-click-paste", "false"), ("option-as-meta", "both"), ("bell", "none"),
        ("confirm-close-process", "false"), ("tab-bar", "always"), ("window-decorations", "false"),
        ("restore-session", "false"),
    ]
    let out = ConfigWriter.settings(values.map { (key: $0.0, value: $0.1) }, in: Config.defaultFileText)
    let (config, diagnostics) = ConfigParser.parse(out)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    #expect(config.fontSize == 15)
    #expect(config.themeName == "nyx-light")
    #expect(config.cursorStyle == .underline)
    #expect(config.optionAsMeta == .both)
    #expect(config.tabBar == .always)
    #expect(config.backgroundBlur == 20)
}

// MARK: - Rewriting a whole list

private func list(_ values: [String], into text: String) -> String {
    ConfigWriter.settingList("quick", values: values, in: text)
}

private func quickLines(_ text: String) -> [String] {
    ConfigParser.parse(text).config.quickActions.map { "\($0.name)|\($0.kind.rawValue)|\($0.command)" }
}

@Test func aListReplacesEveryLineInOrder() {
    let text = """
    quick = A | toggle | a
    quick = B | b
    """
    let out = list(["C | toggle | c", "D | d"], into: text)
    #expect(quickLines(out) == ["C|toggle|c", "D|send|d"])
}

/// Adding a button must not scatter one list across two places in the file.
@Test func anExtraValueGoesRightAfterTheLastExistingLine() {
    let text = """
    # buttons
    quick = A | a
    quick = B | b

    font-size = 15
    """
    let out = list(["A | a", "B | b", "C | c"], into: text)
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines[3] == "quick = C | c")
    #expect(out.contains("font-size = 15"))
    #expect(out.contains("# buttons"))
}

/// Removing takes the surplus from the back, so the lines that survive keep their positions and
/// whatever comments were written above them stay attached to the right entries.
@Test func removingShrinksTheListFromTheBack() {
    let text = """
    quick = A | a
    quick = B | b
    quick = C | c
    """
    #expect(quickLines(list(["A | a"], into: text)) == ["A|send|a"])
}

@Test func aFileWithNoSuchKeyGetsTheWholeListAppended() {
    let out = list(["A | a", "B | b"], into: "font-size = 14")
    #expect(out.hasPrefix("font-size = 14"))
    #expect(quickLines(out) == ["A|send|a", "B|send|b"])
}

@Test func anEmptyListRemovesEveryLine() {
    let out = list([], into: "quick = A | a\nquick = B | b\nfont-size = 14")
    #expect(quickLines(out).isEmpty)
    #expect(out.contains("font-size = 14"))
}

/// Commented-out examples are the user's notes, not entries, and must survive being edited around.
@Test func commentedExamplesAreNotTouched() {
    let text = """
    # quick = Example | echo hi
    quick = A | a
    """
    let out = list(["A | a", "B | b"], into: text)
    #expect(out.contains("# quick = Example | echo hi"))
    #expect(quickLines(out) == ["A|send|a", "B|send|b"])
}

/// Whatever the interface writes has to read back as what it wrote.
@Test func aListWrittenFromTheInterfaceRoundTrips() {
    let actions = [
        QuickAction(name: "Caffeine", kind: .toggle, command: "caffeinate -d"),
        QuickAction(name: "Logs", kind: .run, command: "tail -f x | grep err"),
        QuickAction(name: "Deploy", kind: .send, command: "./deploy.sh"),
    ]
    let values = actions.map { "\($0.name) | \($0.kind.rawValue) | \($0.command)" }
    let out = ConfigWriter.settingList("quick", values: values, in: Config.defaultFileText)
    let parsed = ConfigParser.parse(out)
    #expect(parsed.diagnostics.isEmpty)
    #expect(parsed.config.quickActions == actions)
}

// MARK: - Comment-exempt keys

/// The bug: `ConfigWriter.replacingValue` used to look for a `#` in the *old* line's tail and keep
/// everything from there on as "the human's trailing comment" -- which is right for an ordinary
/// key, but for a comment-exempt key (`ConfigGrammar.commentExemptKeys`) the `#` was never a
/// comment, it was part of the value `ConfigParser` never stripped. Writing a new value over an old
/// one that happened to contain `#` kept a fragment of the *old* value stuck onto the new one.
@Test func writingOverACommentExemptValueContainingHashReplacesItWhole() {
    for key in ["remote-relay-token", "open-file-command", "quick"] {
        let old = key == "quick" ? "Note | send | echo '#1'" : "abc#123"
        let new = key == "quick" ? "Note | send | echo new #2 value" : "xyz#456 with spaces"
        let out = write(key, new, into: "\(key) = \(old)")
        #expect(out == "\(key) = \(new)\n", "\(key): got \(out)")
    }
}

/// The same replacement, read back: the parser must see exactly the new value, not the new value
/// plus a leftover piece of the old one.
@Test func aCommentExemptValueContainingHashRoundTripsAfterBeingOverwritten() {
    let out = write("remote-relay-token", "xyz#456 with spaces",
                    into: "remote-relay-token = abc#123")
    #expect(ConfigParser.parse(out).config.remoteRelayToken == "xyz#456 with spaces")
}

/// A non-exempt key is unaffected: it still keeps its trailing comment, `#` and all. (The writer
/// always puts exactly one space before a kept comment, regardless of how many separated it from
/// the old value -- `replacingValue`'s existing behaviour, not something this fix changes.)
@Test func aNonExemptKeyStillKeepsItsTrailingComment() {
    let out = write("font-size", "18", into: "font-size = 13  # bumped for the big monitor")
    #expect(out == "font-size = 18 # bumped for the big monitor\n")
}

/// The owner's config file gained `remote = onremote-relay-token = …` on 2026-09-07. The writer
/// returned text with no trailing newline, so the very next thing appended to that file by any
/// other means -- `cat token >> ~/.config/nyx/config`, which is the documented way to set the
/// token -- glued itself onto the last line. One newline, exactly one, on every result.
@Test func everyWrittenFileEndsWithExactlyOneNewline() {
    for text in ["", "font-size = 13", "font-size = 13\n", "font-size = 13\n\n\n",
                 Config.defaultFileText] {
        let out = ConfigWriter.setting("padding", to: "16", in: text)
        #expect(out.hasSuffix("\n"), "no trailing newline for \(text.debugDescription)")
        #expect(!out.hasSuffix("\n\n"), "more than one for \(text.debugDescription)")
        // Idempotent, because `settings` reduces over `setting`: a second pass must not grow it.
        #expect(ConfigWriter.setting("padding", to: "16", in: out) == out)
    }
}

@Test func aListWriteEndsTheSameWay() {
    let out = ConfigWriter.settingList("quick", values: ["A | send | echo a"], in: "padding = 4")
    #expect(out.hasSuffix("\n"))
    #expect(!out.hasSuffix("\n\n"))
}

/// And the parser does not need one, which is the other half of the finding: a file somebody else
/// wrote, or an older Nyx wrote, still parses.
@Test func aFileWithNoTrailingNewlineParses() {
    #expect(ConfigParser.parse("remote = on\nremote-relay = wss://r/v1/ws").config.remote == .on)
    #expect(ConfigParser.parse("padding = 12").config.padding == 12)
}
