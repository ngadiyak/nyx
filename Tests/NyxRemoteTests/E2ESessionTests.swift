import CryptoKit
import Foundation
import NyxCore
import Testing
@testable import NyxRemote

private func scratchDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nyx-remote-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func identity() throws -> DeviceIdentity {
    try DeviceIdentity.load(from: scratchDirectory().appendingPathComponent("identity"))
}

/// A ready-made host/client pair with real ephemeral keys, signed and verified the way `RemoteHost`
/// and `RemoteClient` would, so the crypto tests exercise the whole handshake rather than
/// hand-assembled `E2ESession`s that skip the signature step.
private func pair(sessionID: [UInt8]) throws -> (host: E2ESession, client: E2ESession) {
    let hostIdentity = try identity()
    let clientIdentity = try identity()
    let hostEphemeral = E2ESession.ephemeral()
    let clientEphemeral = E2ESession.ephemeral()

    let (hostPub, hostSig) = try E2ESession.signedPublicKey(hostEphemeral, sessionID: sessionID, identity: hostIdentity)
    let (clientPub, clientSig) = try E2ESession.signedPublicKey(clientEphemeral, sessionID: sessionID, identity: clientIdentity)

    #expect(E2ESession.verifyPeer(pubkey: hostPub, sig: hostSig, sessionID: sessionID, deviceID: hostIdentity.deviceID))
    #expect(E2ESession.verifyPeer(pubkey: clientPub, sig: clientSig, sessionID: sessionID, deviceID: clientIdentity.deviceID))

    let host = try E2ESession(mine: hostEphemeral, peer: clientPub, sessionID: sessionID, isHost: true)
    let client = try E2ESession(mine: clientEphemeral, peer: hostPub, sessionID: sessionID, isHost: false)
    return (host, client)
}

@Test func hostAndClientDeriveTheSameKeysFromEachOthersEphemeralKeys() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let (host, client) = try pair(sessionID: sessionID)

    let frame = try host.seal(Array("hello".utf8))
    let opened = try client.open(frame)

    #expect(opened == Array("hello".utf8))
}

@Test func aFrameSealedByTheHostDoesNotOpenOnTheHostItself() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let (host, _) = try pair(sessionID: sessionID)

    let frame = try host.seal(Array("hello".utf8))

    // Specifically a CryptoKitError (authentication failure), not an E2ESession.Errors case --
    // this proves the host's own receive key really differs from its send key, rather than the
    // frame being rejected for some other reason (a bad session id, a replayed counter) that would
    // pass even if the two directions accidentally shared one key.
    #expect(throws: CryptoKitError.self) {
        try host.open(frame)
    }
}

@Test func tamperedCiphertextThrows() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let (host, client) = try pair(sessionID: sessionID)
    let sealed = try host.seal(Array("hello".utf8))
    var tampered = sealed.ciphertext
    tampered[0] ^= 0x01
    let frame = BinaryFrame(sessionID: sealed.sessionID, counter: sealed.counter, ciphertext: tampered)

    #expect(throws: CryptoKitError.self) {
        try client.open(frame)
    }
}

@Test func aFailedOpenLeavesTheReplayWindowUntouched() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let (host, client) = try pair(sessionID: sessionID)
    let sealed = try host.seal(Array("hello".utf8))
    var tampered = sealed.ciphertext
    tampered[0] ^= 0x01
    let badFrame = BinaryFrame(sessionID: sealed.sessionID, counter: sealed.counter, ciphertext: tampered)

    #expect(throws: CryptoKitError.self) {
        try client.open(badFrame)
    }

    // The tampered frame 0 failing to authenticate must not have advanced the replay window --
    // the genuine frame 0 still opens.
    let opened = try client.open(sealed)
    #expect(opened == Array("hello".utf8))
}

@Test func aReplayedFrameThrows() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let (host, client) = try pair(sessionID: sessionID)
    let frame = try host.seal(Array("hello".utf8))
    _ = try client.open(frame)

    #expect(throws: E2ESession.Errors.replayOrReorder(counter: 0)) {
        try client.open(frame)
    }
}

@Test func countersStartAtZeroAndIncrement() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let (host, client) = try pair(sessionID: sessionID)

    let first = try host.seal(Array("a".utf8))
    let second = try host.seal(Array("b".utf8))

    #expect(first.counter == 0)
    #expect(second.counter == 1)
    _ = try client.open(first)
    _ = try client.open(second)
}

@Test func anOutOfOrderFrameIsRejected() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let (host, client) = try pair(sessionID: sessionID)
    let first = try host.seal(Array("a".utf8))
    let second = try host.seal(Array("b".utf8))
    _ = try client.open(second)

    #expect(throws: E2ESession.Errors.replayOrReorder(counter: 0)) {
        try client.open(first)
    }
}

@Test func signedPublicKeyFailsVerificationForTheWrongDeviceID() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let signer = try identity()
    let wrongIdentity = try identity()
    let ephemeral = E2ESession.ephemeral()

    let (pub, sig) = try E2ESession.signedPublicKey(ephemeral, sessionID: sessionID, identity: signer)

    #expect(!E2ESession.verifyPeer(pubkey: pub, sig: sig, sessionID: sessionID, deviceID: wrongIdentity.deviceID))
}

@Test func signedPublicKeyForSessionAFailsVerifyPeerForSessionB() throws {
    let sessionA: [UInt8] = Array(repeating: 7, count: 16)
    let sessionB: [UInt8] = Array(repeating: 8, count: 16)
    let signer = try identity()
    let ephemeral = E2ESession.ephemeral()

    let (pub, sig) = try E2ESession.signedPublicKey(ephemeral, sessionID: sessionA, identity: signer)

    #expect(!E2ESession.verifyPeer(pubkey: pub, sig: sig, sessionID: sessionB, deviceID: signer.deviceID))
}

@Test func verifyPeerRejectsAPublicKeyThatIsNot32Bytes() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let signer = try identity()
    let ephemeral = E2ESession.ephemeral()
    let (_, sig) = try E2ESession.signedPublicKey(ephemeral, sessionID: sessionID, identity: signer)
    let shortPub = RemoteID.base64url(Array(repeating: 1, count: 16)) // half the required length

    #expect(!E2ESession.verifyPeer(pubkey: shortPub, sig: sig, sessionID: sessionID, deviceID: signer.deviceID))
}

@Test func initRejectsASessionIDThatIsNot16Bytes() throws {
    let mine = E2ESession.ephemeral()
    let peerPub = RemoteID.base64url([UInt8](E2ESession.ephemeral().publicKey.rawRepresentation))
    let shortSessionID: [UInt8] = Array(repeating: 7, count: 8)

    #expect(throws: E2ESession.Errors.invalidSessionIDLength(8)) {
        try E2ESession(mine: mine, peer: peerPub, sessionID: shortSessionID, isHost: true)
    }
}

@Test func openRejectsAFrameForADifferentSession() throws {
    let sessionID: [UInt8] = Array(repeating: 7, count: 16)
    let otherSessionID: [UInt8] = Array(repeating: 9, count: 16)
    let (host, client) = try pair(sessionID: sessionID)
    let sealed = try host.seal(Array("hello".utf8))
    let wrongFrame = BinaryFrame(sessionID: otherSessionID, counter: sealed.counter, ciphertext: sealed.ciphertext)

    #expect(throws: E2ESession.Errors.sessionMismatch) {
        try client.open(wrongFrame)
    }
}

@Test func fingerprintDigestIsOrderIndependentAnd32Bytes() throws {
    let a = RemoteID.base64url(Array(repeating: 1, count: 32))
    let b = RemoteID.base64url(Array(repeating: 2, count: 32))

    let ab = try FingerprintHash.digest(myID: a, peerID: b)
    let ba = try FingerprintHash.digest(myID: b, peerID: a)

    #expect(ab == ba)
    #expect(ab.count == 32)
}

@Test func fingerprintDigestThrowsForAnUndecodableID() {
    let good = RemoteID.base64url(Array(repeating: 1, count: 32))

    #expect(throws: FingerprintHash.Errors.malformedDeviceID("not base64url!!")) {
        try FingerprintHash.digest(myID: good, peerID: "not base64url!!")
    }
}
