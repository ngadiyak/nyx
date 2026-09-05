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
    /// The devices this Mac has actually paired with, from `setPaired`.
    ///
    /// Every `presence` and `catalogue` message is checked against it. The relay routes; it does
    /// not vouch (§7.1), so an entry naming a device that is not in `paired.json` is either a bug
    /// or a relay offering a row that looks like one of the user's own Macs, complete with a name
    /// and a working directory of its choosing. Attaching to it would fail at the signature check
    /// -- but the row has no business being in ⌘⇧P at all.
    private var pairedIDs: Set<String> = []

    /// Shown in the settings page and, when set, as the palette's first Remote row -- so a relay
    /// outage or a bad token is something the user is told, not a list that quietly goes empty.
    public var relayStatusText: String?

    public init() {}

    /// A `presence` message: who is online right now, by name. This is the freshest name Nyx has
    /// for a device, so it always wins over whatever `setPaired` supplied.
    public mutating func applyPresence(_ devices: [RemotePresence]) {
        for p in devices where pairedIDs.contains(p.deviceID) {
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
        guard pairedIDs.contains(deviceID) else { return }
        var device = byID[deviceID] ?? Device(id: deviceID, name: "", online: true, sessions: [])
        device.sessions = sessions
        byID[deviceID] = device
    }

    /// The locally paired devices' names, from `PairedDevices` on disk. Also *the* list of devices
    /// this catalogue will accept anything about at all -- see `pairedIDs`.
    ///
    /// Only fills in a name for a device Nyx has no live (online) name for yet: a device presence
    /// has already named should keep the name presence gave it, not be second-guessed by a
    /// possibly stale local copy. Devices no longer in the list are dropped whole, because this is
    /// what Remove in the settings page calls: unpairing has to take the Mac out of the palette,
    /// with its live sessions, and not only out of `paired.json`.
    public mutating func setPaired(_ names: [String: String]) {
        pairedIDs = Set(names.keys)
        byID = byID.filter { pairedIDs.contains($0.key) }
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
    ///
    /// Every paired device gets *some* row. A Mac that is awake but has published nothing (it was
    /// just launched, or its user closed the last tab) would otherwise disappear from the list
    /// entirely, which reads as a pairing that has broken rather than as a Mac with nothing open.
    ///
    /// `home` is the *local* user's home directory, collapsed to `~` in a row's detail the way a
    /// shell prompt does. Local rather than the host's because it is a local palette being read;
    /// on the two Macs this feature is for it is the same path, and where it is not, the row shows
    /// the absolute path, which is never wrong -- only longer.
    public func paletteItems(now: Date, home: String = "") -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let status = relayStatusText {
            items.append(.remoteSession(deviceID: "", sessionID: "", title: status, detail: "",
                                        isEnabled: false))
        }
        for device in devices {
            if device.online {
                guard !device.sessions.isEmpty else {
                    // The machine on the left, what is wrong with it on the right. Saying "iMac —
                    // no sessions" *and* putting the same words in the detail said it twice.
                    items.append(.remoteSession(deviceID: device.id, sessionID: "",
                                                title: device.name, detail: "no sessions",
                                                isEnabled: false))
                    continue
                }
                for session in device.sessions {
                    items.append(.remoteSession(deviceID: device.id, sessionID: session.sessionID,
                                                title: "\(device.name) · \(session.title)",
                                                detail: Self.detail(for: session, now: now,
                                                                    home: home),
                                                searchable: Self.searchable(session)))
                }
            } else {
                items.append(.remoteSession(deviceID: device.id, sessionID: "",
                                            title: device.name, detail: "offline",
                                            isEnabled: false))
            }
        }
        return items
    }

    /// Everything about a session a person might type to find it again, beyond its title: where it
    /// is, what it is on, what is running, and what was last run. Not the relative time -- "3 h ago"
    /// is not something anyone searches for, and it would make every row match a query of "ago".
    public static func searchable(_ s: RemoteSessionInfo) -> [String] {
        [s.cwd, s.repo, s.branch, s.process, s.lastCommand]
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
