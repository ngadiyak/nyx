import Foundation

/// A command that has just ended, and how long it ran.
public struct FinishedCommand: Equatable {
    /// The absolute row of the prompt it started at, so the caller can look up its status and text.
    public let promptRow: Int
    public let duration: Double
    /// The id of the command that ran, from `Terminal.runningCommand?.id` -- 0 when none was tracked.
    /// Lets `CommandNotificationRule` recognise a command the user armed by hand.
    public let id: UInt32

    public init(promptRow: Int, duration: Double, id: UInt32 = 0) {
        self.promptRow = promptRow
        self.duration = duration
        self.id = id
    }
}

/// Noticing that a command finished, from nothing but the marks the shell emits.
///
/// There is no event for "a command ended": what actually happens is that a new prompt appears
/// below the old one. So this watches the bottom-most prompt, times the command from the moment its
/// output begins, and reports the previous one when a new prompt takes its place.
///
/// The duration is the whole point. A notification per `ls` is noise that gets the feature turned
/// off within a day, so only commands that ran long enough for the user to have looked away are
/// worth interrupting them about.
public struct CommandWatcher: Equatable {
    /// Commands shorter than this are never reported.
    public var minimumDuration: Double

    private var trackedPrompt: Int?
    private var startedAt: Double?
    private var wasRunning = false
    private var trackedID: UInt32 = 0

    public init(minimumDuration: Double = 10) {
        self.minimumDuration = minimumDuration
    }

    /// Feed the state of the bottom-most prompt on every update. Returns the command that just
    /// ended, when one did and it ran long enough to be worth mentioning.
    ///
    /// `outputStarted` is the shell's `C` mark: the command is running, as opposed to a prompt the
    /// user is still typing at. Timing from there rather than from the prompt appearing is what
    /// stops a terminal left open overnight reporting the first command of the morning as a
    /// nine-hour job.
    /// The prompt's row is deliberately NOT used as identity. Absolute rows shift whenever the
    /// scrollback trims, which happens on every new line once the buffer is full -- so a long build
    /// looked like a new command on every tick, the clock restarted each time, and the notification
    /// never fired. Precisely the case the feature exists for. What is stable is the transition:
    /// a command is running, and then it is not.
    public mutating func observe(bottomPromptRow: Int?, outputStarted: Bool,
                                 now: Double) -> FinishedCommand? {
        let finished = observe(bottomPromptRow: bottomPromptRow, outputStarted: outputStarted,
                               runningID: 0, now: now)
        guard let finished, finished.duration >= minimumDuration else { return nil }
        return finished
    }

    /// As `observe(bottomPromptRow:outputStarted:now:)`, but reports *every* finished command with
    /// its id, leaving "is it worth a notification" to `CommandNotificationRule` -- which can then
    /// say yes to a two-second command the user armed by hand.
    public mutating func observe(bottomPromptRow: Int?, outputStarted: Bool, runningID: UInt32,
                                 now: Double) -> FinishedCommand? {
        defer { wasRunning = outputStarted }
        if outputStarted {
            if !wasRunning { startedAt = now }
            trackedPrompt = bottomPromptRow
            if runningID != 0 { trackedID = runningID }
            return nil
        }
        guard wasRunning, let started = startedAt, let row = trackedPrompt else {
            startedAt = nil; trackedPrompt = nil; trackedID = 0
            return nil
        }
        let finished = FinishedCommand(promptRow: row, duration: now - started, id: trackedID)
        startedAt = nil; trackedPrompt = nil; trackedID = 0
        return finished
    }
}

/// Whether a finished command is worth interrupting the user about.
public enum CommandNotificationRule {
    /// Armed by hand wins over everything: the user asked. Otherwise the old rule -- long enough
    /// to have looked away from, and the window not in front.
    public static func shouldNotify(_ finished: FinishedCommand, armed: Set<UInt32>,
                                    windowFocused: Bool, minimumDuration: Double) -> Bool {
        if finished.id != 0 && armed.contains(finished.id) { return true }
        return !windowFocused && finished.duration >= minimumDuration
    }
}

/// What the notification for a finished command says.
public enum CommandNotification {
    /// Long command lines are truncated: a notification is a glance, and the shell's own scrollback
    /// is where the whole thing lives.
    public static let commandLimit = 60

    public static func title(failed: Bool) -> String {
        failed ? "Command failed" : "Command finished"
    }

    /// The command line, tidied: collapsed whitespace, truncated, and the exit status when it
    /// failed -- which is the one number a user actually wants from a failure they missed.
    public static func body(command: String, exitStatus: Int32?) -> String {
        let text = summarise(command)
        guard let exitStatus, exitStatus != 0 else { return text }
        return text.isEmpty ? "exited \(exitStatus)" : "\(text) — exited \(exitStatus)"
    }

    static func summarise(_ command: String) -> String {
        let collapsed = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > commandLimit else { return collapsed }
        return String(collapsed.prefix(commandLimit - 1)) + "…"
    }
}

public extension Terminal {
    /// What the user typed at a command's prompt, as best the marks allow.
    ///
    /// The rows from the prompt to just before its output, which for every shell integration in
    /// practice is the prompt string followed by the command line. The prompt itself is left in:
    /// stripping it would need to know what the user's prompt looks like, and the extra context --
    /// which directory, which host -- is worth more in a notification than tidiness.
    func commandText(of region: CommandRegion) -> String {
        let last = (region.outputStart.map { $0 - 1 } ?? region.promptRow)
        guard last >= region.promptRow else { return "" }
        let text = (region.promptRow...min(last, totalRows - 1))
            .map { rowText(absoluteRow: $0).text }
            .joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Just what the user typed, with the shell's own prompt sliced off at the `B` mark.
    ///
    /// `commandText` above keeps the prompt on purpose, which is right for a notification and wrong
    /// for everything that treats the result as a command: "Copy Command", "Copy as Markdown",
    /// "Run This Command Again" and "Edit and Run" all produced
    /// `nik@nik-newmac ~ % printf ...` on a real `PS1`, and Run Again sent that whole string to the
    /// shell. `Row.inputStartColumn` is the shell telling us exactly where its prompt ends, so
    /// there is nothing to guess.
    ///
    /// Rows between the prompt and the output belong to the command line too. A row that soft-wrapped
    /// is joined to the next with nothing between them -- it is one line, and a space inserted at the
    /// wrap point would corrupt the command being re-run -- while a genuinely new row (a multi-line
    /// command) is joined with a space, as `commandText` does.
    ///
    /// Falls back to `commandText` when the shell emitted no `B`: without it there is no way to say
    /// where the prompt ends, and the wider answer beats an empty one.
    func commandLine(of region: CommandRegion) -> String {
        let last = min(region.outputStart.map { $0 - 1 } ?? region.promptRow, totalRows - 1)
        guard last >= region.promptRow else { return "" }
        // The `B` is not always on the prompt row. A prompt long enough to wrap -- a narrow split,
        // or the two-line prompts starship and powerlevel10k draw -- puts it on a continuation row,
        // and looking only at the first row found nothing and handed back the whole prompt as the
        // command. Searched forwards, so the first `B` in the command wins.
        var inputStart: Int?
        var start = region.promptRow
        for row in region.promptRow...last {
            if let column = absoluteRow(row)?.inputStartColumn {
                inputStart = column
                start = row
                break
            }
        }
        guard let inputStart else { return commandText(of: region) }

        var text = ""
        for row in start...last {
            let line = rowText(absoluteRow: row)
            let characters = Array(line.text)
            // The `B` column is a terminal column; `columnOf` maps it to a character index, which is
            // not the same number once a wide glyph sits in the prompt.
            let from = row == start
                ? (line.columnOf.firstIndex { $0 >= inputStart } ?? characters.count)
                : 0
            guard from < characters.count else { continue }
            // `rowText` pads every empty cell with a space so a column stays a column; a command
            // line has no columns to preserve, and the padding would otherwise land in the middle
            // of a multi-row command.
            var piece = String(characters[from...])
            while piece.hasSuffix(" ") { piece.removeLast() }
            guard !piece.isEmpty else { continue }
            if !text.isEmpty { text += (absoluteRow(row - 1)?.wrapped ?? false) ? "" : " " }
            text += piece
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
