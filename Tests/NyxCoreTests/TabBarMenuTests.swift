import Foundation
import Testing
@testable import NyxCore

private let now = ISO8601DateFormatter().date(from: "2026-09-11T12:00:00Z")!

private func session(_ id: String, title: String, process: String = "zsh",
                     lastCommand: String = "", minutesAgo: Int = 2) -> RemoteSessionInfo {
    let at = ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    return RemoteSessionInfo(sessionID: id, title: title, cwd: "/home/nik/projects/nyx", repo: "nyx",
                             branch: "main", process: process, lastCommand: lastCommand,
                             lastActivity: at, cols: 80, rows: 24)
}

private func items(_ c: RemoteCatalogue, remote: RemoteMode = .on, relay: String = "wss://r/v1/ws",
                   token: String = "t", refusal: String? = nil) -> [TabBarMenuItem] {
    TabBarMenu.items(catalogue: c, remote: remote, relay: relay, token: token,
                     refusal: refusal, now: now)
}

private func tail(remote: RemoteMode = .on, relay: String = "wss://r/v1/ws",
                  token: String = "t", refusal: String? = nil) -> [TabBarMenuItem] {
    TabBarMenu.tabMenuTail(remote: remote, relay: relay, token: token, refusal: refusal)
}

/// Nothing but a dead `New Remote Tab…` is ever greyed. Stated once, here, and asserted by name
/// rather than by an `allSatisfy` over a rule the type itself defines -- a separator answers
/// `isEnabled == true` precisely so a caller needs no special case, which makes "everything is
/// enabled or a separator" true of every list this builder can produce and therefore worth nothing.
private func disabledTitles(_ rows: [TabBarMenuItem]) -> [String] {
    rows.filter { !$0.isEnabled }.map(\.title)
}

/// The shape every state shares: a new tab, a rule, and the way to a remote one. The bar's menu is
/// not a second command palette -- it is the two kinds of tab there are.
@Test func theMenuAlwaysOffersANewTabAndAWayToARemoteOne() {
    let rows = items(RemoteCatalogue())
    #expect(rows[0] == .newTab)
    #expect(rows[1] == .separator)
    #expect(rows[2] == .newRemoteTab(reason: nil))
    #expect(rows[0].title == "New Tab")
    #expect(rows[2].title == "New Remote Tab\u{2026}")
    #expect(disabledTitles(rows).isEmpty)
}

/// Remote switched off. The item is dead and says the sentence the Remote page says, not a fifth
/// spelling of it -- and the sentence itself is a row that opens the page it names.
@Test func remoteSwitchedOffKillsTheItemInTheRemotePagesOwnWords() {
    let rows = items(RemoteCatalogue(), remote: .off)
    let reason = "Remote sessions are off — tick Enable remote sessions to pair."
    #expect(rows[2] == .newRemoteTab(reason: reason))
    #expect(!rows[2].isEnabled)
    #expect(rows[3] == .openRemoteSettings(reason))
    #expect(rows[3].isEnabled)                       // the reason is the one thing left to press
    #expect(rows[3].title == reason)
    #expect(rows.count == 4)                         // and nothing to attach to below it
    #expect(disabledTitles(rows) == ["New Remote Tab\u{2026}"])
    #expect(reason == RemotePageStatus.text(mode: .off, relay: "", token: "").sentence)
}

/// And `remote = off` is a *greyed row with a sentence*, not an empty menu. Said outright because
/// the obvious thing to copy from `RemoteCoordinator.paletteItems` is its
/// `guard config.remote == .on else { return [] }`, and copying it here would delete the one row
/// that explains why the other one is missing -- which no Core test would catch if this one did not
/// exist, since a menu with two rows in it looks perfectly reasonable.
@Test func remoteSwitchedOffIsAGreyedRowWithAReasonRatherThanNoRowAtAll() {
    let rows = items(RemoteCatalogue(), remote: .off, relay: "", token: "")
    #expect(rows.count == 4)
    #expect(rows.contains { $0.title == "New Remote Tab\u{2026}" })
    #expect(rows.contains { $0.title.hasPrefix("Remote sessions are off") })
}

@Test func anEmptyTokenKillsItWithTheTokensOwnSentence() {
    let rows = items(RemoteCatalogue(), token: "  ")
    let reason = "Pairing needs a relay token — set Relay token above."
    #expect(rows[2] == .newRemoteTab(reason: reason))
    #expect(rows[3] == .openRemoteSettings(reason))
}

/// A relay that has **refused** this device -- `bad_token`, `bad_signature`, `replaced` -- is a
/// different sentence from the configuration's, and it is the connection's. It is also the only
/// socket state that greys the item: it is not coming back without a `connect()`.
@Test func aRefusedRelayKillsItWithTheRefusalsOwnSentence() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session("s1", title: "zsh")])
    let refusal = "Relay refused this device (replaced)"
    let rows = items(c, refusal: refusal)
    #expect(rows[2] == .newRemoteTab(reason: refusal))
    #expect(rows[3] == .openRemoteSettings(refusal))
    #expect(rows.count == 4)
    #expect(disabledTitles(rows) == ["New Remote Tab\u{2026}"])
}

/// And every *other* socket state leaves it alone, which is the whole of T10-3: connecting,
/// reconnecting, backing off, or simply offline and retrying. The item's action is
/// `showRemoteSessions()`, which opens a **list** -- and `RemoteCoordinator.paletteItems` leads that
/// list with the status row precisely so an outage is explained where the user is looking. Greying
/// the route to the explanation at the moment it is wanted is the opposite of the fix.
@Test func aRelayThatIsMerelyBusyLeavesTheItemAndItsSessionsAlone() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session("s1", title: "zsh")])
    // Exactly the configuration of the test above, minus the refusal.
    let rows = items(c, refusal: nil)
    #expect(rows[2] == .newRemoteTab(reason: nil))
    #expect(rows.count == 4)                         // …and row 3 is the session, not a sentence
    #expect(rows[3].title == "Mac mini (office) \u{b7} zsh \u{b7} 2 min ago")
    #expect(disabledTitles(rows).isEmpty)
}

/// Configured, connected, and nothing published. The item lives -- it opens the Remote rows, which
/// is where "no sessions" and "offline" are explained -- and there is nothing under it.
@Test func aWorkingRelayWithNothingOpenStillOffersTheWayIn() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    let rows = items(c)
    #expect(rows == [.newTab, .separator, .newRemoteTab(reason: nil)])
}

/// The everyday case: one Mac with two sessions, one asleep, one that unpaired this Mac. Only the
/// sessions a person can actually open get a row. The palette shows the other two as placeholders
/// because a paired Mac missing from a *search result* reads as a broken pairing; a context menu is
/// a list of verbs, and "iMac (studio) — offline" is not one.
@Test func onlyReachableSessionsGetARowAndTheyReadLikeThePalettesRows() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)", "d2": "iMac (studio)", "d3": "MacBook"])
    c.applyPresence([
        RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true),
        RemotePresence(deviceID: "d2", name: "iMac (studio)", online: false),
        RemotePresence(deviceID: "d3", name: "MacBook", online: false, notPaired: true),
    ])
    c.applyCatalogue(deviceID: "d1", sessions: [
        session("s1", title: "zsh", process: "swift test", lastCommand: "make test"),
        session("s2", title: "vim Pane.swift", process: "vim", lastCommand: "git status",
                minutesAgo: 60),
    ])
    let rows = items(c)
    #expect(rows.count == 5)
    // One line, because a menu row is one line: `NSMenuItem.subtitle` is macOS 14.4 and this
    // package's floor is 14.0. Three facts, in the palette's own separator: which Mac, what the
    // tab there calls itself, and when it was last touched.
    #expect(rows[3] == .session(deviceID: "d1", sessionID: "s1",
                                sessionTitle: "Mac mini (office) \u{b7} zsh", age: "2 min ago"))
    #expect(rows[3].title == "Mac mini (office) \u{b7} zsh \u{b7} 2 min ago")
    #expect(rows[4].title == "Mac mini (office) \u{b7} vim Pane.swift \u{b7} 1 h ago")
    #expect(disabledTitles(rows).isEmpty)
    // No row for the sleeping Mac and none for the one that unpaired this one.
    #expect(!rows.contains { $0.title.contains("iMac") })
    #expect(!rows.contains { $0.title.contains("MacBook") })
}

/// The **default** session title, which is the one the fixtures never had. `TabTitle.fallback`
/// publishes `"\(process) \u{2014} \(place)"` whenever the shell has not set an OSC title -- plain
/// zsh on macOS, i.e. most sessions -- so an ordinary title already contains an em dash. Joining
/// device, title and the palette's whole detail with a *second* em dash produced, on a live relay,
/// `beta \u{b7} zsh \u{2014} ~ \u{2014} ~ \u{b7} running: zsh \u{b7} just now`: two dashes, the
/// directory twice, and the tab's own words lost in the middle. The row is three `\u{b7}`-separated
/// facts and the title passes through untouched, so the only em dash in the row is the title's own.
@Test func aSessionRowIsTheDeviceTheTabsOwnTitleAndItsAge() {
    let s = session("s1", title: "zsh \u{2014} ~/projects/nyx", process: "swift test",
                    lastCommand: "make test")
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [s])
    let rows = items(c)
    #expect(rows[3] == .session(deviceID: "d1", sessionID: "s1",
                                sessionTitle: "Mac mini (office) \u{b7} zsh \u{2014} ~/projects/nyx",
                                age: "2 min ago"))
    #expect(rows[3].title == "Mac mini (office) \u{b7} zsh \u{2014} ~/projects/nyx \u{b7} 2 min ago")
    #expect(rows[3].title.filter { $0 == "\u{2014}" }.count == 1)
    // Nothing the palette one row above already says on its second line. `running:`, the branch and
    // the last command are its detail's, not this row's.
    #expect(!rows[3].title.contains("running:"))
    #expect(!rows[3].title.contains("make test"))
    #expect(!rows[3].title.contains("main"))
    // And the age is the palette's own piece, not a second spelling of "2 minutes": the two rows
    // describe one moment, so they are the same function.
    #expect(rows[3].title.hasSuffix(RemoteCatalogue.relative(s.lastActivity, now: now)))
    #expect(RemoteCatalogue.detail(for: s, now: now, home: "/home/nik").contains("2 min ago"))
}

/// A tab's own menu, with remote sessions never switched on -- the default configuration and most
/// users. Measured: the nine-row tab menu is 228 pt wide, and appending the 62-character sentence
/// more than doubles it, for a feature that user has not asked for. Nothing is appended at all.
@Test func aTabsMenuGainsNothingWhenRemoteSessionsAreOff() {
    #expect(tail(remote: .off) == [])
    #expect(tail(remote: .off, relay: "", token: "") == [])
    // Not even a relay that has refused this Mac: with the switch off there is nothing connecting
    // for it to have refused.
    #expect(tail(remote: .off, refusal: "Relay refused this device (replaced)") == [])
}

/// Opted in and misconfigured. The greyed row **and** its sentence, the same pair the bar's menu
/// shows: a user who ticked the box is owed the reason it does not work where they right-clicked.
@Test func aTabsMenuCarriesTheGreyedRowAndItsSentenceOnceRemoteIsOn() {
    let reason = "Pairing needs a relay token — set Relay token above."
    #expect(tail(token: " ") == [.newRemoteTab(reason: reason), .openRemoteSettings(reason)])
    #expect(disabledTitles(tail(token: " ")) == ["New Remote Tab\u{2026}"])
    let refusal = "Relay refused this device (replaced)"
    #expect(tail(refusal: refusal) == [.newRemoteTab(reason: refusal),
                                       .openRemoteSettings(refusal)])
}

/// Opted in and working: the live row alone. The sessions stay off a tab's menu -- it is nine rows
/// about *that tab* already, and `New Remote Tab…` opens the list.
@Test func aTabsMenuCarriesTheLiveRowAloneWhenRemoteIsReady() {
    #expect(tail() == [.newRemoteTab(reason: nil)])
    #expect(disabledTitles(tail()).isEmpty)
}
