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
