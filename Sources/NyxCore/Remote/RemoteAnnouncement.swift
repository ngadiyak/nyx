import Foundation

/// When a remote tab's state is worth saying out loud, and in what words (§8.1).
///
/// The strip is the only notice a person gets that a tab has stopped taking their keystrokes, and
/// the notice is a colour and a sentence in a row they are not looking at. Nothing else in the
/// window moves: a demoted writer's next twenty keystrokes simply go nowhere.
///
/// Only a phase or a role change, so a window being dragged narrower -- which rewrites the label
/// several times a second -- says nothing, and the words are `stripText`, so the announcement and
/// the strip cannot describe one tab two ways.
public enum RemoteAnnouncement {
    /// What a live writer's tab says when it has just become one. `stripText` is nil there, by
    /// design (a tab that owns its session looks like an ordinary terminal), and the transition
    /// into it is the strip *vanishing* -- which is silence about the one change a person can act on.
    public static let canType = "You can type in this session"

    public static func text(from previous: AttachState?, to current: AttachState) -> String? {
        guard let previous else { return nil }
        guard previous.phase != current.phase || previous.role != current.role else { return nil }
        return current.stripText ?? RemoteAnnouncement.canType
    }
}
