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
    ///
    /// `removeLast()` and not `removeLast(2)`: `"\r\n"` is **one** `Character` -- CRLF is a single
    /// extended grapheme cluster -- so removing two took the line ending *and the character before
    /// it*. It went unnoticed because it only bites on an odd number of trailing line endings, and
    /// a screen whose last written row is its first (one prompt on a fresh window) has an even one;
    /// a host with two written rows loses the last character of its screen, which on a real attach
    /// read as `got:g` for `got:go` and `"x" [New` for `"x" [New]`.
    public static func trimmingTrailingBlankLines(_ transcript: String) -> String {
        var text = transcript
        while text.hasSuffix("\r\n") { text.removeLast() }
        return text
    }

    /// The bytes a client feeds to become a mirror of the host.
    ///
    /// A host inside a full-screen program is two things at once: a shell buffer with a command
    /// history in it, and a program owning the screen. Sent as one flat transcript, the client got
    /// the program's rows in its *primary* buffer -- so its block history was gone (one block where
    /// the host had seven: no ⌘↑, no folds, no Copy Output, no sticky prompt for that tab, ever),
    /// and when the program exited its `DECRST 1049` had nothing to restore, leaving the tildes on
    /// screen with the prompt underneath them.
    ///
    /// So the snapshot says what it is, in the only language the mirror speaks: the primary buffer
    /// with its marks, then the same `DECSET 1049` the program itself sent, then the program's
    /// screen, then the host's cursor. Nothing new on the wire and nothing new in the client: the
    /// client's own parser puts each half where the host has it.
    ///
    /// `cursor` is one-based row/column as `CUP` counts them, and is written only when there is an
    /// alternate screen: a primary transcript already leaves the cursor at the end of the host's
    /// last written row (see `trimmingTrailingBlankLines`), and moving it again would take it off
    /// the prompt.
    public static func compose(primary: String, alternate: String?,
                               cursor: (row: Int, col: Int)?) -> String {
        guard let alternate else { return primary }
        // `\u{1b}[H` before the screen text because `DECSET 1049` clears the buffer it switches to
        // and leaves the cursor where the primary one had it.
        var out = primary + "\u{1b}[?1049h\u{1b}[H" + alternate
        if let cursor {
            out += "\u{1b}[\(cursor.row + 1);\(cursor.col + 1)H"
        }
        return out
    }

    /// What precedes a *second* snapshot into a terminal that already holds one.
    ///
    /// A re-snapshot used to be appended, which is how a client ended a five-minute idle with 3308
    /// rows against the host's 2007, rows of five concatenated prompts, and eight copies of a
    /// marker the host printed once. RIS resets the screen, the modes and the pen; `ED 3` discards
    /// the scrollback, which RIS deliberately keeps. Both are sequences the mirror already
    /// implements, so the replacement costs no new code path on the receiving side.
    ///
    /// RIS also replaces the terminal's `modes` wholesale (`Terminal.swift:670`), so a re-snapshot
    /// discards the host modes the live stream had accumulated in the mirror -- mouse reporting,
    /// bracketed paste, the cursor shape -- until the host's program sets them again. That is the
    /// right trade against a mirror with a hole in it, and it is why a re-snapshot is the exception
    /// rather than what every reconnect does; before this plan it was what every reconnect did.
    public static let reset = "\u{1b}c\u{1b}[3J"
}
