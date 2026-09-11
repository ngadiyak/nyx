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
    /// Driven by hand, so the sixty-second re-attach window is watched in microseconds.
    let clock = TestClock()

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

    func unpair(_ deviceID: String) {
        lock.lock()
        pairedIDs.removeAll { $0 == deviceID }
        lock.unlock()
    }

    init(script: String, snapshotLines: Int = 200, debounce: TimeInterval = 0.05,
         reattachWindow: TimeInterval = 60) throws {
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
                          snapshotLines: snapshotLines, summaryDebounce: debounce,
                          reattachWindow: reattachWindow, clock: clock.clock)
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
    func attach(_ peer: TestPeer, to id: [UInt8]? = nil) throws -> RemoteMessage? {
        let target = id ?? sessionID
        let key = RemoteID.base64url(target)
        host.handle(try peer.attachMessage(to: hostID, sessionID: target))
        host.flush()
        guard let attached = link.messages(ofType: "attached")
            .last(where: { $0.to == peer.deviceID && $0.sessionID == key }) else { return nil }
        try peer.completeAttach(attached, sessionID: target, peerID: hostID)
        return attached
    }

    /// A second published session on the same host. The caller terminates it.
    func addSession(_ script: String, id: UInt8) throws -> (session: TerminalSession, sessionID: [UInt8], key: String) {
        let session = try shellSession(script)
        session.start()
        let sessionID = testSessionID(id)
        host.register(sessionID: sessionID, session: session, summary: { testSummary(sessionID, title: "second") })
        host.flush()
        return (session, sessionID, RemoteID.base64url(sessionID))
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
    // This half was `the relay dropped every attachment, the audit log says so, and the next client
    // in is the writer`. The relay did drop them, but the clients are re-attaching within the
    // second, so they are *held*: nothing is audited and the token stays where it was until the
    // window closes on a client that really has gone.
    #expect(!f.audit.contains(.detached(device: peer.deviceID, session: f.key)))
    let again = try TestPeer()
    f.pair(again.deviceID)
    #expect(try f.attach(again)?.role == "observer")

    f.clock.advance(61)
    f.host.flush()
    #expect(f.audit.contains(.detached(device: peer.deviceID, session: f.key)))
    let promoted = f.link.messages(ofType: "role").last { $0.deviceID == again.deviceID }
    #expect(promoted?.role == "writer")
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

/// Was `aClientThatGoesOfflineLosesItsAttachmentAndItsWriterToken`, which asserted the drop that
/// this plan removes: `presence(offline)` is a socket closing, not a user leaving, so the
/// attachment is held and only the sweep ends it. What the sweep must still do is everything the
/// immediate drop did -- the token moves, the observer is told, the log says so, and nothing is
/// sealed for a device that is not there.
@Test func aClientThatGoesOfflineIsHeldAndOnlyLosesItsWriterTokenWhenTheWindowCloses() throws {
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

    // The relay says nothing else about a client whose socket closed: `presence` is the whole
    // notification. It is not yet an answer about the *user*, so nothing moves.
    f.link.reset()
    f.host.handle(RemoteMessage(t: "presence", devices: [
        RemotePresence(deviceID: writer.deviceID, name: "laptop", online: false),
        RemotePresence(deviceID: observer.deviceID, name: "ipad", online: true),
    ]))
    f.host.flush()
    #expect(f.link.messages(ofType: "role").isEmpty)
    #expect(!f.audit.contains(.detached(device: writer.deviceID, session: f.key)))

    // A minute later it has not come back, and now the token must move -- otherwise nobody left can
    // type for the rest of the session.
    f.clock.advance(61)
    f.host.flush()
    let roles = f.link.messages(ofType: "role")
    #expect(roles.count == 1)
    #expect(roles.first?.to == observer.deviceID)
    #expect(roles.first?.deviceID == observer.deviceID)
    #expect(roles.first?.role == "writer")
    #expect(f.audit.contains(.detached(device: writer.deviceID, session: f.key)))

    // One frame per chunk, all of them for the device that is still here: a frame sealed for the
    // departed writer would break the observer's counter sequence and fail to open.
    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "got:go"))
    f.host.flush()
    #expect(!f.link.frames.isEmpty)
    #expect(f.text(observer, f.link.frames) == "go\r\ngot:go\r\n")
}

/// Nothing is sealed for an attachment while it is held. The chunks still count -- that is what
/// `heldAtSequence` is compared against -- but ~85 KB per client per cycle must not be encrypted
/// and handed to a relay that has already dropped this device's socket.
@Test func outputWhileAClientIsHeldIsCountedButNotSentToIt() throws {
    let f = try HostFixture(script: "read x; printf \"got:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(try f.attach(peer) != nil)

    f.host.handle(RemoteMessage(t: "presence", devices: [
        RemotePresence(deviceID: peer.deviceID, name: "laptop", online: false),
    ]))
    f.host.flush()
    f.link.reset()
    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "got:go"))
    f.host.flush()
    #expect(f.link.frames.isEmpty)
}

/// Was `deviceWentOfflineDoesTheSameAsAPresenceMessage`, and it still does -- the meaning of both
/// has changed together. The door that drops at once is `deviceRemoved`, which is what Remove uses.
@Test func deviceWentOfflineHoldsTheAttachmentJustAsAPresenceMessageDoes() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    let attached = try f.attach(peer)
    #expect(attached != nil)

    f.link.reset()
    f.host.deviceWentOffline(peer.deviceID)
    f.host.flush()
    #expect(!f.audit.contains(.detached(device: peer.deviceID, session: f.key)))

    // Held, so the token is still its own: a client attaching now is an observer behind it, because
    // the device this host is holding a place for may be a second away from re-attaching.
    let next = try TestPeer()
    f.pair(next.deviceID)
    #expect(try f.attach(next)?.role == "observer")

    // And when the window closes the token moves to the client that is actually here.
    f.clock.advance(61)
    f.host.flush()
    #expect(f.audit.contains(.detached(device: peer.deviceID, session: f.key)))
    let promoted = f.link.messages(ofType: "role").last { $0.deviceID == next.deviceID }
    #expect(promoted?.role == "writer")
}

@Test func aFrameSealedByAnotherClientDoesNotAdvanceTheWritersWindow() throws {
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

    // Counter 0, sealed with the wrong key. The host tries it against the writer's cipher, where it
    // fails to authenticate; if that failure advanced the window, the writer's own counter-0 frame
    // -- the next thing that happens -- would be thrown away as a replay.
    f.host.handle(try observer.seal(Array("bad\n".utf8)))
    f.host.flush()
    f.host.handle(try writer.seal(Array("hi\n".utf8)))
    #expect(waitForShell(f, containing: "got:hi"))
}

@Test func unregisterIsAuditedAsTheSessionEndingNotAsClientsLeaving() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    let attached = try f.attach(peer)
    #expect(attached != nil)

    f.host.unregister(sessionID: f.sessionID)
    f.host.flush()

    #expect(f.audit.contains(.sessionEnded(session: f.key)))
    #expect(!f.audit.contains(.detached(device: peer.deviceID, session: f.key)))
}

@Test func takeControlAndDetachFromAnUnpairedDeviceAreIgnored() throws {
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

    // The device was unpaired while attached. Nothing it says afterwards may move the writer token
    // or tear down anyone's attachment, whatever the relay is still willing to forward.
    f.unpair(second.deviceID)
    f.link.reset()
    f.host.handle(second.message(.takeControl(to: f.hostID, sessionID: f.key)))
    f.host.handle(second.message(.detach(to: f.hostID, sessionID: f.key)))
    f.host.flush()

    #expect(f.link.messages(ofType: "role").isEmpty)
    #expect(!f.audit.contains(.tookControl(device: second.deviceID, session: f.key)))
    #expect(!f.audit.contains(.detached(device: second.deviceID, session: f.key)))
}

@Test func detachingFromOneSessionLeavesTheSameDevicesOtherSessionAlone() throws {
    let f = try HostFixture(script: "read x; printf \"one:$x\\n\"; sleep 30")
    defer { f.terminate() }
    f.register()
    let second = try f.addSession("read y; printf \"two:$y\\n\"; sleep 30", id: 5)
    defer { second.session.terminate() }

    // One device, two tabs. Each attachment has its own ephemeral key and cipher, exactly as a real
    // client's two attachments do.
    let identity = try testIdentity()
    let onFirst = TestPeer(identity: identity)
    let onSecond = TestPeer(identity: identity)
    f.pair(identity.deviceID)
    let firstAttached = try f.attach(onFirst)
    let secondAttached = try f.attach(onSecond, to: second.sessionID)
    #expect(firstAttached?.role == "writer")
    #expect(secondAttached?.role == "writer")

    // Closing one tab detaches from one session. `detach` names a session on the wire, and the spec
    // says detaching never affects anything else; a device-wide sweep here would take the other tab
    // down without a word to it -- no `session_ended`, no `role`, just a screen that stops moving.
    f.link.reset()
    f.host.handle(onFirst.message(.detach(to: f.hostID, sessionID: f.key)))
    f.host.flush()

    f.host.handle(try onSecond.seal(Array("go\n".utf8)))
    #expect(waitUntil { second.session.withTerminal { $0.transcript(options: .plainText) }.contains("two:go") })
    #expect(f.link.messages(ofType: "role").filter { $0.sessionID == second.key }.isEmpty)
    let detachments = f.audit.filter { if case .detached = $0 { return true } else { return false } }
    #expect(detachments == [.detached(device: identity.deviceID, session: f.key)])

    // And the session it did leave sends it nothing more.
    let framesAfterDetach = f.link.frames.count
    f.session.send(Array("stop\n".utf8))
    #expect(waitForShell(f, containing: "one:stop"))
    f.host.flush()
    let toSecondOnly = f.text(onSecond, Array(f.link.frames.dropFirst(framesAfterDetach)))
    #expect(toSecondOnly.isEmpty || !toSecondOnly.contains("one:stop"))
}

/// A pane registers before it has published anything about itself, so the first catalogue after
/// launch carried a summary with an empty `session_id` -- and the relay validates that field and
/// rejects the *whole* message, so every launch answered its first publish with `bad_message` and
/// the real catalogue went out only on the next update. Found by running two instances against the
/// relay and reading what it sent back.
@Test func aCatalogueCarriesTheRegisteredSessionIDEvenBeforeTheSummaryHasOne() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.session.terminate() }
    // The default `RemoteSessionInfo` a pane's summary box holds before its first update.
    f.host.register(sessionID: f.sessionID, session: f.session, summary: {
        RemoteSessionInfo(sessionID: "", title: "", cwd: "", repo: "", branch: "", process: "",
                          lastCommand: "", lastActivity: "", cols: 80, rows: 24)
    })

    #expect(waitUntil { !f.link.messages(ofType: "sessions").isEmpty })
    let published = try #require(f.link.messages(ofType: "sessions").last?.sessions)
    #expect(published.map(\.sessionID) == [f.key])
}

/// The client's socket dropped and came straight back -- which, until the relay was fixed, was
/// every ninety-one seconds. The attachment it left is the attachment it returns to: same role, no
/// second snapshot, and nothing in the audit log, because the device never left.
@Test func aClientThatComesStraightBackResumesWithNoSnapshotAndNoAuditLine() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let writer = try TestPeer()
    let observer = try TestPeer()
    f.pair(writer.deviceID)
    f.pair(observer.deviceID)
    f.register()
    #expect(try f.attach(writer)?.role == "writer")
    #expect(try f.attach(observer)?.role == "observer")

    // The relay's only word about a socket that closed.
    f.link.reset()
    f.host.handle(RemoteMessage(t: "presence", devices: [
        RemotePresence(deviceID: writer.deviceID, name: "laptop", online: false),
    ]))
    f.host.flush()
    // Nothing yet: the token stays where it was, the observer's strip does not flap, and the log
    // does not record a departure that may not have happened.
    #expect(f.link.messages(ofType: "role").isEmpty)
    #expect(f.audit.filter { $0 == .detached(device: writer.deviceID, session: f.key) }.isEmpty)

    // Back inside the window, with a fresh ephemeral key as every attach has.
    writer.rotateEphemeral()
    let again = try f.attach(writer)
    #expect(again?.role == "writer")                       // the role it left with
    #expect(f.link.frames.isEmpty)                         // and nothing was re-encrypted for it
    let order = f.link.sendOrder
    let attachedIndex = try #require(order.lastIndex(of: "attached"))
    let endIndex = try #require(order.lastIndex(of: "snapshot_end"))
    #expect(endIndex == attachedIndex + 1)                 // not one frame between them
    #expect(f.audit.filter { $0 == .attached(device: writer.deviceID, session: f.key) }.count == 1)
}

/// The other half: a session that printed while the client was away has a hole in it, and there is
/// nothing to replay from -- the host buffers nothing. So it re-snapshots, and the snapshot says so
/// by starting with the reset, which is what stops the client appending a second copy of the
/// host's screen to the first.
@Test func aClientThatMissedOutputGetsAFreshSnapshotThatReplacesTheOldOne() throws {
    let f = try HostFixture(script: "read x; printf \"got:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(try f.attach(peer) != nil)

    f.host.handle(RemoteMessage(t: "presence", devices: [
        RemotePresence(deviceID: peer.deviceID, name: "laptop", online: false),
    ]))
    f.host.flush()
    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "got:go"))
    f.host.flush()

    f.link.reset()
    peer.rotateEphemeral()
    let again = try f.attach(peer)
    #expect(again != nil)
    let order = f.link.sendOrder
    let attachedIndex = try #require(order.lastIndex(of: "attached"))
    let endIndex = try #require(order.lastIndex(of: "snapshot_end"))
    #expect(endIndex > attachedIndex + 1)                  // there *are* frames this time
    let text = f.text(peer, f.link.frames)
    // RIS and ED 3 first, which is what stops the second snapshot being appended to the first.
    #expect(text.hasPrefix(RemoteSnapshot.reset))
    // And the hole is closed: what printed while it was away is in the new snapshot.
    #expect(text.contains("got:go"))
}

/// The window C1 was about, and the reason `presence(online)` is not a branch. A relay re-registers
/// a client only when the host answers its `attach` (`relay/hub.go:446-469`), so between "the
/// client is back online" and "the client has re-attached" every chunk this host sends is dropped
/// by the relay and counted in `dropped_binary`. If a presence had cleared the hold, this re-attach
/// would look like a clean resume and the client's mirror would be permanently short -- silently,
/// which is the same class of defect as B1 itself.
@Test func outputPrintedAfterTheHostHearsTheClientIsBackStillForcesAReSnapshot() throws {
    let f = try HostFixture(script: "read x; printf \"got:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(try f.attach(peer) != nil)

    let devices = { (online: Bool) in
        RemoteMessage(t: "presence",
                      devices: [RemotePresence(deviceID: peer.deviceID, name: "laptop", online: online)])
    }
    f.host.handle(devices(false))
    f.host.flush()
    f.host.handle(devices(true))          // the socket is back; the attach has not arrived
    f.host.flush()
    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "got:go"))
    f.host.flush()

    f.link.reset()
    peer.rotateEphemeral()
    #expect(try f.attach(peer) != nil)
    let text = f.text(peer, f.link.frames)
    #expect(text.hasPrefix(RemoteSnapshot.reset))
    #expect(text.contains("got:go"))
}

/// The second face of the same bug. `acceptAttach` exists in `RemoteClientTests` precisely so "a
/// test can re-deliver the identical message the way a relay can", and a host that answered a
/// duplicated `attach` with an empty screen would be handing a client that asked for the session an
/// empty terminal. Only an attachment that was *held* can resume.
@Test func aSecondAttachFromADeviceThatNeverDroppedGetsTheWholeSnapshot() throws {
    let f = try HostFixture(script: "printf 'alpha\\n'; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(waitForShell(f, containing: "alpha"))
    #expect(try f.attach(peer) != nil)

    f.link.reset()
    peer.rotateEphemeral()
    #expect(try f.attach(peer)?.role == "writer")       // the role it already had
    let text = f.text(peer, f.link.frames)
    #expect(text.hasPrefix(RemoteSnapshot.reset))       // the mirror already holds one
    #expect(text.contains("alpha"))
}

/// The third face, and the one that arrives through ordinary traffic. `presence` is a snapshot of
/// *every* peer, re-sent whenever any of them changes, so a held client is named `offline` again and
/// again while it is away -- once per lid-opening on some other Mac. A `suspend` that re-baselined
/// on each of those would move `heldAtSequence` past the chunks this client missed and hand it a
/// resume with no snapshot; it would also arm a fresh sweep timer every time, so a client that never
/// came back would never be swept.
@Test func aSecondOfflinePresenceDuringOneHoldDoesNotEraseWhatWasMissed() throws {
    let f = try HostFixture(script: "read x; printf \"got:$x\\n\"; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(try f.attach(peer) != nil)

    let offline = RemoteMessage(t: "presence", devices: [
        RemotePresence(deviceID: peer.deviceID, name: "laptop", online: false),
    ])
    f.host.handle(offline)
    f.host.flush()
    f.session.send(Array("go\n".utf8))
    #expect(waitForShell(f, containing: "got:go"))
    f.host.flush()
    f.host.handle(offline)          // another Mac's presence changed; this one is still away
    f.host.flush()

    f.link.reset()
    peer.rotateEphemeral()
    #expect(try f.attach(peer) != nil)
    let text = f.text(peer, f.link.frames)
    #expect(text.hasPrefix(RemoteSnapshot.reset))
    #expect(text.contains("got:go"))
}

/// The device is gone for good -- unpaired, not merely asleep -- so there is nothing to come back
/// to and holding the attachment would strand the writer token on a Mac that is no longer allowed
/// to type. This is the one path that drops immediately, and the one that audits it.
@Test func aRemovedDeviceLosesItsAttachmentAtOnce() throws {
    let f = try HostFixture(script: "sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(try f.attach(peer) != nil)

    f.link.reset()
    f.unpair(peer.deviceID)
    f.host.deviceRemoved(peer.deviceID)
    f.host.flush()
    #expect(f.audit.contains(.detached(device: peer.deviceID, session: f.key)))
    // And a re-attach from it is refused by the pairing check, not answered as a resume.
    peer.rotateEphemeral()
    #expect(try f.attach(peer) == nil)
}

/// The other end of the window. A client that never comes back must not hold the writer token for
/// the rest of the session: the sweep is what turns a held attachment into a departed one, and it
/// is the *only* thing that writes the audit line for a device whose socket simply went.
@Test func aClientThatNeverComesBackIsSweptWhenTheWindowCloses() throws {
    let f = try HostFixture(script: "sleep 30", reattachWindow: 60)
    defer { f.terminate() }
    let writer = try TestPeer()
    let observer = try TestPeer()
    f.pair(writer.deviceID)
    f.pair(observer.deviceID)
    f.register()
    #expect(try f.attach(writer)?.role == "writer")
    #expect(try f.attach(observer)?.role == "observer")

    f.link.reset()
    f.host.handle(RemoteMessage(t: "presence", devices: [
        RemotePresence(deviceID: writer.deviceID, name: "laptop", online: false),
    ]))
    f.host.flush()
    #expect(f.audit.filter { $0 == .detached(device: writer.deviceID, session: f.key) }.isEmpty)

    f.clock.advance(61)
    f.host.flush()
    #expect(f.audit.contains(.detached(device: writer.deviceID, session: f.key)))
    // The token moved, and the observer was told -- which is the whole reason the sweep exists.
    let promoted = f.link.messages(ofType: "role")
        .last { $0.deviceID == observer.deviceID && $0.to == observer.deviceID }
    #expect(promoted?.role == "writer")
}

/// A device that dropped, came back, and dropped again inside one window: the first timer must not
/// sweep the second suspension's attachment before its own minute is up.
@Test func aSecondDropRestartsTheWindowRatherThanInheritingIt() throws {
    let f = try HostFixture(script: "sleep 30", reattachWindow: 60)
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(try f.attach(peer) != nil)

    let offline = RemoteMessage(t: "presence", devices: [
        RemotePresence(deviceID: peer.deviceID, name: "laptop", online: false),
    ])
    f.host.handle(offline)
    f.host.flush()
    f.clock.advance(50)
    peer.rotateEphemeral()
    #expect(try f.attach(peer) != nil)          // back, inside the window
    f.host.handle(offline)                      // and gone again
    f.host.flush()
    f.clock.advance(20)                         // 70 s since the *first* drop, 20 since this one
    f.host.flush()
    #expect(f.audit.filter { $0 == .detached(device: peer.deviceID, session: f.key) }.isEmpty)
    f.clock.advance(45)
    f.host.flush()
    #expect(f.audit.contains(.detached(device: peer.deviceID, session: f.key)))
}

/// B3, on the host's side of the wire. Attaching while the host is in a full-screen program used to
/// send one flat transcript of the *active* screen: vim's tildes landed in the client's primary
/// buffer, where the host's seven blocks should have been, and the program's exit had nothing to
/// restore. The snapshot now says what it is.
@Test func aSnapshotTakenInsideAFullScreenProgramCarriesBothBuffers() throws {
    let f = try HostFixture(script: "printf '\\033]133;A\\007$ \\033]133;B\\007vim x\\n\\033]133;C\\007'; "
                            + "printf '\\033[?1049h\\033[H~\\r\\n\\\"x\\\" [New]'; sleep 30")
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    #expect(waitForShell(f, containing: "[New]"))

    #expect(try f.attach(peer) != nil)
    let text = f.text(peer, f.link.frames)
    #expect(text.contains("vim x"))                     // the block the host still has
    #expect(text.contains("\u{1b}]133;A\u{7}"))         // and the marks its blocks are built from
    // The switch the program itself made, before the program's screen, and a cursor after it.
    let switchIndex = try #require(text.range(of: "\u{1b}[?1049h"))
    let programIndex = try #require(text.range(of: "[New]"))
    #expect(switchIndex.lowerBound < programIndex.lowerBound)
    #expect(text.contains("\u{1b}[") && text.hasSuffix("H"))
}

/// D2: the host resized while somebody was watching. `attached` says the size once and said it
/// never again, so the mirror stayed the shape the host had at attach and every line wrapped. It
/// self-healed only because the socket died every ninety-one seconds; fixing that made it
/// permanent, which is why this is in the same plan.
@Test func aResizedHostTellsEveryAttachedClientItsNewSize() throws {
    let f = try HostFixture(script: "sleep 30", debounce: 0.01)
    defer { f.terminate() }
    let peer = try TestPeer()
    f.pair(peer.deviceID)
    f.register()
    let attached = try #require(try f.attach(peer))
    #expect(attached.cols == 80)

    f.link.reset()
    f.session.resize(cols: 132, rows: 40)
    f.host.summaryChanged()
    #expect(waitUntil { f.link.messages(ofType: "role").contains { $0.cols == 132 } })
    let role = try #require(f.link.messages(ofType: "role").last { $0.cols != nil })
    #expect(role.to == peer.deviceID)
    #expect(role.deviceID == peer.deviceID)             // whose role it is, which is what the client checks
    #expect(role.role == "writer")                      // unchanged; only the size moved
    #expect(role.rows == 40)

    // And it is said once per change, not once per publish: a summary that changes nothing about
    // the size must not put a `role` on the wire for every keystroke of a title.
    f.link.reset()
    f.host.summaryChanged()
    f.host.flush()
    #expect(waitUntil { !f.link.messages(ofType: "sessions").isEmpty })
    #expect(f.link.messages(ofType: "role").isEmpty)
}
