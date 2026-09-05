import CryptoKit
import Foundation
import NyxCore
import Testing
@testable import NyxRemote

/// A client, its fake wire, and the host it thinks it is talking to.
private final class ClientFixture {
    let link: FakeLink
    let identity: DeviceIdentity
    let client: RemoteClient
    let host: TestPeer
    let paired = PairedBox()
    let sessionID = testSessionID()
    let key = RemoteID.base64url(testSessionID())

    init(attachTimeout: TimeInterval = 15) throws {
        identity = try testIdentity()
        link = FakeLink(deviceID: identity.deviceID)
        host = try TestPeer(isHost: true)
        let paired = self.paired
        client = RemoteClient(link: link, identity: identity, paired: { paired.devices },
                              attachTimeout: attachTimeout)
        paired.add(host.deviceID)
    }

    var deviceID: String { identity.deviceID }

    func attach(title: String = "shell") -> RemoteClient.Attachment {
        client.attach(hostID: host.deviceID, hostName: "studio", sessionID: sessionID, title: title)
    }

    /// The host's side of the handshake: verify the client's key, answer `attached`. Returns the
    /// answer, so a test can re-deliver the identical message the way a relay can.
    @discardableResult
    func acceptAttach(role: String = "writer", cols: Int = 80, rows: Int = 24) throws -> RemoteMessage {
        let attach = try #require(link.messages(ofType: "attach").last)
        // Every accepted attach is a fresh round on the host too, with a key of its own.
        host.rotateEphemeral()
        let accepted = try host.completeAttach(attach, sessionID: sessionID, peerID: deviceID)
        #expect(accepted)
        let answer = try host.attachedMessage(to: deviceID, sessionID: sessionID, role: role, cols: cols, rows: rows)
        client.handle(answer)
        return answer
    }

    func hostSends(_ text: String) throws {
        client.handle(try host.seal(Array(text.utf8)))
    }
}

/// Collects what an attachment reported, so a test can assert on the whole sequence rather than on
/// the state it happens to be in at the end.
private final class Recorder {
    private let lock = NSLock()
    private(set) var phases: [AttachState.Phase] = []
    private(set) var roles: [AttachState.Role] = []
    private(set) var bytes: [UInt8] = []

    func watch(_ attachment: RemoteClient.Attachment) {
        attachment.onState = { [self] state in
            lock.lock()
            phases.append(state.phase)
            roles.append(state.role)
            lock.unlock()
        }
        attachment.onBytes = { [self] chunk in
            lock.lock()
            bytes += chunk
            lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    func phaseCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return phases.count
    }
}

@Test func attachPutsASignedAttachOnTheWireAndWaitsInAttaching() throws {
    let f = try ClientFixture()
    let attachment = f.attach(title: "vim")

    #expect(attachment.state.phase == .attaching)
    #expect(attachment.state.role == .observer)     // nothing may be typed until the host says so
    #expect(attachment.state.tabTitle == "⟵ studio · vim")
    let sent = try #require(f.link.messages(ofType: "attach").first)
    #expect(sent.to == f.host.deviceID)
    #expect(sent.sessionID == f.key)
    let pubkey = try #require(sent.ephemeralPubkey)
    let sig = try #require(sent.sig)
    #expect(E2ESession.verifyPeer(pubkey: pubkey, sig: sig, sessionID: f.sessionID, deviceID: f.deviceID))
}

@Test func theHostsAnswerCarriesTheAttachmentThroughSnapshotToLive() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)

    try f.acceptAttach(role: "writer", cols: 132, rows: 40)
    #expect(attachment.state.phase == .snapshot)
    #expect(attachment.state.role == .writer)
    #expect(attachment.cols == 132 && attachment.rows == 40)
    // Nothing may be typed yet: the host is still sending scrollback, and a keystroke now would be
    // interleaved into it.
    #expect(!attachment.state.acceptsInput)

    try f.hostSends("scrollback\r\n")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))

    #expect(attachment.state.phase == .live)
    #expect(attachment.state.acceptsInput)
    #expect(recorder.text == "scrollback\r\n")
    #expect(recorder.phases == [.snapshot, .live])
}

@Test func bytesArriveInOrderAndAReplayedFrameIsDropped() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)
    try f.acceptAttach()

    let first = try f.host.seal(Array("one".utf8))
    let second = try f.host.seal(Array("two".utf8))
    f.client.handle(first)
    f.client.handle(second)
    f.client.handle(first)   // the relay re-delivering, or somebody replaying
    // Out of order: `second` has already been accepted, so `first` cannot be trusted to be new.
    #expect(recorder.text == "onetwo")
}

@Test func anAttachedMessageWhoseSignatureDoesNotVerifyIsIgnored() throws {
    let f = try ClientFixture()
    let attachment = f.attach()

    // A key signed by somebody else: the relay substituting its own ephemeral key looks exactly
    // like this, and accepting it would hand the relay the plaintext.
    let impostor = try TestPeer(isHost: true)
    var forged = try impostor.attachedMessage(to: f.deviceID, sessionID: f.sessionID, role: "writer")
    forged.from = f.host.deviceID
    f.client.handle(forged)

    #expect(attachment.state.phase == .attaching)
}

@Test func anAttachedMessageFromAnUnpairedDeviceIsIgnored() throws {
    let f = try ClientFixture()
    let stranger = try TestPeer(isHost: true)
    let attachment = f.client.attach(hostID: stranger.deviceID, hostName: "stranger",
                                     sessionID: f.sessionID, title: "shell")

    let attach = try #require(f.link.messages(ofType: "attach").last)
    try stranger.completeAttach(attach, sessionID: f.sessionID, peerID: f.deviceID)
    f.client.handle(try stranger.attachedMessage(to: f.deviceID, sessionID: f.sessionID, role: "writer"))

    #expect(attachment.state.phase == .attaching)
}

@Test func onlyAWriterPutsInputOnTheWireAndTheHostCanOpenIt() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "observer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))

    #expect(!attachment.state.acceptsInput)
    attachment.send(Array("rm -rf /\n".utf8))
    #expect(f.link.frames.isEmpty)   // an observer's keystrokes never leave this Mac

    f.client.handle(f.host.message(.role(to: f.deviceID, sessionID: f.key,
                                         deviceID: f.deviceID, role: "writer")))
    #expect(attachment.state.role == .writer)
    attachment.send(Array("ls\n".utf8))
    let frame = try #require(f.link.frames.first)
    #expect(f.host.open(frame).map { String(decoding: $0, as: UTF8.self) } == "ls\n")
}

@Test func aRoleMessageAboutAnotherDeviceDoesNotChangeThisOnesRole() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")

    // Someone else was made an observer. Read carelessly, this message demotes *this* client -- and
    // the host tells everyone about everyone, so it arrives on every writer's socket every time an
    // observer joins.
    let other = try TestPeer()
    f.client.handle(f.host.message(.role(to: f.deviceID, sessionID: f.key,
                                         deviceID: other.deviceID, role: "observer")))
    #expect(attachment.state.role == .writer)

    // The same message about this device does change it.
    f.client.handle(f.host.message(.role(to: f.deviceID, sessionID: f.key,
                                         deviceID: f.deviceID, role: "observer")))
    #expect(attachment.state.role == .observer)
}

@Test func sessionEndedLeavesTheAttachmentNamingTheHost() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)
    try f.acceptAttach()
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))

    f.client.handle(f.host.message(.sessionEnded(to: f.deviceID, sessionID: f.key)))

    #expect(attachment.state.phase == .ended("studio"))
    #expect(attachment.state.stripText == "Session ended on studio")
    #expect(!attachment.state.acceptsInput)
    // Nothing arrives after the end, and nothing more is said about it.
    let phases = recorder.phaseCount()
    try f.hostSends("late")
    f.client.handle(f.host.message(.sessionEnded(to: f.deviceID, sessionID: f.key)))
    #expect(recorder.text.isEmpty)
    #expect(recorder.phaseCount() == phases)
}

@Test func detachTellsTheHostAndStopsTheStream() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)
    try f.acceptAttach()

    attachment.detach()
    let detach = try #require(f.link.messages(ofType: "detach").first)
    #expect(detach.to == f.host.deviceID)
    #expect(detach.sessionID == f.key)

    try f.hostSends("after")
    #expect(recorder.text.isEmpty)
    attachment.send(Array("x".utf8))
    #expect(f.link.frames.isEmpty)
}

@Test func takeControlAsksTheHost() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "observer")

    attachment.takeControl()

    let m = try #require(f.link.messages(ofType: "take_control").first)
    #expect(m.to == f.host.deviceID)
    #expect(m.sessionID == f.key)
    // The role does not change here: the host arbitrates, and a client that changed its own mind
    // would let two clients believe they were the writer at once.
    #expect(attachment.state.role == .observer)
}

@Test func linkDidReconnectReattachesWithAFreshKeyAndTakesANewSnapshot() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)
    try f.acceptAttach()
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    let firstKey = f.link.messages(ofType: "attach").first?.ephemeralPubkey

    f.client.linkDidReconnect()
    #expect(attachment.state.phase == .reconnecting)
    #expect(!attachment.state.acceptsInput)

    let attaches = f.link.messages(ofType: "attach")
    #expect(attaches.count == 2)
    // A new ephemeral key per attach is the forward secrecy the spec asks for: reusing the old one
    // would tie the new stream to a key that has already been used on a socket that failed.
    #expect(attaches.last?.ephemeralPubkey != firstKey)

    try f.acceptAttach(role: "writer")
    try f.hostSends("fresh snapshot\r\n")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))

    #expect(attachment.state.phase == .live)
    #expect(recorder.text == "fresh snapshot\r\n")
    #expect(recorder.phases == [.snapshot, .live, .reconnecting, .snapshot, .live])
}

@Test func anEndedAttachmentIsNotReattachedOnReconnect() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.handle(f.host.message(.sessionEnded(to: f.deviceID, sessionID: f.key)))

    f.client.linkDidReconnect()

    #expect(f.link.messages(ofType: "attach").count == 1)
    #expect(attachment.state.phase == .ended("studio"))
}

@Test func aSessionIDThatCannotBeOneNeverReachesTheRelay() throws {
    let f = try ClientFixture()
    let attachment = f.client.attach(hostID: f.host.deviceID, hostName: "studio",
                                     sessionID: [1, 2, 3], title: "shell")

    // Every session id on the wire is 16 bytes. Sending this would have the relay answer
    // `no_such_session` at best; the tab says so itself instead of spinning on "Attaching…".
    #expect(f.link.messages(ofType: "attach").isEmpty)
    #expect(attachment.state.phase == .ended("studio"))
}

@Test func aRealShellReachesARealClientThroughTheHostAndBack() throws {
    let hostIdentity = try testIdentity()
    let clientIdentity = try testIdentity()
    let hostLink = FakeLink(deviceID: hostIdentity.deviceID)
    let clientLink = FakeLink(deviceID: clientIdentity.deviceID)
    let paired = PairedBox()
    paired.add(hostIdentity.deviceID)
    paired.add(clientIdentity.deviceID)

    let host = RemoteHost(link: hostLink, identity: hostIdentity, paired: { paired.devices },
                          audit: { _ in }, snapshotLines: 200)
    let client = RemoteClient(link: clientLink, identity: clientIdentity, paired: { paired.devices })

    // The relay stamps `from` on everything it forwards; these two closures are the whole of it.
    hostLink.onMessage = { m in
        var out = m
        out.from = hostIdentity.deviceID
        client.handle(out)
    }
    hostLink.onFrame = { client.handle($0) }
    clientLink.onMessage = { m in
        var out = m
        out.from = clientIdentity.deviceID
        host.handle(out)
    }
    clientLink.onFrame = { host.handle($0) }

    let session = try shellSession("printf 'ready\\n'; read x; printf \"typed:$x\\n\"; sleep 30")
    defer { session.terminate() }
    session.start()
    let sessionID = testSessionID(4)
    #expect(waitUntil { session.withTerminal { $0.transcript(options: .plainText) }.contains("ready") })
    host.register(sessionID: sessionID, session: session, summary: { testSummary(sessionID) })
    host.flush()

    let attachment = client.attach(hostID: hostIdentity.deviceID, hostName: "studio",
                                   sessionID: sessionID, title: "shell")
    let recorder = Recorder()
    recorder.watch(attachment)
    host.flush()

    #expect(waitUntil { attachment.state.phase == .live })
    #expect(attachment.state.role == .writer)
    #expect(recorder.text.contains("ready"))

    // And back the other way: what the client types is decrypted by the host and written to the PTY,
    // and what the shell answers comes back as live bytes.
    attachment.send(Array("hello\n".utf8))
    #expect(waitUntil { recorder.text.contains("typed:hello") })
    // The keystroke's echo and the shell's answer, both of them, in order: a client that got only
    // the second would be one that had silently lost the first chunk after its snapshot.
    #expect(recorder.text.hasSuffix("hello\r\ntyped:hello\r\n"))
    #expect(recorder.text.components(separatedBy: "ready").count == 2)   // the snapshot, once
}

@Test func attachingAgainToOneSessionEndsTheAttachmentItReplaces() throws {
    let f = try ClientFixture()
    let first = f.attach()
    let recorder = Recorder()
    recorder.watch(first)
    try f.acceptAttach()

    // The host keys its attachments by device and session, so a second attach from this device
    // replaces the first there too. The displaced one must say so rather than sit on a frozen
    // screen in `live` waiting for bytes that will never be routed to it again.
    let second = f.attach()
    #expect(first.state.phase == .ended("studio"))
    #expect(second.state.phase == .attaching)

    // And it does not send `detach` on its way out: that would tear down the attachment that just
    // replaced it.
    #expect(f.link.messages(ofType: "detach").isEmpty)
    try f.acceptAttach()
    #expect(second.state.phase == .snapshot)
    try f.hostSends("only for the new one")
    #expect(recorder.text.isEmpty)
}

@Test func aReplayedAttachedDoesNotRestartTheStream() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)
    let answer = try f.acceptAttach()
    let firstFrame = try f.host.seal(Array("snapshot".utf8))
    f.client.handle(firstFrame)
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.phase == .live)

    // The relay re-delivering the same `attached`, or an attacker replaying it. Rebuilding the
    // cipher from it would derive the very same keys with a fresh replay window -- so every frame
    // of the session so far could be played back into the terminal -- and would drop the tab from
    // `live` to `snapshot` while the stream carried on.
    f.client.handle(answer)

    #expect(attachment.state.phase == .live)
    #expect(recorder.phases == [.snapshot, .live])
    f.client.handle(firstFrame)
    #expect(recorder.text == "snapshot")
}

@Test func concurrentSendsReachTheWireInCounterOrder() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))

    // Two panes' worth of typing at once -- a paste on one thread while a key repeat runs on
    // another. Sealing and sending must be one step: a counter taken under the lock and transmitted
    // after it can arrive behind a later one, and the host, which rejects anything at or below the
    // last counter it accepted, throws the earlier keystroke away for good.
    //
    // Made deterministic rather than left to the scheduler: the one-byte send is held up inside the
    // link, which is where a real link is slow, and the two-byte one is not. If the seal is not in
    // the same critical section as the transmit, the second overtakes the first.
    f.link.beforeAppendingFrame = { frame in
        if frame.ciphertext.count == 1 + 16 { usleep(20_000) }
    }
    let slowSendStarted = DispatchSemaphore(value: 0)
    let slowSendFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        slowSendStarted.signal()
        attachment.send([0x41])
        slowSendFinished.signal()
    }
    slowSendStarted.wait()
    usleep(3_000)
    attachment.send([0x42, 0x43])
    slowSendFinished.wait()
    #expect(f.link.frames.map(\.counter) == [0, 1])

    f.link.beforeAppendingFrame = nil
    f.link.reset()
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        attachment.send([UInt8(i % 256)])
    }

    let counters = f.link.frames.map(\.counter)
    #expect(counters == (2..<202).map { UInt64($0) })
    // And the host opens all 200 in the order they arrived, which is the same statement made by
    // the side that actually enforces it.
    #expect(f.link.frames.allSatisfy { f.host.open($0) != nil })
}

// MARK: - Attaches that never happen

@Test func aRelayErrorForThisSessionFailsTheAttachInWords() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)

    f.client.handle(RemoteMessage(t: "error", to: f.host.deviceID, code: "host_offline",
                                  sessionID: f.key, message: "device offline"))

    #expect(attachment.state.phase == .failed("Host is offline"))
    #expect(attachment.state.stripText == "Host is offline")
    #expect(attachment.state.closesOnNextKey)
    #expect(recorder.phases == [.failed("Host is offline")])
}

@Test func eachRelayErrorCodeReachesTheStripAsItsOwnSentence() throws {
    for (code, sentence) in [("not_paired", "Not paired with this device"),
                             ("no_such_session", "That session no longer exists"),
                             ("too_many", "The host has too many viewers")] {
        let f = try ClientFixture()
        let attachment = f.attach()
        f.client.handle(RemoteMessage(t: "error", code: code, sessionID: f.key))
        #expect(attachment.state.phase == .failed(sentence))
    }
}

/// A pairing error (`pair_expired`) carries no `session_id`, and an error for somebody else's
/// session carries one that is not ours. Neither may knock this tab over.
@Test func anErrorForAnotherSessionOrNoSessionIsIgnored() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    f.client.handle(RemoteMessage(t: "error", code: "pair_expired"))
    f.client.handle(RemoteMessage(t: "error", code: "host_offline",
                                  sessionID: RemoteID.base64url(testSessionID(7))))
    #expect(attachment.state.phase == .attaching)
}

/// The relay echoes the `to` of the request that failed. An error naming a different host is an
/// answer to somebody else's attach on the same session id, which cannot happen with one host per
/// session -- but if it did, believing it would close a live tab.
@Test func anErrorNamingADifferentHostIsIgnored() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    f.client.handle(RemoteMessage(t: "error", to: RemoteID.base64url([UInt8](repeating: 3, count: 32)),
                                  code: "host_offline", sessionID: f.key))
    #expect(attachment.state.phase == .attaching)
}

@Test func anErrorAfterTheSessionIsLiveIsIgnored() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.phase == .live)
    f.client.handle(RemoteMessage(t: "error", code: "host_offline", sessionID: f.key))
    #expect(attachment.state.phase == .live)
}

@Test func anAttachNobodyAnswersFailsRatherThanWaitingForEver() throws {
    let f = try ClientFixture(attachTimeout: 0.05)
    let attachment = f.attach()
    let recorder = Recorder()
    recorder.watch(attachment)
    #expect(waitUntil(1) { attachment.state.phase == .failed("No answer from the host") })
    #expect(recorder.phases == [.failed("No answer from the host")])
}

@Test func anAttachThatIsAnsweredDoesNotLaterTimeOut() throws {
    let f = try ClientFixture(attachTimeout: 0.05)
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    usleep(150_000)
    #expect(attachment.state.phase == .live)
}

/// A reconnect arms a fresh timeout, and answering *that* round stops it: a client whose socket
/// came back and re-attached successfully must not be knocked into `failed` by the timer the
/// re-attach armed.
@Test func aReconnectThatIsAnsweredDoesNotTimeOutEither() throws {
    let f = try ClientFixture(attachTimeout: 0.05)
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.linkDidReconnect()
    #expect(attachment.state.phase == .reconnecting)
    try f.acceptAttach()
    usleep(150_000)
    #expect(attachment.state.phase == .snapshot)
}

/// The stale-round replay Task 7 parked: an `attached` from the previous round, re-delivered while
/// this attachment is `reconnecting`, used to be accepted and built a cipher pairing the *new*
/// ephemeral key with the old round's -- decrypting nothing the host now sends, so the tab sat at
/// `snapshot` for ever. The attachment now only accepts an `attached` for the key it currently has
/// outstanding, so the stale one is dropped and the round's own answer still lands.
@Test func anAttachedFromThePreviousRoundIsNotAcceptedAfterAReconnect() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let stale = try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.phase == .live)

    f.client.linkDidReconnect()
    #expect(attachment.state.phase == .reconnecting)
    f.client.handle(stale)
    #expect(attachment.state.phase == .reconnecting)   // the old round's answer means nothing now

    try f.acceptAttach(role: "observer")
    #expect(attachment.state.phase == .snapshot)
    #expect(attachment.state.role == .observer)
}

/// Two `attached` messages inside one round: the second is a duplicate whatever sent it, and
/// rebuilding the cipher from it would wind the replay window back to zero.
@Test func aSecondAttachedInsideOneRoundIsDropped() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    let answer = try f.acceptAttach()
    #expect(attachment.state.phase == .snapshot)
    let recorder = Recorder()
    recorder.watch(attachment)
    f.client.handle(answer)
    #expect(recorder.phases.isEmpty)
}

// MARK: - The socket going away

/// The gap this closes: nothing told a client its socket had dropped, so an attached tab stayed
/// `live` -- no "Reconnecting…", and every keystroke still accepted, sealed with a cipher the host
/// has already thrown away and flushed at it when the socket comes back.
@Test func aDroppedSocketPutsEveryLiveAttachmentIntoReconnecting() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.phase == .live)
    #expect(attachment.state.acceptsInput)

    f.client.linkDidDisconnect()

    #expect(attachment.state.phase == .reconnecting)
    #expect(!attachment.state.acceptsInput)
    f.link.reset()
    attachment.send([0x61])
    #expect(f.link.frames.isEmpty)   // nothing may be sealed for a session that has gone
}

/// It must not re-attach by itself: the socket is *down*, so an `attach` now would only be queued
/// in the outbox and then sent behind the one `linkDidReconnect` sends when it comes back.
@Test func aDroppedSocketSendsNothing() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.link.reset()
    f.client.linkDidDisconnect()
    #expect(f.link.messages.isEmpty)
    #expect(attachment.state.phase == .reconnecting)
}

/// A drop then a reconnect is one round trip: `reconnecting` on the strip, then a fresh attach.
@Test func aDropFollowedByAReconnectAttachesAgain() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.linkDidDisconnect()
    f.link.reset()
    f.client.linkDidReconnect()
    #expect(f.link.messages(ofType: "attach").count == 1)
    try f.acceptAttach(role: "observer")
    #expect(attachment.state.phase == .snapshot)
}

@Test func aDroppedSocketLeavesAnEndedAttachmentAlone() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.handle(f.host.message(.sessionEnded(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.phase == .ended("studio"))
    f.client.linkDidDisconnect()
    #expect(attachment.state.phase == .ended("studio"))
}

/// Turning remote sessions off, or changing the relay, tears the client down. Every open tab has to
/// be told, or it sits on a screen that has quietly stopped moving with no way to know why.
@Test func endingEveryAttachmentSaysWhyAndStopsAcceptingInput() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    let recorder = Recorder()
    recorder.watch(attachment)

    f.client.endAll(reason: AttachFailure.remoteTurnedOff)

    // `.failed`, not `.ended`: `.ended`'s payload is a *machine name*, interpolated into "Session
    // ended on <host>", and nothing on the host ended -- this side stopped. `.failed` shows the
    // reason as the whole sentence, and behaves identically otherwise.
    #expect(attachment.state.phase == .failed(AttachFailure.remoteTurnedOff))
    #expect(attachment.state.stripText == "Remote sessions turned off")
    #expect(attachment.state.closesOnNextKey)
    #expect(!attachment.state.acceptsInput)
    #expect(recorder.phases == [.failed(AttachFailure.remoteTurnedOff)])
}
