import CryptoKit
import Foundation
import NyxCore

/// A device's long-lived Ed25519 keypair: what the relay authenticates by challenge signature, and
/// what a peer's `attach` signature is checked against. Loaded once at launch and held for the
/// process lifetime -- there is no rotation in v1 (spec §7.3).
public struct DeviceIdentity {
    public let signing: Curve25519.Signing.PrivateKey

    /// base64url of the 32-byte raw public key -- the id every other message on the wire refers to
    /// this device by.
    public var deviceID: String { RemoteID.base64url([UInt8](signing.publicKey.rawRepresentation)) }

    public init(signing: Curve25519.Signing.PrivateKey) {
        self.signing = signing
    }

    /// What stops `load` from trusting a key file a careless `chmod -R` or a shared-account default
    /// umask left readable by anyone else on the machine -- an Ed25519 private key is 32 bytes, easy
    /// to miss in a `ls -l` skim, so this fails loudly with the exact path and mode rather than
    /// silently signing with a key another local user can read.
    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case insecurePermissions(path: String, mode: UInt16)
        case unreadable(path: String)

        public var description: String {
            switch self {
            case .insecurePermissions(let path, let mode):
                return "refusing identity file \(path): mode is 0\(String(mode, radix: 8)), must be 0600"
            case .unreadable(let path):
                return "identity file \(path) could not be read"
            }
        }
    }

    /// Loads the identity at `url`, creating it (mode 0600) the first time this device runs. A file
    /// that already exists but is group- or other-readable is refused rather than used, because by
    /// the time this can be checked the key may already have been readable by another local
    /// account for as long as the file existed.
    public static func load(from url: URL) throws -> DeviceIdentity {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let posix = attrs[.posixPermissions] as? NSNumber else {
                throw LoadError.unreadable(path: url.path)
            }
            let mode = posix.uint16Value & 0o777
            guard mode & 0o077 == 0 else {
                throw LoadError.insecurePermissions(path: url.path, mode: mode)
            }
            guard let data = try? Data(contentsOf: url) else {
                throw LoadError.unreadable(path: url.path)
            }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            return DeviceIdentity(signing: key)
        }

        let key = Curve25519.Signing.PrivateKey()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return DeviceIdentity(signing: key)
    }

    public func sign(_ message: [UInt8]) throws -> [UInt8] {
        [UInt8](try signing.signature(for: Data(message)))
    }

    public static func verify(_ signature: [UInt8], for message: [UInt8], by deviceID: String) -> Bool {
        guard let keyBytes = RemoteID.bytes(base64url: deviceID), keyBytes.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(keyBytes)) else {
            return false
        }
        return publicKey.isValidSignature(Data(signature), for: Data(message))
    }

    /// What a device signs to answer the relay's connect challenge: the protocol tag pins the
    /// signature to this exact use (so it can never be replayed as, say, an e2e attach signature),
    /// the nonce stops a captured signature being replayed on a later connection, and the device id
    /// bytes stop the relay -- or a man in the middle -- from replaying one device's signature as
    /// proof of a different device's identity.
    public static func challengeMessage(nonce: [UInt8], deviceID: String) -> [UInt8] {
        Array("nyx-relay-v1".utf8) + nonce + (RemoteID.bytes(base64url: deviceID) ?? [])
    }
}
