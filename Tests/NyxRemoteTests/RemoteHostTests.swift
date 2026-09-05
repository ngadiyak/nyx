import CryptoKit
import Foundation
import NyxCore
import Testing
@testable import NyxRemote

/// Everything one host test needs, wired the way `NyxApp` will wire it: a real shell on a real PTY,
/// a fake wire, a paired-devices list the test can change, and a collected audit log.
private final class HostFixture {
    let link: FakeLink
    let identity: DeviceIdentity
    let host: RemoteHost
    let session: TerminalSession
    let sessionID: [UInt8]
    let key: String

    private let lock = NSLock()
    private var pairedIDs: [String] = []
    private var events: [AuditLine.Event] = []

    var hostID: String { identity.deviceID }

    var audit: [AuditLine.Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func pair(_ deviceID: String) {
        lock.lock()
        pairedIDs.append(deviceID)
        lock.unlock()
    }

    init(script: String, snapshotLines: Int = 200, debounce: TimeInterval = 0.05) throws {
        identity = try testIdentity()
        link = FakeLink(deviceID: identity.deviceID)
        session = try shellSession(script)
        sessionID = testSessionID()
        key = RemoteID.base64url(sessionID)
        let lock = self.lock
        var pairedBox: () -> [String] = { [] }
        var auditBox: (AuditLine.Event) -> Void = { _ in }
        host = RemoteHost(link: link, identity: identity,
                          paired: { PairedDevices(devices: pairedBox().map { PairedDevice(id: $0, name: $0, pairedAt: Date()) }) },
                          audit: { auditBox($0) },
                          snapshotLines: snapshotLines, summaryDebounce: debounce)
        pairedBox = { [weak self] in
            guard let self else { return [] }
            lock.lock()
            defer { lock.unlock() }
            return self.pairedIDs
        }
        auditBox = { [weak self] event in
            guard let self else { return }
            lock.lock()
            self.events.append(event)
            lock.unlock()
        }
        session.start()
    }

    func register() {
        host.register(sessionID: sessionID, session: session, summary: { [sessionID] in testSummary(sessionID) })
        host.flush()
    }

    /// Runs a full attach for `peer` and returns the `attached` message the host sent.
    func attach(_ peer: TestPeer) throws -> RemoteMessage? {
        host.handle(try peer.attachMessage(to: hostID, sessionID: sessionID))
        host.flush()
        guard let attached = link.messages(ofType: "attached").last(where: { $0.to == peer.deviceID }) else { return nil }
        try peer.completeAttach(attached, sessionID: sessionID, peerID: hostID)
        return attached
    }

    /// Everything the host sent to `peer` as data, decrypted in the order it was sent. Frames are
    /// opened once and only once: `E2ESession.open` moves the replay window, so a second pass over
    /// the same frames would be rejected -- which is the point of the counter, not a test quirk.
    func text(_ peer: TestPeer, _ frames: [BinaryFrame]) -> String {
        String(decoding: frames.compactMap { peer.open($0) }.flatMap { $0 }, as: UTF8.self)
    }

    func terminate() {
        session.terminate()
    }
}

private func waitForShell(_ f: HostFixture, containing needle: String) -> Bool {
    waitUntil { f.session.withTerminal { $0.transcript(options: .plainText) }.contains(needle) }
}

@Test func anAttachIsAnsweredWithARoleASnapshotAndThenTheLiveTail() throws {
    let f = try HostFixture(script: "printf 'alpha\\n'; read x; printf \"beta:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(waitForShell(f, containing: "alpha"))

    let sent = try f.attach(peer)
    let attached = try #require(sent)
    #expect(attached.role == "writer")
    #expect(attached.cols == 80 && attached.rows == 24)
    #expect(attached.sessionID == f.key)

    let order = f.link.sendOrder
    let attachedIndex = try #require(order.firstIndex(of: "attached"))
    let endIndex = try #require(order.firstIndex(of: "snapshot_end"))
    #expect(attachedIndex < endIndex)
    #expect(order[(attachedIndex + 1)..<endIndex].allSatisfy { $0 == "frame" })

    let snapshotFrames = f.link.frames
    #expect(f.text(peer, snapshotFrames).contains("alpha"))

    // Local input on the host is never arbitrated: it goes straight to the PTY, and what the shell
    // writes back must reach the attached client as live bytes -- after `snapshot_end`, once.
    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "beta:go"))
    #expect(waitUntil { f.link.frames.count > snapshotFrames.count })
    f.host.flush()
    let live = Array(f.link.frames.dropFirst(snapshotFrames.count))
    let liveText = f.text(peer, live)
    #expect(liveText == "go\r\nbeta:go\r\n")   // the echo of the keystroke and the shell's answer, once each
    #expect(f.link.sendOrder.lastIndex(of: "snapshot_end")! < f.link.sendOrder.lastIndex(of: "frame")!)
    #expect(f.audit == [.attached(device: peer.deviceID, session: f.key)])
}

@Test func theSessionIsPublishedBeforeAnyAttachCanBeAnswered() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    f.register()

    // The relay refuses `attached` for a session the host does not publish, so `register` must put
    // the catalogue on the wire immediately rather than waiting for the summary debounce.
    let sessions = f.link.messages(ofType: "sessions")
    #expect(sessions.count == 1)
    #expect(sessions.first?.sessions?.first?.sessionID == f.key)
}

@Test func anAttachForAnUnknownSessionIsIgnored() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()

    var stray = try peer.attachMessage(to: f.hostID, sessionID: testSessionID(3))
    stray.from = peer.deviceID
    f.host.handle(stray)
    f.host.flush()

    #expect(f.link.messages(ofType: "attached").isEmpty)
    #expect(f.audit.isEmpty)
}

@Test func anAttachFromAnUnpairedDeviceIsIgnoredAndNotAudited() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.register()   // deliberately not paired

    f.host.handle(try peer.attachMessage(to: f.hostID, sessionID: f.sessionID))
    f.host.flush()

    #expect(f.link.messages(ofType: "attached").isEmpty)
    #expect(f.link.frames.isEmpty)
    // Nothing is written to the audit log either: an unpaired device is not an event on this Mac,
    // it is a message the relay should never have forwarded.
    #expect(f.audit.isEmpty)
}

@Test func anAttachWhoseSignatureDoesNotVerifyIsIgnored() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    let other = try TestPeer()
    f.pair(peer.deviceID)
    f.register()

    // The signature is genuine -- but made by a different device's key, which is exactly what a
    // relay substituting its own ephemeral key would produce.
    var forged = try other.attachMessage(to: f.hostID, sessionID: f.sessionID)
    forged.from = peer.deviceID
    f.host.handle(forged)
    f.host.flush()

    #expect(f.link.messages(ofType: "attached").isEmpty)
    #expect(f.audit.isEmpty)
}

@Test func theSecondClientToAttachIsAnObserverAndTakeControlSwapsBoth() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let first = try TestPeer()
    let second = try TestPeer()
    f.pair(first.deviceID)
    f.pair(second.deviceID)
    f.register()

    let firstAttached = try f.attach(first)
    let secondAttached = try f.attach(second)
    #expect(firstAttached?.role == "writer")
    #expect(secondAttached?.role == "observer")

    f.link.reset()
    f.host.handle(second.message(.takeControl(to: f.hostID, sessionID: f.key)))
    f.host.flush()

    // Every attached client is told about every change, so an observer's strip updates when someone
    // else takes control, not only when it is the one that changed.
    let roles = f.link.messages(ofType: "role")
    #expect(roles.count == 4)
    #expect(roles.filter { $0.deviceID == first.deviceID && $0.role == "observer" }.compactMap(\.to).sorted()
            == [first.deviceID, second.deviceID].sorted())
    #expect(roles.filter { $0.deviceID == second.deviceID && $0.role == "writer" }.compactMap(\.to).sorted()
            == [first.deviceID, second.deviceID].sorted())
    #expect(f.audit.contains(.tookControl(device: second.deviceID, session: f.key)))
}

@Test func inputFromTheWriterReachesTheShell() throws {
    let f = try HostFixture(script: "read x; printf \"got:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    let attached = try f.attach(peer)
    #expect(attached != nil)

    f.host.handle(try peer.seal(Array("hi\n".utf8)))
    #expect(waitForShell(f, containing: "got:hi"))
}

@Test func inputFromAnObserverNeverReachesTheShell() throws {
    let f = try HostFixture(script: "read x; printf \"got:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let writer = try TestPeer()
    let observer = try TestPeer()
    f.pair(writer.deviceID)
    f.pair(observer.deviceID)
    f.register()
    let writerAttached = try f.attach(writer)
    let observerAttached = try f.attach(observer)
    #expect(writerAttached?.role == "writer")
    #expect(observerAttached?.role == "observer")

    // The observer's frame is sealed with a key the host only accepts from the writer, so it cannot
    // even be opened, let alone written to the PTY. The writer's line goes in after it, and the
    // shell reads exactly one line: whichever arrives first is what `got:` shows.
    f.host.handle(try observer.seal(Array("bad\n".utf8)))
    f.host.flush()
    f.host.handle(try writer.seal(Array("hi\n".utf8)))
    #expect(waitForShell(f, containing: "got:hi"))
    #expect(!f.session.withTerminal { $0.transcript(options: .plainText) }.contains("bad"))
}

@Test func aTamperedFrameIsDiscardedWithoutAdvancingTheReplayWindow() throws {
    let f = try HostFixture(script: "read x; printf \"got:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    let attached = try f.attach(peer)
    #expect(attached != nil)

    let genuine = try peer.seal(Array("hi\n".utf8))
    var flipped = genuine.ciphertext
    flipped[0] ^= 0x01
    f.host.handle(BinaryFrame(sessionID: genuine.sessionID, counter: genuine.counter, ciphertext: flipped))
    f.host.flush()

    // The tampered frame carried counter 0. If the host had advanced its window on a frame that
    // failed authentication, the genuine frame -- also counter 0 -- would now be rejected as a
    // replay and the keystroke would be lost.
    f.host.handle(genuine)
    #expect(waitForShell(f, containing: "got:hi"))
}

@Test func detachPromotesTheLongestAttachedObserverAndIsAudited() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let first = try TestPeer()
    let second = try TestPeer()
    f.pair(first.deviceID)
    f.pair(second.deviceID)
    f.register()
    let firstAttached = try f.attach(first)
    let secondAttached = try f.attach(second)
    #expect(firstAttached?.role == "writer")
    #expect(secondAttached?.role == "observer")

    f.link.reset()
    f.host.handle(first.message(.detach(to: f.hostID, sessionID: f.key)))
    f.host.flush()

    let roles = f.link.messages(ofType: "role")
    #expect(roles.count == 1)
    #expect(roles.first?.to == second.deviceID)
    #expect(roles.first?.deviceID == second.deviceID)
    #expect(roles.first?.role == "writer")
    #expect(f.audit.contains(.detached(device: first.deviceID, session: f.key)))
}

@Test func unregisterTellsEveryAttachedClientTheSessionEnded() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let first = try TestPeer()
    let second = try TestPeer()
    f.pair(first.deviceID)
    f.pair(second.deviceID)
    f.register()
    let firstAttached = try f.attach(first)
    let secondAttached = try f.attach(second)
    #expect(firstAttached?.role == "writer")
    #expect(secondAttached?.role == "observer")

    f.link.reset()
    f.host.unregister(sessionID: f.sessionID)
    f.host.flush()

    let ended = f.link.messages(ofType: "session_ended")
    #expect(ended.compactMap(\.to).sorted() == [first.deviceID, second.deviceID].sorted())
    #expect(ended.allSatisfy { $0.sessionID == f.key })
    // And the catalogue no longer offers it, so the relay stops answering attaches for it.
    #expect(f.link.messages(ofType: "sessions").last?.sessions?.isEmpty == true)
}

@Test func outputAfterUnregisterIsNotSentToAnyone() throws {
    let f = try HostFixture(script: "read x; printf \"late:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    let attached = try f.attach(peer)
    #expect(attached != nil)
    f.host.unregister(sessionID: f.sessionID)
    f.host.flush()

    let before = f.link.frames.count
    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "late:go"))
    f.host.flush()
    #expect(f.link.frames.count == before)
}

@Test func linkDidReconnectResendsThePairedListAndTheCatalogue() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    let attached = try f.attach(peer)
    #expect(attached != nil)

    f.link.reset()
    f.host.linkDidReconnect()
    f.host.flush()

    #expect(f.link.messages(ofType: "paired").first?.deviceIDs == [peer.deviceID])
    #expect(f.link.messages(ofType: "sessions").first?.sessions?.first?.sessionID == f.key)
    // The relay dropped every attachment when the socket went; the audit log says so, and the next
    // client to attach is the writer again rather than an observer behind a client that is gone.
    #expect(f.audit.contains(.detached(device: peer.deviceID, session: f.key)))
    let again = try TestPeer()
    f.pair(again.deviceID)
    let reattached = try f.attach(again)
    #expect(reattached?.role == "writer")
}

@Test func aClientThatAttachesTwiceKeepsTheRoleItAlreadyHad() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let writer = try TestPeer()
    let observer = try TestPeer()
    f.pair(writer.deviceID)
    f.pair(observer.deviceID)
    f.register()
    let writerAttached = try f.attach(writer)
    let observerAttached = try f.attach(observer)
    #expect(writerAttached?.role == "writer")
    #expect(observerAttached?.role == "observer")

    // A client whose socket dropped re-sends `attach`; it must come back to the role it left with,
    // rather than being appended to the arbiter a second time and demoted behind the observer that
    // arrived after it.
    let again = try f.attach(writer)
    #expect(again?.role == "writer")

    // And the observer is still exactly one entry, so a later detach promotes it once.
    f.link.reset()
    f.host.handle(writer.message(.detach(to: f.hostID, sessionID: f.key)))
    f.host.flush()
    #expect(f.link.messages(ofType: "role").filter { $0.deviceID == observer.deviceID }.count == 1)
}

@Test func summaryChangedPublishesOnceForABurstOfChanges() throws {
    let f = try HostFixture(script: "sleep 30", debounce: 0.05)
    defer { f.terminate() }
    f.register()
    f.link.reset()

    for _ in 0..<10 { f.host.summaryChanged() }
    f.host.flush()
    #expect(f.link.messages(ofType: "sessions").isEmpty)   // nothing goes out immediately

    #expect(waitUntil { !f.link.messages(ofType: "sessions").isEmpty })
    usleep(120_000)
    #expect(f.link.messages(ofType: "sessions").count == 1)
}

@Test func aSessionPublishedAfterItHasAlreadyPrintedStillStreamsWhatComesNext() throws {
    // The ordinary case, and the one a fixture that registers first never reaches: a session has
    // been running in a tab for hours before remote sessions are switched on, so the host starts
    // counting output chunks in the middle of the stream, not at zero. Getting that offset wrong
    // costs the client every live byte until the session has printed as much again as it had
    // before it was published -- which on a busy session is silence for a very long time.
    let f = try HostFixture(script: "printf 'before\\n'; read x; printf \"after:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    #expect(waitForShell(f, containing: "before"))
    f.register()

    let sent = try f.attach(peer)
    let attached = try #require(sent)
    #expect(attached.role == "writer")
    let snapshot = f.link.frames
    #expect(f.text(peer, snapshot).contains("before"))

    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "after:go"))
    #expect(waitUntil { f.link.frames.count > snapshot.count })
    f.host.flush()
    // Exactly what the PTY produced from that keystroke, echo included: "contains" would pass
    // while quietly losing the first chunk after the snapshot, which is what a wrong offset does.
    let live = f.text(peer, Array(f.link.frames.dropFirst(snapshot.count)))
    #expect(live == "go\r\nafter:go\r\n")
}
