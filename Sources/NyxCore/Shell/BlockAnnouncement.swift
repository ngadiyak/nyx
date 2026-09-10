import Foundation

/// Whether a finished command is worth saying out loud, and in what words.
///
/// Nothing in Nyx ever posted an accessibility notification: a command finishing was silent, which
/// for a VoiceOver user is a terminal that never tells them anything happened (a11y 0.2).
/// Announcing *every* command is the opposite mistake -- it talks over the person typing the next
/// one -- so the rule is the commands you waited for and the ones that went wrong.
///
/// The words are `BlockHeader.summary`: what the strip shows, what the pinned line shows, and now
/// what is spoken, so the three cannot describe one command three ways.
public enum BlockAnnouncement {
    /// Below this a command finished while you were still reading the line you typed.
    public static let minimumDuration: Double = 2

    /// `summary` is an autoclosure because the caller's is a `BlockHeader` built off the frame --
    /// a backwards walk for the prompt row and a parse of the block's request -- and this is asked
    /// on the coalesced check after *every* command, most of which are a quick success with
    /// nothing to say. The words are only needed once the rule has already said yes, so the
    /// cheap facts are tested first and the sentence is fetched last.
    public static func text(for region: CommandRegion, summary: @autoclosure () -> String,
                            paneIsFocused: Bool) -> String? {
        guard paneIsFocused else { return nil }
        // Still running: it has neither a status nor a duration, and "12s" is a clock, not news.
        guard region.exitStatus != nil || region.duration != nil else { return nil }
        guard region.failed || (region.duration ?? 0) >= minimumDuration else { return nil }
        let words = summary()
        guard !words.isEmpty else { return nil }
        return words
    }
}
