import Testing
@testable import NyxCore

private func state(phase: AttachState.Phase, role: AttachState.Role) -> AttachState {
    var s = AttachState(hostName: "iMac", title: "zsh")
    s.phase = phase
    s.role = role
    return s
}

@Test func tabTitleShowsHostAndTitle() {
    #expect(AttachState(hostName: "iMac", title: "zsh").tabTitle == "⟵ iMac · zsh")
}

@Test func newlyInitializedStateIsAttachingObserver() {
    let s = AttachState(hostName: "iMac", title: "zsh")
    #expect(s.phase == .attaching)
    #expect(s.role == .observer)
    #expect(s.acceptsInput == false)
}

@Test func stripTextAttachingIsTheSameForBothRoles() {
    #expect(state(phase: .attaching, role: .writer).stripText == "Attaching…")
    #expect(state(phase: .attaching, role: .observer).stripText == "Attaching…")
}

@Test func stripTextSnapshotIsStillAttaching() {
    #expect(state(phase: .snapshot, role: .writer).stripText == "Attaching…")
    #expect(state(phase: .snapshot, role: .observer).stripText == "Attaching…")
}

@Test func stripTextLiveWriterHasNoStrip() {
    let s = state(phase: .live, role: .writer)
    #expect(s.stripText == nil)
    #expect(s.stripButton == nil)
    #expect(s.acceptsInput == true)
}

@Test func stripTextLiveObserverOffersTakeControl() {
    let s = state(phase: .live, role: .observer)
    #expect(s.stripText == "Observing — Take control")
    #expect(s.stripButton == "Take control")
    #expect(s.acceptsInput == false)
}

@Test func stripTextReconnectingIsTheSameForBothRoles() {
    #expect(state(phase: .reconnecting, role: .writer).stripText == "Reconnecting…")
    #expect(state(phase: .reconnecting, role: .observer).stripText == "Reconnecting…")
}

@Test func stripTextEndedNamesTheHostFromTheEvent() {
    #expect(state(phase: .ended("iMac"), role: .writer).stripText == "Session ended on iMac")
    #expect(state(phase: .ended("iMac"), role: .observer).stripText == "Session ended on iMac")
}

@Test func badgeMatchesRole() {
    #expect(state(phase: .live, role: .writer).badge == "writer")
    #expect(state(phase: .live, role: .observer).badge == "observer")
}

@Test func stripButtonOnlyAppearsForObserverLive() {
    #expect(state(phase: .attaching, role: .observer).stripButton == nil)
    #expect(state(phase: .reconnecting, role: .observer).stripButton == nil)
    #expect(state(phase: .ended("iMac"), role: .observer).stripButton == nil)
}
