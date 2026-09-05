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
