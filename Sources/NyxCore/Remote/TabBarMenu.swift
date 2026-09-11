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
    /// `sessionTitle` is the Mac and the tab's own title; `age` is when that tab was last touched,
    /// and it is the **only** other fact on the row. The palette's full detail used to be here, and
    /// on a live relay it read `beta · zsh — ~ — ~ · running: zsh · just now`: `TabTitle.fallback`
    /// already publishes `"\(process) — \(place)"` whenever the shell has not set an OSC title, so
    /// the title carries the process and the directory, and the detail then said both again after a
    /// second em dash. What a person picks a session by is which Mac, what it calls itself, and how
    /// stale it is; the rest is one row above, in `New Remote Tab…`, which opens the palette.
    ///
    /// Two strings, joined by `title` into the one line a menu row has. `NSMenuItem.subtitle` would
    /// have given it two lines and is **macOS 14.4**, three point releases above this package's
    /// floor (`Package.swift:23`); an `if #available` fork would be two different menus to read and
    /// to picture. Kept apart here rather than pre-joined so a test can assert the age is the
    /// palette's own piece -- which is the thing that must not drift.
    case session(deviceID: String, sessionID: String, sessionTitle: String, age: String)

    public var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .separator: return ""
        case .newRemoteTab: return "New Remote Tab\u{2026}"
        case .openRemoteSettings(let sentence): return sentence
        // `·`, the palette's own separator, and not an em dash: the ordinary session title contains
        // an em dash already (`TabTitle.fallback`), so a second one made the row unreadable rather
        // than clearer. An unparseable timestamp gives an empty age, and the row is then the two
        // names with no trailing separator hanging off them.
        case .session(_, _, let sessionTitle, let age):
            return age.isEmpty ? sessionTitle : "\(sessionTitle) \u{b7} \(age)"
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
                             token: String, refusal: String?, now: Date) -> [TabBarMenuItem] {
        var rows: [TabBarMenuItem] = [.newTab, .separator]
        let reason = deadReason(remote: remote, relay: relay, token: token, refusal: refusal)
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
        rows.append(contentsOf: sessionRows(catalogue: catalogue, now: now))
        return rows
    }

    /// What a **tab's** own menu gains at its end, which is nothing at all until the user has asked
    /// for remote sessions.
    ///
    /// Measured: `menu-tab-light.png` is 228 pt wide, and the widest of these sentences is 62
    /// characters -- appending it more than doubles the width of the nine-row menu that every user
    /// who has never enabled the feature right-clicks. The bar's own menu is unaffected (it is
    /// three rows about the two kinds of tab there are, and "the other kind exists" is worth saying
    /// there); a tab's menu is nine rows about that tab, and a tenth about a feature the
    /// configuration says is off is an advertisement.
    ///
    /// Once `remote = on` the user has opted in, and the dead row with its sentence is then owed
    /// where they right-clicked -- the same greyed row plus live sentence pair the bar shows, since
    /// a greyed row alone naming your problem and offering nothing was the D4 defect.
    ///
    /// Deliberately no session rows: `New Remote Tab…` opens the list, and the bar's menu carries
    /// them.
    public static func tabMenuTail(remote: RemoteMode, relay: String, token: String,
                                   refusal: String?) -> [TabBarMenuItem] {
        guard remote == .on else { return [] }
        guard let reason = deadReason(remote: remote, relay: relay, token: token,
                                      refusal: refusal) else {
            return [.newRemoteTab(reason: nil)]
        }
        return [.newRemoteTab(reason: reason), .openRemoteSettings(reason)]
    }

    /// Why `New Remote Tab…` is dead, or nil. The configuration first: a feature that is switched
    /// off has nothing to fail at, which is the same ordering `RemotePageStatus` itself applies.
    /// One spelling, so the bar's menu and a tab's cannot disagree about whether it works.
    private static func deadReason(remote: RemoteMode, relay: String, token: String,
                                   refusal: String?) -> String? {
        let gate = RemotePageStatus.text(mode: remote, relay: relay, token: token)
        return gate.blocksPairing ? gate.sentence : refusal
    }

    /// One row per session that can actually be attached to: which Mac, what the tab there calls
    /// itself, and how stale it is.
    ///
    /// The age is `RemoteCatalogue.relative`, the palette's own piece, so the two lists cannot
    /// describe one moment two ways.
    ///
    /// A function of its own rather than a loop inside `items`, and the history is measured. When
    /// this row called `RemoteCatalogue.detail`, inlining the body into `items` dropped `make
    /// bench` from 185 MB/s to 177 -- below this project's 180 floor -- for a file the parser never
    /// calls; the package builds release with `-cross-module-optimization` (`Package.swift`) and
    /// six bisecting builds put the whole 5% on that one cross-module call site. The row now calls
    /// the much smaller `RemoteCatalogue.relative` instead, and **re-measured on this tree the
    /// effect is gone**: back to back, 188/187/186 MB/s with the loop behind this symbol and
    /// 185/186/188 with it inlined into `items` -- one spread, both well above the floor. The
    /// function is kept because it is the clearer shape, not because the bench still needs it.
    /// Nothing here is hot; if you do rearrange it, run `make bench`.
    private static func sessionRows(catalogue: RemoteCatalogue, now: Date) -> [TabBarMenuItem] {
        catalogue.devices
            .filter { $0.online && !$0.notPaired }
            .flatMap { device in
                device.sessions.map { session in
                    .session(deviceID: device.id, sessionID: session.sessionID,
                             sessionTitle: "\(device.name) \u{b7} \(session.title)",
                             age: RemoteCatalogue.relative(session.lastActivity, now: now))
                }
            }
    }
}
