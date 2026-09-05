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

        public var onState: ((AttachState) -> Void)?
        /// Decrypted PTY output, in order, with the snapshot first. Called on the relay's thread.
        public var onBytes: (([UInt8]) -> Void)?

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
        /// Set by `detach()`: the owner has closed the tab, so nothing more is reported to it and
        /// nothing more is sent on its behalf, even if the relay is still delivering frames.
        private var finished = false

        init(sessionID: [UInt8], hostID: String, hostName: String, title: String,
             link: RelayLink, identity: DeviceIdentity) {
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
        public func send(_ input: [UInt8]) {
            lock.lock()
            guard !finished, _state.acceptsInput, let e2e, let frame = try? e2e.seal(input) else {
                lock.unlock()
                return
            }
            lock.unlock()
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
            lock.unlock()
            guard let signed else { return }
            link.send(.attach(to: hostID, sessionID: key, ephemeralPubkey: signed.pubkey, sig: signed.sig))
        }

        /// A session id that is not 16 bytes cannot be attached to: the relay would answer
        /// `no_such_session` and this tab would sit at "Attaching…" for ever. It says so instead.
        func failImmediately() {
            report { $0.phase = .ended(self.hostName) }
        }

        func handleAttached(_ m: RemoteMessage) {
            guard let pubkey = m.ephemeralPubkey, let sig = m.sig,
                  E2ESession.verifyPeer(pubkey: pubkey, sig: sig, sessionID: sessionID, deviceID: hostID) else {
                // The signature is the only thing distinguishing the host from the relay in the
                // middle of it: an unsigned or wrongly signed key is dropped and the tab stays in
                // `attaching`, rather than being decrypted by whoever sent it.
                return
            }
            lock.lock()
            guard !finished, let session = try? E2ESession(mine: ephemeral, peer: pubkey,
                                                           sessionID: sessionID, isHost: false) else {
                lock.unlock()
                return
            }
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

        func handle(_ frame: BinaryFrame) {
            lock.lock()
            guard !finished, !isEnded(_state.phase), let e2e, let bytes = try? e2e.open(frame) else {
                // A frame that will not open is a replay, a reorder, or a forgery. Dropping it is
                // the whole point of the counter: feeding it to the terminal would paint a screen
                // the host never had.
                lock.unlock()
                return
            }
            lock.unlock()
            onBytes?(bytes)
        }

        var isLive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !finished && !isEnded(_state.phase)
        }

        private func isEnded(_ phase: AttachState.Phase) -> Bool {
            if case .ended = phase { return true }
            return false
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
            lock.unlock()
            onState?(updated)
        }
    }

    private let link: RelayLink
    private let identity: DeviceIdentity
    private let paired: () -> PairedDevices
    private let lock = NSLock()
    /// Keyed by session id, which is all a data frame carries: two attachments to the same session
    /// id would be the same session, and the relay does not allow two hosts to own one.
    private var attachments: [String: Attachment] = [:]

    public init(link: RelayLink, identity: DeviceIdentity, paired: @escaping () -> PairedDevices) {
        self.link = link
        self.identity = identity
        self.paired = paired
    }

    public func attach(hostID: String, hostName: String, sessionID: [UInt8], title: String) -> Attachment {
        let attachment = Attachment(sessionID: sessionID, hostID: hostID, hostName: hostName,
                                    title: title, link: link, identity: identity)
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
