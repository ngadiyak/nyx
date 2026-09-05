import Foundation

/// The six-character rendezvous code one Mac shows so another can find it at the relay. The
/// alphabet drops `0`/`O` and `1`/`I` -- the two pairs a person reading a code aloud, or typing it
/// on a phone keyboard, confuses most often.
public enum PairCode {
    public static let alphabet: [Character] = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// `random(n)` must return a value in `0..<n`; production passes a real RNG, tests a fixed
    /// sequence, so the code itself never depends on `Int.random` and is reproducible.
    public static func make(random: (Int) -> Int) -> String {
        String((0..<6).map { _ in alphabet[random(alphabet.count)] })
    }

    /// What a person typed, forgiving spaces, dashes and case -- `display` puts the dash back in
    /// for reading, but nothing requires it to be typed back exactly the way it was shown.
    public static func normalise(_ typed: String) -> String? {
        let cleaned = typed.uppercased().filter { $0 != " " && $0 != "-" }
        guard cleaned.count == 6, cleaned.allSatisfy(alphabet.contains) else { return nil }
        return cleaned
    }

    /// `"K7M4QZ"` -> `"K7M-4QZ"`: the shape the pairing sheet shows on screen.
    public static func display(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<mid])-\(code[mid...])"
    }
}

/// A short, spoken-out-loud proof that both sides of a pairing derived the same secret -- what
/// defeats a relay that quietly swapped in its own key during the handshake, since the relay never
/// sees the shared secret itself, only routes messages about it. Only digest bytes are handled
/// here: hashing needs CryptoKit, which `NyxCore` may not import, so `NyxRemote` hashes and hands
/// the bytes over.
public enum Fingerprint {
    /// 256 short, distinct, common English nouns -- enough that four of them chosen by digest
    /// bytes give a fingerprint two people can read to each other and be confident of a mismatch,
    /// with no entry easily misheard for another.
    public static let words: [String] = [
        "apple", "river", "stone", "zero", "table", "chair", "window", "door",
        "garden", "forest", "mountain", "valley", "ocean", "island", "desert", "canyon",
        "meadow", "harbor", "bridge", "tunnel", "castle", "tower", "village", "market",
        "street", "corner", "alley", "plaza", "fountain", "statue", "museum", "library",
        "theater", "stadium", "airport", "station", "platform", "ladder", "anchor", "compass",
        "lantern", "candle", "mirror", "pillow", "blanket", "carpet", "curtain", "kettle",
        "basket", "bottle", "bucket", "hammer", "wrench", "chisel", "needle", "thread",
        "button", "zipper", "ribbon", "fabric", "leather", "velvet", "cotton", "wool",
        "silk", "pepper", "salt", "sugar", "honey", "butter", "cheese", "bread",
        "grain", "wheat", "barley", "corn", "rice", "potato", "carrot", "onion",
        "garlic", "ginger", "lemon", "orange", "grape", "melon", "peach", "plum",
        "cherry", "banana", "coconut", "walnut", "almond", "hazel", "maple", "willow",
        "birch", "cedar", "pine", "spruce", "fern", "moss", "ivy", "clover",
        "thistle", "daisy", "tulip", "rose", "lily", "violet", "lotus", "orchid",
        "cactus", "bamboo", "palm", "olive", "fig", "date", "apricot", "raisin",
        "pumpkin", "squash", "cabbage", "lettuce", "spinach", "parsley", "basil", "mint",
        "sage", "thyme", "cinnamon", "vanilla", "cocoa", "coffee", "copper", "bronze",
        "silver", "gold", "iron", "steel", "nickel", "zinc", "marble", "granite",
        "quartz", "crystal", "diamond", "pearl", "amber", "coral", "shell", "pebble",
        "boulder", "cliff", "ridge", "slope", "summit", "glacier", "tundra", "prairie",
        "savanna", "jungle", "swamp", "marsh", "lagoon", "reef", "current", "tide",
        "wave", "breeze", "storm", "thunder", "lightning", "cloud", "rainbow", "horizon",
        "sunrise", "sunset", "comet", "meteor", "planet", "nebula", "galaxy", "orbit",
        "rocket", "satellite", "telescope", "map", "globe", "sail", "rudder", "mast",
        "oar", "canoe", "kayak", "yacht", "ferry", "tractor", "wagon", "carriage",
        "bicycle", "scooter", "engine", "wheel", "gear", "piston", "lever", "pulley",
        "spring", "hinge", "bolt", "screw", "nail", "plank", "beam", "brick",
        "cement", "plaster", "tile", "shingle", "chimney", "fireplace", "hearth", "mantle",
        "attic", "cellar", "hallway", "staircase", "balcony", "terrace", "patio", "fence",
        "gate", "hedge", "lawn", "orchard", "vineyard", "barn", "silo", "windmill",
        "lighthouse", "pier", "dock", "wharf", "quarry", "mine", "cavern", "grotto",
        "oasis", "dune", "plateau", "fjord", "delta", "estuary", "channel", "strait",
    ]

    /// The first four digest bytes, each indexing `words` -- one byte per word keeps the mapping a
    /// direct lookup, and four words is what a person can read aloud and compare in one breath.
    public static func words(digest: [UInt8]) -> [String] {
        digest.prefix(4).map { words[Int($0)] }
    }

    public static func text(digest: [UInt8]) -> String {
        words(digest: digest).joined(separator: "-")
    }

    /// The bytes `NyxRemote` hashes to get the fingerprint digest: both devices' public keys,
    /// concatenated smaller-first so it does not matter which side computes it -- host and client
    /// must land on the same digest from either direction, and byte order is the only order two
    /// unrelated public keys naturally agree on.
    public static func input(a: [UInt8], b: [UInt8]) -> [UInt8] {
        a.lexicographicallyPrecedes(b) ? a + b : b + a
    }
}

/// The pairing state machine, run identically on both sides of a pairing with only `side` and the
/// events fed to it differing. Kept as one type rather than two so the rules that must agree
/// between host and client -- what "confirmed by both" means, what expiry does -- cannot drift
/// apart by being edited in only one place.
public struct PairingFlow: Equatable {
    public enum Side: Equatable { case host, client }

    public enum State: Equatable {
        case idle
        /// Host: `pair_open` sent, waiting for the relay's `pair_opened` before the code is shown --
        /// a client cannot join before the relay actually knows the code, so showing it any earlier
        /// would let someone type a code the relay would reject.
        case opening(String, expires: Date)
        case showingCode(String, expires: Date)                       // host
        case joining(code: String)                                     // client, waiting for pair_accept
        case requested(peerID: String, peerName: String)               // host, waiting for the user to accept
        case confirming(peerID: String, peerName: String, fingerprint: String, mine: Bool, theirs: Bool)
        case paired(peerID: String, peerName: String)
        case failed(String)                                            // "Code expired", "No such code", "That code is in use"
    }

    public enum Event: Equatable {
        case open(code: String, now: Date)                       // host pressed Pair…
        case opened(code: String)                                // relay's pair_opened: the code is live
        case join(code: String)                                  // client typed a code
        case request(peerID: String, peerName: String)           // host got pair_request
        case accept                                              // host pressed Accept
        case accepted(peerID: String, peerName: String)          // client got pair_accept
        case fingerprint(String)                                 // both: NyxRemote computed it
        case confirmMine                                         // user pressed Confirm
        case confirmTheirs                                       // got pair_confirm
        case error(code: String)                                 // pair_expired / pair_taken
        case tick(now: Date)                                     // expiry
        case cancel
    }

    public enum Effect: Equatable {
        case send(RemoteMessage)
        case computeFingerprint(peerID: String)
        case store(peerID: String, peerName: String)
    }

    /// How long a code stays valid at the relay -- matches the design spec's "valid for five
    /// minutes", and is the same value `tick` checks against on both the opening and shown code.
    private static let codeLifetime: TimeInterval = 300

    public let side: Side
    public private(set) var state: State

    public init(side: Side) {
        self.side = side
        self.state = .idle
    }

    public mutating func handle(_ e: Event, selfID: String) -> [Effect] {
        if case .cancel = e {
            state = .idle
            return []
        }

        switch (state, e) {
        case (.idle, .open(let code, let now)):
            state = .opening(code, expires: now.addingTimeInterval(Self.codeLifetime))
            return [.send(.pairOpen(code: code))]

        case (.idle, .join(let code)):
            state = .joining(code: code)
            return [.send(.pairJoin(code: code))]

        case (.opening(let code, let expires), .opened(let acked)) where acked == code:
            state = .showingCode(code, expires: expires)
            return []

        case (.opening(_, let expires), .tick(let now)):
            if now >= expires { state = .failed("Code expired") }
            return []

        case (.showingCode(_, let expires), .tick(let now)):
            if now >= expires { state = .failed("Code expired") }
            return []

        case (.opening, .error(let code)):
            state = .failed(Self.failureText(for: code))
            return []

        case (.showingCode, .request(let peerID, let peerName)) where peerID != selfID:
            state = .requested(peerID: peerID, peerName: peerName)
            return []

        case (.showingCode, .error(let code)):
            state = .failed(Self.failureText(for: code))
            return []

        case (.requested(let peerID, let peerName), .accept):
            state = .confirming(peerID: peerID, peerName: peerName, fingerprint: "", mine: false, theirs: false)
            return [.send(.pairAccept(to: peerID)), .computeFingerprint(peerID: peerID)]

        case (.joining, .accepted(let peerID, let peerName)) where peerID != selfID:
            state = .confirming(peerID: peerID, peerName: peerName, fingerprint: "", mine: false, theirs: false)
            return [.computeFingerprint(peerID: peerID)]

        case (.joining, .error(let code)):
            state = .failed(Self.failureText(for: code))
            return []

        case (.confirming(let peerID, let peerName, _, let mine, let theirs), .fingerprint(let fp)):
            state = .confirming(peerID: peerID, peerName: peerName, fingerprint: fp, mine: mine, theirs: theirs)
            return []

        case (.confirming(let peerID, let peerName, let fp, _, let theirs), .confirmMine):
            if theirs {
                state = .paired(peerID: peerID, peerName: peerName)
                return [.send(.pairConfirm(to: peerID)), .store(peerID: peerID, peerName: peerName)]
            }
            state = .confirming(peerID: peerID, peerName: peerName, fingerprint: fp, mine: true, theirs: false)
            return [.send(.pairConfirm(to: peerID))]

        case (.confirming(let peerID, let peerName, let fp, let mine, _), .confirmTheirs):
            if mine {
                state = .paired(peerID: peerID, peerName: peerName)
                return [.store(peerID: peerID, peerName: peerName)]
            }
            state = .confirming(peerID: peerID, peerName: peerName, fingerprint: fp, mine: false, theirs: true)
            return []

        case (.confirming, .error(let code)):
            state = .failed(Self.failureText(for: code))
            return []

        default:
            return [] // not valid from this state -- e.g. an event that arrived twice, or out of order
        }
    }

    /// What the relay's `error.code` means to the person waiting on this pairing. `pair_expired`
    /// covers both a code that timed out and one the relay never heard of (it cannot tell those
    /// apart once the code is gone), so both read as the same message.
    private static func failureText(for errorCode: String) -> String {
        switch errorCode {
        case "pair_expired": return "Code expired"
        case "pair_taken": return "That code is in use"
        default: return "No such code"
        }
    }

    /// What the pairing sheet shows for the current state: title, body, and the primary button's
    /// label (nil hides the button -- there is nothing to do yet but wait).
    public var sheetText: (title: String, body: String, primary: String?) { Self.sheetText(for: state) }

    /// The state-only half of `sheetText`, so `PairingSheet.update(state:)` can render a state it
    /// was just handed -- e.g. by `UISnapshot`, which pictures every state directly and never runs
    /// a real flow -- without needing a live `PairingFlow` instance to read it off of.
    public static func sheetText(for state: State) -> (title: String, body: String, primary: String?) {
        switch state {
        case .idle:
            return ("", "", nil)
        case .opening:
            return ("Pairing…", "Requesting a code from the relay", nil)
        case .showingCode(let code, _):
            return ("Pair with another device",
                    "On the other Mac, open Settings → Remote → Pair… and enter\n \(PairCode.display(code))", nil)
        case .joining:
            return ("Pairing…", "Waiting for the other Mac", nil)
        case .requested(_, let peerName):
            return ("\(peerName) wants to pair", "Accept to continue", "Accept")
        case .confirming(_, _, _, let mine, _):
            // Just the lead-in: the fingerprint itself is shown once, by the sheet's own bold
            // label -- repeating it here as well as in the body read as the same word twice.
            return ("Confirm the fingerprint", "Both Macs must show:", mine ? nil : "Confirm")
        case .paired(_, let peerName):
            return ("Paired with \(peerName)", "", "Done")
        case .failed(let message):
            return ("Pairing failed", message, "Close")
        }
    }
}
