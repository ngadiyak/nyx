import Foundation
import Testing
@testable import NyxCore

private func live(_ role: AttachState.Role) -> AttachState {
    var s = AttachState(hostName: "beta", title: "zsh")
    s.phase = .live
    s.role = role
    return s
}

/// §8.1: the strip's state changes are announcement sites. They are the only notice a person gets
/// that a tab has stopped taking their keystrokes -- the change is a colour and a sentence in a row
/// they are not looking at, and nothing else in the window moves.
@Test func aPhaseChangeIsAnnouncedInTheStripsOwnWords() {
    var ended = live(.writer)
    ended.phase = .ended("beta")
    #expect(RemoteAnnouncement.text(from: live(.writer), to: ended)
        == "Session ended on beta · ⌘W to close")
}

@Test func losingTheWriterRoleIsAnnounced() {
    #expect(RemoteAnnouncement.text(from: live(.writer), to: live(.observer))
        == "Observing — Take control")
}

/// The one state with no strip is the one that needs words most: gaining the writer role is the
/// strip *disappearing*, which says nothing at all out loud.
@Test func gainingTheWriterRoleIsAnnouncedEvenThoughTheStripGoes() {
    #expect(RemoteAnnouncement.text(from: live(.observer), to: live(.writer))
        == "You can type in this session")
}

@Test func nothingIsAnnouncedWhenNeitherThePhaseNorTheRoleMoved() {
    var narrower = live(.observer)
    narrower.hostSize = GridSize(cols: 132, rows: 40)
    narrower.paneSize = GridSize(cols: 96, rows: 30)
    #expect(RemoteAnnouncement.text(from: live(.observer), to: narrower) == nil)
}

/// A tab's first state is not a change to announce: every remote tab would open by talking.
@Test func theFirstStateIsNotAnnounced() {
    #expect(RemoteAnnouncement.text(from: nil, to: live(.writer)) == nil)
}
