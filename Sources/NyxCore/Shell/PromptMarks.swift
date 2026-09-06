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
    /// The last row belonging to this command -- the row before the next prompt, or, for the last
    /// command in the buffer, the last row anything has actually been written to.
    ///
    /// The clamp matters because "the end of the buffer" for a running command is the whole unwritten
    /// screen below its cursor. `npm install` two lines in owned forty rows, so folding it reported
    /// "… 38 lines hidden" for two real lines, and every further line it printed landed inside the
    /// hidden range: the screen stopped changing.
    public let endRow: Int
    /// nil when the command is still running, or the shell reported no status.
    public let exitStatus: Int32?
    /// How long it ran, in seconds. nil while it is still running, or without shell integration.
    public let duration: Double?
    /// The prompt row's `Row.commandID`. 0 for a region built before ids existed, so an old call
    /// site that does not pass one still compiles.
    public let id: UInt32
    /// The clock reading `Terminal.runningCommand` recorded when this command started, carried
    /// over only while it is still the one running. nil once it has finished, or for a command
    /// built before `runningCommand` existed to ask.
    public let startedAt: Double?

    /// No prompt follows this command, so it is the last one in the buffer and `endRow` is a clamp
    /// rather than a boundary: everything below it is unwritten screen that belongs to nobody. A
    /// walk over the buffer's commands has to stop here rather than step past `endRow` and find
    /// this same command again.
    public let isLastInBuffer: Bool

    public init(promptRow: Int, outputStart: Int?, endRow: Int, exitStatus: Int32?,
                duration: Double? = nil, id: UInt32 = 0, startedAt: Double? = nil,
                isLastInBuffer: Bool = false) {
        self.promptRow = promptRow
        self.outputStart = outputStart
        self.endRow = endRow
        self.exitStatus = exitStatus
        self.duration = duration
        self.id = id
        self.startedAt = startedAt
        self.isLastInBuffer = isLastInBuffer
    }

    /// The rows holding just the output, empty when the command produced none.
    public var outputRows: Range<Int> {
        guard let outputStart, outputStart <= endRow else { return 0..<0 }
        return outputStart..<(endRow + 1)
    }

    /// A command the shell reported a non-zero status for. `nil` status is not failure -- it is a
    /// command still running, or a shell that reports `D` without one.
    public var failed: Bool { (exitStatus ?? 0) != 0 }

    /// The one bit every piece of a block's chrome colours itself by. Kept here so the spine, the
    /// gutter, the summary and a fold placeholder cannot each derive it a different way -- a
    /// running block's placeholder was grey while its own spine was amber.
    public var status: BlockStatus {
        if failed { return .failed }
        return (outputStart != nil && exitStatus == nil && duration == nil) ? .running : .succeeded
    }
}

/// How a command ended, or that it has not. `.succeeded` covers a command that reported nothing:
/// a shell that emits `D` without a status has not said anything went wrong.
public enum BlockStatus: Equatable {
    case running, succeeded, failed
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

/// One walk's memory of which command owns the row it last asked about.
///
/// A reference type on purpose: it is threaded through a walk that is otherwise made of
/// non-mutating functions on `Terminal`, and every step of that walk has to see what the step
/// before it learned. Make one per walk and throw it away — it caches absolute row numbers, so a
/// memo kept across anything that feeds the terminal, evicts rows or changes the prompt marks will
/// answer for rows that have moved. Nothing here holds a `Terminal`, so it cannot notice.
public final class CommandRegionMemo {
    /// How many times the walk actually had to scan the buffer. The point of the memo, and what the
    /// cost tests assert on: it is the number of blocks a walk crosses, not the number of rows.
    public internal(set) var resolutions = 0

    /// The rows `region` is the answer for. Empty until the first resolution.
    private var covered: Range<Int> = 0..<0
    private var region: CommandRegion?

    public init() {}

    /// Whether the last answer covers this row. A remembered *absence* — above the first prompt —
    /// is as worth caching as a hit, because finding it out is a scan to row zero, so this is asked
    /// separately from reading `remembered` rather than folded into a nested optional.
    func covers(_ row: Int) -> Bool { covered.contains(row) }

    /// The last answer. Meaningless unless `covers(row)` said so.
    var remembered: CommandRegion? { region }

    func remember(_ region: CommandRegion?, covering rows: Range<Int>) {
        self.region = region
        covered = rows
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

    /// `command(containingAbsoluteRow:)` with the answer to the previous row still in hand.
    ///
    /// Every row of a block resolves to the same region, and resolving it costs a scan to the
    /// prompt above and the prompt below — the length of the block. A walk that asks per row
    /// therefore costs `rows × blockLength`: one screenful stepped backwards through a
    /// five-thousand-row `cat` re-derived the same region twenty to fifty times, on the frame path,
    /// inside `session.withTerminal`, so the PTY reader waited for it too. Passing one memo through
    /// the walk turns that back into one resolution per block the walk actually crosses.
    ///
    /// nil is memoised as well: above the first prompt there is no region and finding that out is
    /// itself a scan to row zero.
    func region(containing row: Int, memo: CommandRegionMemo) -> CommandRegion? {
        guard row >= 0, row < totalRows else { return nil }
        if memo.covers(row) { return memo.remembered }
        let region = command(containingAbsoluteRow: row)
        memo.resolutions += 1
        if let region {
            // Exactly the rows this region answers for: from its prompt to the row before the next
            // prompt, and for the last command in the buffer to the end of it — `endRow` stops at
            // the last row *written*, but the unwritten screen below still resolves here.
            let upper = region.isLastInBuffer ? totalRows : region.endRow + 1
            memo.remember(region, covering: region.promptRow..<max(region.promptRow + 1, upper))
        } else {
            // No prompt at or before `row`, so no prompt at or before anything above it either.
            memo.remember(nil, covering: 0..<(row + 1))
        }
        return region
    }

    /// The command whose region contains `row`, or nil when `row` is above the first prompt.
    ///
    /// The region runs from its own prompt to the row before the next one, so clicking anywhere in
    /// a command's output -- or on its prompt -- identifies the same command.
    ///
    /// A **scan** every time. Anything that asks about more than one row in a row wants
    /// `region(containing:memo:)`; see that for what the repeated scan cost on the frame path.
    func command(containingAbsoluteRow row: Int) -> CommandRegion? {
        guard row >= 0, row < totalRows else { return nil }
        let start = promptMarks(atAbsoluteRow: row).contains(.promptStart) ? row : previousPrompt(before: row)
        guard let start else { return nil }
        let next = nextPrompt(after: start)
        // Where the marks may be looked for: the whole region as the buffer describes it. Kept
        // unclamped so that "the shell said this command started" -- `outputStart != nil`, which the
        // command watcher, the notifications and the spine all read -- means the same thing it
        // always did for a command that has begun and printed nothing yet.
        let searchEnd = (next ?? totalRows) - 1
        // Where the command *ends*, which is a different question. The last command in the buffer
        // ends at the last row anything has been written to, not at the end of the buffer: the rows
        // below its cursor are unwritten screen. Counting them made a running command's region forty
        // rows long two lines in, so folding it said "… 38 lines hidden" for two real lines and then
        // swallowed everything it printed afterwards -- the screen stopped changing.
        let end: Int
        if let next {
            end = next - 1
        } else {
            var last = min(totalRows - 1, scrollback.count + screen.cursor.y)
            // The cursor sits on the row the *next* character will go on. While that row is still
            // empty the command has not written it, and counting it would put one blank line inside
            // every fold of a command that is between lines. Exactly one step back, because a
            // command that printed blank lines really did print them.
            if last > start, absoluteRow(last)?.isBlank ?? true { last -= 1 }
            end = last
        }

        // Searched strictly after the prompt row, for the same ownership reason as the status
        // below: a command that produced no output leaves its `C` on the row its successor's
        // prompt lands on, and counting it would give the new prompt an output region made of
        // everything below it.
        var outputStart: Int?
        if start < searchEnd {
            for r in (start + 1)...searchEnd where promptMarks(atAbsoluteRow: r).contains(.outputStart) {
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
        let id = absoluteRow(start)?.commandID ?? 0
        return CommandRegion(promptRow: start, outputStart: outputStart, endRow: max(start, end),
                             exitStatus: status, duration: absoluteRow(start)?.commandDuration,
                             id: id, startedAt: runningCommand?.id == id ? runningCommand?.startedAt : nil,
                             isLastInBuffer: next == nil)
    }

    /// The command whose region ends just above `region`'s prompt, or nil for the first command.
    ///
    /// Not `lastFinishedCommand`: at the instant a new command starts running, the region *containing
    /// the bottom row* is already the one that just started -- its own output has begun -- so asking
    /// "what finished last" answers with the command that is running right now instead of the one
    /// before it. Walking to the row above the prompt is the only way to name the one that actually
    /// finished.
    func previousCommand(of region: CommandRegion) -> CommandRegion? {
        guard region.promptRow > 0 else { return nil }
        return command(containingAbsoluteRow: region.promptRow - 1)
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

    /// Which command a fold gesture acts on -- ⌘⇧↑, and "select the command's output" with it.
    ///
    /// "The command containing the top screen row" is right only when the user put that row there.
    /// At the bottom of a session it is wherever the last few commands happened to leave the
    /// scroll: after a twenty-row build and a three-row `curl`, the top row is in the middle of the
    /// build's output, so ⌘⇧↑ folded the build while the user was looking at the curl. At the
    /// bottom the answer is *this* command -- the one running, if one is, so a noisy build can be
    /// folded to a live tail while it runs, else the last one that finished. Scrolled back, the top
    /// row is a deliberate choice and still means what it says.
    func commandToFold() -> CommandRegion? {
        guard shellEmitsPromptMarks else { return nil }
        guard viewportOffset == 0 else { return command(containingAbsoluteRow: viewportTopRow) }
        if let running = runningCommand, running.id != 0,
           let region = command(containingAbsoluteRow: totalRows - 1), region.id == running.id {
            return region
        }
        return lastFinishedCommand
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
