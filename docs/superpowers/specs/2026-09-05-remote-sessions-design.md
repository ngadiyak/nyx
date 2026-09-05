# Remote sessions — design

**Date:** 2026-09-05. **Status:** draft for review.
**Brief:** `REMOTE_TERMINAL_PROMPT.md` (repo root). **Parent spec:** `2026-09-03-nyx-terminal-design.md`.
**Server repository:** `github.com/ngadiyak/nyx-server` (empty; created for this).

## 1. Goal

The user works across several Macs, each with its own repos, running processes, agent sessions and
dev servers. Nyx on machine 1 attaches to a live session on machine 2 through a relay both machines
reach outbound, without any direct network path between them. This is *agent-native context
switching*: find the session where the build or the agent is running, read it, take control when
needed, leave it running. It is not an SSH replacement.

Decisions the user made (2026-09-05): remote sessions are listed in the command palette and open as
a tab in the current window; devices pair with a six-character code; payloads are end-to-end
encrypted from v1 so the relay never sees terminal text; attaching delivers the last 2,000 lines
of transcript (with OSC 133 marks) and then the live stream. Stack: Go for the relay, no Swift on
the server; relay runs as a Docker container on `89.124.111.196` behind the existing Caddy, on the
subdomain `nyx.agentforge.cc` (DNS record exists); existing services and ports are not touched.
For testing, "machine 2" is a second Nyx instance on the same Mac.

## 2. Non-goals (v1)

File transfer, clipboard sync, sudo/password helpers, multi-user teams, replacing SSH, server-side
command execution, remote *creation* of sessions (v1 attaches to sessions that exist on the host),
resizing the host's pane from a remote client, mobile clients, a web client.

## 3. Roles and topology

```
 Nyx (machine 1, "client")  ──wss──▶  nyx-relay (Go, Docker, behind Caddy)  ◀──wss──  Nyx (machine 2, "host")
        observer / writer                 routes envelopes, holds presence               owns PTY, shell, cwd
```

Every Nyx instance is both a potential host (it publishes its local sessions) and a potential client
(it can list and attach to other hosts' sessions). The relay only routes: it knows which devices are
online, which sessions each host advertises (metadata only), and which client is attached to which
session. Terminal bytes cross it as ciphertext it cannot read.

## 4. Approaches considered

**A. Direct P2P with the relay only for signalling (WebRTC data channels).** Lowest latency, no
relay bandwidth. Rejected for v1: NAT traversal, TURN fallback and a WebRTC stack on the Swift side
are weeks of work and a second transport to debug; the relay path is required anyway as fallback.

**B. Relay carries everything; host runs a separate daemon.** A headless agent on machine 2 owning
PTYs. Rejected: the user's sessions live inside Nyx.app (blocks, marks, scrollback); duplicating
PTY ownership in a daemon splits the model. If Nyx is not running on machine 2 there is nothing
worth attaching to.

**C. Relay carries everything; Nyx.app is the host (chosen).** One transport (WebSocket over TLS),
one codebase for the client side, the host's existing `TerminalSession` tapped for output and fed
for input. Simple, explicit, and the E2E layer sits on top without the relay knowing.

## 5. User-visible behaviour

### 5.1 Setup, once per device

`⌘,` → Remote page: **Enable remote sessions** (off by default), **Device name** (defaults to the
Mac's name), **Relay** (`wss://nyx.agentforge.cc/v1/ws`, editable), **Relay token** (a shared secret
the relay is deployed with; keeps strangers off the endpoint even before pairing), a list of
**Paired devices** with Remove, and **Pair with another device…**. Enabling generates the device
identity on first use and connects.

Config keys: `remote = off|on`, `remote-device-name`, `remote-relay`, `remote-relay-token`,
`remote-snapshot-lines = 2000`. Paired devices and the identity live in `~/.config/nyx/remote/`
(not in the config file: keys are not settings).

### 5.2 Pairing

On machine 2: Settings → Pair… shows a code like `K7M-4QZ` (6 characters, unambiguous alphabet)
valid for five minutes. On machine 1: Settings → Pair… → enter code. Both sides then show the same
short fingerprint of the pair (four words from a fixed list, e.g. `apple-river-stone-zero`) and a
**Confirm** button. Confirming on both stores the other device's public key and name. The code is
only a rendezvous token at the relay; the fingerprint comparison is what defeats a relay that
substitutes keys. A pairing not confirmed on both sides within five minutes is discarded.

### 5.3 Finding a session

`⌘⇧P` gains a **Remote** section: one row per remote session, `machine · title`, with a second line
`~/projects/nyx  main  · running: swift test · last: make test · 2 min ago`. Rows come from the
host's published metadata and update live while the palette is open. A host that is offline shows
its name greyed with "offline". The action `remote_sessions` (menu Shell → Remote Sessions…, no
default chord) opens the palette filtered to that section.

### 5.4 Attaching

Choosing a row opens a new tab in the current window titled `⟵ machine · title`. The tab shows the
last `remote-snapshot-lines` lines of the host's scrollback (with prompt marks, so blocks, folds
and ⌘↑ work immediately), then the live stream. The tab's grid takes the host pane's size; if the
window is smaller, the tab scrolls; if larger, the grid is letterboxed. The tab bar shows a small
badge: **observer** or **writer**.

The first client to attach becomes the writer; later ones are observers. An observer's keystrokes
are dropped and the tab shows a one-line strip "Observing — Take control" (a button, also the
action `remote_take_control`). Taking control demotes the previous writer to observer with the same
strip. The host's own user is never blocked: local input on machine 2 always works.

Closing the tab detaches. Detaching never affects the host session. A dropped connection shows
"Reconnecting…" in the strip and reattaches automatically with a fresh snapshot.

### 5.5 On the host

Nothing changes on screen. `~/.config/nyx/remote/audit.log` records, one line each: device paired
/ removed, `<device> attached to <session title>`, `took control`, `detached`, with timestamps.
Settings → Remote shows the last 20 lines.

### 5.6 Failure has a face

- Relay unreachable: the Remote section says "Relay unreachable (nyx.agentforge.cc)"; hosts keep
  retrying with backoff; nothing else in Nyx is affected.
- Wrong relay token: "Relay rejected this device's token" in the section and in the settings page.
- Host offline: the row says so; attach is disabled.
- Session ended on the host: the tab shows "Session ended on <machine>" and closes on the next key.
- Pairing code wrong or expired: said in the sheet.
- A device with `remote = off` is invisible to everyone and connects to nothing.

## 6. Protocol

WebSocket over TLS. Control messages are JSON text frames; terminal data are binary frames. Every
message carries `v: 1`. Field names are `snake_case`.

### 6.1 Connection and authentication

1. Client opens `wss://<relay>/v1/ws` and sends `hello {device_id, device_name, token}`.
   `device_id` is the Ed25519 public key, base64url.
2. Relay replies `challenge {nonce}`; client replies `auth {signature}` = Ed25519 over
   `"nyx-relay-v1" || nonce || device_id`. Relay replies `welcome {server_time}` or `error`.
3. Heartbeat: relay pings every 30 s; a socket silent for 90 s is closed and the device marked
   offline.

The relay token is compared in constant time; without it the socket is closed before `hello` is
answered, so the endpoint is invisible to scanners.

### 6.2 Presence and catalogue

- Host → relay: `sessions {sessions: [{session_id, title, cwd, repo, branch, process, last_command,
  last_activity, cols, rows}]}` on change, debounced to at most once per 2 s.
- Relay → client: `presence {devices: [{device_id, name, online}]}` and `catalogue {device_id,
  sessions}` for every device the client is paired with, on connect and on change. Catalogues are
  delivered only between paired devices; the relay learns pairings from `paired {device_ids}` that
  each device sends after `welcome` (both sides must list each other).

### 6.3 Pairing

- Host → relay: `pair_open {code}` (the code is generated on the host; relay keeps `code → device`
  for 5 minutes, one code per device).
- Client → relay: `pair_join {code, pubkey}`; relay forwards `pair_join` to the host as
  `pair_request {from, pubkey, name}` and the host's `pair_accept {to, pubkey, name}` back to the
  client. Each side computes the fingerprint `words(SHA256(min(pkA,pkB) || max(pkA,pkB)))[0..<4]`
  and shows it. `pair_confirm` from both sides closes the exchange; the relay then forgets the code.

### 6.4 Attach, control, data

- Client → relay → host: `attach {session_id, ephemeral_pubkey, sig}` (X25519 public key signed by
  the client's Ed25519 key). Host replies `attached {ephemeral_pubkey, sig, role, cols, rows}`
  (role `writer` or `observer`), then sends the snapshot as data frames, then `snapshot_end`.
- Shared secret: X25519(ephemeral_client, ephemeral_host) → HKDF-SHA256 with info
  `"nyx-e2e-v1" || session_id` → two ChaCha20-Poly1305 keys (host→client, client→host). Nonce =
  96-bit counter per direction. Every data frame is `session_id (16 bytes) || counter (8) || ciphertext`.
  The relay routes by `session_id` without decrypting.
- Data frames: host → client carry raw PTY output bytes; client → host carry input bytes (ignored by
  the host when the sender is not the writer).
- `take_control {session_id}` from a client; host replies `role {session_id, device_id, role}` to
  everyone attached.
- `detach {session_id}`; `session_ended {session_id}` from host to attached clients.
- Errors: `error {code, message}` with codes `bad_token`, `not_paired`, `no_such_session`,
  `host_offline`, `pair_expired`, `pair_taken`.

### 6.5 What the relay stores

In memory only: online devices with their socket, the `paired` lists they declared, open pairing
codes with expiry, and attachments (`session_id → host, [clients]`). Restarting the relay drops all
of it; clients reconnect and re-declare. No database, no files.

## 7. Client design (Nyx)

### 7.1 Modules

- `NyxCore/Remote/` (pure, tested): `RemoteMessage` (Codable envelopes, §6), `RemoteCatalogue`
  (devices + sessions, palette rows, sorting, "offline" text), `PairingFlow` (state machine: idle →
  showing code → request received → fingerprint shown → confirmed/expired, and the client mirror),
  `AttachState` (idle → attaching → snapshot → live → reconnecting → ended; role; strip text),
  `WriterArbiter` (who writes; first attacher wins; take-control transfers; host local input never
  arbitrated), `SessionSummary` (what a host publishes for a pane, from title, cwd, marks and the
  foreground process name), `Fingerprint` (words from a hash), `AuditLine` (formatting), `Backoff`.
- `NyxRemote` (new SwiftPM target; Foundation + CryptoKit + NyxCore; no AppKit): `RelayConnection`
  (URLSessionWebSocketTask, hello/challenge/auth, heartbeats, reconnect with `Backoff`),
  `DeviceIdentity` (Ed25519 keypair in `~/.config/nyx/remote/identity`, 0600, created once),
  `PairedDevices` (JSON file beside it), `E2ESession` (X25519 + HKDF + ChaChaPoly, counters),
  `RemoteHost` (publishes catalogue, answers attaches, taps `TerminalSession` output, writes input
  through the arbiter, writes the audit log), `RemoteClient` (attach/detach, decrypts to a byte
  stream, sends input). Tested with swift-testing: codec round-trips, crypto round-trips with a
  tampered frame rejected, identity file permissions, a fake relay (in-process WebSocket server is
  not available in Foundation — `RelayConnection` is tested against the Go relay in an integration
  test, see §9).
- `NyxApp`: `Pane` gains a second construction path, `Pane(remote: RemoteClient.Attachment, …)`,
  whose `TerminalSession` is replaced by a `RemoteSession` conforming to the same small interface
  (`withTerminal`, `send`, `onUpdate`, `resize` is a no-op, `terminate` detaches). The observer strip
  is chrome (`RemoteStripView`), with a `UISnapshot` case per state. Palette section, actions
  `remote_sessions` / `remote_take_control`, the Remote settings page, the pairing sheet.

The `TerminalSession` surface `Pane` uses is extracted into a protocol `PaneSession` so the remote
session is a second conformer rather than a fork of `Pane`.

### 7.2 Host side data path

`TerminalSession` gains `onOutput: (([UInt8]) -> Void)?`, called on the reader thread with the raw
bytes after they are fed to the terminal. `RemoteHost` encrypts and forwards them to every attached
client; the snapshot is `terminal.transcript(rows: last N)` (with marks, from blocks v2) taken under
`withTerminal` at attach time, sent before live bytes are allowed through (bytes arriving during
the snapshot are queued, so nothing is lost or duplicated). Input from the writer goes to
`session.send`. Session metadata (`SessionSummary`) is recomputed on `onUpdate` (debounced 2 s):
title, cwd (OSC 7), git repo/branch (read `.git/HEAD` under cwd — no git invocation), foreground
process name (`proc_pidinfo`, already used for cwd), last command and last activity (prompt marks).
The snapshot carries text, attributes and prompt marks but no alternate-screen or mode state, so
attaching while the host runs a full-screen program (vim, htop, a pager) shows that program's rows
in the primary buffer until it next redraws — correct-looking but in the wrong buffer, and left
that way in v1: carrying mode state across an attach is a v1.1 item.

### 7.3 Security summary

Device identity Ed25519; relay authentication by challenge signature plus a shared relay token;
pairing by rendezvous code with out-of-band fingerprint confirmation; per-attach X25519 with
ephemeral keys signed by the device keys (forward secrecy per attachment); ChaCha20-Poly1305 with
per-direction counters (replay and reordering rejected); the relay sees device ids, names, session
metadata and ciphertext sizes. Metadata is not encrypted in v1 (the palette needs it before any
attach); this is stated in the settings page.

## 8. Server design (nyx-server)

- Go 1.22+, standard library plus `nhooyr.io/websocket` (or `gorilla/websocket`) and
  `golang.org/x/crypto` for Ed25519 verification. Single binary `nyx-relay`.
- Packages: `relay/` (hub: devices, pairings, codes, attachments, routing), `protocol/` (message
  types mirroring §6, with a JSON schema-like validation), `cmd/nyx-relay/` (flags: `-listen
  :8787`, `-token-file`, `-log json`).
- Tests: hub logic with fake connections (routing, pairing expiry, attach/detach, take-control
  broadcast, unpaired catalogue not delivered); an end-to-end test with `httptest` and two
  WebSocket clients.
- Deployment (in the repo): `Dockerfile` (multi-stage, static binary, distroless), `compose.yml`
  (service `nyx-relay` on the external network `remnawave-network`, no host ports, token from
  `/opt/nyx-server/token`), `caddy/nyx.caddy` (one site block: `nyx.agentforge.cc { reverse_proxy
  nyx-relay:8787 }`), `deploy.sh` (from the dev Mac: `rsync` the repo to `/opt/nyx-server`, `docker
  compose build && up -d`, add `import /opt/nyx-server/caddy/nyx.caddy` to the existing Caddyfile
  once if missing, `docker exec caddy caddy reload`), `README.md` (ops: logs, token rotation,
  restart). The token is generated once by `deploy.sh` and printed for pasting into both Macs.
- Observability: structured logs (connect, auth fail, pair open/close, attach/detach) without
  payloads; `/healthz` on the same port for Caddy.

## 9. Testing

- Core: state machines, arbiter, catalogue rows, summary extraction, fingerprint words, audit
  lines, message codec — swift-testing, exhaustive per transition.
- NyxRemote: crypto round-trip and tamper rejection, identity file creation and permissions,
  paired-devices persistence.
- Server: Go unit tests and the httptest end-to-end.
- Integration (opt-in, `NYX_REMOTE_INTEGRATION=1`): a swift test launches the Go relay binary
  locally, two `RelayConnection`s pair through it, attach, and exchange encrypted bytes.
- Rung 6: two Nyx instances on this Mac (`NYX_CONFIG` pointing at two config directories with
  different device names) against the deployed relay; a temporary hook attaches from instance 1 to
  instance 2, prints the snapshot's first line and a round-tripped keystroke, then is removed.
- UI snapshots: the Remote settings page, the pairing sheet (code shown, fingerprint shown), the
  observer/writer strip, the palette's Remote section with an online and an offline host.

## 10. Documentation

README section "Remote sessions"; `docs/configuration.md` keys and actions; `docs/architecture.md`
new target and module rows; `docs/status.md`; nyx-server README for operations.

## 11. Open questions resolved by default

- The relay token is one shared secret for all of the user's devices (personal use); rotation is
  editing the file and redeploying.
- Sessions are identified by a random 16-byte id generated when the pane is created (stable for the
  pane's life, not persisted across relaunch).
- A host advertises every pane, including remote-attached ones? No: only local PTY panes are
  published, so attachments cannot chain.
- Snapshot size counts rows, not bytes; a 2,000-row transcript with attributes is under 1 MB in
  practice.
