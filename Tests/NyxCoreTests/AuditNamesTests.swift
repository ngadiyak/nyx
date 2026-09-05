import Foundation
import Testing
@testable import NyxCore

private let date = Date(timeIntervalSince1970: 1_788_609_600) // 2026-09-05T12:00:00Z

/// Real ids, from the smoke run whose log this fix exists because of.
private let deviceID = "8hgFMxB9cg29wj9TIaSGnKA2L6BcejQCCI8iZ8NwNi8"
private let sessionID = "GntMPWQxgr1R_3FcRQke0g"

@Test func aKnownDeviceAndSessionResolveToTheirNames() {
    let resolved = AuditNames.resolve(deviceID: deviceID, sessionID: sessionID,
                                      names: [deviceID: "alpha"], titles: [sessionID: "zsh"])
    #expect(resolved.device == "alpha")
    #expect(resolved.session == "zsh")
}

/// §5.5 says the file reads `<device> attached to <session title>`. This is the whole line a
/// person opening `audit.log` sees, and the reason the mapping exists at all: before it, the log
/// held two base64 ids and told the host's user nothing they could act on.
@Test func theAttachedLineNamesBothEnds() {
    let named = AuditNames.naming(.attached(device: deviceID, session: sessionID),
                                  names: [deviceID: "alpha"], titles: [sessionID: "zsh"])
    #expect(AuditLine.text(named, at: date) == "2026-09-05T12:00:00Z  attached  alpha → zsh")
}

/// A device that was unpaired a moment ago, or a session whose pane has closed, has no name left
/// to look up. Eight characters is enough to tell two ids apart in a log and short enough not to
/// wrap the line -- and it is still the id, so it can be matched against `paired.json` by hand.
@Test func anUnknownIdFallsBackToItsFirstEightCharacters() {
    let resolved = AuditNames.resolve(deviceID: deviceID, sessionID: sessionID,
                                      names: [:], titles: [:])
    #expect(resolved.device == "8hgFMxB9")
    #expect(resolved.session == "GntMPWQx")
}

/// A pane that has never set a title publishes an empty one. An empty name in the log would read
/// as `attached   → ` -- worse than the id, because it names nothing at all.
@Test func anEmptyNameIsTreatedAsNoName() {
    let resolved = AuditNames.resolve(deviceID: deviceID, sessionID: sessionID,
                                      names: [deviceID: ""], titles: [sessionID: ""])
    #expect(resolved.device == "8hgFMxB9")
    #expect(resolved.session == "GntMPWQx")
}

@Test func tookControlAndDetachedAreNamedTheSameWay() {
    let names = [deviceID: "alpha"], titles = [sessionID: "swift test"]
    let took = AuditNames.naming(.tookControl(device: deviceID, session: sessionID),
                                 names: names, titles: titles)
    #expect(AuditLine.text(took, at: date) == "2026-09-05T12:00:00Z  took control  alpha → swift test")
    let gone = AuditNames.naming(.detached(device: deviceID, session: sessionID),
                                 names: names, titles: titles)
    #expect(AuditLine.text(gone, at: date) == "2026-09-05T12:00:00Z  detached  alpha → swift test")
}

@Test func aSessionEndingIsNamedByItsTitleAlone() {
    let ended = AuditNames.naming(.sessionEnded(session: sessionID),
                                  names: [:], titles: [sessionID: "zsh"])
    #expect(AuditLine.text(ended, at: date) == "2026-09-05T12:00:00Z  session ended  zsh")
}

/// Pairing events carry the peer's announced name, never an id, so there is nothing here to map.
/// Passing them through unchanged is what lets the caller name every event the same way.
@Test func pairingEventsPassThroughUntouched() {
    #expect(AuditNames.naming(.paired("alpha"), names: [:], titles: [:]) == .paired("alpha"))
    #expect(AuditNames.naming(.removed("alpha"), names: [:], titles: [:]) == .removed("alpha"))
}
