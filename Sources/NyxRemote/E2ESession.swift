import CryptoKit
import Foundation
import NyxCore

/// The SHA-256 half of a pairing fingerprint: `NyxCore.Fingerprint` picks the words, but hashing
/// needs CryptoKit, which `NyxCore` may not import, so this is the only place the digest bytes are
/// produced.
public enum FingerprintHash {
    /// Thrown instead of hashing an empty stand-in for an id that would not decode -- a fingerprint
    /// computed from a silently-substituted empty id can still produce four ordinary-looking words,
    /// which is exactly the failure mode a fingerprint exists to catch: a person reading them aloud
    /// with no reason to suspect the comparison never included one side's real key.
    public enum Errors: Error, Equatable {
        case malformedDeviceID(String)
    }

    /// 32 bytes, the same from either side of a pairing regardless of which id is "mine" --
    /// `Fingerprint.input` orders the two ids before hashing, so both devices land on one digest.
    public static func digest(myID: String, peerID: String) throws -> [UInt8] {
        guard let a = RemoteID.bytes(base64url: myID) else { throw Errors.malformedDeviceID(myID) }
        guard let b = RemoteID.bytes(base64url: peerID) else { throw Errors.malformedDeviceID(peerID) }
        return [UInt8](SHA256.hash(data: Data(Fingerprint.input(a: a, b: b))))
    }
}

/// One attachment's end-to-end cipher: an ephemeral X25519 key agreement (forward secrecy per
/// attach, spec §7.3), signed by the long-lived device identity so the relay cannot substitute its
/// own ephemeral key, then ChaCha20-Poly1305 with a per-direction counter so a replayed or
/// reordered frame is rejected rather than decrypted. A class, not a struct: `seal`/`open` mutate
/// the running counters and the type is handed around by reference to the one host or client loop
/// that owns a given attachment.
public final class E2ESession {
    public enum Errors: Error, Equatable {
        /// `open` saw a counter at or below the last one it accepted -- a replay, a duplicate, or
        /// frames delivered out of order.
        case replayOrReorder(counter: UInt64)
        case malformedPeerKey
        case frameTooShort
        /// `sessionID` at construction was not 16 bytes -- every session id on the wire is 16
        /// random bytes (`RemoteID.isSessionID`); anything else cannot be a real one.
        case invalidSessionIDLength(Int)
        /// `open` saw a frame stamped with a different session id than this instance was built
        /// for -- one `E2ESession` exists per attachment, so a frame for another session here means
        /// either frames were routed to the wrong instance, or the relay (or an attacker) is trying
        /// to feed one attachment's ciphertext into another's counter window.
        case sessionMismatch
    }

    private static let tagLength = 16

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sessionID: [UInt8]
    private var sendCounter: UInt64 = 0
    private var lastAcceptedCounter: UInt64?

    public static func ephemeral() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// What one side sends in `attach`/`attached`: its ephemeral public key, and a signature over
    /// that key bound to this session id -- so the peer can be sure the key came from the device it
    /// paired with, not from whoever the relay happens to route the message through.
    public static func signedPublicKey(
        _ ephemeral: Curve25519.KeyAgreement.PrivateKey,
        sessionID: [UInt8],
        identity: DeviceIdentity
    ) throws -> (pubkey: String, sig: String) {
        let pubBytes = [UInt8](ephemeral.publicKey.rawRepresentation)
        let message = Array("nyx-e2e-v1".utf8) + sessionID + pubBytes
        let signature = try identity.sign(message)
        return (RemoteID.base64url(pubBytes), RemoteID.base64url(signature))
    }

    public static func verifyPeer(pubkey: String, sig: String, sessionID: [UInt8], deviceID: String) -> Bool {
        guard let pubBytes = RemoteID.bytes(base64url: pubkey), pubBytes.count == 32,
              let sigBytes = RemoteID.bytes(base64url: sig) else {
            return false
        }
        let message = Array("nyx-e2e-v1".utf8) + sessionID + pubBytes
        return DeviceIdentity.verify(sigBytes, for: message, by: deviceID)
    }

    /// Derives this attachment's two direction keys from the shared X25519 secret. `isHost` picks
    /// which of the HKDF output's two halves is "my" send key versus "my" receive key -- the host
    /// sends with the host->client half and the client sends with the client->host half, so a frame
    /// this side sealed can never be the one it also accepts back (caught by `open` failing
    /// authentication, not by trusting the caller never to try).
    public init(mine: Curve25519.KeyAgreement.PrivateKey, peer pubkey: String, sessionID: [UInt8], isHost: Bool) throws {
        guard sessionID.count == 16 else { throw Errors.invalidSessionIDLength(sessionID.count) }
        guard let peerBytes = RemoteID.bytes(base64url: pubkey), peerBytes.count == 32 else {
            throw Errors.malformedPeerKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(peerBytes))
        let shared = try mine.sharedSecretFromKeyAgreement(with: peerKey)
        let info = Data(Array("nyx-e2e-v1".utf8) + sessionID)
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 64)
        let keyBytes = material.withUnsafeBytes { [UInt8]($0) }
        let hostToClient = SymmetricKey(data: keyBytes[0..<32])
        let clientToHost = SymmetricKey(data: keyBytes[32..<64])
        sendKey = isHost ? hostToClient : clientToHost
        receiveKey = isHost ? clientToHost : hostToClient
        self.sessionID = sessionID
    }

    /// 4 zero bytes ‖ the 8-byte big-endian counter -- a fixed-width nonce built from a counter that
    /// never repeats within one direction's key, which is all ChaChaPoly needs to be safe without
    /// needing a random nonce per frame.
    private func nonce(for counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((counter >> UInt64(shift)) & 0xff))
        }
        return try! ChaChaPoly.Nonce(data: bytes) // 12 bytes by construction; cannot fail
    }

    private func additionalData(counter: UInt64) -> Data {
        var out = Data(sessionID)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((counter >> UInt64(shift)) & 0xff))
        }
        return out
    }

    /// Seals one frame and advances the send counter. Counters start at 0 and never repeat for the
    /// life of this instance, so the receiver can always tell a fresh frame from a replay.
    public func seal(_ plaintext: [UInt8]) throws -> BinaryFrame {
        let counter = sendCounter
        sendCounter += 1
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce(for: counter), authenticating: additionalData(counter: counter))
        let ciphertext = [UInt8](box.ciphertext) + [UInt8](box.tag)
        return BinaryFrame(sessionID: sessionID, counter: counter, ciphertext: ciphertext)
    }

    /// Rejects a counter at or below the last one accepted before touching the ciphertext at all --
    /// a replay should not even reach the (comparatively expensive, and side-channel-sensitive)
    /// authenticated decryption.
    public func open(_ frame: BinaryFrame) throws -> [UInt8] {
        guard frame.sessionID == sessionID else { throw Errors.sessionMismatch }
        if let last = lastAcceptedCounter, frame.counter <= last {
            throw Errors.replayOrReorder(counter: frame.counter)
        }
        guard frame.ciphertext.count >= Self.tagLength else { throw Errors.frameTooShort }
        let tag = frame.ciphertext.suffix(Self.tagLength)
        let ciphertext = frame.ciphertext.dropLast(Self.tagLength)
        let box = try ChaChaPoly.SealedBox(nonce: nonce(for: frame.counter), ciphertext: ciphertext, tag: tag)
        let plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: additionalData(counter: frame.counter))
        lastAcceptedCounter = frame.counter
        return [UInt8](plaintext)
    }
}
