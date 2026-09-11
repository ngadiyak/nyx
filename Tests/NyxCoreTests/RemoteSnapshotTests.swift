import Foundation
import Testing
@testable import NyxCore

// MARK: - The snapshot a host sends an attaching client

/// The rung-6 run of two instances against the live relay attached to a host whose 74-row screen
/// held one prompt line. The client drew a blank terminal: `Transcript` ends *every* row with a
/// line ending, blank ones included, so the client fed 73 newlines after the prompt and pushed the
/// host's whole screen off the top of its grid.
@Test func aScreenWithOneLineAndBlanksBelowItArrivesAsThatOneLine() {
    let screen = "nik@mac ~ %\r\n" + String(repeating: "\r\n", count: 73)
    #expect(RemoteSnapshot.trimmingTrailingBlankLines(screen) == "nik@mac ~ %")
}

/// Blank lines a person can see between two commands are content, not padding.
@Test func blankLinesBetweenTwoCommandsSurvive() {
    #expect(RemoteSnapshot.trimmingTrailingBlankLines("first\r\n\r\nsecond\r\n\r\n") == "first\r\n\r\nsecond")
}

@Test func anEmptyBufferStaysEmpty() {
    #expect(RemoteSnapshot.trimmingTrailingBlankLines(String(repeating: "\r\n", count: 24)) == "")
    #expect(RemoteSnapshot.trimmingTrailingBlankLines("") == "")
}

/// A row that carries nothing but a shell mark is not blank: dropping it would lose the prompt
/// boundary the client draws blocks and folds from.
@Test func aRowThatIsOnlyAPromptMarkIsKept() {
    let text = "output\r\n\u{1b}]133;A\u{7}\r\n\r\n"
    #expect(RemoteSnapshot.trimmingTrailingBlankLines(text) == "output\r\n\u{1b}]133;A\u{7}")
}

// MARK: - A snapshot of a host that is inside a full-screen program

/// The snapshot is ANSI, which is what lets it describe a host that is *in* a full-screen program
/// rather than merely showing one: the primary buffer with its marks, then the switch the program
/// itself made, then the program's screen, then where the cursor is. The client's own parser does
/// the rest -- and when the program exits, its `DECRST 1049` has the primary buffer to restore.
@Test func aComposedSnapshotPutsTheAltScreenOnTopOfThePrimaryOne() {
    let text = RemoteSnapshot.compose(primary: "$ vim x\r\n", alternate: "~\r\n\"x\" [New]",
                                      cursor: (row: 2, col: 5))
    #expect(text == "$ vim x\r\n\u{1b}[?1049h\u{1b}[H~\r\n\"x\" [New]\u{1b}[3;6H")
}

@Test func aHostOnItsOrdinaryScreenComposesToJustTheTranscript() {
    #expect(RemoteSnapshot.compose(primary: "$ ls\r\nfile", alternate: nil, cursor: nil)
        == "$ ls\r\nfile")
    // A cursor without an alternate screen is not written: the primary transcript already leaves
    // the client's cursor at the end of the host's last written row (see
    // `trimmingTrailingBlankLines`), and a CUP here would move it off the prompt.
    #expect(RemoteSnapshot.compose(primary: "$ ls\r\nfile", alternate: nil, cursor: (row: 0, col: 0))
        == "$ ls\r\nfile")
}

/// A *second* snapshot into a terminal that already holds one is what produced 3308 rows against
/// the host's 2007, and rows reading `nik@nik-newmac ~ % nik@nik-newmac ~ % …`: it was appended.
/// A re-snapshot therefore replaces the mirror, and the replacement is itself escape sequences --
/// RIS for the screen and modes, `ED 3` for the scrollback RIS deliberately keeps.
@Test func theResetPrefixEmptiesAMirrorBeforeItIsFilledAgain() {
    let t = Terminal(cols: 20, rows: 3, scrollbackLimit: 500)
    t.feed("UNIQUE_MARKER\r\n")
    for _ in 0..<10 { t.feed("filler\r\n") }
    #expect(t.transcript(options: .plainText).contains("UNIQUE_MARKER"))
    t.feed(RemoteSnapshot.reset)
    #expect(t.rowCount(of: .active) == t.rows)
    let after = t.transcript(options: .plainText)
    #expect(!after.contains("UNIQUE_MARKER"))
    #expect(!after.contains("filler"))
    t.feed("UNIQUE_MARKER\r\n")
    #expect(t.transcript(options: .plainText).components(separatedBy: "UNIQUE_MARKER").count - 1 == 1)
}
