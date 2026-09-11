import Foundation
import Testing
@testable import NyxCore

private let now = ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z")!

private func session(id: String = "s1", title: String = "zsh", cwd: String = "/tmp",
                      repo: String = "", branch: String = "", process: String = "",
                      lastCommand: String = "", lastActivity: String = "") -> RemoteSessionInfo {
    RemoteSessionInfo(sessionID: id, title: title, cwd: cwd, repo: repo, branch: branch,
                      process: process, lastCommand: lastCommand, lastActivity: lastActivity,
                      cols: 80, rows: 24)
}

// MARK: - Presence + catalogue -> palette rows

@Test func presenceThenCatalogueProduceOneRowPerSession() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [
        session(title: "zsh", cwd: "/home/nik/projects/nyx", branch: "main",
                process: "swift test", lastCommand: "make test", lastActivity: "2026-09-05T11:58:00Z")
    ])
    let items = c.paletteItems(now: now)
    #expect(items.count == 1)
    #expect(items[0].title == "iMac · zsh")
    #expect(items[0].detail == RemoteCatalogue.detail(for: session(cwd: "/home/nik/projects/nyx",
        branch: "main", process: "swift test", lastCommand: "make test",
        lastActivity: "2026-09-05T11:58:00Z"), now: now))
}

@Test func theDetailStringMatchesTheDesignExample() {
    let s = session(cwd: "/home/nik/projects/nyx", branch: "main", process: "swift test",
                    lastCommand: "make test", lastActivity: "2026-09-05T11:58:00Z")
    let text = RemoteCatalogue.detail(for: s, now: now, home: "/home/nik")
    #expect(text == "~/projects/nyx  main · running: swift test · last: make test · 2 min ago")
}

@Test func anOfflineDeviceYieldsOnePlaceholderRow() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    let items = c.paletteItems(now: now)
    #expect(items.count == 1)
    #expect(items[0].detail == "offline")
    #expect(items[0].kind == .remoteSession(deviceID: "d1", sessionID: ""))
}

@Test func anOnlineDeviceWithNoSessionsSaysSoInsteadOfVanishing() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [])
    let items = c.paletteItems(now: now)
    #expect(items.count == 1)
    #expect(items[0].title == "iMac")
    #expect(items[0].detail == "no sessions")
    #expect(items[0].kind == .remoteSession(deviceID: "d1", sessionID: ""))
}

/// The paired-but-never-seen case: a device only `setPaired` knows about is offline, and must not
/// be reported as an online Mac that happens to be running nothing.
@Test func aPairedDeviceThatHasNeverConnectedIsOfflineNotEmpty() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    let row = c.paletteItems(now: now)[0]
    #expect(row.title == "iMac")
    #expect(row.detail == "offline")
}

// MARK: - relative()

@Test func relativeJustUnderAMinuteIsJustNow() {
    #expect(RemoteCatalogue.relative(iso(secondsAgo: 59), now: now) == "just now")
}

@Test func relativeAtOneMinute() {
    #expect(RemoteCatalogue.relative(iso(secondsAgo: 60), now: now) == "1 min ago")
}

@Test func relativeAtOneHour() {
    #expect(RemoteCatalogue.relative(iso(secondsAgo: 3600), now: now) == "1 h ago")
}

@Test func relativeAtADayIsYesterday() {
    #expect(RemoteCatalogue.relative(iso(secondsAgo: 86400), now: now) == "yesterday")
}

@Test func relativeOfGarbageIsEmpty() {
    #expect(RemoteCatalogue.relative("not a date", now: now) == "")
}

private func iso(secondsAgo: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
}

// MARK: - cwd shortening

@Test func cwdIsShortenedToTilde() {
    let s = session(cwd: "/home/nik/projects/nyx")
    #expect(RemoteCatalogue.detail(for: s, now: now, home: "/home/nik") == "~/projects/nyx")
}

@Test func cwdWithNoHomePrefixIsUnchanged() {
    let s = session(cwd: "/var/tmp")
    #expect(RemoteCatalogue.detail(for: s, now: now, home: "/home/nik") == "/var/tmp")
}

// MARK: - Sorting

@Test func devicesSortOnlineFirstThenByName() {
    var c = RemoteCatalogue()
    c.setPaired(["a": "Alpha", "b": "Zebra", "c": "Beta"])
    c.applyPresence([
        RemotePresence(deviceID: "b", name: "Zebra", online: false),
        RemotePresence(deviceID: "a", name: "Alpha", online: true),
        RemotePresence(deviceID: "c", name: "Beta", online: true),
    ])
    #expect(c.devices.map(\.id) == ["a", "c", "b"])
}

// MARK: - PaletteSource ordering

@Test func remoteRowsComeLastInThePalette() {
    let remote = PaletteItem.remoteSession(deviceID: "d", sessionID: "s", title: "iMac · zsh", detail: "")
    let items = PaletteSource.items(actions: [.newTab], chord: { _ in nil },
                                    themes: ["dracula"], tabTitles: ["zsh"], remote: [remote])
    #expect(items.last?.kind == .remoteSession(deviceID: "d", sessionID: "s"))
}

@Test func aPaletteRowShortensTheHomeDirectory() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session(cwd: "/Users/nik/projects/nyx")])
    #expect(c.paletteItems(now: now, home: "/Users/nik")[0].detail.hasPrefix("~/projects/nyx"))
    #expect(c.paletteItems(now: now)[0].detail.hasPrefix("/Users/nik/projects/nyx"))
}

// MARK: - Rows nothing can be done with

/// Spec §5.3: an offline host is greyed. The three rows that stand for something rather than being
/// something -- an offline Mac, a Mac with nothing open, the relay's status -- say so in the model,
/// because a row drawn exactly like an actionable one is a row people press.
@Test func theThreeNonActionableRowsAreDisabled() {
    var c = RemoteCatalogue()
    c.relayStatusText = "Relay unreachable (nyx.agentforge.cc)"
    c.setPaired(["d1": "iMac", "d2": "Mac mini"])
    c.applyPresence([
        RemotePresence(deviceID: "d1", name: "iMac", online: true),
        RemotePresence(deviceID: "d2", name: "Mac mini", online: false),
    ])
    c.applyCatalogue(deviceID: "d1", sessions: [])
    #expect(c.paletteItems(now: now).allSatisfy { !$0.isEnabled })
}

@Test func aSessionRowIsActionable() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session()])
    #expect(c.paletteItems(now: now)[0].isEnabled)
}

@Test func everyOtherKindOfRowIsActionable() {
    #expect(PaletteItem.action(.newTab, chord: nil).isEnabled)
    #expect(PaletteItem.theme("dracula").isEnabled)
    #expect(PaletteItem.tab(0, title: "zsh").isEnabled)
}

/// The state belongs on one side of the row, not on both. "iMac — offline" beside a detail reading
/// "offline" said it twice; the title is the machine and the detail is what is wrong with it.
@Test func aStateIsSaidOnceNotTwice() {
    var c = RemoteCatalogue()
    c.relayStatusText = "Relay unreachable (nyx.agentforge.cc)"
    c.setPaired(["d1": "iMac", "d2": "Mac mini"])
    c.applyPresence([
        RemotePresence(deviceID: "d1", name: "iMac", online: true),
        RemotePresence(deviceID: "d2", name: "Mac mini", online: false),
    ])
    c.applyCatalogue(deviceID: "d1", sessions: [])
    let items = c.paletteItems(now: now)
    #expect(items[0].title == "Relay unreachable (nyx.agentforge.cc)")
    #expect(items[0].detail == "")
    #expect(items[1].title == "iMac")
    #expect(items[1].detail == "no sessions")
    #expect(items[2].title == "Mac mini")
    #expect(items[2].detail == "offline")
}

// MARK: - Only paired devices

/// The relay decides what `presence` and `catalogue` say, and it is the one participant this
/// design does not trust (§7.1: it routes, it does not vouch). A relay that named a device this
/// Mac has never paired with would otherwise put a row in ⌘⇧P -- with a machine name and a
/// directory of its choosing -- that looks exactly like a Mac the user owns. Attaching to it would
/// fail at the signature check, but the row should never have been offered.
@Test func anUnpairedDeviceNeverYieldsARow() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true),
                     RemotePresence(deviceID: "evil", name: "iMac", online: true)])
    c.applyCatalogue(deviceID: "evil", sessions: [session(title: "zsh")])

    let items = c.paletteItems(now: now)
    #expect(items.count == 1)
    #expect(items[0].kind == .remoteSession(deviceID: "d1", sessionID: ""))
    #expect(c.devices.map(\.id) == ["d1"])
}

/// Remove in the settings page takes the Mac out of the palette, not just out of `paired.json`.
/// Before this, `setPaired` only ever added: an unpaired device kept its rows -- with live
/// sessions on them -- until Nyx was restarted.
@Test func unpairingTakesTheDeviceOutOfTheCatalogue() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac", "d2": "Mac mini"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true),
                     RemotePresence(deviceID: "d2", name: "Mac mini", online: true)])
    c.applyCatalogue(deviceID: "d2", sessions: [session(title: "zsh")])
    #expect(c.paletteItems(now: now).count == 2)

    c.setPaired(["d1": "iMac"])
    let items = c.paletteItems(now: now)
    #expect(items.count == 1)
    #expect(items[0].kind == .remoteSession(deviceID: "d1", sessionID: ""))
}

// MARK: - Finding a session by what you were doing in it

/// A palette that matched only the machine name and the window title made the Remote section a
/// list you scrolled rather than searched: what a person remembers about a session on another Mac
/// is what they were doing in it, not what its title bar happened to say.
@Test func aRemoteRowIsFoundByTheLastCommandRunInIt() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [
        session(id: "s1", title: "zsh", cwd: "/Users/nik/projects/nyx", repo: "nyx",
                branch: "feat/remote-sessions", process: "swift", lastCommand: "swift test"),
        session(id: "s2", title: "zsh", cwd: "/Users/nik/notes", lastCommand: "ls"),
    ])
    var palette = CommandPalette(items: c.paletteItems(now: now))

    palette.setQuery("swift test")

    #expect(palette.results.count == 1)
    #expect(palette.selected?.kind == .remoteSession(deviceID: "d1", sessionID: "s1"))
}

/// The other four fields, each on its own, because each of them is a thing somebody types: the
/// directory, the repository, the branch, and what is running right now.
@Test func aRemoteRowIsFoundByItsDirectoryRepoBranchOrProcess() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [
        session(id: "s1", title: "zsh", cwd: "/Users/nik/projects/nyx", repo: "nyx",
                branch: "feat/remote-sessions", process: "htop", lastCommand: ""),
    ])
    let items = c.paletteItems(now: now)

    for query in ["projects/nyx", "nyx", "remote-sessions", "htop"] {
        var palette = CommandPalette(items: items)
        palette.setQuery(query)
        #expect(palette.results.count == 1, "\(query) found nothing")
    }
}

/// A row with nothing but a title still searches by title -- and does not pick up a trail of empty
/// strings that would make it match a query of spaces.
@Test func aSessionWithNoDetailsStillSearchesByItsTitle() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session(id: "s1", title: "zsh", cwd: "")])
    var palette = CommandPalette(items: c.paletteItems(now: now))

    palette.setQuery("remote")

    #expect(palette.results.count == 1)
}

// MARK: - An offline name, and a Mac that has removed this one

/// D1. The relay sends `Name: ""` for a peer it has no live socket for, and `applyPresence` wrote
/// it over the name `setPaired` had put there -- so two sleeping Macs were two identical blank
/// rows, and §5.3's promise of "its name greyed with 'offline'" was a promise about nothing. The
/// comment that a presence name "is the freshest name Nyx has, so it always wins" is right for an
/// online device and wrong for the one case that reaches it every time.
@Test func anOfflinePresenceDoesNotEraseTheNameWeAlreadyHave() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false)])
    #expect(c.devices.first?.name == "Mac mini (office)")
    let rows = c.paletteItems(now: Date())
    #expect(rows.first?.title == "Mac mini (office)")
    #expect(rows.first?.detail == "offline")
    #expect(rows.first?.isEnabled == false)
}

/// A name presence *does* supply still wins: it is the one the other Mac is announcing now.
@Test func anOnlinePresenceNameStillWins() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "old name"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "renamed", online: true)])
    #expect(c.devices.first?.name == "renamed")
}

/// D6/B2 in the palette: a Mac that has removed this one is not a Mac that is asleep, and the row
/// has to stop offering something to press. It keeps the name, because the name is how a person
/// knows *which* Mac to go and re-pair.
@Test func anUnpairedPeerReadsAsUnpairedRatherThanOffline() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyCatalogue(deviceID: "d1", sessions: [session()])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false, notPaired: true)])
    let rows = c.paletteItems(now: Date())
    #expect(rows.count == 1)
    #expect(rows[0].title == "Mac mini (office)")
    #expect(rows[0].detail == "no longer paired with this Mac")
    #expect(rows[0].isEnabled == false)
    // Its sessions go with it: a row you could press was the defect, not the label.
    #expect(c.devices.first?.sessions.isEmpty == true)
}

/// And the flag clears, or the row would stay dead through the next pairing.
@Test func aRepairedPeerComesBackOnline() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false, notPaired: true)])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    #expect(c.devices.first?.notPaired == false)
    #expect(c.devices.first?.online == true)
}

/// D6's other half, for the relay that cannot say it: the `not_paired` answer to an *attach* is
/// the first thing this Mac hears, and the rows have to go on that too.
@Test func forgettingADeviceTakesItsRowsWithoutUnpairingIt() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)", "d2": "iMac (studio)"])
    c.applyCatalogue(deviceID: "d1", sessions: [session()])
    c.forget(deviceID: "d1")
    #expect(c.devices.count == 1)
    #expect(c.devices.first?.id == "d2")
    // And it is not a re-pair: the next `setPaired` from the same `paired.json` puts the row back
    // as an offline one, which is honest -- this Mac has not removed anything.
    c.setPaired(["d1": "Mac mini (office)", "d2": "iMac (studio)"])
    #expect(c.devices.count == 2)
}

/// D1 again, on the path task 4 itself added. `forget` deletes the row, and the very next `presence`
/// rebuilt it from the message -- where the name is `""`, because the relay sends an empty one for
/// any peer it has no live socket for, which is every peer this path is about. The row a person
/// reaches through the attach refusal came back blank: "" greyed with "no longer paired with this
/// Mac", naming no Mac to go and re-pair. The name this Mac declared is the one to fall back on.
@Test func aForgottenDeviceComesBackWithTheNameThisMacDeclared() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.forget(deviceID: "d1")
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false, notPaired: true)])
    let unpaired = c.paletteItems(now: now)
    #expect(unpaired.first?.title == "Mac mini (office)")
    #expect(unpaired.first?.detail == "no longer paired with this Mac")
    // And the same again for the relay that cannot say `not_paired`: its empty name reaches the
    // offline row through the identical fallback.
    c.forget(deviceID: "d1")
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false)])
    let offline = c.paletteItems(now: now)
    #expect(offline.first?.title == "Mac mini (office)")
    #expect(offline.first?.detail == "offline")
}

/// The other message with the same fallback: a `catalogue` for a device whose row has been
/// forgotten -- the host re-paired and published again -- created it with no name at all, so every
/// one of its session rows read " · zsh".
@Test func aForgottenDeviceThatPublishesAgainIsStillNamed() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.forget(deviceID: "d1")
    c.applyCatalogue(deviceID: "d1", sessions: [session()])
    #expect(c.paletteItems(now: now).first?.title == "Mac mini (office) · zsh")
}
