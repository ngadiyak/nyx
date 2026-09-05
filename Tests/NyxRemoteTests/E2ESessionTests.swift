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

    #expect(throws: (any Error).self) {
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

    #expect(throws: (any Error).self) {
        try client.open(frame)
    }
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

@Test func fingerprintDigestIsOrderIndependentAnd32Bytes() {
    let a = RemoteID.base64url(Array(repeating: 1, count: 32))
    let b = RemoteID.base64url(Array(repeating: 2, count: 32))

    let ab = FingerprintHash.digest(myID: a, peerID: b)
    let ba = FingerprintHash.digest(myID: b, peerID: a)

    #expect(ab == ba)
    #expect(ab.count == 32)
}
