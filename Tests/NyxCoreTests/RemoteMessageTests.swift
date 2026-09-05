import Foundation
import Testing
@testable import NyxCore

private let deviceIDFixture = String(repeating: "A", count: 43)
private let sessionIDFixture = String(repeating: "A", count: 22)

// MARK: - Decoding fixtures from the relay

@Test func decodesWelcome() throws {
    let data = Data(#"{"v":1,"t":"welcome","server_time":"2026-09-05T12:00:00Z"}"#.utf8)
    let msg = try RemoteMessage.decode(data)
    #expect(msg.t == "welcome")
    #expect(msg.serverTime == "2026-09-05T12:00:00Z")
}

@Test func decodesCatalogue() throws {
    let json = """
    {"v":1,"t":"catalogue","device_id":"\(deviceIDFixture)","sessions":[{"session_id":"\(sessionIDFixture)","title":"zsh","cwd":"/tmp","repo":"","branch":"","process":"","last_command":"","last_activity":"","cols":80,"rows":24}]}
    """
    let msg = try RemoteMessage.decode(Data(json.utf8))
    #expect(msg.t == "catalogue")
    #expect(msg.deviceID == deviceIDFixture)
    let session = try #require(msg.sessions?.first)
    #expect(session == RemoteSessionInfo(sessionID: sessionIDFixture, title: "zsh", cwd: "/tmp",
                                         repo: "", branch: "", process: "", lastCommand: "",
                                         lastActivity: "", cols: 80, rows: 24))
}

@Test func decodesError() throws {
    let data = Data(#"{"v":1,"t":"error","code":"bad_token","message":"x"}"#.utf8)
    let msg = try RemoteMessage.decode(data)
    #expect(msg.t == "error")
    #expect(msg.code == "bad_token")
    #expect(msg.message == "x")
}

// MARK: - Rejection

@Test func decodeRejectsWrongVersion() {
    #expect(throws: (any Error).self) {
        try RemoteMessage.decode(Data(#"{"v":2,"t":"x"}"#.utf8))
    }
}

@Test func decodeRejectsMissingType() {
    #expect(throws: (any Error).self) {
        try RemoteMessage.decode(Data(#"{"v":1}"#.utf8))
    }
}

// MARK: - Encoding

/// The relay decodes with a real JSON parser, so extra keys would be harmless -- but a client that
/// sends fields the receiver has to guess the meaning of is how wire drift starts. This pins the
/// exact key set `hello` puts on the wire.
@Test func encodedHelloHasExactlyItsKeys() throws {
    let data = RemoteMessage.hello(deviceID: "d", deviceName: "MacBook", token: "t").encoded()
    let any = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(any.keys) == ["v", "t", "device_id", "device_name", "token"])
}

// MARK: - RemoteID

@Test func remoteIDAcceptsCorrectLengths() {
    #expect(RemoteID.isDeviceID(deviceIDFixture))
    #expect(RemoteID.isSessionID(sessionIDFixture))
}

@Test func remoteIDRejectsShortStrings() {
    #expect(!RemoteID.isDeviceID("AAAA"))
    #expect(!RemoteID.isSessionID("AAAA"))
    #expect(!RemoteID.isDeviceID(""))
}

@Test func base64urlHasNoPaddingAndTheURLSafeAlphabet() {
    let bytes: [UInt8] = Array(repeating: 0xff, count: 32)
    let s = RemoteID.base64url(bytes)
    #expect(!s.contains("="))
    #expect(!s.contains("+"))
    #expect(!s.contains("/"))
    #expect(RemoteID.bytes(base64url: s) == bytes)
}

// MARK: - BinaryFrame

@Test func binaryFrameRoundTrips() throws {
    let sessionID: [UInt8] = Array(1...16)
    let frame = BinaryFrame(sessionID: sessionID, counter: 0x0102_0304_0506_0708, ciphertext: [9, 9, 9])
    let parsed = try #require(BinaryFrame(frame.bytes))
    #expect(parsed == frame)
    #expect(parsed.sessionID == sessionID)
    #expect(parsed.counter == 0x0102_0304_0506_0708)
    #expect(parsed.ciphertext == [9, 9, 9])
}

@Test func binaryFrameRejectsTooShort() {
    #expect(BinaryFrame(Array(repeating: 0, count: 23)) == nil)
}
