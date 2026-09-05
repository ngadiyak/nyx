import Foundation
import Testing
@testable import NyxCore

private let t0 = Date(timeIntervalSince1970: 1_757_000_000)

// MARK: - PairCode

@Test func makeYieldsSixAlphabetCharacters() {
    let code = PairCode.make(random: { _ in 0 })
    #expect(code.count == 6)
    #expect(code.allSatisfy(PairCode.alphabet.contains))
}

@Test func normaliseStripsSpacesDashesAndCase() {
    #expect(PairCode.normalise("k7m-4qz ") == "K7M4QZ")
}

@Test func normaliseRejectsACharacterOutsideTheAlphabet() {
    #expect(PairCode.normalise("K7M4Q0") == nil)
}

@Test func normaliseRejectsTheWrongLength() {
    #expect(PairCode.normalise("K7M4Q") == nil)
}

@Test func displayInsertsTheDash() {
    #expect(PairCode.display("K7M4QZ") == "K7M-4QZ")
}

// MARK: - Fingerprint

@Test func wordsPicksByDigestByte() {
    let digest: [UInt8] = [5, 10, 15, 20]
    #expect(Fingerprint.words(digest: digest) == [
        Fingerprint.words[5], Fingerprint.words[10], Fingerprint.words[15], Fingerprint.words[20],
    ])
}

@Test func wordsListHas256DistinctEntries() {
    #expect(Fingerprint.words.count == 256)
    #expect(Set(Fingerprint.words).count == 256)
}

@Test func textJoinsFourWordsWithDashes() {
    let digest: [UInt8] = [0, 1, 2, 3]
    #expect(Fingerprint.text(digest: digest) == Fingerprint.words[0...3].joined(separator: "-"))
}

@Test func inputIsOrderIndependent() {
    let a: [UInt8] = [1, 2, 3]
    let b: [UInt8] = [9, 9, 9]
    #expect(Fingerprint.input(a: a, b: b) == Fingerprint.input(a: b, b: a))
}

// MARK: - PairingFlow: host happy path

@Test func hostHappyPath() {
    var host = PairingFlow(side: .host)
    #expect(host.state == .idle)

    let openEffects = host.handle(.open(code: "ABCDEF", now: t0), selfID: "host-id")
    #expect(openEffects == [.send(.pairOpen(code: "ABCDEF"))])
    #expect(host.state == .opening("ABCDEF", expires: t0.addingTimeInterval(300)))

    let openedEffects = host.handle(.opened(code: "ABCDEF"), selfID: "host-id")
    #expect(openedEffects == [])
    #expect(host.state == .showingCode("ABCDEF", expires: t0.addingTimeInterval(300)))

    let requestEffects = host.handle(.request(peerID: "peer-id", peerName: "MacBook"), selfID: "host-id")
    #expect(requestEffects == [])
    #expect(host.state == .requested(peerID: "peer-id", peerName: "MacBook"))

    let acceptEffects = host.handle(.accept, selfID: "host-id")
    #expect(acceptEffects == [.send(.pairAccept(to: "peer-id")), .computeFingerprint(peerID: "peer-id")])
    #expect(host.state == .confirming(peerID: "peer-id", peerName: "MacBook", fingerprint: "", mine: false, theirs: false))

    let fpEffects = host.handle(.fingerprint("apple-river-stone-zero"), selfID: "host-id")
    #expect(fpEffects == [])
    #expect(host.state == .confirming(peerID: "peer-id", peerName: "MacBook",
                                      fingerprint: "apple-river-stone-zero", mine: false, theirs: false))

    let confirmMineEffects = host.handle(.confirmMine, selfID: "host-id")
    #expect(confirmMineEffects == [.send(.pairConfirm(to: "peer-id"))])
    #expect(host.state == .confirming(peerID: "peer-id", peerName: "MacBook",
                                      fingerprint: "apple-river-stone-zero", mine: true, theirs: false))

    let confirmTheirsEffects = host.handle(.confirmTheirs, selfID: "host-id")
    #expect(confirmTheirsEffects == [.store(peerID: "peer-id", peerName: "MacBook")])
    #expect(host.state == .paired(peerID: "peer-id", peerName: "MacBook"))
}

// MARK: - PairingFlow: client happy path

@Test func clientHappyPath() {
    var client = PairingFlow(side: .client)

    let joinEffects = client.handle(.join(code: "ABCDEF", now: t0), selfID: "client-id")
    #expect(joinEffects == [.send(.pairJoin(code: "ABCDEF"))])
    #expect(client.state == .joining(code: "ABCDEF"))

    let acceptedEffects = client.handle(.accepted(peerID: "host-id", peerName: "iMac"), selfID: "client-id")
    #expect(acceptedEffects == [.computeFingerprint(peerID: "host-id")])
    #expect(client.state == .confirming(peerID: "host-id", peerName: "iMac", fingerprint: "", mine: false, theirs: false))

    let fpEffects = client.handle(.fingerprint("apple-river-stone-zero"), selfID: "client-id")
    #expect(fpEffects == [])
    #expect(client.state == .confirming(peerID: "host-id", peerName: "iMac",
                                        fingerprint: "apple-river-stone-zero", mine: false, theirs: false))

    // The host's confirmation can arrive before the user presses Confirm on this side.
    let confirmTheirsEffects = client.handle(.confirmTheirs, selfID: "client-id")
    #expect(confirmTheirsEffects == [])
    #expect(client.state == .confirming(peerID: "host-id", peerName: "iMac",
                                        fingerprint: "apple-river-stone-zero", mine: false, theirs: true))

    let confirmMineEffects = client.handle(.confirmMine, selfID: "client-id")
    #expect(confirmMineEffects == [.send(.pairConfirm(to: "host-id")), .store(peerID: "host-id", peerName: "iMac")])
    #expect(client.state == .paired(peerID: "host-id", peerName: "iMac"))
}

// MARK: - Expiry, errors, ignored events

@Test func openingExpiresOnATickPastExpiry() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    let effects = host.handle(.tick(now: t0.addingTimeInterval(301)), selfID: "id")
    #expect(effects == [])
    #expect(host.state == .failed("Code expired"))
}

@Test func showingCodeExpiresOnATickPastExpiry() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    _ = host.handle(.opened(code: "ABCDEF"), selfID: "id")
    _ = host.handle(.tick(now: t0.addingTimeInterval(100)), selfID: "id") // not expired yet
    #expect(host.state == .showingCode("ABCDEF", expires: t0.addingTimeInterval(300)))
    _ = host.handle(.tick(now: t0.addingTimeInterval(300)), selfID: "id") // exactly at expiry
    #expect(host.state == .failed("Code expired"))
}

@Test func pairTakenWhileOpeningFails() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    let effects = host.handle(.error(code: "pair_taken"), selfID: "id")
    #expect(effects == [])
    #expect(host.state == .failed("That code is in use"))
}

@Test func pairExpiredErrorFailsWithCodeExpiredText() {
    var client = PairingFlow(side: .client)
    _ = client.handle(.join(code: "ABCDEF", now: t0), selfID: "id")
    let effects = client.handle(.error(code: "pair_expired"), selfID: "id")
    #expect(effects == [])
    #expect(client.state == .failed("Code expired"))
}

@Test func cancelReturnsToIdleFromAnyState() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    let effects = host.handle(.cancel, selfID: "id")
    #expect(effects == [])
    #expect(host.state == .idle)
}

@Test func eventsOutOfOrderAreIgnored() {
    var host = PairingFlow(side: .host)
    // accept before anyone has requested to pair: nothing to accept.
    let effects = host.handle(.accept, selfID: "id")
    #expect(effects == [])
    #expect(host.state == .idle)
}

@Test func aPeerNamingItselfIsIgnored() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    _ = host.handle(.opened(code: "ABCDEF"), selfID: "id")
    let effects = host.handle(.request(peerID: "id", peerName: "me"), selfID: "id")
    #expect(effects == [])
    #expect(host.state == .showingCode("ABCDEF", expires: t0.addingTimeInterval(300)))
}

// MARK: - sheetText

@Test func sheetTextPerState() {
    #expect(PairingFlow(side: .host).sheetText == ("", "", nil))
    // The client's idle state is a sheet somebody is looking at with a code field in it, so unlike
    // the host's it has to say what to type and where the other Mac shows it.
    #expect(PairingFlow(side: .client).sheetText
        == ("Enter the code shown on the other Mac",
            "Settings → Remote → Pair with another device… shows it", nil))

    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    #expect(host.sheetText == ("Pairing…", "Requesting a code from the relay", nil))
    _ = host.handle(.opened(code: "ABCDEF"), selfID: "id")
    #expect(host.sheetText == ("Pair with another device",
                               "On the other Mac, open Settings → Remote → Pair… and enter\n ABC-DEF", nil))

    _ = host.handle(.request(peerID: "p", peerName: "MacBook"), selfID: "id")
    #expect(host.sheetText == ("MacBook wants to pair", "Accept to continue", "Accept"))

    _ = host.handle(.accept, selfID: "id")
    _ = host.handle(.fingerprint("apple-river-stone-zero"), selfID: "id")
    // The lead-in only: the fingerprint itself is the sheet's bold label, not the body text, so
    // it is not repeated here.
    #expect(host.sheetText == ("Confirm the fingerprint", "Both Macs must show:", "Confirm"))
    _ = host.handle(.confirmMine, selfID: "id")
    #expect(host.sheetText.primary == nil) // already confirmed on this side

    _ = host.handle(.confirmTheirs, selfID: "id")
    #expect(host.sheetText == ("Paired with MacBook", "", "Done"))

    var client = PairingFlow(side: .client)
    _ = client.handle(.join(code: "ABCDEF", now: t0), selfID: "id")
    #expect(client.sheetText == ("Pairing…", "Waiting for the other Mac", nil))

    var failedFlow = PairingFlow(side: .client)
    _ = failedFlow.handle(.join(code: "ABCDEF", now: t0), selfID: "id")
    _ = failedFlow.handle(.error(code: "pair_expired"), selfID: "id")
    #expect(failedFlow.sheetText == ("Pairing failed", "Code expired", "Close"))
}

// MARK: - Resolving the fingerprint before the state is shown

/// The rung-6 run of two instances against the live relay showed an empty fingerprint on both
/// sheets: the caller ran `handle`, then applied the `.computeFingerprint` effect by feeding
/// `.fingerprint` back in, and then showed the state it had captured *before* doing so. The one
/// thing on that sheet a person is asked to compare aloud was blank.
@Test func acceptingLeavesTheFingerprintInTheStateTheSheetIsShownFrom() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "me")
    _ = host.handle(.opened(code: "ABCDEF"), selfID: "me")
    _ = host.handle(.request(peerID: "peer", peerName: "MacBook"), selfID: "me")

    let effects = host.handleResolvingFingerprint(.accept, selfID: "me",
                                                  fingerprint: { $0 == "peer" ? "apple-river-stone-zero" : nil })

    #expect(effects == [.send(.pairAccept(to: "peer"))])
    #expect(host.state == .confirming(peerID: "peer", peerName: "MacBook",
                                      fingerprint: "apple-river-stone-zero", mine: false, theirs: false))
}

@Test func theClientsAcceptedAlsoArrivesWithTheFingerprintAlreadyIn() {
    var client = PairingFlow(side: .client)
    _ = client.handle(.join(code: "ABCDEF", now: t0), selfID: "me")

    let effects = client.handleResolvingFingerprint(.accepted(peerID: "peer", peerName: "iMac"),
                                                    selfID: "me", fingerprint: { _ in "river-stone-zero-apple" })

    #expect(effects.isEmpty)
    #expect(client.state == .confirming(peerID: "peer", peerName: "iMac",
                                        fingerprint: "river-stone-zero-apple", mine: false, theirs: false))
}

/// A fingerprint that cannot be computed -- a peer id that is not 32 base64url bytes -- leaves the
/// sheet in `.confirming` with nothing to compare rather than skipping the confirmation step.
@Test func afingerprintThatCannotBeComputedStillLeavesTheUserAtTheConfirmStep() {
    var client = PairingFlow(side: .client)
    _ = client.handle(.join(code: "ABCDEF", now: t0), selfID: "me")
    _ = client.handleResolvingFingerprint(.accepted(peerID: "peer", peerName: "iMac"),
                                          selfID: "me", fingerprint: { _ in nil })
    #expect(client.state == .confirming(peerID: "peer", peerName: "iMac",
                                        fingerprint: "", mine: false, theirs: false))
}

// MARK: - Nothing waits for ever

/// Every state between the code and the pairing has the same five-minute deadline, counted from
/// the `open` or the `join` that started it. Before this, only the code itself expired: a client
/// that typed a code the other Mac never accepted sat in "Pairing…" until the user pressed Cancel,
/// and the host's own "wants to pair" sheet waited for ever with an Accept button on it.
@Test func joiningTimesOutFiveMinutesAfterTheCodeWasTyped() {
    var client = PairingFlow(side: .client)
    _ = client.handle(.join(code: "ABCDEF", now: t0), selfID: "id")

    let early = client.handle(.tick(now: t0.addingTimeInterval(299)), selfID: "id")
    #expect(early.isEmpty)
    #expect(client.state == .joining(code: "ABCDEF"))

    let late = client.handle(.tick(now: t0.addingTimeInterval(301)), selfID: "id")
    #expect(late.isEmpty)
    #expect(client.state == .failed("Pairing timed out"))
}

@Test func aRequestNobodyAcceptsTimesOut() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    _ = host.handle(.opened(code: "ABCDEF"), selfID: "id")
    _ = host.handle(.request(peerID: "peer", peerName: "MacBook"), selfID: "id")
    #expect(host.state == .requested(peerID: "peer", peerName: "MacBook"))

    _ = host.handle(.tick(now: t0.addingTimeInterval(301)), selfID: "id")
    #expect(host.state == .failed("Pairing timed out"))
}

/// The deadline is counted from `open`, not from reaching this state: two people comparing a
/// fingerprint have the same five minutes the code had, not a fresh five.
@Test func aFingerprintNobodyConfirmsTimesOutFiveMinutesAfterOpen() {
    var host = PairingFlow(side: .host)
    _ = host.handle(.open(code: "ABCDEF", now: t0), selfID: "id")
    _ = host.handle(.opened(code: "ABCDEF"), selfID: "id")
    _ = host.handle(.request(peerID: "peer", peerName: "MacBook"), selfID: "id")
    _ = host.handle(.accept, selfID: "id")
    _ = host.handle(.fingerprint("apple-river-stone-zero"), selfID: "id")

    _ = host.handle(.tick(now: t0.addingTimeInterval(299)), selfID: "id")
    #expect(host.state == .confirming(peerID: "peer", peerName: "MacBook",
                                      fingerprint: "apple-river-stone-zero", mine: false, theirs: false))

    _ = host.handle(.tick(now: t0.addingTimeInterval(300)), selfID: "id")
    #expect(host.state == .failed("Pairing timed out"))
}

/// A pairing that completed is done. The coordinator keeps ticking while the sheet is up (it says
/// "Paired with …" until the user closes it), and a tick that turned that into a failure would
/// undo a pairing that is already stored on both Macs.
@Test func aFinishedPairingIsNotTimedOut() {
    var client = PairingFlow(side: .client)
    _ = client.handle(.join(code: "ABCDEF", now: t0), selfID: "id")
    _ = client.handle(.accepted(peerID: "host-id", peerName: "iMac"), selfID: "id")
    _ = client.handle(.confirmTheirs, selfID: "id")
    _ = client.handle(.confirmMine, selfID: "id")
    #expect(client.state == .paired(peerID: "host-id", peerName: "iMac"))

    _ = client.handle(.tick(now: t0.addingTimeInterval(3600)), selfID: "id")
    #expect(client.state == .paired(peerID: "host-id", peerName: "iMac"))
}
