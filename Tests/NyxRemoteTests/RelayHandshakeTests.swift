import Foundation
import NyxCore
import Testing
@testable import NyxRemote

/// A nonce shaped like the relay's: 32 random bytes, base64url without padding.
private func nonce(_ byte: UInt8 = 7) -> (bytes: [UInt8], wire: String) {
    let bytes = [UInt8](repeating: byte, count: 32)
    return (bytes, RemoteID.base64url(bytes))
}

private let testDeviceID = RemoteID.base64url([UInt8](repeating: 3, count: 32))

/// A signer that records what it was asked to sign, so the test can check the exact bytes the
/// relay will verify without needing a real key.
private final class Signer {
    var seen: [[UInt8]] = []
    var answer: [UInt8]? = [UInt8](repeating: 0xAB, count: 64)
    func sign(_ message: [UInt8]) -> [UInt8]? {
        seen.append(message)
        return answer
    }
}

@Test func theChallengeIsAnsweredWithASignatureOverTheProtocolTagNonceAndDeviceID() {
    let signer = Signer()
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: signer.sign)
    let challenge = nonce()

    let outcome = handshake.receive(RemoteMessage(t: "challenge", nonce: challenge.wire))

    #expect(outcome == .send(.auth(signature: RemoteID.base64url([UInt8](repeating: 0xAB, count: 64)))))
    #expect(signer.seen == [DeviceIdentity.challengeMessage(nonce: challenge.bytes, deviceID: testDeviceID)!])
    #expect(handshake.expecting == .welcome)
}

@Test func welcomeAfterTheSignatureIsTheHandshakeDone() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)
    _ = handshake.receive(RemoteMessage(t: "challenge", nonce: nonce().wire))

    let outcome = handshake.receive(RemoteMessage(t: "welcome", serverTime: "2026-09-05T00:00:00Z"))

    #expect(outcome == .online)
    #expect(handshake.expecting == .nothing)
}

@Test func aBadTokenErrorInsteadOfAChallengeIsARejection() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)

    let outcome = handshake.receive(RemoteMessage(t: "error", code: "bad_token", message: "relay token rejected"))

    #expect(outcome == .rejected(code: "bad_token"))
    #expect(handshake.expecting == .nothing)
}

@Test func aBadSignatureErrorInsteadOfAWelcomeIsARejection() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)
    _ = handshake.receive(RemoteMessage(t: "challenge", nonce: nonce().wire))

    let outcome = handshake.receive(RemoteMessage(t: "error", code: "bad_signature"))

    #expect(outcome == .rejected(code: "bad_signature"))
}

@Test func anErrorWithNoCodeStillCarriesAWordRatherThanAnEmptyReason() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)

    let outcome = handshake.receive(RemoteMessage(t: "error"))

    #expect(outcome == .retryableError(code: "error"))
}

@Test func onlyBadTokenAndBadSignatureAreTerminal() {
    #expect(RelayHandshake.terminalErrorCodes == ["bad_token", "bad_signature"])
}

@Test func anErrorCodeThisClientHasNeverHeardOfIsWorthRetrying() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)

    let outcome = handshake.receive(RemoteMessage(t: "error", code: "relay_restarting"))

    #expect(outcome == .retryableError(code: "relay_restarting"))
    #expect(handshake.expecting == .nothing)
}

@Test func aTooManyErrorBeforeWelcomeIsRetryableNotTerminal() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)
    _ = handshake.receive(RemoteMessage(t: "challenge", nonce: nonce().wire))

    #expect(handshake.receive(RemoteMessage(t: "error", code: "too_many")) == .retryableError(code: "too_many"))
}

// MARK: - The handshake deadline, on an injected clock

@Test func aHandshakeIsNotOverdueBeforeItsTimeout() {
    let deadline = HandshakeDeadline(startedAt: 100, timeout: 25)

    #expect(!deadline.hasExpired(at: 100, authenticated: false))
    #expect(!deadline.hasExpired(at: 124.9, authenticated: false))
    #expect(deadline.remaining(at: 110) == 15)
}

@Test func aHandshakeIsOverdueAtItsTimeout() {
    let deadline = HandshakeDeadline(startedAt: 100, timeout: 25)

    #expect(deadline.hasExpired(at: 125, authenticated: false))
    #expect(deadline.hasExpired(at: 1000, authenticated: false))
}

@Test func anAuthenticatedConnectionIsNeverOverdue() {
    let deadline = HandshakeDeadline(startedAt: 100, timeout: 0.2)

    #expect(!deadline.hasExpired(at: 1000, authenticated: true))
}

@Test func theTimeLeftIsNeverNegativeSoATimerCanBeArmedWithItUnchecked() {
    let deadline = HandshakeDeadline(startedAt: 100, timeout: 4)

    #expect(deadline.remaining(at: 500) == 0)
    #expect(deadline.remaining(at: 101) == 3)
}

@Test func aNonceThatIsNotThirtyTwoBytesIsAProtocolError() {
    let signer = Signer()
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: signer.sign)

    let short = handshake.receive(RemoteMessage(t: "challenge", nonce: RemoteID.base64url([1, 2, 3])))

    #expect(short == .protocolError("challenge nonce is not 32 bytes"))
    #expect(signer.seen.isEmpty)
    #expect(handshake.expecting == .nothing)
}

@Test func aMissingNonceIsAProtocolError() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)

    #expect(handshake.receive(RemoteMessage(t: "challenge")) == .protocolError("challenge nonce is not 32 bytes"))
}

@Test func aSignatureThatCannotBeProducedIsAProtocolErrorNotASilentStall() {
    let signer = Signer()
    signer.answer = nil
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: signer.sign)

    let outcome = handshake.receive(RemoteMessage(t: "challenge", nonce: nonce().wire))

    #expect(outcome == .protocolError("the challenge could not be signed"))
}

@Test func aPresenceMessageBeforeTheChallengeIsAProtocolError() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)

    let outcome = handshake.receive(RemoteMessage(t: "presence", devices: []))

    #expect(outcome == .protocolError("expected challenge, got presence"))
}

@Test func aSecondChallengeAfterTheSignatureIsAProtocolError() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)
    _ = handshake.receive(RemoteMessage(t: "challenge", nonce: nonce().wire))

    let outcome = handshake.receive(RemoteMessage(t: "challenge", nonce: nonce(8).wire))

    #expect(outcome == .protocolError("expected welcome, got challenge"))
}

@Test func nothingIsAcceptedOnceTheHandshakeIsFinished() {
    var handshake = RelayHandshake(deviceID: testDeviceID, sign: Signer().sign)
    _ = handshake.receive(RemoteMessage(t: "challenge", nonce: nonce().wire))
    _ = handshake.receive(RemoteMessage(t: "welcome"))

    let outcome = handshake.receive(RemoteMessage(t: "welcome"))

    #expect(outcome == .protocolError("the handshake is already finished"))
}

@Test func theSignatureOnTheWireIsOneTheRelayWouldVerify() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nyx-handshake-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let identity = try DeviceIdentity.load(from: dir.appendingPathComponent("identity"))
    var handshake = RelayHandshake(deviceID: identity.deviceID) { try? identity.sign($0) }
    let challenge = nonce(0x5A)

    let outcome = handshake.receive(RemoteMessage(t: "challenge", nonce: challenge.wire))

    guard case .send(let auth) = outcome else {
        Issue.record("expected an auth message, got \(outcome)")
        return
    }
    let wireSignature = try #require(auth.signature)
    let signature = try #require(RemoteID.bytes(base64url: wireSignature))
    let message = try #require(DeviceIdentity.challengeMessage(nonce: challenge.bytes, deviceID: identity.deviceID))
    #expect(DeviceIdentity.verify(signature, for: message, by: identity.deviceID))
}
