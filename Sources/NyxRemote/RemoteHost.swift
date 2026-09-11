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
        /// When the relay said this device's socket had gone, or nil while it is connected.
        ///
        /// A held attachment is the whole of the reconnect fix: the relay's word that a socket
        /// closed is not the user's word that they have finished, and treating the two the same
        /// cost the writer its token, the client a second snapshot and the log two lines -- every
        /// ninety-one seconds, because that is how often the relay used to close a quiet socket.
        var suspendedAt: Date?
        /// `registration.sequence` at the moment it was held: the chunk number the client's mirror
        /// is known to be complete up to. **nil when there is no such number**, which is a hold
        /// that can never resume -- see `suspend(_:baselineIsTrustworthy:)`.
        ///
        /// A sequence rather than a "did it miss anything" boolean, because a boolean can only be
        /// set by code that runs, and the windows in which output reaches nobody are exactly the
        /// windows in which nothing on this side is watching. `deliver` bumps `sequence` for every
        /// chunk whether or not anybody is attached, so `sequence == heldAtSequence` at re-attach
        /// time means, verifiably, that not one chunk was produced *and sent* while this attachment
        /// was away. Anything else is a re-snapshot, and the cost of being wrong in that direction
        /// is one snapshot rather than a hole nobody can see (`E2ESession.open` checks that counters
        /// increase and cannot see a gap).
        var heldAtSequence: UInt64?
        /// The screen size this client was last told, so a resize is announced once per client
        /// rather than on every debounced publish.
        ///
        /// Per attachment and not per registration, which is where it started. A resize is
        /// announced from the *debounced* publish, so for up to `summaryDebounce` the host knows a
        /// size nobody attached has been told; an `attach` landing in that window carries the new
        /// size in its own `attached`, and a registration-wide record would have taken that as
        /// having told everybody. The clients already watching would then keep the shape the host
        /// had when *they* attached, for the life of the tab -- D2 again, re-opened by a second
        /// viewer arriving at the wrong moment.
        var announcedSize: GridSize
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
    private let reattachWindow: TimeInterval
    private let clock: RemoteClock
    private let queue = DispatchQueue(label: "nyx.remote.host")

    private var registrations: [String: Registration] = [:]
    /// Publication order, so the catalogue a paired device sees is stable between updates rather
    /// than reshuffled by dictionary iteration every time anything changes.
    private var order: [String] = []
    private var summaryPending = false

    /// `paired` and `summary` are read every time they are needed rather than captured once: the
    /// user pairs a device, renames a session or changes directory while this object lives, and a
    /// snapshot of either taken at construction would be wrong within seconds.
    ///
    /// `reattachWindow` is how long an attachment survives its client's socket closing. Sixty
    /// seconds, the same number `RemoteClient.Attachment.reattachWindow` gives the client to keep
    /// asking: the two are one race seen from its two ends, and a host that gave up first would
    /// end a tab that was still trying.
    public init(link: RelayLink, identity: DeviceIdentity, paired: @escaping () -> PairedDevices,
                audit: @escaping (AuditLine.Event) -> Void, snapshotLines: Int,
                summaryDebounce: TimeInterval = 2,
                reattachWindow: TimeInterval = 60, clock: RemoteClock = .system) {
        self.link = link
        self.identity = identity
        self.paired = paired
        self.audit = audit
        self.snapshotLines = snapshotLines
        self.summaryDebounce = summaryDebounce
        self.reattachWindow = reattachWindow
        self.clock = clock
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

    /// This host's own socket came back. The relay kept nothing: it dropped this device's catalogue
    /// and sent `session_suspended` to everyone who was attached, so each of them is re-attaching
    /// as soon as this Mac's catalogue lists the session again.
    ///
    /// The attachments are **held**, and the arbiter is left exactly as it was. Clearing both --
    /// which is what this did -- made every one of those re-attaches a new attachment: a fresh
    /// snapshot, the writer token handed to whoever asked first, and two audit lines per client.
    /// With the relay closing quiet sockets every ninety-one seconds, that was the churn the QA
    /// measured. The sweep is what ends an attachment whose client really has gone.
    public func linkDidReconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.link.send(.paired(self.paired().ids))
            let devices = Set(self.order.compactMap { self.registrations[$0] }
                .flatMap { $0.attachments.keys })
            // **With no baseline**, so every one of these re-attaches is answered with a fresh
            // snapshot. Nothing suspends when this Mac's own socket goes -- the relay tells this
            // host about *other* devices, and its own status arrives too late and only as a status
            // -- so `deliver` went on sealing each chunk and bumping `sequence` into a link with
            // nowhere to put it. A baseline taken now would count exactly the chunks nobody
            // received, the re-attach would satisfy `heldAtSequence == sequence`, and the client
            // would resume onto a mirror permanently missing everything this host printed during
            // the outage, silently. There is no number here that means "delivered", so there is no
            // number.
            //
            // `suspend` is idempotent by its own guard, which matters here: a client whose socket
            // dropped before this host's did is already held, with a baseline that *is* trustworthy
            // -- it was taken before either socket went -- and re-holding it would throw that away.
            for deviceID in devices.sorted() { self.suspend(deviceID, baselineIsTrustworthy: false) }
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

    /// A device this host was talking to has gone *quiet*: the relay's socket for it closed. Its
    /// attachments are **held** for `reattachWindow`, because a closed socket is not a closed tab
    /// -- the client is already re-attaching -- and dropping them is what made every reconnect a
    /// new attachment.
    ///
    /// Reachable through `presence` and kept public for the one caller that is not the relay: a
    /// test that drives a departure without a wire message. The app's own reason for calling it
    /// directly is gone -- `RemoteCoordinator.removePairing` now calls `deviceRemoved`, which is a
    /// different answer to a different question.
    public func deviceWentOffline(_ deviceID: String) {
        queue.async { [weak self] in
            self?.suspend(deviceID)
        }
    }

    /// The user removed this device. Its attachments go at once: there is nothing to come back to,
    /// the pairing check would refuse the re-attach anyway, and a held attachment would leave the
    /// writer token on a Mac that is no longer allowed to type.
    public func deviceRemoved(_ deviceID: String) {
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
        let existing = registration.attachments[from]
        let role: AttachState.Role
        if existing != nil, let held = registration.arbiter.role(of: from) {
            role = held
        } else {
            role = registration.arbiter.attached(from)
        }
        // A resume, and only under both halves of the proof: the attachment was actually **held**
        // (a socket that closed, not a second `attach` from a device that never went), and not one
        // chunk was produced while it was away. Then its mirror is still exactly this host's
        // screen, and it gets `attached` and `snapshot_end` with nothing between them -- no ~85 KB
        // re-encrypted, no second copy of the transcript appended to the first, no writer/observer
        // flap, no line in the log. This is the whole client-side half of B1.
        //
        // `existing != nil` alone is **not** enough, and was the first draft of this line: a
        // duplicated or replayed `attach` from a device that never dropped would have been answered
        // with an empty screen where it used to get the snapshot.
        //
        // One residual window, named because a reader must not believe there is none: a chunk
        // delivered in the milliseconds between the client's socket closing and this host being
        // told (`offlineLocked` removes the client from `h.attached` and broadcasts presence under
        // one lock, so it is a relay-to-host trip, tens of milliseconds) is sealed, sent, dropped
        // by the relay, and *counted* -- so it lands below `heldAtSequence` and the resume believes
        // the mirror is whole. Closing it needs the client to say how much it actually received,
        // which is a wire field and a byte-accounting handshake on both sides; it is in the ledger,
        // and the cost of the residual is whatever this host produced in that window -- usually
        // nothing, one chunk on a quiet session, several on a printing one, since `deliver` runs
        // once per PTY read -- after a socket drop that the fixed relay makes rare.
        let resuming = existing?.suspendedAt != nil
            && existing?.heldAtSequence == registration.sequence

        // The snapshot and the cut-off come out of the session under one lock, so the text and the
        // point in the byte stream it corresponds to cannot disagree.
        let (snapshot, cols, rows, fed) = registration.session.withTerminalAndOutputCount { terminal, count in
            guard !resuming else { return ("", terminal.cols, terminal.rows, count) }
            // The *primary* buffer, always: `absoluteRow` is the scrollback followed by whichever
            // screen is active, so while a full-screen program is up the rows this host's command
            // history lives on are in no transcript at all -- which cost an attaching client seven
            // blocks and gave it vim's tildes in their place (B3).
            let primaryRows = terminal.rowCount(of: .primary)
            let top = max(0, primaryRows - snapshotLines)
            // Without the trim, the blank rows under the host's cursor arrive as newlines and
            // scroll the host's screen off the top of the client's grid; see `RemoteSnapshot`.
            let primary = RemoteSnapshot.trimmingTrailingBlankLines(
                terminal.transcript(rows: top..<primaryRows, options: .forRestoring, buffer: .primary))
            // And the program on top of it, when there is one, with the host's cursor after it.
            let alternate = terminal.modes.altScreen
                ? RemoteSnapshot.trimmingTrailingBlankLines(
                    terminal.transcript(rows: 0..<terminal.rowCount(of: .alternate),
                                        options: .forRestoring, buffer: .alternate))
                : nil
            let cursor = terminal.modes.altScreen
                ? (row: terminal.cursor.y, col: terminal.cursor.x)
                : nil
            let text = RemoteSnapshot.compose(primary: primary, alternate: alternate, cursor: cursor)
            // A *second* snapshot into a mirror that already holds one used to be appended: 3308
            // rows against this host's 2007, and rows reading `nik@nik-newmac ~ % nik@nik-newmac ~
            // % …`. A re-snapshot replaces.
            return ((existing != nil ? RemoteSnapshot.reset : "") + text,
                    terminal.cols, terminal.rows, count)
        }
        // `fed` for a snapshot, `registration.sequence` for a resume, and the difference is the one
        // chunk that has been fed but whose tap has not run yet (`withTerminalAndOutputCount`
        // documents that window: the count moves with the feed, the tap runs after the lock is
        // dropped). A snapshot has that chunk inside its text, so `fed` is what must not be sent
        // again. A resume has no text at all, so `fed` would put the cut-off one *above* a chunk
        // still in flight: it would reach `deliver`, fail `startSequence <= sequence`, and be
        // dropped -- never snapshotted and never streamed. The resume has already proved that
        // nothing below `registration.sequence` was missed, so that is where it starts.
        //
        // `announcedSize` is the size `attached` is about to carry, so the next publish does not
        // repeat it to this client -- and, being per client, does not skip it for anybody else.
        registration.attachments[from] = Attachment(deviceID: from, e2e: e2e,
                                                    startSequence: resuming ? registration.sequence : fed,
                                                    suspendedAt: nil, heldAtSequence: nil,
                                                    announcedSize: GridSize(cols: cols, rows: rows))

        // Sealed before anything is sent, because half a snapshot is worse than none: the client
        // would draw a screen missing its middle and never know. A seal that fails here cannot
        // recover -- the cipher is per attachment -- so the attach is abandoned and said so in the
        // log, and the client, having had no `attached`, stays in `attaching` and can try again.
        guard let frames = chunked(Array(snapshot.utf8), sealedBy: e2e) else {
            registration.attachments[from] = nil
            announce(registration.arbiter.detached(from), in: registration, key: key)
            // Only if this device was ever announced as attached. A seal that fails on a *resume*
            // must not write the second half of a pair whose first half was never written.
            if existing == nil { audit(.detached(device: from, session: key)) }
            return
        }
        link.send(.attached(to: from, sessionID: key, ephemeralPubkey: signed.pubkey, sig: signed.sig,
                            role: Self.name(role), cols: cols, rows: rows))
        for frame in frames { link.send(frame) }
        link.send(.snapshotEnd(to: from, sessionID: key))
        // One line per attachment, not one per reconnect. A device whose socket blinked never left
        // -- nothing was written when it went -- so writing "attached" when it comes back would be
        // half of a pair whose other half does not exist. The QA counted two such lines per client
        // per ninety-one seconds.
        if existing == nil { audit(.attached(device: from, session: key)) }
    }

    /// The relay's word about the devices this host is paired with.
    ///
    /// Two answers, not three. Offline is a socket that closed -- hold. `not_paired` is the peer
    /// saying it has removed this Mac, which is settled and immediate.
    ///
    /// **Online is deliberately not an answer.** A hold is released by the `attach` that replaces
    /// the `Attachment`, and by nothing else. Clearing it on a presence would open a window --
    /// from the broadcast until the client's `attach` actually lands, which is a relay round trip
    /// plus the client's own re-attach backoff -- in which `deliver` believes it has a live
    /// attachment, seals every chunk, and sends them to a relay that has not re-registered this
    /// client yet (`relay/hub.go:446-469` adds it back only when the host answers `attached`), so
    /// they are counted in `dropped_binary` and lost. The re-attach would then look like a clean
    /// resume and the mirror would be silently short. The sweep does not need this branch either:
    /// it guards on `suspendedAt` identity, and a re-attach replaces the whole `Attachment`.
    private func presence(_ m: RemoteMessage) {
        for device in m.devices ?? [] {
            if device.notPaired {
                dropAttachments(of: device.deviceID)
            } else if !device.online {
                suspend(device.deviceID)
            }
        }
    }

    /// Marks every attachment of `deviceID` as held, and arms the sweep that ends them if it does
    /// not come back. One timer per suspension, not one per session: a device is offline from all
    /// of them at once.
    ///
    /// **An attachment that is already held is left exactly as it is.** `presence` is a *snapshot*,
    /// not an event: `presenceFor` lists every peer the device declared, offline ones included
    /// (`relay/hub.go:161-172`), and `broadcastPresence` rebuilds and sends it whenever **any**
    /// mutually paired peer's presence changes (`:178-184`). So with three or more paired Macs --
    /// which is the feature's premise -- a *different* Mac opening its lid twenty seconds into this
    /// client's hold delivers another snapshot that still says this one is offline. Re-baselining on
    /// it would move `heldAtSequence` forward over the chunks the client actually missed and turn
    /// its re-attach into a resume with no snapshot: C1's defect again, reached through ordinary
    /// presence traffic. It would also arm a fresh timer with a fresh `suspendedAt` each time, so a
    /// client that never comes back but whose *peers* keep changing presence would never be swept
    /// and would hold the writer token for as long as the traffic lasted.
    ///
    /// Hold once. The first `suspendedAt` and the first `heldAtSequence` are the record, and the
    /// first timer is still pending with an identity check that still matches.
    ///
    /// `baselineIsTrustworthy` is whether `registration.sequence` still means "the client's mirror
    /// is complete up to here". It is true for a hold taken because the *client's* socket closed,
    /// which is what `sequence` counts deliveries to. It is false for the one caller whose own
    /// socket is the one that went: see `linkDidReconnect`. A hold with no baseline can never
    /// resume, which is exactly what it is for.
    private func suspend(_ deviceID: String, baselineIsTrustworthy: Bool = true) {
        let now = clock.now()
        var held = false
        for key in order {
            guard let registration = registrations[key],
                  let attachment = registration.attachments[deviceID],
                  attachment.suspendedAt == nil else { continue }
            registration.attachments[deviceID]?.suspendedAt = now
            // Per registration, because `sequence` is: a device attached to two of this Mac's
            // sessions is held on both, and each one remembers its own session's chunk number.
            registration.attachments[deviceID]?.heldAtSequence =
                baselineIsTrustworthy ? registration.sequence : nil
            held = true
        }
        // False when everything was already held, and then no second timer is armed -- which is the
        // whole point of the guard above.
        guard held else { return }
        // One tick past the window, so the sweep and a re-attach that arrives at the last second
        // cannot both believe they were first.
        clock.after(reattachWindow + 1) { [weak self] in
            self?.queue.async { self?.sweep(deviceID, suspendedAt: now) }
        }
    }

    /// The window closed and the device did not come back, so now it really has gone: the
    /// attachment ends, the token moves, and *this* is where the audit line is written.
    ///
    /// `suspendedAt` is the identity check. A device that dropped, returned and dropped again has a
    /// newer suspension, and this timer belongs to the older one -- without the comparison the
    /// first drop's minute would end the second drop's attachment twenty seconds into its own.
    private func sweep(_ deviceID: String, suspendedAt: Date) {
        for key in order {
            guard let registration = registrations[key],
                  registration.attachments[deviceID]?.suspendedAt == suspendedAt else { continue }
            registration.attachments[deviceID] = nil
            announce(registration.arbiter.detached(deviceID), in: registration, key: key)
            audit(.detached(device: deviceID, session: key))
        }
    }

    /// Removes a device from *every* session it is attached to, which is right for the two callers
    /// that have it: a device the user has removed, or one the peer says has removed this Mac, is
    /// gone from all of them at once, and there will be no `detach` for any of them. `detach` itself
    /// is per session.
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

    /// One session, named by `session_id` -- never the device's other attachments. A client with two
    /// of this host's sessions open in two tabs closes one of them, and the other must not notice:
    /// the wire contract makes `detach` per session and spec 5.4 says detaching affects nothing
    /// else, so a device-wide sweep here would take the second tab down with no `session_ended` and
    /// no `role`, leaving it on a screen that simply stops moving.
    ///
    /// Like `takeControl` it re-checks the pairing rather than trusting the attachment alone: a
    /// device unpaired while attached must not be able to move the writer token or tear anything
    /// down afterwards, and the relay has no way to know the user has just removed it.
    private func detach(_ m: RemoteMessage) {
        guard let from = m.from, let key = m.sessionID, let registration = registrations[key],
              paired().contains(from),
              registration.attachments.removeValue(forKey: from) != nil else { return }
        announce(registration.arbiter.detached(from), in: registration, key: key)
        audit(.detached(device: from, session: key))
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
        var broken: [String] = []
        for deviceID in registration.attachments.keys.sorted() {
            guard let attachment = registration.attachments[deviceID],
                  attachment.startSequence <= sequence else { continue }
            // A held attachment has no socket: the relay dropped it when the device's own socket
            // went, so sealing and sending would be ~85 KB per client per cycle into nothing.
            // Nothing is recorded here -- `registration.sequence` was already incremented above,
            // which is what `heldAtSequence` is compared against at the re-attach.
            guard attachment.suspendedAt == nil else { continue }
            guard let frames = chunked(bytes, sealedBy: attachment.e2e) else {
                broken.append(deviceID)
                continue
            }
            for frame in frames { link.send(frame) }
        }
        // A cipher that cannot seal is a cipher that will never seal again (in practice only a
        // counter run to 2^64, so this is effectively unreachable) -- but sending nothing and
        // saying nothing would leave that client drawing a screen with a hole in it, silently,
        // since a receiver only checks that counters increase and cannot see a gap. Ending the
        // attachment is the honest version: the tab says the session ended and the user can attach
        // again, and the log says it happened.
        for deviceID in broken {
            registration.attachments[deviceID] = nil
            link.send(.sessionEnded(to: deviceID, sessionID: key))
            announce(registration.arbiter.detached(deviceID), in: registration, key: key)
            audit(.detached(device: deviceID, session: key))
        }
    }

    /// The catalogue as the relay is told it.
    ///
    /// The session id is stamped from the registration rather than taken from the summary. A pane
    /// registers before it has published anything about itself, so the very first catalogue after
    /// launch carried a summary with an empty `session_id` -- and the relay validates that field and
    /// rejects the *whole* message, so every Nyx launch answered its first publish with
    /// `bad_message` and the real catalogue only went out on the next update. It also makes a
    /// mismatch impossible: what a client attaches to is the id this host is keyed by.
    private func publishSessions() {
        link.send(.sessions(order.compactMap { key in
            guard var info = registrations[key]?.summary() else { return nil }
            info.sessionID = key
            return info
        }))
        announceSizes()
    }

    /// This host's window size, resent to everyone attached when it changes.
    ///
    /// `attached` carries it once and nothing carried it again, so a host resized while a client
    /// watched went on sending output laid out for its new width into a mirror still shaped like
    /// the old one, and every line wrapped (D2). `role` is what carries it: it already goes to
    /// every attached client of a session, it already names which device's role it is, and the
    /// relay already forwards it -- a message of its own would be a fifth thing to keep in step
    /// across two repositories. A held attachment is skipped: it has no socket, and its resume
    /// will carry the size in `attached`.
    ///
    /// Asked per attachment rather than per session, because "who has been told" is a fact about a
    /// client and not about a terminal: see `Attachment.announcedSize`.
    private func announceSizes() {
        for key in order {
            guard let registration = registrations[key] else { continue }
            let size = registration.session.withTerminal { GridSize(cols: $0.cols, rows: $0.rows) }
            for deviceID in registration.attachments.keys.sorted() {
                guard let attachment = registration.attachments[deviceID],
                      attachment.suspendedAt == nil, attachment.announcedSize != size else { continue }
                registration.attachments[deviceID]?.announcedSize = size
                let role = registration.arbiter.role(of: deviceID) ?? .observer
                link.send(.role(to: deviceID, sessionID: key, deviceID: deviceID,
                                role: Self.name(role), cols: size.cols, rows: size.rows))
            }
        }
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
