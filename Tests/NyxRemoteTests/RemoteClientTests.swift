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

    init() throws {
        identity = try testIdentity()
        link = FakeLink(deviceID: identity.deviceID)
        host = try TestPeer(isHost: true)
        let paired = self.paired
        client = RemoteClient(link: link, identity: identity, paired: { paired.devices })
        paired.add(host.deviceID)
    }

    var deviceID: String { identity.deviceID }

    func attach(title: String = "shell") -> RemoteClient.Attachment {
        client.attach(hostID: host.deviceID, hostName: "studio", sessionID: sessionID, title: title)
    }

    /// The host's side of the handshake: verify the client's key, answer `attached`.
    func acceptAttach(role: String = "writer", cols: Int = 80, rows: Int = 24) throws {
        let attach = try #require(link.messages(ofType: "attach").last)
        let accepted = try host.completeAttach(attach, sessionID: sessionID, peerID: deviceID)
        #expect(accepted)
        client.handle(try host.attachedMessage(to: deviceID, sessionID: sessionID, role: role, cols: cols, rows: rows))
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
