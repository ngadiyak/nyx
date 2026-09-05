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
public struct PairedDevices: Codable, Equatable {
    public var devices: [PairedDevice]

    public init(devices: [PairedDevice] = []) {
        self.devices = devices
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

    public func save(to url: URL) throws {
        let data = try Self.codec().encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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

    public var namesByID: [String: String] {
        Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
    }
}
