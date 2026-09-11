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
        ///
        /// `since` is when the suspension started, so the strip can say how long this has been
        /// going on. "Will reattach" alone is the same sentence after five seconds and after five
        /// hours, and the difference between those two is the whole of what a person wants to know.
        case suspended(String, since: Date)
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
    /// Whether ⌘W on this pane closes the tab this strip is in -- true when the pane is its tab's
    /// only one, which is the ordinary case for a remote tab.
    ///
    /// Set by the pane, like `geometryNote`, and for the same reason: the number of panes in a tab
    /// is not something `NyxRemote` knows. It exists because the strip offering "⌘W to close" in a
    /// split tab was telling the user to close their *other* pane's tab as well.
    public var closesWholeTab = true
    /// The clock the strip's "offline since" is read against. Injected so a test can pin it; the
    /// pane leaves it at the system's.
    public var timeZone = TimeZone.current
    /// The start of the reader's current day, which is what turns "since 14:32" into "since
    /// yesterday 14:32".
    ///
    /// A day rather than a moment, and stored rather than read from the clock inside `stripText`,
    /// for one reason: this type is compared to decide whether anything changed, and a value that
    /// moved every frame would make every layout pass look like a state change and re-title the tab
    /// sixty times a second. The wording depends on nothing finer than the day anyway.
    public var today: Date

    public init(hostName: String, title: String) {
        self.phase = .attaching
        self.role = .observer
        self.hostName = hostName
        self.title = title
        self.today = AttachState.startOfDay(Date(), in: .current)
    }

    /// The words on a strip that has a Close button, for the three states that keep their tab.
    ///
    /// The tab used to close itself on the next keystroke, which threw away the transcript of a
    /// session that had just ended -- exactly when somebody wants to scroll back through it. It
    /// stays now, so the strip has to say how to get rid of it.
    ///
    /// Empty when this pane is not its tab's only one: there ⌘W closes the whole tab, other pane
    /// and all, which is not what the button beside these words does. The button says "Close" and
    /// that is the whole offer.
    private var closeHint: String { closesWholeTab ? " \u{00b7} \u{2318}W to close" : "" }

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
        case .suspended(let host, let since):
            return "\(host) has been offline since \(Self.offlineSince(since, today: today, in: timeZone))"
                + " — waiting for it to come back" + closeHint
        case .ended(let host):
            return "Session ended on \(host)" + closeHint
        case .failed(let reason):
            return reason + closeHint
        }
    }

    /// "14:32", in the reader's own time zone. Not a relative age ("3 minutes ago"): a strip is not
    /// redrawn on a timer, so a relative time would be wrong the moment after it was written, and a
    /// wall-clock time stays true for as long as the tab is open.
    static func clockTime(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// When the suspension started, as a person reads a clock.
    ///
    /// A bare "since 14:32" is a lie by omission on a Mac left overnight: it is the same four
    /// characters whether the host went five minutes ago or last Tuesday, and the tab is exactly
    /// the kind of thing that is still open in the morning. The day is added as soon as it is not
    /// today's, and named once it is further back than yesterday.
    public static func offlineSince(_ since: Date, today: Date, in zone: TimeZone) -> String {
        let time = clockTime(since, in: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = calendar.startOfDay(for: since)
        let start = calendar.startOfDay(for: today)
        guard let elapsed = calendar.dateComponents([.day], from: day, to: start).day, elapsed != 0
        else { return time }
        if elapsed == 1 { return "yesterday \(time)" }
        let parts = calendar.dateComponents([.day, .month], from: since)
        guard let number = parts.day, let month = parts.month, (1...12).contains(month) else {
            return time
        }
        return "\(number) \(AttachState.monthNames[month - 1]) \(time)"
    }

    /// Fixed rather than `DateFormatter`'s: every other word on this strip is English, and a month
    /// that changed language with the system locale while the sentence around it did not would read
    /// worse than one that did not change at all.
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Midnight at the start of `date` in `zone` -- what `today` wants, and the only part of "now"
    /// the "offline since" wording depends on.
    public static func startOfDay(_ date: Date, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.startOfDay(for: date)
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

    /// What the strip may draw, longest first: the view takes the first that fits its width.
    ///
    /// There is only ever one alternative, and it is the geometry note that goes. It is the least
    /// urgent clause on the strip -- a window that is too small is a thing the user can also simply
    /// see -- and truncating the sentence in front of it ("Mac mini has been offline since 14:3…")
    /// would lose the part that cannot be seen any other way.
    public var stripLabelOptions: [String] {
        guard let full = stripLabel else { return [] }
        guard geometryNote != nil else { return [full] }
        var withoutNote = self
        withoutNote.geometryNote = nil
        guard let shorter = withoutNote.stripLabel, shorter != full else { return [full] }
        return [full, shorter]
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

    /// Whether this tab still holds an attachment the client is routing to.
    ///
    /// Everything but `ended` and `failed`, including `suspended`: a suspended tab is waiting, not
    /// finished, and it is still the one tab that session belongs to. It is what stops the palette
    /// selecting the corpse of a tab whose session ended instead of opening a fresh one.
    public var isAttached: Bool {
        switch phase {
        case .ended, .failed: return false
        case .attaching, .snapshot, .live, .reconnecting, .suspended: return true
        }
    }

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
    /// Two numbers and a subtraction was a puzzle, not a sentence: "160×74 — showing 96×30" left
    /// the reader to work out that the missing columns are the *right-hand* ones and that the
    /// prompt they cannot find is down there somewhere. This says what has happened to them and the
    /// one thing that fixes it.
    public static func geometryNote(host: GridSize, pane: GridSize) -> String? {
        guard host.cols > pane.cols || host.rows > pane.rows else { return nil }
        return "Host is \(host.cols)×\(host.rows) — the prompt and cursor may be off screen;"
            + " enlarge the window"
    }

    /// The word beside this tab's title, or nil when there is none.
    ///
    /// It was the role and nothing else, so an ended, failed or suspended tab wore `writer` or
    /// `observer` -- a live-looking word on a tab that refuses every keystroke. The badge answers
    /// what this tab *is*: a role while there is one, "offline" while its host is away, and nothing
    /// at all before a role has been granted or after there is nothing left to have one in.
    public var badge: String? {
        switch phase {
        case .live, .reconnecting: return role == .writer ? "writer" : "observer"
        case .suspended: return "offline"
        case .attaching, .snapshot, .ended, .failed: return nil
        }
    }
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

    /// A second tab tried to take over an attachment another window already owns.
    ///
    /// There is one attachment per session id and it has one owner: its callbacks are a single slot
    /// each, so a second `RemoteSession` wiring itself in silently froze the first window's tab in
    /// `live` -- still drawn, still accepting keystrokes, and never showing another byte. Choosing
    /// the row goes to the window that has it; this sentence is what a tab says if it ever gets
    /// past that.
    public static let alreadyOpen = "Already open in another window"

    /// `session_suspended` for a session this tab never actually reached. There is no transcript to
    /// keep and no snapshot to come back to, so it is a failed attach rather than a pause.
    public static let hostWentOfflineDuringAttach = "Host went offline before the session attached"
}
