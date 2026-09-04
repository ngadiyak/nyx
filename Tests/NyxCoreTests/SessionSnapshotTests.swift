import Foundation
import Testing
@testable import NyxCore

private func pane(_ id: Int, cwd: String? = "/Users/nik", transcript: String? = nil) -> PaneSnapshot {
    PaneSnapshot(id: id, workingDirectory: cwd, title: "zsh", transcript: transcript)
}

private func snapshot(savedAt: Date = Date()) -> SessionSnapshot {
    let layout = PaneLayoutNode.split(vertical: false, ratio: 0.4,
                                      first: .leaf(1),
                                      second: .split(vertical: true, ratio: 0.6,
                                                     first: .leaf(2), second: .leaf(3)))
    let tab = TabSnapshot(layout: layout, panes: [pane(1), pane(2), pane(3)], focused: 2,
                          customTitle: "build", groupName: "work", groupColorIndex: 3)
    return SessionSnapshot(windows: [WindowSnapshot(tabs: [tab], selectedTab: 0,
                                                    frame: [100, 200, 900, 600])],
                           savedAt: savedAt)
}

// MARK: - Round trip

@Test func aSnapshotSurvivesBeingWrittenAndReadBack() throws {
    let original = snapshot()
    let restored = try #require(SessionSnapshot.decoded(from: original.encoded()))
    #expect(restored == original)
}

@Test func theLayoutSurvivesWithItsRatiosAndAxes() throws {
    let restored = try #require(SessionSnapshot.decoded(from: snapshot().encoded()))
    let layout = restored.windows[0].tabs[0].layout
    guard case .split(let vertical, let ratio, _, let second) = layout else {
        Issue.record("layout was not a split")
        return
    }
    #expect(!vertical)
    #expect(ratio == 0.4)
    guard case .split(let innerVertical, _, _, _) = second else {
        Issue.record("inner node was not a split")
        return
    }
    #expect(innerVertical)
}

@Test func scrollbackTravelsAsAnsiText() throws {
    let text = "\u{1b}[31mred\u{1b}[0m\r\nplain\r\n"
    let snap = SessionSnapshot(windows: [WindowSnapshot(
        tabs: [TabSnapshot(layout: .leaf(1), panes: [pane(1, transcript: text)], focused: 1)],
        selectedTab: 0)])
    let restored = try #require(SessionSnapshot.decoded(from: snap.encoded()))
    #expect(restored.windows[0].tabs[0].panes[0].transcript == text)
}

// MARK: - Refusing to restore

/// A file from a newer Nyx cannot be read safely. Coming back to no windows is recoverable;
/// coming back to a half-read layout is confusing in a way that is hard to undo.
@Test func aSnapshotFromAnotherVersionIsNotUsed() throws {
    var object = try #require(JSONSerialization.jsonObject(with: snapshot().encoded()) as? [String: Any])
    object["version"] = SessionSnapshot.currentVersion + 1
    let data = try JSONSerialization.data(withJSONObject: object)
    let restored = SessionSnapshot.decoded(from: data)
    #expect(restored?.isUsable() != true)
}

/// Silently reopening twelve tabs from last month is worse than opening one fresh window.
@Test func aVeryOldSnapshotIsNotRestored() {
    let old = snapshot(savedAt: Date(timeIntervalSinceNow: -30 * 24 * 3600))
    #expect(!old.isUsable())
    #expect(snapshot(savedAt: Date(timeIntervalSinceNow: -3600)).isUsable())
}

/// A clock that moved backwards must not make a snapshot from the future look fresh.
@Test func aSnapshotDatedInTheFutureIsNotRestored() {
    #expect(!snapshot(savedAt: Date(timeIntervalSinceNow: 3600)).isUsable())
}

@Test func anEmptySnapshotIsNotWorthRestoring() {
    #expect(!SessionSnapshot(windows: []).isUsable())
    #expect(!SessionSnapshot(windows: [WindowSnapshot(tabs: [], selectedTab: 0)]).isUsable())
}

/// A truncated or garbled file must never stop the terminal starting.
@Test func rubbishDecodesToNothingRatherThanThrowing() {
    #expect(SessionSnapshot.decoded(from: Data("not json at all".utf8)) == nil)
    #expect(SessionSnapshot.decoded(from: Data()) == nil)
    #expect(SessionSnapshot.decoded(from: Data("{\"version\":1}".utf8)) == nil)
}

// MARK: - Layout conversion

@Test func aTreeConvertsToALayoutAndBack() {
    let tree = PaneTree.leaf(PaneID(1))
        .splitting(PaneID(1), axis: .horizontal, with: PaneID(2), ratio: 0.5)
        .splitting(PaneID(2), axis: .vertical, with: PaneID(3), ratio: 0.3)

    let layout = PaneLayoutNode(tree)
    #expect(layout.paneIDs == [1, 2, 3])

    // Restored panes are new objects with new ids, so the layout is remapped rather than reused.
    let remapped = layout.tree(idFor: { PaneID($0 + 100) })
    #expect(remapped?.panes == [PaneID(101), PaneID(102), PaneID(103)])
}

/// A shell that cannot be recreated should cost its pane, not the whole window.
@Test func aPaneThatCannotBeRestoredCollapsesToItsSibling() {
    let layout = PaneLayoutNode.split(vertical: false, ratio: 0.5, first: .leaf(1), second: .leaf(2))
    let tree = layout.tree(idFor: { $0 == 1 ? nil : PaneID($0) })
    #expect(tree == .leaf(PaneID(2)))
}

@Test func aLayoutWhoseEveryPaneIsGoneRestoresNothing() {
    let layout = PaneLayoutNode.split(vertical: false, ratio: 0.5, first: .leaf(1), second: .leaf(2))
    #expect(layout.tree(idFor: { _ in nil }) == nil)
}

/// A hand-edited or corrupted ratio must not produce a pane of zero width.
@Test func anImpossibleRatioIsClamped() {
    let layout = PaneLayoutNode.split(vertical: false, ratio: 9.9, first: .leaf(1), second: .leaf(2))
    guard case .split(_, let ratio, _, _)? = layout.tree(idFor: { PaneID($0) }) else {
        Issue.record("expected a split")
        return
    }
    #expect(ratio <= 0.95 && ratio >= 0.05)
}
