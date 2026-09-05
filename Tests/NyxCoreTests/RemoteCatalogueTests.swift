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
    c.applyPresence([
        RemotePresence(deviceID: "d1", name: "iMac", online: true),
        RemotePresence(deviceID: "d2", name: "Mac mini", online: false),
    ])
    c.applyCatalogue(deviceID: "d1", sessions: [])
    #expect(c.paletteItems(now: now).allSatisfy { !$0.isEnabled })
}

@Test func aSessionRowIsActionable() {
    var c = RemoteCatalogue()
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
