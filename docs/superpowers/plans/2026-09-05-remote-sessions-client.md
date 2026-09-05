# Remote Sessions — Nyx Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nyx publishes its local sessions to the relay, lists other paired Macs' sessions in the command palette, pairs devices by a six-character code with fingerprint confirmation, and attaches to a remote session as a tab — end-to-end encrypted, snapshot then live stream, one writer at a time, with an audit log on the host.

**Architecture:** Decisions live in `NyxCore/Remote/` as value types with tests (messages, catalogue rows, pairing and attach state machines, writer arbitration, session summaries, fingerprint words, audit lines, backoff). A new target `NyxRemote` (Foundation + CryptoKit + NyxCore, never AppKit) owns I/O: the WebSocket relay connection, the device identity and paired-devices files, the E2E cipher, and the host/client orchestrators. `NyxApp` converts and draws: a `PaneSession` protocol lets a remote attachment stand in for a `TerminalSession` inside `Pane`; the palette gets a Remote section; settings get a Remote page and a pairing sheet.

**Tech Stack:** Swift 6.0.3 in Swift 5 mode, SwiftPM, swift-testing, CryptoKit (Curve25519 signing and key agreement, HKDF, ChaChaPoly), `URLSessionWebSocketTask`. The relay from `docs/superpowers/plans/2026-09-05-remote-sessions-server.md` (deployed at `wss://nyx.agentforge.cc/v1/ws`; the local binary `~/projects/nyx-server/bin/nyx-relay` for integration tests).

**Spec:** `/Users/nik/projects/nyx/docs/superpowers/specs/2026-09-05-remote-sessions-design.md`. **Wire contract:** the table in the server plan (field names, base64url, error codes) is authoritative; every JSON fixture in this plan matches it.

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY (no CryptoKit: hashing happens in `NyxRemote`, Core maps digest bytes to words). `NyxRemote` imports Foundation, CryptoKit, NyxCore — never AppKit. `NyxRender` unchanged.
- swift-testing only; hoist mutating calls out of `#expect`; runner hang → `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`; never wait on a background run; `rm -rf .build` if an unrelated Metal test crashes after a stored-property change.
- Warning-free in library and test targets: `swift build 2>&1 | grep -c warning:` → 0 and `swift build --build-tests 2>&1 | grep -c warning:` → 0. `make bench` ≥ 180.
- `Terminal` is touched only inside `withTerminal { }`; the reference never escapes. The reader thread of `TerminalSession` must not block on network I/O: the output tap hands bytes to a queue.
- Wire strings are base64url without padding; device id = base64url(32-byte Ed25519 public key); session id = base64url(16 random bytes); every message has `v: 1`.
- Files under `~/.config/nyx/remote/` (beside the config, so `NYX_CONFIG` moves them): `identity` (0600), `paired.json`, `audit.log`. Nothing else is written.
- Every drawn control is an accessibility element; every new piece of chrome gets a `UISnapshot` case per state; config keys follow `.claude/skills/nyx-config-keys/SKILL.md`; actions follow "Adding an action" there.
- Nothing is done until the ladder in `docs/testing.md` has run and the two-instance rung-6 check passed; the product-manager agent judges at the end.
- Branch `feat/remote-sessions` off `main`. `git add` by name; never `CLAUDE.md`, `.claude/`, `docs/testing.md`, `docs/workflow.md`, `docs/checklist.md`. Commit trailer on every commit: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01YHJ5Uc1qA7f7FHixuhp8Gy`.

---

## File map

| File | Responsibility | Task |
|---|---|---|
| `Sources/NyxCore/Remote/RemoteMessage.swift` | Codable envelope, `RemoteSession` metadata, ids, validation of what the client receives | 1 |
| `Sources/NyxCore/Remote/RemoteCatalogue.swift` | devices + catalogues → palette rows, presence text, relative time | 2 |
| `Sources/NyxCore/Remote/PairingFlow.swift` | code alphabet/generation, `Fingerprint.words`, host and client state machines | 3 |
| `Sources/NyxCore/Remote/AttachState.swift`, `WriterArbiter.swift`, `SessionSummary.swift`, `AuditLine.swift`, `Backoff.swift` | attach lifecycle and strip text; who writes; what a host publishes; audit formatting; reconnect delays | 4 |
| `Package.swift` | `NyxRemote` target + `NyxRemoteTests` | 5 |
| `Sources/NyxRemote/DeviceIdentity.swift`, `PairedDevices.swift`, `E2ESession.swift`, `RemoteFiles.swift` | keys on disk, trusted peers, the cipher, paths | 5 |
| `Sources/NyxRemote/RelayConnection.swift` | WebSocket, handshake, reconnect, envelope/binary delivery | 6 |
| `Sources/NyxRemote/RemoteHost.swift`, `RemoteClient.swift` | publish + answer attaches + tap output; attach + decrypt + input | 7 |
| `Sources/NyxCore/Session/TerminalSession.swift` | `onOutput` tap; `PaneSession` protocol | 7 |
| `Sources/NyxCore/Config/*`, `Sources/NyxApp/SettingsWindowController.swift`, `PairingSheet.swift` | keys, actions, Remote page, pairing sheet | 8 |
| `Sources/NyxApp/RemoteCoordinator.swift`, `RemoteSession.swift`, `RemoteStripView.swift`, `Pane.swift`, `TabController.swift`, `AppDelegate.swift`, `UISnapshot.swift` | app wiring: one coordinator per app, remote pane, strip, palette section, tabs | 9 |
| docs, README, smoke hook | verification and documentation | 10 |

---

### Task 0: Branch and relay availability

- [ ] **Step 1:** `git checkout -b feat/remote-sessions main`; `swift test --no-parallel 2>&1 | tail -2` (record the count); confirm the relay: `curl -fsS https://nyx.agentforge.cc/healthz` prints stats, and `~/projects/nyx-server/bin/nyx-relay -h` runs (build it with `make -C ~/projects/nyx-server build` if missing). Record the relay token location: `~/projects/nyx-server/token`.

---

### Task 1: Messages

**Files:** Create `Sources/NyxCore/Remote/RemoteMessage.swift`, `Tests/NyxCoreTests/RemoteMessageTests.swift`.

**Interfaces (produces):**

```swift
public struct RemoteSessionInfo: Codable, Equatable {   // wire name "Session"
    public var sessionID: String; public var title, cwd, repo, branch, process, lastCommand, lastActivity: String
    public var cols, rows: Int
}
public struct RemotePresence: Codable, Equatable { public var deviceID: String; public var name: String; public var online: Bool }
public struct RemoteMessage: Codable, Equatable {
    public var v: Int = 1; public var t: String
    public var from, to, deviceID, deviceName, token, nonce, signature, code, name: String?
    public var deviceIDs: [String]?; public var devices: [RemotePresence]?; public var sessions: [RemoteSessionInfo]?
    public var sessionID, ephemeralPubkey, sig, role, serverTime, message: String?
    public var cols, rows: Int?
    // CodingKeys map to snake_case exactly as the server plan's table.
    public static func decode(_ data: Data) throws -> RemoteMessage   // rejects v != 1 or empty t
    public func encoded() -> Data
    public static func hello(deviceID:deviceName:token:) / auth(signature:) / paired(_:) / sessions(_:) / pairOpen(code:) / pairJoin(code:) / pairAccept(to:) / pairConfirm(to:) / attach(to:sessionID:ephemeralPubkey:sig:) / attached(to:sessionID:ephemeralPubkey:sig:role:cols:rows:) / snapshotEnd(to:sessionID:) / takeControl(to:sessionID:) / role(to:sessionID:deviceID:role:) / detach(to:sessionID:) / sessionEnded(to:sessionID:)
}
public enum RemoteID {
    public static func isDeviceID(_ s: String) -> Bool   // base64url, 32 bytes
    public static func isSessionID(_ s: String) -> Bool  // 16 bytes
    public static func base64url(_ bytes: [UInt8]) -> String
    public static func bytes(base64url s: String) -> [UInt8]?
}
public struct BinaryFrame: Equatable {   // session_id(16) ‖ counter(8 BE) ‖ ciphertext
    public let sessionID: [UInt8]; public let counter: UInt64; public let ciphertext: [UInt8]
    public init?(_ data: [UInt8]); public var bytes: [UInt8]
}
```

- [ ] **Step 1: Tests** (`RemoteMessageTests.swift`): decode the exact fixtures `{"v":1,"t":"welcome","server_time":"2026-09-05T12:00:00Z"}`, `{"v":1,"t":"catalogue","device_id":"<43 A's>","sessions":[{"session_id":"<22 A's>","title":"zsh","cwd":"/tmp","repo":"","branch":"","process":"","last_command":"","last_activity":"","cols":80,"rows":24}]}`, `{"v":1,"t":"error","code":"bad_token","message":"x"}`; encode `hello` and assert the JSON keys are exactly `v,t,device_id,device_name,token` (decode into `[String: Any]` and compare the key set); `decode` rejects `{"v":2,"t":"x"}` and `{"v":1}`; `RemoteID` accepts 43/22-char ids and rejects short ones; `BinaryFrame` round-trips and rejects 23 bytes; `base64url` produces no `=` and uses `-_`.

- [ ] **Step 2:** Run `swift test --no-parallel --filter RemoteMessage` → compile errors.

- [ ] **Step 3: Implement** with explicit `CodingKeys` (`deviceID = "device_id"`, `deviceName = "device_name"`, `deviceIDs = "device_ids"`, `sessionID = "session_id"`, `ephemeralPubkey = "ephemeral_pubkey"`, `serverTime = "server_time"`, `lastCommand = "last_command"`, `lastActivity = "last_activity"`, the rest identical). Use `JSONEncoder` with `.withoutEscapingSlashes` and `.sortedKeys`. `base64url` via `Data.base64EncodedString()` then `+→-`, `/→_`, strip `=`; the inverse pads back to a multiple of 4.

- [ ] **Step 4:** Tests green; `swift build 2>&1 | grep -c warning:` → 0.

- [ ] **Step 5:** `git add Sources/NyxCore/Remote/RemoteMessage.swift Tests/NyxCoreTests/RemoteMessageTests.swift; git commit -m "Remote: the messages the relay and the other Macs exchange"`.

---

### Task 2: Catalogue and palette rows

**Files:** Create `Sources/NyxCore/Remote/RemoteCatalogue.swift`, `Tests/NyxCoreTests/RemoteCatalogueTests.swift`; modify `Sources/NyxCore/Palette/CommandPalette.swift` (`PaletteItemKind.remoteSession(deviceID: String, sessionID: String)`, `PaletteItem.remoteSession(...)`, `PaletteSource.items(..., remote: [PaletteItem])` appended after tabs), `Tests/NyxCoreTests/CommandPaletteTests.swift` (order test extended).

**Interfaces (produces):**

```swift
public struct RemoteCatalogue: Equatable {
    public struct Device: Equatable { public let id: String; public var name: String; public var online: Bool; public var sessions: [RemoteSessionInfo] }
    public init()
    public mutating func applyPresence(_ devices: [RemotePresence])
    public mutating func applyCatalogue(deviceID: String, sessions: [RemoteSessionInfo])
    public mutating func setPaired(_ names: [String: String])   // id → name from PairedDevices; offline devices keep their names
    public var devices: [Device]                                  // sorted: online first, then by name
    public func paletteItems(now: Date) -> [PaletteItem]          // one per session of an online device; an offline device yields one disabled-looking row "machine — offline"
    public static func detail(for s: RemoteSessionInfo, now: Date) -> String  // "~/projects/nyx  main · running: swift test · last: make test · 2 min ago"
    public static func relative(_ iso8601: String, now: Date) -> String       // "just now", "2 min ago", "3 h ago", "yesterday", "" when unparsable
    public var relayStatusText: String?   // set by the app: "Relay unreachable (…)", "Relay rejected this device's token"; shown as a first row when non-nil
}
```

- [ ] **Step 1: Tests:** presence then catalogue produce one item per session with title `"<machine> · <title>"` and the detail string above (use a fixed `now`); an offline device yields exactly one row whose detail is `"offline"` and whose kind is `.remoteSession(deviceID:, sessionID: "")`; `relative` boundaries (59 s → "just now", 60 s → "1 min ago", 3600 s → "1 h ago", 86400 s → "yesterday", garbage → ""); `cwd` shortened with `~` for the home prefix passed in (`RemoteCatalogue.detail(for:now:home:)` — add `home: String` parameter, default "" ); sorting online first; `PaletteSource.items` places remote rows last.

- [ ] **Step 2–4:** fail → implement → green, warning-free.

- [ ] **Step 5:** commit "Remote: the palette knows the other Macs' sessions".

---

### Task 3: Pairing flow and fingerprint

**Files:** Create `Sources/NyxCore/Remote/PairingFlow.swift`, `Tests/NyxCoreTests/PairingFlowTests.swift`.

**Interfaces (produces):**

```swift
public enum PairCode {
    public static let alphabet: [Character] = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    public static func make(random: (Int) -> Int) -> String          // 6 chars from `alphabet`
    public static func normalise(_ typed: String) -> String?         // uppercases, strips spaces and dashes, nil unless 6 valid chars
    public static func display(_ code: String) -> String              // "K7M-4QZ"
}
public enum Fingerprint {
    public static let words: [String]   // 256 short English words, fixed order
    public static func words(digest: [UInt8]) -> [String]   // first four bytes → four words
    public static func text(digest: [UInt8]) -> String      // "apple-river-stone-zero"
    public static func input(a: [UInt8], b: [UInt8]) -> [UInt8]  // min(a,b) ‖ max(a,b) lexicographically — what NyxRemote hashes
}
public struct PairingFlow: Equatable {
    public enum Side: Equatable { case host, client }
    public enum State: Equatable {
        case idle
        case opening(code: String, expires: Date)                     // host, waiting for pair_opened
        case showingCode(String, expires: Date)                       // host
        case joining(code: String)                                     // client, waiting for pair_accept
        case requested(peerID: String, peerName: String)               // host, waiting for the user to accept
        case confirming(peerID: String, peerName: String, fingerprint: String, mine: Bool, theirs: Bool)
        case paired(peerID: String, peerName: String)
        case failed(String)                                            // "Code expired", "No such code", "That code is in use"
    }
    public enum Event: Equatable {
        case open(code: String, now: Date)                       // host pressed Pair…
        case opened(code: String)                                // relay acknowledged (pair_opened); only now is the code shown
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
    public enum Effect: Equatable { case send(RemoteMessage); case computeFingerprint(peerID: String); case store(peerID: String, peerName: String) }
    public let side: Side; public private(set) var state: State
    public init(side: Side)
    public mutating func handle(_ e: Event, selfID: String) -> [Effect]
    public var sheetText: (title: String, body: String, primary: String?)   // what the sheet shows per state
}
```

Rules: host `open` → `.opening` + `.send(pairOpen)`; host `opened` → `.showingCode` (a `pair_taken` error while opening → `.failed("That code is in use")`, and the sheet offers Pair… again with a fresh code); host `request` → `.requested`; host `accept` → `.send(pairAccept(to: peer))` + `.computeFingerprint(peerID)`; client `join` → `.joining` + `.send(pairJoin)`; client `accepted` → `.computeFingerprint`; both: `fingerprint` → `.confirming(mine: false, theirs: false)`; `confirmMine` → `.send(pairConfirm(to: peer))`, mine = true; `confirmTheirs` → theirs = true; when both true → `.paired` + `.store`; `error` → `.failed(text)`; `tick` past expiry in `.showingCode` → `.failed("Code expired")`; `cancel` → `.idle`. Any event not valid in a state is ignored (no effects). `sheetText` per state: showingCode → ("Pair with another device", "On the other Mac, open Settings → Remote → Pair… and enter\n K7M-4QZ", nil); requested → ("<name> wants to pair", "Accept to continue", "Accept"); confirming → ("Confirm the fingerprint", "Both Macs must show:\n<fingerprint>", mine ? nil : "Confirm"); paired → ("Paired with <name>", "", "Done"); failed(x) → ("Pairing failed", x, "Close"); joining → ("Pairing…", "Waiting for the other Mac", nil).

- [ ] **Step 1: Tests:** the happy path on both sides asserting every state and effect in order; `join` with an unnormalisable code is rejected by `PairCode.normalise` (test that separately: `"k7m-4qz "` → `"K7M4QZ"`, `"K7M4Q0"` → nil); `make` with a fixed `random` yields six alphabet chars; `Fingerprint.words(digest:)` picks `words[digest[i]]`; `input(a:b:)` is order-independent; expiry via `tick`; `error("pair_expired")` → failed text "Code expired"; events out of order are ignored; `sheetText` for each state.

- [ ] **Step 2–5:** fail → implement → green → commit "Remote: pairing by code, confirmed by a fingerprint both Macs show".

---

### Task 4: Attach state, writer arbitration, session summary, audit, backoff

**Files:** Create the five Core files and `Tests/NyxCoreTests/{AttachStateTests,WriterArbiterTests,SessionSummaryTests,AuditLineTests,BackoffTests}.swift`.

**Interfaces (produces):**

```swift
public struct AttachState: Equatable {
    public enum Phase: Equatable { case attaching, snapshot, live, reconnecting, ended(String) }
    public enum Role: Equatable { case writer, observer }
    public var phase: Phase; public var role: Role; public var hostName: String; public var title: String
    public init(hostName: String, title: String)
    public var tabTitle: String            // "⟵ machine · title"
    public var stripText: String?          // "Attaching…", "Observing — Take control" (observer, live), "Reconnecting…", "Session ended on <machine>"; nil for writer+live
    public var stripButton: String?        // "Take control" only for observer+live
    public var acceptsInput: Bool          // role == .writer && phase == .live
    public var badge: String               // "writer" / "observer"
}
public struct WriterArbiter: Equatable {
    public init()
    public mutating func attached(_ deviceID: String) -> AttachState.Role      // first attacher becomes writer
    public mutating func detached(_ deviceID: String) -> [(deviceID: String, role: AttachState.Role)]   // if the writer left, the longest-attached observer is promoted; returns changed roles
    public mutating func takeControl(_ deviceID: String) -> [(deviceID: String, role: AttachState.Role)]  // demotes the previous writer; returns both changes
    public func role(of deviceID: String) -> AttachState.Role?
    public var writer: String?
}
public struct SessionSummary: Equatable {
    public static func make(sessionID: String, title: String, cwd: String?, processName: String?, lastCommand: String?, lastActivity: Date?, cols: Int, rows: Int, repo: (name: String, branch: String)?) -> RemoteSessionInfo
    public static func repo(atPath cwd: String, readFile: (String) -> String?) -> (name: String, branch: String)?   // walks up to a `.git/HEAD`; branch from "ref: refs/heads/x", else first 8 chars of the hash; name = directory holding .git
    public static func lastCommand(in t: Terminal) -> String?   // t.lastFinishedCommand.map { t.commandLine(of: $0) }
}
public enum AuditLine {
    public static func text(_ event: Event, at date: Date) -> String   // "2026-09-05T12:00:00Z  attached  <device name> → <session title>"
    public enum Event: Equatable { case paired(String), removed(String), attached(device: String, session: String), tookControl(device: String, session: String), detached(device: String, session: String) }
}
public struct Backoff: Equatable {
    public init(initial: Double = 1, maximum: Double = 60)
    public mutating func next() -> Double     // 1, 2, 4, … capped, deterministic (no jitter in Core; the caller may add it)
    public mutating func reset()
}
```

- [ ] **Step 1: Tests** per type: arbiter (first attacher writer, second observer; writer leaves → oldest observer promoted; take-control swaps; unknown device → nil); attach strip text for every phase×role; `repo(atPath:)` with a fake `readFile` for `/a/b/.git/HEAD` = `"ref: refs/heads/main\n"` → ("b","main"), detached HEAD → 8-char hash, no repo → nil, worktree `.git` *file* (`gitdir: …`) → nil (documented limitation); `SessionSummary.make` maps every field and formats `lastActivity` as ISO 8601 UTC; audit line format; backoff sequence and cap.

- [ ] **Step 2–5:** implement → green → commit "Remote: who may type, what a host advertises, what the audit says".

---

### Task 5: The NyxRemote target: identity, paired devices, cipher

**Files:** Modify `Package.swift` (add `.target(name: "NyxRemote", dependencies: ["NyxCore"], path: "Sources/NyxRemote", swiftSettings: releaseSettings)`, `.testTarget(name: "NyxRemoteTests", dependencies: ["NyxRemote"], path: "Tests/NyxRemoteTests")`, and `"NyxRemote"` to the `Nyx` executable's dependencies). Create `Sources/NyxRemote/RemoteFiles.swift`, `DeviceIdentity.swift`, `PairedDevices.swift`, `E2ESession.swift`; `Tests/NyxRemoteTests/{DeviceIdentityTests,PairedDevicesTests,E2ESessionTests}.swift`.

**Interfaces (produces):**

```swift
public enum RemoteFiles { public static func directory(besideConfigAt config: URL) -> URL   // <config dir>/remote
                          public static func identity(in dir: URL) -> URL; pairedDevices(in:) ; auditLog(in:) }
public struct DeviceIdentity {
    public let signing: Curve25519.Signing.PrivateKey
    public var deviceID: String                                // base64url(public key raw)
    public static func load(from url: URL) throws -> DeviceIdentity        // creates (0600) when missing; throws when the file is not 0600 or unreadable
    public func sign(_ message: [UInt8]) throws -> [UInt8]
    public static func verify(_ signature: [UInt8], for message: [UInt8], by deviceID: String) -> Bool
    public static func challengeMessage(nonce: [UInt8], deviceID: String) -> [UInt8]   // "nyx-relay-v1" ‖ nonce ‖ id bytes
}
public struct PairedDevice: Codable, Equatable { public let id: String; public var name: String; public let pairedAt: Date }
public struct PairedDevices: Codable, Equatable {
    public var devices: [PairedDevice]
    public static func load(from url: URL) -> PairedDevices    // empty when missing or corrupt (corrupt → also renames the file to `paired.json.broken`)
    public func save(to url: URL) throws
    public mutating func add(_ d: PairedDevice); remove(id:); func contains(_ id:) -> Bool; var ids: [String]; var namesByID: [String: String]
}
public enum FingerprintHash { public static func digest(myID: String, peerID: String) -> [UInt8]   // SHA256(Fingerprint.input(a:b:)) }
public final class E2ESession {
    public static func ephemeral() -> Curve25519.KeyAgreement.PrivateKey
    public static func signedPublicKey(_ k: Curve25519.KeyAgreement.PrivateKey, sessionID: [UInt8], identity: DeviceIdentity) throws -> (pubkey: String, sig: String)   // sig over "nyx-e2e-v1" ‖ sessionID ‖ pubkey raw
    public static func verifyPeer(pubkey: String, sig: String, sessionID: [UInt8], deviceID: String) -> Bool
    public init(mine: Curve25519.KeyAgreement.PrivateKey, peer pubkey: String, sessionID: [UInt8], isHost: Bool) throws
        // shared = X25519; HKDF-SHA256(salt: none, info: "nyx-e2e-v1" ‖ sessionID) → 64 bytes: [0..<32] host→client key, [32..<64] client→host key
    public func seal(_ plaintext: [UInt8]) throws -> BinaryFrame    // nonce = 4 zero bytes ‖ counter BE; counter increments per call
    public func open(_ frame: BinaryFrame) throws -> [UInt8]       // rejects a counter ≤ the last accepted (replay/reorder) and a bad tag; AAD = sessionID ‖ counter
}
```

- [ ] **Step 1: Tests:** identity created on first load with mode 0600 and the same key on second load; a file with mode 0644 is refused; `sign`/`verify` round trip and a flipped bit fails; `challengeMessage` layout; paired devices save/load round trip, corrupt file → empty + `.broken` rename; `E2ESession` host and client derive the same keys from each other's ephemeral public keys, a frame sealed by the host opens on the client and not on the host (direction keys differ), tampered ciphertext throws, a replayed frame throws, counters start at 0 and increment; `signedPublicKey`/`verifyPeer` round trip with the wrong device id failing; `FingerprintHash.digest` is order-independent and 32 bytes.

- [ ] **Step 2–5:** `swift test --no-parallel --filter 'DeviceIdentity|PairedDevices|E2ESession'` red → implement → green; both warning counts 0. Commit "NyxRemote: a device's identity, the Macs it trusts, and the cipher between them".

---

### Task 6: The relay connection

**Files:** Create `Sources/NyxRemote/RelayConnection.swift`, `Tests/NyxRemoteTests/RelayConnectionTests.swift` (integration, opt-in).

**Interfaces (produces):**

```swift
public protocol RelayConnectionDelegate: AnyObject {
    func relay(_ c: RelayConnection, didChange status: RelayConnection.Status)
    func relay(_ c: RelayConnection, didReceive message: RemoteMessage)
    func relay(_ c: RelayConnection, didReceive frame: BinaryFrame)
}
public final class RelayConnection {
    public enum Status: Equatable { case offline, connecting, authenticating, online, failed(String) }   // failed("bad_token") etc.
    public init(url: URL, token: String, identity: DeviceIdentity, deviceName: String, session: URLSession = .shared)
    public weak var delegate: RelayConnectionDelegate?
    public private(set) var status: Status
    public func connect()            // idempotent; reconnects with Backoff on drop; `failed(bad_token)`/`failed(bad_signature)` do NOT retry
    public func disconnect()
    public func send(_ m: RemoteMessage)
    public func send(_ f: BinaryFrame)
    public var deviceID: String
}
```

Implementation: `URLSessionWebSocketTask`; a serial `DispatchQueue("nyx.relay")` owns all state; `receive` loop re-armed after each message; the handshake reads `challenge`, signs with `DeviceIdentity.challengeMessage`, waits for `welcome`; `error` before `welcome` → `.failed(code)`; delegate callbacks on the relay queue (the app hops to main). Text frames decode via `RemoteMessage.decode`; binary via `BinaryFrame.init`. On task error after `welcome` → `.offline` then reconnect after `Backoff.next()` seconds; after `welcome`, `Backoff.reset()`.

- [ ] **Step 1: Integration test (opt-in):** skipped unless `NYX_RELAY_BIN` is set (`Tests` use `Testing`'s `.enabled(if:)` trait). Launch the binary with `Process` on `127.0.0.1:0`? The binary takes `-listen`; use a free port chosen by binding a socket then closing it. Create two identities in a temp dir, two `RelayConnection`s with delegates capturing messages via `Expectation`-like continuations (a small `Recorder` class with a semaphore), and assert: both reach `.online`; host `pair_open`, client `pair_join` → host delegate sees `pair_request` with the client's id; wrong token → `.failed("bad_token")` and no reconnect within 2 s.

- [ ] **Step 2–5:** implement; run `NYX_RELAY_BIN=$HOME/projects/nyx-server/bin/nyx-relay swift test --no-parallel --filter RelayConnection` green; without the env var the test is skipped; commit "NyxRemote: the connection to the relay, with the handshake and reconnects".

---

### Task 7: Host and client orchestration

**Files:** Modify `Sources/NyxCore/Session/TerminalSession.swift` (`public var onOutput: (([UInt8]) -> Void)?` called in `readLoop` after `feed`, outside the lock; `public protocol PaneSession: AnyObject { func withTerminal<T>(_:) rethrows -> T; func send(_:); func resize(cols:rows:); func terminate(); var onUpdate/onEvent/onExit; var pid: pid_t?; var foregroundProcessGroup: pid_t? }` with `TerminalSession: PaneSession`). Create `Sources/NyxRemote/RemoteHost.swift`, `RemoteClient.swift`; `Tests/NyxRemoteTests/RemoteHostTests.swift`, `RemoteClientTests.swift` (with a fake `RelayLink` protocol the connection conforms to: `send(message)`, `send(frame)`, so orchestrators are tested without sockets).

**Interfaces (produces):**

```swift
public protocol RelayLink: AnyObject { func send(_ m: RemoteMessage); func send(_ f: BinaryFrame); var deviceID: String { get } }
extension RelayConnection: RelayLink {}

public final class RemoteHost {
    public init(link: RelayLink, identity: DeviceIdentity, paired: () -> PairedDevices, audit: @escaping (AuditLine.Event) -> Void, snapshotLines: Int)
    public func register(sessionID: [UInt8], session: TerminalSession, summary: @escaping () -> RemoteSessionInfo)   // taps session.onOutput; the pane calls `summaryChanged()` when it notices a change
    public func unregister(sessionID: [UInt8])       // sends session_ended to attached clients
    public func summaryChanged()                     // debounced 2 s → link.send(.sessions(...))
    public func handle(_ m: RemoteMessage)           // attach / take_control / detach from clients
    public func handle(_ f: BinaryFrame)             // input from the writer → session.send
    public func linkDidReconnect()                   // resend sessions + paired
}
public final class RemoteClient {
    public final class Attachment {
        public let sessionID: [UInt8]; public let hostID: String; public private(set) var state: AttachState
        public var onState: ((AttachState) -> Void)?; public var onBytes: (([UInt8]) -> Void)?   // decrypted PTY output, in order
        public func send(_ input: [UInt8])       // dropped unless state.acceptsInput
        public func takeControl(); public func detach()
        public var cols: Int; public var rows: Int
    }
    public init(link: RelayLink, identity: DeviceIdentity, paired: () -> PairedDevices)
    public func attach(hostID: String, hostName: String, sessionID: [UInt8], title: String) -> Attachment
    public func handle(_ m: RemoteMessage); public func handle(_ f: BinaryFrame)
    public func linkDidReconnect()                   // re-attaches every live attachment (state → .reconnecting, then a fresh snapshot)
}
```

Host attach handling: verify `sig` with `E2ESession.verifyPeer(…, deviceID: from)` and that `from` is paired (else ignore and audit nothing); make an ephemeral key, reply `attached` with role from `WriterArbiter.attached(from)`, cols/rows from the terminal; then, under `withTerminal`, take `transcript(rows: max(0, totalRows - snapshotLines)..<totalRows)` and enqueue it as the first frames; bytes from `onOutput` that arrive while the snapshot is being sent are appended to the same per-attachment queue (a serial `DispatchQueue` per host), so ordering is preserved and nothing is lost; then `snapshot_end`. The `onOutput` tap must return immediately: it appends to the queue and returns. Input frames: decrypt with the attachment's session; if the sender is the writer, `session.send`. `take_control`: arbiter → send `role` to every attached client; audit. `detach`/client offline: arbiter, audit. `unregister`: `session_ended` to all.

Client: `attach` creates the ephemeral key, sends `attach`, state `.attaching`; on `attached` verify the host's signature against `hostID`, build the `E2ESession`, state `.snapshot`; frames decrypt and go to `onBytes` in counter order; `snapshot_end` → `.live`; `role` → update role; `session_ended` → `.ended(hostName)`; `detach()` sends `detach` and stops.

- [ ] **Step 1: Tests** with the fake link and a real `TerminalSession`? `TerminalSession` spawns a process; for the host test use a small `/bin/cat`-less approach: spawn `/bin/sh -c 'printf "hello\r\n"; sleep 30'` via `SessionConfig`, register it, drive an attach from a fake client (real crypto both sides in-process), assert the first decrypted bytes contain `hello`, then feed input through the client and read it back in the shell's output (`sh -c 'read x; echo got:$x; sleep 30'` — typing `hi\n` yields `got:hi`). Also: an attach from an unpaired id is ignored; two clients → writer/observer roles; `take_control` swaps and both receive `role`; observer input is dropped by the client (`acceptsInput` false) and by the host if it arrives anyway; a tampered frame from the client is discarded; `unregister` sends `session_ended`. Client tests: state transitions on the message sequence; reordered frames rejected; `linkDidReconnect` re-sends `attach`.

- [ ] **Step 2–5:** implement → green (kill the `sleep` children in test teardown via `session.terminate()`) → both warning counts 0 → commit "NyxRemote: a host that answers attaches with a snapshot and a live tail, and a client that reads them".

---

### Task 8: Config keys, actions, settings page, pairing sheet

**Files:** `Sources/NyxCore/Config/Config.swift`, `ConfigParser.swift`, `ConfigDiff.swift` (`remoteChanged` flag, no deferred note), `KeyBinding.swift` (`remoteSessions = "remote_sessions"`, `remoteTakeControl = "remote_take_control"`, `remotePair = "remote_pair"`), `ActionCatalog.swift` (Shell section group `[.remoteSessions, .remotePair]`, Go section group `[.remoteTakeControl]`), `Sources/NyxApp/SettingsWindowController.swift` (Remote page), create `Sources/NyxApp/PairingSheet.swift`, `docs/configuration.md`; tests `ConfigTests`, `ConfigDiffTests`, `ActionCatalogTests`, `KeyBindingTests`.

Keys: `remote` (`off`/`on`, default off), `remote-device-name` (default `Host.current().localizedName ?? "Mac"`, resolved at use, stored empty), `remote-relay` (default `wss://nyx.agentforge.cc/v1/ws`), `remote-relay-token` (default empty; not comment-stripped: tokens may contain `#`), `remote-snapshot-lines` (default 2000, clamp 100…20000). Settings → Remote page: checkbox "Enable remote sessions", text fields for name/relay/token (token as `NSSecureTextField`), stepper for snapshot lines, a table "Paired devices" (name, id prefix, date) with Remove, buttons "Pair with another device…" and "Enter a code…", a read-only `NSTextView` with the last 20 audit lines, and a status line ("Online as <name>", "Relay unreachable", "Relay rejected this device's token", "Remote sessions are off"). `PairingSheet` is an `NSPanel` driven by `PairingFlow.sheetText`: a code label in a large monospaced font, a text field for the client side, the fingerprint in bold, Accept/Confirm/Close buttons; every control accessible; `UISnapshot` cases `pairing-{code,requested,confirming,paired,failed}-{dark,light}.png` and `settings-remote-{dark,light}.png`.

- [ ] **Step 1: Tests:** keys parse/clamp/round-trip through `defaultFileText`; diff flag; actions in the catalogue; `remote_sessions` has no default chord (menu + palette only).
- [ ] **Step 2–5:** implement, render snapshots, Read them, commit "Remote: the settings page, the pairing sheet and the keys behind them".

---

### Task 9: App wiring — coordinator, remote pane, strip, palette section, tabs

**Files:** Create `Sources/NyxApp/RemoteCoordinator.swift` (one per app: owns `DeviceIdentity`, `PairedDevices`, `RelayConnection`, `RemoteHost`, `RemoteClient`, `RemoteCatalogue`, the pairing flow; hops delegate callbacks to main; starts when `config.remote == .on` and a token is set; stops on `off`; exposes `catalogue`, `pair(host:)`, `pair(client code:)`, `attach(deviceID:sessionID:) -> RemoteClient.Attachment`, `status`), `Sources/NyxApp/RemoteSession.swift` (`final class RemoteSession: PaneSession` — owns a `Terminal` sized to the host's cols/rows fed on the main-thread-hopped `onBytes`; `send` → attachment.send; `resize` no-op; `terminate` → detach; `withTerminal` under its own lock), `Sources/NyxApp/RemoteStripView.swift` (the one-row strip over the top of the pane, like `StickyPromptView`, text + optional button from `AttachState`); modify `Pane.swift` (`init(_:config:remote: RemoteSession, state: AttachState)`; `session` becomes `let session: any PaneSession`; the strip; `acceptsInput` gate in `keyDown`/paste when the pane is remote; block chrome and shell-integration features work unchanged because marks arrive in the snapshot), `TabController.swift` (`openRemote(deviceID:sessionID:)` → new tab with the remote pane, title from `AttachState.tabTitle`, badge text via `TabBarItem`'s existing indicator or a new `label` field; the palette's Remote section from `coordinator.catalogue.paletteItems(now:)`; `.remoteSessions` opens the palette with the query "remote "; `.remoteTakeControl` on a remote pane; `.remotePair` opens the sheet; every local pane registers with `RemoteHost` when created and unregisters when closed, with `summaryChanged()` on title/cwd/prompt-mark changes), `AppDelegate.swift` (create the coordinator; pass it to windows), `UISnapshot.swift` (`remote-strip-{observer,reconnecting,ended}-{dark,light}.png`, `command-palette-remote.png`).

- [ ] **Step 1:** Extract `PaneSession` use in `Pane` (compile-only refactor, existing behaviour unchanged; full suite green). Commit "Pane talks to a session through a protocol".
- [ ] **Step 2:** `RemoteSession` + `Pane(remote:)` + strip + `TabController.openRemote`; palette section; actions; coordinator. Build warning-free; snapshots rendered and read.
- [ ] **Step 3:** Host registration of local panes and summaries; audit log writes; settings status line live.
- [ ] **Step 4:** Commit in three commits along those lines.

---

### Task 10: Two instances on one Mac, docs, reviews

- [ ] **Step 1: Rung 6.** Two config directories: `~/.config/nyx-a` and `~/.config/nyx-b`, each with `remote = on`, distinct `remote-device-name` (`alpha`, `beta`), the relay token from `~/projects/nyx-server/token`. Launch two instances: `NYX_CONFIG=~/.config/nyx-a/config ./build/Nyx.app/Contents/MacOS/Nyx` and the same for `b`. A temporary `NYX_SMOKE_QA=remote` hook in `AppDelegate` (instance b first): b opens the pairing sheet and prints the code; a joins with `NYX_SMOKE_PAIR_CODE`, both print the fingerprint, both confirm; a prints the catalogue; a attaches to b's first session, prints the first line of the snapshot and, after sending `echo smoke-ok\n`, the decrypted line containing `smoke-ok`; b prints the audit lines; a detaches. Paste every SMOKE line into the report. Remove the hook; `git diff --stat` clean of `AppDelegate.swift`.
- [ ] **Step 2: The ladder:** both warning counts 0; `swift test --no-parallel`; `NYX_RELAY_BIN=… swift test --filter RelayConnection`; `make bench` ×3; `NYX_UI_SNAPSHOT` (Read the remote/pairing/strip PNGs); `NYX_SNAPSHOT=1 swift test --filter Snapshot`.
- [ ] **Step 3: Docs:** README "Remote sessions" section (setup on both Macs, pairing, attaching, what the relay sees); `docs/configuration.md` keys and actions; `docs/architecture.md` (`NyxRemote` row in the module table, `Remote/` row in the Core table, "where to add things" row); `docs/status.md` rows; spec §11 note in the parent spec. Commit "Docs: remote sessions".
- [ ] **Step 4:** Controller runs `code-reviewer` (whole branch), `design-reviewer` (pairing sheet, settings page, strip, palette section), `product-manager`; fix waves; merge with a merge commit naming test count and bench; push; reinstall to /Applications.

---

## Self-review against the spec

§5.1 setup keys/page → T8; §5.2 pairing code, fingerprint, 5-minute expiry → T3, T6, T8, T9; §5.3 palette Remote section with live rows, offline devices, `remote_sessions` action → T2, T8, T9; §5.4 tab, snapshot then live, host grid size, badge, writer/observer strip, take control, host user never blocked, detach never affects host, reconnect with fresh snapshot → T4, T7, T9; §5.5 audit log + settings tail → T4, T7, T8; §5.6 failure faces → T2 (`relayStatusText`), T6 (`failed` statuses), T9 (strip states); §6 protocol → T1, T5, T6, T7 (mirrors the server plan); §7 modules → T1–T7, T9; §7.2 snapshot ordering without loss → T7; §7.3 security → T5, T7; §9 testing → every task + T10; §10 docs → T10.

Type consistency: `RemoteMessage` factory names in T1 are the ones T3 (`pairOpen`, `pairJoin`, `pairAccept`, `pairConfirm`), T6 (`hello`, `auth`, `paired`), T7 (`attach`, `attached`, `snapshotEnd`, `takeControl`, `role`, `detach`, `sessionEnded`, `sessions`) use; `AttachState.Role` is shared by `WriterArbiter` (T4), `RemoteHost`/`RemoteClient` (T7) and the strip (T9); `BinaryFrame` (T1) is what `E2ESession.seal/open` (T5), `RelayConnection` (T6) and the orchestrators (T7) pass around; `PaneSession` (T7) is what `Pane` (T9) and `RemoteSession` (T9) use.
