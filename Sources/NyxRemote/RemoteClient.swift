import CryptoKit
import Foundation
import NyxCore

/// This Mac attached to somebody else's session: it asks a paired host to attach, checks the host
/// really is that host, decrypts what comes back into an ordered byte stream, and sends what the
/// user types when it is allowed to.
///
/// Unlike `RemoteHost` this has no queue of its own. Everything it does is either short (a state
/// change, one authenticated decryption) or is the caller's own act (`send`, `detach`), and the
/// bytes must reach the pane in the order the relay delivered them -- a queue here would add a
/// second place for them to be reordered without making anything simpler. What it has instead is a
/// lock per attachment, because `E2ESession` counters and the attach state are read by the pane on
/// the main thread while the relay's queue is writing them.
///
/// `onBytes` and `onState` are therefore called on the relay's thread, never on main: the pane hops.
public final class RemoteClient {
    /// One attached remote session: everything a tab needs, and nothing about how it is drawn.
    public final class Attachment {
        public let sessionID: [UInt8]
        public let hostID: String
        /// Kept for the strip and the tab title after the session ends, when the host is gone.
        public let hostName: String

        /// Behind the same lock as everything else here, and not a plain stored property.
        ///
        /// The owner assigns these on the main thread, while the relay's queue *and* the attach
        /// timeout's queue are reading them in order to call back -- three threads on one
        /// unsynchronised closure slot. They are copied out under the lock and called outside it,
        /// because holding a lock across a call into a pane's redraw is how a UI freeze starts.
        public var onState: ((AttachState) -> Void)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _onState
            }
            set {
                lock.lock()
                _onState = newValue
                lock.unlock()
            }
        }

        /// Decrypted PTY output, in order, with the snapshot first. Called on the relay's thread.
        public var onBytes: (([UInt8]) -> Void)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _onBytes
            }
            set {
                lock.lock()
                _onBytes = newValue
                lock.unlock()
            }
        }

        /// The host's terminal size, from `attached`. The pane letterboxes or scrolls to it rather
        /// than resizing the host's window, which belongs to the person sitting in front of it.
        /// Behind the same lock as the state: the pane reads these on the main thread while the
        /// relay's thread is writing them.
        public var cols: Int {
            lock.lock()
            defer { lock.unlock() }
            return _cols
        }

        public var rows: Int {
            lock.lock()
            defer { lock.unlock() }
            return _rows
        }

        public var state: AttachState {
            lock.lock()
            defer { lock.unlock() }
            return _state
        }

        let key: String
        /// The client routes to this attachment by session id; `detach()` is how it stops, so the
        /// attachment has to be able to tell it. Weak: the app owns the client, and a tab that has
        /// gone must not keep it alive.
        weak var client: RemoteClient?
        private let link: RelayLink
        private let identity: DeviceIdentity
        private let lock = NSLock()
        private var _state: AttachState
        private var ephemeral: Curve25519.KeyAgreement.PrivateKey
        private var e2e: E2ESession?
        private var _cols = 0
        private var _rows = 0
        private var _onState: ((AttachState) -> Void)?
        private var _onBytes: (([UInt8]) -> Void)?
        /// Set by `detach()`: the owner has closed the tab, so nothing more is reported to it and
        /// nothing more is sent on its behalf, even if the relay is still delivering frames.
        private var finished = false
        /// The public half of the ephemeral key this attachment has an `attach` outstanding for,
        /// or nil when it has none. It is the round marker: cleared the moment an `attached` is
        /// accepted, so a second one inside the same round is dropped, and replaced by `begin()`,
        /// so an answer to the *previous* round -- the corner Task 7 parked -- is dropped too
        /// rather than building a cipher that decrypts nothing.
        private var awaiting: String?
        /// Every host ephemeral key this attachment has already built a cipher from.
        ///
        /// The host makes a fresh one per attach -- that is what forward secrecy per attachment
        /// means -- so a repeat is a replay by construction, whether the relay re-delivered it or
        /// somebody kept a copy. It is the only round marker on the wire: `attached` carries the
        /// host's key and no echo of ours, so nothing else in the message says which of this
        /// attachment's rounds it answers. One string per reconnect, so it does not grow.
        private var usedHostKeys: Set<String> = []
        /// Which attach round the outstanding timeout belongs to; a timer for a round that has
        /// already been answered or superseded does nothing.
        private var round = 0
        private let timeout: TimeInterval
        /// Timers only. `RemoteClient` deliberately has no queue of its own (see the type's note),
        /// and a delayed check is the one thing it cannot do without somewhere to run.
        private static let timers = DispatchQueue(label: "nyx.remote.client.timeout")

        init(sessionID: [UInt8], hostID: String, hostName: String, title: String,
             link: RelayLink, identity: DeviceIdentity, timeout: TimeInterval) {
            self.timeout = timeout
            self.sessionID = sessionID
            self.hostID = hostID
            self.hostName = hostName
            self.link = link
            self.identity = identity
            self.key = RemoteID.base64url(sessionID)
            self.ephemeral = E2ESession.ephemeral()
            self._state = AttachState(hostName: hostName, title: title)
        }

        /// Input the user typed. Dropped unless this client is the writer *and* the snapshot is
        /// over: a keystroke sent during the snapshot would arrive at the host out of the order the
        /// user saw, and one sent by an observer would be a keystroke the user was told was
        /// impossible.
        ///
        /// The seal and the transmit are one critical section, and deliberately so even though it
        /// means holding a lock across a call into the link. Counters are the order: two threads
        /// typing at once (a paste while a key repeats) that sealed under the lock and transmitted
        /// after it could arrive at the host in the other order, and the host -- which rejects
        /// anything at or below the last counter it accepted -- would drop the earlier keystroke
        /// for good. `RelayLink.send` only enqueues, so the section stays short.
        public func send(_ input: [UInt8]) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished, _state.acceptsInput, let e2e, let frame = try? e2e.seal(input) else { return }
            link.send(frame)
        }

        public func takeControl() {
            lock.lock()
            let ended = finished || isEnded(_state.phase)
            lock.unlock()
            guard !ended else { return }
            // The role does not change here. The host arbitrates and answers with `role`; deciding
            // locally would let two clients believe they are the writer at the same time.
            link.send(.takeControl(to: hostID, sessionID: key))
        }

        /// The tab was closed. Tells the host, and stops: no further state is reported to an owner
        /// that has gone, and late frames are dropped rather than decrypted.
        public func detach() {
            lock.lock()
            let alreadyFinished = finished
            finished = true
            lock.unlock()
            guard !alreadyFinished else { return }
            link.send(.detach(to: hostID, sessionID: key))
            client?.forget(key)
        }

        // MARK: - Driven by RemoteClient

        /// Sends `attach` with a freshly signed ephemeral key. Called once at attach and again
        /// after every reconnect -- a new key each time, which is what makes one attachment's
        /// traffic unreadable even to someone who later learns this device's identity key.
        func begin() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            ephemeral = E2ESession.ephemeral()
            e2e = nil
            let signed = try? E2ESession.signedPublicKey(ephemeral, sessionID: sessionID, identity: identity)
            awaiting = signed?.pubkey
            round += 1
            let thisRound = round
            lock.unlock()
            // Armed even when the signing failed and nothing was sent: with no `attach` on the wire
            // there will certainly be no answer, and the tab must say so rather than sit in
            // "Attaching…" for the rest of its life.
            Attachment.timers.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.attachTimedOut(round: thisRound)
            }
            guard let signed else { return }
            link.send(.attach(to: hostID, sessionID: key, ephemeralPubkey: signed.pubkey, sig: signed.sig))
        }

        /// Nothing came back for this round. Neither `attached` nor `error` -- the relay may have
        /// dropped the message, or the host may have gone between the presence update that put the
        /// row in the palette and the attach itself.
        private func attachTimedOut(round: Int) {
            lock.lock()
            let stale = finished || round != self.round || awaiting == nil
            lock.unlock()
            guard !stale else { return }
            report(if: { self.isAwaitingAttach($0.phase) }) { $0.phase = .failed(AttachFailure.noAnswer) }
        }

        /// The relay refused the attach: `host_offline`, `not_paired`, `no_such_session`,
        /// `too_many`. Only while an attach is outstanding -- an error that arrives after the
        /// session is live is about something else, and must not close a working tab.
        func handleError(code: String) {
            report(if: { self.isAwaitingAttach($0.phase) }) {
                $0.phase = .failed(AttachFailure.text(code: code))
            }
        }

        /// A session id that is not 16 bytes cannot be attached to: the relay would answer
        /// `no_such_session` and this tab would sit at "Attaching…" for ever. It says so instead.
        func failImmediately() {
            report { $0.phase = .ended(self.hostName) }
        }

        /// The host's answer to *this* attach. Accepted only while one is outstanding: a relay that
        /// re-delivers an `attached`, or an attacker replaying one, would otherwise rebuild the
        /// cipher from the same two ephemeral keys -- the same session keys, with the replay window
        /// wound back to the start -- so every frame of the session so far could be played into the
        /// terminal again, and the tab would fall from `live` back to `snapshot` while the live
        /// stream carried on.
        func handleAttached(_ m: RemoteMessage) {
            guard let pubkey = m.ephemeralPubkey, let sig = m.sig,
                  E2ESession.verifyPeer(pubkey: pubkey, sig: sig, sessionID: sessionID, deviceID: hostID) else {
                // The signature is the only thing distinguishing the host from the relay in the
                // middle of it: an unsigned or wrongly signed key is dropped and the tab stays in
                // `attaching`, rather than being decrypted by whoever sent it.
                return
            }
            // Checked before the cipher is built, and fatal to the attachment rather than merely
            // ignored: the size is what the mirror `Terminal` is resized to on the main thread, and
            // an `attached` this far outside the possible is not a host with an odd window -- it is
            // a message this client has no reason to trust the rest of either.
            guard AttachGeometry.isSane(cols: m.cols ?? 0, rows: m.rows ?? 0) else {
                // The host still believes it has a viewer, and a stranded attachment holds the
                // writer token; this side is leaving, so it says so before it stops listening.
                link.send(.detach(to: hostID, sessionID: key))
                end(reason: AttachFailure.badGeometry)
                client?.forget(key)
                return
            }
            lock.lock()
            // `awaiting` is what makes this one round's answer rather than any round's: it is set
            // by `begin()` and cleared here, so a duplicate inside this round and an answer to the
            // previous round are both dropped, whichever order they arrive in.
            guard !finished, isAwaitingAttach(_state.phase), awaiting != nil,
                  !usedHostKeys.contains(pubkey),
                  let session = try? E2ESession(mine: ephemeral, peer: pubkey,
                                                sessionID: sessionID, isHost: false) else {
                lock.unlock()
                return
            }
            awaiting = nil
            usedHostKeys.insert(pubkey)
            e2e = session
            _cols = m.cols ?? _cols
            _rows = m.rows ?? _rows
            lock.unlock()
            report {
                $0.phase = .snapshot
                $0.role = m.role == "writer" ? .writer : .observer
            }
        }

        func handleSnapshotEnd() {
            report(if: { $0.phase == .snapshot }) { $0.phase = .live }
        }

        func handleRole(_ role: String) {
            report { $0.role = role == "writer" ? .writer : .observer }
        }

        func handleSessionEnded() {
            report(if: { !self.isEnded($0.phase) }) { $0.phase = .ended(self.hostName) }
        }

        /// Another attachment has taken over this session id. This one is dead -- the client routes
        /// by session id, and the host keys its attachments by device and session, so nothing will
        /// ever be delivered here again. It deliberately does not send `detach`: on the host that
        /// would tear down the attachment that just replaced it.
        func displace() {
            report(if: { !self.isEnded($0.phase) }) { $0.phase = .ended(self.hostName) }
            lock.lock()
            finished = true
            lock.unlock()
        }

        func handleReconnect() {
            report(if: { !self.isEnded($0.phase) }) { $0.phase = .reconnecting }
            begin()
        }

        /// The socket went. Deliberately does *not* re-attach: there is nothing to send it on, so an
        /// `attach` now would only sit in the outbox and go out behind the one `handleReconnect`
        /// sends when the socket is back. All this does is stop the tab looking live -- which stops
        /// `acceptsInput`, and with it every keystroke that would otherwise be sealed with a cipher
        /// the host has already forgotten and flushed at it minutes later.
        func handleDisconnect() {
            report(if: { !self.isEnded($0.phase) }) { $0.phase = .reconnecting }
        }

        /// This side stopped: remote sessions were switched off, or the relay this Mac talks to
        /// changed. Nothing on the host ended, so the reason is the whole sentence rather than a
        /// machine name.
        func end(reason: String) {
            report(if: { !self.isEnded($0.phase) }) { $0.phase = .failed(reason) }
            lock.lock()
            finished = true
            lock.unlock()
        }

        func handle(_ frame: BinaryFrame) {
            lock.lock()
            guard !finished, !isEnded(_state.phase), let e2e, let bytes = try? e2e.open(frame) else {
                // A frame that will not open is a replay, a reorder, or a forgery. Dropping it is
                // the whole point of the counter: feeding it to the terminal would paint a screen
                // the host never had.
                lock.unlock()
                return
            }
            let deliver = _onBytes
            lock.unlock()
            deliver?(bytes)
        }

        var isLive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !finished && !isEnded(_state.phase)
        }

        /// The two phases in which an `attached` is something this client asked for: the first
        /// attach, and the re-attach after a reconnect. In `snapshot` and `live` the handshake is
        /// over, and in `ended` there is nothing left to attach to.
        ///
        /// It is not enough on its own: an `attached` from the *previous* round, replayed while
        /// this attachment is `reconnecting`, is also one this phase would allow, and the cipher it
        /// builds pairs the new ephemeral key with the old round's -- decrypting nothing the host
        /// now sends, so the tab would sit at `snapshot` for ever. `awaiting` and `usedHostKeys`
        /// are what close that, and `attachTimedOut` is what catches a round nothing answers.
        private func isAwaitingAttach(_ phase: AttachState.Phase) -> Bool {
            phase == .attaching || phase == .reconnecting
        }

        /// Both of the phases from which nothing more will ever arrive: the session stopped, or it
        /// was never reached. Frames, roles and `session_ended` are all dropped in either.
        private func isEnded(_ phase: AttachState.Phase) -> Bool {
            switch phase {
            case .ended, .failed: return true
            case .attaching, .snapshot, .live, .reconnecting: return false
            }
        }

        /// Mutates the state under the lock and reports it outside: `onState` redraws a tab, and
        /// holding a lock across a caller's redraw is how a UI freeze starts.
        private func report(if condition: ((AttachState) -> Bool)? = nil, _ change: (inout AttachState) -> Void) {
            lock.lock()
            guard !finished, condition?(_state) ?? true else {
                lock.unlock()
                return
            }
            var updated = _state
            change(&updated)
            guard updated != _state else {
                lock.unlock()
                return
            }
            _state = updated
            let report = _onState
            lock.unlock()
            report?(updated)
        }
    }

    private let link: RelayLink
    private let identity: DeviceIdentity
    private let paired: () -> PairedDevices
    private let attachTimeout: TimeInterval
    private let lock = NSLock()
    /// Keyed by session id, which is all a data frame carries: two attachments to the same session
    /// id would be the same session, and the relay does not allow two hosts to own one.
    private var attachments: [String: Attachment] = [:]

    /// `attachTimeout` is a parameter so a test can watch an unanswered attach fail in a tenth of a
    /// second rather than in fifteen. The default is long enough for a relay and a host that are
    /// merely slow (the relay allows itself 10 s per handshake step) and short enough that a person
    /// is not left reading "Attaching…" wondering whether it is working.
    public init(link: RelayLink, identity: DeviceIdentity, paired: @escaping () -> PairedDevices,
                attachTimeout: TimeInterval = 15) {
        self.link = link
        self.identity = identity
        self.paired = paired
        self.attachTimeout = attachTimeout
    }

    public func attach(hostID: String, hostName: String, sessionID: [UInt8], title: String) -> Attachment {
        let attachment = Attachment(sessionID: sessionID, hostID: hostID, hostName: hostName,
                                    title: title, link: link, identity: identity,
                                    timeout: attachTimeout)
        guard sessionID.count == 16 else {
            attachment.failImmediately()
            return attachment
        }
        attachment.client = self
        lock.lock()
        let displaced = attachments[attachment.key]
        attachments[attachment.key] = attachment
        lock.unlock()
        displaced?.displace()
        attachment.begin()
        return attachment
    }

    public func handle(_ m: RemoteMessage) {
        // The relay's own refusals, which have no `from` -- the relay is not a device. They are
        // routed by the `session_id` the relay echoes back; a pairing error carries none and
        // belongs to the pairing sheet, not to any tab.
        if m.t == "error" {
            guard let key = m.sessionID, let attachment = self[key],
                  m.to == nil || m.to == attachment.hostID else { return }
            attachment.handleError(code: m.code ?? "")
            return
        }
        guard let key = m.sessionID, let from = m.from, let attachment = self[key],
              attachment.hostID == from else { return }
        switch m.t {
        case "attached":
            // A host we have not paired with is a host whose signature means nothing, whatever the
            // relay says about it.
            guard paired().contains(from) else { return }
            attachment.handleAttached(m)
        case "snapshot_end":
            attachment.handleSnapshotEnd()
        case "role":
            // The host tells every attached client about every change, so this is only ours if it
            // names this device.
            guard m.deviceID == link.deviceID, let role = m.role else { return }
            attachment.handleRole(role)
        case "session_ended":
            attachment.handleSessionEnded()
            forget(key)
        default:
            break
        }
    }

    public func handle(_ f: BinaryFrame) {
        self[RemoteID.base64url(f.sessionID)]?.handle(f)
    }

    /// The socket came back. The relay dropped every attachment when it went, so each live one asks
    /// again from the beginning: `reconnecting` on the strip, a new ephemeral key, and a fresh
    /// snapshot -- which is also the only way to catch up on what was printed while it was down.
    public func linkDidReconnect() {
        lock.lock()
        let live = attachments.values.filter { $0.isLive }
        lock.unlock()
        for attachment in live { attachment.handleReconnect() }
    }

    /// The socket dropped. Every live attachment says "Reconnecting…" and stops accepting input
    /// until `linkDidReconnect` gets an answer from the host again.
    ///
    /// Without this a client whose network went sat at `live`, still taking keystrokes: they were
    /// sealed with the pre-drop cipher, queued in the connection's outbox, and delivered after the
    /// reconnect had rotated the keys -- so the host dropped them, and the person typing had no way
    /// to know anything had happened at all.
    public func linkDidDisconnect() {
        lock.lock()
        let live = attachments.values.filter { $0.isLive }
        lock.unlock()
        for attachment in live { attachment.handleDisconnect() }
    }

    /// Ends every attachment with one reason and forgets them. For an owner that is going away:
    /// remote sessions switched off, or a relay setting changed under a live connection.
    public func endAll(reason: String) {
        lock.lock()
        let live = attachments.values.filter { $0.isLive }
        attachments.removeAll()
        lock.unlock()
        for attachment in live { attachment.end(reason: reason) }
    }

    /// Ends every attachment to one host, and forgets them. For a device the user has just
    /// unpaired: the tabs are this Mac's own, and one left live would go on decrypting the screen
    /// of a device its owner has said they no longer trust.
    ///
    /// Deliberately silent on the wire. The host is told by the relay -- the `paired` list it is
    /// sent no longer contains this device -- and a `detach` to a device that is no longer paired
    /// would be refused by that same check anyway.
    public func endAll(matching hostID: String, reason: String) {
        lock.lock()
        let live = attachments.values.filter { $0.isLive && $0.hostID == hostID }
        for attachment in live { attachments[attachment.key] = nil }
        lock.unlock()
        for attachment in live { attachment.end(reason: reason) }
    }

    /// Stops routing to an attachment: its tab is gone (`detach()`) or its session ended.
    fileprivate func forget(_ key: String) {
        lock.lock()
        attachments[key] = nil
        lock.unlock()
    }

    private subscript(key: String) -> Attachment? {
        lock.lock()
        defer { lock.unlock() }
        return attachments[key]
    }
}
