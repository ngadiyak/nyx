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
