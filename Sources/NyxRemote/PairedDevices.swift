import Foundation

/// One device this Mac has completed pairing with: enough to show it in the palette and the
/// settings page, and to check an incoming `attach` claims to be from a device we actually trust.
public struct PairedDevice: Codable, Equatable {
    public let id: String
    public var name: String
    public let pairedAt: Date

    public init(id: String, name: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
    }
}

/// The `paired.json` file: every device this Mac trusts. Corruption is treated as data loss, not a
/// crash -- a half-written file from a killed process should not stop Nyx from starting, and the
/// broken copy is kept (renamed, never deleted) so a person who cares can recover the names by hand
/// instead of the file just vanishing.
public struct PairedDevices: Equatable {
    public var devices: [PairedDevice]

    public init(devices: [PairedDevice] = []) {
        self.devices = devices
    }

    public enum SaveError: Error, Equatable {
        case cannotCreateFile(path: String)
        /// The complete temporary file could not be renamed over the real one. Reported rather
        /// than swallowed because the pairing the caller has just made is not on disk: it will
        /// work until Nyx is restarted and then be gone, which is the kind of half-success a user
        /// cannot diagnose.
        case cannotReplaceFile(path: String, errno: Int32)
    }

    private enum CodingKeys: String, CodingKey { case devices }

    /// Collapses entries that share an id to the last one in the list, kept at the position of its
    /// *first* occurrence -- a hand-edited or half-written file should not crash Nyx at launch
    /// (`namesByID` used to build a `Dictionary` with `uniqueKeysWithValues:`, which traps on a
    /// duplicate key), and once collapsed here `devices`, `ids` and `contains` all agree because
    /// they all read the same de-duplicated array.
    private static func deduplicated(_ devices: [PairedDevice]) -> [PairedDevice] {
        var indexByID: [String: Int] = [:]
        var result: [PairedDevice] = []
        for device in devices {
            if let index = indexByID[device.id] {
                result[index] = device
            } else {
                indexByID[device.id] = result.count
                result.append(device)
            }
        }
        return result
    }

    private static func codec() -> (encoder: JSONEncoder, decoder: JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// Empty when the file does not exist yet (first run) or fails to decode (corrupt). In the
    /// corrupt case the unreadable file is renamed to `<name>.broken` beside itself -- moved, not
    /// deleted, in case its bytes still hold something recoverable -- and a fresh, empty set is
    /// returned so the caller need not distinguish "no devices" from "broken file".
    public static func load(from url: URL) -> PairedDevices {
        guard let data = try? Data(contentsOf: url) else { return PairedDevices() }
        if let decoded = try? codec().decoder.decode(PairedDevices.self, from: data) {
            return decoded
        }
        let broken = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".broken")
        try? FileManager.default.removeItem(at: broken)
        try? FileManager.default.moveItem(at: url, to: broken)
        return PairedDevices()
    }

    /// Written exactly the way `DeviceIdentity.load` writes the key beside it: the directory at
    /// 0700, a sibling `paired.json.tmp` created *already* at 0600 (not written-then-chmod'd,
    /// which leaves a window at the process umask's default mode), the bytes flushed to the disk
    /// rather than to the page cache, and only then renamed over the real name.
    ///
    /// The rename is the point. This file is rewritten on every pairing and every Remove, and the
    /// previous shape truncated it first and wrote afterwards -- so a crash or a full disk in
    /// between left a zero-byte file where the list of every device this Mac trusts had been, and
    /// the only cure is pairing each one again by hand on both Macs. `rename(2)` replaces the name
    /// in one step: a reader sees the old contents or the new ones, never nothing.
    public func save(to url: URL) throws {
        let data = try Self.codec().encoder.encode(self)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.appendingPathExtension("tmp")
        // A leftover from a process that died mid-save is stale by definition: this one is about to
        // write the whole list.
        try? fm.removeItem(at: temporary)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SaveError.cannotCreateFile(path: temporary.path)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        // `rename`, not `moveItem`: the destination usually exists, and `FileManager` refuses to
        // move onto an existing file. The mode travels with the temporary file, so the result is
        // 0600 whatever the old file was.
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw SaveError.cannotReplaceFile(path: url.path, errno: code)
        }
    }

    /// Re-pairing an already-known id updates its entry in place rather than adding a duplicate --
    /// a renamed device pairing again should not leave the palette showing it twice.
    public mutating func add(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
    }

    public mutating func remove(id: String) {
        devices.removeAll { $0.id == id }
    }

    public func contains(_ id: String) -> Bool {
        devices.contains { $0.id == id }
    }

    public var ids: [String] { devices.map(\.id) }

    /// `uniquingKeysWith:` rather than `uniqueKeysWithValues:` even though `devices` should already
    /// be duplicate-free after `load`'s de-duplication -- a direct `PairedDevices(devices:)` (tests,
    /// or a future caller) bypasses that step, and a dictionary literal that traps on its input is
    /// the wrong failure mode for a value read at launch.
    public var namesByID: [String: String] {
        Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { _, new in new })
    }
}

extension PairedDevices: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([PairedDevice].self, forKey: .devices)
        self.devices = Self.deduplicated(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(devices, forKey: .devices)
    }
}
