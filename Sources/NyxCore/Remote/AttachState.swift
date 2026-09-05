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
        /// The host's own socket to the relay went (a closed lid, a dropped network), so the relay
        /// dropped the attachment and told this side `session_suspended`. The associated string is
        /// the host's name.
        ///
        /// Not `ended` and not `failed`: nothing is over. The session is still running on the host,
        /// this tab keeps its transcript, and the client re-attaches by itself the moment that
        /// host's catalogue lists the session again. Saying "Session ended" here -- which is what
        /// this build did before the relay could tell the two apart -- was a sentence the user
        /// could check and find false, on the one screen they had no other way to check.
        case suspended(String)
        /// The associated string is the host's name, not this state's own `hostName` -- the event
        /// that ends a session names the host that ended it, and while the two are normally the
        /// same value, the strip should say what the message said, not what was cached at attach.
        case ended(String)
        /// The attach never happened, and the associated string says why in the words a person can
        /// act on ("Host is offline", not `host_offline`).
        ///
        /// Distinct from `ended` because the two are different sentences to read: `ended` is a
        /// session that was there and stopped, `failed` is one that was never reached. They behave
        /// identically otherwise: no input, a Close button, and a transcript that stays until the
        /// user closes the tab.
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
        /// Nothing is arriving and nothing the user does here will change that on its own: the
        /// session ended on the host, the attach never happened, or the host has dropped off the
        /// relay. Drawn in the theme's failure colour, the way a failed exit status is.
        case warning
    }

    public var phase: Phase
    public var role: Role
    public var hostName: String
    public var title: String
    /// "Host's screen is 160×74 — showing 96×30", or nil when the host's grid fits.
    ///
    /// Set by the pane, not by the client: it is the one thing on the strip that depends on how big
    /// *this* window is, which nothing in `NyxRemote` knows or should. `AttachState.geometryNote`
    /// computes it; this carries it, so the strip stays one value to draw from.
    public var geometryNote: String?

    public init(hostName: String, title: String) {
        self.phase = .attaching
        self.role = .observer
        self.hostName = hostName
        self.title = title
    }

    /// The words on a strip that has a Close button, for the three states that keep their tab.
    ///
    /// The tab used to close itself on the next keystroke, which threw away the transcript of a
    /// session that had just ended -- exactly when somebody wants to scroll back through it. It
    /// stays now, so the strip has to say how to get rid of it.
    static let closeHint = " \u{2014} \u{2318}W to close"

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
        joined(phaseText)
    }

    /// The sentence the phase alone produces, before the pane's geometry note is added to it.
    private var phaseText: String? {
        switch phase {
        case .attaching, .snapshot:
            return "Attaching…"
        case .live:
            return role == .observer ? "Observing — Take control" : nil
        case .reconnecting:
            return "Reconnecting…"
        case .suspended(let host):
            return "\(host) is offline — will reattach" + Self.closeHint
        case .ended(let host):
            return "Session ended on \(host)" + Self.closeHint
        case .failed(let reason):
            return reason + Self.closeHint
        }
    }

    /// A state with nothing else to say still shows the note, which is why this is not simply an
    /// append: on a live writer the geometry note is the *only* thing the strip is there for.
    private func joined(_ base: String?) -> String? {
        switch (base, geometryNote) {
        case (nil, nil): return nil
        case (let base?, nil): return base
        case (nil, let note?): return note
        case (let base?, let note?): return "\(base) · \(note)"
        }
    }

    /// What the strip's one button does, if it has one. The *title* is `stripButton`; this is what
    /// pressing it means, so the view dispatches on a case rather than on the words it drew.
    public enum StripAction: Equatable {
        case takeControl
        /// Closes the tab, exactly as ⌘W does. On the three states that keep a tab nothing will
        /// ever arrive in again: the transcript stays until somebody says otherwise, so there has
        /// to be a way to say it that does not require knowing a shortcut.
        case close
    }

    public var stripAction: StripAction? {
        switch phase {
        case .live: return role == .observer ? .takeControl : nil
        case .suspended, .ended, .failed: return .close
        case .attaching, .snapshot, .reconnecting: return nil
        }
    }

    public var stripButton: String? {
        switch stripAction {
        case .takeControl: return "Take control"
        case .close: return "Close"
        case nil: return nil
        }
    }

    /// What the strip's *label* reads when the button is drawn beside it.
    ///
    /// `stripText` is the whole sentence, for anything with only words to work with -- a screen
    /// reader, a log line, a smoke hook. On screen the offer is a button, and a label repeating it
    /// would put "Take control" twice on one row. Every other state's label is the sentence itself,
    /// because every other state has no button.
    public var stripLabel: String? {
        switch phase {
        case .live: return role == .observer ? joined("Observing") : joined(nil)
        // The Close button says "Close" and the sentence says "⌘W to close": not the same words,
        // and the shortcut is the half a button cannot teach.
        case .attaching, .snapshot, .reconnecting, .suspended, .ended, .failed: return stripText
        }
    }

    public var acceptsInput: Bool { role == .writer && phase == .live }

    public var severity: Severity {
        switch phase {
        case .suspended, .ended, .failed: return .warning
        case .attaching, .snapshot, .live, .reconnecting: return .info
        }
    }

    /// What the strip says when the host's screen is bigger than the pane showing it, and nil when
    /// it is not.
    ///
    /// A remote pane takes the host's grid and does not resize it (§5.4: the person in front of the
    /// host owns that window size), so a client on a smaller screen simply loses the right-hand
    /// columns and the bottom rows -- silently, which is the part that makes a person think the
    /// host's shell is broken rather than that their own window is small. Scrolling the larger grid
    /// is still §12; saying so is not.
    public static func geometryNote(host: GridSize, pane: GridSize) -> String? {
        guard host.cols > pane.cols || host.rows > pane.rows else { return nil }
        return "Host\u{2019}s screen is \(host.cols)×\(host.rows) — showing \(pane.cols)×\(pane.rows)"
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

    /// The user switched remote sessions off while a tab was attached. The session on the host is
    /// untouched; it is this side that stopped, and the tab must say so rather than sitting on a
    /// screen that has quietly stopped moving.
    public static let remoteTurnedOff = "Remote sessions turned off"

    /// A remote setting changed under a live connection -- the relay address, the token, the name
    /// this Mac announces -- so the socket is rebuilt and every attachment on the old one is gone.
    /// Distinct from `remoteTurnedOff`, which would be a lie the user could check: the feature is
    /// still on, and the next attach will work.
    public static let remoteSettingsChanged = "Remote settings changed"

    /// The relay let go of this device for a reason reconnecting cannot fix: `bad_token`,
    /// `bad_signature`, or `replaced`. The code is carried through because it is the one word that
    /// separates "fix your token" from "two copies of Nyx are sharing an identity file", and the
    /// settings page shows the same wording.
    public static func relayRefused(_ code: String) -> String {
        "Relay refused this device (\(code))"
    }

    /// The host's `attached` claimed a screen size no terminal can have. Not a network problem and
    /// not the host's user's doing, so it says what happened rather than "The host could not be
    /// reached": the numbers came over the relay unsigned, and this Mac refused them.
    public static let badGeometry = "The host reported an impossible screen size"

    /// The user removed this host from their paired devices while a tab on it was open. Ending it
    /// is the other half of what Remove means: the host stops serving this Mac, and this Mac stops
    /// showing the host's screen. Nothing on the host ended, so it says what this side did.
    public static let unpaired = "This device was removed from your paired devices"

    /// An attach the relay never answered at all -- neither `attached` nor `error`. Distinct from
    /// every code above because nothing on the far end has admitted to anything: the message may
    /// have been dropped, or the host may have gone between the presence update and the attach.
    public static let noAnswer = "No answer from the host"
}
