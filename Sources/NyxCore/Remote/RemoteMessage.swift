import Foundation

/// One terminal a host offers over the relay. Wire name is `Session` (see the server's protocol
/// table); string fields may be empty rather than absent, because the relay stores and forwards
/// this verbatim and an empty `branch` (no repo) must still round-trip as a session, not as a
/// decode failure.
public struct RemoteSessionInfo: Codable, Equatable {
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var repo: String
    public var branch: String
    public var process: String
    public var lastCommand: String
    public var lastActivity: String
    public var cols: Int
    public var rows: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title, cwd, repo, branch, process
        case lastCommand = "last_command"
        case lastActivity = "last_activity"
        case cols, rows
    }

    public init(sessionID: String, title: String, cwd: String, repo: String, branch: String,
                process: String, lastCommand: String, lastActivity: String, cols: Int, rows: Int) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.repo = repo
        self.branch = branch
        self.process = process
        self.lastCommand = lastCommand
        self.lastActivity = lastActivity
        self.cols = cols
        self.rows = rows
    }
}

/// One entry of a `presence` message: a paired device and whether it is online right now.
public struct RemotePresence: Codable, Equatable {
    public var deviceID: String
    public var name: String
    public var online: Bool

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name, online
    }

    public init(deviceID: String, name: String, online: Bool) {
        self.deviceID = deviceID
        self.name = name
        self.online = online
    }
}

/// Every message on the wire between a Nyx device and the relay, and between two Nyx devices via
/// the relay. One type rather than one per `t` keeps decoding a single step; the server's wire
/// table (`docs/superpowers/plans/2026-09-05-remote-sessions-server.md`) is the contract this
/// mirrors field-for-field -- the JSON names here are not free to drift from it, because the Go
/// relay and this client must agree on the bytes, not just on the meaning.
public struct RemoteMessage: Codable, Equatable {
    public var v: Int = 1
    public var t: String
    public var from: String?
    public var to: String?
    public var deviceID: String?
    public var deviceName: String?
    public var token: String?
    public var nonce: String?
    public var signature: String?
    public var code: String?
    public var name: String?
    public var deviceIDs: [String]?
    public var devices: [RemotePresence]?
    public var sessions: [RemoteSessionInfo]?
    public var sessionID: String?
    public var ephemeralPubkey: String?
    public var sig: String?
    public var role: String?
    public var serverTime: String?
    public var message: String?
    public var cols: Int?
    public var rows: Int?

    private enum CodingKeys: String, CodingKey {
        case v, t, from, to
        case deviceID = "device_id"
        case deviceName = "device_name"
        case token, nonce, signature, code, name
        case deviceIDs = "device_ids"
        case devices, sessions
        case sessionID = "session_id"
        case ephemeralPubkey = "ephemeral_pubkey"
        case sig, role
        case serverTime = "server_time"
        case message, cols, rows
    }

    public init(t: String, from: String? = nil, to: String? = nil, deviceID: String? = nil,
                deviceName: String? = nil, token: String? = nil, nonce: String? = nil,
                signature: String? = nil, code: String? = nil, name: String? = nil,
                deviceIDs: [String]? = nil, devices: [RemotePresence]? = nil,
                sessions: [RemoteSessionInfo]? = nil, sessionID: String? = nil,
                ephemeralPubkey: String? = nil, sig: String? = nil, role: String? = nil,
                serverTime: String? = nil, message: String? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.t = t
        self.from = from
        self.to = to
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.token = token
        self.nonce = nonce
        self.signature = signature
        self.code = code
        self.name = name
        self.deviceIDs = deviceIDs
        self.devices = devices
        self.sessions = sessions
        self.sessionID = sessionID
        self.ephemeralPubkey = ephemeralPubkey
        self.sig = sig
        self.role = role
        self.serverTime = serverTime
        self.message = message
        self.cols = cols
        self.rows = rows
    }

    /// What decoding a wire frame can go wrong in a way the caller should distinguish from a plain
    /// JSON syntax error: the relay speaks a version we don't, or sent a frame without a type.
    public enum DecodeError: Error, Equatable {
        case unsupportedVersion(Int)
        case missingType
    }

    /// Parses one wire frame. Rejects anything not this protocol version and anything without a
    /// message type before the caller ever switches on `t` -- matching the relay's own `Decode`,
    /// which is the reference this must not drift from.
    public static func decode(_ data: Data) throws -> RemoteMessage {
        let msg = try JSONDecoder().decode(RemoteMessage.self, from: data)
        guard msg.v == 1 else { throw DecodeError.unsupportedVersion(msg.v) }
        guard !msg.t.isEmpty else { throw DecodeError.missingType }
        return msg
    }

    /// `.sortedKeys` makes the output deterministic (useful for tests and logs); `.withoutEscapingSlashes`
    /// keeps paths in `cwd` readable on the wire. Optional fields left `nil` are omitted by the
    /// synthesized encoder, mirroring the Go side's `omitempty`.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func hello(deviceID: String, deviceName: String, token: String) -> RemoteMessage {
        RemoteMessage(t: "hello", deviceID: deviceID, deviceName: deviceName, token: token)
    }

    public static func auth(signature: String) -> RemoteMessage {
        RemoteMessage(t: "auth", signature: signature)
    }

    public static func paired(_ deviceIDs: [String]) -> RemoteMessage {
        RemoteMessage(t: "paired", deviceIDs: deviceIDs)
    }

    public static func sessions(_ sessions: [RemoteSessionInfo]) -> RemoteMessage {
        RemoteMessage(t: "sessions", sessions: sessions)
    }

    public static func pairOpen(code: String) -> RemoteMessage {
        RemoteMessage(t: "pair_open", code: code)
    }

    /// The relay's acknowledgement of `pair_open`. Nyx never sends this; it exists here only so
    /// `PairingFlowTests` can construct the event without a live relay.
    public static func pairOpened(code: String) -> RemoteMessage {
        RemoteMessage(t: "pair_opened", code: code)
    }

    public static func pairJoin(code: String) -> RemoteMessage {
        RemoteMessage(t: "pair_join", code: code)
    }

    public static func pairAccept(to: String) -> RemoteMessage {
        RemoteMessage(t: "pair_accept", to: to)
    }

    public static func pairConfirm(to: String) -> RemoteMessage {
        RemoteMessage(t: "pair_confirm", to: to)
    }

    public static func attach(to: String, sessionID: String, ephemeralPubkey: String, sig: String) -> RemoteMessage {
        RemoteMessage(t: "attach", to: to, sessionID: sessionID, ephemeralPubkey: ephemeralPubkey, sig: sig)
    }

    public static func attached(to: String, sessionID: String, ephemeralPubkey: String, sig: String,
                                 role: String, cols: Int, rows: Int) -> RemoteMessage {
        RemoteMessage(t: "attached", to: to, sessionID: sessionID, ephemeralPubkey: ephemeralPubkey,
                      sig: sig, role: role, cols: cols, rows: rows)
    }

    public static func snapshotEnd(to: String, sessionID: String) -> RemoteMessage {
        RemoteMessage(t: "snapshot_end", to: to, sessionID: sessionID)
    }

    public static func takeControl(to: String, sessionID: String) -> RemoteMessage {
        RemoteMessage(t: "take_control", to: to, sessionID: sessionID)
    }

    public static func role(to: String, sessionID: String, deviceID: String, role: String) -> RemoteMessage {
        RemoteMessage(t: "role", to: to, deviceID: deviceID, sessionID: sessionID, role: role)
    }

    public static func detach(to: String, sessionID: String) -> RemoteMessage {
        RemoteMessage(t: "detach", to: to, sessionID: sessionID)
    }

    public static func sessionEnded(to: String, sessionID: String) -> RemoteMessage {
        RemoteMessage(t: "session_ended", to: to, sessionID: sessionID)
    }
}

/// Validation and encoding for the two kinds of id on the wire, and the base64url alphabet both
/// use. A device id is an Ed25519 public key (32 bytes); a session id is 16 random bytes -- the
/// byte counts, not the string length, are what `Envelope.Validate` on the relay actually checks,
/// so this checks the same thing rather than a length range that could accept a malformed id.
public enum RemoteID {
    public static func isDeviceID(_ s: String) -> Bool { bytes(base64url: s)?.count == 32 }
    public static func isSessionID(_ s: String) -> Bool { bytes(base64url: s)?.count == 16 }

    /// Standard base64, `+`/`/` swapped for `-`/`_`, padding stripped -- URL- and JSON-string-safe,
    /// and what the relay expects (its `base64.RawURLEncoding`).
    public static func base64url(_ bytes: [UInt8]) -> String {
        var s = Data(bytes).base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// The inverse of `base64url`: swap the alphabet back, then re-pad to a multiple of four
    /// characters, since `Data(base64Encoded:)` requires the padding this wire format strips.
    public static func bytes(base64url s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let data = Data(base64Encoded: t) else { return nil }
        return [UInt8](data)
    }
}

/// A decrypted-frame-shaped binary WebSocket message: which session it belongs to, its position in
/// that session's stream (so a reordered or replayed frame can be detected), and the ciphertext
/// itself. Kept as raw bytes rather than `Data` slices because a `Data` produced by
/// `dropFirst`/`subdata` here would otherwise carry the original buffer's index base into code that
/// assumes zero-based indices.
public struct BinaryFrame: Equatable {
    static let headerLength = 24 // 16-byte session id + 8-byte big-endian counter

    public let sessionID: [UInt8]
    public let counter: UInt64
    public let ciphertext: [UInt8]

    public init?(_ data: [UInt8]) {
        guard data.count >= Self.headerLength else { return nil }
        sessionID = Array(data[0..<16])
        var c: UInt64 = 0
        for i in 0..<8 { c = (c << 8) | UInt64(data[16 + i]) }
        counter = c
        ciphertext = Array(data[Self.headerLength...])
    }

    public init(sessionID: [UInt8], counter: UInt64, ciphertext: [UInt8]) {
        self.sessionID = sessionID
        self.counter = counter
        self.ciphertext = ciphertext
    }

    public var bytes: [UInt8] {
        var out = sessionID
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((counter >> UInt64(shift)) & 0xff))
        }
        out.append(contentsOf: ciphertext)
        return out
    }
}
