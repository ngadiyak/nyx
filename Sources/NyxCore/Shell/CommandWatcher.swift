import Foundation

/// A command that has just ended, and how long it ran.
public struct FinishedCommand: Equatable {
    /// The absolute row of the prompt it started at, so the caller can look up its status and text.
    public let promptRow: Int
    public let duration: Double

    public init(promptRow: Int, duration: Double) {
        self.promptRow = promptRow
        self.duration = duration
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
        defer { wasRunning = outputStarted }

        if outputStarted {
            if !wasRunning { startedAt = now }
            trackedPrompt = bottomPromptRow      // kept current as rows shift underneath
            return nil
        }

        guard wasRunning, let started = startedAt else { return nil }
        let ran = now - started
        let row = trackedPrompt
        startedAt = nil
        trackedPrompt = nil
        guard ran >= minimumDuration, let row else { return nil }
        return FinishedCommand(promptRow: row, duration: ran)
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
}
