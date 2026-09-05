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
    /// nil unless the test asked for one, in which case every delay the client takes is under the
    /// test's control rather than the scheduler's.
    let testClock: TestClock?

    init(attachTimeout: TimeInterval = 15, clock: TestClock? = nil) throws {
        identity = try testIdentity()
        link = FakeLink(deviceID: identity.deviceID)
        host = try TestPeer(isHost: true)
        testClock = clock
        let paired = self.paired
        client = RemoteClient(link: link, identity: identity, paired: { paired.devices },
                              attachTimeout: attachTimeout, clock: clock?.clock ?? .system)
        paired.add(host.deviceID)
    }

    /// A `catalogue` from this fixture's host, the way the relay forwards one.
    func catalogue(_ ids: [[UInt8]]) -> RemoteMessage {
        var m = RemoteMessage(t: "catalogue", deviceID: host.deviceID,
                              sessions: ids.map {
            RemoteSessionInfo(sessionID: RemoteID.base64url($0), title: "shell", cwd: "", repo: "",
                              branch: "", process: "zsh", lastCommand: "", lastActivity: "",
                              cols: 80, rows: 24)
        })
        m.from = host.deviceID
        return m
    }

    /// The relay's own `session_suspended`, as the deployed relay sends it: stamped with the host
    /// id it is about.
    func suspended() -> RemoteMessage {
        var m = RemoteMessage(t: "session_suspended", to: deviceID, sessionID: key)
        m.from = host.deviceID
        return m
    }

    /// A `presence` naming this fixture's host, the way the relay sends one.
    func presence(hostOnline: Bool) -> RemoteMessage {
        RemoteMessage(t: "presence",
                      devices: [RemotePresence(deviceID: host.deviceID, name: "studio",
                                               online: hostOnline)])
    }

    /// The relay's refusal of an attach, carrying the session id it answers.
    func error(_ code: String) -> RemoteMessage {
        RemoteMessage(t: "error", to: host.deviceID, code: code, sessionID: key)
    }

    var deviceID: String { identity.deviceID }

    func attach(title: String = "shell") -> RemoteClient.Attachment {
        outcome(title: title).attachment
    }

    /// The whole answer, for the tests that care whether the attachment was already owned.
    func outcome(title: String = "shell") -> RemoteClient.Outcome {
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

/// `.suspended` carries the moment it started, which no test can predict; these are how a test says
/// "suspended, whenever that was".
private func isSuspended(_ phase: AttachState.Phase?) -> Bool {
    if case .suspended = phase { return true }
    return false
}

private func suspensionTime(_ phase: AttachState.Phase) -> Date? {
    if case .suspended(_, let since) = phase { return since }
    return nil
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
                                     sessionID: f.sessionID, title: "shell").attachment

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
    #expect(attachment.state.stripText == "Session ended on studio · ⌘W to close")
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
                                     sessionID: [1, 2, 3], title: "shell").attachment

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
                                   sessionID: sessionID, title: "shell").attachment
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

/// Two *different* hosts claiming one session id -- the only way one session id can still mean two
/// attachments now that attaching twice to the same host hands back the first. The client routes by
/// session id and nothing else, so the older one will never be delivered another byte; it says so
/// rather than sitting on a frozen screen in `live`.
@Test func aSecondHostClaimingOneSessionIDEndsTheAttachmentItReplaces() throws {
    let f = try ClientFixture()
    let first = f.attach()
    let recorder = Recorder()
    recorder.watch(first)
    try f.acceptAttach()

    let other = try TestPeer(isHost: true)
    f.paired.add(other.deviceID)
    let second = f.client.attach(hostID: other.deviceID, hostName: "loft",
                                 sessionID: f.sessionID, title: "shell").attachment
    #expect(first.state.phase == .ended("studio"))
    #expect(second.state.phase == .attaching)

    // And it does not send `detach` on its way out: that would tear down the attachment that just
    // replaced it.
    #expect(f.link.messages(ofType: "detach").isEmpty)
    let attach = try #require(f.link.messages(ofType: "attach").last)
    other.rotateEphemeral()
    #expect(try other.completeAttach(attach, sessionID: f.sessionID, peerID: f.deviceID))
    f.client.handle(try other.attachedMessage(to: f.deviceID, sessionID: f.sessionID, role: "writer"))
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
    #expect(attachment.state.stripText == "Host is offline · ⌘W to close")
    #expect(attachment.state.stripButton == "Close")
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
    #expect(attachment.state.stripText == "Remote sessions turned off · ⌘W to close")
    #expect(!attachment.state.acceptsInput)
    #expect(recorder.phases == [.failed(AttachFailure.remoteTurnedOff)])
}

/// The relay refusing this device is not an outage: `RelayConnection` goes straight to `.failed`
/// without ever passing `.offline`, so nothing else tells the attachments anything. Left alone they
/// stay `live` for ever, taking keystrokes into an outbox that will never be flushed.
@Test func aRelayThatRefusesThisDeviceEndsEveryTabWithTheCode() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.acceptsInput)

    f.client.endAll(reason: AttachFailure.relayRefused("bad_token"))

    #expect(attachment.state.stripText == "Relay refused this device (bad_token) · ⌘W to close")
    #expect(!attachment.state.acceptsInput)
}

/// A setting changed under a live connection is not the switch being turned off, and the tab says
/// which of the two happened.
@Test func aSettingsChangeEndsATabWithItsOwnReason() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.endAll(reason: AttachFailure.remoteSettingsChanged)
    #expect(attachment.state.stripText == "Remote settings changed · ⌘W to close")
}

/// A hostile or broken relay can put any integer in `attached`: nothing in that message is signed
/// beyond the host's ephemeral key, and `RemoteSession` hands the two numbers straight to
/// `Terminal.resize` on the thread that draws. The attachment refuses the whole round instead --
/// no cipher, no snapshot, and `cols`/`rows` left where they were, so the mirror is never resized.
@Test func anImpossibleHostScreenSizeFailsTheAttachAndLeavesTheMirrorAlone() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(cols: 1_000_000, rows: 24)
    #expect(attachment.state.phase == .failed(AttachFailure.badGeometry))
    #expect(attachment.cols == 0)
    #expect(attachment.rows == 0)
    // And it is over: a host that answers again, sanely, does not get a second chance to build a
    // cipher into a tab that has already told the user why it is dead.
    try f.acceptAttach(cols: 80, rows: 24)
    #expect(attachment.state.phase == .failed(AttachFailure.badGeometry))
    #expect(attachment.cols == 0)
}

@Test func anOrdinaryHostScreenSizeIsTakenAsTheMirrorSize() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(cols: 160, rows: 74)
    #expect(attachment.state.phase == .snapshot)
    #expect(attachment.cols == 160)
    #expect(attachment.rows == 74)
}

/// Remove in the settings page is about this Mac in both directions. The host side stops serving
/// the device (`RemoteHost.deviceWentOffline`), and this is the other half: the tabs *this* Mac has
/// open on the device it has just disowned are ended too. Leaving them live would go on decrypting
/// somebody's screen into a window after the user said they no longer trust it.
@Test func unpairingEndsThisMacsOwnTabsOnThatHostAndNoOthers() throws {
    let f = try ClientFixture()
    let other = try TestPeer(isHost: true)
    let kept = f.client.attach(hostID: other.deviceID, hostName: "laptop",
                               sessionID: testSessionID(3), title: "vim").attachment
    let ended = f.attach()
    try f.acceptAttach()
    #expect(ended.state.phase == .snapshot)

    f.client.endAll(matching: f.host.deviceID, reason: AttachFailure.unpaired)

    #expect(ended.state.phase == .failed(AttachFailure.unpaired))
    #expect(ended.state.stripText == "This device was removed from your paired devices · ⌘W to close")
    #expect(kept.state.phase == .attaching)
    // And it is off the routing table: a frame the host sends afterwards reaches nothing.
    f.link.reset()
    try f.hostSends("still here")
    #expect(f.link.messages(ofType: "detach").isEmpty)
}

/// The geometry check must not become a way to kill a working tab. The host signs its ephemeral
/// key and the session id, not the two numbers, so anyone who saw a genuine `attached` can re-send
/// it with `cols` rewritten -- and if the size were checked before the round guards, that copy
/// would end a session that is live and running. It is a replay, and replays are dropped.
@Test func aReplayedAttachedWithAbsurdGeometryChangesNothingOnALiveAttachment() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    var answer = try f.acceptAttach(cols: 160, rows: 74)
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.phase == .live)

    answer.cols = 1_000_000
    f.client.handle(answer)

    #expect(attachment.state.phase == .live)
    #expect(attachment.cols == 160)
    #expect(attachment.rows == 74)
    // And the session still decrypts: nothing about the cipher was touched.
    let recorder = Recorder()
    recorder.watch(attachment)
    try f.hostSends("still here")
    #expect(recorder.text == "still here")
}

// MARK: - A host that drops off the relay

/// The defect a person met by closing a laptop lid: the relay synthesised `session_ended`, the tab
/// said "Session ended on <host>" -- which was false, the session was running the whole time -- and
/// nothing ever brought it back. The relay now says `session_suspended` and this is what it means.
@Test func aSuspendedSessionKeepsItsTabAndRefusesInput() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.acceptsInput)
    let recorder = Recorder()
    recorder.watch(attachment)

    f.client.handle(f.suspended())

    let suspendedAt = try #require(suspensionTime(attachment.state.phase))
    #expect(attachment.state.phase == .suspended("studio", since: suspendedAt))
    #expect(attachment.state.stripText?.hasPrefix("studio has been offline since ") == true)
    #expect(attachment.state.stripText?.hasSuffix("waiting for it to come back · ⌘W to close") == true)
    #expect(attachment.state.severity == .warning)
    #expect(!attachment.state.acceptsInput)
    #expect(recorder.phases.count == 1)
    #expect(isSuspended(recorder.phases.first))
}

/// A suspended tab is not a dead one: input is refused, but the attachment is still routed to, and
/// a keystroke typed at it goes nowhere rather than being sealed with a cipher the relay has
/// already forgotten.
@Test func aSuspendedTabSendsNothing() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.client.handle(f.suspended())
    f.link.reset()

    attachment.send(Array("ls\n".utf8))

    #expect(f.link.frames.isEmpty)
}

/// The whole recovery, end to end: the host comes back, publishes its catalogue, and this side
/// re-attaches with a *new* ephemeral key and takes a fresh snapshot -- which is the only way to
/// catch up on what the session printed while nobody was watching.
@Test func aHostThatComesBackWithTheSessionIsReattachedTo() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    let firstKey = try #require(f.link.messages(ofType: "attach").last?.ephemeralPubkey)
    f.client.handle(f.suspended())
    f.link.reset()
    let recorder = Recorder()
    recorder.watch(attachment)

    f.client.handle(f.presence(hostOnline: true))
    f.client.handle(f.catalogue([f.sessionID]))

    let sent = try #require(f.link.messages(ofType: "attach").last)
    #expect(sent.ephemeralPubkey != firstKey, "a re-attach must not reuse the suspended round's key")
    #expect(attachment.state.phase == .reconnecting)

    try f.acceptAttach(role: "writer")
    #expect(attachment.state.phase == .snapshot)
    try f.hostSends("back on the air\n")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))

    #expect(attachment.state.phase == .live)
    #expect(attachment.state.acceptsInput)
    #expect(recorder.text == "back on the air\n")
    #expect(recorder.phases == [.reconnecting, .snapshot, .live])
}

/// The other answer the host can give: it is back, and that session is not in its list. Nothing
/// else can ever tell a suspended tab its session really has gone -- the `session_ended` that would
/// have said so was never sent, because the host was not there to send it.
@Test func aHostThatComesBackWithoutTheSessionEndsTheTab() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.suspended())
    f.link.reset()

    f.client.handle(f.presence(hostOnline: true))
    f.client.handle(f.catalogue([testSessionID(7)]))

    #expect(attachment.state.phase == .ended("studio"))
    #expect(attachment.state.stripText == "Session ended on studio · ⌘W to close")
    #expect(f.link.messages(ofType: "attach").isEmpty, "an ended session must not be attached to")
}

/// A catalogue is not an event about a working tab. One arriving while the session is live -- they
/// arrive whenever anything on the host changes its title -- must not restart the attach.
@Test func aCatalogueDoesNothingToALiveTab() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.link.reset()

    f.client.handle(f.catalogue([]))

    #expect(attachment.state.phase == .live)
    #expect(f.link.messages(ofType: "attach").isEmpty)
}

// MARK: - The re-attach race

/// The second thing the lid-closing found: after an outage both Macs reconnect at their own pace,
/// and a client that gets in first is told `no_such_session` about a session that is about to be
/// re-published a second later. Believing that answer killed the tab.
@Test func aReattachWaitsOutNoSuchSessionAndSucceedsWhenTheHostCatchesUp() throws {
    let clock = TestClock()
    let f = try ClientFixture(clock: clock)
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.client.linkDidDisconnect()
    f.link.reset()
    _ = clock.takeDelays()

    f.client.linkDidReconnect()
    #expect(f.link.messages(ofType: "attach").count == 1)

    // The host has not re-published yet. Three refusals in a row, and the tab still says the one
    // true thing about them: this is taking a while.
    for _ in 0..<3 {
        f.client.handle(f.error("no_such_session"))
        #expect(attachment.state.phase == .reconnecting)
        #expect(attachment.state.stripText == "Reconnecting…")
        clock.advance(20)
    }
    #expect(f.link.messages(ofType: "attach").count == 4)

    try f.acceptAttach(role: "writer")
    #expect(attachment.state.phase == .snapshot)
}

/// The delays themselves: 1, 2, 4 -- `Backoff`, not a fixed poll, so a host that is really gone is
/// asked about a handful of times rather than sixty.
@Test func theReattachRetriesBackOff() throws {
    let clock = TestClock()
    let f = try ClientFixture(attachTimeout: 900, clock: clock)
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.linkDidReconnect()
    _ = clock.takeDelays()

    for _ in 0..<3 {
        f.client.handle(f.error("host_offline"))
        clock.advance(20)
    }

    // The attach timeout is armed per round as well; the retry delays are the ones under 16 s.
    #expect(clock.takeDelays().filter { $0 <= 15 } == [1, 2, 4])
    #expect(attachment.state.phase == .reconnecting)
}

/// A minute of asking is enough. After it the tab says nobody answered -- not the relay's last
/// code, which by then describes one attempt out of several.
@Test func aReattachThatNeverSucceedsGivesUpAfterAMinute() throws {
    let clock = TestClock()
    let f = try ClientFixture(attachTimeout: 900, clock: clock)
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.linkDidReconnect()

    for _ in 0..<12 {
        f.client.handle(f.error("host_offline"))
        clock.advance(10)
    }

    #expect(attachment.state.phase == .failed(AttachFailure.noAnswer))
    #expect(attachment.state.stripText == "No answer from the host · ⌘W to close")
}

/// Only the two codes a race produces are waited out. `not_paired` is a settled answer: retrying it
/// for a minute would leave the tab saying "Reconnecting…" about something that will never connect.
@Test func aSettledRefusalDuringAReattachIsShownAtOnce() throws {
    let clock = TestClock()
    let f = try ClientFixture(clock: clock)
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.linkDidReconnect()

    f.client.handle(f.error("not_paired"))

    #expect(attachment.state.phase == .failed("Not paired with this device"))
}

/// The *first* attach of all has no race to lose: nothing was ever attached, so `host_offline`
/// means what it says and the tab must say it rather than spending a minute pretending.
@Test func theFirstAttachDoesNotRetry() throws {
    let clock = TestClock()
    let f = try ClientFixture(clock: clock)
    let attachment = f.attach()

    f.client.handle(f.error("host_offline"))

    #expect(attachment.state.phase == .failed("Host is offline"))
}

/// A suspension's re-attach is the same race and gets the same patience: the catalogue that woke it
/// can arrive a moment before the host has finished publishing.
@Test func aSuspendedReattachAlsoWaitsOutARefusal() throws {
    let clock = TestClock()
    let f = try ClientFixture(clock: clock)
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.suspended())
    f.client.handle(f.presence(hostOnline: true))
    f.client.handle(f.catalogue([f.sessionID]))

    f.client.handle(f.error("no_such_session"))
    #expect(attachment.state.phase == .reconnecting)

    clock.advance(5)
    try f.acceptAttach(role: "writer")
    #expect(attachment.state.phase == .snapshot)
}

// MARK: - Attaching twice

/// Choosing the same palette row twice used to end the first tab with "Session ended on <host>" --
/// a sentence about the host that was not true about anything. There is one attachment per session
/// id because a data frame carries nothing else to route on, so the second caller gets the first.
@Test func attachingTwiceToOneSessionReturnsTheSameAttachment() throws {
    let f = try ClientFixture()
    let first = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.link.reset()

    let second = f.attach()

    #expect(second === first)
    #expect(first.state.phase == .live)
    #expect(f.link.messages(ofType: "attach").isEmpty, "a second attach must not go on the wire")
}

/// A tab that ended is not in the way of a new one: re-attaching after "Session ended" is a fresh
/// attachment, which is what makes the palette row work again once the host re-opens the session.
@Test func attachingAgainAfterATabEndedMakesANewAttachment() throws {
    let f = try ClientFixture()
    let first = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.sessionEnded(to: f.deviceID, sessionID: f.key)))
    #expect(first.state.phase == .ended("studio"))

    let second = f.attach()

    #expect(second !== first)
    #expect(second.state.phase == .attaching)
}

/// The exact order the deployed relay sends when a host's socket goes: `session_suspended`, then
/// that host's now-*empty* `catalogue`, and only then the `presence` saying it is gone. Believing
/// the first catalogue ended the tab half a second after suspending it with the very sentence the
/// suspended state exists to stop being told, which is what a real run against the relay showed.
@Test func theEmptyCatalogueAHostLeavesBehindDoesNotEndTheTab() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))

    f.client.handle(f.suspended())
    f.client.handle(f.catalogue([]))
    f.client.handle(f.presence(hostOnline: false))

    #expect(isSuspended(attachment.state.phase))

    // And when the host really does come back with nothing open, the tab does end: presence first,
    // then the catalogue, which is the order a reconnecting host produces.
    f.client.handle(f.presence(hostOnline: true))
    f.client.handle(f.catalogue([]))
    #expect(attachment.state.phase == .ended("studio"))
}

// MARK: - One attachment, one owner

/// The freeze a second window caused. `onBytes`/`onState` are one slot each, so a second
/// `RemoteSession` wiring itself in did not share the stream -- it took it, and the window that had
/// it was left with a tab still drawn, still accepting keystrokes, and never showing another byte.
/// `attach` says so, and the caller goes to the window that owns it instead.
@Test func attachingToASessionAnotherOwnerAlreadyHasSaysSo() throws {
    let f = try ClientFixture()
    let first = f.outcome()
    #expect(!first.wasAlreadyOpen)
    try f.acceptAttach(role: "writer")
    // What a `RemoteSession` does when it starts.
    first.attachment.onBytes = { _ in }
    first.attachment.onState = { _ in }

    let second = f.outcome()

    #expect(second.attachment === first.attachment)
    #expect(second.wasAlreadyOpen)
}

/// An attachment nobody has wired into yet is not "already open": that is the ordinary case of a
/// palette row chosen twice in the moment before the tab exists, and the caller should get on with
/// making the tab rather than refusing it.
@Test func anUnownedAttachmentIsNotReportedAsAlreadyOpen() throws {
    let f = try ClientFixture()
    _ = f.outcome()

    #expect(!f.outcome().wasAlreadyOpen)
}

// MARK: - A blip on this Mac's socket while the host is away

/// The defect: `.suspended` is not "ended", so the link's own disconnect/reconnect drove a suspended
/// tab into `.reconnecting` -- which started a sixty-second window against a host that was still
/// gone and landed the tab on "No answer from the host". An outage on this side turned into a
/// verdict about the other one.
@Test func aBlipOnThisMacsSocketLeavesASuspendedTabSuspended() throws {
    let clock = TestClock()
    let f = try ClientFixture(clock: clock)
    let attachment = f.attach()
    try f.acceptAttach(role: "writer")
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.client.handle(f.suspended())
    #expect(isSuspended(attachment.state.phase))
    f.link.reset()

    f.client.linkDidDisconnect()
    #expect(isSuspended(attachment.state.phase))
    f.client.linkDidReconnect()
    #expect(isSuspended(attachment.state.phase))
    #expect(f.link.messages(ofType: "attach").isEmpty,
            "a suspended tab must not re-attach on this side's reconnect: the host is still gone")

    // A minute of the retry window would have expired by now, had one been started.
    clock.advance(90)
    #expect(isSuspended(attachment.state.phase))

    // And the ordinary wake-up still works afterwards.
    f.client.handle(f.presence(hostOnline: true))
    f.client.handle(f.catalogue([f.sessionID]))
    #expect(attachment.state.phase == .reconnecting)
    try f.acceptAttach(role: "writer")
    #expect(attachment.state.phase == .snapshot)
}

/// A `session_suspended` for a tab that never got past "Attaching…" has no transcript to keep and
/// no snapshot to come back to. It is an attach that did not happen, and says so rather than
/// offering to reattach to something the user never saw.
@Test func aHostThatGoesBeforeTheAttachLandsFailsRatherThanSuspends() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    #expect(attachment.state.phase == .attaching)

    f.client.handle(f.suspended())

    #expect(attachment.state.phase == .failed(AttachFailure.hostWentOfflineDuringAttach))
    #expect(attachment.state.stripText
        == "Host went offline before the session attached · ⌘W to close")
}
