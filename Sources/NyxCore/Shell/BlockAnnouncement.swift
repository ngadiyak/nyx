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

    /// The finish one check found, and whether it is worth saying anything about.
    public struct Finish: Equatable {
        /// The command that ended. Its id is recorded by the caller **whatever happens next** --
        /// on both signals, and whether or not the pane is focused -- so that one command is
        /// spoken once and a finish nobody was there to hear is not spoken later.
        public let region: CommandRegion
        /// Whether this finish happened while the pane was looking. False for the history a pane
        /// starts life with, which is recorded and not spoken.
        public let isNews: Bool

        public init(region: CommandRegion, isNews: Bool) {
            self.region = region
            self.isNews = isNews
        }
    }

    /// Which finished command a coalesced check is looking at, from the two signals it has.
    ///
    /// `observed` is `CommandWatcher.observe`'s answer, resolved to its region: a command this pane
    /// **saw running**. `predecessor` is the region above the bottom-most one -- the command whose
    /// prompt the shell has just replaced -- which is the only signal an *instant* command leaves.
    /// The watcher cannot report one: the check is coalesced half a second after output arrives, so
    /// `false` at the prompt started and ended between two looks, and "a failure is announced
    /// however short" was a rule with no path to it (Task 6's §7, review Important).
    ///
    /// `lastHandled` is the last finish this pane dealt with -- announced, or deliberately not.
    /// Both signals name the same command whenever both fire, so one id recorded on both paths is
    /// what keeps a three-second build from being spoken twice.
    ///
    /// **With several prompts between two checks only the newest predecessor is announced.** A
    /// check has exactly one predecessor to look at; the finishes before it are history by the time
    /// anyone could be told about them, and three sentences spoken over each other is worse than
    /// one. That is a decision, not an omission.
    ///
    /// `isFirstLook` is the caller's **first check on this pane**, and a first look is never news:
    /// the command above the prompt then is a restored session's last build or a snapshot fed in
    /// before the shell started -- `Transcript.forRestoring` puts the `133;D;<status>` marks back,
    /// so those regions carry real exit statuses -- and announcing one is a terminal telling you
    /// about yesterday. It is recorded, and the check after it has a baseline.
    ///
    /// **It is a flag and not `lastHandled == nil` on purpose.** "Has not looked yet" and "has
    /// recorded nothing yet" are different, and keying on the recorded id swallowed the first
    /// failure a user ever typed in a fresh pane: that pane's first look is its shell's first
    /// prompt, where there is no predecessor at all and nothing is recorded, so the `false` typed a
    /// moment later arrived with an empty baseline and was filed as history. Working from the
    /// second command onwards is worse than never working, because nobody would report it.
    ///
    /// A command in `observed` is news even on a first look, because the watcher only has it if it
    /// started here.
    public static func finish(observed: CommandRegion?, predecessor: CommandRegion?,
                              lastHandled: UInt32?, isFirstLook: Bool) -> Finish? {
        if let observed, ended(observed), observed.id != 0, observed.id != lastHandled {
            return Finish(region: observed, isNews: true)
        }
        guard let predecessor, ended(predecessor), predecessor.id != 0,
              predecessor.id != lastHandled else { return nil }
        return Finish(region: predecessor, isNews: !isFirstLook)
    }

    /// A command with an ending. The prompt you are typing at, and the command running at it, have
    /// neither a status nor a duration -- and "12s" is a clock, not news.
    private static func ended(_ region: CommandRegion) -> Bool {
        region.exitStatus != nil || region.duration != nil
    }

    /// The sentence is `<command line> — <summary>`, and the subject is not decoration.
    /// `exit 1 · 815ms` on its own names nothing: a VoiceOver user with a build in one pane, a
    /// test run in another and a `curl` in a third is told that something failed and left to find
    /// out what (PM P1). The command line is `Terminal.commandLine(of:)` -- the shell's own prompt
    /// sliced off at the `B` mark, so the announcement says `swift build` and not
    /// `nik@nik-newmac ~ % swift build` -- collapsed and cut to 60 characters by the same
    /// `CommandNotification.summarise` the notification uses, because a spoken sentence is a glance
    /// and a wrapped three-line `curl` is not.
    ///
    /// **A shell that emits `A`/`C`/`D` but no `B`** gets the wider answer, not an empty one:
    /// `commandLine` falls back to `commandText`, which keeps the prompt, so the subject there is
    /// `nik@nik-newmac ~ % swift build` cut to 60 characters. Deliberately not stripped -- `B` is
    /// the shell telling us where its prompt ends, and guessing at a `PS1` would cut real commands
    /// in half -- and the command is still in the sentence, which is the point. Sixty characters of
    /// prompt and no command is the bad case; a shell with no `B` also has no `inputStartColumn`
    /// anywhere, so it is a whole-integration problem rather than this rule's.
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
        guard ended(region) else { return nil }
        guard region.failed || (region.duration ?? 0) >= minimumDuration else { return nil }
        let words = summary()
        guard !words.isEmpty else { return nil }
        // A block whose command row has been trimmed out of the scrollback has a status and no
        // text at all. The summary is still the news; a bare "— exit 2" is not.
        let subject = CommandNotification.summarise(command())
        guard !subject.isEmpty else { return words }
        return "\(subject) \u{2014} \(words)"
    }
}
