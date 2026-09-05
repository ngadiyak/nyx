import CryptoKit
import Foundation
import NyxCore
import Testing
@testable import NyxRemote

/// A fresh scratch directory per test, removed afterwards -- identity files touch the real
/// filesystem (permissions are the whole point), so these cannot run against an in-memory fake.
private func scratchDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nyx-remote-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func identityIsCreatedOnFirstLoadWithMode0600() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("identity")

    _ = try DeviceIdentity.load(from: url)

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    #expect(mode & 0o777 == 0o600)
}

@Test func theSecondLoadReturnsTheSameKey() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("identity")

    let first = try DeviceIdentity.load(from: url)
    let second = try DeviceIdentity.load(from: url)

    #expect(first.deviceID == second.deviceID)
}

@Test func aFileWithGroupOrOtherBitsIsRefused() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("identity")
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

    #expect(throws: DeviceIdentity.LoadError.self) {
        try DeviceIdentity.load(from: url)
    }
}

@Test func signAndVerifyRoundTrip() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let identity = try DeviceIdentity.load(from: dir.appendingPathComponent("identity"))
    let message: [UInt8] = Array("hello relay".utf8)

    let signature = try identity.sign(message)

    #expect(DeviceIdentity.verify(signature, for: message, by: identity.deviceID))
}

@Test func aFlippedBitFailsVerification() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let identity = try DeviceIdentity.load(from: dir.appendingPathComponent("identity"))
    let message: [UInt8] = Array("hello relay".utf8)
    var signature = try identity.sign(message)
    signature[0] ^= 0x01

    #expect(!DeviceIdentity.verify(signature, for: message, by: identity.deviceID))
}

@Test func remoteFilesLiveBesideTheConfigFileNotInsideIt() {
    let config = URL(fileURLWithPath: "/Users/x/.config/nyx/config")
    let dir = RemoteFiles.directory(besideConfigAt: config)

    #expect(dir.path == "/Users/x/.config/nyx/remote")
    #expect(RemoteFiles.identity(in: dir).path == "/Users/x/.config/nyx/remote/identity")
    #expect(RemoteFiles.pairedDevices(in: dir).path == "/Users/x/.config/nyx/remote/paired.json")
    #expect(RemoteFiles.auditLog(in: dir).path == "/Users/x/.config/nyx/remote/audit.log")
}

@Test func challengeMessageLayout() {
    let nonce: [UInt8] = [1, 2, 3, 4]
    let deviceIDBytes: [UInt8] = Array(repeating: 9, count: 32)
    let deviceID = RemoteID.base64url(deviceIDBytes)

    let message = DeviceIdentity.challengeMessage(nonce: nonce, deviceID: deviceID)

    #expect(message == Array("nyx-relay-v1".utf8) + nonce + deviceIDBytes)
}
