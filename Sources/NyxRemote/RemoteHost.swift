import CryptoKit
import Foundation
import NyxCore

/// This Mac as a host: it publishes its sessions to the relay, answers attaches from paired
/// devices, streams each session's output to whoever is attached, and lets exactly one of them type.
///
/// Everything mutable lives on one serial queue and is only ever touched there. That is not
/// decoration. Output arrives on each session's PTY reader thread, attaches arrive on the relay
/// connection's queue, and the pane calls `register`/`summaryChanged` from the main thread; the
/// queue is also what puts the snapshot and the live bytes in the right order without a buffer of
/// its own, because a chunk tapped after the snapshot block was enqueued is a block after it.
///
/// The one thing the queue cannot order by itself is the join between the two: see
/// `Registration.sequence`.
public final class RemoteHost {
    /// One attached client. `startSequence` is the output-chunk number this client's snapshot ends
    /// at -- chunks below it are already in the snapshot text, chunks from it on are streamed.
    private struct Attachment {
        let deviceID: String
        let e2e: E2ESession
        let startSequence: UInt64
    }

    /// A published session and everyone attached to it. A class so the queue can mutate one in
    /// place without writing the whole dictionary entry back; nothing outside the queue sees it.
    private final class Registration {
        let session: TerminalSession
        let summary: () -> RemoteSessionInfo
        var arbiter = WriterArbiter()
        var attachments: [String: Attachment] = [:]
        /// The absolute number of the next output chunk to be delivered, in the session's own
        /// numbering (it starts at whatever the session had already fed when this host tapped it,
        /// which is why `tapOutput` returns that number rather than the tap being assumed to start
        /// at zero).
        ///
        /// It lags the session's fed count by at most the one chunk that has been fed but whose tap
        /// call has not run yet, and assigning the number here, on the queue, rather than in the
        /// tap, is what makes the join exact: the snapshot's cut-off is the session's fed count, so
        /// a chunk fed before the snapshot but tapped after it still gets its own lower number and
        /// is therefore not sent again.
        var sequence: UInt64 = 0

        init(session: TerminalSession, summary: @escaping () -> RemoteSessionInfo) {
            self.session = session
            self.summary = summary
        }
    }

    /// One data frame never carries more than this. The relay's per-connection outbound queue is
    /// bounded in frames, not bytes, but a 10,000-line snapshot in a single frame would still be a
    /// megabyte-long WebSocket message that the client cannot start drawing until all of it has
    /// arrived; at 16 KiB the first line of scrollback is on screen while the rest is still coming.
    private static let maxFrameBytes = 16 * 1024

    private let link: RelayLink
    private let identity: DeviceIdentity
    private let paired: () -> PairedDevices
    private let audit: (AuditLine.Event) -> Void
    private let snapshotLines: Int
    private let summaryDebounce: TimeInterval
    private let queue = DispatchQueue(label: "nyx.remote.host")

    private var registrations: [String: Registration] = [:]
    /// Publication order, so the catalogue a paired device sees is stable between updates rather
    /// than reshuffled by dictionary iteration every time anything changes.
    private var order: [String] = []
    private var summaryPending = false

    /// `paired` and `summary` are read every time they are needed rather than captured once: the
    /// user pairs a device, renames a session or changes directory while this object lives, and a
    /// snapshot of either taken at construction would be wrong within seconds.
    public init(link: RelayLink, identity: DeviceIdentity, paired: @escaping () -> PairedDevices,
                audit: @escaping (AuditLine.Event) -> Void, snapshotLines: Int,
                summaryDebounce: TimeInterval = 2) {
        self.link = link
        self.identity = identity
        self.paired = paired
        self.audit = audit
        self.snapshotLines = snapshotLines
        self.summaryDebounce = summaryDebounce
    }

    // MARK: - Sessions

    /// Publishes a session and taps its output.
    ///
    /// `summary` is called on this host's own serial queue, not on main, and at moments the caller
    /// does not choose (a debounced publish, a reconnect). It must therefore read only values that
    /// are safe to touch from another thread -- or capture what it needs and hop -- rather than
    /// reaching into a pane's AppKit state.
    ///
    /// The catalogue goes out immediately, before this returns to the queue's next block: the relay
    /// refuses an `attached` for a session its host does not publish, so a session that were
    /// announced only by the debounced summary could be attached to (from a palette row that is
    /// otherwise up to date) in a window where the answer would be thrown away.
    public func register(sessionID: [UInt8], session: TerminalSession, summary: @escaping () -> RemoteSessionInfo) {
        guard sessionID.count == 16 else {
            assertionFailure("RemoteHost.register: a session id is 16 bytes, got \(sessionID.count)")
            return
        }
        let key = RemoteID.base64url(sessionID)
        queue.async { [weak self] in
            guard let self else { return }
            let registration = Registration(session: session, summary: summary)
            self.registrations[key] = registration
            if !self.order.contains(key) { self.order.append(key) }
            // The tap holds this host weakly: the pane owns the session, the session owns this
            // closure, and a strong reference here would keep the host alive for as long as any
            // session it ever published.
            //
            // The count it returns is where this session's numbering starts. A session is normally
            // published long after it started printing, so starting at zero would put every
            // delivered chunk below the cut-off an attach later takes from the session's own count,
            // and the client would be sent nothing live until the session had printed as much again
            // as it had before it was published.
            registration.sequence = session.tapOutput { [weak self] bytes in
                self?.queue.async { self?.deliver(key: key, bytes: bytes) }
            }
            self.publishSessions()
        }
    }

    /// Stops publishing a session and tells everyone attached to it that it is over. Their tabs say
    /// "Session ended on <this Mac>"; nothing about the local session changes.
    public func unregister(sessionID: [UInt8]) {
        let key = RemoteID.base64url(sessionID)
        queue.async { [weak self] in
            guard let self, let registration = self.registrations.removeValue(forKey: key) else { return }
            self.order.removeAll { $0 == key }
            registration.session.tapOutput(nil)
            for deviceID in registration.attachments.keys.sorted() {
                self.link.send(.sessionEnded(to: deviceID, sessionID: key))
            }
            // One line for the session, not one per client: this end is what stopped, and a row of
            // "detached" lines would read as the clients having left of their own accord.
            self.audit(.sessionEnded(session: key))
            self.publishSessions()
        }
    }

    /// The pane noticed something a palette row shows -- a new title, a directory, a finished
    /// command. Coalesced: the first change schedules the publish, and every change inside that
    /// window rides along with it, so a session whose title changes on every keystroke publishes
    /// twice a second at worst and, unlike a debounce that restarts its timer, still publishes
    /// while the changes keep coming.
    public func summaryChanged() {
        queue.async { [weak self] in
            guard let self, !self.summaryPending else { return }
            self.summaryPending = true
            self.queue.asyncAfter(deadline: .now() + self.summaryDebounce) { [weak self] in
                guard let self else { return }
                self.summaryPending = false
                self.publishSessions()
            }
        }
    }

    /// The socket came back. The relay keeps nothing across a disconnect: it dropped this device's
    /// catalogue and sent `session_ended` to everyone who was attached, so the attachments here are
    /// gone whether this side likes it or not. They are cleared (and audited) rather than kept,
    /// because a stale arbiter would make the next client to attach an observer behind a writer
    /// that no longer exists.
    public func linkDidReconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.link.send(.paired(self.paired().ids))
            for key in self.order {
                guard let registration = self.registrations[key] else { continue }
                for deviceID in registration.attachments.keys.sorted() {
                    self.audit(.detached(device: deviceID, session: key))
                }
                registration.attachments.removeAll()
                registration.arbiter = WriterArbiter()
            }
            self.publishSessions()
        }
    }

    // MARK: - Messages from clients

    public func handle(_ m: RemoteMessage) {
        queue.async { [weak self] in
            guard let self else { return }
            switch m.t {
            case "attach": self.attach(m)
            case "take_control": self.takeControl(m)
            case "detach": self.detach(m)
            case "presence": self.presence(m)
            default: break
            }
        }
    }

    /// Input from a client. Only the writer's key is tried, so an observer's frame -- and anything
    /// the relay misrouted, and anything an attacker made up -- cannot be decrypted at all, let
    /// alone written to the PTY. A frame that fails to open leaves the writer's replay window
    /// untouched, so a tampered frame cannot make the genuine one that follows look like a replay.
    public func handle(_ f: BinaryFrame) {
        queue.async { [weak self] in
            guard let self,
                  let registration = self.registrations[RemoteID.base64url(f.sessionID)],
                  let writer = registration.arbiter.writer,
                  let attachment = registration.attachments[writer],
                  let input = try? attachment.e2e.open(f) else { return }
            registration.session.send(input)
        }
    }

    /// A device this host was talking to has gone. The relay says so once, in `presence`, and says
    /// nothing else -- there is no `detach` from a socket that closed -- so without this its
    /// attachment lives on: the writer token is stranded on a Mac that is not there (nobody left
    /// can type), and every chunk of output is still encrypted and sent for it.
    ///
    /// Public as well as reachable through `presence` because the app knows things the relay does
    /// not: the connection this host itself is on has dropped, or the user removed a pairing.
    public func deviceWentOffline(_ deviceID: String) {
        queue.async { [weak self] in
            self?.dropAttachments(of: deviceID)
        }
    }

    /// Blocks until everything already queued has run. For tests: the public API is asynchronous on
    /// purpose (the reader thread must never wait on a network), so a test that asserted on the
    /// wire right after calling `handle` would be asserting on a race.
    func flush() {
        queue.sync {}
    }

    // MARK: - Queue-only work

    private func attach(_ m: RemoteMessage) {
        guard let from = m.from, let key = m.sessionID,
              let sessionID = RemoteID.bytes(base64url: key), sessionID.count == 16,
              let pubkey = m.ephemeralPubkey, let sig = m.sig else { return }
        // Three separate reasons to drop the message without a word, and each is the relay's bug or
        // an attacker, never this user's: a device we never paired with, a session we do not
        // publish, and a signature that does not belong to the device the relay says sent it. None
        // of them is written to the audit log -- that file is a record of what paired devices did
        // on this Mac, and filling it with unroutable traffic would bury the lines that matter.
        guard paired().contains(from), let registration = registrations[key] else { return }
        guard E2ESession.verifyPeer(pubkey: pubkey, sig: sig, sessionID: sessionID, deviceID: from) else { return }

        let mine = E2ESession.ephemeral()
        guard let signed = try? E2ESession.signedPublicKey(mine, sessionID: sessionID, identity: identity),
              let e2e = try? E2ESession(mine: mine, peer: pubkey, sessionID: sessionID, isHost: true) else { return }

        // A client that reconnects re-sends `attach` for a session it never really left. It keeps
        // the role it had: appending it to the arbiter again would both demote it behind observers
        // that arrived while it was away and leave a duplicate entry that breaks promotion later.
        let role: AttachState.Role
        if registration.attachments[from] != nil, let existing = registration.arbiter.role(of: from) {
            role = existing
        } else {
            role = registration.arbiter.attached(from)
        }

        // The snapshot and the cut-off come out of the session under one lock, so the text and the
        // point in the byte stream it corresponds to cannot disagree.
        let (snapshot, cols, rows, fed) = registration.session.withTerminalAndOutputCount { terminal, count in
            let top = max(0, terminal.totalRows - snapshotLines)
            return (terminal.transcript(rows: top..<terminal.totalRows, options: .forRestoring),
                    terminal.cols, terminal.rows, count)
        }
        registration.attachments[from] = Attachment(deviceID: from, e2e: e2e, startSequence: fed)

        // Sealed before anything is sent, because half a snapshot is worse than none: the client
        // would draw a screen missing its middle and never know. A seal that fails here cannot
        // recover -- the cipher is per attachment -- so the attach is abandoned and said so in the
        // log, and the client, having had no `attached`, stays in `attaching` and can try again.
        guard let frames = chunked(Array(snapshot.utf8), sealedBy: e2e) else {
            registration.attachments[from] = nil
            announce(registration.arbiter.detached(from), in: registration, key: key)
            audit(.detached(device: from, session: key))
            return
        }
        link.send(.attached(to: from, sessionID: key, ephemeralPubkey: signed.pubkey, sig: signed.sig,
                            role: Self.name(role), cols: cols, rows: rows))
        for frame in frames { link.send(frame) }
        link.send(.snapshotEnd(to: from, sessionID: key))
        audit(.attached(device: from, session: key))
    }

    /// The relay's only word about a client that went away. Every device it lists as offline is
    /// dropped from every session it was attached to, exactly as if it had sent `detach`.
    private func presence(_ m: RemoteMessage) {
        for device in m.devices ?? [] where !device.online {
            dropAttachments(of: device.deviceID)
        }
    }

    /// Removes a device from every session it is attached to: promote whoever the arbiter picks,
    /// tell the clients that are left, and write the line that says it is gone. Shared by `detach`,
    /// `presence` and `deviceWentOffline` so a client that vanishes leaves exactly the same state
    /// behind as one that said goodbye.
    private func dropAttachments(of deviceID: String) {
        for key in order {
            guard let registration = registrations[key],
                  registration.attachments.removeValue(forKey: deviceID) != nil else { continue }
            announce(registration.arbiter.detached(deviceID), in: registration, key: key)
            audit(.detached(device: deviceID, session: key))
        }
    }

    private func takeControl(_ m: RemoteMessage) {
        guard let from = m.from, let key = m.sessionID, let registration = registrations[key],
              paired().contains(from), registration.attachments[from] != nil else { return }
        let changes = registration.arbiter.takeControl(from)
        guard !changes.isEmpty else { return }
        announce(changes, in: registration, key: key)
        audit(.tookControl(device: from, session: key))
    }

    /// Both this and `takeControl` re-check the pairing rather than trusting the attachment alone:
    /// a device unpaired while attached must not be able to move the writer token or tear anything
    /// down afterwards, and the relay has no way to know the user has just removed it.
    private func detach(_ m: RemoteMessage) {
        guard let from = m.from, let key = m.sessionID, let registration = registrations[key],
              paired().contains(from), registration.attachments[from] != nil else { return }
        dropAttachments(of: from)
    }

    /// One `role` message per change, per client still attached: an observer's strip has to change
    /// when somebody else takes control, not only when the observer itself is the one demoted.
    private func announce(_ changes: [(deviceID: String, role: AttachState.Role)],
                          in registration: Registration, key: String) {
        for change in changes {
            for deviceID in registration.attachments.keys.sorted() {
                link.send(.role(to: deviceID, sessionID: key, deviceID: change.deviceID,
                                role: Self.name(change.role)))
            }
        }
    }

    private func deliver(key: String, bytes: [UInt8]) {
        guard let registration = registrations[key] else { return }
        let sequence = registration.sequence
        registration.sequence += 1
        for deviceID in registration.attachments.keys.sorted() {
            guard let attachment = registration.attachments[deviceID],
                  attachment.startSequence <= sequence else { continue }
            for frame in chunked(bytes, sealedBy: attachment.e2e) ?? [] { link.send(frame) }
        }
    }

    private func publishSessions() {
        link.send(.sessions(order.compactMap { registrations[$0]?.summary() }))
    }

    /// nil if any part failed to seal, never a partial answer: a caller that sent what it got would
    /// be putting a stream with a hole in it on the wire, and the client cannot tell a hole from a
    /// program that printed nothing.
    private func chunked(_ bytes: [UInt8], sealedBy e2e: E2ESession) -> [BinaryFrame]? {
        guard !bytes.isEmpty else { return [] }
        var frames: [BinaryFrame] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.maxFrameBytes, bytes.count)
            guard let frame = try? e2e.seal(Array(bytes[start..<end])) else { return nil }
            frames.append(frame)
            start = end
        }
        return frames
    }

    private static func name(_ role: AttachState.Role) -> String {
        role == .writer ? "writer" : "observer"
    }
}
