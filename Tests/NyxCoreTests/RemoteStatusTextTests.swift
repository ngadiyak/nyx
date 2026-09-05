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
