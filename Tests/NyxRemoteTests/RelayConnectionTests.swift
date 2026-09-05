import Foundation
import NyxCore
import Testing
@testable import NyxRemote

// MARK: - The outbox, without a socket

private func message(_ t: String) -> RelayOutbox.Frame { .text(RemoteMessage(t: t)) }

@Test func theOutboxKeepsWhatWasQueuedInOrder() {
    var outbox = RelayOutbox()
    outbox.append(message("a"))
    outbox.append(message("b"))

    let drained = outbox.drain()

    #expect(drained == [message("a"), message("b")])
    #expect(outbox.frames.isEmpty)
    #expect(outbox.dropped == 0)
}

@Test func theOutboxDropsTheOldestFrameOnceItIsFull() {
    var outbox = RelayOutbox(limit: 3)
    for name in ["a", "b", "c", "d"] { outbox.append(message(name)) }

    #expect(outbox.frames == [message("b"), message("c"), message("d")])
    #expect(outbox.dropped == 1)
}

@Test func theOutboxDefaultsToTwoHundredAndFiftySixFrames() {
    var outbox = RelayOutbox()
    for index in 0..<300 { outbox.append(message("m\(index)")) }

    #expect(outbox.limit == 256)
    #expect(outbox.frames.count == 256)
    #expect(outbox.frames.first == message("m44"))
    #expect(outbox.dropped == 44)
}

@Test func aDrainedOutboxForgetsWhatItDropped() {
    var outbox = RelayOutbox(limit: 1)
    outbox.append(message("a"))
    outbox.append(message("b"))
    _ = outbox.drain()

    #expect(outbox.dropped == 0)
}

@Test func clearingTheOutboxThrowsAwayWhatWasQueued() {
    var outbox = RelayOutbox(limit: 2)
    outbox.append(message("a"))
    outbox.append(message("b"))
    outbox.append(message("c"))
    outbox.clear()

    #expect(outbox.frames.isEmpty)
    #expect(outbox.dropped == 0)
}

@Test func theOutboxCarriesBinaryFramesToo() {
    var outbox = RelayOutbox()
    let frame = BinaryFrame(sessionID: [UInt8](repeating: 1, count: 16), counter: 9, ciphertext: [7, 7])
    outbox.append(.binary(frame))

    #expect(outbox.drain() == [.binary(frame)])
}

@Test func aConnectionStartsOfflineAndKnowsItsDeviceID() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nyx-relay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let identity = try DeviceIdentity.load(from: dir.appendingPathComponent("identity"))

    let connection = RelayConnection(url: URL(string: "ws://127.0.0.1:1/v1/ws")!, token: "t",
                                     identity: identity, deviceName: "Test")

    #expect(connection.status == .offline)
    #expect(connection.deviceID == identity.deviceID)
}

// MARK: - Against the real relay

/// Records everything a connection reports and lets a test block until a condition holds. The
/// arrays are read only from inside `wait`, which already holds the lock -- `NSCondition` is not
/// recursive, so a locking accessor called from a predicate would deadlock.
private final class Recorder: RelayConnectionDelegate {
    private let condition = NSCondition()
    var statuses: [RelayConnection.Status] = []
    var messages: [RemoteMessage] = []
    var frames: [BinaryFrame] = []

    func relay(_ connection: RelayConnection, didChange status: RelayConnection.Status) {
        condition.lock()
        statuses.append(status)
        condition.broadcast()
        condition.unlock()
    }

    func relay(_ connection: RelayConnection, didReceive message: RemoteMessage) {
        condition.lock()
        messages.append(message)
        condition.broadcast()
        condition.unlock()
    }

    func relay(_ connection: RelayConnection, didReceive frame: BinaryFrame) {
        condition.lock()
        frames.append(frame)
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func wait(upTo seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while !predicate() {
            if !condition.wait(until: deadline) { return predicate() }
        }
        return true
    }

    func snapshot<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }
}

/// A port nothing is listening on right now: bind to 0, read back what the kernel chose, close.
/// The relay binary does not report the port it bound, so there is no way to ask it afterwards.
private func freePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    var chosen = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &chosen) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    try #require(named == 0)
    return UInt16(bigEndian: chosen.sin_port)
}

/// The relay under test: its own process, its own port, its own token, torn down by the caller.
private struct Relay {
    let process: Process
    let port: UInt16
    let logURL: URL
    var socketURL: URL { URL(string: "ws://127.0.0.1:\(port)/v1/ws")! }
    var log: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
}

private func startRelay(binary: String, in directory: URL, port fixed: UInt16? = nil,
                        logName: String = "relay.log") throws -> Relay {
    let port = try fixed ?? freePort()
    let logURL = directory.appendingPathComponent(logName)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: logURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["-listen", "127.0.0.1:\(port)", "-token", "test-token"]
    process.standardOutput = handle
    process.standardError = handle
    try process.run()

    let health = URL(string: "http://127.0.0.1:\(port)/healthz")!
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if (try? Data(contentsOf: health)) != nil {
            return Relay(process: process, port: port, logURL: logURL)
        }
        usleep(50_000)
    }
    process.terminate()
    throw RelayTestError.neverBecameHealthy(port: port)
}

private enum RelayTestError: Error { case neverBecameHealthy(port: UInt16) }

/// The whole client half of §6.1 against the real Go relay: two devices complete the handshake,
/// a frame queued before the socket existed still arrives, one device's pairing code reaches the
/// other through the relay, and a wrong token stops rather than reconnecting. Opt-in because it
/// needs the relay binary; `NYX_RELAY_BIN=~/projects/nyx-server/bin/nyx-relay swift test`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_RELAY_BIN"] != nil))
func twoDevicesHandshakePairThroughTheRelayAndAWrongTokenStops() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["NYX_RELAY_BIN"])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nyx-relay-it-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let relay = try startRelay(binary: binary, in: directory)
    defer {
        relay.process.terminate()
        relay.process.waitUntilExit()
    }

    let hostIdentity = try DeviceIdentity.load(from: directory.appendingPathComponent("host/identity"))
    let clientIdentity = try DeviceIdentity.load(from: directory.appendingPathComponent("client/identity"))

    let hostRecorder = Recorder()
    let clientRecorder = Recorder()
    let host = RelayConnection(url: relay.socketURL, token: "test-token", identity: hostIdentity,
                               deviceName: "Host Mac")
    let client = RelayConnection(url: relay.socketURL, token: "test-token", identity: clientIdentity,
                                 deviceName: "Client Mac")
    host.delegate = hostRecorder
    client.delegate = clientRecorder
    defer {
        host.disconnect()
        client.disconnect()
    }

    // Queued before there is a socket at all: it must arrive after `welcome`, not be lost.
    let code = "ABC234"
    host.send(.pairOpen(code: code))
    host.connect()
    client.connect()

    let hostOnline = hostRecorder.wait(upTo: 10) { hostRecorder.statuses.contains(.online) }
    let clientOnline = clientRecorder.wait(upTo: 10) { clientRecorder.statuses.contains(.online) }
    #expect(hostOnline, "the host never reached .online; relay log:\n\(relay.log)")
    #expect(clientOnline, "the client never reached .online; relay log:\n\(relay.log)")
    #expect(host.status == .online)
    #expect(client.status == .online)
    #expect(hostRecorder.snapshot { hostRecorder.statuses } == [.connecting, .authenticating, .online])

    let opened = hostRecorder.wait(upTo: 5) { hostRecorder.messages.contains { $0.t == "pair_opened" } }
    #expect(opened, "the queued pair_open never reached the relay; log:\n\(relay.log)")

    client.send(.pairJoin(code: code))
    let requested = hostRecorder.wait(upTo: 5) {
        hostRecorder.messages.contains { $0.t == "pair_request" && $0.from == clientIdentity.deviceID }
    }
    #expect(requested, "the host never saw pair_request; log:\n\(relay.log)")
    let request = hostRecorder.snapshot { hostRecorder.messages.first { $0.t == "pair_request" } }
    #expect(request?.name == "Client Mac")

    // A wrong token: `error bad_token` and close 4401, and nothing that looks like a retry after.
    let strayIdentity = try DeviceIdentity.load(from: directory.appendingPathComponent("stray/identity"))
    let strayRecorder = Recorder()
    let stray = RelayConnection(url: relay.socketURL, token: "the wrong token", identity: strayIdentity,
                                deviceName: "Stray Mac")
    stray.delegate = strayRecorder
    defer { stray.disconnect() }
    stray.connect()

    let refused = strayRecorder.wait(upTo: 10) { strayRecorder.statuses.contains(.failed("bad_token")) }
    #expect(refused, "a wrong token did not produce .failed(bad_token); log:\n\(relay.log)")
    let afterRefusal = strayRecorder.snapshot { strayRecorder.statuses.count }
    Thread.sleep(forTimeInterval: 2)
    #expect(strayRecorder.snapshot { strayRecorder.statuses.count } == afterRefusal,
            "the refused connection kept trying: \(strayRecorder.snapshot { strayRecorder.statuses })")
    #expect(stray.status == .failed("bad_token"))
}

/// The other half of the lifecycle: the relay goes away, the connection says so, and it comes back
/// on its own with what was queued in the meantime still in hand. A relay restart is the ordinary
/// case (a deploy), not the exotic one, so this is the path a user actually meets.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_RELAY_BIN"] != nil))
func theConnectionComesBackByItselfAfterTheRelayRestarts() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["NYX_RELAY_BIN"])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nyx-relay-it-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try startRelay(binary: binary, in: directory)
    var running = first.process
    defer {
        running.terminate()
        running.waitUntilExit()
    }

    let identity = try DeviceIdentity.load(from: directory.appendingPathComponent("device/identity"))
    let recorder = Recorder()
    let connection = RelayConnection(url: first.socketURL, token: "test-token", identity: identity,
                                     deviceName: "Restarting Mac")
    connection.delegate = recorder
    defer { connection.disconnect() }
    connection.connect()

    #expect(recorder.wait(upTo: 10) { recorder.statuses.contains(.online) },
            "never reached .online; log:\n\(first.log)")

    first.process.terminate()
    first.process.waitUntilExit()
    #expect(recorder.wait(upTo: 10) { recorder.statuses.last == .offline },
            "the dropped socket was never reported: \(recorder.snapshot { recorder.statuses })")

    // Queued while there is no relay at all: it has to survive the reconnect, not the drop.
    connection.send(.pairOpen(code: "ZY9876"))

    let second = try startRelay(binary: binary, in: directory, port: first.port, logName: "relay2.log")
    running = second.process

    #expect(recorder.wait(upTo: 20) { recorder.statuses.filter { $0 == .online }.count == 2 },
            "never reconnected: \(recorder.snapshot { recorder.statuses }); log:\n\(second.log)")
    #expect(recorder.wait(upTo: 5) { recorder.messages.contains { $0.t == "pair_opened" } },
            "what was queued while offline never went out; log:\n\(second.log)")
    #expect(connection.status == .online)
}
