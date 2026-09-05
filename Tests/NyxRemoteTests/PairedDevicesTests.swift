import Foundation
import Testing
@testable import NyxRemote

private func scratchDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nyx-remote-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func saveAndLoadRoundTrip() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("paired.json")
    var devices = PairedDevices()
    devices.add(PairedDevice(id: "device-a", name: "Mac mini", pairedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    devices.add(PairedDevice(id: "device-b", name: "MacBook", pairedAt: Date(timeIntervalSince1970: 1_700_000_100)))

    try devices.save(to: url)
    let loaded = PairedDevices.load(from: url)

    #expect(loaded == devices)
}

@Test func loadingAMissingFileIsEmpty() {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("paired.json")

    #expect(PairedDevices.load(from: url) == PairedDevices())
}

@Test func corruptFileLoadsEmptyAndIsRenamedBroken() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("paired.json")
    try Data("not json at all".utf8).write(to: url)

    let loaded = PairedDevices.load(from: url)

    #expect(loaded == PairedDevices())
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(FileManager.default.fileExists(atPath: url.path + ".broken"))
}

@Test func addReplacesAnExistingEntryWithTheSameID() {
    var devices = PairedDevices()
    devices.add(PairedDevice(id: "d1", name: "old name", pairedAt: Date()))
    devices.add(PairedDevice(id: "d1", name: "new name", pairedAt: Date()))

    #expect(devices.devices.count == 1)
    #expect(devices.namesByID["d1"] == "new name")
}

@Test func duplicateIDsInTheFileCollapseToOneDeviceLastWins() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("paired.json")
    let json = """
    {"devices":[
        {"id":"d1","name":"old name","pairedAt":"2026-01-01T00:00:00Z"},
        {"id":"d1","name":"new name","pairedAt":"2026-01-02T00:00:00Z"}
    ]}
    """
    try Data(json.utf8).write(to: url)

    let loaded = PairedDevices.load(from: url)

    #expect(loaded.devices.count == 1)
    #expect(loaded.namesByID["d1"] == "new name")
    #expect(loaded.ids == ["d1"])
    #expect(loaded.contains("d1"))
}

@Test func saveWritesTheFileAndDirectoryAtSecureModes() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let remoteDir = dir.appendingPathComponent("remote")
    let url = remoteDir.appendingPathComponent("paired.json")
    var devices = PairedDevices()
    devices.add(PairedDevice(id: "d1", name: "a", pairedAt: Date()))

    try devices.save(to: url)

    let fileAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(((fileAttrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777 == 0o600)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: remoteDir.path)
    #expect(((dirAttrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777 == 0o700)
}

@Test func removeDropsTheDevice() {
    var devices = PairedDevices()
    devices.add(PairedDevice(id: "d1", name: "a", pairedAt: Date()))
    devices.remove(id: "d1")

    #expect(!devices.contains("d1"))
    #expect(devices.ids.isEmpty)
}

/// The second save is the one that matters. `paired.json` is rewritten on every pairing and every
/// Remove, and the old shape -- create the file empty, then write into it -- meant that a crash or
/// a full disk between those two steps left a zero-byte file where the list of every device this
/// Mac trusts used to be. The list is rebuilt only by pairing each device again, by hand, on both
/// Macs. Written to a sibling `.tmp` at 0600 and renamed over the top, so the name either has the
/// old contents or the new ones and never nothing.
@Test func savingOverAnExistingFileNeverLeavesItEmptyOrLoose() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("remote").appendingPathComponent("paired.json")

    var devices = PairedDevices()
    devices.add(PairedDevice(id: "d1", name: "a", pairedAt: Date(timeIntervalSince1970: 1)))
    try devices.save(to: url)
    devices.add(PairedDevice(id: "d2", name: "b", pairedAt: Date(timeIntervalSince1970: 2)))
    try devices.save(to: url)

    #expect(PairedDevices.load(from: url) == devices)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(((attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777 == 0o600)
    // Nothing left beside it: a `paired.json.tmp` lying around at 0600 is a second copy of the
    // same list for anything that later goes looking.
    let left = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(left == ["paired.json"])
}

/// And a save that cannot be completed leaves the previous list alone. That is the whole reason
/// for the temporary file: the old shape truncated `paired.json` first and wrote afterwards, so
/// anything that went wrong in between (a full disk, a crash) took the list of every device this
/// Mac trusts with it -- recoverable only by pairing each one again, by hand, on both Macs.
@Test func aSaveThatCannotBeWrittenLeavesTheOldListIntact() throws {
    let dir = scratchDirectory()
    let fm = FileManager.default
    defer {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? fm.removeItem(at: dir)
    }
    let url = dir.appendingPathComponent("paired.json")
    var devices = PairedDevices()
    devices.add(PairedDevice(id: "d1", name: "a", pairedAt: Date(timeIntervalSince1970: 1)))
    try devices.save(to: url)

    // No new names may be created here; the existing file is still writable, which is exactly the
    // difference between truncating it and writing beside it.
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    var more = devices
    more.add(PairedDevice(id: "d2", name: "b", pairedAt: Date(timeIntervalSince1970: 2)))
    #expect(throws: (any Error).self) { try more.save(to: url) }

    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(PairedDevices.load(from: url) == devices)
}

/// A `paired.json.tmp` left behind by a process that died mid-save must not stop the next save --
/// and must not survive it either, since it is a second copy of the list of trusted devices for
/// anything that later goes looking.
@Test func aStaleTemporaryFileIsReplacedRatherThanTrippedOver() throws {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("paired.json")
    try Data("half a file".utf8).write(to: url.appendingPathExtension("tmp"))

    var devices = PairedDevices()
    devices.add(PairedDevice(id: "d1", name: "a", pairedAt: Date(timeIntervalSince1970: 1)))
    try devices.save(to: url)

    #expect(PairedDevices.load(from: url) == devices)
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
}
