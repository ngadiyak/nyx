import Foundation

/// One row of the tab bar's context menu.
public enum TabBarMenuItem: Equatable {
    case newTab
    case separator
    /// Opens the Remote rows -- the same list `Shell → Remote Sessions…` opens, which is the one
    /// place the offline Macs, the Macs with nothing open and the relay's own status line are
    /// explained. `reason` is nil when it can act, and otherwise the sentence saying why not.
    case newRemoteTab(reason: String?)
    /// That sentence again, as a row that *does* something: it opens Settings → Remote, where the
    /// field it names lives. Present only when `newRemoteTab` is dead.
    ///
    /// A disabled row and nothing else was the defect the palette's relay-status row had (D4): the
    /// one row that names the user's problem was the one row that refused to act on it. The
    /// sentence is on the dead item as well, as help and as a tooltip, so a pointer resting on the
    /// thing that will not work is answered there.
    case openRemoteSettings(String)
    /// Attach to this session directly, without the palette in between: the bar's menu is where a
    /// person who knows which Mac they want goes.
    ///
    /// Two strings, joined by `title` into the one line a menu row has. `NSMenuItem.subtitle` would
    /// have given it the palette's two lines and is **macOS 14.4**, three point releases above this
    /// package's floor (`Package.swift:23`); an `if #available` fork would be two different menus to
    /// read and to picture. Kept apart here rather than pre-joined so a test can assert the detail
    /// is the palette's own -- which is the thing that must not drift.
    case session(deviceID: String, sessionID: String, sessionTitle: String, detail: String)

    public var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .separator: return ""
        case .newRemoteTab: return "New Remote Tab\u{2026}"
        case .openRemoteSettings(let sentence): return sentence
        // An em dash, not the `·` the detail uses internally between its own clauses: the reader
        // has to be able to see where the machine and the session stop and where they were.
        case .session(_, _, let sessionTitle, let detail):
            return detail.isEmpty ? sessionTitle : "\(sessionTitle) \u{2014} \(detail)"
        }
    }

    /// What a menu draws greyed. The separator answers `true` so a caller can say
    /// `item.isEnabled = row.isEnabled` without a special case; `NSMenuItem.separator()` has no
    /// enabled state to set.
    public var isEnabled: Bool {
        if case .newRemoteTab(let reason) = self { return reason == nil }
        return true
    }
}

/// What a right-click on the tab bar offers.
///
/// In Core because every decision in it is one: which of two sentences says why the remote half is
/// dead, whether a Mac's sessions are worth listing, and what a session row reads as. `NyxApp` has
/// no test target, and a menu assembled in a view controller is a menu nothing can ask a question
/// about -- which is how the bar came to have no menu at all for two of the four things a
/// right-click can land on.
public enum TabBarMenu {
    /// `refusal` is the connection's answer, and **only** the one answer that is final: the relay
    /// has let go of this device for a reason reconnecting cannot fix (`bad_token`, `bad_signature`,
    /// `replaced`). It is distinct from `RemotePageStatus`'s, which is the *configuration's*, and
    /// neither can be said in the other's words -- "set Relay token above" is wrong about a relay
    /// that has refused a token it was given, and "Relay refused this device" is wrong about a Mac
    /// that has never been given one.
    ///
    /// **Every other socket state is deliberately not a reason.** Connecting, reconnecting, backing
    /// off, offline-and-retrying: the row's action is "open the list of remote sessions", and that
    /// list leads with the status row saying what the socket is doing
    /// (`RemoteCoordinator.paletteItems`). Greying the route to the explanation at the moment it is
    /// wanted -- which is the moment the relay is struggling -- is the opposite of the fix, and it
    /// would take the session rows with it on every launch.
    public static func items(catalogue: RemoteCatalogue, remote: RemoteMode, relay: String,
                             token: String, refusal: String?, now: Date,
                             home: String = "") -> [TabBarMenuItem] {
        var rows: [TabBarMenuItem] = [.newTab, .separator]
        // The configuration first: a feature that is switched off has nothing to fail at, which is
        // the same ordering `RemotePageStatus` itself applies.
        let gate = RemotePageStatus.text(mode: remote, relay: relay, token: token)
        let reason = gate.blocksPairing ? gate.sentence : refusal
        rows.append(.newRemoteTab(reason: reason))
        if let reason {
            rows.append(.openRemoteSettings(reason))
            // And nothing below it. A configuration that cannot work has no catalogue, and a relay
            // that has refused this device has had its catalogue emptied already (Task 4 Step 6),
            // so the early return is what `sessionRows` would produce anyway -- said outright
            // because a reader should not have to prove that to themselves.
            return rows
        }
        // Only what can actually be opened. The palette lists a sleeping Mac and a Mac with nothing
        // published as greyed placeholders, because in a list you produce by *typing* a paired Mac
        // that is simply missing reads as a broken pairing. A context menu is a list of verbs, and
        // it has "New Remote Tab…" above it for the rest.
        rows.append(contentsOf: sessionRows(catalogue: catalogue, now: now, home: home))
        return rows
    }

    /// One row per session that can actually be attached to, in the palette's own words.
    ///
    /// A function of its own rather than a loop inside `items`, and the reason is measured: with
    /// the body inlined into `items`, `make bench` fell from 185 MB/s to 177 -- below this
    /// project's 180 floor -- for a file the parser never calls. The package builds release with
    /// `-cross-module-optimization` (`Package.swift`); six bisecting builds put the whole 5% on
    /// that one call site. The working hypothesis the measurement supports, not confirmed further
    /// than that: a second caller of `RemoteCatalogue.detail` relaid out `nyx-bench`'s copy of
    /// `Terminal.feed` under cross-module optimization. Keeping the loop behind its own symbol
    /// puts the bench back at 185. Nothing here is hot; do not "simplify" it back inline without
    /// running `make bench` first.
    private static func sessionRows(catalogue: RemoteCatalogue, now: Date,
                                    home: String) -> [TabBarMenuItem] {
        catalogue.devices
            .filter { $0.online && !$0.notPaired }
            .flatMap { device in
                device.sessions.map { session in
                    .session(deviceID: device.id, sessionID: session.sessionID,
                             sessionTitle: "\(device.name) · \(session.title)",
                             detail: RemoteCatalogue.detail(for: session, now: now, home: home))
                }
            }
    }
}
