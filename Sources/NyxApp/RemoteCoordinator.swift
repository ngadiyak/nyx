import AppKit
import NyxCore
import NyxRemote

/// The application's one remote-sessions object: the device identity, the paired list, the socket
/// to the relay, the host that publishes this Mac's sessions, the client that attaches to somebody
/// else's, the catalogue behind the palette's Remote section, and the pairing flow.
///
/// One per app, not one per window. Two connections presenting the same device id is exactly what
/// the relay closes with `replaced`, and a second catalogue would be a second answer to "what is on
/// the other Mac".
///
/// **Threading.** Everything on this object is main-thread only. `RelayConnection` calls its
/// delegate on its own queue, so all three delegate methods do nothing but hop; `RemoteHost` has a
/// queue of its own and is safe to call from anywhere; `RemoteClient` does its work on the caller's
/// thread, so calling it from main is what puts an attachment's bytes on main in the order the
/// relay delivered them. `RemoteSession` takes them off main again immediately -- feeding a
/// 2,000-line snapshot into a `Terminal` is not work for the thread that draws.
final class RemoteCoordinator: NSObject, RelayConnectionDelegate {
    /// The catalogue changed, the connection status changed, or a device was paired: whatever is on
    /// screen that reads either of them (the settings page, an open palette) should ask again.
    var onChange: (() -> Void)?
    /// The pairing state machine moved. The settings window draws the sheet from it.
    var onPairingState: ((PairingFlow.State) -> Void)?

    private(set) var catalogue = RemoteCatalogue()
    private var config: Config
    private var identity: DeviceIdentity?
    private var paired = PairedDevices()
    private var connection: RelayConnection?
    private(set) var host: RemoteHost?
    private var client: RemoteClient?
    private var pairing: PairingFlow?
    private var pairingTimer: Timer?
    /// Something that went wrong before the relay was reached -- an identity file this Mac cannot
    /// read or write. Shown in place of the connection status, which would otherwise read
    /// "Connecting…" for ever with nothing ever connecting.
    private var startupFailure: String?
    /// Every audit line, in order, off the main thread: the file is appended to from the host's
    /// queue and from the settings window, and two appends racing would interleave two lines.
    private let auditQueue = DispatchQueue(label: "nyx.remote.audit", qos: .utility)
    private var wakeObserver: NSObjectProtocol?

    init(config: Config) {
        self.config = config
        super.init()
        // A Mac that wakes with its lid open has a socket the relay gave up on 90 seconds ago and
        // nothing to tell it so until the next send fails. `ensureConnected`, not `connect`: waking
        // up is not a user's gesture, and treating it as one would throw away a backoff earned by a
        // relay that is genuinely down.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.connection?.ensureConnected()
        }
        apply(config)
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - Starting and stopping

    /// The config file changed. Starts, stops, or rebuilds: every one of the five remote keys is
    /// baked into the socket or the host at construction (the URL, the token, the name this Mac
    /// announces, how much scrollback an attach gets), so a change to any of them is a restart
    /// rather than a setting to poke into a live object.
    func apply(_ newConfig: Config) {
        let wasRunning = connection != nil
        let changed = ConfigDiff(from: config, to: newConfig).remoteChanged
        config = newConfig
        guard RemoteCoordinatorPolicy.shouldRun(config: config) else {
            stop(reason: AttachFailure.remoteTurnedOff)
            onChange?()
            return
        }
        guard !wasRunning || changed else { return }
        // Not "turned off": the feature is still on, one of its settings moved, and the next attach
        // will work. Saying the wrong one of those is a lie a user can check.
        stop(reason: AttachFailure.remoteSettingsChanged)
        start()
        onChange?()
    }

    private func start() {
        startupFailure = nil
        let directory = RemoteFiles.directory(besideConfigAt: ConfigStore.path)
        let identity: DeviceIdentity
        do {
            identity = try DeviceIdentity.load(from: RemoteFiles.identity(in: directory))
        } catch {
            // The one failure with nowhere else to go: with no key this device cannot authenticate,
            // cannot sign an attach and cannot be paired with. Said on the settings page rather
            // than swallowed, because every other symptom of it looks like a network problem.
            startupFailure = "Remote sessions could not start: \(error)"
            return
        }
        self.identity = identity
        paired = PairedDevices.load(from: RemoteFiles.pairedDevices(in: directory))
        pairedBox.set(paired)
        catalogue = RemoteCatalogue()
        catalogue.setPaired(paired.namesByID)

        guard let url = URL(string: config.remoteRelay), url.host != nil else {
            startupFailure = "Remote sessions could not start: \(config.remoteRelay) is not a relay address"
            return
        }
        let connection = RelayConnection(url: url, token: config.remoteRelayToken, identity: identity,
                                         deviceName: deviceName)
        connection.delegate = self
        self.connection = connection
        // Read through the box rather than captured: the user pairs and unpairs while this host
        // lives, and a list copied at construction would be wrong within seconds.
        let pairedBox = self.pairedBox
        host = RemoteHost(link: connection, identity: identity, paired: {
            pairedBox.devices
        }, audit: { [weak self] event in
            // Hopped to main rather than appended where it is raised: the host raises these on its
            // own queue with the ids it has, and the names §5.5 promises the file holds -- the
            // paired list and the titles of the open panes -- are main-thread state.
            DispatchQueue.main.async { self?.appendAudit(event) }
        }, snapshotLines: config.remoteSnapshotLines)
        client = RemoteClient(link: connection, identity: identity, paired: { pairedBox.devices })
        // Every tab that is already open, before the socket is: the relay refuses an `attached` for
        // a session its host does not publish, and a Mac that had to be restarted to publish what
        // it already had open would be a feature nobody could find.
        registerExistingPublications()
        // The switch being turned on, or the app being launched with it on, is the user's gesture.
        connection.connect()
    }

    /// `reason` is what every open remote tab is told. There is always one: a tab whose attachment
    /// is simply dropped sits on a screen that has quietly stopped moving, with nothing saying why.
    /// Nothing on the host ended -- this side did -- so it is the whole sentence rather than a
    /// machine name.
    private func stop(reason: String) {
        pairingTimer?.invalidate()
        pairingTimer = nil
        pairing = nil
        client?.endAll(reason: reason)
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
        // The host is dropped whole rather than asked to unregister each session: every pane that
        // published one holds a `RemotePublication` that will find no host to unregister from,
        // which is the right answer -- there is nothing left to unpublish from.
        host = nil
        client = nil
        sessionTitles = [:]
        catalogue = RemoteCatalogue()
        catalogue.setPaired(paired.namesByID)
    }

    /// The paired list as anything not on the main thread may read it.
    ///
    /// `RemoteHost` calls its `paired` closure on its own serial queue, so this cannot simply read
    /// the main-thread property. It is a copy behind a lock rather than a `DispatchQueue.main.sync`
    /// because that would be a lock held across a hop to the thread that draws -- and the host's
    /// queue is where output frames are sealed, so blocking it blocks every attached client.
    private let pairedBox = PairedDevicesBox()

    /// A `PairedDevices` value readable from any thread. Written only from main, whenever the list
    /// changes; every reader gets its own copy.
    private final class PairedDevicesBox {
        private let lock = NSLock()
        private var value = PairedDevices()

        var devices: PairedDevices {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ new: PairedDevices) {
            lock.lock()
            value = new
            lock.unlock()
        }
    }

    // MARK: - What the interface asks

    var isRunning: Bool { connection != nil }

    var deviceName: String {
        RemoteDeviceName.resolve(configured: config.remoteDeviceName,
                                 hostName: Host.current().localizedName ?? "")
    }

    var relayHost: String { URL(string: config.remoteRelay)?.host ?? config.remoteRelay }

    /// The one line the settings page shows, and the row the palette's Remote section leads with
    /// when it is not simply "Online".
    var statusText: String {
        let connection = self.connection?.status.statusText(relayHost: relayHost)
            ?? .unreachable(host: relayHost)
        return RemoteStatusText.text(mode: config.remote, connection: connection,
                                     deviceName: deviceName, failure: startupFailure,
                                     droppedWhileOffline: droppedWhileOffline)
    }

    /// The palette's Remote rows. Only a status row when there is something wrong: a section headed
    /// "Online as this Mac" would be a row nobody can do anything with, on the one list that is
    /// meant to be all verbs.
    func paletteItems(now: Date = Date()) -> [PaletteItem] {
        guard config.remote == .on else { return [] }
        var shown = catalogue
        shown.relayStatusText = isConnected ? nil : statusText
        return shown.paletteItems(now: now, home: NSHomeDirectory())
    }

    /// What the outage this connection has just come back from cost, read at the moment it came
    /// back. `RelayConnection` clears its own counter when the *next* offline stretch starts
    /// filling the queue, so the count has to be taken at the `.online` transition rather than
    /// asked for whenever the page happens to redraw. It is only ever shown beside "Online as …",
    /// and every reconnection overwrites it, so one outage's number never outlives the next.
    private var droppedWhileOffline = 0

    private var isConnected: Bool {
        if case .online = connection?.status { return true }
        return false
    }

    var pairedDevices: [PairedDevice] { paired.devices }

    /// Attaches to a session on a paired Mac. nil when remote sessions are off or the session id is
    /// not one -- the palette's placeholder rows (an offline Mac, a Mac with nothing open, the
    /// status line) carry an empty one on purpose.
    func attach(deviceID: String, sessionID: String, hostName: String, title: String) -> RemoteClient.Attachment? {
        guard let client, let bytes = RemoteID.bytes(base64url: sessionID), bytes.count == 16 else {
            return nil
        }
        return client.attach(hostID: deviceID, hostName: hostName, sessionID: bytes, title: title)
    }

    /// The name and title a palette row's device and session carry now, for the tab that is about
    /// to open. Read here rather than parsed back out of the row's own text, which is formatted for
    /// reading rather than for being taken apart again.
    func describe(deviceID: String, sessionID: String) -> (hostName: String, title: String) {
        let device = catalogue.devices.first { $0.id == deviceID }
        let session = device?.sessions.first { $0.sessionID == sessionID }
        return (device?.name ?? "Mac", session?.title ?? "session")
    }

    /// The audit log's last lines, as the settings page shows them.
    func auditLogTail(lines: Int) -> [String] {
        let url = RemoteFiles.auditLog(in: RemoteFiles.directory(besideConfigAt: ConfigStore.path))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .suffix(lines))
    }

    /// Removes a pairing: the device can no longer see this Mac's sessions, and every attachment
    /// either Mac still holds is torn down rather than left running on a device the user has just
    /// disowned.
    func removePairing(deviceID: String) {
        let name = paired.devices.first { $0.id == deviceID }?.name ?? deviceID
        paired.remove(id: deviceID)
        savePaired()
        catalogue.setPaired(paired.namesByID)
        host?.deviceWentOffline(deviceID)
        // Both directions. The line above stops serving this Mac's sessions to the device; this one
        // ends the tabs this Mac has open *on* it, which would otherwise go on showing the screen
        // of a device the user has just said they no longer trust.
        client?.endAll(matching: deviceID, reason: AttachFailure.unpaired)
        connection?.send(.paired(paired.ids))
        appendAudit(.removed(name))
        onChange?()
    }

    // MARK: - Pairing

    /// This Mac shows a code. The sheet stays in "Pairing…" until the relay confirms the code is
    /// live, because a code shown before the relay knows it is a code the other Mac would be told
    /// does not exist.
    func pairAsHost() {
        guard let identity, connection != nil else {
            NSSound.beep()
            return
        }
        var flow = PairingFlow(side: .host)
        let effects = flow.handle(.open(code: PairCode.make(random: { Int.random(in: 0..<$0) }),
                                        now: Date()), selfID: identity.deviceID)
        begin(flow, effects: effects)
    }

    /// This Mac types a code. The sheet opens idle, showing the field.
    func pairAsClient() {
        guard connection != nil else {
            NSSound.beep()
            return
        }
        begin(PairingFlow(side: .client), effects: [])
    }

    /// A button on the pairing sheet, or the code the user typed.
    func handlePairing(_ event: PairingFlow.Event) {
        guard var flow = pairing, let identity else { return }
        // `handleResolvingFingerprint`, not `handle`: the fingerprint has to be in the state before
        // that state reaches the sheet. See the method's own note for what showing it a step early
        // did to the one thing on that sheet a person is asked to read aloud.
        let effects = flow.handleResolvingFingerprint(event, selfID: identity.deviceID,
                                                      fingerprint: { peerID in
            guard let digest = try? FingerprintHash.digest(myID: identity.deviceID, peerID: peerID)
            else { return nil }
            return Fingerprint.text(digest: digest)
        })
        pairing = flow
        apply(effects)
        if case .cancel = event { endPairing() } else { onPairingState?(flow.state) }
    }

    func cancelPairing() {
        endPairing()
    }

    private func begin(_ flow: PairingFlow, effects: [PairingFlow.Effect]) {
        pairing = flow
        apply(effects)
        onPairingState?(flow.state)
        pairingTimer?.invalidate()
        // A code is good for five minutes; a tick a second would be four hundred wake-ups to notice
        // one deadline. Five seconds is inside the granularity anyone reads a countdown at.
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.handlePairing(.tick(now: Date()))
        }
    }

    private func endPairing() {
        pairingTimer?.invalidate()
        pairingTimer = nil
        pairing = nil
    }

    private func apply(_ effects: [PairingFlow.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let message):
                connection?.send(message)
            case .computeFingerprint:
                // Resolved inside the flow, before the state it produced is shown -- see
                // `handlePairing`. Reaching here would mean something drove the flow with `handle`
                // directly, and the sheet would show a fingerprint that is one step behind.
                continue
            case .store(let peerID, let peerName):
                paired.add(PairedDevice(id: peerID, name: peerName, pairedAt: Date()))
                savePaired()
                catalogue.setPaired(paired.namesByID)
                connection?.send(.paired(paired.ids))
                appendAudit(.paired(peerName))
                onChange?()
            }
        }
    }

    private func savePaired() {
        pairedBox.set(paired)
        let directory = RemoteFiles.directory(besideConfigAt: ConfigStore.path)
        try? paired.save(to: RemoteFiles.pairedDevices(in: directory))
    }

    // MARK: - Publishing this Mac's sessions

    /// Starts publishing one local pane's session to paired Macs, and hands back the handle the
    /// pane keeps for as long as it lives.
    ///
    /// A handle is made whether or not remote sessions are on right now: switching them on later
    /// must publish the tabs that are already open, and a pane cannot be asked to notice that. The
    /// coordinator holds every handle weakly -- the pane owns it, and a pane that has gone must not
    /// keep a session id alive in a list nobody will ever look at again.
    func publish(_ session: TerminalSession) -> RemotePublication {
        let publication = RemotePublication(session: session, coordinator: self)
        publications.append(Weak(publication))
        publications.removeAll { $0.value == nil }
        register(publication)
        return publication
    }

    /// The pane closed. Its clients are told the session ended; nothing about this Mac changes.
    func unpublish(_ publication: RemotePublication) {
        publications.removeAll { $0.value == nil || $0.value === publication }
        host?.unregister(sessionID: publication.sessionID)
    }

    /// The pane published a new title, directory, command or size.
    func summaryChanged() {
        host?.summaryChanged()
    }

    private func register(_ publication: RemotePublication) {
        guard let host, let session = publication.session else { return }
        // The summary closure runs on the host's own queue, at moments nobody here chooses, so it
        // reads only the box -- a value the pane writes from the main thread and nothing else
        // touches. Reaching into the pane's AppKit state from that queue is the mistake this shape
        // exists to make impossible.
        let box = publication.box
        host.register(sessionID: publication.sessionID, session: session, summary: { box.value })
    }

    /// Every live publication, weakly. A window with twelve tabs is twelve of these; a `Weak` box
    /// rather than an `NSHashTable` because the order matters (it is the order the catalogue is
    /// published in) and the list is swept on every change anyway.
    private var publications: [Weak<RemotePublication>] = []

    private struct Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    /// Re-publishes every open pane after the connection is rebuilt -- the switch turned on, a
    /// relay address changed, a token pasted in. Without it, turning remote sessions on would
    /// publish nothing until the user opened a new tab.
    private func registerExistingPublications() {
        publications.removeAll { $0.value == nil }
        for entry in publications {
            guard let publication = entry.value else { continue }
            register(publication)
        }
    }

    // MARK: - The audit log

    /// The title of every session this Mac has published in this run, by base64url session id.
    ///
    /// Entries are *not* dropped when a pane closes. `session ended` is audited from the host's
    /// queue after `unpublish` has already taken the publication out of the list, so a map that
    /// forgot the title at that moment would write `session ended  GntMPWQx` -- the one line in
    /// the file about a session that no longer exists to be looked up anywhere else. Cleared with
    /// the rest of the state in `stop()`.
    private var sessionTitles: [String: String] = [:]

    /// Main thread only, like everything else here. A handful of entries per window.
    private func refreshSessionTitles() {
        for entry in publications {
            guard let publication = entry.value else { continue }
            let title = publication.box.value.title
            guard !title.isEmpty else { continue }
            sessionTitles[RemoteID.base64url(publication.sessionID)] = title
        }
    }

    /// Appends one line to `~/.config/nyx/remote/audit.log`. Best effort and never reported: a log
    /// that cannot be written must not take the session down with it, and there is no screen this
    /// could be shown on at the moment it happens (the host's user is not looking at anything).
    ///
    /// Main thread only: it reads the paired list and the published titles to turn the event's ids
    /// into the names of §5.5. Only the write itself goes to the audit queue.
    private func appendAudit(_ event: AuditLine.Event) {
        refreshSessionTitles()
        let named = AuditNames.naming(event, names: paired.namesByID, titles: sessionTitles)
        let line = AuditLine.text(named, at: Date()) + "\n"
        let url = RemoteFiles.auditLog(in: RemoteFiles.directory(besideConfigAt: ConfigStore.path))
        auditQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) {
                // 0700, like the identity's directory: the file names every device that has
                // attached to this Mac and when, and `createDirectory` applies its attributes only
                // to a directory it actually creates -- so this is the branch that must carry them.
                try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
                try? data.write(to: url)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: - RelayConnectionDelegate
    //
    // All three arrive on the relay's own queue. All three do nothing but hop: everything this
    // object owns is main-thread state, and the ordering the main queue gives is the ordering the
    // attachments need (a snapshot frame before the live frame that follows it).

    func relay(_ connection: RelayConnection, didChange status: RelayConnection.Status) {
        DispatchQueue.main.async { [weak self] in self?.statusChanged(status) }
    }

    func relay(_ connection: RelayConnection, didReceive message: RemoteMessage) {
        DispatchQueue.main.async { [weak self] in self?.received(message) }
    }

    func relay(_ connection: RelayConnection, didReceive frame: BinaryFrame) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.host?.handle(frame)
            self.client?.handle(frame)
        }
    }

    private func statusChanged(_ status: RelayConnection.Status) {
        if case .online = status {
            // Read here and nowhere else: the count is what the outage just ended cost, and
            // `RelayConnection` clears it when the next one starts filling the queue.
            droppedWhileOffline = connection?.droppedWhileOffline ?? 0
            // The relay keeps nothing across a disconnect: it dropped this device's catalogue and
            // every attachment on it. Both sides re-declare, which is also what publishes this
            // Mac's sessions and re-declares the pairings for the first connection of all.
            host?.linkDidReconnect()
            client?.linkDidReconnect()
        }
        // The relay let go of this device for good: a bad token, a bad signature, or another
        // connection presenting the same device id. `RelayConnection` goes straight here without
        // passing `.offline`, so nothing else would ever tell the attachments -- they would stay
        // `live` for the rest of the session, taking keystrokes into an outbox that will never be
        // flushed. The socket is not coming back without a `connect()`, so they end rather than
        // reconnect.
        if case .failed(let code) = status {
            client?.endAll(reason: AttachFailure.relayRefused(code))
        }
        if case .offline = status {
            // Everything the other Macs told us is now a guess. Emptying it is the honest answer,
            // and `paletteItems` puts the status line where the sessions were.
            catalogue = RemoteCatalogue()
            catalogue.setPaired(paired.namesByID)
            // And every attached tab has to be told, or it goes on looking live: still taking
            // keystrokes, sealing them with a cipher the host has already forgotten, and flushing
            // them at it after the reconnect has rotated the keys.
            client?.linkDidDisconnect()
        }
        onChange?()
    }

    private func received(_ message: RemoteMessage) {
        switch message.t {
        case "presence":
            catalogue.applyPresence(message.devices ?? [])
            // The host needs this one too: it is the relay's only word about a client that went
            // away, and without it the writer token is stranded on a Mac that is not there.
            host?.handle(message)
            onChange?()
        case "catalogue":
            guard let deviceID = message.deviceID else { return }
            catalogue.applyCatalogue(deviceID: deviceID, sessions: message.sessions ?? [])
            onChange?()
        case "pair_opened":
            guard let code = message.code else { return }
            handlePairing(.opened(code: code))
        case "pair_request":
            guard let from = message.from else { return }
            handlePairing(.request(peerID: from, peerName: message.name ?? from))
        case "pair_accept":
            guard let from = message.from else { return }
            handlePairing(.accepted(peerID: from, peerName: message.name ?? from))
        case "pair_confirm":
            handlePairing(.confirmTheirs)
        case "error":
            // A pairing error carries no session id; an attach error does, and belongs to the tab
            // that is waiting on it rather than to a sheet that may not even be open.
            if message.sessionID == nil, pairing != nil {
                handlePairing(.error(code: message.code ?? ""))
            }
            client?.handle(message)
        default:
            host?.handle(message)
            client?.handle(message)
        }
    }
}

/// One local pane published to paired Macs, for as long as that pane exists.
///
/// It owns the session id (16 random bytes, made once and stable for the pane's life) and the box
/// the summary is read out of. The pane writes the box on the main thread whenever anything a
/// palette row shows moves; `RemoteHost` reads it on its own queue, which is why it is a box and
/// not a closure over the pane.
final class RemotePublication {
    let sessionID: [UInt8]
    /// Weak: the pane owns its session, and a published session that has ended must not be kept
    /// alive by the list of things that were once published.
    private(set) weak var session: TerminalSession?
    let box = SummaryBox()
    private weak var coordinator: RemoteCoordinator?
    private var ended = false

    init(session: TerminalSession, coordinator: RemoteCoordinator) {
        // 16 random bytes, per the wire contract and spec §11: made when the pane is created and
        // never persisted, so a session id means "this pane, this run" and cannot be guessed from
        // one launch to the next.
        self.sessionID = (0..<16).map { _ in UInt8.random(in: 0...255) }
        self.session = session
        self.coordinator = coordinator
    }

    /// What this pane looks like in another Mac's palette. Called on the main thread only.
    func update(_ info: RemoteSessionInfo) {
        guard !ended, box.set(info) else { return }
        coordinator?.summaryChanged()
    }

    /// The pane closed. Everyone attached is told the session ended.
    func end() {
        guard !ended else { return }
        ended = true
        coordinator?.unpublish(self)
    }

    /// The published summary, readable from any thread.
    ///
    /// `RemoteHost.register`'s closure runs on the host's serial queue at moments the pane does not
    /// choose -- a debounced publish, a reconnect -- so it must read only values that are safe to
    /// touch from another thread. This is that value: written on main, copied out under a lock.
    final class SummaryBox {
        private let lock = NSLock()
        private var info = RemoteSessionInfo(sessionID: "", title: "", cwd: "", repo: "", branch: "",
                                             process: "", lastCommand: "", lastActivity: "",
                                             cols: 80, rows: 24)

        var value: RemoteSessionInfo {
            lock.lock()
            defer { lock.unlock() }
            return info
        }

        /// Returns whether anything actually changed, so an unchanged summary does not wake the
        /// host's queue and re-publish the whole catalogue every half second.
        @discardableResult
        func set(_ new: RemoteSessionInfo) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard new != info else { return false }
            info = new
            return true
        }
    }
}
