import Foundation

/// Whether a finished command is worth saying out loud, and in what words.
///
/// Nothing in Nyx ever posted an accessibility notification: a command finishing was silent, which
/// for a VoiceOver user is a terminal that never tells them anything happened (a11y 0.2).
/// Announcing *every* command is the opposite mistake -- it talks over the person typing the next
/// one -- so the rule is the commands you waited for and the ones that went wrong.
///
/// The words are the command and then `BlockHeader.summary`: what the strip shows, what the pinned
/// line shows, and now what is spoken, so the three cannot describe one command three ways.
public enum BlockAnnouncement {
    /// Below this a command finished while you were still reading the line you typed.
    public static let minimumDuration: Double = 2

    /// The sentence is `<command line> — <summary>`, and the subject is not decoration.
    /// `exit 1 · 815ms` on its own names nothing: a VoiceOver user with a build in one pane, a
    /// test run in another and a `curl` in a third is told that something failed and left to find
    /// out what (PM P1). The command line is `Terminal.commandLine(of:)` -- the shell's own prompt
    /// sliced off at the `B` mark, so the announcement says `swift build` and not
    /// `nik@nik-newmac ~ % swift build` -- collapsed and cut to 60 characters by the same
    /// `CommandNotification.summarise` the notification uses, because a spoken sentence is a glance
    /// and a wrapped three-line `curl` is not.
    ///
    /// `command` and `summary` are autoclosures because both are work the caller does off the
    /// frame -- a backwards walk for the prompt row, a string built out of the grid, a parse of the
    /// block's request -- and this is asked on the coalesced check after *every* command, most of
    /// which are a quick success with nothing to say. The cheap facts are tested first and the
    /// words are fetched only once the rule has already said yes.
    public static func text(for region: CommandRegion, command: @autoclosure () -> String,
                            summary: @autoclosure () -> String,
                            paneIsFocused: Bool) -> String? {
        guard paneIsFocused else { return nil }
        // Still running: it has neither a status nor a duration, and "12s" is a clock, not news.
        guard region.exitStatus != nil || region.duration != nil else { return nil }
        guard region.failed || (region.duration ?? 0) >= minimumDuration else { return nil }
        let words = summary()
        guard !words.isEmpty else { return nil }
        // A shell that emits no `B`, or a block whose command row has been trimmed away, has a
        // status and no command line. The summary is still the news; a bare "— exit 2" is not.
        let subject = CommandNotification.summarise(command())
        guard !subject.isEmpty else { return words }
        return "\(subject) \u{2014} \(words)"
    }
}
