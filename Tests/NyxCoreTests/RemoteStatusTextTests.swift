import Testing
@testable import NyxCore

@Test func offBeatsWhateverTheConnectionSays() {
    // `mode: .off` must win even if a caller passes a stale `.online`, so a device that just
    // turned remote off cannot flash "Online as ..." on its way down.
    #expect(RemoteStatusText.text(mode: .off, connection: .online, deviceName: "MacBook") == "Remote sessions are off")
}

@Test func connectingReadsAsConnecting() {
    #expect(RemoteStatusText.text(mode: .on, connection: .connecting, deviceName: "MacBook") == "Connecting…")
}

@Test func onlineNamesTheDevice() {
    #expect(RemoteStatusText.text(mode: .on, connection: .online, deviceName: "MacBook") == "Online as MacBook")
}

@Test func unreachableNamesTheHost() {
    #expect(RemoteStatusText.text(mode: .on, connection: .unreachable(host: "nyx.agentforge.cc"), deviceName: "MacBook")
        == "Relay unreachable (nyx.agentforge.cc)")
}

@Test func badTokenSaysSo() {
    #expect(RemoteStatusText.text(mode: .on, connection: .badToken, deviceName: "MacBook")
        == "Relay rejected this device's token")
}

@Test func aRefusalNamesItsReason() {
    #expect(RemoteStatusText.text(mode: .on, connection: .refused("replaced"), deviceName: "MacBook")
        == "Relay refused this device (replaced)")
}

/// The keys are right and the relay is fine, but this Mac could not read or write its own identity
/// file. Nothing else on the page can say that, and "Connecting…" for ever is the alternative.
@Test func aStartupFailureOutranksTheConnection() {
    #expect(RemoteStatusText.text(mode: .on, connection: .connecting, deviceName: "MacBook",
                                  failure: "Remote sessions could not start: identity unreadable")
        == "Remote sessions could not start: identity unreadable")
}

@Test func offStillOutranksAStartupFailure() {
    #expect(RemoteStatusText.text(mode: .off, connection: .connecting, deviceName: "MacBook",
                                  failure: "Remote sessions could not start: identity unreadable")
        == "Remote sessions are off")
}

/// What a reconnection cost. `RelayConnection`'s send queue is bounded, so a long outage throws
/// away catalogue updates and keystrokes rather than growing without limit -- and until now it did
/// so silently, which is the one thing a user cannot forgive: the palette was stale and nothing
/// said why.
@Test func comingBackOnlineSaysWhatTheOutageCost() {
    #expect(RemoteStatusText.text(mode: .on, connection: .online, deviceName: "beta",
                                  droppedWhileOffline: 44)
        == "Online as beta · 44 updates were dropped while offline")
}

@Test func aCleanReconnectSaysNothingExtra() {
    #expect(RemoteStatusText.text(mode: .on, connection: .online, deviceName: "beta",
                                  droppedWhileOffline: 0) == "Online as beta")
}

/// One is one. "1 updates were dropped" is the kind of sentence that makes a person distrust
/// everything else on the page.
@Test func oneDroppedUpdateReadsAsOne() {
    #expect(RemoteStatusText.text(mode: .on, connection: .online, deviceName: "beta",
                                  droppedWhileOffline: 1)
        == "Online as beta · 1 update was dropped while offline")
}

/// The count belongs to the moment the socket comes back. Every other state has its own sentence,
/// and appending an outage's cost to "Relay unreachable" would be describing an outage that is
/// still happening in the past tense.
@Test func aCountIsIgnoredWhenThereIsNoConnectionToHaveRecovered() {
    #expect(RemoteStatusText.text(mode: .on, connection: .unreachable(host: "relay"),
                                  deviceName: "beta", droppedWhileOffline: 44)
        == "Relay unreachable (relay)")
    #expect(RemoteStatusText.text(mode: .off, connection: .online, deviceName: "beta",
                                  droppedWhileOffline: 44) == "Remote sessions are off")
}

/// The switch on and the token field empty. This build never opens a socket in that state, so the
/// page used to sit on "Relay unreachable (nyx.agentforge.cc)" -- a sentence that sends a person to
/// check their network over a field they simply had not filled in.
@Test func anEmptyTokenAsksForTheTokenRatherThanBlamingTheRelay() {
    #expect(RemoteStatusText.text(mode: .on, connection: .needsToken, deviceName: "Studio")
        == "Paste the relay token to connect")
}

/// Off still outranks it: a feature that is switched off has nothing to be missing a token for.
@Test func aSwitchedOffFeatureNeverAsksForAToken() {
    #expect(RemoteStatusText.text(mode: .off, connection: .needsToken, deviceName: "Studio")
        == "Remote sessions are off")
}
