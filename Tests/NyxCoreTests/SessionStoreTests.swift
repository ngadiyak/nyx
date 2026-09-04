import Foundation
import Testing
@testable import NyxCore

private func pane(_ id: Int) -> PaneSnapshot {
    PaneSnapshot(id: id, workingDirectory: "/tmp", title: "zsh", transcript: "hello\r\n")
}

private func window(tabs: Int) -> WindowSnapshot {
    WindowSnapshot(tabs: (0..<tabs).map { _ in
        TabSnapshot(layout: .leaf(1), panes: [pane(1)], focused: 1)
    }, selectedTab: 0)
}

// MARK: - Where the file goes

/// Beside the config, never in the bundle -- and derived from `ConfigPath`, so a `$NYX_CONFIG`
/// pointing at a scratch directory takes the session file with it.
@Test func theSessionFileSitsBesideTheConfigFile() {
    let url = SessionPath.resolve(environment: [:], home: "/Users/nik")
    #expect(url.path == "/Users/nik/.config/nyx/session.json")
}

@Test func movingTheConfigMovesTheSessionFileWithIt() {
    let url = SessionPath.resolve(environment: ["NYX_CONFIG": "/tmp/scratch/config"], home: "/Users/nik")
    #expect(url.path == "/tmp/scratch/session.json")
}

@Test func theSessionFileCanBeNamedOutright() {
    let url = SessionPath.resolve(environment: ["NYX_SESSION": "/tmp/other.json"], home: "/Users/nik")
    #expect(url.path == "/tmp/other.json")
}

@Test func anEmptySessionOverrideIsIgnored() {
    let url = SessionPath.resolve(environment: ["NYX_SESSION": ""], home: "/Users/nik")
    #expect(url.path == "/Users/nik/.config/nyx/session.json")
}

// MARK: - Reading and writing

@Test func aSnapshotWrittenToDiskComesBack() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nyx-session-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(url: directory.appendingPathComponent("nested/session.json"))

    let original = SessionSnapshot(windows: [window(tabs: 2)])
    #expect(store.save(original))
    #expect(store.load() == original)

    store.clear()
    #expect(store.load() == nil)
}

/// Every failure path here has to be quiet, because the caller is either starting up or shutting
/// down and neither is a moment to throw.
@Test func aMissingOrRubbishFileReadsAsNoSession() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nyx-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("session.json")
    #expect(SessionStore(url: url).load() == nil)
    try Data("{ not json".utf8).write(to: url)
    #expect(SessionStore(url: url).load() == nil)
}

/// A path that cannot be written to says so instead of throwing out of a `applicationWillTerminate`.
@Test func anUnwritablePathReportsFailureRatherThanThrowing() {
    let store = SessionStore(url: URL(fileURLWithPath: "/dev/null/nyx/session.json"))
    #expect(!store.save(SessionSnapshot(windows: [window(tabs: 1)])))
}

// MARK: - How much is kept

@Test func onlyTheNewestRowsAreKept() {
    #expect(SessionCapture.rowRange(totalRows: 12_000, limit: 5_000) == 7_000..<12_000)
    #expect(SessionCapture.rowRange(totalRows: 300, limit: 5_000) == 0..<300)
}

/// A buffer with nothing in it, and a limit that makes no sense, must still produce a range that
/// can be handed to `transcript(rows:)` without trapping.
@Test func theRowCapIsAlwaysAValidRange() {
    #expect(SessionCapture.rowRange(totalRows: 0, limit: 5_000) == 0..<0)
    #expect(SessionCapture.rowRange(totalRows: 10, limit: 0) == 10..<10)
    #expect(SessionCapture.rowRange(totalRows: 10, limit: -5) == 10..<10)
    #expect(SessionCapture.rowRange(totalRows: -3, limit: 100) == 0..<0)
}

// MARK: - What launch does
//
// Every one of these must end with the user looking at a terminal. Three features have shipped in
// this project that silently did nothing; a restore that quietly opens no window is the same bug.

@Test func aGoodSnapshotIsRestored() {
    let snapshot = SessionSnapshot(windows: [window(tabs: 2), window(tabs: 1)])
    #expect(SessionRestore.plan(snapshot: snapshot, enabled: true) == .restore(snapshot.windows))
}

@Test func theSettingBeingOffMeansAFreshWindow() {
    #expect(SessionRestore.plan(snapshot: SessionSnapshot(windows: [window(tabs: 2)]),
                                enabled: false) == .freshWindow)
}

@Test func noFileMeansAFreshWindow() {
    #expect(SessionRestore.plan(snapshot: nil, enabled: true) == .freshWindow)
}

@Test func anUnusableSnapshotMeansAFreshWindow() {
    let old = SessionSnapshot(windows: [window(tabs: 1)],
                              savedAt: Date(timeIntervalSinceNow: -30 * 24 * 3600))
    #expect(SessionRestore.plan(snapshot: old, enabled: true) == .freshWindow)
}

/// A window with no tabs in it would restore as a window with nothing in it, which is worse than
/// no window at all -- and if every window is like that, there is nothing to restore.
@Test func windowsWithNoTabsAreDroppedAndCanFallBackAltogether() {
    let empty = WindowSnapshot(tabs: [], selectedTab: 0)
    #expect(SessionRestore.plan(snapshot: SessionSnapshot(windows: [empty]), enabled: true) == .freshWindow)

    let mixed = SessionSnapshot(windows: [empty, window(tabs: 1)])
    #expect(SessionRestore.plan(snapshot: mixed, enabled: true) == .restore([mixed.windows[1]]))
}

// MARK: - The setting

@Test func restoreSessionDefaultsToOnAndParses() {
    #expect(Config.defaults.restoreSession)
    let (off, d) = ConfigParser.parse("restore-session = no")
    #expect(d.isEmpty)
    #expect(!off.restoreSession)
    let (on, d2) = ConfigParser.parse("restore-session = yes")
    #expect(d2.isEmpty)
    #expect(on.restoreSession)
}

@Test func aBadRestoreSessionValueIsReportedAndKeepsTheDefault() {
    let (c, d) = ConfigParser.parse("restore-session = maybe")
    #expect(d.count == 1)
    #expect(c.restoreSession)
}

// MARK: - Where a window comes back

@Test func aSavedFrameComesBackAsARectangle() {
    let rect = SessionRestore.frame(from: [100, 200, 900, 600])
    #expect(rect == PaneRect(x: 100, y: 200, width: 900, height: 600))
}

/// The session file is plain JSON a person can edit, so nonsense in it has to be a possibility
/// rather than an assumption -- and a window 3 points wide has no title bar left to close it with.
@Test func aNonsensicalFrameIsIgnored() {
    #expect(SessionRestore.frame(from: nil) == nil)
    #expect(SessionRestore.frame(from: [1, 2, 3]) == nil)
    #expect(SessionRestore.frame(from: [0, 0, 3, 3]) == nil)
    #expect(SessionRestore.frame(from: [0, 0, .nan, 600]) == nil)
    #expect(SessionRestore.frame(from: [0, 0, .infinity, 600]) == nil)
}
