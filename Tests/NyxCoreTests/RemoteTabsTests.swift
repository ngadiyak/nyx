import Testing
@testable import NyxCore

private let studio = "host-studio"
private let loft = "host-loft"

private func open(_ index: Int, _ host: String, _ session: String) -> RemoteTabs.Open {
    RemoteTabs.Open(index: index, hostID: host, sessionID: session)
}

@Test func aSessionAlreadyOpenNamesItsTab() {
    let tabs = [open(0, studio, "aaa"), open(2, studio, "bbb"), open(3, loft, "ccc")]
    #expect(RemoteTabs.existing(sessionID: "bbb", hostID: studio, among: tabs) == 2)
    #expect(RemoteTabs.existing(sessionID: "ccc", hostID: loft, among: tabs) == 3)
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
