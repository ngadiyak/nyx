import Foundation
import NyxCore

/// Everything a `RelayConnection` hands back. Every call arrives on the connection's own serial
/// queue, never on the main thread: the connection has no idea whether its owner is a view (which
/// must hop to main) or a background orchestrator (which must not), so it does not guess.
public protocol RelayConnectionDelegate: AnyObject {
    func relay(_ connection: RelayConnection, didChange status: RelayConnection.Status)
    func relay(_ connection: RelayConnection, didReceive message: RemoteMessage)
    func relay(_ connection: RelayConnection, didReceive frame: BinaryFrame)
}

/// What is waiting to go out while the socket is down. Bounded and oldest-dropped rather than
/// unbounded: a Mac that has been offline for an hour must not come back and replay an hour of
/// stale presence and catalogue updates, and it must not have spent that hour growing an array.
/// The newest frames are the ones worth keeping -- a `sessions` list from a minute ago is wrong.
struct RelayOutbox {
    enum Frame: Equatable {
        case text(RemoteMessage)
        case binary(BinaryFrame)
    }

    private(set) var frames: [Frame] = []
    /// How many frames the bound has thrown away since the last drain, so a caller can tell the
    /// difference between "nothing was sent" and "something was silently lost".
    private(set) var dropped = 0
    let limit: Int

    init(limit: Int = 256) {
        self.limit = limit
    }

    mutating func append(_ frame: Frame) {
        frames.append(frame)
        while frames.count > limit {
            frames.removeFirst()
            dropped += 1
        }
    }

    mutating func drain() -> [Frame] {
        let out = frames
        frames = []
        dropped = 0
        return out
    }

    mutating func clear() {
        frames = []
        dropped = 0
    }
}

/// The device's one socket to the relay: the handshake of spec §6.1, reconnection with backoff, and
/// delivery of decoded control messages and binary data frames to a delegate.
///
/// All mutable state lives on one serial queue and is only ever touched there. That is not
/// decoration: `URLSessionWebSocketTask` calls back on URLSession's own queue, the timers fire on
/// theirs, and the app sends from the main thread, so without a single owner every field here would
/// be a race. `status` and `droppedWhileOffline` are the exceptions -- they are read from the main
/// thread to draw, so they sit behind a lock of their own rather than a `queue.sync`, which would
/// deadlock the moment a delegate callback (already on the queue) read one.
///
/// **Liveness** is the relay's job, not this class's. The relay pings every 30 s and
/// `URLSessionWebSocketTask` answers those itself, which keeps the socket warm through NAT and
/// proxies *and* is what the relay's own liveness watchdog reads: a socket with nothing to say
/// stays open, and one that stops answering pings is closed within 90 s. (Until 2026-09-11 the
/// relay measured *silence* instead -- `coder/websocket`'s Read returns on a data message only --
/// so it closed every idle session every ninety-one seconds, and this comment described that as
/// the contract.) A socket that has gone half-open is noticed by the next receive or send that
/// fails -- there is deliberately no client-side ping, because one would only duplicate the
/// relay's timer while adding a second way for a healthy connection to be declared dead.
public final class RelayConnection {
    public enum Status: Equatable {
        case offline
        case connecting
        case authenticating
        case online
        /// The relay refused this device and reconnecting cannot help: `bad_token`,
        /// `bad_signature`, or `replaced` -- the last meaning another connection presented the same
        /// device id, which is why two Nyx instances must never share one identity file. Only an
        /// explicit `connect()` leaves this state.
        case failed(String)
    }

    private let url: URL
    private let token: String
    private let identity: DeviceIdentity
    private let deviceName: String
    private let session: URLSession
    private let queue = DispatchQueue(label: "nyx.relay")
    private let handshakeTimeout: TimeInterval

    private let delegateLock = NSLock()
    private weak var storedDelegate: RelayConnectionDelegate?
    /// Weakly held, and behind a lock because it is set from the main thread while the relay queue
    /// is reading it in order to call back. The lock makes the *access* safe, not ordered: a
    /// callback the queue had already read the delegate for can still arrive after the setter
    /// returns, so an owner tearing down must tolerate one late call. (Being weak, an owner that
    /// has actually been deallocated is simply never called.)
    public var delegate: RelayConnectionDelegate? {
        get {
            delegateLock.lock()
            defer { delegateLock.unlock() }
            return storedDelegate
        }
        set {
            delegateLock.lock()
            storedDelegate = newValue
            delegateLock.unlock()
        }
    }

    private let statusLock = NSLock()
    private var lockedStatus: Status = .offline
    private var lockedDropped = 0

    public var status: Status {
        statusLock.lock()
        defer { statusLock.unlock() }
        return lockedStatus
    }

    /// How many frames the send queue threw away during the most recent stretch of being offline.
    /// It is set as the queue overflows and cleared when a new offline stretch starts filling the
    /// queue again, so an owner that reads it while handling `.online` sees what the outage cost --
    /// which is the only moment there is anything honest to tell the user.
    public var droppedWhileOffline: Int {
        statusLock.lock()
        defer { statusLock.unlock() }
        return lockedDropped
    }

    // Queue-only state below.
    private var task: URLSessionWebSocketTask?
    private var handshake: RelayHandshake?
    private var deadline: HandshakeDeadline?
    private var authenticated = false
    private var wantsConnection = false
    private var backoff: Backoff
    private var outbox = RelayOutbox()
    /// Bumped every time a socket is opened or torn down. Every callback and timer carries the
    /// epoch it was armed in and does nothing if it no longer matches -- a `URLSessionWebSocketTask`
    /// completion for a socket that was cancelled two reconnects ago still arrives, and without
    /// this it would report the live connection as dropped.
    private var epoch = 0

    /// `handshakeTimeout` and `backoff` are parameters, not constants, so a test can drive the
    /// deadline and the reconnect delays in a second rather than in a minute. The defaults are what
    /// ships: the relay allows itself 10 s per handshake step, so 25 s is comfortably past a relay
    /// that is merely slow and well short of a user deciding the app is broken.
    public init(url: URL, token: String, identity: DeviceIdentity, deviceName: String,
                session: URLSession = .shared, handshakeTimeout: TimeInterval = 25,
                backoff: Backoff = Backoff()) {
        self.url = url
        self.token = token
        self.identity = identity
        self.deviceName = deviceName
        self.session = session
        self.handshakeTimeout = handshakeTimeout
        self.backoff = backoff
    }

    deinit {
        // The receive loop holds only a weak reference to this object, so without this the socket
        // would stay open until the relay's 90 s idle timeout noticed nobody was home.
        task?.cancel(with: .goingAway, reason: nil)
    }

    public var deviceID: String { identity.deviceID }

    /// The user's gesture: the "Reconnect" button, or enabling remote sessions. Idempotent -- while
    /// connecting or online it does nothing -- and it is the only way out of `failed`. It also
    /// starts the reconnect delays over, because someone who has just fixed the relay token or
    /// rejoined a network should not wait out a 60 s delay earned by an outage that is over.
    /// Anything that fires on its own schedule wants `ensureConnected()` instead.
    public func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = true
            guard self.task == nil else { return }
            self.backoff.reset()
            self.openSocket()
        }
    }

    /// Connect if not already connecting, without resetting the backoff. For callers that run on
    /// somebody else's schedule -- a wake-from-sleep notification, a network-path change, a periodic
    /// check -- where treating every trigger as a user gesture would defeat the backoff entirely and
    /// hammer a relay that is down. Like `connect()` it does not disturb a live socket; unlike
    /// `connect()` it does not resurrect a `failed` connection on its own.
    public func ensureConnected() {
        queue.async { [weak self] in
            guard let self, self.task == nil else { return }
            if case .failed = self.status { return }
            self.wantsConnection = true
            self.openSocket()
        }
    }

    /// Stops for good until `connect()` is called again: any pending reconnect is cancelled, and
    /// anything still queued is dropped, because frames queued for a session the user has ended are
    /// not worth replaying whenever the connection next comes back.
    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = false
            self.closeSocket()
            self.backoff.reset()
            self.outbox.clear()
            self.setDropped(0)
            self.setStatus(.offline)
        }
    }

    /// Queued while the connection is not yet authenticated and flushed after `welcome`, so callers
    /// never have to ask whether the socket is up; see `RelayOutbox` for what happens when the
    /// queue is full and `droppedWhileOffline` for how to find out that it did.
    public func send(_ message: RemoteMessage) { enqueue(.text(message)) }

    public func send(_ frame: BinaryFrame) { enqueue(.binary(frame)) }

    /// The reconnect delays as they stand. Read on the queue that owns them, so a test sees the
    /// state after every call it has already made rather than a torn one.
    var backoffForTesting: Backoff { queue.sync { backoff } }

    /// Winds the delays forward the way that many failed attempts would, without the minutes of
    /// real waiting that earning them takes.
    func advanceBackoffForTesting(times: Int) {
        queue.sync { for _ in 0..<times { _ = backoff.next() } }
    }

    /// Which of the relay's private close codes (the server plan's "Close codes") mean this device
    /// must stop rather than reconnect. Pure so the mapping is testable: the socket that carries
    /// these is the one case where the relay says why without sending a message first.
    static func terminalStatus(forCloseCode raw: Int) -> Status? {
        switch raw {
        case 4000: return .failed("replaced")
        case 4401: return .failed("bad_token")
        case 4403: return .failed("bad_signature")
        default: return nil
        }
    }

    // MARK: - The socket

    private func enqueue(_ frame: RelayOutbox.Frame) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.authenticated, self.task != nil {
                self.write(frame, epoch: self.epoch)
            } else {
                // An empty queue means a new offline stretch is starting, so what the last one lost
                // stops being the current answer.
                if self.outbox.frames.isEmpty { self.setDropped(0) }
                self.outbox.append(frame)
                self.setDropped(self.outbox.dropped)
            }
        }
    }

    private func openSocket() {
        epoch += 1
        let armed = epoch
        // Deliberately not an URLRequest with a `timeoutInterval`: on a WebSocket task that becomes
        // an idle timeout on an established socket, which would tear down a healthy but quiet
        // connection between the relay's 30 s pings. `HandshakeDeadline` is armed instead.
        let socket = session.webSocketTask(with: url)
        task = socket
        authenticated = false
        handshake = RelayHandshake(deviceID: identity.deviceID) { [identity] message in
            try? identity.sign(message)
        }
        deadline = HandshakeDeadline(startedAt: Self.now(), timeout: handshakeTimeout)
        setStatus(.connecting)
        socket.resume()
        write(.text(RelayHandshake.hello(deviceID: identity.deviceID, deviceName: deviceName, token: token)),
              epoch: armed)
        receiveNext(epoch: armed)
        armHandshakeDeadline(epoch: armed, after: handshakeTimeout)
    }

    /// The timer decides when to look; `HandshakeDeadline` decides what the answer is. If the wake
    /// is early -- `asyncAfter` guarantees no upper bound, only a lower one, but a suspended and
    /// resumed Mac can make wall-clock and dispatch time disagree either way -- it re-arms for
    /// whatever is left rather than giving up on the deadline entirely.
    private func armHandshakeDeadline(epoch armed: Int, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, armed == self.epoch, let deadline = self.deadline, !self.authenticated else { return }
            let now = Self.now()
            if deadline.hasExpired(at: now, authenticated: self.authenticated) {
                self.drop(epoch: armed)
            } else {
                self.armHandshakeDeadline(epoch: armed, after: max(0.01, deadline.remaining(at: now)))
            }
        }
    }

    private static func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// Returns the close code the peer sent, read *before* the cancel below replaces it with ours.
    @discardableResult
    private func closeSocket() -> Int {
        epoch += 1
        let peerCode = task?.closeCode.rawValue ?? 0
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        handshake = nil
        deadline = nil
        authenticated = false
        return peerCode
    }

    private func write(_ frame: RelayOutbox.Frame, epoch armed: Int) {
        guard let socket = task, armed == epoch else { return }
        let message: URLSessionWebSocketTask.Message
        switch frame {
        case .text(let envelope):
            message = .string(String(decoding: envelope.encoded(), as: UTF8.self))
        case .binary(let binary):
            message = .data(Data(binary.bytes))
        }
        socket.send(message) { [weak self] error in
            guard let self, error != nil else { return }
            self.queue.async { self.drop(epoch: armed) }
        }
    }

    private func receiveNext(epoch armed: Int) {
        guard let socket = task, armed == epoch else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard armed == self.epoch else { return }
                switch result {
                case .failure:
                    self.drop(epoch: armed)
                case .success(let message):
                    self.handle(message, epoch: armed)
                    self.receiveNext(epoch: armed)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, epoch armed: Int) {
        switch message {
        case .data(let data):
            // A binary frame shorter than its 24-byte header cannot be routed to a session at all;
            // dropping it is what the relay does with the same bytes.
            guard authenticated, let frame = BinaryFrame([UInt8](data)) else { return }
            delegate?.relay(self, didReceive: frame)
        case .string(let text):
            guard let envelope = try? RemoteMessage.decode(Data(text.utf8)) else { return }
            deliver(envelope, epoch: armed)
        @unknown default:
            return
        }
    }

    /// Handshake messages are consumed here and never reach the delegate: the status change is what
    /// says the handshake succeeded, and an owner that had to recognise `challenge` and `welcome`
    /// itself would be able to get the sequence wrong. Once authenticated, everything is passed on
    /// verbatim -- including `error`, which after `welcome` is about one request (`pair_expired`,
    /// `not_paired`) and says nothing about the health of the connection.
    private func deliver(_ message: RemoteMessage, epoch armed: Int) {
        if authenticated {
            delegate?.relay(self, didReceive: message)
            return
        }
        guard var pending = handshake else { return }
        let outcome = pending.receive(message)
        handshake = pending
        switch outcome {
        case .send(let reply):
            write(.text(reply), epoch: armed)
            setStatus(.authenticating)
        case .online:
            authenticated = true
            deadline = nil
            backoff.reset()
            // Flushed before the status change so that anything the delegate sends on hearing
            // `.online` goes out behind what was queued while the socket was down, not in front.
            for frame in outbox.drain() { write(frame, epoch: armed) }
            setStatus(.online)
        case .rejected(let code):
            closeSocket()
            wantsConnection = false
            setStatus(.failed(code))
        case .retryableError, .protocolError:
            drop(epoch: armed)
        }
    }

    /// One dropped socket: tear it down, say so, and arm the next attempt. Called from four places
    /// (a read error, a write error, a handshake that never finished, a retryable refusal) so that
    /// all four produce exactly one status change and at most one scheduled reconnect.
    private func drop(epoch armed: Int) {
        guard armed == epoch, task != nil else { return }
        let peerCode = closeSocket()
        // The relay says `bad_token`/`bad_signature` in a message first, so those are normally
        // handled by `deliver`; this is the backstop, and the only path for 4000 "replaced", which
        // the relay closes on without sending anything at all.
        if let terminal = Self.terminalStatus(forCloseCode: peerCode) {
            wantsConnection = false
            setStatus(terminal)
            return
        }
        setStatus(.offline)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard wantsConnection else { return }
        let delay = backoff.next()
        let armed = epoch
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, armed == self.epoch, self.wantsConnection, self.task == nil else { return }
            self.openSocket()
        }
    }

    private func setStatus(_ new: Status) {
        statusLock.lock()
        let changed = lockedStatus != new
        lockedStatus = new
        statusLock.unlock()
        guard changed else { return }
        delegate?.relay(self, didChange: new)
    }

    private func setDropped(_ count: Int) {
        statusLock.lock()
        lockedDropped = count
        statusLock.unlock()
    }
}

public extension RelayConnection.Status {
    /// How the settings page and the palette's Remote section describe this connection.
    ///
    /// The mapping is here rather than in `NyxApp` because it is the one place that knows both
    /// types: `RemoteStatusText.Connection` is Core's (and Core may not import CryptoKit, so it
    /// cannot see this enum at all), and this is `NyxRemote`'s. `relayHost` is the relay URL's
    /// host, which only the owner of the configuration knows.
    ///
    /// `offline` maps to "unreachable" rather than to a state of its own: from the page's point of
    /// view a socket that is down and being retried and one that has never come up are the same
    /// thing -- the relay is not answering.
    func statusText(relayHost: String) -> RemoteStatusText.Connection {
        switch self {
        case .offline: return .unreachable(host: relayHost)
        case .connecting, .authenticating: return .connecting
        case .online: return .online
        case .failed(let code): return code == "bad_token" ? .badToken : .refused(code)
        }
    }
}
