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

@Test func stripTextFailedIsTheReasonItself() {
    #expect(state(phase: .failed("Host is offline"), role: .observer).stripText == "Host is offline")
    #expect(state(phase: .failed("Not paired with this device"), role: .writer).stripText
        == "Not paired with this device")
    #expect(state(phase: .failed("Host is offline"), role: .writer).stripButton == nil)
    #expect(state(phase: .failed("Host is offline"), role: .writer).acceptsInput == false)
}

@Test func onlyEndedAndFailedCloseTheTabOnTheNextKey() {
    #expect(state(phase: .attaching, role: .observer).closesOnNextKey == false)
    #expect(state(phase: .snapshot, role: .observer).closesOnNextKey == false)
    #expect(state(phase: .live, role: .writer).closesOnNextKey == false)
    #expect(state(phase: .reconnecting, role: .writer).closesOnNextKey == false)
    #expect(state(phase: .ended("iMac"), role: .observer).closesOnNextKey)
    #expect(state(phase: .failed("Host is offline"), role: .observer).closesOnNextKey)
}

/// A tab whose attach failed still has to say which machine it was trying to reach: the strip
/// carries the reason, so the title is the only thing left naming the host.
@Test func aFailedAttachKeepsItsTabTitle() {
    #expect(state(phase: .failed("Host is offline"), role: .observer).tabTitle == "⟵ iMac · zsh")
}

// MARK: - AttachFailure

@Test func everyRelayErrorCodeHasASentenceOfItsOwn() {
    #expect(AttachFailure.text(code: "host_offline") == "Host is offline")
    #expect(AttachFailure.text(code: "not_paired") == "Not paired with this device")
    #expect(AttachFailure.text(code: "no_such_session") == "That session no longer exists")
    #expect(AttachFailure.text(code: "too_many") == "The host has too many viewers")
}

/// A relay that grows a code this build has never heard of must still leave the tab saying
/// something a person can act on, rather than an empty strip or a wire identifier.
@Test func anUnknownErrorCodeStillReads() {
    #expect(AttachFailure.text(code: "wat") == "The host could not be reached")
    #expect(AttachFailure.text(code: "") == "The host could not be reached")
}

@Test func theTimeoutHasItsOwnWords() {
    #expect(AttachFailure.noAnswer == "No answer from the host")
}

@Test func theStripLabelDropsWhatTheButtonAlreadySays() {
    let observing = state(phase: .live, role: .observer)
    #expect(observing.stripText == "Observing — Take control")
    #expect(observing.stripLabel == "Observing")
    #expect(state(phase: .live, role: .writer).stripLabel == nil)
    // Every state without a button reads exactly as its sentence.
    for s in [state(phase: .attaching, role: .observer), state(phase: .snapshot, role: .writer),
              state(phase: .reconnecting, role: .writer), state(phase: .ended("iMac"), role: .writer),
              state(phase: .failed("Host is offline"), role: .observer)] {
        #expect(s.stripLabel == s.stripText)
    }
}

/// The host's shell goes on setting its own title through the stream after the attach, so the tab
/// follows it -- with the arrow and the machine name still in front, which is the whole point of
/// the remote tab's title.
@Test func theTabTitleFollowsTheHostsOwnTitleOnceItSetsOne() {
    let s = AttachState(hostName: "iMac", title: "zsh")
    #expect(s.tabTitle(currentTitle: "vim Pane.swift") == "⟵ iMac · vim Pane.swift")
    #expect(s.tabTitle(currentTitle: "") == "⟵ iMac · zsh")
    #expect(s.tabTitle == s.tabTitle(currentTitle: ""))
}

// MARK: - Severity

/// Every state used to be the same accent band, so "Session ended" and "Attaching…" were the same
/// picture with different words in it -- the two things a person most needs to tell apart at a
/// glance, told apart only by reading.
@Test func onlyTheStatesThatWentWrongAreWarnings() {
    #expect(state(phase: .attaching, role: .observer).severity == .info)
    #expect(state(phase: .snapshot, role: .observer).severity == .info)
    #expect(state(phase: .live, role: .observer).severity == .info)
    // Reconnecting is not a warning: it is a state that fixes itself, and the strip already says so.
    #expect(state(phase: .reconnecting, role: .writer).severity == .info)
    #expect(state(phase: .ended("iMac"), role: .writer).severity == .warning)
    #expect(state(phase: .failed("Host is offline"), role: .observer).severity == .warning)
}

/// The one state with no strip has no severity to draw either.
@Test func theLiveWriterHasNoStripAndSoNoBand() {
    let writer = state(phase: .live, role: .writer)
    #expect(writer.stripText == nil)
    #expect(writer.severity == .info)
}

@Test func turningRemoteSessionsOffEndsATabWithWordsOfItsOwn() {
    #expect(AttachFailure.remoteTurnedOff == "Remote sessions turned off")
}

@Test func aRelayThatRefusesThisDeviceSaysWhichRefusal() {
    #expect(AttachFailure.relayRefused("bad_token") == "Relay refused this device (bad_token)")
    #expect(AttachFailure.relayRefused("replaced") == "Relay refused this device (replaced)")
}

/// Three reasons a remote tab ends from this side, and they are three different sentences: the
/// switch went off, a setting changed under it, or the relay stopped accepting this device. Saying
/// "turned off" for a device-name edit would be a lie the user could check.
@Test func theThreeReasonsThisSideEndsATabAreDistinct() {
    let reasons = [AttachFailure.remoteTurnedOff, AttachFailure.remoteSettingsChanged,
                   AttachFailure.relayRefused("bad_token")]
    #expect(Set(reasons).count == 3)
    #expect(AttachFailure.remoteSettingsChanged == "Remote settings changed")
}
