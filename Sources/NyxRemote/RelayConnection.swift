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

/// The device's one socket to the relay: the handshake of spec §6.1, a heartbeat, reconnection with
/// backoff, and delivery of decoded control messages and binary data frames to a delegate.
///
/// All mutable state lives on one serial queue and is only ever touched there. That is not
/// decoration: `URLSessionWebSocketTask` calls back on URLSession's own queue, the timers fire on
/// theirs, and the app sends from the main thread, so without a single owner every field here would
/// be a race. `status` is the one exception -- it is read from the main thread to draw, so it sits
/// behind a lock of its own rather than a `queue.sync`, which would deadlock the moment a delegate
/// callback (already on the queue) read it.
public final class RelayConnection {
    public enum Status: Equatable {
        case offline
        case connecting
        case authenticating
        case online
        /// The relay refused this device: `bad_token`, `bad_signature`. No amount of reconnecting
        /// fixes either, so this state does not retry -- only an explicit `connect()` leaves it.
        case failed(String)
    }

    private let url: URL
    private let token: String
    private let identity: DeviceIdentity
    private let deviceName: String
    private let session: URLSession
    private let queue = DispatchQueue(label: "nyx.relay")

    private let delegateLock = NSLock()
    private weak var storedDelegate: RelayConnectionDelegate?
    /// Weakly held, and behind a lock because it is set from the main thread while the relay queue
    /// is reading it to call back. (Computed rather than a `weak var` for exactly that reason -- a
    /// plain stored property here is a data race the first time an owner is replaced.)
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
    public var status: Status {
        statusLock.lock()
        defer { statusLock.unlock() }
        return lockedStatus
    }

    // Queue-only state below.
    private var task: URLSessionWebSocketTask?
    private var handshake: RelayHandshake?
    private var authenticated = false
    private var wantsConnection = false
    private var backoff = Backoff()
    private var outbox = RelayOutbox()
    private var pingTimer: DispatchSourceTimer?
    /// Bumped every time a socket is opened or torn down. Every callback and timer carries the
    /// epoch it was armed in and does nothing if it no longer matches -- a `URLSessionWebSocketTask`
    /// completion for a socket that was cancelled two reconnects ago still arrives, and without
    /// this it would report the live connection as dropped.
    private var epoch = 0

    /// How long the relay is given to get from `hello` to `welcome` before the socket is treated as
    /// dead. The relay's own deadline is 10 s per step; a socket that is open but silent (a captive
    /// portal, a stalled proxy) would otherwise leave the UI saying "connecting" forever.
    private static let handshakeTimeout: TimeInterval = 25
    /// The relay pings every 30 s and `URLSessionWebSocketTask` answers those itself, so this is
    /// not needed to stay alive. It is needed to *notice*: a connection that is dead in one
    /// direction produces no read error at all until something is written, and a Mac whose relay
    /// socket is quietly dead shows sessions that cannot be attached to.
    private static let pingInterval: TimeInterval = 30

    public init(url: URL, token: String, identity: DeviceIdentity, deviceName: String,
                session: URLSession = .shared) {
        self.url = url
        self.token = token
        self.identity = identity
        self.deviceName = deviceName
        self.session = session
    }

    deinit {
        // The receive loop holds only a weak reference to this object, so without this the socket
        // would stay open until the relay's 90 s idle timeout noticed nobody was home.
        task?.cancel(with: .goingAway, reason: nil)
        pingTimer?.cancel()
    }

    public var deviceID: String { identity.deviceID }

    /// Idempotent: calling it while connecting or online does nothing. Calling it after `failed`
    /// deliberately does start a fresh attempt -- that is the "Reconnect" the user reaches for
    /// after fixing the relay token, and it is the only way out of `failed`.
    public func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = true
            guard self.task == nil else { return }
            // A deliberate connect starts the delays over: someone who has just fixed the token or
            // rejoined a network should not wait out a 60 s delay earned by an outage that is over.
            self.backoff.reset()
            self.openSocket()
        }
    }

    /// Stops for good until `connect()` is called again: no reconnect is scheduled and anything
    /// still queued is dropped, because frames queued for a session the user has ended are not
    /// worth replaying whenever the connection next comes back.
    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsConnection = false
            self.closeSocket()
            self.backoff.reset()
            self.outbox.clear()
            self.setStatus(.offline)
        }
    }

    /// Queued while the connection is not yet authenticated and flushed after `welcome`, so callers
    /// never have to ask whether the socket is up; see `RelayOutbox` for what happens when the
    /// queue is full.
    public func send(_ message: RemoteMessage) { enqueue(.text(message)) }

    public func send(_ frame: BinaryFrame) { enqueue(.binary(frame)) }

    // MARK: - The socket

    private func enqueue(_ frame: RelayOutbox.Frame) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.authenticated, self.task != nil {
                self.write(frame, epoch: self.epoch)
            } else {
                self.outbox.append(frame)
            }
        }
    }

    private func openSocket() {
        epoch += 1
        let armed = epoch
        // Deliberately not an URLRequest with a `timeoutInterval`: on a WebSocket task that becomes
        // an idle timeout on an established socket, which would tear down a healthy but quiet
        // connection between the relay's 30 s pings. The handshake deadline below is armed instead.
        let socket = session.webSocketTask(with: url)
        task = socket
        authenticated = false
        handshake = RelayHandshake(deviceID: identity.deviceID) { [identity] message in
            try? identity.sign(message)
        }
        setStatus(.connecting)
        socket.resume()
        write(.text(RelayHandshake.hello(deviceID: identity.deviceID, deviceName: deviceName, token: token)),
              epoch: armed)
        receiveNext(epoch: armed)
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, armed == self.epoch, !self.authenticated else { return }
            self.drop(epoch: armed)
        }
    }

    private func closeSocket() {
        epoch += 1
        pingTimer?.cancel()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        handshake = nil
        authenticated = false
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
    /// itself would be able to get the sequence wrong.
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
            backoff.reset()
            // Flushed before the status change so that anything the delegate sends on hearing
            // `.online` goes out behind what was queued while the socket was down, not in front.
            for frame in outbox.drain() { write(frame, epoch: armed) }
            startPings(epoch: armed)
            setStatus(.online)
        case .rejected(let code):
            closeSocket()
            wantsConnection = false
            setStatus(.failed(code))
        case .protocolError:
            drop(epoch: armed)
        }
    }

    /// One dropped socket: tear it down, say so, and arm the next attempt. Called from four places
    /// (a read error, a write error, a failed ping, a handshake that never finished) so that all
    /// four produce exactly one `.offline` and one scheduled reconnect.
    private func drop(epoch armed: Int) {
        guard armed == epoch, task != nil else { return }
        closeSocket()
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

    private func startPings(epoch armed: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, armed == self.epoch, let socket = self.task else { return }
            socket.sendPing { [weak self] error in
                guard let self, error != nil else { return }
                self.queue.async { self.drop(epoch: armed) }
            }
        }
        pingTimer?.cancel()
        pingTimer = timer
        timer.resume()
    }

    private func setStatus(_ new: Status) {
        statusLock.lock()
        let changed = lockedStatus != new
        lockedStatus = new
        statusLock.unlock()
        guard changed else { return }
        delegate?.relay(self, didChange: new)
    }
}
