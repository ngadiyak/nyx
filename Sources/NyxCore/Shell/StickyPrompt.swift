import Foundation

/// The command line to pin above the viewport while its output is being read.
public struct StickyPrompt: Equatable {
    /// The absolute row holding the command line -- what to draw in the pinned strip.
    public let row: Int
    /// Whether the command failed, so the strip can say so without the user scrolling back.
    public let failed: Bool
    /// nil while the command is still running.
    public let exitStatus: Int32?

    public init(row: Int, failed: Bool, exitStatus: Int32?) {
        self.row = row
        self.failed = failed
        self.exitStatus = exitStatus
    }
}

public extension Terminal {
    /// The command whose output fills the top of the viewport, or nil when there is nothing worth
    /// pinning.
    ///
    /// Scrolling through a long build leaves the command that produced it far above, and what is on
    /// screen becomes a wall of text with no attribution. Pinning its command line answers "what am
    /// I even looking at" without scrolling back to find out and losing your place.
    ///
    /// Returns nil when the prompt is already on screen -- pinning a copy of a line the user can
    /// already see wastes a row and reads as a rendering bug -- and nil when the shell emits no
    /// marks, since then there is no command line to name.
    func stickyPrompt(viewportTop: Int? = nil) -> StickyPrompt? {
        // The same gate the spine, the summary and the gutter obey. A band naming the command that
        // started vim, drawn over vim, is the chrome-that-does-not-step-aside bug this project
        // avoids everywhere else (Addendum 1) -- and on the alternate screen the pinned command's
        // exit status is gone as well, so the band was drawn over a TUI *and* lying about it.
        //
        // `hasMarks` carries the old `shellEmitsPromptMarks` guard, which is also why this is the
        // first line: without marks there is nothing to pin, and finding that out the slow way
        // means `previousPrompt` walking the whole scrollback -- under the session lock, on every
        // frame, for every shell without integration.
        guard CommandBlockChrome.isAllowed(altScreen: modes.altScreen,
                                           mouseReporting: modes.mouse != .none,
                                           hasMarks: shellEmitsPromptMarks) else { return nil }
        let top = viewportTop ?? viewportTopRow
        guard let region = command(containingAbsoluteRow: top) else { return nil }

        // The prompt is on screen already, so there is nothing to remind anyone of.
        guard region.promptRow < top else { return nil }

        // A command with no output has nothing to read, so nothing to lose track of. This also
        // keeps the strip from appearing over the prompt the user is typing at.
        guard let outputStart = region.outputStart, outputStart <= top else { return nil }

        return StickyPrompt(row: region.promptRow, failed: region.failed,
                            exitStatus: region.exitStatus)
    }
}

/// What the pinned strip reads, decided here rather than in the view.
///
/// One row is all there is, over a terminal whose rows are as wide as the font makes them, so the
/// text has to be collapsed and cut to fit -- and the cut has to be the same one a test can assert.
public enum StickyPromptLabel {
    /// The strip's text for a command, in at most `columns` columns.
    ///
    /// The command's rows arrive joined by spaces (`Terminal.commandText`), and a prompt string
    /// routinely contains runs of them for alignment; collapsing those is what makes a 40-column
    /// strip show the command rather than the padding in front of it.
    ///
    /// A failed command carries its status in the text as well as in the colour -- colour alone says
    /// "something is wrong here" to a reader who can see it and nothing at all to one who cannot --
    /// *unless* `summary` is already saying it at the other end of the same row.
    ///
    /// `summary` is the note the band draws right-aligned (`BlockHeader.summary`: `exit 2 · 8.8s`,
    /// `200 · 142 ms · 1.2 KB · json`). When it is there and there is room for both with a column
    /// between them, the text is the command and nothing else: `↑ $ make test  exit 2 … exit 2 ·
    /// 8.8s` said the status twice on one row, and the spoken sentence said it twice too. The
    /// suffix comes back only when the two do not fit, because the note is drawn at the right edge
    /// whatever happens and the text is what gets cut.
    ///
    /// Defaulted to `""` so a caller with no note -- a test, or any future band without one -- gets
    /// the old, self-sufficient text rather than silently losing the status.
    public static func text(command: String, exitStatus: Int32?, columns: Int,
                            summary: String = "") -> String {
        let status = (exitStatus ?? 0) != 0 ? "  exit \(exitStatus!)" : ""
        let body = collapsed(command)
        guard columns > 0 else { return "" }
        if !summary.isEmpty, body.count + summary.count + 1 <= columns { return body }
        let room = max(0, columns - status.count)
        // The status is worth more than the tail of a long command line: it is the thing the user
        // scrolled back to find out.
        guard body.count > room else { return body + status }
        guard room > 1 else { return String(status.suffix(columns)) }
        return String(body.prefix(room - 1)) + "\u{2026}" + status
    }

    /// Whitespace runs collapsed to one space, and the ends trimmed.
    static func collapsed(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(character)
        }
        return out
    }
}

public extension StickyPromptLabel {
    /// What VoiceOver hears: `exit 1 · 8.8s: swift build …. Scroll to its prompt.`
    ///
    /// "Running command: …" was said of commands that had finished, which is a label describing the
    /// wrong half of the state it was built from (a11y 7.1). What happened comes first, because it
    /// is the answer to the question that made someone press this; the command line is the middle;
    /// and the last sentence is the only place the band says what pressing it does, since it has no
    /// bezel and no title.
    ///
    /// `text` is `text(command:exitStatus:columns:summary:)`'s answer -- the collapsed, cut command
    /// line the band draws -- so the spoken sentence and the drawn one are one string, cut once,
    /// and the status is in exactly one of them. Concatenating the two blindly is what said
    /// "exit 1 middle-dot exit 1".
    static func accessibilityLabel(text: String, summary: String) -> String {
        // A header with nothing to say -- a quick success, a shell that reported no status -- still
        // gets a sentence that names what this thing is.
        guard !summary.isEmpty else { return "Pinned command: \(text). Scroll to its prompt." }
        return "\(summary): \(text). Scroll to its prompt."
    }

    /// The letter spacing the band's label needs so that its N-th glyph starts N whole cells in.
    ///
    /// `glyphAdvance` must be measured from **the same face the cell was measured from** -- the
    /// pane's own terminal font (`Pane.terminalFont`). Then this is nothing but the rounding
    /// `FontSet` does: it builds the font at `pointSize × scale` and takes `ceil` of the advance in
    /// whole device pixels, so the cell is `ceil(advance × scale) / scale` and the kern is what the
    /// `ceil` added -- at least 0 and less than one device pixel. Half a pixel per character is
    /// invisible at the first glyph and two and a half cells out by the 44th, which is a pinned
    /// command line sliding out from under the output it names: the drift `textInset` cannot fix,
    /// because it only places the start.
    ///
    /// Measured from a *different* face -- which is what `.monospacedSystemFont` against a cell
    /// built from `font-family = Menlo` was -- the number is not a rounding at all but the gap
    /// between two fonts, of either sign, and the band was drawn in SF Mono over a Menlo grid. The
    /// arithmetic here still behaves (a cell narrower than the advance kerns negative, so the
    /// letters crowd but stay on their columns); it is the caller that must not do it.
    ///
    /// Zero for an unmeasured pane rather than a nonsense number: a band laid out before its font
    /// or its grid has been measured is one frame from being laid out again.
    static func kern(cellWidth: Double, glyphAdvance: Double) -> Double {
        guard cellWidth > 0, glyphAdvance > 0 else { return 0 }
        return cellWidth - glyphAdvance
    }

    /// Where the band's command line begins, in points from the band's own leading edge: the first
    /// column boundary at or past `minimum` (the leading arrow and the gap after it).
    ///
    /// The band starts at the gutter's edge -- `max(padding, PromptGutter.hitWidth)` -- which is not
    /// a column boundary at the shipping `padding = 8`. Text laid out from there is a fraction of a
    /// cell out of step with the output rows above and below it, and monospaced text half a cell out
    /// of step reads as a smeared duplicate of itself rather than as a different surface.
    ///
    /// Points, not columns, because the caller has a constraint to set rather than a cell to fill;
    /// `Double` because `NyxCore` hands out no CoreGraphics type (plan 1a's constraints).
    static func textInset(bandLeft: Double, padding: Double, cellWidth: Double,
                          minimum: Double) -> Double {
        guard cellWidth > 0 else { return minimum }
        let need = bandLeft + minimum
        let column = max(0, ((need - padding) / cellWidth).rounded(.up))
        return max(minimum, padding + column * cellWidth - bandLeft)
    }
}
