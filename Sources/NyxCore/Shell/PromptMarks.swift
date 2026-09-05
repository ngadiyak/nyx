import Foundation

/// What a shell told us with `OSC 133`, as flags -- a row routinely carries more than one.
///
/// A shell emits `A` and `B` on the same prompt line, and emits `D` for the command that just
/// finished on the very line the next prompt is about to occupy. Anything that stores one mark per
/// row loses whichever arrived first, so these accumulate.
///
/// A shell that emits these is telling the terminal where its prompt ends and a command's output
/// begins -- the difference between a terminal that can only scroll and one that can jump between
/// commands, copy the output of one, and say whether it failed.
public struct PromptMarks: OptionSet, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `A` -- the prompt starts here.
    public static let promptStart = PromptMarks(rawValue: 1)
    /// `B` -- the user's typing starts here.
    public static let commandStart = PromptMarks(rawValue: 2)
    /// `C` -- the command's output starts here.
    public static let outputStart = PromptMarks(rawValue: 4)
    /// `D` -- a command finished on this row; it may also carry the exit status.
    public static let commandDone = PromptMarks(rawValue: 8)
}

/// One command as the shell described it, in absolute (scrollback-relative) rows.
///
/// Absolute, not viewport-relative, for the same reason `Selection` is: the buffer scrolls under
/// the user while they are reading, and a region that meant row 3 of the screen a moment ago has to
/// keep meaning the same line.
public struct CommandRegion: Equatable {
    /// The row carrying the `A` mark: where the prompt begins.
    public let promptRow: Int
    /// Where the command's output begins, if the shell marked it.
    public let outputStart: Int?
    /// The last row belonging to this command -- the row before the next prompt, or the end of the
    /// buffer for the command still running.
    public let endRow: Int
    /// nil when the command is still running, or the shell reported no status.
    public let exitStatus: Int32?
    /// How long it ran, in seconds. nil while it is still running, or without shell integration.
    public let duration: Double?
    /// The prompt row's `Row.commandID`. 0 for a region built before ids existed, so an old call
    /// site that does not pass one still compiles.
    public let id: UInt32

    public init(promptRow: Int, outputStart: Int?, endRow: Int, exitStatus: Int32?,
                duration: Double? = nil, id: UInt32 = 0) {
        self.promptRow = promptRow
        self.outputStart = outputStart
        self.endRow = endRow
        self.exitStatus = exitStatus
        self.duration = duration
        self.id = id
    }

    /// The rows holding just the output, empty when the command produced none.
    public var outputRows: Range<Int> {
        guard let outputStart, outputStart <= endRow else { return 0..<0 }
        return outputStart..<(endRow + 1)
    }

    /// A command the shell reported a non-zero status for. `nil` status is not failure -- it is a
    /// command still running, or a shell that reports `D` without one.
    public var failed: Bool { (exitStatus ?? 0) != 0 }
}

/// How a duration is written where a person will read it.
///
/// Kept out of the views because every place that shows one -- the gutter, the sticky strip, a fold
/// placeholder, a block header -- has to write it the same way, and because "0.0s" and "2m 3s" are
/// decisions worth a test rather than a guess in three files.
public enum DurationText {
    /// Short enough to sit in a gutter tooltip or a one-row strip.
    ///
    /// Sub-second times are given in milliseconds: the difference between 4 ms and 400 ms is the
    /// whole point of showing it, and "0.0s" versus "0.4s" throws that away.
    public static func short(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        if minutes < 60 { return "\(minutes)m \(rest)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Whether a command took long enough to be worth mentioning at all. Writing `3ms` beside every
    /// `cd` is noise that makes the number people do care about harder to see.
    public static func isWorthShowing(_ seconds: Double, threshold: Double = 0.5) -> Bool {
        seconds.isFinite && seconds >= threshold
    }
}

public extension Terminal {
    /// The marks on an absolute row -- empty for a row past the ends.
    func promptMarks(atAbsoluteRow row: Int) -> PromptMarks {
        guard let r = absoluteRow(row) else { return [] }
        return PromptMarks(rawValue: r.promptMark)
    }

    func exitStatus(atAbsoluteRow row: Int) -> Int32? {
        absoluteRow(row)?.exitStatus
    }

    /// Absolute rows carrying a prompt-start mark, in order.
    ///
    /// This walks the whole buffer, so it belongs on a keystroke -- jumping, or building the
    /// gutter's model -- and not in a per-frame path. Drawing the gutter reads each visible row's
    /// own mark instead, which is O(1).
    var promptRows: [Int] {
        (0..<totalRows).filter { promptMarks(atAbsoluteRow: $0).contains(.promptStart) }
    }

    /// The nearest prompt above `row`, or nil when there is none.
    func previousPrompt(before row: Int) -> Int? {
        stride(from: min(row, totalRows) - 1, through: 0, by: -1)
            .first { promptMarks(atAbsoluteRow: $0).contains(.promptStart) }
    }

    /// The nearest prompt below `row`, or nil when there is none.
    func nextPrompt(after row: Int) -> Int? {
        guard row + 1 < totalRows else { return nil }
        return ((row + 1)..<totalRows).first { promptMarks(atAbsoluteRow: $0).contains(.promptStart) }
    }

    /// The command whose region contains `row`, or nil when `row` is above the first prompt.
    ///
    /// The region runs from its own prompt to the row before the next one, so clicking anywhere in
    /// a command's output -- or on its prompt -- identifies the same command.
    func command(containingAbsoluteRow row: Int) -> CommandRegion? {
        guard row >= 0, row < totalRows else { return nil }
        let start = promptMarks(atAbsoluteRow: row).contains(.promptStart) ? row : previousPrompt(before: row)
        guard let start else { return nil }
        let next = nextPrompt(after: start)
        let end = (next ?? totalRows) - 1

        // Searched strictly after the prompt row, for the same ownership reason as the status
        // below: a command that produced no output leaves its `C` on the row its successor's
        // prompt lands on, and counting it would give the new prompt an output region made of
        // everything below it.
        var outputStart: Int?
        if start < end {
            for r in (start + 1)...end where promptMarks(atAbsoluteRow: r).contains(.outputStart) {
                outputStart = r
                break
            }
        }

        // The `D` closing this command usually lands on the row the *next* prompt occupies, so the
        // search has to reach that row. It starts strictly *after* this prompt for the mirror
        // reason: a `D` sitting on our own prompt row closes whatever ran before us, and counting
        // it would make every command inherit its predecessor's status -- including the prompt the
        // user is still typing at, which would show as failed the moment anything before it did.
        var status: Int32?
        let statusSearchEnd = min(next ?? (totalRows - 1), totalRows - 1)
        if start < statusSearchEnd {
            for r in (start + 1)...statusSearchEnd where promptMarks(atAbsoluteRow: r).contains(.commandDone) {
                status = exitStatus(atAbsoluteRow: r)
                break
            }
        }
        return CommandRegion(promptRow: start, outputStart: outputStart, endRow: max(start, end),
                             exitStatus: status, duration: absoluteRow(start)?.commandDuration,
                             id: absoluteRow(start)?.commandID ?? 0)
    }

    /// The most recently finished command -- what "copy the last command's output" means.
    ///
    /// The command at the bottom of the buffer is usually the prompt the user is typing at, which
    /// has produced nothing yet, so this skips back to the last one that actually ended.
    var lastFinishedCommand: CommandRegion? {
        var row = totalRows - 1
        while row >= 0 {
            guard let region = command(containingAbsoluteRow: row) else { return nil }
            if region.exitStatus != nil || !region.outputRows.isEmpty { return region }
            row = region.promptRow - 1
        }
        return nil
    }

    /// The selection covering a command's output, or nil when it produced none.
    func selectionForOutput(of region: CommandRegion) -> Selection? {
        let rows = region.outputRows
        guard !rows.isEmpty else { return nil }
        return Selection(anchor: AbsolutePosition(row: rows.lowerBound, col: 0),
                         head: AbsolutePosition(row: rows.upperBound - 1, col: cols),
                         mode: .character)
    }

    /// Scrolls so that `row` sits a little below the top of the viewport, and reports whether the
    /// viewport actually moved.
    ///
    /// A little below rather than flush at the top: jumping to a prompt is a request to read what
    /// that command *did*, and a prompt pinned to the very first line puts its output entirely
    /// below the fold.
    /// Scrolls only if `row` is not already on screen, and reports whether the viewport moved.
    ///
    /// This is what stepping through search hits wants: three hits on the visible screen should
    /// highlight one after another without the text sliding under the reader each time, and a hit
    /// two screens up should bring the screen to it.
    @discardableResult
    func revealAbsoluteRow(_ row: Int, margin: Int = 1) -> Bool {
        let top = viewportTopRow
        guard row < top || row >= top + rows else { return false }
        return scrollToAbsoluteRow(row, margin: margin)
    }

    func scrollToAbsoluteRow(_ row: Int, margin: Int = 1) -> Bool {
        let target = max(0, row - margin)
        let offset = max(0, min(scrollback.count, scrollback.count - target))
        guard offset != viewportOffset else { return false }
        viewportOffset = offset
        return true
    }
}
