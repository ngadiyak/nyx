import Foundation

/// What a host sends an attaching client to draw before the live stream starts.
public enum RemoteSnapshot {
    /// Drops the blank lines a screen's transcript ends with, including the final line ending.
    ///
    /// `Transcript` ends *every* row it is asked for with `\r\n`, blank ones included, because a
    /// saved scrollback is a range of rows and each of them is a line. A host's screen is mostly
    /// blank rows below the cursor -- 73 of them on a 74-row window at a fresh prompt -- so the
    /// snapshot sent as-is was one line of prompt followed by 73 newlines. The client fed all of
    /// it, its own grid scrolled by 73, and an attach drew a blank terminal with the host's screen
    /// pushed off the top; everything the host wrote afterwards then landed 73 rows lower there
    /// than it did on the host. Two instances against the live relay showed exactly that.
    ///
    /// Dropping the last line ending as well as the empty lines is deliberate: it leaves the
    /// client's cursor at the end of the host's last written row -- where the host's own cursor is
    /// at a prompt -- rather than one row below it.
    ///
    /// A row that carried nothing but a shell mark (`OSC 133`) is not empty and is kept: it is the
    /// prompt boundary the client's blocks, folds and ⌘↑ are drawn from.
    ///
    /// `\r\n` only, because a snapshot is transcribed with `Transcript.Options.forRestoring`, whose
    /// whole point is that a bare `\n` would come back as a staircase.
    public static func trimmingTrailingBlankLines(_ transcript: String) -> String {
        var text = transcript
        while text.hasSuffix("\r\n") { text.removeLast(2) }
        return text
    }
}
