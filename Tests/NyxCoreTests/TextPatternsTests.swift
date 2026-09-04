import Testing
@testable import NyxCore

private let separators = Set(" ()[]{}'\"`,;:|<>")

private func kind(_ line: String, at column: Int) -> TokenKind? {
    TextPatterns.token(at: column, in: line)?.kind
}

private func text(_ line: String, at column: Int) -> String? {
    TextPatterns.token(at: column, in: line)?.text
}

// MARK: - URLs

@Test func aUrlIsFoundWholeWhereverInsideItYouPoint() {
    let line = "see https://example.com/a/b?q=1 for details"
    for column in 4..<31 {
        #expect(text(line, at: column) == "https://example.com/a/b?q=1", "column \(column)")
    }
}

/// Trailing punctuation belongs to the sentence, not the link -- opening a URL with a comma glued
/// to the end of it is the classic version of this bug.
@Test func punctuationAfterAUrlIsNotPartOfIt() {
    #expect(text("go to https://example.com, then leave", at: 10) == "https://example.com")
    #expect(text("(https://example.com)", at: 5) == "https://example.com")
}

@Test func aSchemeOtherThanHttpStillCounts() {
    #expect(kind("ssh://box.local/x", at: 2) == .url)
    #expect(kind("file:///Users/nik/notes.txt", at: 2) == .url)
}

// MARK: - Paths

@Test func anAbsolutePathIsRecognised() {
    #expect(text("/Users/nik/projects/nyx/README.md", at: 5) == "/Users/nik/projects/nyx/README.md")
    #expect(kind("/etc/hosts", at: 2) == .path(line: nil, column: nil))
}

@Test func aHomeOrRelativePathIsRecognised() {
    #expect(text("~/.config/nyx/config", at: 3) == "~/.config/nyx/config")
    #expect(text("edit ./src/main.swift now", at: 8) == "./src/main.swift")
    #expect(text("see ../sibling/file.txt", at: 6) == "../sibling/file.txt")
}

/// The reason this feature exists: jumping straight to the line a compiler complained about.
@Test func aCompilerLocationCarriesItsLineAndColumn() {
    #expect(kind("Sources/App/Main.swift:42:7: error: bad", at: 4) == .path(line: 42, column: 7))
    #expect(text("Sources/App/Main.swift:42:7: error: bad", at: 4) == "Sources/App/Main.swift:42:7")
    #expect(kind("/tmp/x.log:9: warning", at: 2) == .path(line: 9, column: nil))
}

@Test func abareFilenameWithAnExtensionIsAPath() {
    #expect(kind("open README.md please", at: 6) == .path(line: nil, column: nil))
    #expect(text("open README.md please", at: 6) == "README.md")
}

/// A URL contains slashes and dots, so a path pattern will happily claim one. Order matters.
@Test func aUrlIsNotMistakenForAPath() {
    #expect(kind("https://example.com/a/b.txt", at: 3) == .url)
}

// MARK: - Hashes, addresses, mail

@Test func aCommitHashIsRecognised() {
    #expect(kind("commit f368db7 landed", at: 8) == .commitHash)
    #expect(kind("at 8e5440b60b59f4929f169aabbccddeeff001122 exactly", at: 5) == .commitHash)
}

/// A run of digits is a number -- a line count, a byte size, a PID -- and treating it as a git
/// object would make half the output of `ls -l` clickable.
@Test func aPlainNumberIsNotACommitHash() {
    #expect(kind("total 1234567 bytes", at: 8) != .commitHash)
}

@Test func addressesAndMailAreRecognised() {
    #expect(kind("listening on 192.168.1.14 now", at: 15) == .ipAddress)
    #expect(kind("mail nik@example.com about it", at: 8) == .email)
}

// MARK: - Nothing there

@Test func plainProseHasNoStructuredTokens() {
    #expect(TextPatterns.tokens(in: "the quick brown fox jumps").isEmpty)
    #expect(kind("the quick brown fox", at: 5) == nil)
}

@Test func tokensNeverOverlap() {
    let tokens = TextPatterns.tokens(in: "https://example.com/x.txt and /etc/hosts and 10.0.0.1")
    for (a, b) in zip(tokens, tokens.dropFirst()) {
        #expect(a.columns.upperBound <= b.columns.lowerBound)
    }
}

// MARK: - Double-click behaviour

/// Double-clicking a path selects the whole path, not the fragment between two slashes. This is
/// the difference the feature is for.
@Test func doubleClickTakesTheWholeStructuredTokenNotJustTheWord() {
    let line = "error in /Users/nik/projects/nyx/README.md today"
    let token = try! #require(TextPatterns.selectionToken(at: 20, in: line, separators: separators))
    #expect(token.text == "/Users/nik/projects/nyx/README.md")
}

@Test func doubleClickFallsBackToTheWordWhenNothingStructuredIsThere() {
    let token = try! #require(TextPatterns.selectionToken(at: 6, in: "the quick brown fox",
                                                          separators: separators))
    #expect(token.text == "quick")
    #expect(token.kind == .word)
}

@Test func doubleClickOnASeparatorSelectsNothing() {
    #expect(TextPatterns.selectionToken(at: 3, in: "the quick", separators: separators) == nil)
}

@Test func doubleClickPastTheEndOfTheLineSelectsNothing() {
    #expect(TextPatterns.selectionToken(at: 99, in: "short", separators: separators) == nil)
}

// MARK: - Wide characters

/// A wide glyph is one character in two columns. Without the mapping every token to its right
/// would be reported one column too far left, and ⌘-clicking a link would open the wrong thing --
/// or nothing.
@Test func columnsAreMappedThroughWideCharacters() {
    let line = "日本 https://example.com"
    // Columns: 日=0, 本=2, space=4, url starts at 5.
    let columnOf = [0, 2, 4] + Array(5..<(5 + "https://example.com".count))
    let token = try! #require(TextPatterns.token(at: 7, in: line, columnOf: columnOf))
    #expect(token.text == "https://example.com")
    #expect(token.columns.lowerBound == 5)
}

@Test func aClickOnTheSecondCellOfAWideGlyphBelongsToThatGlyph() {
    let line = "日本語"
    let columnOf = [0, 2, 4]
    let token = try! #require(TextPatterns.word(at: 3, in: line, separators: separators,
                                                columnOf: columnOf))
    #expect(token.text == "日本語")
}
