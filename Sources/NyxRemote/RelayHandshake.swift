import Foundation
import NyxCore

/// The three-message opening of a relay connection (spec §6.1) as a value type, so the part of
/// `RelayConnection` that can be wrong -- which reply belongs to which incoming message, and which
/// failures are worth retrying -- is testable without a socket. `RelayConnection` owns only the
/// URLSession plumbing around it.
///
/// The sequence is `hello` (sent by the caller as soon as the socket opens) → `challenge {nonce}`
/// → `auth {signature}` → `welcome`. Anything else before `welcome` ends the handshake: the relay
/// sends `error bad_token` or `error bad_signature` and then closes with 4401/4403, and it sends
/// nothing else at all until the socket is authenticated.
public struct RelayHandshake {
    /// What the caller must do with the message it just received.
    public enum Outcome: Equatable {
        /// Send this text frame and keep waiting.
        case send(RemoteMessage)
        /// `welcome` arrived: the connection is authenticated.
        case online
        /// The relay refused this device for a reason no reconnect can fix -- the token is wrong,
        /// or this device's key is not one the relay will accept -- so the caller must stop rather
        /// than retry, and tell the user the code.
        case rejected(code: String)
        /// The relay answered with some other error before `welcome`. Unlike a rejection this is
        /// worth retrying: a relay that is out of capacity, restarting, or newer than this client
        /// (a code it has never heard of) is a temporary condition, and treating every unknown code
        /// as permanent would strand a device until someone thought to press Reconnect.
        case retryableError(code: String)
        /// The relay said something that is not part of the handshake, or said it malformed. The
        /// socket is not usable; the caller drops it and may retry with backoff, because unlike a
        /// rejection this can be a relay that is restarting or a proxy injecting frames.
        case protocolError(String)
    }

    /// Which of the two relay messages the handshake is still waiting for. `.nothing` means it is
    /// over -- either authenticated or finished by a rejection or a protocol error.
    public enum Expecting: Equatable { case challenge, welcome, nothing }

    /// The only two error codes the relay sends before `welcome` that mean "and do not come back":
    /// the token is not the relay's, or this device's signature did not verify. Everything else --
    /// including a code from a relay newer than this client -- is temporary by default, because
    /// the cost of retrying something permanent is a backoff loop, while the cost of giving up on
    /// something temporary is a Mac that never comes back until somebody notices.
    public static let terminalErrorCodes: Set<String> = ["bad_token", "bad_signature"]

    public private(set) var expecting: Expecting = .challenge

    private let deviceID: String
    private let sign: ([UInt8]) -> [UInt8]?

    /// `sign` is injected rather than taking a `DeviceIdentity` so the decision logic can be tested
    /// with a recording stub -- the point of the tests is which bytes get signed, not CryptoKit.
    public init(deviceID: String, sign: @escaping ([UInt8]) -> [UInt8]?) {
        self.deviceID = deviceID
        self.sign = sign
    }

    /// The opening message. Sent before any `receive`, as soon as the socket is open: the relay
    /// gives a device 10 seconds to produce it and closes with 4400 otherwise.
    public static func hello(deviceID: String, deviceName: String, token: String) -> RemoteMessage {
        .hello(deviceID: deviceID, deviceName: deviceName, token: token)
    }

    public mutating func receive(_ message: RemoteMessage) -> Outcome {
        // An `error` is the relay's answer at either step, so it is checked before the step: a
        // wrong token is answered instead of the challenge, a wrong signature instead of welcome.
        // The code is what the user is shown, so an error with no code still carries a word rather
        // than an empty string.
        if message.t == "error" {
            expecting = .nothing
            let code = message.code ?? ""
            let named = code.isEmpty ? "error" : code
            return Self.terminalErrorCodes.contains(named) ? .rejected(code: named)
                                                           : .retryableError(code: named)
        }
        switch expecting {
        case .challenge:
            guard message.t == "challenge" else {
                expecting = .nothing
                return .protocolError("expected challenge, got \(message.t)")
            }
            // Exactly 32 bytes, matching the relay's own `rand.Read(nonce)`. A shorter nonce is
            // either a relay this client does not understand or an attempt to get a signature over
            // guessable bytes, and signing it anyway would spend this device's key on both.
            guard let wire = message.nonce, let nonce = RemoteID.bytes(base64url: wire), nonce.count == 32 else {
                expecting = .nothing
                return .protocolError("challenge nonce is not 32 bytes")
            }
            guard let toSign = DeviceIdentity.challengeMessage(nonce: nonce, deviceID: deviceID),
                  let signature = sign(toSign) else {
                expecting = .nothing
                return .protocolError("the challenge could not be signed")
            }
            expecting = .welcome
            return .send(.auth(signature: RemoteID.base64url(signature)))
        case .welcome:
            guard message.t == "welcome" else {
                expecting = .nothing
                return .protocolError("expected welcome, got \(message.t)")
            }
            expecting = .nothing
            return .online
        case .nothing:
            return .protocolError("the handshake is already finished")
        }
    }
}

/// When a handshake that has not finished has waited too long. Split out from `RelayConnection` so
/// the rule can be tested against an injected clock instead of against a real timer: the timer only
/// decides when to *look*, this decides what the answer is.
///
/// It exists because the relay is not obliged to answer. A socket that completes at the TCP level
/// and then goes silent -- a stalled proxy, a captive portal that swallows the upgrade, a relay
/// killed between `accept` and its first write -- produces no error of any kind, so without a
/// deadline the connection sits in `.connecting` forever and the user is told nothing.
struct HandshakeDeadline: Equatable {
    /// Seconds on the same monotonic-enough scale the caller passes to `hasExpired`.
    let startedAt: TimeInterval
    let timeout: TimeInterval

    func hasExpired(at now: TimeInterval, authenticated: Bool) -> Bool {
        guard !authenticated else { return false }
        return now - startedAt >= timeout
    }

    /// How much longer to wait before looking again. Never negative, so a caller can arm a timer
    /// with it without checking.
    func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, startedAt + timeout - now)
    }
}
