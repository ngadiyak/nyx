# Remote Sessions — Relay Server Implementation Plan (nyx-server)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small Go relay, `nyx-relay`, that authenticates Nyx devices, tracks presence and session catalogues, rendezvous-pairs devices by code, and routes control messages and encrypted terminal frames between paired devices — deployed as a Docker container behind the existing Caddy on `nyx.agentforge.cc`.

**Architecture:** One binary, three packages: `protocol` (message shapes and validation, the contract the Nyx client mirrors), `relay` (the hub: devices, pairings, codes, attachments, routing — pure logic over an abstract connection), `server` (WebSocket transport with `github.com/coder/websocket`, auth handshake, heartbeats, `/healthz`). The hub holds everything in memory; a restart forgets it and clients re-declare.

**Tech Stack:** Go 1.22+ (installed locally at `/opt/homebrew/bin/go`, 1.27), `github.com/coder/websocket` v1.8.x, stdlib `crypto/ed25519`, `net/http/httptest` for end-to-end tests. Docker multi-stage build on the server (Docker 29, Compose v5); no Go on the server.

**Spec:** `/Users/nik/projects/nyx/docs/superpowers/specs/2026-09-05-remote-sessions-design.md` (§6 protocol, §8 server). This plan is the protocol's authoritative wire definition; the client plan mirrors it.

## Global Constraints

- Repository: `/Users/nik/projects/nyx-server` (cloned, empty; remote `git@github.com:ngadiyak/nyx-server.git`, branch `main`). Module path `github.com/ngadiyak/nyx-server`.
- Go code is `gofmt`-clean and `go vet`-clean; `go test ./...` passes; no test uses real network ports other than `httptest`.
- The relay never decrypts, logs or stores terminal payloads. Logs carry device ids (first 8 chars), names, message types and errors — never message bodies.
- The relay token is compared with `crypto/subtle.ConstantTimeCompare`; a wrong token gets `error bad_token` and the socket closed.
- All wire strings for keys, nonces, signatures and session ids are base64url without padding. Device id = base64url(32-byte Ed25519 public key). Session id = base64url(16 random bytes).
- Every JSON message has `"v": 1` and `"t": "<type>"`; unknown `t` from an authenticated device → `error {code: "bad_message"}` and the message is dropped (the socket stays open).
- Server: existing ports and services on `89.124.111.196` are not touched; the relay container joins the external Docker network `remnawave-network` and exposes no host port; Caddy reaches it as `nyx-relay:8787`; the only edit to the existing Caddyfile (`/opt/remnawave/caddy/Caddyfile`) is one `import /opt/nyx-server/caddy/nyx.caddy` line.
- Commit messages: one plain sentence; body with why; trailer on every commit:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01YHJ5Uc1qA7f7FHixuhp8Gy`. `git add` by name.

---

## Wire protocol (the contract)

WebSocket at `wss://<host>/v1/ws`. Text frames are JSON control messages; binary frames are terminal data. Field names `snake_case`. A message the relay forwards between devices is forwarded verbatim plus `"from": "<sender device_id>"`; the relay sets `from` itself and ignores any `from` a sender supplies.

| `t` | direction | fields | relay behaviour |
|---|---|---|---|
| `hello` | device → relay | `device_id`, `device_name`, `token` | first message; wrong token → `error bad_token` + close 4401; else `challenge` |
| `challenge` | relay → device | `nonce` (32 bytes b64url) | |
| `auth` | device → relay | `signature` = Ed25519 over `"nyx-relay-v1" ‖ nonce ‖ device_id_bytes` | bad → `error bad_signature` + close 4403; good → `welcome` |
| `welcome` | relay → device | `server_time` (RFC 3339) | device is now online |
| `error` | relay → device | `code`, `message` | codes below |
| `paired` | device → relay | `device_ids: [..]` | the devices this one trusts; a pairing is mutual only when both lists contain each other |
| `presence` | relay → device | `devices: [{device_id, name, online}]` | sent after `welcome` and whenever a mutually paired device's presence changes; lists the device's own `paired` entries |
| `sessions` | host → relay | `sessions: [Session]` | stored as the host's catalogue; forwarded as `catalogue` to every online mutually paired device |
| `catalogue` | relay → device | `device_id` (the host), `sessions: [Session]` | also sent after `welcome` for every online mutually paired host |
| `pair_open` | host → relay | `code` (6 chars `[A-HJ-NP-Z2-9]`, host-generated) | stores `code → host` for 5 minutes; a second `pair_open` from the same host replaces its code; a code in use by another host → `error pair_taken` |
| `pair_opened` | relay → host | `code` | acknowledges `pair_open`; the host shows the code only after this, so a client cannot join before the relay knows the code |
| `pair_join` | client → relay | `code` | unknown/expired → `error pair_expired`; else forwards `pair_request {from, name}` to the host and remembers `code → (host, client)` |
| `pair_request` | relay → host | `from`, `name` | |
| `pair_accept` | host → relay → client | `to` | forwarded (with `from`, `name`) only to the client of the host's open code |
| `pair_confirm` | either → relay → other | `to` | forwarded between the two parties of the code; when both have sent it the code is deleted |
| `attach` | client → relay → host | `to`, `session_id`, `ephemeral_pubkey`, `sig` | forwarded if mutually paired and `to` online, else `error not_paired` / `host_offline` |
| `attached` | host → relay → client | `to`, `session_id`, `ephemeral_pubkey`, `sig`, `role` (`writer`/`observer`), `cols`, `rows` | forwarded; relay records `session_id → host` and adds `to` to its attached clients |
| `snapshot_end` | host → relay → client | `to`, `session_id` | forwarded |
| `take_control` | client → relay → host | `to`, `session_id` | forwarded |
| `role` | host → relay → client | `to`, `session_id`, `device_id`, `role` | forwarded (the host sends one per attached client) |
| `detach` | client → relay → host | `to`, `session_id` | forwarded; relay removes the client from the attachment |
| `session_ended` | host → relay → client | `to`, `session_id` | forwarded; relay removes the client from the attachment |
| `session_suspended` | relay → client | `session_id`, `from` (the host) | sent to every attached client when the *host* disconnects (instead of `session_ended`, which only a host sends); the attachment is dropped at the relay; the client keeps the tab and re-attaches when the host's catalogue lists the session again |

`Session` = `{session_id, title, cwd, repo, branch, process, last_command, last_activity (RFC 3339), cols, rows}`; string fields may be empty.

Binary frames: `session_id (16 raw bytes) ‖ counter (8 bytes big-endian) ‖ ciphertext`. From the session's host: forwarded to every attached client of that session. From an attached client: forwarded to the host. Anything else: dropped and counted.

Error codes: `bad_token`, `bad_signature`, `bad_message`, `not_paired`, `host_offline`, `no_such_session`, `pair_expired`, `pair_taken`, `too_many`.

An `error` that answers a message naming a session echoes that message's `session_id` and `to`, so a client can attribute `host_offline`, `not_paired`, `no_such_session` or `too_many` to the right attachment.

Close codes: 4400 (protocol violation before auth), 4401 (bad token), 4403 (bad signature), 4000 (replaced by a newer connection of the same device), 1001 (relay shutting down).

Ownership and limits (added after review): a host may only send `attached` for a session id it currently publishes in its `sessions`; an `attach` naming a session the host does not publish, or an `attached` for a session another host already owns, is answered `no_such_session`. `host_offline` is answered only when the relay can prove the pairing was mutual (it keeps an offline device's last declared peers for one hour), otherwise `not_paired`. Caps per device: 64 paired ids, 256 sessions, 64 hosted attachments, 10 `pair_join` per 5 minutes; a code already joined by another device answers `pair_taken`. Over a cap → `error too_many`. Every connection has a bounded outbound queue (256 frames); a peer that does not drain it is closed.

Presence rules: a device is online from `welcome` until its socket closes or is silent for 90 s (the relay pings every 30 s). On disconnect: its catalogue is dropped (paired devices get an empty `catalogue` for it), every attachment it hosted sends **`session_suspended`** to the attached clients (`session_ended` is host-originated only — a host that has gone cannot say its session is over), every attachment it was a client of is left, and mutually paired devices get a `presence` update. The three arrive in that order — `session_suspended`, then the empty `catalogue`, then the `presence` — which is why a client must not treat that catalogue as news about the session until the presence says the host is back. In the other direction, on every client connect *and* reconnect the relay answers a `paired` declaration with that device's `presence` first and its peers' `catalogue`s after it, so a client re-attaching after its own outage learns whether a host is there before any catalogue arrives (or fails to).

---

## File map

```
nyx-server/
  go.mod, go.sum, Makefile, README.md, .gitignore
  protocol/   message.go (Envelope, Session, Decode/Encode, Validate), message_test.go
  relay/      hub.go (Hub, Conn interface, Device, routing), pairing.go (codes, expiry), hub_test.go, pairing_test.go
  server/     server.go (HTTP handler, handshake, heartbeats, /healthz), server_test.go (httptest end-to-end)
  cmd/nyx-relay/main.go
  Dockerfile, compose.yml, caddy/nyx.caddy, deploy.sh
```

---

### Task 0: Repository skeleton

**Files:** Create `go.mod`, `Makefile`, `.gitignore`, `README.md` in `/Users/nik/projects/nyx-server`.

- [ ] **Step 1: Initialise the module and the tooling**

```bash
cd /Users/nik/projects/nyx-server
export PATH=/opt/homebrew/bin:$PATH
go mod init github.com/ngadiyak/nyx-server
go get github.com/coder/websocket@v1.8.13
```

`Makefile`:

```make
GO ?= /opt/homebrew/bin/go
.PHONY: build test vet fmt run
build: ; $(GO) build -o bin/nyx-relay ./cmd/nyx-relay
test: ; $(GO) test ./...
vet: ; $(GO) vet ./... && test -z "$$(gofmt -l .)"
fmt: ; gofmt -w .
run: build ; ./bin/nyx-relay -listen 127.0.0.1:8787 -token dev-token
```

`.gitignore`: `bin/`, `token`.

`README.md` (short for now; Task 6 completes the ops section):

```markdown
# nyx-server

The relay for Nyx remote sessions. Devices connect outbound over WebSocket/TLS; the relay
authenticates them, tracks which are online and which sessions each host offers, pairs devices by
a short code, and routes control messages and end-to-end-encrypted terminal frames between paired
devices. It stores nothing on disk and cannot read terminal contents.

Protocol: `docs/superpowers/specs/2026-09-05-remote-sessions-design.md` §6 in the Nyx repository
(the plan `docs/superpowers/plans/2026-09-05-remote-sessions-server.md` carries the wire table).
```

- [ ] **Step 2: Verify and commit**

Run: `make vet && make test` → no output from gofmt, `no test files` is fine.

```bash
git add go.mod go.sum Makefile .gitignore README.md
git commit -m "Start nyx-server: module, tooling and what it is for"
```

---

### Task 1: Protocol messages

**Files:** Create `protocol/message.go`, `protocol/message_test.go`.

**Interfaces (produces):**

```go
package protocol
const Version = 1
type Session struct { SessionID, Title, Cwd, Repo, Branch, Process, LastCommand string; LastActivity string; Cols, Rows int }  // json tags snake_case
type Envelope struct {
    V int `json:"v"`; T string `json:"t"`
    From, To string                       // json "from","to", omitempty
    DeviceID, DeviceName, Token, Nonce, Signature, Code, Name string   // snake_case, omitempty
    DeviceIDs []string; Devices []Presence; Sessions []Session
    SessionID, EphemeralPubkey, Sig, Role string; Cols, Rows int
    ServerTime, ErrCode, Message string  // json "server_time","code","message"
}
type Presence struct { DeviceID string; Name string; Online bool }
func Decode(b []byte) (Envelope, error)     // rejects v != 1, empty t
func (e Envelope) Encode() []byte
func (e Envelope) Validate() error          // per-type required fields (table below)
func Error(code, msg string) Envelope
func IsDeviceID(s string) bool              // base64url, decodes to 32 bytes
func IsSessionID(s string) bool             // base64url, decodes to 16 bytes
func IsPairCode(s string) bool              // 6 chars of [A-HJ-NP-Z2-9]
```

Required fields per type (Validate): `hello`: device_id (IsDeviceID), device_name non-empty, token non-empty; `auth`: signature; `paired`: device_ids all IsDeviceID; `sessions`: every session_id IsSessionID; `pair_open`/`pair_join`: code IsPairCode; `pair_accept`, `pair_confirm`, `take_control`, `detach`, `snapshot_end`, `session_ended`: to IsDeviceID (+ session_id for the session ones); `attach`: to, session_id, ephemeral_pubkey (32-byte b64url), sig (64-byte b64url); `attached`: to, session_id, ephemeral_pubkey, sig, role ∈ {writer, observer}, cols/rows > 0; `role`: to, session_id, device_id, role.

- [ ] **Step 1: Write the failing tests**

```go
package protocol

import "testing"

func TestDecodeRejectsWrongVersion(t *testing.T) {
    if _, err := Decode([]byte(`{"v":2,"t":"hello"}`)); err == nil {
        t.Fatal("expected error for v=2")
    }
    if _, err := Decode([]byte(`{"v":1}`)); err == nil {
        t.Fatal("expected error for missing t")
    }
}

func TestRoundTrip(t *testing.T) {
    e := Envelope{V: Version, T: "attached", To: "x", SessionID: "y", Role: "writer", Cols: 120, Rows: 40}
    d, err := Decode(e.Encode())
    if err != nil || d.T != "attached" || d.Cols != 120 || d.Role != "writer" {
        t.Fatalf("round trip lost data: %+v %v", d, err)
    }
}

func TestValidateHello(t *testing.T) {
    good := Envelope{V: 1, T: "hello", DeviceID: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", DeviceName: "mac", Token: "t"}
    if err := good.Validate(); err != nil {
        t.Fatalf("valid hello rejected: %v", err)
    }
    bad := good
    bad.DeviceID = "short"
    if err := bad.Validate(); err == nil {
        t.Fatal("short device id accepted")
    }
    bad = good
    bad.DeviceName = ""
    if err := bad.Validate(); err == nil {
        t.Fatal("empty name accepted")
    }
}

func TestIDs(t *testing.T) {
    if !IsDeviceID("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") { t.Fatal("32-byte id rejected") }
    if IsDeviceID("AAAA") { t.Fatal("4-byte id accepted") }
    if !IsSessionID("AAAAAAAAAAAAAAAAAAAAAA") { t.Fatal("16-byte session id rejected") }
    if !IsPairCode("K7M4QZ") { t.Fatal("good code rejected") }
    if IsPairCode("K7M4Q0") { t.Fatal("code with 0 accepted") }
    if IsPairCode("k7m4qz") { t.Fatal("lowercase accepted") }
}

func TestValidateAttached(t *testing.T) {
    e := Envelope{V: 1, T: "attached", To: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        SessionID: "AAAAAAAAAAAAAAAAAAAAAA", EphemeralPubkey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        Sig: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", Role: "writer", Cols: 80, Rows: 24}
    if err := e.Validate(); err != nil { t.Fatalf("valid attached rejected: %v", err) }
    e.Role = "boss"
    if err := e.Validate(); err == nil { t.Fatal("bad role accepted") }
}

func TestUnknownTypeIsAnError(t *testing.T) {
    if err := (Envelope{V: 1, T: "dance"}).Validate(); err == nil { t.Fatal("unknown type accepted") }
}
```

(43 base64url characters decode to 32 bytes; 22 to 16; 86 to 64.)

- [ ] **Step 2: Run to verify they fail**

Run: `make test` → compile errors (`undefined: Decode`).

- [ ] **Step 3: Implement**

```go
package protocol

import (
    "encoding/base64"
    "encoding/json"
    "errors"
    "fmt"
    "regexp"
)

const Version = 1

type Session struct {
    SessionID    string `json:"session_id"`
    Title        string `json:"title"`
    Cwd          string `json:"cwd"`
    Repo         string `json:"repo"`
    Branch       string `json:"branch"`
    Process      string `json:"process"`
    LastCommand  string `json:"last_command"`
    LastActivity string `json:"last_activity"`
    Cols         int    `json:"cols"`
    Rows         int    `json:"rows"`
}

type Presence struct {
    DeviceID string `json:"device_id"`
    Name     string `json:"name"`
    Online   bool   `json:"online"`
}

// Envelope is every message on the wire. One struct rather than one per type keeps decoding a
// single step; Validate says which fields a type needs.
type Envelope struct {
    V               int        `json:"v"`
    T               string     `json:"t"`
    From            string     `json:"from,omitempty"`
    To              string     `json:"to,omitempty"`
    DeviceID        string     `json:"device_id,omitempty"`
    DeviceName      string     `json:"device_name,omitempty"`
    Token           string     `json:"token,omitempty"`
    Nonce           string     `json:"nonce,omitempty"`
    Signature       string     `json:"signature,omitempty"`
    Code            string     `json:"code,omitempty"`
    Name            string     `json:"name,omitempty"`
    DeviceIDs       []string   `json:"device_ids,omitempty"`
    Devices         []Presence `json:"devices,omitempty"`
    Sessions        []Session  `json:"sessions,omitempty"`
    SessionID       string     `json:"session_id,omitempty"`
    EphemeralPubkey string     `json:"ephemeral_pubkey,omitempty"`
    Sig             string     `json:"sig,omitempty"`
    Role            string     `json:"role,omitempty"`
    Cols            int        `json:"cols,omitempty"`
    Rows            int        `json:"rows,omitempty"`
    ServerTime      string     `json:"server_time,omitempty"`
    Message         string     `json:"message,omitempty"`
}

// `error` messages carry their code in "code" too, which collides with the pairing code field on
// the wire only in name: an error never carries a pairing code and vice versa.

func Decode(b []byte) (Envelope, error) {
    var e Envelope
    if err := json.Unmarshal(b, &e); err != nil {
        return e, err
    }
    if e.V != Version {
        return e, fmt.Errorf("unsupported version %d", e.V)
    }
    if e.T == "" {
        return e, errors.New("missing t")
    }
    return e, nil
}

func (e Envelope) Encode() []byte {
    e.V = Version
    b, _ := json.Marshal(e)
    return b
}

func Error(code, msg string) Envelope {
    return Envelope{V: Version, T: "error", Code: code, Message: msg}
}

func decodesTo(s string, n int) bool {
    b, err := base64.RawURLEncoding.DecodeString(s)
    return err == nil && len(b) == n
}

func IsDeviceID(s string) bool  { return decodesTo(s, 32) }
func IsSessionID(s string) bool { return decodesTo(s, 16) }

var pairCode = regexp.MustCompile(`^[A-HJ-NP-Z2-9]{6}$`)

func IsPairCode(s string) bool { return pairCode.MatchString(s) }

func (e Envelope) Validate() error {
    need := func(ok bool, what string) error {
        if !ok {
            return fmt.Errorf("%s: bad or missing %s", e.T, what)
        }
        return nil
    }
    session := func() error {
        if err := need(IsDeviceID(e.To), "to"); err != nil {
            return err
        }
        return need(IsSessionID(e.SessionID), "session_id")
    }
    switch e.T {
    case "hello":
        if err := need(IsDeviceID(e.DeviceID), "device_id"); err != nil { return err }
        if err := need(e.DeviceName != "", "device_name"); err != nil { return err }
        return need(e.Token != "", "token")
    case "auth":
        return need(decodesTo(e.Signature, 64), "signature")
    case "paired":
        for _, id := range e.DeviceIDs {
            if err := need(IsDeviceID(id), "device_ids"); err != nil { return err }
        }
        return nil
    case "sessions":
        for _, s := range e.Sessions {
            if err := need(IsSessionID(s.SessionID), "session_id"); err != nil { return err }
        }
        return nil
    case "pair_open", "pair_join":
        return need(IsPairCode(e.Code), "code")
    case "pair_accept", "pair_confirm":
        return need(IsDeviceID(e.To), "to")
    case "take_control", "detach", "snapshot_end", "session_ended":
        return session()
    case "attach":
        if err := session(); err != nil { return err }
        if err := need(decodesTo(e.EphemeralPubkey, 32), "ephemeral_pubkey"); err != nil { return err }
        return need(decodesTo(e.Sig, 64), "sig")
    case "attached":
        if err := session(); err != nil { return err }
        if err := need(decodesTo(e.EphemeralPubkey, 32), "ephemeral_pubkey"); err != nil { return err }
        if err := need(decodesTo(e.Sig, 64), "sig"); err != nil { return err }
        if err := need(e.Role == "writer" || e.Role == "observer", "role"); err != nil { return err }
        return need(e.Cols > 0 && e.Rows > 0, "cols/rows")
    case "role":
        if err := session(); err != nil { return err }
        if err := need(IsDeviceID(e.DeviceID), "device_id"); err != nil { return err }
        return need(e.Role == "writer" || e.Role == "observer", "role")
    case "challenge", "welcome", "error", "presence", "catalogue", "pair_request":
        return nil // relay-originated; never validated on receipt by the relay
    }
    return fmt.Errorf("unknown message type %q", e.T)
}
```

- [ ] **Step 4: Run the tests**

Run: `make vet && make test` → `ok github.com/ngadiyak/nyx-server/protocol`.

- [ ] **Step 5: Commit**

```bash
git add protocol/message.go protocol/message_test.go
git commit -m "Protocol: every message the relay and the clients exchange, with validation"
```

---

### Task 2: The hub — devices, pairing, catalogue, attachments, routing

**Files:** Create `relay/conn.go`, `relay/hub.go`, `relay/pairing.go`, `relay/hub_test.go`, `relay/pairing_test.go`.

**Interfaces (produces):**

```go
package relay
type Conn interface { SendText(b []byte) error; SendBinary(b []byte) error; Close(code int, reason string) }
type Clock func() time.Time
type Hub struct { /* private */ }
func NewHub(clock Clock) *Hub
func (h *Hub) Online(id, name string, c Conn)          // after a successful handshake
func (h *Hub) Offline(id string)                       // socket closed
func (h *Hub) HandleText(from string, b []byte)        // an authenticated device's text frame
func (h *Hub) HandleBinary(from string, b []byte)      // an authenticated device's binary frame
func (h *Hub) Expire()                                 // drops pairing codes older than 5 minutes; call once a minute
func (h *Hub) Stats() Stats                            // counts for /healthz and logs
```

The hub is single-goroutine-safe by a mutex; every public method locks. Sends are performed while holding the lock via `Conn` methods that must not block for long — the server's `Conn` implementation writes with a per-connection timeout.

- [ ] **Step 1: Write the failing tests**

`relay/hub_test.go` uses a fake conn that records frames:

```go
package relay

import (
    "encoding/base64"
    "encoding/json"
    "testing"
    "time"

    "github.com/ngadiyak/nyx-server/protocol"
)

type fake struct {
    texts  [][]byte
    bins   [][]byte
    closed bool
}

func (f *fake) SendText(b []byte) error   { f.texts = append(f.texts, b); return nil }
func (f *fake) SendBinary(b []byte) error { f.bins = append(f.bins, b); return nil }
func (f *fake) Close(int, string)         { f.closed = true }

func (f *fake) last() protocol.Envelope {
    var e protocol.Envelope
    if len(f.texts) > 0 {
        _ = json.Unmarshal(f.texts[len(f.texts)-1], &e)
    }
    return e
}

func (f *fake) find(t string) *protocol.Envelope {
    for i := len(f.texts) - 1; i >= 0; i-- {
        var e protocol.Envelope
        _ = json.Unmarshal(f.texts[i], &e)
        if e.T == t {
            return &e
        }
    }
    return nil
}

func id(seed byte) string {
    b := make([]byte, 32)
    for i := range b { b[i] = seed }
    return base64.RawURLEncoding.EncodeToString(b)
}

func sid(seed byte) string {
    b := make([]byte, 16)
    for i := range b { b[i] = seed }
    return base64.RawURLEncoding.EncodeToString(b)
}

func msg(e protocol.Envelope) []byte { e.V = 1; return e.Encode() }

var now = time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)

func newHub() (*Hub, *time.Time) {
    t := now
    return NewHub(func() time.Time { return t }), &t
}

// Two devices that declared each other.
func pairedHub() (*Hub, *fake, *fake) {
    h, _ := newHub()
    a, b := &fake{}, &fake{}
    h.Online(id(1), "alpha", a)
    h.Online(id(2), "beta", b)
    h.HandleText(id(1), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(2)}}))
    h.HandleText(id(2), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(1)}}))
    return h, a, b
}

func TestPresenceIsMutualAndLive(t *testing.T) {
    h, a, b := pairedHub()
    p := b.find("presence")
    if p == nil || len(p.Devices) != 1 || p.Devices[0].DeviceID != id(1) || !p.Devices[0].Online || p.Devices[0].Name != "alpha" {
        t.Fatalf("beta did not learn alpha is online: %+v", p)
    }
    h.Offline(id(1))
    p = b.find("presence")
    if p == nil || p.Devices[0].Online {
        t.Fatalf("beta did not learn alpha went offline: %+v", p)
    }
    _ = a
}

func TestOneSidedPairingSharesNothing(t *testing.T) {
    h, _ := newHub()
    a, b := &fake{}, &fake{}
    h.Online(id(1), "alpha", a)
    h.Online(id(2), "beta", b)
    h.HandleText(id(1), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(2)}}))
    h.HandleText(id(1), msg(protocol.Envelope{T: "sessions", Sessions: []protocol.Session{{SessionID: sid(9), Title: "zsh"}}}))
    if b.find("catalogue") != nil {
        t.Fatal("beta received a catalogue from a device it has not paired with")
    }
    h.HandleText(id(2), msg(protocol.Envelope{T: "attach", To: id(1), SessionID: sid(9),
        EphemeralPubkey: id(7), Sig: base64.RawURLEncoding.EncodeToString(make([]byte, 64))}))
    if e := b.last(); e.T != "error" || e.Code != "not_paired" {
        t.Fatalf("expected not_paired, got %+v", e)
    }
}

func TestCatalogueFlowsToPairedDevices(t *testing.T) {
    h, _, b := pairedHub()
    h.HandleText(id(1), msg(protocol.Envelope{T: "sessions", Sessions: []protocol.Session{{SessionID: sid(9), Title: "make"}}}))
    c := b.find("catalogue")
    if c == nil || c.DeviceID != id(1) || len(c.Sessions) != 1 || c.Sessions[0].Title != "make" {
        t.Fatalf("beta did not get alpha's catalogue: %+v", c)
    }
    // A device coming online later gets the catalogue on connect.
    g := &fake{}
    h.Online(id(3), "gamma", g)
    h.HandleText(id(3), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(1)}}))
    h.HandleText(id(1), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(2), id(3)}}))
    if c := g.find("catalogue"); c == nil || c.DeviceID != id(1) {
        t.Fatal("gamma did not get alpha's catalogue once mutually paired")
    }
    // Host offline: paired devices get an empty catalogue for it.
    h.Offline(id(1))
    if c := b.find("catalogue"); c == nil || len(c.Sessions) != 0 {
        t.Fatalf("beta kept alpha's sessions after alpha went offline: %+v", c)
    }
}

func TestPairingByCode(t *testing.T) {
    h, clock := newHub()
    host, client := &fake{}, &fake{}
    h.Online(id(1), "host", host)
    h.Online(id(2), "client", client)
    h.HandleText(id(1), msg(protocol.Envelope{T: "pair_open", Code: "K7M4QZ"}))
    h.HandleText(id(2), msg(protocol.Envelope{T: "pair_join", Code: "K7M4QZ"}))
    r := host.find("pair_request")
    if r == nil || r.From != id(2) || r.Name != "client" {
        t.Fatalf("host did not get the request: %+v", r)
    }
    h.HandleText(id(1), msg(protocol.Envelope{T: "pair_accept", To: id(2)}))
    a := client.find("pair_accept")
    if a == nil || a.From != id(1) || a.Name != "host" {
        t.Fatalf("client did not get the accept: %+v", a)
    }
    h.HandleText(id(1), msg(protocol.Envelope{T: "pair_confirm", To: id(2)}))
    h.HandleText(id(2), msg(protocol.Envelope{T: "pair_confirm", To: id(1)}))
    if c := client.find("pair_confirm"); c == nil || c.From != id(1) {
        t.Fatal("client did not get host's confirm")
    }
    if c := host.find("pair_confirm"); c == nil || c.From != id(2) {
        t.Fatal("host did not get client's confirm")
    }
    // The code is gone once both confirmed.
    h.HandleText(id(2), msg(protocol.Envelope{T: "pair_join", Code: "K7M4QZ"}))
    if e := client.last(); e.T != "error" || e.Code != "pair_expired" {
        t.Fatalf("code still usable after confirmation: %+v", e)
    }
    // Expiry.
    h.HandleText(id(1), msg(protocol.Envelope{T: "pair_open", Code: "ABCDEF"}))
    *clock = now.Add(6 * time.Minute)
    h.Expire()
    h.HandleText(id(2), msg(protocol.Envelope{T: "pair_join", Code: "ABCDEF"}))
    if e := client.last(); e.T != "error" || e.Code != "pair_expired" {
        t.Fatalf("expired code accepted: %+v", e)
    }
}

func TestCodeInUseByAnotherHost(t *testing.T) {
    h, _ := newHub()
    a, b := &fake{}, &fake{}
    h.Online(id(1), "a", a)
    h.Online(id(2), "b", b)
    h.HandleText(id(1), msg(protocol.Envelope{T: "pair_open", Code: "K7M4QZ"}))
    h.HandleText(id(2), msg(protocol.Envelope{T: "pair_open", Code: "K7M4QZ"}))
    if e := b.last(); e.T != "error" || e.Code != "pair_taken" {
        t.Fatalf("expected pair_taken, got %+v", e)
    }
}

func attached(t *testing.T) (*Hub, *fake, *fake) {
    h, host, client := pairedHub()
    sig := base64.RawURLEncoding.EncodeToString(make([]byte, 64))
    h.HandleText(id(2), msg(protocol.Envelope{T: "attach", To: id(1), SessionID: sid(9), EphemeralPubkey: id(7), Sig: sig}))
    if a := host.find("attach"); a == nil || a.From != id(2) {
        t.Fatal("host did not get the attach")
    }
    h.HandleText(id(1), msg(protocol.Envelope{T: "attached", To: id(2), SessionID: sid(9), EphemeralPubkey: id(8), Sig: sig, Role: "writer", Cols: 100, Rows: 30}))
    if a := client.find("attached"); a == nil || a.From != id(1) || a.Role != "writer" {
        t.Fatal("client did not get attached")
    }
    return h, host, client
}

func TestBinaryFramesRouteBySession(t *testing.T) {
    h, host, client := attached(t)
    raw, _ := base64.RawURLEncoding.DecodeString(sid(9))
    frame := append(append(raw, make([]byte, 8)...), []byte("cipher")...)
    h.HandleBinary(id(1), frame)
    if len(client.bins) != 1 || string(client.bins[0][24:]) != "cipher" {
        t.Fatalf("client did not receive the host's frame: %v", client.bins)
    }
    h.HandleBinary(id(2), frame)
    if len(host.bins) != 1 {
        t.Fatalf("host did not receive the client's frame: %v", host.bins)
    }
    // An unrelated device's frame for this session is dropped.
    g := &fake{}
    h.Online(id(3), "gamma", g)
    h.HandleBinary(id(3), frame)
    if len(host.bins) != 1 || len(client.bins) != 1 {
        t.Fatal("a stranger's frame was routed")
    }
    // Detach: the client's frames no longer reach the host.
    h.HandleText(id(2), msg(protocol.Envelope{T: "detach", To: id(1), SessionID: sid(9)}))
    h.HandleBinary(id(2), frame)
    if len(host.bins) != 1 {
        t.Fatal("frame routed after detach")
    }
}

func TestHostOfflineEndsSessions(t *testing.T) {
    h, _, client := attached(t)
    h.Offline(id(1))
    if e := client.find("session_ended"); e == nil || e.SessionID != sid(9) {
        t.Fatal("client was not told the session ended")
    }
}

func TestAttachToOfflineHost(t *testing.T) {
    h, _, client := pairedHub()
    h.Offline(id(1))
    sig := base64.RawURLEncoding.EncodeToString(make([]byte, 64))
    h.HandleText(id(2), msg(protocol.Envelope{T: "attach", To: id(1), SessionID: sid(9), EphemeralPubkey: id(7), Sig: sig}))
    if e := client.last(); e.T != "error" || e.Code != "host_offline" {
        t.Fatalf("expected host_offline, got %+v", e)
    }
}

func TestUnknownTypeIsReportedNotFatal(t *testing.T) {
    h, a, _ := pairedHub()
    h.HandleText(id(1), []byte(`{"v":1,"t":"dance"}`))
    if e := a.last(); e.T != "error" || e.Code != "bad_message" || a.closed {
        t.Fatalf("expected bad_message without a close, got %+v closed=%v", e, a.closed)
    }
}

func TestForwardedMessagesCarryFromAndNeverTrustIt(t *testing.T) {
    h, host, _ := pairedHub()
    h.HandleText(id(2), msg(protocol.Envelope{T: "take_control", To: id(1), SessionID: sid(9), From: id(3)}))
    if e := host.find("take_control"); e == nil || e.From != id(2) {
        t.Fatalf("from was not set by the relay: %+v", e)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test` → compile errors in `relay`.

- [ ] **Step 3: Implement the hub**

`relay/conn.go`:

```go
package relay

// Conn is what the hub needs from a socket. The server implements it with per-write timeouts so a
// stalled client cannot hold the hub's lock.
type Conn interface {
    SendText(b []byte) error
    SendBinary(b []byte) error
    Close(code int, reason string)
}
```

`relay/pairing.go`:

```go
package relay

import "time"

const codeTTL = 5 * time.Minute

type pairing struct {
    host    string
    client  string // set on pair_join
    opened  time.Time
    hostOK  bool // pair_confirm seen from the host
    clientOK bool
}

type pairings struct {
    byCode map[string]*pairing
}

func newPairings() pairings { return pairings{byCode: map[string]*pairing{}} }

// open registers a code for a host, replacing the host's previous code. Returns false when another
// host holds the code.
func (p *pairings) open(code, host string, now time.Time) bool {
    if existing, ok := p.byCode[code]; ok && existing.host != host {
        return false
    }
    for c, pr := range p.byCode {
        if pr.host == host && c != code {
            delete(p.byCode, c)
        }
    }
    p.byCode[code] = &pairing{host: host, opened: now}
    return true
}

func (p *pairings) join(code, client string, now time.Time) (*pairing, bool) {
    pr, ok := p.byCode[code]
    if !ok || now.Sub(pr.opened) > codeTTL {
        delete(p.byCode, code)
        return nil, false
    }
    pr.client = client
    return pr, true
}

// between finds the open pairing whose two parties are exactly a and b (in either order).
func (p *pairings) between(a, b string) (string, *pairing) {
    for code, pr := range p.byCode {
        if (pr.host == a && pr.client == b) || (pr.host == b && pr.client == a) {
            return code, pr
        }
    }
    return "", nil
}

func (p *pairings) expire(now time.Time) {
    for code, pr := range p.byCode {
        if now.Sub(pr.opened) > codeTTL {
            delete(p.byCode, code)
        }
    }
}
```

`relay/hub.go`:

```go
package relay

import (
    "encoding/base64"
    "sync"
    "time"

    "github.com/ngadiyak/nyx-server/protocol"
)

type Clock func() time.Time

type device struct {
    id, name string
    conn     Conn
    paired   map[string]bool // devices this one declared
    sessions []protocol.Session
}

type attachment struct {
    host    string
    clients map[string]bool
}

type Stats struct {
    Online, Pairings, Attachments int
    DroppedBinary                 int
}

// Hub routes between authenticated devices. Everything is in memory: restart the relay and the
// devices reconnect and re-declare.
type Hub struct {
    mu       sync.Mutex
    clock    Clock
    devices  map[string]*device
    pairings pairings
    attached map[string]*attachment // by session id (wire string)
    dropped  int
}

func NewHub(clock Clock) *Hub {
    return &Hub{clock: clock, devices: map[string]*device{}, pairings: newPairings(), attached: map[string]*attachment{}}
}

func (h *Hub) send(id string, e protocol.Envelope) {
    if d, ok := h.devices[id]; ok {
        _ = d.conn.SendText(e.Encode())
    }
}

func (h *Hub) mutual(a, b string) bool {
    da, oka := h.devices[a]
    db, okb := h.devices[b]
    return oka && okb && da.paired[b] && db.paired[a]
}

// declaredPeers lists everything `id` declared, online or not (offline devices are still shown,
// as offline, so the palette can name them).
func (h *Hub) presenceFor(id string) protocol.Envelope {
    d := h.devices[id]
    var out []protocol.Presence
    for peer := range d.paired {
        p := protocol.Presence{DeviceID: peer}
        if pd, ok := h.devices[peer]; ok && pd.paired[id] {
            p.Name, p.Online = pd.name, true
        }
        out = append(out, p)
    }
    return protocol.Envelope{T: "presence", Devices: out}
}

func (h *Hub) broadcastPresence(about string) {
    for id, d := range h.devices {
        if id != about && d.paired[about] {
            h.send(id, h.presenceFor(id))
        }
    }
}

func (h *Hub) sendCatalogues(to string) {
    for peer := range h.devices[to].paired {
        if h.mutual(to, peer) {
            h.send(to, protocol.Envelope{T: "catalogue", DeviceID: peer, Sessions: h.devices[peer].sessions})
        }
    }
}

func (h *Hub) Online(id, name string, c Conn) {
    h.mu.Lock()
    defer h.mu.Unlock()
    if old, ok := h.devices[id]; ok {
        old.conn.Close(4000, "replaced by a new connection")
        h.offlineLocked(id)
    }
    h.devices[id] = &device{id: id, name: name, conn: c, paired: map[string]bool{}}
}

func (h *Hub) Offline(id string) {
    h.mu.Lock()
    defer h.mu.Unlock()
    h.offlineLocked(id)
}

func (h *Hub) offlineLocked(id string) {
    d, ok := h.devices[id]
    if !ok {
        return
    }
    for sidStr, a := range h.attached {
        if a.host == id {
            for c := range a.clients {
                h.send(c, protocol.Envelope{T: "session_ended", From: id, To: c, SessionID: sidStr})
            }
            delete(h.attached, sidStr)
        } else {
            delete(a.clients, id)
        }
    }
    delete(h.devices, id)
    for peer, pd := range h.devices {
        if pd.paired[id] && d.paired[peer] {
            h.send(peer, protocol.Envelope{T: "catalogue", DeviceID: id})
        }
    }
    h.broadcastPresence(id)
}

func (h *Hub) Expire() {
    h.mu.Lock()
    defer h.mu.Unlock()
    h.pairings.expire(h.clock())
}

func (h *Hub) Stats() Stats {
    h.mu.Lock()
    defer h.mu.Unlock()
    return Stats{Online: len(h.devices), Pairings: len(h.pairings.byCode), Attachments: len(h.attached), DroppedBinary: h.dropped}
}

func (h *Hub) HandleText(from string, b []byte) {
    h.mu.Lock()
    defer h.mu.Unlock()
    d, ok := h.devices[from]
    if !ok {
        return
    }
    e, err := protocol.Decode(b)
    if err == nil {
        err = e.Validate()
    }
    if err != nil {
        h.send(from, protocol.Error("bad_message", err.Error()))
        return
    }
    e.From = from
    switch e.T {
    case "paired":
        d.paired = map[string]bool{}
        for _, id := range e.DeviceIDs {
            if id != from {
                d.paired[id] = true
            }
        }
        h.send(from, h.presenceFor(from))
        h.sendCatalogues(from)
        for peer := range d.paired {
            if h.mutual(from, peer) {
                h.send(peer, h.presenceFor(peer))
                h.send(peer, protocol.Envelope{T: "catalogue", DeviceID: from, Sessions: d.sessions})
            }
        }
    case "sessions":
        d.sessions = e.Sessions
        for peer := range d.paired {
            if h.mutual(from, peer) {
                h.send(peer, protocol.Envelope{T: "catalogue", DeviceID: from, Sessions: d.sessions})
            }
        }
    case "pair_open":
        if !h.pairings.open(e.Code, from, h.clock()) {
            h.send(from, protocol.Error("pair_taken", "that code is in use"))
        }
    case "pair_join":
        pr, ok := h.pairings.join(e.Code, from, h.clock())
        if !ok {
            h.send(from, protocol.Error("pair_expired", "no such code, or it expired"))
            return
        }
        h.send(pr.host, protocol.Envelope{T: "pair_request", From: from, Name: d.name})
    case "pair_accept", "pair_confirm":
        code, pr := h.pairings.between(from, e.To)
        if pr == nil {
            h.send(from, protocol.Error("pair_expired", "no open pairing with that device"))
            return
        }
        e.Name = d.name
        h.send(e.To, e)
        if e.T == "pair_confirm" {
            if from == pr.host {
                pr.hostOK = true
            } else {
                pr.clientOK = true
            }
            if pr.hostOK && pr.clientOK {
                delete(h.pairings.byCode, code)
            }
        }
    case "attach", "take_control", "detach", "attached", "snapshot_end", "role", "session_ended":
        if !h.mutual(from, e.To) {
            if _, online := h.devices[e.To]; !online && d.paired[e.To] {
                h.send(from, protocol.Error("host_offline", "that device is offline"))
            } else {
                h.send(from, protocol.Error("not_paired", "not paired with that device"))
            }
            return
        }
        switch e.T {
        case "attached":
            a := h.attached[e.SessionID]
            if a == nil {
                a = &attachment{host: from, clients: map[string]bool{}}
                h.attached[e.SessionID] = a
            }
            a.clients[e.To] = true
        case "detach":
            if a := h.attached[e.SessionID]; a != nil && a.host == e.To {
                delete(a.clients, from)
                if len(a.clients) == 0 {
                    delete(h.attached, e.SessionID)
                }
            }
        case "session_ended":
            if a := h.attached[e.SessionID]; a != nil && a.host == from {
                delete(a.clients, e.To)
                if len(a.clients) == 0 {
                    delete(h.attached, e.SessionID)
                }
            }
        }
        h.send(e.To, e)
    default:
        h.send(from, protocol.Error("bad_message", "unexpected "+e.T))
    }
}

func (h *Hub) HandleBinary(from string, b []byte) {
    h.mu.Lock()
    defer h.mu.Unlock()
    if len(b) < 24 {
        h.dropped++
        return
    }
    sidStr := base64.RawURLEncoding.EncodeToString(b[:16])
    a := h.attached[sidStr]
    if a == nil {
        h.dropped++
        return
    }
    if a.host == from {
        for c := range a.clients {
            if d, ok := h.devices[c]; ok {
                _ = d.conn.SendBinary(b)
            }
        }
        return
    }
    if a.clients[from] {
        if d, ok := h.devices[a.host]; ok {
            _ = d.conn.SendBinary(b)
        }
        return
    }
    h.dropped++
}
```

- [ ] **Step 4: Run the tests**

Run: `make vet && make test` → `ok .../relay`. If `TestPresenceIsMutualAndLive` fails on the offline presence, check `offlineLocked` calls `broadcastPresence` *after* deleting the device (it does) and that `presenceFor` reports an offline peer with `Online: false` (it does, since `h.devices[peer]` is gone).

- [ ] **Step 5: Commit**

```bash
git add relay/conn.go relay/hub.go relay/pairing.go relay/hub_test.go
git commit -m "The hub: who is online, who trusts whom, pairing by code, and routing by session"
```

---

### Task 3: WebSocket server, handshake, heartbeats, health

**Files:** Create `server/server.go`, `server/server_test.go`.

**Interfaces (produces):**

```go
package server
type Options struct { Token string; Hub *relay.Hub; Logger *slog.Logger; PingInterval, IdleTimeout, WriteTimeout time.Duration }
func New(o Options) http.Handler   // routes: GET /v1/ws (websocket), GET /healthz (200 "ok\n" + JSON stats)
```

Handshake in the handler: read `hello` (10 s deadline) → validate → constant-time token check (`bad_token`, close 4401) → send `challenge{nonce}` → read `auth` → verify `ed25519.Verify(pub, "nyx-relay-v1"||nonce||pub, sig)` (`bad_signature`, close 4403) → `welcome{server_time}` → `hub.Online` → read loop (text → `HandleText`, binary → `HandleBinary`) → on error/close `hub.Offline`. Pings every `PingInterval` (30 s); a read deadline of `IdleTimeout` (90 s) refreshed on every frame and pong. Writes use a `WriteTimeout` (5 s) and a per-connection mutex (`Conn` implementation `wsConn`).

- [ ] **Step 1: Write the failing end-to-end test**

```go
package server

import (
    "context"
    "crypto/ed25519"
    "crypto/rand"
    "encoding/base64"
    "encoding/json"
    "net/http/httptest"
    "strings"
    "testing"
    "time"

    "github.com/coder/websocket"
    "github.com/ngadiyak/nyx-server/protocol"
    "github.com/ngadiyak/nyx-server/relay"
)

type client struct {
    t    *testing.T
    c    *websocket.Conn
    id   string
    priv ed25519.PrivateKey
}

func dial(t *testing.T, url, name, token string) *client {
    pub, priv, _ := ed25519.GenerateKey(rand.Reader)
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    c, _, err := websocket.Dial(ctx, url, nil)
    if err != nil {
        t.Fatal(err)
    }
    cl := &client{t: t, c: c, id: base64.RawURLEncoding.EncodeToString(pub), priv: priv}
    cl.send(protocol.Envelope{T: "hello", DeviceID: cl.id, DeviceName: name, Token: token})
    return cl
}

func (cl *client) send(e protocol.Envelope) {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    if err := cl.c.Write(ctx, websocket.MessageText, e.Encode()); err != nil {
        cl.t.Fatal(err)
    }
}

func (cl *client) read() (websocket.MessageType, protocol.Envelope, []byte) {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    typ, b, err := cl.c.Read(ctx)
    if err != nil {
        return typ, protocol.Envelope{}, nil
    }
    var e protocol.Envelope
    if typ == websocket.MessageText {
        _ = json.Unmarshal(b, &e)
    }
    return typ, e, b
}

func (cl *client) expect(t string) protocol.Envelope {
    for i := 0; i < 20; i++ {
        typ, e, _ := cl.read()
        if typ == websocket.MessageText && e.T == t {
            return e
        }
        if e.T == "" {
            break
        }
    }
    cl.t.Fatalf("never received %s", t)
    return protocol.Envelope{}
}

func (cl *client) authenticate() {
    ch := cl.expect("challenge")
    nonce, _ := base64.RawURLEncoding.DecodeString(ch.Nonce)
    pub, _ := base64.RawURLEncoding.DecodeString(cl.id)
    msg := append(append([]byte("nyx-relay-v1"), nonce...), pub...)
    sig := ed25519.Sign(cl.priv, msg)
    cl.send(protocol.Envelope{T: "auth", Signature: base64.RawURLEncoding.EncodeToString(sig)})
    cl.expect("welcome")
}

func newServer(t *testing.T) (*httptest.Server, string) {
    h := relay.NewHub(time.Now)
    s := httptest.NewServer(New(Options{Token: "secret", Hub: h, PingInterval: time.Second, IdleTimeout: 5 * time.Second, WriteTimeout: time.Second}))
    t.Cleanup(s.Close)
    return s, "ws" + strings.TrimPrefix(s.URL, "http") + "/v1/ws"
}

func TestHandshakeRejectsBadToken(t *testing.T) {
    _, url := newServer(t)
    cl := dial(t, url, "mac", "wrong")
    typ, e, _ := cl.read()
    if typ != websocket.MessageText || e.T != "error" || e.Code != "bad_token" {
        t.Fatalf("expected bad_token, got %+v", e)
    }
    if _, e2, _ := cl.read(); e2.T != "" {
        t.Fatal("socket stayed open after bad token")
    }
}

func TestHandshakeRejectsBadSignature(t *testing.T) {
    _, url := newServer(t)
    cl := dial(t, url, "mac", "secret")
    cl.expect("challenge")
    cl.send(protocol.Envelope{T: "auth", Signature: base64.RawURLEncoding.EncodeToString(make([]byte, 64))})
    if _, e, _ := cl.read(); e.T != "error" || e.Code != "bad_signature" {
        t.Fatalf("expected bad_signature, got %+v", e)
    }
}

func TestTwoDevicesPairAttachAndExchangeFrames(t *testing.T) {
    _, url := newServer(t)
    host := dial(t, url, "host", "secret")
    host.authenticate()
    client := dial(t, url, "client", "secret")
    client.authenticate()

    host.send(protocol.Envelope{T: "pair_open", Code: "K7M4QZ"})
    client.send(protocol.Envelope{T: "pair_join", Code: "K7M4QZ"})
    req := host.expect("pair_request")
    if req.From != client.id {
        t.Fatal("wrong requester")
    }
    host.send(protocol.Envelope{T: "pair_accept", To: client.id})
    client.expect("pair_accept")
    host.send(protocol.Envelope{T: "pair_confirm", To: client.id})
    client.send(protocol.Envelope{T: "pair_confirm", To: host.id})
    host.expect("pair_confirm")
    client.expect("pair_confirm")

    host.send(protocol.Envelope{T: "paired", DeviceIDs: []string{client.id}})
    client.send(protocol.Envelope{T: "paired", DeviceIDs: []string{host.id}})
    p := client.expect("presence")
    if len(p.Devices) != 1 || !p.Devices[0].Online {
        t.Fatalf("client does not see the host online: %+v", p)
    }

    sid := base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef"))
    host.send(protocol.Envelope{T: "sessions", Sessions: []protocol.Session{{SessionID: sid, Title: "zsh", Cols: 80, Rows: 24}}})
    cat := client.expect("catalogue")
    if len(cat.Sessions) != 1 || cat.Sessions[0].Title != "zsh" {
        t.Fatalf("catalogue not delivered: %+v", cat)
    }

    sig := base64.RawURLEncoding.EncodeToString(make([]byte, 64))
    eph := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
    client.send(protocol.Envelope{T: "attach", To: host.id, SessionID: sid, EphemeralPubkey: eph, Sig: sig})
    host.expect("attach")
    host.send(protocol.Envelope{T: "attached", To: client.id, SessionID: sid, EphemeralPubkey: eph, Sig: sig, Role: "writer", Cols: 80, Rows: 24})
    client.expect("attached")

    frame := append(append([]byte("0123456789abcdef"), make([]byte, 8)...), []byte("ciphertext")...)
    ctx := context.Background()
    if err := host.c.Write(ctx, websocket.MessageBinary, frame); err != nil {
        t.Fatal(err)
    }
    typ, _, b := client.read()
    if typ != websocket.MessageBinary || string(b[24:]) != "ciphertext" {
        t.Fatalf("client did not get the frame: %v %q", typ, b)
    }
    if err := client.c.Write(ctx, websocket.MessageBinary, frame); err != nil {
        t.Fatal(err)
    }
    typ, _, b = host.read()
    if typ != websocket.MessageBinary || string(b[24:]) != "ciphertext" {
        t.Fatalf("host did not get the frame: %v %q", typ, b)
    }

    host.c.Close(websocket.StatusNormalClosure, "bye")
    if e := client.expect("session_ended"); e.SessionID != sid {
        t.Fatalf("client not told the session ended: %+v", e)
    }
}

func TestHealthz(t *testing.T) {
    s, _ := newServer(t)
    resp, err := s.Client().Get(s.URL + "/healthz")
    if err != nil || resp.StatusCode != 200 {
        t.Fatalf("healthz: %v %v", err, resp)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test` → compile errors in `server`.

- [ ] **Step 3: Implement the server**

```go
package server

import (
    "context"
    "crypto/ed25519"
    "crypto/rand"
    "crypto/subtle"
    "encoding/base64"
    "encoding/json"
    "log/slog"
    "net/http"
    "sync"
    "time"

    "github.com/coder/websocket"
    "github.com/ngadiyak/nyx-server/protocol"
    "github.com/ngadiyak/nyx-server/relay"
)

type Options struct {
    Token        string
    Hub          *relay.Hub
    Logger       *slog.Logger
    PingInterval time.Duration
    IdleTimeout  time.Duration
    WriteTimeout time.Duration
}

type server struct {
    o Options
}

func New(o Options) http.Handler {
    if o.Logger == nil {
        o.Logger = slog.Default()
    }
    if o.PingInterval == 0 {
        o.PingInterval = 30 * time.Second
    }
    if o.IdleTimeout == 0 {
        o.IdleTimeout = 90 * time.Second
    }
    if o.WriteTimeout == 0 {
        o.WriteTimeout = 5 * time.Second
    }
    s := &server{o: o}
    mux := http.NewServeMux()
    mux.HandleFunc("GET /healthz", s.healthz)
    mux.HandleFunc("GET /v1/ws", s.ws)
    return mux
}

func (s *server) healthz(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    _ = json.NewEncoder(w).Encode(s.o.Hub.Stats())
}

// wsConn is relay.Conn over a websocket: one writer at a time, every write with a deadline, so a
// stalled peer fails its own write instead of holding the hub.
type wsConn struct {
    c       *websocket.Conn
    mu      sync.Mutex
    timeout time.Duration
}

func (w *wsConn) write(typ websocket.MessageType, b []byte) error {
    w.mu.Lock()
    defer w.mu.Unlock()
    ctx, cancel := context.WithTimeout(context.Background(), w.timeout)
    defer cancel()
    return w.c.Write(ctx, typ, b)
}

func (w *wsConn) SendText(b []byte) error   { return w.write(websocket.MessageText, b) }
func (w *wsConn) SendBinary(b []byte) error { return w.write(websocket.MessageBinary, b) }
func (w *wsConn) Close(code int, reason string) {
    _ = w.c.Close(websocket.StatusCode(code), reason)
}

func short(id string) string {
    if len(id) > 8 {
        return id[:8]
    }
    return id
}

func (s *server) ws(w http.ResponseWriter, r *http.Request) {
    c, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
    if err != nil {
        return
    }
    c.SetReadLimit(4 << 20)
    conn := &wsConn{c: c, timeout: s.o.WriteTimeout}
    log := s.o.Logger

    readText := func(timeout time.Duration) (protocol.Envelope, bool) {
        ctx, cancel := context.WithTimeout(context.Background(), timeout)
        defer cancel()
        typ, b, err := c.Read(ctx)
        if err != nil || typ != websocket.MessageText {
            return protocol.Envelope{}, false
        }
        e, err := protocol.Decode(b)
        if err != nil || e.Validate() != nil {
            return protocol.Envelope{}, false
        }
        return e, true
    }

    hello, ok := readText(10 * time.Second)
    if !ok || hello.T != "hello" {
        conn.Close(4400, "expected hello")
        return
    }
    if subtle.ConstantTimeCompare([]byte(hello.Token), []byte(s.o.Token)) != 1 {
        _ = conn.SendText(protocol.Error("bad_token", "relay token rejected").Encode())
        conn.Close(4401, "bad token")
        log.Info("auth failed", "reason", "token", "device", short(hello.DeviceID))
        return
    }
    nonce := make([]byte, 32)
    _, _ = rand.Read(nonce)
    _ = conn.SendText(protocol.Envelope{T: "challenge", Nonce: base64.RawURLEncoding.EncodeToString(nonce)}.Encode())
    auth, ok := readText(10 * time.Second)
    if !ok || auth.T != "auth" {
        conn.Close(4400, "expected auth")
        return
    }
    pub, _ := base64.RawURLEncoding.DecodeString(hello.DeviceID)
    sig, _ := base64.RawURLEncoding.DecodeString(auth.Signature)
    msg := append(append([]byte("nyx-relay-v1"), nonce...), pub...)
    if !ed25519.Verify(ed25519.PublicKey(pub), msg, sig) {
        _ = conn.SendText(protocol.Error("bad_signature", "signature did not verify").Encode())
        conn.Close(4403, "bad signature")
        log.Info("auth failed", "reason", "signature", "device", short(hello.DeviceID))
        return
    }
    _ = conn.SendText(protocol.Envelope{T: "welcome", ServerTime: time.Now().UTC().Format(time.RFC3339)}.Encode())
    s.o.Hub.Online(hello.DeviceID, hello.DeviceName, conn)
    log.Info("online", "device", short(hello.DeviceID), "name", hello.DeviceName)
    defer func() {
        s.o.Hub.Offline(hello.DeviceID)
        log.Info("offline", "device", short(hello.DeviceID))
    }()

    ctx, cancel := context.WithCancel(r.Context())
    defer cancel()
    go func() {
        t := time.NewTicker(s.o.PingInterval)
        defer t.Stop()
        for {
            select {
            case <-ctx.Done():
                return
            case <-t.C:
                pctx, pcancel := context.WithTimeout(ctx, s.o.WriteTimeout)
                err := c.Ping(pctx)
                pcancel()
                if err != nil {
                    cancel()
                    return
                }
            }
        }
    }()

    for {
        rctx, rcancel := context.WithTimeout(ctx, s.o.IdleTimeout)
        typ, b, err := c.Read(rctx)
        rcancel()
        if err != nil {
            return
        }
        switch typ {
        case websocket.MessageText:
            s.o.Hub.HandleText(hello.DeviceID, b)
        case websocket.MessageBinary:
            s.o.Hub.HandleBinary(hello.DeviceID, b)
        }
    }
}
```

Note: `coder/websocket`'s `Read` answers pings automatically and a successful `Ping` round-trip proves liveness; the read deadline of `IdleTimeout` is what drops a silent peer.

- [ ] **Step 4: Run the tests**

Run: `make vet && make test` → all three packages `ok`. If `expect` in the pairing test times out waiting for `presence`, remember the hub sends `presence` on every `paired` declaration — the client's `expect("presence")` may first receive the presence sent when the *host* declared (with the client offline in the host's view: not delivered to the client at all since mutual pairing needs both) — the loop in `expect` skips unrelated messages, so the assertion should hold; if it does not, print the sequence received and adjust the hub, not the test's intent.

- [ ] **Step 5: Commit**

```bash
git add server/server.go server/server_test.go
git commit -m "The WebSocket server: token, challenge, signature, heartbeats and health"
```

---

### Task 4: The binary

**Files:** Create `cmd/nyx-relay/main.go`.

- [ ] **Step 1: Implement**

```go
package main

import (
    "context"
    "errors"
    "flag"
    "log/slog"
    "net/http"
    "os"
    "os/signal"
    "strings"
    "syscall"
    "time"

    "github.com/ngadiyak/nyx-server/relay"
    "github.com/ngadiyak/nyx-server/server"
)

func main() {
    listen := flag.String("listen", ":8787", "address to listen on")
    token := flag.String("token", "", "relay token (or set -token-file)")
    tokenFile := flag.String("token-file", "", "file holding the relay token")
    flag.Parse()

    log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    if *token == "" && *tokenFile != "" {
        b, err := os.ReadFile(*tokenFile)
        if err != nil {
            log.Error("cannot read token file", "err", err)
            os.Exit(2)
        }
        *token = strings.TrimSpace(string(b))
    }
    if *token == "" {
        log.Error("a relay token is required (-token or -token-file)")
        os.Exit(2)
    }

    hub := relay.NewHub(time.Now)
    go func() {
        for range time.Tick(time.Minute) {
            hub.Expire()
        }
    }()
    srv := &http.Server{Addr: *listen, Handler: server.New(server.Options{Token: *token, Hub: hub, Logger: log}), ReadHeaderTimeout: 10 * time.Second}

    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer stop()
    go func() {
        <-ctx.Done()
        shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        _ = srv.Shutdown(shutdown)
    }()
    log.Info("nyx-relay listening", "addr", *listen)
    if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
        log.Error("server failed", "err", err)
        os.Exit(1)
    }
}
```

- [ ] **Step 2: Build and smoke locally**

```bash
make build && (./bin/nyx-relay -listen 127.0.0.1:8787 -token dev &) && sleep 1 && curl -s http://127.0.0.1:8787/healthz; pkill -f 'bin/nyx-relay'
```
Expected: `{"Online":0,"Pairings":0,"Attachments":0,"DroppedBinary":0}`.

- [ ] **Step 3: Commit**

```bash
git add cmd/nyx-relay/main.go
git commit -m "nyx-relay: flags, JSON logs, graceful shutdown"
```

---

### Task 5: Deployment behind Caddy

**Files:** Create `Dockerfile`, `compose.yml`, `caddy/nyx.caddy`, `deploy.sh`; extend `README.md`.

- [ ] **Step 1: Write the files**

`Dockerfile`:

```dockerfile
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /nyx-relay ./cmd/nyx-relay

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /nyx-relay /nyx-relay
USER nonroot
EXPOSE 8787
ENTRYPOINT ["/nyx-relay", "-listen", ":8787", "-token-file", "/run/secrets/relay_token"]
```

(If the `golang` image version in the base is newer than what `go.mod` says, keep `go 1.22` in `go.mod` so the build works; do not pin the toolchain higher than the image.)

`compose.yml`:

```yaml
services:
  nyx-relay:
    build: .
    image: nyx-relay:local
    container_name: nyx-relay
    restart: unless-stopped
    networks: [remnawave-network]
    secrets: [relay_token]
    healthcheck:
      test: ["CMD", "/nyx-relay", "-h"]
      interval: 60s
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

secrets:
  relay_token:
    file: ./token

networks:
  remnawave-network:
    external: true
```

(The distroless image has no shell or curl; the healthcheck above only proves the binary starts. Caddy's reverse proxy and `/healthz` from outside are the real check.)

`caddy/nyx.caddy`:

```
nyx.agentforge.cc {
	encode zstd gzip
	reverse_proxy nyx-relay:8787
}
```

`deploy.sh`:

```bash
#!/usr/bin/env bash
# Deploys nyx-relay to the relay host: syncs this repo, builds the image there, starts it on the
# existing Caddy network, and wires the Caddy site once. Run from the dev machine.
set -euo pipefail
HOST=${HOST:-root@89.124.111.196}
DIR=/opt/nyx-server
CADDYFILE=/opt/remnawave/caddy/Caddyfile

cd "$(dirname "$0")"
if [ ! -f token ]; then
  openssl rand -base64 32 | tr -d '\n' > token
  echo "generated a new relay token in ./token — paste it into Nyx on every device:"
  cat token; echo
fi

rsync -az --delete --exclude .git --exclude bin "$PWD/" "$HOST:$DIR/"
ssh "$HOST" bash -s <<EOF
set -euo pipefail
cd $DIR
chmod 600 token
docker compose build --quiet
docker compose up -d
if ! grep -q "import $DIR/caddy/nyx.caddy" $CADDYFILE; then
  printf '\n# Nyx relay (nyx-server)\nimport %s/caddy/nyx.caddy\n' "$DIR" >> $CADDYFILE
fi
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
EOF
sleep 3
curl -fsS https://nyx.agentforge.cc/healthz && echo " — relay is up"
```

`README.md` gains an "Operations" section: deploy (`./deploy.sh`), logs (`ssh root@89.124.111.196 docker logs -f nyx-relay`), token rotation (edit `token`, `./deploy.sh`, update every device), restart (`docker compose -f /opt/nyx-server/compose.yml restart`), what the relay can see (device ids, names, session metadata, frame sizes) and cannot (terminal contents).

- [ ] **Step 2: Deploy and verify**

Run `./deploy.sh` (it prints the generated token; keep it — Nyx needs it). Expected last line: `{"Online":0,...} — relay is up`. Then on the server: `docker logs nyx-relay | tail -3` shows `nyx-relay listening`. Check nothing else changed: `docker ps` shows the same containers plus `nyx-relay`; `ss -ltn` on the host shows no new listening port.

If Caddy's `import` of a path outside its mounted volumes fails (the Caddyfile is mounted from `/opt/remnawave/caddy/`, and `/opt/nyx-server` is not in the container), copy `caddy/nyx.caddy` to `/opt/remnawave/caddy/nyx.caddy` in `deploy.sh` and import that path instead; the rule "one import line in the existing Caddyfile" stands.

- [ ] **Step 3: Commit (never the token)**

```bash
git add Dockerfile compose.yml caddy/nyx.caddy deploy.sh README.md
git commit -m "Deploy nyx-relay behind the existing Caddy on nyx.agentforge.cc"
git push -u origin main
```

`token` is git-ignored; confirm with `git status` before pushing.

---

## Self-review against the spec

- §6.1 hello/challenge/auth/welcome, 30 s ping / 90 s idle, constant-time token → Task 3. ✔
- §6.2 presence and catalogue only between mutually paired devices, on connect and on change → Task 2 (`paired`, `sessions`, `Online`, `Offline`). ✔
- §6.3 pairing by code, 5-minute TTL, one code per host, `pair_taken`, forwarding of accept/confirm, code deleted after both confirm → Task 2. ✔
- §6.4 attach/attached/snapshot_end/take_control/role/detach/session_ended forwarded; binary frames routed by session id; relay never decrypts → Tasks 2, 3. ✔
- §6.5 memory only → Task 2. ✔
- §8 packages, tests with fake connections, httptest end-to-end, Dockerfile, compose on `remnawave-network`, Caddy block, deploy script, README ops, structured logs without payloads, `/healthz` → Tasks 3–5. ✔

Type consistency: `protocol.Envelope` fields used in `relay` and `server` match Task 1's struct (`Code`, `Message`, `DeviceIDs`, `Sessions`, `EphemeralPubkey`, `Sig`, `Role`, `Cols`, `Rows`, `ServerTime`, `Nonce`, `Signature`, `Name`, `From`, `To`, `SessionID`, `DeviceID`, `DeviceName`, `Token`). `relay.Conn` is implemented by `server.wsConn` with the three methods. `Hub` methods used by the server are exactly `Online`, `Offline`, `HandleText`, `HandleBinary`, `Expire`, `Stats`.
