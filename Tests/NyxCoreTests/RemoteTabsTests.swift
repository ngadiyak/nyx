import Foundation
import Testing
@testable import NyxCore

private let studio = "host-studio"
private let loft = "host-loft"

private func open(window: Int = 0, _ index: Int, _ host: String, _ session: String,
                  live: Bool = true) -> RemoteTabs.Open {
    RemoteTabs.Open(window: window, index: index, hostID: host, sessionID: session, isLive: live)
}

@Test func aSessionAlreadyOpenNamesItsTab() {
    let tabs = [open(0, studio, "aaa"), open(2, studio, "bbb"), open(3, loft, "ccc")]
    #expect(RemoteTabs.existing(sessionID: "bbb", hostID: studio, among: tabs)
        == RemoteTabs.Match(window: 0, tab: 2))
    #expect(RemoteTabs.existing(sessionID: "ccc", hostID: loft, among: tabs)
        == RemoteTabs.Match(window: 0, tab: 3))
}

@Test func aSessionThatIsNotOpenHasNoTab() {
    let tabs = [open(0, studio, "aaa")]
    #expect(RemoteTabs.existing(sessionID: "zzz", hostID: studio, among: tabs) == nil)
    #expect(RemoteTabs.existing(sessionID: "aaa", hostID: studio, among: []) == nil)
}

/// A session id is sixteen random bytes made on the host, not a global name: two Macs can mint the
/// same one, and going to a tab on the wrong Mac would be worse than opening a second tab.
@Test func theSameSessionIDOnAnotherHostIsAnotherSession() {
    let tabs = [open(1, studio, "aaa")]
    #expect(RemoteTabs.existing(sessionID: "aaa", hostID: loft, among: tabs) == nil)
}

/// The palette's placeholder rows -- an offline Mac, a Mac with nothing open, the relay's status
/// line -- all carry an empty session id. Matching them to each other would select a tab for a row
/// that stands for nothing.
@Test func anEmptySessionIDMatchesNothingEvenAnotherEmptyOne() {
    let tabs = [open(0, studio, "")]
    #expect(RemoteTabs.existing(sessionID: "", hostID: studio, among: tabs) == nil)
}

/// The case that froze a tab rather than merely duplicating it: an attachment has one owner, so a
/// second window wiring itself into it left the first window's tab drawn, accepting keystrokes, and
/// never showing another byte. The answer has to name the window as well as the tab.
@Test func aSessionOpenInAnotherWindowNamesThatWindow() {
    let tabs = [open(window: 0, 1, studio, "aaa"), open(window: 2, 3, studio, "bbb")]
    #expect(RemoteTabs.existing(sessionID: "bbb", hostID: studio, among: tabs)
        == RemoteTabs.Match(window: 2, tab: 3))
}

/// A tab whose session ended keeps its transcript and stays on screen, but holds no attachment any
/// more. Selecting it would answer the palette row with a corpse, and the row would go on doing
/// nothing for as long as the dead tab was left open.
@Test func aDeadTabDoesNotShadowTheRow() {
    let tabs = [open(window: 0, 1, studio, "aaa", live: false)]
    #expect(RemoteTabs.existing(sessionID: "aaa", hostID: studio, among: tabs) == nil)
}

/// With both open -- the session ended in one window and was opened again in another -- the live
/// one is the answer, whichever order they are listed in.
@Test func aLiveTabWinsOverADeadOneForTheSameSession() {
    let dead = open(window: 0, 1, studio, "aaa", live: false)
    let live = open(window: 1, 0, studio, "aaa")
    #expect(RemoteTabs.existing(sessionID: "aaa", hostID: studio, among: [dead, live])
        == RemoteTabs.Match(window: 1, tab: 0))
    #expect(RemoteTabs.existing(sessionID: "aaa", hostID: studio, among: [live, dead])
        == RemoteTabs.Match(window: 1, tab: 0))
}

// MARK: - What "still holds the attachment" means

@Test func everyPhaseButEndedAndFailedStillHoldsItsAttachment() {
    func state(_ phase: AttachState.Phase) -> AttachState {
        var s = AttachState(hostName: "iMac", title: "zsh")
        s.phase = phase
        return s
    }
    #expect(state(.attaching).isAttached)
    #expect(state(.snapshot).isAttached)
    #expect(state(.live).isAttached)
    #expect(state(.reconnecting).isAttached)
    // Waiting, not finished: it is still the one tab that session belongs to.
    #expect(state(.suspended("iMac", since: Date())).isAttached)
    #expect(!state(.ended("iMac")).isAttached)
    #expect(!state(.failed("Host is offline")).isAttached)
}
