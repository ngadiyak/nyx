import Foundation

/// What an attached remote tab shows: the strip above the grid, the tab's own title, and whether
/// local keystrokes are allowed to reach the host at all. Kept apart from the tab's chrome so a
/// role change (an observer taking control) or a dropped connection is one value change a view
/// redraws from, not a scatter of `if`s across the tab bar and the pane.
public struct AttachState: Equatable {
    public enum Phase: Equatable {
        case attaching
        case snapshot
        case live
        case reconnecting
        /// The associated string is the host's name, not this state's own `hostName` -- the event
        /// that ends a session names the host that ended it, and while the two are normally the
        /// same value, the strip should say what the message said, not what was cached at attach.
        case ended(String)
    }

    public enum Role: Equatable { case writer, observer }

    public var phase: Phase
    public var role: Role
    public var hostName: String
    public var title: String

    public init(hostName: String, title: String) {
        self.phase = .attaching
        self.role = .observer
        self.hostName = hostName
        self.title = title
    }

    public var tabTitle: String { "⟵ \(hostName) · \(title)" }

    /// nil means no strip at all -- the one state (writer, live) where the tab looks exactly like a
    /// local one, because from the writer's side of a session that owns it, it is one.
    public var stripText: String? {
        switch phase {
        case .attaching, .snapshot:
            return "Attaching…"
        case .live:
            return role == .observer ? "Observing — Take control" : nil
        case .reconnecting:
            return "Reconnecting…"
        case .ended(let host):
            return "Session ended on \(host)"
        }
    }

    public var stripButton: String? {
        phase == .live && role == .observer ? "Take control" : nil
    }

    public var acceptsInput: Bool { role == .writer && phase == .live }

    public var badge: String { role == .writer ? "writer" : "observer" }
}
