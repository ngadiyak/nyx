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
