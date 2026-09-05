import Foundation

/// What the palette's Remote section knows: which paired devices are online, what sessions each
/// one publishes, and how to turn that into rows. Kept apart from `RemoteMessage` because this is
/// the *view* of the wire data -- sorted, named, formatted -- while `RemoteMessage` is just what
/// arrived.
public struct RemoteCatalogue: Equatable {
    public struct Device: Equatable {
        public let id: String
        public var name: String
        public var online: Bool
        public var sessions: [RemoteSessionInfo]
    }

    private var byID: [String: Device] = [:]

    /// Shown in the settings page and, when set, as the palette's first Remote row -- so a relay
    /// outage or a bad token is something the user is told, not a list that quietly goes empty.
    public var relayStatusText: String?

    public init() {}

    /// A `presence` message: who is online right now, by name. This is the freshest name Nyx has
    /// for a device, so it always wins over whatever `setPaired` supplied.
    public mutating func applyPresence(_ devices: [RemotePresence]) {
        for p in devices {
            var device = byID[p.deviceID] ?? Device(id: p.deviceID, name: p.name, online: p.online, sessions: [])
            device.name = p.name
            device.online = p.online
            if !p.online { device.sessions = [] } // a host's catalogue is dropped when it disconnects
            byID[p.deviceID] = device
        }
    }

    /// A `catalogue` message: the sessions one host currently publishes. The relay only ever sends
    /// this for an online host, so a device this names for the first time is assumed online even if
    /// no `presence` has arrived yet -- the alternative, showing its sessions under "offline", would
    /// be actively wrong.
    public mutating func applyCatalogue(deviceID: String, sessions: [RemoteSessionInfo]) {
        var device = byID[deviceID] ?? Device(id: deviceID, name: "", online: true, sessions: [])
        device.sessions = sessions
        byID[deviceID] = device
    }

    /// The locally paired devices' names, from `PairedDevices` on disk. Only fills in a name for a
    /// device Nyx has no live (online) name for yet -- a device presence has already named should
    /// keep the name presence gave it, not be second-guessed by a possibly stale local copy.
    public mutating func setPaired(_ names: [String: String]) {
        for (id, name) in names {
            if var device = byID[id] {
                if !device.online { device.name = name }
                byID[id] = device
            } else {
                byID[id] = Device(id: id, name: name, online: false, sessions: [])
            }
        }
    }

    /// Online devices first (what the user is most likely to want), then alphabetically by name so
    /// the list does not reshuffle on every presence update.
    public var devices: [Device] {
        byID.values.sorted { a, b in
            if a.online != b.online { return a.online }
            return a.name < b.name
        }
    }

    /// The Remote section of the command palette: a relay-status row if there is one, then one row
    /// per session of every online device, then one placeholder row per offline device -- so a
    /// paired Mac that is asleep still shows up, just not as something you can attach to.
    public func paletteItems(now: Date) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let status = relayStatusText {
            items.append(.remoteSession(deviceID: "", sessionID: "", title: status, detail: ""))
        }
        for device in devices {
            if device.online {
                for session in device.sessions {
                    items.append(.remoteSession(deviceID: device.id, sessionID: session.sessionID,
                                                title: "\(device.name) · \(session.title)",
                                                detail: Self.detail(for: session, now: now)))
                }
            } else {
                items.append(.remoteSession(deviceID: device.id, sessionID: "",
                                            title: "\(device.name) — offline", detail: "offline"))
            }
        }
        return items
    }

    /// The palette row's second line. `home`, when it prefixes `cwd`, is collapsed to `~` the way a
    /// shell prompt does -- the caller passes the *local* user's home, since that is whose palette
    /// is reading a possibly different machine's absolute path.
    public static func detail(for s: RemoteSessionInfo, now: Date, home: String = "") -> String {
        var head = shortenedCwd(s.cwd, home: home)
        if !s.branch.isEmpty {
            head = head.isEmpty ? s.branch : "\(head)  \(s.branch)"
        }
        var tail: [String] = []
        if !s.process.isEmpty { tail.append("running: \(s.process)") }
        if !s.lastCommand.isEmpty { tail.append("last: \(s.lastCommand)") }
        let rel = relative(s.lastActivity, now: now)
        if !rel.isEmpty { tail.append(rel) }
        guard !tail.isEmpty else { return head }
        return head.isEmpty ? tail.joined(separator: " · ") : "\(head) · \(tail.joined(separator: " · "))"
    }

    private static func shortenedCwd(_ cwd: String, home: String) -> String {
        guard !home.isEmpty else { return cwd }
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    /// A human relative time for a palette row -- exact timestamps are not something you read at a
    /// glance across a busy list. Buckets get coarser as they get older: minutes are worth counting
    /// precisely, days are not.
    public static func relative(_ iso8601: String, now: Date) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return "" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed) / 60) min ago" }
        if elapsed < 86400 { return "\(Int(elapsed) / 3600) h ago" }
        if elapsed < 172_800 { return "yesterday" }
        return "\(Int(elapsed) / 86400) days ago"
    }
}
