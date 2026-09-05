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
        /// The attach never happened, and the associated string says why in the words a person can
        /// act on ("Host is offline", not `host_offline`).
        ///
        /// Distinct from `ended` because the two are different sentences to read: `ended` is a
        /// session that was there and stopped, `failed` is one that was never reached. They behave
        /// identically otherwise -- no input, no button, and the tab closes on the next key --
        /// which is why `closesOnNextKey` exists rather than each caller matching both cases.
        case failed(String)
    }

    public enum Role: Equatable { case writer, observer }

    /// How the strip is coloured. Not a second copy of the phase: it is the one thing the *band*
    /// carries, and a view that switched on the phase itself would be the scatter of `if`s this
    /// type exists to prevent.
    ///
    /// `reconnecting` is deliberately `info`. It is a state that fixes itself, and colouring it
    /// like a failure would teach people to ignore the colour on the two states that do not.
    public enum Severity: Equatable {
        case info
        /// Something is over and will not come back: the session ended on the host, or the attach
        /// never happened. Drawn in the theme's failure colour, the way a failed exit status is.
        case warning
    }

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

    public var tabTitle: String { tabTitle(currentTitle: "") }

    /// The tab's title. `currentTitle` is whatever the host's own shell has set with OSC 0/2 since
    /// the attach -- those bytes arrive in the stream like every other -- and empty means it never
    /// has, in which case the title the palette row carried is the best name there is.
    ///
    /// The arrow and the machine name stay in front of it either way: the one thing this tab must
    /// never look like is a tab on this Mac.
    public func tabTitle(currentTitle: String) -> String {
        "⟵ \(hostName) · \(currentTitle.isEmpty ? title : currentTitle)"
    }

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
        case .failed(let reason):
            return reason
        }
    }

    public var stripButton: String? {
        phase == .live && role == .observer ? "Take control" : nil
    }

    /// What the strip's *label* reads when the button is drawn beside it.
    ///
    /// `stripText` is the whole sentence, for anything with only words to work with -- a screen
    /// reader, a log line, a smoke hook. On screen the offer is a button, and a label repeating it
    /// would put "Take control" twice on one row. Every other state's label is the sentence itself,
    /// because every other state has no button.
    public var stripLabel: String? {
        switch phase {
        case .live: return role == .observer ? "Observing" : nil
        case .attaching, .snapshot, .reconnecting, .ended, .failed: return stripText
        }
    }

    public var acceptsInput: Bool { role == .writer && phase == .live }

    /// Whether the next keystroke should close this tab instead of being sent anywhere.
    ///
    /// A tab in either of these two phases will never show another byte, so leaving it on screen
    /// waiting to be closed by hand is a dead window the user has to tidy up; closing it on the
    /// first key is what every "press any key to continue" has always meant. The keystroke is
    /// deliberately swallowed rather than delivered to whatever tab comes next.
    public var closesOnNextKey: Bool {
        switch phase {
        case .ended, .failed: return true
        case .attaching, .snapshot, .live, .reconnecting: return false
        }
    }

    public var severity: Severity {
        switch phase {
        case .ended, .failed: return .warning
        case .attaching, .snapshot, .live, .reconnecting: return .info
        }
    }

    public var badge: String { role == .writer ? "writer" : "observer" }
}

/// Why an attach did not happen, in the words the strip shows.
///
/// The relay's `error.code` is a wire identifier -- `host_offline`, `not_paired` -- and a tab that
/// printed one would be telling the user to go and read a protocol document. The mapping lives here
/// rather than in `NyxRemote` because it is a decision about what a person is told, and because the
/// list of codes is the spec's (§6.4), not the socket's.
public enum AttachFailure {
    public static func text(code: String) -> String {
        switch code {
        case "host_offline": return "Host is offline"
        case "not_paired": return "Not paired with this device"
        case "no_such_session": return "That session no longer exists"
        case "too_many": return "The host has too many viewers"
        // Deliberately not the code itself: a relay newer than this build can invent codes, and
        // "The host could not be reached" is true of every one of them.
        default: return "The host could not be reached"
        }
    }

    /// The user switched remote sessions off, or changed the relay this Mac talks to, while a tab
    /// was attached. The session on the host is untouched; it is this side that stopped, and the
    /// tab must say so rather than sitting on a screen that has quietly stopped moving.
    public static let remoteTurnedOff = "Remote sessions turned off"

    /// An attach the relay never answered at all -- neither `attached` nor `error`. Distinct from
    /// every code above because nothing on the far end has admitted to anything: the message may
    /// have been dropped, or the host may have gone between the presence update and the attach.
    public static let noAnswer = "No answer from the host"
}
