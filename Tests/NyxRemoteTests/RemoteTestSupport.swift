import CryptoKit
import Foundation
import NyxCore
@testable import NyxRemote

/// A `RelayLink` that keeps what was sent instead of writing it to a socket, and optionally hands
/// it straight to the other side's `handle`. That is how a whole attach -- signatures, key
/// agreement, snapshot, live bytes, input -- runs inside one test process with real crypto at both
/// ends and no relay.
final class FakeLink: RelayLink {
    let deviceID: String
    /// Called with everything sent, on whatever thread sent it. Wiring two `FakeLink`s to each
    /// other's owner is what makes an end-to-end test.
    var onMessage: ((RemoteMessage) -> Void)?
    var onFrame: ((BinaryFrame) -> Void)?
    /// Called before a frame is recorded, so a test can make one transmission slow and see whether
    /// a second sender can overtake it. A real link is slow in exactly this place.
    var beforeAppendingFrame: ((BinaryFrame) -> Void)?

    private let lock = NSLock()
    private var sentMessages: [RemoteMessage] = []
    private var sentFrames: [BinaryFrame] = []
    private var sendLog: [String] = []

    init(deviceID: String) {
        self.deviceID = deviceID
    }

    func send(_ m: RemoteMessage) {
        lock.lock()
        sentMessages.append(m)
        sendLog.append(m.t)
        lock.unlock()
        onMessage?(m)
    }

    func send(_ f: BinaryFrame) {
        beforeAppendingFrame?(f)
        lock.lock()
        sentFrames.append(f)
        sendLog.append("frame")
        lock.unlock()
        onFrame?(f)
    }

    var messages: [RemoteMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sentMessages
    }

    var frames: [BinaryFrame] {
        lock.lock()
        defer { lock.unlock() }
        return sentFrames
    }

    /// Messages and frames interleaved in the order they were sent, which is what several of these
    /// tests are really about: `attached` before the snapshot, the snapshot before `snapshot_end`,
    /// live bytes only after it.
    var sendOrder: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sendLog
    }

    func reset() {
        lock.lock()
        sentMessages = []
        sentFrames = []
        sendLog = []
        lock.unlock()
    }

    func messages(ofType t: String) -> [RemoteMessage] { messages.filter { $0.t == t } }
}

/// A scratch directory per identity, so every test device gets its own key file rather than sharing
/// one and accidentally proving nothing about signatures.
func testIdentity() throws -> DeviceIdentity {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nyx-remote-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try DeviceIdentity.load(from: dir.appendingPathComponent("identity"))
}

enum TestPeerError: Error { case notAttached }

/// One end of an attach, done by hand with the real primitives: this is what `RemoteClient` (as a
/// client) or `RemoteHost` (as a host) does, written out separately so a test of either is not
/// merely checking that the thing under test agrees with itself.
final class TestPeer {
    let identity: DeviceIdentity
    /// A var, not a let: a real host and a real client each make a *fresh* ephemeral key for every
    /// attach (that is what "forward secrecy per attachment" means), and a fixture that reused one
    /// would make a replayed `attached` indistinguishable from a genuine second round.
    private(set) var ephemeral = E2ESession.ephemeral()
    let isHost: Bool
    private(set) var e2e: E2ESession?

    init(isHost: Bool = false) throws {
        self.isHost = isHost
        identity = try testIdentity()
    }

    /// A second peer on the *same* device: one client attached to two of a host's sessions is one
    /// device id with two attachments, each with its own ephemeral key and cipher, which is what a
    /// real `RemoteClient` does.
    init(identity: DeviceIdentity, isHost: Bool = false) {
        self.isHost = isHost
        self.identity = identity
    }

    var deviceID: String { identity.deviceID }

    /// Starts a new attach round on this peer, the way a real one does.
    func rotateEphemeral() {
        ephemeral = E2ESession.ephemeral()
        e2e = nil
    }

    func attachMessage(to host: String, sessionID: [UInt8]) throws -> RemoteMessage {
        let signed = try E2ESession.signedPublicKey(ephemeral, sessionID: sessionID, identity: identity)
        var m = RemoteMessage.attach(to: host, sessionID: RemoteID.base64url(sessionID),
                                     ephemeralPubkey: signed.pubkey, sig: signed.sig)
        m.from = deviceID
        return m
    }

    /// The host's answer, signed the way a real host signs it.
    func attachedMessage(to client: String, sessionID: [UInt8], role: String,
                         cols: Int = 80, rows: Int = 24) throws -> RemoteMessage {
        let signed = try E2ESession.signedPublicKey(ephemeral, sessionID: sessionID, identity: identity)
        var m = RemoteMessage.attached(to: client, sessionID: RemoteID.base64url(sessionID),
                                       ephemeralPubkey: signed.pubkey, sig: signed.sig,
                                       role: role, cols: cols, rows: rows)
        m.from = deviceID
        return m
    }

    /// Verifies the peer's signed ephemeral key exactly as the real code does, then derives the
    /// session keys. Returns false if the signature does not check out.
    @discardableResult
    func completeAttach(_ m: RemoteMessage, sessionID: [UInt8], peerID: String) throws -> Bool {
        guard let pubkey = m.ephemeralPubkey, let sig = m.sig,
              E2ESession.verifyPeer(pubkey: pubkey, sig: sig, sessionID: sessionID, deviceID: peerID) else {
            return false
        }
        e2e = try E2ESession(mine: ephemeral, peer: pubkey, sessionID: sessionID, isHost: isHost)
        return true
    }

    func open(_ frame: BinaryFrame) -> [UInt8]? {
        guard let e2e else { return nil }
        return try? e2e.open(frame)
    }

    func seal(_ bytes: [UInt8]) throws -> BinaryFrame {
        guard let e2e else { throw TestPeerError.notAttached }
        return try e2e.seal(bytes)
    }

    /// A message this peer sends about an attachment it already has, with `from` filled in the way
    /// the relay fills it.
    func message(_ m: RemoteMessage) -> RemoteMessage {
        var out = m
        out.from = deviceID
        return out
    }
}

/// A paired-devices list a test can change while the object under test holds a closure onto it.
final class PairedBox {
    private let lock = NSLock()
    private var ids: [String] = []

    func add(_ id: String) {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }

    var devices: PairedDevices {
        lock.lock()
        defer { lock.unlock() }
        return PairedDevices(devices: ids.map { PairedDevice(id: $0, name: $0, pairedAt: Date()) })
    }
}

/// Polls instead of sleeping a fixed time: a shell's output arrives when the scheduler says so.
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

/// A real shell on a real PTY. A trailing `sleep 30` keeps the child alive past the assertions, so
/// each test is about the host and not about a race with the process exiting; every caller
/// terminates it.
func shellSession(_ script: String, cols: Int = 80, rows: Int = 24) throws -> TerminalSession {
    let config = SessionConfig(shellPath: "/bin/sh", argv: ["sh", "-c", script],
                               environment: ["PATH": "/bin:/usr/bin"], cwd: nil,
                               cols: cols, rows: rows, palette: Themes.palette(named: "nyx-dark"))
    return try TerminalSession(config: config)
}

func testSessionID(_ byte: UInt8 = 9) -> [UInt8] { Array(repeating: byte, count: 16) }

func testSummary(_ sessionID: [UInt8], title: String = "shell") -> RemoteSessionInfo {
    SessionSummary.make(sessionID: RemoteID.base64url(sessionID), title: title, cwd: "/tmp",
                        processName: "sh", lastCommand: nil, lastActivity: nil, cols: 80, rows: 24,
                        repo: nil)
}

/// A clock a test drives by hand, so a retry schedule measured in minutes can be watched in
/// microseconds.
///
/// `after` records rather than runs: nothing fires until `advance` moves the clock past its
/// deadline, which is what makes "the backoff was 1, then 2, then 4" an assertion about the code
/// rather than about how long the test happened to sleep.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var pending: [(due: Date, delay: TimeInterval, body: () -> Void)] = []
    /// Every delay asked for, in order -- the backoff sequence itself.
    private(set) var delays: [TimeInterval] = []

    var clock: RemoteClock {
        RemoteClock(now: { [weak self] in self?.snapshotNow ?? Date() },
                    after: { [weak self] seconds, body in self?.schedule(seconds, body) })
    }

    private var snapshotNow: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func schedule(_ seconds: TimeInterval, _ body: @escaping () -> Void) {
        lock.lock()
        pending.append((current.addingTimeInterval(seconds), seconds, body))
        delays.append(seconds)
        lock.unlock()
    }

    /// Moves the clock forward and runs everything that came due, oldest deadline first. Bodies run
    /// outside the lock because they schedule more work on this same clock.
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = pending.filter { $0.due <= current }.sorted { $0.due < $1.due }
        pending.removeAll { $0.due <= current }
        lock.unlock()
        for entry in due { entry.body() }
    }

    /// The delays asked for since the last time this was called, so one test can assert on one run
    /// of retries without counting the attach timeouts armed alongside them.
    func takeDelays() -> [TimeInterval] {
        lock.lock()
        defer {
            delays = []
            lock.unlock()
        }
        return delays
    }
}
