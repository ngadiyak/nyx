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
                return "refusing identity file \(path): mode is 0\(String(mode, radix: 8)), " +
                    "must not be readable by group or other"
            case .unreadable(let path):
                return "identity file \(path) could not be read"
            }
        }
    }

    /// Loads the identity at `url`, creating it (directory 0700, file 0600) the first time this
    /// device runs. A file that already exists but is group- or other-readable is refused rather
    /// than used, because by the time this can be checked the key may already have been readable by
    /// another local account for as long as the file existed. A file that exists, is 0600, but does
    /// not decode as a private key (truncated, corrupted) is likewise refused rather than silently
    /// replaced -- regenerating a new identity here would change this device's id out from under
    /// every peer it has already paired with, without them ever being told why attach signatures
    /// stopped verifying.
    public static func load(from url: URL) throws -> DeviceIdentity {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        // A directory that already exists is tightened rather than trusted: `createDirectory` below
        // only applies its attributes when it actually creates the directory, so a `remote/` left at
        // 0755 by an earlier version, a restore from a backup, or a careless `chmod -R` would
        // otherwise keep letting other local accounts list -- and stat the mode of -- files whose
        // whole protection is that nobody else can open them.
        if let attrs = try? fm.attributesOfItem(atPath: dir.path),
           let posix = attrs[.posixPermissions] as? NSNumber, posix.uint16Value & 0o077 != 0 {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        if fm.fileExists(atPath: url.path) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let posix = attrs[.posixPermissions] as? NSNumber else {
                throw LoadError.unreadable(path: url.path)
            }
            let mode = posix.uint16Value & 0o777
            guard mode & 0o077 == 0 else {
                throw LoadError.insecurePermissions(path: url.path, mode: mode)
            }
            guard let data = try? Data(contentsOf: url),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
                throw LoadError.unreadable(path: url.path)
            }
            return DeviceIdentity(signing: key)
        }

        // Created so that the private key bytes never exist on disk at a mode looser than 0600 and
        // `identity` itself is never a partially written file: the directory is 0700 before
        // anything is written into it, the key goes to a sibling `identity.tmp` created empty
        // already at 0600 (not written-then-chmod'd, which would leave a window at the process
        // umask's default mode), and only a complete temporary file is renamed over the final name.
        // Without the rename, a crash or a full disk between `createFile` and `write` would leave a
        // 0-byte `identity` that the branch above then refuses forever as unreadable -- and the
        // only cure for that would be deleting the file, which changes this device's id out from
        // under every peer it has paired with.
        let key = Curve25519.Signing.PrivateKey()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.appendingPathExtension("tmp")
        try? fm.removeItem(at: temporary)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LoadError.unreadable(path: temporary.path)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: key.rawRepresentation)
        try handle.close()
        try fm.moveItem(at: temporary, to: url)
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
    /// proof of a different device's identity. Returns `nil` for a `deviceID` that does not decode
    /// rather than silently signing over an empty id -- a caller that ignores the failure gets no
    /// message at all instead of one whose id half is quietly wrong.
    public static func challengeMessage(nonce: [UInt8], deviceID: String) -> [UInt8]? {
        guard let idBytes = RemoteID.bytes(base64url: deviceID) else { return nil }
        return Array("nyx-relay-v1".utf8) + nonce + idBytes
    }
}
