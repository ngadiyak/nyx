import Foundation
import Testing
@testable import NyxCore

/// 14:32 in UTC, and every test that shows a clock time pins the zone to match.
private let offlineAt = Date(timeIntervalSince1970: 1_757_082_720)
private let utc = TimeZone(identifier: "UTC")!

private func suspended(_ host: String) -> AttachState.Phase { .suspended(host, since: offlineAt) }

/// A state whose clock is pinned: the same zone the times below are written in, and a "today" that
/// contains `offlineAt`, so the bare "14:32" is what a same-day suspension reads as.
private func suspendedState(_ host: String = "iMac", now: Date = offlineAt) -> AttachState {
    var s = state(phase: suspended(host), role: .writer)
    s.timeZone = utc
    s.today = AttachState.startOfDay(now, in: utc)
    return s
}

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
    #expect(state(phase: .ended("iMac"), role: .writer).stripText == "Session ended on iMac · ⌘W to close")
    #expect(state(phase: .ended("iMac"), role: .observer).stripText == "Session ended on iMac · ⌘W to close")
}

/// The one sentence that has to say two things at once: the session is fine and this tab is not
/// showing it right now. "Session ended" was what this build said before the relay could tell a
/// host that closed its lid from a host that closed the session.
///
/// It carries the time because "will reattach" reads the same after five seconds and after five
/// hours, and which of those it is, is the whole of what a person wants to know.
@Test func stripTextSuspendedSaysSinceWhenAndThatItIsWaiting() {
    let s = suspendedState()
    #expect(s.stripText
        == "iMac has been offline since 14:32 — waiting for it to come back · ⌘W to close")
    #expect(s.acceptsInput == false)
    #expect(s.severity == .warning)
    #expect(s.stripButton == "Close")
}

/// A wall-clock time in the reader's own zone, not the host's and not UTC.
@Test func theOfflineTimeIsInTheReadersOwnZone() {
    var s = state(phase: suspended("iMac"), role: .writer)
    s.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
    s.today = AttachState.startOfDay(offlineAt, in: s.timeZone)
    #expect(s.stripText?.contains("since 17:32") == true)
    s.timeZone = TimeZone(secondsFromGMT: -5 * 3600 - 1800)!
    s.today = AttachState.startOfDay(offlineAt, in: s.timeZone)
    #expect(s.stripText?.contains("since 09:02") == true)
}

// MARK: - "since" on a Mac that was left overnight

/// A bare "since 14:32" is the same four characters whether the host went five minutes ago or last
/// Tuesday -- and a suspended tab is exactly the kind of thing that is still open in the morning.
@Test func anOfflineTimeFromAnotherDayCarriesTheDay() {
    let day: TimeInterval = 86_400
    #expect(AttachState.offlineSince(offlineAt, today: offlineAt, in: utc) == "14:32")
    #expect(AttachState.offlineSince(offlineAt, today: offlineAt + day, in: utc)
        == "yesterday 14:32")
    #expect(AttachState.offlineSince(offlineAt, today: offlineAt + 2 * day, in: utc)
        == "5 Sep 14:32")
    #expect(AttachState.offlineSince(offlineAt, today: offlineAt + 30 * day, in: utc)
        == "5 Sep 14:32")
}

/// It is calendar days, not elapsed hours: 23:50 and 00:10 the next morning are twenty minutes
/// apart and still "yesterday", which is how a person reads a clock.
@Test func theDayBoundaryIsTheCalendarsNotTwentyFourHours() {
    let lateLastNight = Date(timeIntervalSince1970: 1_757_115_000)   // 23:30 UTC, 5 Sep
    let earlyToday = Date(timeIntervalSince1970: 1_757_119_800)      // 00:50 UTC, 6 Sep
    #expect(AttachState.offlineSince(lateLastNight, today: earlyToday, in: utc)
        == "yesterday 23:30")
    // The same two moments read in a zone where they fall on one day are simply a time.
    let west = TimeZone(secondsFromGMT: -6 * 3600)!
    #expect(AttachState.offlineSince(lateLastNight, today: earlyToday, in: west) == "17:30")
}

/// The whole sentence, on a tab left open overnight.
@Test func theStripSaysYesterdayOnATabLeftOvernight() {
    let s = suspendedState(now: offlineAt + 86_400)
    #expect(s.stripText
        == "iMac has been offline since yesterday 14:32 — waiting for it to come back · ⌘W to close")
}

/// ⌘W closes the whole tab, so a pane sharing its tab with another must not offer it: the Close
/// button beside these words closes this pane, and the two would have been saying different things.
@Test func aPaneSharingItsTabDoesNotOfferCommandW() {
    var s = state(phase: .ended("iMac"), role: .writer)
    s.closesWholeTab = false
    #expect(s.stripText == "Session ended on iMac")
    #expect(s.stripButton == "Close")
    var alone = s
    alone.closesWholeTab = true
    #expect(alone.stripText == "Session ended on iMac · ⌘W to close")
}

@Test func badgeMatchesRole() {
    #expect(state(phase: .live, role: .writer).badge == "writer")
    #expect(state(phase: .live, role: .observer).badge == "observer")
}

/// Two buttons, and the states that have neither. A tab that will never show another byte carries
/// its own way out, because it no longer closes itself on the next key.
@Test func theStripOffersTakeControlWhileObservingAndCloseOnceNothingMoreWillArrive() {
    #expect(state(phase: .attaching, role: .observer).stripButton == nil)
    #expect(state(phase: .snapshot, role: .observer).stripButton == nil)
    #expect(state(phase: .reconnecting, role: .observer).stripButton == nil)
    #expect(state(phase: .live, role: .observer).stripButton == "Take control")
    #expect(state(phase: .live, role: .writer).stripButton == nil)
    #expect(state(phase: .ended("iMac"), role: .observer).stripButton == "Close")
    #expect(state(phase: .failed("Host is offline"), role: .writer).stripButton == "Close")
    #expect(state(phase: suspended("iMac"), role: .writer).stripButton == "Close")
}

@Test func stripTextFailedIsTheReasonItself() {
    #expect(state(phase: .failed("Host is offline"), role: .observer).stripText
        == "Host is offline · ⌘W to close")
    #expect(state(phase: .failed("Not paired with this device"), role: .writer).stripText
        == "Not paired with this device · ⌘W to close")
    #expect(state(phase: .failed("Host is offline"), role: .writer).acceptsInput == false)
}

/// Every state that keeps a tab nothing will ever arrive in again says how to get rid of it. The
/// three that are still working say nothing of the kind, because ⌘W there would lose a live session.
@Test func onlyTheStatesThatKeepADeadTabTellYouHowToCloseIt() {
    for s in [state(phase: .ended("iMac"), role: .observer),
              state(phase: .failed("Host is offline"), role: .observer),
              suspendedState()] {
        #expect(s.stripText?.hasSuffix(" · ⌘W to close") == true)
    }
    for s in [state(phase: .attaching, role: .observer), state(phase: .snapshot, role: .observer),
              state(phase: .live, role: .observer), state(phase: .reconnecting, role: .writer)] {
        #expect(s.stripText?.contains("⌘W") != true)
    }
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
              state(phase: suspended("iMac"), role: .writer),
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
    #expect(state(phase: suspended("iMac"), role: .writer).severity == .warning)
}

// MARK: - The geometry note

/// The silent clipping a user could only diagnose by counting columns: a host on a 160-column
/// screen mirrored into a 96-column pane loses the right-hand third with nothing said.
@Test func aHostScreenBiggerThanThePaneSaysSoOnTheStrip() {
    // Two numbers and a subtraction was a puzzle: it left the reader to work out that the missing
    // columns are the right-hand ones and that the prompt is off the bottom.
    #expect(AttachState.geometryNote(host: GridSize(cols: 132, rows: 40),
                                     pane: GridSize(cols: 96, rows: 30))
        == "Host is 132×40 — the prompt and cursor may be off screen; enlarge the window")
    // Either dimension is enough: rows clip as invisibly as columns do.
    #expect(AttachState.geometryNote(host: GridSize(cols: 80, rows: 60),
                                     pane: GridSize(cols: 80, rows: 24)) != nil)
    #expect(AttachState.geometryNote(host: GridSize(cols: 200, rows: 24),
                                     pane: GridSize(cols: 80, rows: 24)) != nil)
}

/// A pane at least as big as the host has nothing to warn about -- the rest of it is letterboxed,
/// which is what §5.4 asks for and what a person can see for themselves.
@Test func aPaneBigEnoughForTheHostGetsNoNote() {
    #expect(AttachState.geometryNote(host: GridSize(cols: 80, rows: 24),
                                     pane: GridSize(cols: 80, rows: 24)) == nil)
    #expect(AttachState.geometryNote(host: GridSize(cols: 80, rows: 24),
                                     pane: GridSize(cols: 200, rows: 60)) == nil)
}

/// The one state with no sentence of its own is exactly where the note has to stand alone: a live
/// writer's tab is an ordinary terminal until it is quietly showing two thirds of somebody else's.
@Test func theNoteIsTheWholeStripWhenThePhaseHasNothingToSay() {
    var writer = state(phase: .live, role: .writer)
    #expect(writer.stripText == nil)
    writer.geometryNote = "Host is 132×40"
    #expect(writer.stripText == "Host is 132×40")
    #expect(writer.stripLabel == writer.stripText)
    #expect(writer.severity == .info)
    #expect(writer.stripButton == nil)
}

@Test func theNoteJoinsThePhasesOwnSentenceRatherThanReplacingIt() {
    var observing = state(phase: .live, role: .observer)
    observing.geometryNote = "Host is 132×40"
    #expect(observing.stripText == "Observing — Take control · Host is 132×40")
    #expect(observing.stripLabel == "Observing · Host is 132×40")
    #expect(observing.stripButton == "Take control")
}

/// A strip too narrow for both clauses loses the geometry note, not the end of the sentence in
/// front of it: a window that is too small is a thing the user can also simply see, and
/// "Mac mini has been offline since 14:3…" would lose the part that cannot be seen any other way.
@Test func aNarrowStripDropsTheGeometryNoteBeforeItTruncates() {
    var s = suspendedState("Mac mini")
    s.geometryNote = "Host is 132×40 — the prompt and cursor may be off screen; enlarge the window"
    let options = s.stripLabelOptions
    #expect(options.count == 2)
    #expect(options[0] == s.stripText)
    #expect(options[1] == "Mac mini has been offline since 14:32 — waiting for it to come back · ⌘W to close")
    #expect(options[0].count > options[1].count)
}

/// Nothing to choose between when there is no note: one option, and the view draws it.
@Test func aStripWithNoNoteHasOneOption() {
    #expect(state(phase: .ended("iMac"), role: .writer).stripLabelOptions
        == ["Session ended on iMac · ⌘W to close"])
    // The live writer has no strip at all, so there is nothing to offer the view.
    #expect(state(phase: .live, role: .writer).stripLabelOptions.isEmpty)
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

@Test func aSecondWindowIsToldWhyItCannotHaveTheAttachment() {
    #expect(AttachFailure.alreadyOpen == "Already open in another window")
}

@Test func aHostThatGoesBeforeTheAttachLandsIsAFailedAttach() {
    #expect(AttachFailure.hostWentOfflineDuringAttach
        == "Host went offline before the session attached")
}
