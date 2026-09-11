import Testing
@testable import NyxCore

/// Spec §5.3, pulled forward: the owner's Pair button was disabled and the reason was ~300 px away
/// with a table between, so they did not see it. The sentence is decided here and drawn beneath the
/// buttons it explains.
@Test func theFourRemotePageSentencesAreExact() {
    #expect(RemotePageStatus.text(mode: .off, relay: "wss://r/v1/ws", token: "t")
        == ("Remote sessions are off — tick Enable remote sessions to pair.", true))
    #expect(RemotePageStatus.text(mode: .on, relay: "", token: "t")
        == ("Pairing needs a relay — set Relay above.", true))
    #expect(RemotePageStatus.text(mode: .on, relay: "wss://r/v1/ws", token: "  ")
        == ("Pairing needs a relay token — set Relay token above.", true))
    #expect(RemotePageStatus.text(mode: .on, relay: "wss://r/v1/ws", token: "t")
        == ("Ready to pair. Both Macs must reach the same relay.", false))
}

/// Being off outranks having no token: a feature that is switched off has nothing to fail at.
@Test func theSwitchOutranksTheFieldsBelowIt() {
    #expect(RemotePageStatus.text(mode: .off, relay: "", token: "").blocksPairing)
    #expect(RemotePageStatus.text(mode: .off, relay: "", token: "").sentence
        == "Remote sessions are off — tick Enable remote sessions to pair.")
}

/// §7.4: the page had one explanatory sentence, at the very bottom, under the activity log, about
/// the relay's metadata -- a long way from the token field it is about, and nothing at all about
/// what a remote session *is* or where a relay comes from. Both sentences live here so the picture
/// and the page cannot drift.
@Test func thePageExplainsItselfInTwoSentencesFromCore() {
    #expect(RemotePageCopy.what == "A remote session is a Nyx tab on another of your Macs, reached "
        + "through a relay both machines dial out to. Nyx never sends terminal text the relay can read.")
    #expect(RemotePageCopy.relay == "The relay URL and token come from the nyx-server you run; "
        + "Nyx cannot issue them.")
}

/// And what the one number on the page costs, because nothing said: 2,000 lines measured ~85 KB,
/// sealed and sent on every attach.
@Test func theSnapshotCostIsSaidInTheUnitTheUserSetIt() {
    #expect(RemotePageCopy.snapshotCost(lines: 2000)
        == "How much scrollback a Mac attaching to this one receives: about 85 KB at 2000 lines, "
        + "sent once per attach.")
    #expect(RemotePageCopy.snapshotCost(lines: 100).contains("about 4 KB at 100 lines"))
}
