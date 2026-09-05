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

    /// Written in the same create-empty-at-0600-then-fill order as `DeviceIdentity.load`: the
    /// trusted-devices list is less sensitive than a private key, but the same class of bug applies
    /// -- writing plaintext then `chmod`ing, or an atomic write that replaces the file with a fresh
    /// temp file at the process umask's default mode, both leave a window where the file (which
    /// still names every paired device) is readable more broadly than intended.
    public func save(to url: URL) throws {
        let data = try Self.codec().encoder.encode(self)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SaveError.cannotCreateFile(path: url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        try handle.close()
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
