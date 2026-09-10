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
    /// A failed command carries its status in the text as well as in the colour: colour alone says
    /// "something is wrong here" to a reader who can see it and nothing at all to one who cannot.
    public static func text(command: String, exitStatus: Int32?, columns: Int) -> String {
        let status = (exitStatus ?? 0) != 0 ? "  exit \(exitStatus!)" : ""
        let body = collapsed(command)
        guard columns > 0 else { return "" }
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
    /// What VoiceOver hears: `Pinned command: swift build … · exit 1 · 8.8s. Scrolls back to it.`
    ///
    /// "Running command: …" was said of commands that had finished, which is a label describing the
    /// wrong half of the state it was built from (a11y 7.1). `text` is
    /// `text(command:exitStatus:columns:)`'s answer -- the collapsed, cut command line the band
    /// draws -- so the spoken sentence and the drawn one are one string, cut once, and the second
    /// sentence is the only place the band says what pressing it does: it has no bezel and no title.
    static func accessibilityLabel(text: String, summary: String) -> String {
        let sentence = summary.isEmpty ? text : "\(text) \u{b7} \(summary)"
        return "Pinned command: \(sentence). Scrolls back to it."
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
