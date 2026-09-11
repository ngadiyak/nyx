# UX Round — Plan 6: Remote Sessions That Survive Being Used

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A remote session stops dying every ninety-one seconds and stops lying: the Go relay keeps a quiet-but-alive socket open and says "not paired" when a peer has unpaired, a reconnect *resumes* an attachment (no second snapshot, no writer/observer flap, no audit line), attaching while the host is in vim keeps the client's whole block history, every Settings field commits what was pasted into it, and the strip, the pairing sheet and the Remote page say what they mean where they are read.

**Architecture:** Three layers, each fixed where the decision belongs. **The relay** (`~/projects/nyx-server`, Go) learns liveness from pongs rather than from a read deadline, marks a peer whose pairing has gone non-mutual, and forwards the host's screen size on `role`. **NyxCore** gains the pure values the new behaviour is decided by: a buffer-aware `transcript`, `RemoteSnapshot.compose`/`.reset`, a `RemoteCatalogue` that keeps the name it was given, an `AttachState` whose geometry note has a threshold and a short form, `RemoteAnnouncement`, `RemotePageStatus` and a `ConfigParser` that re-applies a deleted key's default. **NyxRemote** holds an attachment through a socket drop for `reattachWindow` and answers a re-attach with `attached` + `snapshot_end` and nothing in between. **NyxApp** only draws: an appearance-pinned strip button with an `attributedTitle`, a spinner on the pairing sheet, two sentences and relative dates on the Remote page, and text fields that commit on end-editing.

**Tech Stack:** Swift 6.0.3 in Swift 5 mode, SwiftPM, swift-testing, AppKit (unchanged); Go 1.22 + `github.com/coder/websocket` v1.8.13 for the relay (`/opt/homebrew/bin/go`). No new dependencies on either side.

**Spec:** `docs/superpowers/specs/2026-09-07-ux-round-design.md` — §7 is this plan, including its **Addendum (2026-09-10, from the end-to-end QA)**, which is binding; §8.1 (the strip is an Announce site), §8.4 (`hitRowHeight`), §8.5's plan-6 pictures and §10's "Wave 6" paragraph are its edges. Wave-4 items **1** and **3** (§5.1, §5.3) are pulled forward into it by the controller's ruling. The reasoning is `.superpowers/sdd/2026-09-07-ux-round/qa-remote.md` (4 BROKEN, 16 DEGRADED) and, for the wire, `docs/superpowers/plans/2026-09-05-remote-sessions-server.md` (the protocol's authoritative table) and `docs/superpowers/specs/2026-09-05-remote-sessions-design.md` §12 (deliberately open — this plan closes five of its bullets).

**Assumes plans 1a and 1b have landed** (`main` @ `4950075`): `CommandBlockChrome.hitRowHeight(cellHeight:)`, `PromptGutter.hitWidth`, `Announce.say(_:)` in `NyxApp`, and the sticky strip's `stickyStripRow` yielding to the remote strip all exist. Nothing in this plan changes the first three. **`Pane.stickyStripRow` (`Pane.swift:4018`) is the one exception**: Task 7 Step 5 replaces it, because at `line-height 0.8` two `hitRowHeight` bands one 13 pt row apart would overlap, so the pinned band has to step down by whole rows rather than by one. `GridSnapshot`'s own slot arithmetic (`GridSnapshot.swift:1304-1309`) is untouched — it hardcodes slot 0 and documents that no composite carries a remote strip.

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY; `NyxRemote` may import CryptoKit; nothing new reaches `NyxRender` — **this plan does not touch the render path at all**, so `make bench` ≥ 180 MB/s is a guarantee, not a hope.
- Decision logic in Core, behind a pure interface, unit-tested (`CLAUDE.md`). The AppKit layer converts and draws. A rule left in a view handler cannot be verified in this environment.
- Tests are swift-testing (`import Testing`, `@Test`, `#expect`); **hoist mutating calls out of `#expect`/`#require`**. Hang fix: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`.
- Warning-free build, library and tests. Go: `gofmt`-clean, `go vet`-clean, `go test ./...` green, no test using a real port other than `httptest`.
- **The wire is a contract with a second repository.** Every field added here is added in `~/projects/nyx-server/protocol/message.go`, copied in `relay/hub.go`'s `forward`, mirrored in `Sources/NyxCore/Remote/RemoteMessage.swift`, and written into the wire table of `docs/superpowers/plans/2026-09-05-remote-sessions-server.md`. A field in three of those four places is a field that works until the relay is redeployed.
- **The relay is fixed, tested locally, and then deployed — in Task 1, without asking again.** The owner pre-approved the deploy on 2026-09-10 ("добро на деплой даю сразу"): once `go test ./...`, `go vet` and `gofmt` are clean and the two-instance local run is quiet, Task 1 Step 10 runs `cd ~/projects/nyx-server && ./deploy.sh`, confirms `curl -fsS https://nyx.agentforge.cc/healthz`, and pairs nyx-a with nyx-b afresh against the deployed relay. All three go in the task report. **This does not make the client tasks assume the new relay.** They still degrade rather than break against an old one — an absent `not_paired` reads as `false`, an absent `cols`/`rows` on a `role` leaves the mirror as it was — because the two Macs update on their own schedules and a client that needs a relay field to work at all is a client that breaks on the day the container is restarted.
- Never print the relay token. It lives in `~/projects/nyx-server/token` and in the two test configs; it is passed as `"$(cat …/token)"` and never echoed, never pasted into a log, never committed. The QA scrubbed one log that captured it; do not create another.
- Terminal phases are `.ended`, `.failed` and `.suspended`; the live ones are `.attaching`, `.snapshot`, `.live`, `.reconnecting`. The words "resume", "suspend" and "expire" in this plan always mean the *host's* view of an attachment (Task 3), never `AttachState.Phase.suspended`, which is the *client's* view of a host that has gone.
- **No VoiceOver verification is asked of the owner** (owner ruling 2026-09-10): a11y work is specified, implemented and tested in Core, and nothing in this plan waits on a VoiceOver run. §10's VoiceOver gate is waived for the round.
- **No Intel build.** §7.5 (the universal binary) was struck by the owner on 2026-09-10 and is not in this plan.
- Commit trailer on every commit, the only one:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`
  `git add` by name. Never touch `CLAUDE.md`, `.claude/`, `docs/testing.md`, `docs/workflow.md`, `docs/status.md`, `README.md`. Commits in `~/projects/nyx-server` carry the same trailer.

---

### Task 1: The relay — a quiet socket lives, an unpaired peer is named, and `role` carries the size

**Repository: `~/projects/nyx-server` (Go). No file in the Nyx repository changes except the wire table.**

**Files:**
- Modify: `~/projects/nyx-server/server/server.go` — liveness from pongs and data, not from the read deadline (`:326-332`, `:235-245`)
- Modify: `~/projects/nyx-server/server/server_test.go` — two new tests and a `dialWith` helper
- Modify: `~/projects/nyx-server/protocol/message.go` — `Presence.NotPaired`
- Modify: `~/projects/nyx-server/relay/hub.go` — `device.unpairedBy`, `presenceFor`, the `paired` handler, `forward` for `role`
- Modify: `~/projects/nyx-server/relay/hub_test.go` — three new tests
- Modify: `~/projects/nyx-server/README.md` — the liveness paragraph
- Modify: `docs/superpowers/plans/2026-09-05-remote-sessions-server.md` (Nyx repo) — the wire table's `presence` and `role` rows, and the presence rules paragraph

**Interfaces:**
- Consumes: nothing. This is the first task.
- Produces (the wire, which Tasks 3 and 4 mirror):

```go
// protocol
type Presence struct {
    DeviceID  string `json:"device_id"`
    Name      string `json:"name"`
    Online     bool  `json:"online"`
    NotPaired bool   `json:"not_paired,omitempty"` // the peer is connected and no longer declares us
}
// role, forwarded: {t:"role", from, to, session_id, device_id, role, cols, rows}
//   cols/rows are the host's current screen and may be absent (a host that has not resized).
```

- [ ] **Step 1: Write the two failing server tests.** In `server/server_test.go`, replace `dial` with a pair (the body is today's, plus the options):

```go
func dialWith(t *testing.T, url, name, token string, opts *websocket.DialOptions) *client {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, url, opts)
	if err != nil {
		t.Fatal(err)
	}
	cl := &client{t: t, c: c, id: base64.RawURLEncoding.EncodeToString(pub), priv: priv}
	cl.send(protocol.Envelope{T: "hello", DeviceID: cl.id, DeviceName: name, Token: token})
	return cl
}

func dial(t *testing.T, url, name, token string) *client { return dialWith(t, url, name, token, nil) }
```

  and append:

```go
// The bug this whole task exists for. `coder/websocket`'s Read returns on a *data* message only:
// it services ping and pong frames internally and carries on waiting, so a read deadline measures
// "how long since the peer last said something", which on an idle terminal session is for ever.
// The 90 s IdleTimeout therefore closed healthy sockets every ninety-one seconds, and the Nyx
// client had been written around that as if it were the contract -- costing it a duplicated
// snapshot, a writer/observer flap and ~85 KB of re-encrypted traffic per client per cycle.
func TestAQuietSocketStaysOpenWhileItsPeerIsAnswering(t *testing.T) {
	hub := relay.NewHub(time.Now)
	s := httptest.NewServer(New(Options{Token: "secret", Hub: hub,
		PingInterval: 100 * time.Millisecond, IdleTimeout: 500 * time.Millisecond,
		WriteTimeout: time.Second}))
	t.Cleanup(s.Close)
	url := "ws" + strings.TrimPrefix(s.URL, "http") + "/v1/ws"
	cl := dial(t, url, "mac", "secret")
	cl.authenticate()

	// A real client is always reading, which is what lets its library answer the relay's pings.
	// Nothing else is sent for four idle timeouts.
	closed := make(chan error, 1)
	go func() { closed <- cl.readUntilClosed() }()
	select {
	case err := <-closed:
		t.Fatalf("an idle but answering socket was closed: %v", err)
	case <-time.After(2 * time.Second):
	}
	if got := hub.Stats().Online; got != 1 {
		t.Fatalf("online = %d, want 1", got)
	}
}

// And the other half: liveness must still be a real check. A peer that reads but never answers a
// ping is wedged, and holding its socket open for ever would leak a device slot and keep its
// attachments alive on every host that thinks it is watching.
func TestAPeerThatNeverAnswersAPingIsClosed(t *testing.T) {
	hub := relay.NewHub(time.Now)
	s := httptest.NewServer(New(Options{Token: "secret", Hub: hub,
		PingInterval: 100 * time.Millisecond, IdleTimeout: 400 * time.Millisecond,
		WriteTimeout: time.Second}))
	t.Cleanup(s.Close)
	url := "ws" + strings.TrimPrefix(s.URL, "http") + "/v1/ws"
	// Returning false from OnPingReceived suppresses the pong, which is exactly what a wedged peer
	// looks like from the relay: the TCP connection is fine and nobody is home.
	cl := dialWith(t, url, "mac", "secret", &websocket.DialOptions{
		OnPingReceived: func(context.Context, []byte) bool { return false },
	})
	cl.authenticate()
	closed := make(chan error, 1)
	go func() { closed <- cl.readUntilClosed() }()
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("a peer that never answered a ping was left connected")
	}
}
```

- [ ] **Step 2: Run them and watch the first one fail**

Run: `cd ~/projects/nyx-server && PATH=/opt/homebrew/bin:$PATH go test ./server/ -run 'Quiet|NeverAnswers' -v 2>&1 | tail -20`
Expected: `TestAQuietSocketStaysOpenWhileItsPeerIsAnswering` FAILS ("an idle but answering socket was closed") at about 500 ms; the second test passes already (today's read deadline closes it, for the wrong reason).

- [ ] **Step 3: Liveness from pongs.** In `server/server.go`, add `"sync/atomic"` to the imports and, above `wsConn`:

```go
// liveness is the last moment the peer proved it was there: a pong, or any data frame. A field of
// its own rather than a deadline on the read, because Read never returns for a pong (see
// TestAQuietSocketStaysOpenWhileItsPeerIsAnswering) -- so the read deadline measured silence, not
// death, and killed every idle session on the relay every IdleTimeout.
type liveness struct{ at atomic.Int64 }

func (l *liveness) mark(now time.Time) { l.at.Store(now.UnixNano()) }

func (l *liveness) idleFor(now time.Time) time.Duration {
	return now.Sub(time.Unix(0, l.at.Load()))
}
```

  In `ws()`, take the pong as it arrives and start the clock at the upgrade:

```go
	alive := &liveness{}
	alive.mark(time.Now())
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
		// The pong is the proof, and this callback is the only place it is visible: the read loop
		// handles the frame and carries on waiting, so nothing else in this handler sees it. It is
		// independent of whether `Ping`'s own five-second wait happened to still be running, which
		// is why a busy moment no longer looks like a dead peer.
		OnPongReceived: func(context.Context, []byte) { alive.mark(time.Now()) },
	})
	if err != nil {
		return
	}
```

  and replace the read loop (`:326-339`) with:

```go
	// The liveness check the read deadline used to be, on a timer of its own: a socket with nothing
	// to say stays open, and a peer that has stopped answering pings is closed within IdleTimeout
	// plus one tick. `kill` rather than `Close`: a peer that will not answer a ping will not
	// complete a close handshake either, and the frame would queue behind whatever it is not
	// draining.
	go func() {
		t := time.NewTicker(s.o.IdleTimeout / 3)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-conn.closing:
				return
			case <-t.C:
				if alive.idleFor(time.Now()) > s.o.IdleTimeout {
					log.Info("idle", "device", short(hello.DeviceID))
					conn.kill()
					return
				}
			}
		}
	}()

	for {
		typ, b, err := c.Read(ctx)
		if err != nil {
			return
		}
		// Data proves liveness as well as a pong does, and on a busy session it is what arrives
		// first.
		alive.mark(time.Now())
		switch typ {
		case websocket.MessageText:
			s.o.Hub.HandleText(hello.DeviceID, b)
		case websocket.MessageBinary:
			s.o.Hub.HandleBinary(hello.DeviceID, b)
		}
	}
```

  Also correct the comment in `writeLoop`'s `f.ping` branch, which now names the right liveness check:

```go
			case f.ping:
				ctx, cancel := context.WithTimeout(context.Background(), w.timeout)
				err := w.c.Ping(ctx)
				cancel()
				// A missed ping is not proof the peer is gone: Ping needs the read loop to notice
				// the pong, so one busy moment can miss it. The liveness watchdog in `ws` is the
				// check -- it reads the last pong the connection actually received, from
				// OnPongReceived, and only closes when *that* is stale.
				_ = err
```

- [ ] **Step 4: Run the server tests**

Run: `cd ~/projects/nyx-server && PATH=/opt/homebrew/bin:$PATH go test ./server/ 2>&1 | tail -5`
Expected: `ok`. Both new tests pass, and so do `TestShutdownClosesLiveSockets` and `TestASlowConsumerDoesNotStallEveryoneElse`, which the change must not have disturbed.

- [ ] **Step 5: Write the three failing hub tests.** Append to `relay/hub_test.go`:

```go
// The client half of the "beta has been offline since 21:17 — waiting for it to come back"
// complaint: the sentence was false, and the one screen a person has no other way to check said
// it. Once beta stops declaring alpha, `presenceFor` reported beta as offline with no name --
// which is the same message a sleeping Mac produces -- and nothing on the wire could say
// otherwise, so the relay must say it.
func TestARemovedPeerIsToldItIsNoLongerPaired(t *testing.T) {
	h, a, b := pairedHub()
	_ = a
	// beta re-declares an empty list: Settings -> Remote -> select alpha -> Remove.
	h.HandleText(id(2), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{}}))
	p := a.find("presence")
	if p == nil || len(p.Devices) != 1 || p.Devices[0].DeviceID != id(2) {
		t.Fatalf("alpha was never told: %+v", p)
	}
	if !p.Devices[0].NotPaired {
		t.Fatalf("alpha was told offline, not unpaired: %+v", p.Devices[0])
	}
	if p.Devices[0].Online {
		t.Fatalf("an unpaired peer must not read as reachable: %+v", p.Devices[0])
	}
	// And a re-pairing clears it, or the row would stay dead through the next pairing.
	h.HandleText(id(2), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(1)}}))
	h.HandleText(id(1), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(2)}}))
	p = a.find("presence")
	if p == nil || p.Devices[0].NotPaired || !p.Devices[0].Online {
		t.Fatalf("a re-paired peer is still marked unpaired: %+v", p)
	}

	// Now the case that is probably the *common* one: you unpair from the Mac in front of you, and
	// the other one is asleep. `offlineLocked` has already deleted beta from h.devices, so the flag
	// has nowhere to live but beta's tombstone -- and if it does not live there, beta wakes up and
	// is told alpha is "offline with no name", which is B2's sentence with the fix in place.
	h.Offline(id(2), b)
	h.HandleText(id(1), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{}}))
	woken := &fake{}
	h.Online(id(2), "beta", woken)
	h.HandleText(id(2), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(1)}}))
	back := woken.find("presence")
	if back == nil || len(back.Devices) != 1 || back.Devices[0].DeviceID != id(1) {
		t.Fatalf("a woken Mac got no presence at all: %+v", back)
	}
	if !back.Devices[0].NotPaired {
		t.Fatalf("a Mac unpaired while it slept woke to \"offline\", not \"unpaired\": %+v", back.Devices[0])
	}
}

// `not_paired` is an *event* about a pairing that existed, never an answer derived from the two
// lists: derived, it would tell anyone who declared a guessed device id whether that id is
// connected right now -- the leak `provablyMutual` and the tombstone exist to avoid.
func TestADeviceThatWasNeverPairedLearnsNothingAboutAnother(t *testing.T) {
	h, _ := newHub()
	stranger, beta := &fake{}, &fake{}
	h.Online(id(3), "stranger", stranger)
	h.Online(id(2), "beta", beta)
	// beta never declares the stranger.
	h.HandleText(id(2), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(1)}}))
	h.HandleText(id(3), msg(protocol.Envelope{T: "paired", DeviceIDs: []string{id(2)}}))
	p := stranger.find("presence")
	if p == nil || len(p.Devices) != 1 {
		t.Fatalf("the stranger got no snapshot at all: %+v", p)
	}
	if p.Devices[0].NotPaired || p.Devices[0].Online || p.Devices[0].Name != "" {
		t.Fatalf("a guessed id was answered with something: %+v", p.Devices[0])
	}
}

// The host's window size arrives once, in `attached`, and never again -- so a host resized while a
// client watched went on sending output laid out for its new width into a mirror still shaped like
// the old one, and every line wrapped. `role` is already sent per attached client and already
// forwarded per session, so it is what carries the new size.
func TestAForwardedRoleCarriesTheHostsSize(t *testing.T) {
	h, host, client := pairedHub()
	h.HandleText(id(1), msg(protocol.Envelope{T: "sessions",
		Sessions: []protocol.Session{{SessionID: sid(7), Title: "zsh", Cols: 80, Rows: 24}}}))
	h.HandleText(id(1), msg(protocol.Envelope{T: "role", To: id(2), SessionID: sid(7),
		DeviceID: id(2), Role: "writer", Cols: 98, Rows: 32}))
	r := client.find("role")
	if r == nil {
		t.Fatal("the role was not forwarded")
	}
	if r.Cols != 98 || r.Rows != 32 {
		t.Fatalf("the size was stripped: %+v", r)
	}
	_ = host
}
```

- [ ] **Step 6: Run them and watch them fail**

Run: `cd ~/projects/nyx-server && PATH=/opt/homebrew/bin:$PATH go test ./relay/ -run 'RemovedPeer|NeverPaired|ForwardedRole' 2>&1 | tail -20`
Expected: **a compile failure first** — `protocol.Presence` has no `NotPaired` until Step 7, so the `relay` package does not build and no test runs. Add the field alone (Step 7's first block) and run again: the first test fails (`alpha was never told` — nothing is sent to a peer that is no longer mutual) and the third fails (`the size was stripped`); the second passes and must keep passing.

- [ ] **Step 7: The field, the flag and the forward.** `protocol/message.go`:

```go
// Presence is one entry in a `presence` message: a paired device, whether it is online now, and
// whether the pairing is still mutual.
type Presence struct {
	DeviceID string `json:"device_id"`
	Name     string `json:"name"`
	Online   bool   `json:"online"`
	// The peer is connected and no longer declares this device: it removed the pairing. Reported
	// as itself rather than as "offline", which is a wait that never ends -- and a sentence the
	// user can check and find false, on the one screen they have no other way to check.
	NotPaired bool `json:"not_paired,omitempty"`
}
```

  `relay/hub.go` — the field on `device` and the tombstone that outlives a restart:

```go
type device struct {
	id, name string
	conn     Conn
	paired   map[string]bool // devices this one declared
	// Peers that had declared this device and have since stopped. Recorded when the other side
	// re-declares without us -- an event, not a state derived from the two lists, because derived
	// it would answer "is this id online?" for any id a caller cared to name.
	unpairedBy map[string]bool
	sessions   []protocol.Session
}

type tombstone struct {
	paired     map[string]bool
	unpairedBy map[string]bool
	at         time.Time
}
```

  `Online` starts the map and restores a fresh tombstone's copy, so a Mac that was unpaired while it was asleep is still told when it comes back:

```go
func (h *Hub) Online(id, name string, c Conn) Conn {
	h.mu.Lock()
	defer h.mu.Unlock()
	if d, ok := h.devices[id]; ok {
		old := d.conn
		d.conn, d.name = c, name
		return old
	}
	unpaired := map[string]bool{}
	if t, ok := h.tombstones[id]; ok && h.clock().Sub(t.at) <= tombstoneTTL {
		for peer := range t.unpairedBy {
			unpaired[peer] = true
		}
	}
	h.devices[id] = &device{id: id, name: name, conn: c, paired: map[string]bool{},
		unpairedBy: unpaired}
	return nil
}
```

  In `offlineLocked`, where the tombstone is written, carry it (the existing line becomes):

```go
	h.tombstones[id] = tombstone{paired: d.paired, unpairedBy: d.unpairedBy, at: h.clock()}
```

  `presenceFor` stops flattening the two cases into one:

```go
// presenceFor lists everything `id` declared: online with a name, offline (a peer it cannot reach),
// or `not_paired` -- a peer that is connected and has removed this device.
func (h *Hub) presenceFor(id string) protocol.Envelope {
	d := h.devices[id]
	var out []protocol.Presence
	for peer := range d.paired {
		p := protocol.Presence{DeviceID: peer}
		if d.unpairedBy[peer] {
			// Deliberately not `online`: there is nothing here to attach to, and a row that reads
			// as reachable is the row a person presses.
			p.NotPaired = true
		} else if pd, ok := h.devices[peer]; ok && pd.paired[id] {
			p.Name, p.Online = pd.name, true
		}
		out = append(out, p)
	}
	return protocol.Envelope{T: "presence", Devices: out}
}
```

  and the `paired` handler tells the peers it has just dropped, which nothing else reaches (`broadcastPresence` only ever visits mutual pairs). Inside `case "paired"`, replacing the assignment:

```go
		previous := d.paired
		d.paired = map[string]bool{}
		for _, id := range e.DeviceIDs {
			if id != from {
				d.paired[id] = true
			}
		}
		// Whoever this device has just stopped declaring, and had declared it, is told so. Without
		// this the removed peer is sent nothing at all, and its palette rows and its attached tabs
		// go on describing a Mac that no longer serves it -- for ever, since the next thing it
		// hears about that Mac is also nothing.
		for peer := range previous {
			if d.paired[peer] {
				continue
			}
			pd, ok := h.devices[peer]
			if !ok {
				// The peer is asleep -- and that is the *common* case, since the Mac you unpair
				// from is usually the one in front of you. `offlineLocked` has already deleted it
				// from h.devices, so without this the flag is recorded nowhere at all and the
				// sleeping Mac wakes up to be told its peer is "offline with no name", which is
				// B2's sentence, unfixed. The tombstone is where it goes; `unpairedBy` is a map,
				// so this mutates the stored tombstone in place rather than a copy of it, and
				// `Online` reads it back when the Mac reconnects.
				if t, found := h.tombstones[peer]; found &&
					h.clock().Sub(t.at) <= tombstoneTTL && t.paired[from] {
					t.unpairedBy[from] = true
				}
				continue
			}
			if !pd.paired[from] {
				continue
			}
			pd.unpairedBy[from] = true
			h.send(peer, h.presenceFor(peer))
		}
		// A re-pairing is the same message with the id back in it, so the flag is cleared here too.
		for peer := range d.paired {
			if pd, ok := h.devices[peer]; ok {
				delete(pd.unpairedBy, from)
			}
		}
```

  and `forward` copies the size on a `role`:

```go
	case "role":
		out.SessionID, out.DeviceID, out.Role = e.SessionID, e.DeviceID, e.Role
		// The host's screen, when it has changed since `attached` said it. Copied here rather than
		// carried on a message of its own: `role` already goes to every attached client of a
		// session, and a new message type would be a fifth thing to keep in step across two
		// repositories.
		out.Cols, out.Rows = e.Cols, e.Rows
```

- [ ] **Step 8: Run the whole Go suite, vet, and the two-instance local run**

Run:
```bash
cd ~/projects/nyx-server && PATH=/opt/homebrew/bin:$PATH make vet && PATH=/opt/homebrew/bin:$PATH make test
```
Expected: no `gofmt` output, `ok` for `protocol`, `relay` and `server`.

Then the thing no unit test proves — a real socket, for longer than the old deadline:

```bash
cd ~/projects/nyx-server && PATH=/opt/homebrew/bin:$PATH make run &     # 127.0.0.1:8787, token dev-token
sleep 1
curl -s http://127.0.0.1:8787/healthz     # {"online":0,...}
```

and a real Nyx against it, with two throwaway configs inside the session scratchpad (never `~/.config/nyx`):

```bash
S=/private/tmp/claude-501/*/scratchpad/relay-local && mkdir -p $S/a $S/b
for d in $S/a $S/b; do
  printf 'remote = on\nremote-relay = ws://127.0.0.1:8787/v1/ws\nremote-relay-token = dev-token\nremote-device-name = %s\n' "$(basename $d)" > $d/config
done
./scripts/bundle.sh
NYX_CONFIG=$S/a ./build/Nyx.app/Contents/MacOS/Nyx &
NYX_CONFIG=$S/b ./build/Nyx.app/Contents/MacOS/Nyx &
```

Expected, and this is the measurement the whole task is for: pair the two instances through Settings → Remote (host shows a code, client types it, both confirm the fingerprint), attach from one to the other, then **leave them alone for five minutes** and watch the relay's log. Before this task the log printed `online`/`offline` for each device roughly every ninety-one seconds; now it prints them once. `curl -s http://127.0.0.1:8787/healthz` still shows `"online":2,"attachments":1` after five minutes. Kill both instances and the relay (`kill %1`), and delete `$S`.

- [ ] **Step 9: Commit — and stop.** Two commits, one per repository.

```bash
cd ~/projects/nyx-server
git add server/server.go server/server_test.go relay/hub.go relay/hub_test.go protocol/message.go README.md
git commit -m "$(cat <<'EOF'
A quiet socket is not a dead one, and an unpaired peer says so

`coder/websocket`'s Read returns on a data message only -- it services ping and pong frames
internally and carries on waiting -- so the 90 s read deadline measured silence rather than death
and closed every idle session on the relay every ninety-one seconds. Liveness is now the last pong
(`OnPongReceived`) or data frame, checked by a watchdog on its own timer, so a socket with nothing
to say stays open and a peer that has stopped answering pings is still closed.

`presence` gains `not_paired`: a peer that is connected and has removed this device. It is recorded
as an event when the other side re-declares without us, never derived from the two lists, so it
tells nobody whether a device id they merely named is online. The removed peer is also *sent* a
presence, which nothing did before -- the only broadcast is to mutual pairs, so the one device that
needed the news was the one device that never got it.

A forwarded `role` carries `cols`/`rows`, which is how a client learns the host resized.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

```bash
cd /Users/nik/projects/nyx
git add docs/superpowers/plans/2026-09-05-remote-sessions-server.md
git commit -m "$(cat <<'EOF'
The wire table says how liveness works and what not_paired means

The relay's contract lives in this plan, so the two fields the relay learned today are written
here: `presence.not_paired` for a peer that is connected and has unpaired, and `cols`/`rows` on a
forwarded `role`. The presence rules paragraph no longer says a device is "silent for 90 s" --
silence is not the check; an unanswered ping is.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

  In the wire table, the `presence` row's fields become `devices: [{device_id, name, online, not_paired}]`, the `role` row's become `to, session_id, device_id, role, cols, rows`, and the "Presence rules" paragraph's first sentence becomes: *a device is online from `welcome` until its socket closes or it stops answering the relay's pings (one every 30 s; the socket is closed when no pong and no frame has arrived for 90 s)*. Add one line after the error codes: *an unpaired peer is reported in `presence` with `not_paired: true` rather than as offline; it is set when the other side re-declares a list without this device and cleared when it declares it again.*

- [ ] **Step 10: Deploy it, and prove the live relay took it.** The owner pre-approved this on 2026-09-10 — do not ask again, and do not skip it: until the container is restarted, the relay the owner's own Macs are talking to still closes every idle socket after ninety-one seconds, which is the defect this whole task exists for.

  Only after Steps 8 and 9 are green — `make vet` and `make test` clean, the local two-instance run quiet for five minutes, both commits made. `deploy.sh` is idempotent: it rsyncs the repo to the host, builds the image there, restarts the container, and rewrites the Caddy block between its markers after `caddy validate` has accepted it (a bad block restores the backup and exits non-zero without ever reloading).

```bash
cd ~/projects/nyx-server && ./deploy.sh
```

  Then the three checks, in this order, and every one of them goes in the task report:

```bash
# 1. The relay is up and is the new build.
curl -fsS https://nyx.agentforge.cc/healthz          # {"online":…,"pairings":…,"attachments":…,"dropped_binary":…}
ssh root@89.124.111.196 'docker logs --tail 50 nyx-relay'
```

  Expected in the log: one `online` line per device as they reconnect, and then **nothing** — no `offline`/`online` pair every ninety-one seconds. That absence is the whole fix. `/healthz` must answer 200 with a JSON body; a non-zero `curl` exit is a failed deploy, not a slow one, and the fix is to read the deploy script's own output rather than to re-run it.

```bash
# 2. A fresh pairing against the deployed relay, on the two local instances.
./scripts/bundle.sh
NYX_CONFIG=~/.config/nyx-a ./build/Nyx.app/Contents/MacOS/Nyx &
NYX_CONFIG=~/.config/nyx-b ./build/Nyx.app/Contents/MacOS/Nyx &
```

  On one: Settings → Remote → `Pair with another device…`; on the other: `Enter a code…`, type the code, confirm the fingerprint on both. Both `paired.json` files gain the pairing, both sheets reach "Paired with …". Record the fingerprint (it is not a secret) and the time. Then attach one to the other and **leave them for ten minutes**: `curl -fsS https://nyx.agentforge.cc/healthz` still reports `"attachments":1`, the strip has not flapped, and the client's transcript holds one copy of the host's screen.

  The token is read, never printed:

```bash
grep -c remote-relay-token ~/.config/nyx-a/config    # 1, and never `cat` the line
```

  If the relay token has to be set on an instance, it is written with `"$(cat ~/projects/nyx-server/token)"` and never echoed. A log that captured it once has already had to be scrubbed in this round.

  **Report exactly three lines**, and no more than three:

```
deploy.sh: <exit status> at <time>
healthz:   <the JSON body>
pairing:   nyx-a ↔ nyx-b, fingerprint <four words>, attachment held <n> minutes
```


---

### Task 2: Core — the primary buffer is readable while the alt screen is up, and a snapshot says what it is

**Files:**
- Modify: `Sources/NyxCore/Session/Transcript.swift` — `TranscriptBuffer`, `rowCount(of:)`, `row(_:in:)`, `transcript(rows:options:buffer:)`
- Modify: `Sources/NyxCore/Remote/RemoteSnapshot.swift` — `compose`, `reset`
- Test: `Tests/NyxCoreTests/TranscriptBufferTests.swift` (new), `Tests/NyxCoreTests/RemoteSnapshotTests.swift` (extended)

**Interfaces:**
- Consumes (already in the tree): `Terminal.screen`, `Terminal.inactiveScreen`, `Terminal.scrollback`, `Terminal.modes.altScreen`, `Terminal.cursor`, `Transcript.Options`, `RemoteSnapshot.trimmingTrailingBlankLines`.
- Produces:

```swift
/// Which of a terminal's two screens a transcript is taken from.
public enum TranscriptBuffer: Equatable { case active, primary, alternate }

public extension Terminal {
    func rowCount(of buffer: TranscriptBuffer) -> Int
    func row(_ absolute: Int, in buffer: TranscriptBuffer) -> Row?
    func transcript(rows: Range<Int>, options: Transcript.Options = .forRestoring,
                    buffer: TranscriptBuffer) -> String
}

public extension RemoteSnapshot {
    /// The bytes a client feeds to become a mirror of the host.
    static func compose(primary: String, alternate: String?, cursor: (row: Int, col: Int)?) -> String
    /// What precedes a *second* snapshot into a terminal that already has one.
    static let reset = "\u{1b}c\u{1b}[3J"
}
```

- [ ] **Step 1: Write the failing tests** — `Tests/NyxCoreTests/TranscriptBufferTests.swift`:

```swift
import Testing
@testable import NyxCore

/// A shell with prompt marks, four commands deep, and then a full-screen program on top of it --
/// which is what a host looks like at the moment somebody attaches to the Mac an agent is running
/// on. `\u{1b}[?1049h` is the switch every such program makes.
private func hostInVim() -> Terminal {
    let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 500)
    for command in ["one", "two", "three"] {
        t.feed("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}\(command)\r\n\u{1b}]133;C\u{7}")
        t.feed("out-\(command)\r\n\u{1b}]133;D;0\u{7}")
    }
    t.feed("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}vim x\r\n\u{1b}]133;C\u{7}")
    t.feed("\u{1b}[?1049h\u{1b}[H~\r\n~\r\n\"x\" [New]")
    return t
}

/// The bug, in one assertion. `absoluteRow` is the scrollback followed by the *active* screen, and
/// on the alternate screen the primary one is not in it at all -- so a snapshot taken with it lost
/// every block still on the host's screen (seven on the host, one on the client) and put vim's
/// tildes in the client's primary buffer, where the program's exit had nothing to restore.
@Test func theActiveTranscriptLosesThePrimaryScreenWhileTheAltScreenIsUp() {
    let t = hostInVim()
    #expect(t.modes.altScreen)
    let active = t.transcript(rows: 0..<t.rowCount(of: .active), buffer: .active)
    #expect(active.contains("~"))
    #expect(!active.contains("vim x"))          // the command that is still on the host's screen
}

@Test func thePrimaryTranscriptKeepsTheScreenTheProgramCoveredAndItsMarks() {
    let t = hostInVim()
    let primary = t.transcript(rows: 0..<t.rowCount(of: .primary), buffer: .primary)
    for command in ["one", "two", "three", "vim x"] {
        #expect(primary.contains(command))
    }
    #expect(primary.contains("\u{1b}]133;A\u{7}"))   // the marks the client's blocks are built from
    #expect(!primary.contains("\"x\" [New]"))        // and nothing of the program on top
}

@Test func theAlternateTranscriptIsTheProgramsScreenAlone() {
    let t = hostInVim()
    let alt = t.transcript(rows: 0..<t.rowCount(of: .alternate), buffer: .alternate)
    #expect(alt.contains("\"x\" [New]"))
    #expect(!alt.contains("out-one"))
}

/// Off the alternate screen the three buffers agree, so a caller that always asks for `.primary`
/// is not a caller with two code paths.
@Test func onThePrimaryScreenTheBuffersAgree() {
    let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 500)
    t.feed("hello\r\n")
    #expect(t.rowCount(of: .active) == t.rowCount(of: .primary))
    #expect(t.transcript(rows: 0..<t.rowCount(of: .active), buffer: .active)
        == t.transcript(rows: 0..<t.rowCount(of: .primary), buffer: .primary))
}

@Test func aRowOutsideABufferIsNil() {
    let t = hostInVim()
    #expect(t.row(-1, in: .primary) == nil)
    #expect(t.row(t.rowCount(of: .primary), in: .primary) == nil)
    #expect(t.row(t.rowCount(of: .alternate), in: .alternate) == nil)
}
```

  and, appended to `Tests/NyxCoreTests/RemoteSnapshotTests.swift`:

```swift
/// The snapshot is ANSI, which is what lets it describe a host that is *in* a full-screen program
/// rather than merely showing one: the primary buffer with its marks, then the switch the program
/// itself made, then the program's screen, then where the cursor is. The client's own parser does
/// the rest -- and when the program exits, its `DECRST 1049` has the primary buffer to restore.
@Test func aComposedSnapshotPutsTheAltScreenOnTopOfThePrimaryOne() {
    let text = RemoteSnapshot.compose(primary: "$ vim x\r\n", alternate: "~\r\n\"x\" [New]",
                                      cursor: (row: 2, col: 5))
    #expect(text == "$ vim x\r\n\u{1b}[?1049h\u{1b}[H~\r\n\"x\" [New]\u{1b}[3;6H")
}

@Test func aHostOnItsOrdinaryScreenComposesToJustTheTranscript() {
    #expect(RemoteSnapshot.compose(primary: "$ ls\r\nfile", alternate: nil, cursor: nil)
        == "$ ls\r\nfile")
    // A cursor without an alternate screen is not written: the primary transcript already leaves
    // the client's cursor at the end of the host's last written row (see
    // `trimmingTrailingBlankLines`), and a CUP here would move it off the prompt.
    #expect(RemoteSnapshot.compose(primary: "$ ls\r\nfile", alternate: nil, cursor: (row: 0, col: 0))
        == "$ ls\r\nfile")
}

/// A *second* snapshot into a terminal that already holds one is what produced 3308 rows against
/// the host's 2007, and rows reading `nik@nik-newmac ~ % nik@nik-newmac ~ % …`: it was appended.
/// A re-snapshot therefore replaces the mirror, and the replacement is itself escape sequences --
/// RIS for the screen and modes, `ED 3` for the scrollback RIS deliberately keeps.
@Test func theResetPrefixEmptiesAMirrorBeforeItIsFilledAgain() {
    let t = Terminal(cols: 20, rows: 3, scrollbackLimit: 500)
    t.feed("UNIQUE_MARKER\r\n")
    for _ in 0..<10 { t.feed("filler\r\n") }
    #expect(t.transcript(options: .plainText).contains("UNIQUE_MARKER"))
    t.feed(RemoteSnapshot.reset)
    #expect(t.rowCount(of: .active) == t.rows)
    let after = t.transcript(options: .plainText)
    #expect(!after.contains("UNIQUE_MARKER"))
    #expect(!after.contains("filler"))
    t.feed("UNIQUE_MARKER\r\n")
    #expect(t.transcript(options: .plainText).components(separatedBy: "UNIQUE_MARKER").count - 1 == 1)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'TranscriptBuffer|RemoteSnapshot' 2>&1 | tail -10`
Expected: compile failure — `cannot find 'TranscriptBuffer' in scope`.

- [ ] **Step 3: The buffer-aware transcript.** In `Sources/NyxCore/Session/Transcript.swift`, above the `Terminal` extension:

```swift
/// Which of a terminal's two screens a transcript is taken from.
///
/// `absoluteRow` -- and therefore `transcript(rows:)` -- is the scrollback followed by whichever
/// screen is *active*, which is the right answer for a selection and the wrong one for a snapshot:
/// while a full-screen program is up, the rows a person's command history lives on are in the
/// inactive screen and appear in no transcript at all.
public enum TranscriptBuffer: Equatable {
    /// What the user is looking at: scrollback plus the active screen.
    case active
    /// The shell's own buffer: scrollback plus the primary screen, whichever screen is showing.
    case primary
    /// A full-screen program's screen, with no scrollback (`DECSET 1049` gives it none).
    case alternate
}
```

  and in the extension, beside `transcript(rows:options:)`:

```swift
    /// How many rows that buffer has.
    func rowCount(of buffer: TranscriptBuffer) -> Int {
        switch buffer {
        case .active, .primary: return scrollback.count + rows
        case .alternate: return rows
        }
    }

    /// One row of a buffer, by index from its own top, or nil when out of range.
    func row(_ absolute: Int, in buffer: TranscriptBuffer) -> Row? {
        guard absolute >= 0, absolute < rowCount(of: buffer) else { return nil }
        switch buffer {
        case .active:
            return absoluteRow(absolute)
        case .primary:
            let screenRows = modes.altScreen ? inactiveScreen.rows : screen.rows
            return absolute < scrollback.count ? scrollback[absolute]
                                               : screenRows[absolute - scrollback.count]
        case .alternate:
            return (modes.altScreen ? screen.rows : inactiveScreen.rows)[absolute]
        }
    }

    /// The transcript of a range of rows of one buffer. `.active` is `transcript(rows:options:)`.
    func transcript(rows range: Range<Int>, options: Transcript.Options = .forRestoring,
                    buffer: TranscriptBuffer) -> String {
        transcript(rows: range, options: options, row: { self.row($0, in: buffer) },
                   total: rowCount(of: buffer))
    }
```

  and make the existing writer take its rows from a closure, so there is one implementation rather than two. Replace the header of `transcript(rows:options:)` with:

```swift
    func transcript(rows: Range<Int>, options: Transcript.Options = .forRestoring) -> String {
        transcript(rows: rows, options: options, row: { self.absoluteRow($0) }, total: totalRows)
    }

    private func transcript(rows: Range<Int>, options: Transcript.Options,
                            row rowAt: (Int) -> Row?, total: Int) -> String {
        var out = ""
        var pen = Pen()
        var penIsDefault = true

        for absolute in rows.clamped(to: 0..<total) {
            guard let row = rowAt(absolute) else { continue }
            // ... the body from here down is unchanged ...
```

  (the loop body needs no edit: it already only reads `row`.)

- [ ] **Step 4: The composer and the reset.** Append to `Sources/NyxCore/Remote/RemoteSnapshot.swift`:

```swift
    /// The bytes a client feeds to become a mirror of the host.
    ///
    /// A host inside a full-screen program is two things at once: a shell buffer with a command
    /// history in it, and a program owning the screen. Sent as one flat transcript, the client got
    /// the program's rows in its *primary* buffer -- so its block history was gone (one block where
    /// the host had seven: no ⌘↑, no folds, no Copy Output, no sticky prompt for that tab, ever),
    /// and when the program exited its `DECRST 1049` had nothing to restore, leaving the tildes on
    /// screen with the prompt underneath them.
    ///
    /// So the snapshot says what it is, in the only language the mirror speaks: the primary buffer
    /// with its marks, then the same `DECSET 1049` the program itself sent, then the program's
    /// screen, then the host's cursor. Nothing new on the wire and nothing new in the client: the
    /// client's own parser puts each half where the host has it.
    ///
    /// `cursor` is one-based row/column as `CUP` counts them, and is written only when there is an
    /// alternate screen: a primary transcript already leaves the cursor at the end of the host's
    /// last written row (see `trimmingTrailingBlankLines`), and moving it again would take it off
    /// the prompt.
    public static func compose(primary: String, alternate: String?,
                               cursor: (row: Int, col: Int)?) -> String {
        guard let alternate else { return primary }
        // `\u{1b}[H` before the screen text because `DECSET 1049` clears the buffer it switches to
        // and leaves the cursor where the primary one had it.
        var out = primary + "\u{1b}[?1049h\u{1b}[H" + alternate
        if let cursor {
            out += "\u{1b}[\(cursor.row + 1);\(cursor.col + 1)H"
        }
        return out
    }

    /// What precedes a *second* snapshot into a terminal that already holds one.
    ///
    /// A re-snapshot used to be appended, which is how a client ended a five-minute idle with 3308
    /// rows against the host's 2007, rows of five concatenated prompts, and eight copies of a
    /// marker the host printed once. RIS resets the screen, the modes and the pen; `ED 3` discards
    /// the scrollback, which RIS deliberately keeps. Both are sequences the mirror already
    /// implements, so the replacement costs no new code path on the receiving side.
    ///
    /// RIS also replaces the terminal's `modes` wholesale (`Terminal.swift:670`), so a re-snapshot
    /// discards the host modes the live stream had accumulated in the mirror -- mouse reporting,
    /// bracketed paste, the cursor shape -- until the host's program sets them again. That is the
    /// right trade against a mirror with a hole in it, and it is why a re-snapshot is the exception
    /// rather than what every reconnect does; before this plan it was what every reconnect did.
    public static let reset = "\u{1b}c\u{1b}[3J"
```

- [ ] **Step 5: Run the tests**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'TranscriptBuffer|RemoteSnapshot|Transcript' 2>&1 | tail -5`
Expected: PASS, including the existing `TranscriptTests` — the refactor must not have moved a byte of a saved scrollback.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Session/Transcript.swift Sources/NyxCore/Remote/RemoteSnapshot.swift \
        Tests/NyxCoreTests/TranscriptBufferTests.swift Tests/NyxCoreTests/RemoteSnapshotTests.swift
git commit -m "$(cat <<'EOF'
A transcript can be asked which screen it means

`absoluteRow` is the scrollback followed by the *active* screen, so while a full-screen program is
up the shell's own buffer -- every prompt mark, every block -- is in no transcript at all.
`TranscriptBuffer` names the three answers and one writer serves them, so nothing about saved
scrollback moves.

`RemoteSnapshot.compose` builds the snapshot a host in vim honestly sends: the primary buffer with
its marks, the `DECSET 1049` the program itself sent, the program's screen, the cursor. It is ANSI,
so the client's own parser puts each half where the host has it -- no wire field, no second code
path, and the program's exit has a primary buffer to restore. `RemoteSnapshot.reset` is what a
*second* snapshot is preceded by, because the first one is still in the mirror.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The host — a reconnect resumes, an alt screen crosses the attach, and the mirror follows the host's size

**Files:**
- Modify: `Sources/NyxRemote/RemoteHost.swift` — `Attachment.suspendedAt`/`heldAtSequence`, `suspend`/`sweep`, `attach`'s resume branch and its snapshot, `deliver`, `presence`, `linkDidReconnect`, `deviceRemoved`, the size announcement
- Modify: `Sources/NyxRemote/RemoteClient.swift` — `handleRole` takes the size
- Modify: `Sources/NyxCore/Remote/RemoteMessage.swift` — `RemotePresence.notPaired` and `role(…, cols:rows:)`, mirroring Task 1's two wire fields
- Modify: `Sources/NyxRemote/RelayConnection.swift` — the class comment that described the 90 s close as the contract
- Modify: `Sources/NyxApp/RemoteCoordinator.swift` — `removePairing` calls `deviceRemoved`
- Test: `Tests/NyxRemoteTests/RemoteHostTests.swift` (extended, and two existing tests rewritten), `Tests/NyxRemoteTests/RemoteClientTests.swift` (extended)

**Interfaces:**
- Consumes (Task 2): `RemoteSnapshot.compose(primary:alternate:cursor:)`, `RemoteSnapshot.reset`, `Terminal.transcript(rows:options:buffer:)`, `Terminal.rowCount(of:)`, `TranscriptBuffer`. (Task 1): a forwarded `role` keeps `cols`/`rows`.
- Consumes (already in the tree): `WriterArbiter`, `E2ESession`, `RemoteClock`, `TerminalSession.withTerminalAndOutputCount`.
- **Considered and rejected: a `since` on `attach`.** The exact version of the resume test would be
  the client telling the host how much it has actually received. It cannot, as the code stands, and
  the three reasons are worth writing down because the idea will occur to the next reader:
  `E2ESession.lastAcceptedCounter` is `private` with no accessor (`E2ESession.swift:55`); it counts
  **frames**, while `registration.sequence` counts **chunks**, and `chunked(_:sealedBy:)` splits one
  chunk into as many 16 KiB frames as it needs (`RemoteHost.swift:393-404`); and a fresh
  `E2ESession` is built on **both** sides for every attach (`RemoteClient.Attachment.begin()` sets
  `e2e = nil`, `:209-210`), so the counter restarts at zero per attachment -- which the QA confirmed
  on the wire. Making it exact would mean the client counting decrypted bytes across attachments,
  resetting at `snapshot_end`, and a new wire field carried in all four places: real work, in the
  one place where an off-by-one is a hole nobody can see. It is in the ledger; `heldAtSequence` is
  what this plan ships, with its one residual window named in `attach`.
- Produces:

```swift
public final class RemoteHost {
    public init(link: RelayLink, identity: DeviceIdentity, paired: @escaping () -> PairedDevices,
                audit: @escaping (AuditLine.Event) -> Void, snapshotLines: Int,
                summaryDebounce: TimeInterval = 2,
                reattachWindow: TimeInterval = 60, clock: RemoteClock = .system)
    /// The relay's word that a device's socket has gone. Its attachments are *held*, not dropped.
    public func deviceWentOffline(_ deviceID: String)
    /// The user removed this device. Its attachments go at once -- there is nothing to come back to.
    public func deviceRemoved(_ deviceID: String)
}
public struct RemotePresence: Codable, Equatable {
    public var notPaired: Bool          // absent on the wire reads as false
    public init(deviceID: String, name: String, online: Bool, notPaired: Bool = false)
}
public extension RemoteMessage {
    static func role(to: String, sessionID: String, deviceID: String, role: String,
                     cols: Int? = nil, rows: Int? = nil) -> RemoteMessage
}
// RemoteClient.Attachment, internal: `handleRole` takes the size, and `report` can be forced.
//   func handleRole(_ role: String, cols: Int?, rows: Int?)
//   private func report(if:force:_:)
```

- [ ] **Step 1: Write the failing host tests.** In `Tests/NyxRemoteTests/RemoteHostTests.swift`, give the fixture the driven clock and the window:

```swift
    let clock = TestClock()

    init(script: String, snapshotLines: Int = 200, debounce: TimeInterval = 0.05,
         reattachWindow: TimeInterval = 60) throws {
        // ... unchanged up to the host ...
        host = RemoteHost(link: link, identity: identity,
                          paired: { PairedDevices(devices: pairedBox().map { PairedDevice(id: $0, name: $0, pairedAt: Date()) }) },
                          audit: { auditBox($0) },
                          snapshotLines: snapshotLines, summaryDebounce: debounce,
                          reattachWindow: reattachWindow, clock: clock.clock)
```

  and append the tests:

```swift
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
```

  and, appended to `Tests/NyxRemoteTests/RemoteClientTests.swift`, the client's half of D2:

```swift
/// The mirror follows the host. A `role` that carries a size is the only message that says the
/// host's window changed shape, and the size is not part of `AttachState` -- the pane reads it off
/// the attachment -- so the state has to be *re*-reported even though nothing in it moved, or
/// `RemoteSession.applyHostSize` is never called and the grid keeps its size-at-attach for ever.
@Test func aRoleCarryingASizeResizesTheMirrorAndReportsIt() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer", cols: 80, rows: 24)
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.cols == 80)
    let recorder = Recorder()
    recorder.watch(attachment)
    f.client.handle(f.host.message(.role(to: f.deviceID, sessionID: f.key,
                                         deviceID: f.deviceID, role: "writer",
                                         cols: 132, rows: 40)))
    #expect(attachment.cols == 132)
    #expect(attachment.rows == 40)
    // Reported even though the phase and the role are exactly what they were: that report is what
    // `RemoteSession.applyHostSize` rides on.
    #expect(recorder.phases == [.live])
    #expect(attachment.state.role == .writer)
}

/// The geometry on a `role` is as unsigned as the geometry on an `attached`, and this one arrives
/// at a tab that is already live. An impossible size is *ignored* rather than ending the tab:
/// ending it would hand anyone who can replay a `role` a way to close somebody's session.
@Test func anImpossibleSizeOnARoleIsIgnoredAndTheTabLivesOn() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach(role: "writer", cols: 80, rows: 24)
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.client.handle(f.host.message(.role(to: f.deviceID, sessionID: f.key,
                                         deviceID: f.deviceID, role: "observer",
                                         cols: 2_000_000_000, rows: 1)))
    #expect(attachment.cols == 80)
    #expect(attachment.state.phase == .live)
    #expect(attachment.state.role == .observer)     // the role still applies; only the size did not
}
```

  (`ClientFixture`, `Recorder` and the `f.attach()` → `f.acceptAttach()` → `snapshotEnd` idiom are
  what `Tests/NyxRemoteTests/RemoteClientTests.swift` already uses at `:155-176`; match them rather
  than introducing a second fixture.)

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'RemoteHost|RemoteClient' 2>&1 | tail -20`
Expected: a compile failure first — `RemoteHost` has no `reattachWindow`, no `clock`, no `deviceRemoved`, and `RemoteMessage.role` takes no size. Once those exist as stubs, `aClientThatComesStraightBackResumesWithNoSnapshotAndNoAuditLine` fails on the second snapshot (`endIndex == attachedIndex + 1` is false: there are frames between them) and on the duplicated audit line.

- [ ] **Step 3: The wire mirror.** `Sources/NyxCore/Remote/RemoteMessage.swift`, mirroring Task 1 field for field. First the presence flag, which both this task and Task 4 read:

```swift
/// One entry of a `presence` message: a paired device, whether it is online right now, and whether
/// the pairing is still mutual.
public struct RemotePresence: Codable, Equatable {
    public var deviceID: String
    public var name: String
    public var online: Bool
    /// The peer is connected and no longer declares this device: it removed the pairing.
    ///
    /// The Go side carries it as `not_paired,omitempty`, so it is simply **absent** from every
    /// relay older than Task 1's deploy and from every peer that is paired normally. Absent must
    /// read as `false`, which is what it meant before the field existed.
    public var notPaired: Bool

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name, online
        case notPaired = "not_paired"
    }

    public init(deviceID: String, name: String, online: Bool, notPaired: Bool = false) {
        self.deviceID = deviceID
        self.name = name
        self.online = online
        self.notPaired = notPaired
    }

    /// Hand-written for one field. A property's default value does **not** satisfy the synthesized
    /// decoder -- `var notPaired = false` still emits `decode(_:forKey:)` and throws
    /// `keyNotFound` on a message that omits the key, which is every presence message the deployed
    /// relay has ever sent. Verified on this toolchain (Swift 6.0.3), because getting it wrong
    /// fails only at run time, against a real relay, as "the palette went empty".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        name = try c.decode(String.self, forKey: .name)
        online = try c.decode(Bool.self, forKey: .online)
        notPaired = try c.decodeIfPresent(Bool.self, forKey: .notPaired) ?? false
    }
}
```

  `name` and `online` stay required: the Go struct declares both without `omitempty`, so they are on the wire even for an offline peer (as `""` and `false`). Add one test in `Tests/NyxCoreTests/RemoteMessageTests.swift` that decodes a `presence` **without** `not_paired` and expects `notPaired == false` — that is the compatibility promise this whole paragraph is about, and it is one line to assert and impossible to notice going missing.

  Then `role` carries the host's screen:

```swift
    /// `cols`/`rows` are the host's current screen, present only on a `role` that is announcing a
    /// resize. Optional rather than always sent: an old relay strips them (it copies the fields its
    /// own wire table lists), and a client that required them would break on the day the container
    /// is restarted rather than on the day the field was added.
    public static func role(to: String, sessionID: String, deviceID: String, role: String,
                            cols: Int? = nil, rows: Int? = nil) -> RemoteMessage {
        RemoteMessage(t: "role", to: to, deviceID: deviceID, sessionID: sessionID, role: role,
                      cols: cols, rows: rows)
    }
```

  Nothing else moves here: `RemoteMessage` already has `cols`/`rows` as optional fields with the right JSON names, so this is the factory catching up with the struct.

- [ ] **Step 4: The attachment is held, not dropped.** In `RemoteHost`, the two new fields and the clock:

```swift
    private struct Attachment {
        let deviceID: String
        let e2e: E2ESession
        let startSequence: UInt64
        /// When the relay said this device's socket had gone, or nil while it is connected.
        ///
        /// A held attachment is the whole of the reconnect fix: the relay's word that a socket
        /// closed is not the user's word that they have finished, and treating the two the same
        /// cost the writer its token, the client a second snapshot and the log two lines -- every
        /// ninety-one seconds, because that is how often the relay used to close a quiet socket.
        var suspendedAt: Date?
        /// `registration.sequence` at the moment it was held: the chunk number the client's mirror
        /// is known to be complete up to.
        ///
        /// A sequence rather than a "did it miss anything" boolean, because a boolean can only be
        /// set by code that runs, and the windows in which output reaches nobody are exactly the
        /// windows in which nothing on this side is watching. `deliver` bumps `sequence` for every
        /// chunk whether or not anybody is attached, so `sequence == heldAtSequence` at re-attach
        /// time means, verifiably, that not one chunk was produced while this attachment was away.
        /// Anything else is a re-snapshot, and the cost of being wrong in that direction is one
        /// snapshot rather than a hole nobody can see (`E2ESession.open` checks that counters
        /// increase and cannot see a gap).
        var heldAtSequence: UInt64?
    }
```

```swift
    private let reattachWindow: TimeInterval
    private let clock: RemoteClock
```

  with the two new parameters on `init` — **both defaulted**, so `RemoteCoordinator`'s existing call site compiles untouched:

```swift
    /// `reattachWindow` is how long an attachment survives its client's socket closing. Sixty
    /// seconds, the same number `RemoteClient.Attachment.reattachWindow` gives the client to keep
    /// asking: the two are one race seen from its two ends, and a host that gave up first would
    /// end a tab that was still trying.
    public init(link: RelayLink, identity: DeviceIdentity, paired: @escaping () -> PairedDevices,
                audit: @escaping (AuditLine.Event) -> Void, snapshotLines: Int,
                summaryDebounce: TimeInterval = 2,
                reattachWindow: TimeInterval = 60, clock: RemoteClock = .system) {
```

  `deviceWentOffline` holds instead of dropping, and the user's Remove gets a door of its own:

```swift
    /// A device this host was talking to has gone *quiet*: the relay's socket for it closed. Its
    /// attachments are **held** for `reattachWindow`, because a closed socket is not a closed tab
    /// -- the client is already re-attaching -- and dropping them is what made every reconnect a
    /// new attachment.
    ///
    /// Reachable through `presence` and kept public for the one caller that is not the relay: a
    /// test that drives a departure without a wire message. The app's own reason for calling it
    /// directly is gone -- `RemoteCoordinator.removePairing` now calls `deviceRemoved`, which is a
    /// different answer to a different question.
    public func deviceWentOffline(_ deviceID: String) {
        queue.async { [weak self] in
            self?.suspend(deviceID)
        }
    }

    /// The user removed this device. Its attachments go at once: there is nothing to come back to,
    /// the pairing check would refuse the re-attach anyway, and a held attachment would leave the
    /// writer token on a Mac that is no longer allowed to type.
    public func deviceRemoved(_ deviceID: String) {
        queue.async { [weak self] in
            self?.dropAttachments(of: deviceID)
        }
    }
```

  and the two queue-only halves, beside `dropAttachments` (which keeps its body and loses its
  `presence` caller):

```swift
    /// Marks every attachment of `deviceID` as held, and arms the sweep that ends them if it does
    /// not come back. One timer per suspension, not one per session: a device is offline from all
    /// of them at once.
    ///
    /// **An attachment that is already held is left exactly as it is.** `presence` is a *snapshot*,
    /// not an event: `presenceFor` lists every peer the device declared, offline ones included
    /// (`relay/hub.go:161-172`), and `broadcastPresence` rebuilds and sends it whenever **any**
    /// mutually paired peer's presence changes (`:178-184`). So with three or more paired Macs --
    /// which is the feature's premise -- a *different* Mac opening its lid twenty seconds into this
    /// client's hold delivers another snapshot that still says this one is offline. Re-baselining on
    /// it would move `heldAtSequence` forward over the chunks the client actually missed and turn
    /// its re-attach into a resume with no snapshot: C1's defect again, reached through ordinary
    /// presence traffic. It would also arm a fresh timer with a fresh `suspendedAt` each time, so a
    /// client that never comes back but whose *peers* keep changing presence would never be swept
    /// and would hold the writer token for as long as the traffic lasted.
    ///
    /// Hold once. The first `suspendedAt` and the first `heldAtSequence` are the record, and the
    /// first timer is still pending with an identity check that still matches.
    private func suspend(_ deviceID: String) {
        let now = clock.now()
        var held = false
        for key in order {
            guard let registration = registrations[key],
                  let attachment = registration.attachments[deviceID],
                  attachment.suspendedAt == nil else { continue }
            registration.attachments[deviceID]?.suspendedAt = now
            // Per registration, because `sequence` is: a device attached to two of this Mac's
            // sessions is held on both, and each one remembers its own session's chunk number.
            registration.attachments[deviceID]?.heldAtSequence = registration.sequence
            held = true
        }
        // False when everything was already held, and then no second timer is armed -- which is the
        // whole point of the guard above.
        guard held else { return }
        // One tick past the window, so the sweep and a re-attach that arrives at the last second
        // cannot both believe they were first.
        clock.after(reattachWindow + 1) { [weak self] in
            self?.queue.async { self?.sweep(deviceID, suspendedAt: now) }
        }
    }

    /// The window closed and the device did not come back, so now it really has gone: the
    /// attachment ends, the token moves, and *this* is where the audit line is written.
    ///
    /// `suspendedAt` is the identity check. A device that dropped, returned and dropped again has a
    /// newer suspension, and this timer belongs to the older one -- without the comparison the
    /// first drop's minute would end the second drop's attachment twenty seconds into its own.
    private func sweep(_ deviceID: String, suspendedAt: Date) {
        for key in order {
            guard let registration = registrations[key],
                  registration.attachments[deviceID]?.suspendedAt == suspendedAt else { continue }
            registration.attachments[deviceID] = nil
            announce(registration.arbiter.detached(deviceID), in: registration, key: key)
            audit(.detached(device: deviceID, session: key))
        }
    }
```

  `presence` routes the three answers it can now carry:

```swift
    /// The relay's word about the devices this host is paired with.
    ///
    /// Two answers, not three. Offline is a socket that closed -- hold. `not_paired` is the peer
    /// saying it has removed this Mac, which is settled and immediate.
    ///
    /// **Online is deliberately not an answer.** A hold is released by the `attach` that replaces
    /// the `Attachment`, and by nothing else. Clearing it on a presence would open a window --
    /// from the broadcast until the client's `attach` actually lands, which is a relay round trip
    /// plus the client's own re-attach backoff -- in which `deliver` believes it has a live
    /// attachment, seals every chunk, and sends them to a relay that has not re-registered this
    /// client yet (`relay/hub.go:446-469` adds it back only when the host answers `attached`), so
    /// they are counted in `dropped_binary` and lost. The re-attach would then look like a clean
    /// resume and the mirror would be silently short. The sweep does not need this branch either:
    /// it guards on `suspendedAt` identity, and a re-attach replaces the whole `Attachment`.
    private func presence(_ m: RemoteMessage) {
        for device in m.devices ?? [] {
            if device.notPaired {
                dropAttachments(of: device.deviceID)
            } else if !device.online {
                suspend(device.deviceID)
            }
        }
    }
```

  `deliver` stops sealing for a held attachment -- and needs to remember nothing, because the chunk
  number it has just spent is the record:

```swift
        for deviceID in registration.attachments.keys.sorted() {
            guard let attachment = registration.attachments[deviceID],
                  attachment.startSequence <= sequence else { continue }
            // A held attachment has no socket: the relay dropped it when the device's own socket
            // went, so sealing and sending would be ~85 KB per client per cycle into nothing.
            // Nothing is recorded here -- `registration.sequence` was already incremented above,
            // which is what `heldAtSequence` is compared against at the re-attach.
            guard attachment.suspendedAt == nil else { continue }
            guard let frames = chunked(bytes, sealedBy: attachment.e2e) else {
                broken.append(deviceID)
                continue
            }
            for frame in frames { link.send(frame) }
        }
```

  and `linkDidReconnect` — *this* Mac's socket came back — holds rather than clears:

```swift
    /// This host's own socket came back. The relay kept nothing: it dropped this device's catalogue
    /// and sent `session_suspended` to everyone who was attached, so each of them is re-attaching
    /// as soon as this Mac's catalogue lists the session again.
    ///
    /// The attachments are **held**, and the arbiter is left exactly as it was. Clearing both --
    /// which is what this did -- made every one of those re-attaches a new attachment: a fresh
    /// snapshot, the writer token handed to whoever asked first, and two audit lines per client.
    /// With the relay closing quiet sockets every ninety-one seconds, that was the churn the QA
    /// measured. The sweep is what ends an attachment whose client really has gone.
    public func linkDidReconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.link.send(.paired(self.paired().ids))
            let devices = Set(self.order.compactMap { self.registrations[$0] }
                .flatMap { $0.attachments.keys })
            // `suspend` is idempotent by its own guard, which matters here: a client whose socket
            // dropped before this host's did is already held, and re-baselining it on this host's
            // reconnect would erase the record of what it missed.
            for deviceID in devices.sorted() { self.suspend(deviceID) }
            self.publishSessions()
        }
    }
```

- [ ] **Step 5: The attach resumes, and the snapshot says which screen it is.** In `attach`, after the signature checks, the role branch keeps its shape and gains the resume:

```swift
        let existing = registration.attachments[from]
        let role: AttachState.Role
        if existing != nil, let held = registration.arbiter.role(of: from) {
            role = held
        } else {
            role = registration.arbiter.attached(from)
        }
        // A resume, and only under both halves of the proof: the attachment was actually **held**
        // (a socket that closed, not a second `attach` from a device that never went), and not one
        // chunk was produced while it was away. Then its mirror is still exactly this host's
        // screen, and it gets `attached` and `snapshot_end` with nothing between them -- no ~85 KB
        // re-encrypted, no second copy of the transcript appended to the first, no writer/observer
        // flap, no line in the log. This is the whole client-side half of B1.
        //
        // `existing != nil` alone is **not** enough, and was the first draft of this line: a
        // duplicated or replayed `attach` from a device that never dropped would have been answered
        // with an empty screen where it used to get the snapshot.
        //
        // One residual window, named because a reader must not believe there is none: a chunk
        // delivered in the milliseconds between the client's socket closing and this host being
        // told (`offlineLocked` removes the client from `h.attached` and broadcasts presence under
        // one lock, so it is a relay-to-host trip, tens of milliseconds) is sealed, sent, dropped
        // by the relay, and *counted* -- so it lands below `heldAtSequence` and the resume believes
        // the mirror is whole. Closing it needs the client to say how much it actually received,
        // which is a wire field and a byte-accounting handshake on both sides; it is in the ledger,
        // and the cost of the residual is whatever this host produced in that window -- usually
        // nothing, one chunk on a quiet session, several on a printing one, since `deliver` runs
        // once per PTY read -- after a socket drop that the fixed relay makes rare.
        let resuming = existing?.suspendedAt != nil
            && existing?.heldAtSequence == registration.sequence
```

  and the snapshot becomes buffer-aware:

```swift
        let (snapshot, cols, rows, fed) = registration.session.withTerminalAndOutputCount { terminal, count in
            guard !resuming else { return ("", terminal.cols, terminal.rows, count) }
            // The *primary* buffer, always: `absoluteRow` is the scrollback followed by whichever
            // screen is active, so while a full-screen program is up the rows this host's command
            // history lives on are in no transcript at all -- which cost an attaching client seven
            // blocks and gave it vim's tildes in their place (B3).
            let primaryRows = terminal.rowCount(of: .primary)
            let top = max(0, primaryRows - snapshotLines)
            let primary = RemoteSnapshot.trimmingTrailingBlankLines(
                terminal.transcript(rows: top..<primaryRows, options: .forRestoring, buffer: .primary))
            // And the program on top of it, when there is one, with the host's cursor after it.
            let alternate = terminal.modes.altScreen
                ? RemoteSnapshot.trimmingTrailingBlankLines(
                    terminal.transcript(rows: 0..<terminal.rowCount(of: .alternate),
                                        options: .forRestoring, buffer: .alternate))
                : nil
            let cursor = terminal.modes.altScreen
                ? (row: terminal.cursor.y, col: terminal.cursor.x)
                : nil
            let text = RemoteSnapshot.compose(primary: primary, alternate: alternate, cursor: cursor)
            // A *second* snapshot into a mirror that already holds one used to be appended: 3308
            // rows against this host's 2007, and rows reading `nik@nik-newmac ~ % nik@nik-newmac ~
            // % …`. A re-snapshot replaces.
            return ((existing != nil ? RemoteSnapshot.reset : "") + text,
                    terminal.cols, terminal.rows, count)
        }
        registration.attachments[from] = Attachment(deviceID: from, e2e: e2e, startSequence: fed,
                                                    suspendedAt: nil, heldAtSequence: nil)
        // The size `attached` has just been told, so the announcement in `publishSessions` does not
        // repeat it on the next publish.
        registration.announcedSize = GridSize(cols: cols, rows: rows)
```

  the send is unchanged except for the audit line:

```swift
        link.send(.attached(to: from, sessionID: key, ephemeralPubkey: signed.pubkey, sig: signed.sig,
                            role: Self.name(role), cols: cols, rows: rows))
        for frame in frames { link.send(frame) }
        link.send(.snapshotEnd(to: from, sessionID: key))
        // One line per attachment, not one per reconnect. A device whose socket blinked never left
        // -- nothing was written when it went -- so writing "attached" when it comes back would be
        // half of a pair whose other half does not exist. The QA counted two such lines per client
        // per ninety-one seconds.
        if existing == nil { audit(.attached(device: from, session: key)) }
```

  The failure branch above it needs the same care: a seal that fails on a *resume* must not audit a
  detach for a device that was never announced as attached, so it becomes
  `if existing == nil { audit(.detached(device: from, session: key)) }` — and the attachment is put
  back to `nil` either way, which is what lets the client try again.

- [ ] **Step 6: The size, announced once per change.** `Registration` remembers what it last said:

```swift
        /// The screen size the attached clients were last told, so a resize is announced once
        /// rather than on every debounced publish.
        var announcedSize: GridSize?
```

  and `publishSessions` announces after the catalogue:

```swift
    private func publishSessions() {
        link.send(.sessions(order.compactMap { key in
            guard var info = registrations[key]?.summary() else { return nil }
            info.sessionID = key
            return info
        }))
        announceSizes()
    }

    /// This host's window size, resent to everyone attached when it changes.
    ///
    /// `attached` carries it once and nothing carried it again, so a host resized while a client
    /// watched went on sending output laid out for its new width into a mirror still shaped like
    /// the old one, and every line wrapped (D2). `role` is what carries it: it already goes to
    /// every attached client of a session, it already names which device's role it is, and the
    /// relay already forwards it -- a message of its own would be a fifth thing to keep in step
    /// across two repositories. A held attachment is skipped: it has no socket, and its resume
    /// will carry the size in `attached`.
    private func announceSizes() {
        for key in order {
            guard let registration = registrations[key] else { continue }
            let size = registration.session.withTerminal { GridSize(cols: $0.cols, rows: $0.rows) }
            guard size != registration.announcedSize else { continue }
            registration.announcedSize = size
            for deviceID in registration.attachments.keys.sorted()
            where registration.attachments[deviceID]?.suspendedAt == nil {
                let role = registration.arbiter.role(of: deviceID) ?? .observer
                link.send(.role(to: deviceID, sessionID: key, deviceID: deviceID,
                                role: Self.name(role), cols: size.cols, rows: size.rows))
            }
        }
    }
```

  On the client, `handleRole` takes the size and forces the report:

```swift
        func handleRole(_ role: String, cols: Int?, rows: Int?) {
            lock.lock()
            var moved = false
            // Checked before it is believed, exactly as `handleAttached` does and for the same
            // reason: the host signs its ephemeral key and the session id, never the geometry, so
            // these two numbers are whatever reached the socket. Refused *silently* here, though --
            // this tab is already live, and ending it on a forged `role` would hand anyone who can
            // replay one a way to close somebody's session.
            if let cols, let rows, AttachGeometry.isSane(cols: cols, rows: rows) {
                moved = cols != _cols || rows != _rows
                _cols = cols
                _rows = rows
            }
            lock.unlock()
            // Forced when the size moved and the role did not. `report` drops a state that compares
            // equal, and the size is not *in* `AttachState` -- the pane reads it off the attachment
            // -- so without this the one message that says the host resized changes nothing at all
            // and the mirror keeps its size-at-attach for the life of the tab.
            report(force: moved) { $0.role = role == "writer" ? .writer : .observer }
        }
```

  with `report` gaining the flag:

```swift
        private func report(if condition: ((AttachState) -> Bool)? = nil, force: Bool = false,
                            _ change: (inout AttachState) -> Void) {
            lock.lock()
            guard !finished, condition?(_state) ?? true else {
                lock.unlock()
                return
            }
            var updated = _state
            change(&updated)
            guard force || updated != _state else {
                lock.unlock()
                return
            }
```

  and the routing in `RemoteClient.handle`:

```swift
        case "role":
            guard m.deviceID == link.deviceID, let role = m.role else { return }
            attachment.handleRole(role, cols: m.cols, rows: m.rows)
```

- [ ] **Step 7: Remove tells the host it was Remove.** In `RemoteCoordinator.removePairing`, one line changes and one moves:

```swift
    func removePairing(deviceID: String) {
        let name = paired.devices.first { $0.id == deviceID }?.name ?? deviceID
        // `deviceRemoved`, not `deviceWentOffline`: the attachments go now rather than being held
        // for a minute against a device that is never coming back.
        host?.deviceRemoved(deviceID)
        client?.endAll(matching: deviceID, reason: AttachFailure.unpaired)
        // *After* the teardown above, and the name is kept anyway -- see `namesOfRemovedDevices` in
        // Task 5. The audit line for the detach this raises is written on the main queue, later, so
        // ordering alone cannot save the name.
        namesOfRemovedDevices[deviceID] = name
        paired.remove(id: deviceID)
        savePaired()
        catalogue.setPaired(paired.namesByID)
        connection?.send(.paired(paired.ids))
        appendAudit(.removed(name))
        onChange?()
    }
```

  (`namesOfRemovedDevices` is declared and read in Task 5. Declare it here as an empty
  `[String: String]` and let Task 5 wire it into `appendAudit`; a name written into a dictionary
  nothing reads yet is one line, and splitting the ordering fix from the naming fix would leave a
  commit in which Remove audits an id on purpose.)

- [ ] **Step 8: Correct the comment that described the bug as the contract.** `RelayConnection`'s class note (`Sources/NyxRemote/RelayConnection.swift:64-69`) says the relay "closes a socket that has been silent for 90 s, and that close is what this side sees". After Task 1 that is false, and it was the sentence that let B1 live in a shipped build for a week: a comment stating a defect as a design decision is a defect nobody re-reads. Its second half stays, because it is right:

```swift
/// **Liveness** is the relay's job, not this class's. The relay pings every 30 s and
/// `URLSessionWebSocketTask` answers those itself, which keeps the socket warm through NAT and
/// proxies *and* is what the relay's own liveness watchdog reads: a socket with nothing to say
/// stays open, and one that stops answering pings is closed within 90 s. (Until 2026-09-11 the
/// relay measured *silence* instead -- `coder/websocket`'s Read returns on a data message only --
/// so it closed every idle session every ninety-one seconds, and this comment described that as
/// the contract.) A socket that has gone half-open is noticed by the next receive or send that
/// fails -- there is deliberately no client-side ping, because one would only duplicate the
/// relay's timer while adding a second way for a healthy connection to be declared dead.
```

- [ ] **Step 9: Run the tests**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'RemoteHost|RemoteClient|RemoteSnapshot' 2>&1 | tail -8`
Expected: PASS, all of them, including the existing host tests. Two of those existing tests assert
today's behaviour and are **rewritten in this task, not deleted**: whichever of them says that a
`presence(offline)` drops the attachment at once, and whichever says `linkDidReconnect` clears them
and audits a detach. Rewrite each to the new rule (held, then swept) and say in the commit message
which two moved — a test deleted because the behaviour changed is a rule nobody will notice going
missing again.

- [ ] **Step 10: Commit**

```bash
git add Sources/NyxRemote/RemoteHost.swift Sources/NyxRemote/RemoteClient.swift \
        Sources/NyxRemote/RelayConnection.swift Sources/NyxCore/Remote/RemoteMessage.swift \
        Sources/NyxApp/RemoteCoordinator.swift Tests/NyxCoreTests/RemoteMessageTests.swift \
        Tests/NyxRemoteTests/RemoteHostTests.swift Tests/NyxRemoteTests/RemoteClientTests.swift
git commit -m "$(cat <<'EOF'
A reconnect returns to the attachment it left

The relay's word that a client's socket closed is not that client's word that it has finished, and
the host treated the two the same: `presence(offline)` deleted the attachment, so the re-attach
that followed a moment later was a *new* one -- appended to the back of the arbiter's queue (the
writer silently became an observer for about twelve seconds of every ninety-one), sent the whole
2,000-line snapshot again (~85 KB, and the client appended it to the copy it already had: 3308 rows
against the host's 2007), and wrote two lines into the audit log. An attachment is now held for
sixty seconds, the arbiter is left alone, and a resume is answered with `attached` and
`snapshot_end` and nothing in between. A client that really has gone is swept when the window
closes, which is where the detach line is written; a client that missed output while it was away
gets a fresh snapshot prefixed with `RemoteSnapshot.reset`, because the first one is still in its
mirror. `deviceRemoved` is the door Remove uses, which does drop at once: there is nothing to come
back to.

The snapshot also says which screen it is. It was the *active* buffer, so attaching to a Mac
running vim -- the thing this feature is for -- put the program's rows in the client's primary
buffer and left it one block where the host had seven, with no ⌘↑, no folds and no sticky prompt for
that tab ever again. It is the primary buffer with its marks, then the `DECSET 1049` the program
itself sent, then the program's screen and the host's cursor.

And a `role` carries `cols`/`rows`, so a host resized while somebody is watching stops laying its
output out for a width the mirror does not have. Announced once per change from the debounced
publish, and the client re-reports the state even though nothing in it moved -- the size is read off
the attachment, not carried in it, so an unforced report would have left the mirror the shape the
host was at attach for the life of the tab.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: The client — an unpaired host says so, a refused relay clears the rows, and a dead tab drops its badge

**Files:**
- Modify: `Sources/NyxRemote/RemoteClient.swift` — `handlePresence` takes `notPaired`, `handleError`/`retryReattach` end on `not_paired`
- Modify: `Sources/NyxCore/Remote/RemoteCatalogue.swift` — the offline name rule, `notPaired` on `Device`, `forget(deviceID:)`
- Modify: `Sources/NyxCore/Remote/AttachState.swift` — `badge` becomes optional and phase-aware
- Modify: `Sources/NyxApp/RemoteCoordinator.swift` — `.failed` resets the catalogue, `attach` refuses without a socket, a `not_paired` error drops that host's rows
- Modify: `Sources/NyxApp/TabController.swift` — `badge` is now optional
- Test: `Tests/NyxRemoteTests/RemoteClientTests.swift` (extended), `Tests/NyxCoreTests/RemoteCatalogueTests.swift` (extended), `Tests/NyxCoreTests/AttachStateTests.swift` (extended)

**Interfaces:**
- Consumes (Task 3): `RemotePresence.notPaired`. (Task 1, once deployed): a `presence` entry carrying `not_paired: true`; absent on an older relay, which reads as `false` and leaves every behaviour here exactly as it is today.
- Consumes (already in the tree): `AttachFailure.unpaired`, `AttachFailure.relayRefused(_:)`, `RelayConnection.Status`, `RemoteClient.endAll(matching:reason:)`, `RemoteCatalogue.setPaired(_:)`/`applyPresence(_:)`.
- Produces:

```swift
public extension RemoteCatalogue {
    struct Device: Equatable {
        public let id: String
        public var name: String
        public var online: Bool
        /// This device is connected and has removed the pairing with this Mac.
        /// **Defaulted to `false`**, which is what keeps `applyCatalogue`'s and `setPaired`'s
        /// existing `Device(id:name:online:sessions:)` calls (`RemoteCatalogue.swift:49`, `:70`)
        /// compiling untouched.
        public var notPaired: Bool = false
        public var sessions: [RemoteSessionInfo]
    }
    /// Drops one device's rows without touching `pairedIDs`.
    mutating func forget(deviceID: String)
}
public extension AttachState {
    var badge: String? { get }        // was `String`
}
```

- [ ] **Step 1: Write the failing tests.** First give `ClientFixture.presence` the flag, since three tests want it (`Tests/NyxRemoteTests/RemoteClientTests.swift:50-55`):

```swift
    /// A `presence` naming this fixture's host, the way the relay sends one. `notPaired` is the
    /// answer a relay gives about a peer that is connected and has removed this device.
    func presence(hostOnline: Bool, notPaired: Bool = false) -> RemoteMessage {
        RemoteMessage(t: "presence",
                      devices: [RemotePresence(deviceID: host.deviceID, name: "studio",
                                               online: hostOnline, notPaired: notPaired)])
    }
```

  then append:

```swift
/// B2, the whole of it. The host pressed Remove; the relay says so; the tab must say so. Until the
/// relay could tell the two apart, "beta has been offline since 21:17 — waiting for it to come
/// back" was what a person read while beta sat online two windows away -- a sentence they could
/// check and find false, on the one screen they had no other way to check. `AttachFailure.unpaired`
/// has existed since the feature shipped and was reachable only when *this* Mac did the removing.
@Test func aHostThatUnpairedUsEndsTheTabInsteadOfSuspendingIt() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    #expect(attachment.state.phase == .live)

    f.client.handle(f.presence(hostOnline: false, notPaired: true))
    #expect(attachment.state.phase == .failed(AttachFailure.unpaired))
    #expect(!attachment.state.acceptsInput)
    #expect(!attachment.state.isAttached)
}

/// And it outranks the wait a suspended tab is already in: the QA's tab had been suspended for
/// ninety-five seconds by the time anyone looked at it, still saying it was waiting.
@Test func aSuspendedTabLearnsItWasUnpairedRatherThanWaitingForEver() throws {
    let f = try ClientFixture()
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.client.handle(f.suspended())
    #expect(isSuspended(attachment.state.phase))            // waiting, as it should be
    f.client.handle(f.presence(hostOnline: false, notPaired: true))
    #expect(attachment.state.phase == .failed(AttachFailure.unpaired))
}

/// The belt to that braces, for the relay that has not been deployed yet and for the host that
/// unpaired us while this Mac's socket was down: the re-attach is answered `not_paired`, and that
/// answer is settled. `retryReattach` waits out `host_offline` and `no_such_session` for a minute
/// because those are races; this one is a decision, and waiting it out spends the whole minute to
/// arrive at "No answer from the host", which is a verdict about the wrong session.
@Test func aReattachRefusedAsNotPairedEndsAtOnceRatherThanRetryingForAMinute() throws {
    let clock = TestClock()
    let f = try ClientFixture(clock: clock)
    let attachment = f.attach()
    try f.acceptAttach()
    f.client.handle(f.host.message(.snapshotEnd(to: f.deviceID, sessionID: f.key)))
    f.client.linkDidDisconnect()
    _ = clock.takeDelays()
    f.client.linkDidReconnect()
    #expect(attachment.state.phase == .reconnecting)

    f.client.handle(f.error("not_paired"))
    #expect(attachment.state.phase == .failed(AttachFailure.unpaired))
}
```

  and to `Tests/NyxCoreTests/RemoteCatalogueTests.swift`:

```swift
/// D1. The relay sends `Name: ""` for a peer it has no live socket for, and `applyPresence` wrote
/// it over the name `setPaired` had put there -- so two sleeping Macs were two identical blank
/// rows, and §5.3's promise of "its name greyed with 'offline'" was a promise about nothing. The
/// comment that a presence name "is the freshest name Nyx has, so it always wins" is right for an
/// online device and wrong for the one case that reaches it every time.
@Test func anOfflinePresenceDoesNotEraseTheNameWeAlreadyHave() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false)])
    #expect(c.devices.first?.name == "Mac mini (office)")
    let rows = c.paletteItems(now: Date())
    #expect(rows.first?.title == "Mac mini (office)")
    #expect(rows.first?.detail == "offline")
    #expect(rows.first?.isEnabled == false)
}

/// A name presence *does* supply still wins: it is the one the other Mac is announcing now.
@Test func anOnlinePresenceNameStillWins() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "old name"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "renamed", online: true)])
    #expect(c.devices.first?.name == "renamed")
}

/// D6/B2 in the palette: a Mac that has removed this one is not a Mac that is asleep, and the row
/// has to stop offering something to press. It keeps the name, because the name is how a person
/// knows *which* Mac to go and re-pair.
@Test func anUnpairedPeerReadsAsUnpairedRatherThanOffline() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyCatalogue(deviceID: "d1", sessions: [session()])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false, notPaired: true)])
    let rows = c.paletteItems(now: Date())
    #expect(rows.count == 1)
    #expect(rows[0].title == "Mac mini (office)")
    #expect(rows[0].detail == "no longer paired with this Mac")
    #expect(rows[0].isEnabled == false)
    // Its sessions go with it: a row you could press was the defect, not the label.
    #expect(c.devices.first?.sessions.isEmpty == true)
}

/// And the flag clears, or the row would stay dead through the next pairing.
@Test func aRepairedPeerComesBackOnline() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "", online: false, notPaired: true)])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    #expect(c.devices.first?.notPaired == false)
    #expect(c.devices.first?.online == true)
}

/// D6's other half, for the relay that cannot say it: the `not_paired` answer to an *attach* is
/// the first thing this Mac hears, and the rows have to go on that too.
@Test func forgettingADeviceTakesItsRowsWithoutUnpairingIt() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)", "d2": "iMac (studio)"])
    c.applyCatalogue(deviceID: "d1", sessions: [session()])
    c.forget(deviceID: "d1")
    #expect(c.devices.count == 1)
    #expect(c.devices.first?.id == "d2")
    // And it is not a re-pair: the next `setPaired` from the same `paired.json` puts the row back
    // as an offline one, which is honest -- this Mac has not removed anything.
    c.setPaired(["d1": "Mac mini (office)", "d2": "iMac (studio)"])
    #expect(c.devices.count == 2)
}
```

  and to `Tests/NyxCoreTests/AttachStateTests.swift`:

```swift
/// D11. `badge` was `role == .writer ? "writer" : "observer"` whatever the phase, so a tab that had
/// ended, failed or been suspended wore a badge that reads as a live one -- the QA found a
/// `phase=ended` tab labelled `observer` and a `phase=suspended` one labelled `writer`, both
/// refusing input. The badge is a tab-bar word about what this tab *is*, so a tab that is nothing
/// says nothing.
@Test func aDeadTabWearsNoRoleBadge() {
    #expect(state(phase: .ended("beta"), role: .writer).badge == nil)
    #expect(state(phase: .failed("Host is offline"), role: .observer).badge == nil)
    // Suspended is not dead -- it is waiting -- and "offline" is the useful word there: the role it
    // will come back with is not what a person wants from a tab whose host has gone.
    #expect(state(phase: .suspended("beta", since: Date()), role: .writer).badge == "offline")
    // And no role has been granted yet while it is attaching, so "observer" there would be the
    // default value showing through rather than an answer.
    #expect(state(phase: .attaching, role: .observer).badge == nil)
    #expect(state(phase: .snapshot, role: .observer).badge == nil)
    // The two that were always right, and the one B1 made worth keeping: a reconnecting tab is
    // coming back to the role it left with (Task 3), so it keeps the word.
    #expect(state(phase: .live, role: .writer).badge == "writer")
    #expect(state(phase: .live, role: .observer).badge == "observer")
    #expect(state(phase: .reconnecting, role: .writer).badge == "writer")
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'RemoteClient|RemoteCatalogue|AttachState' 2>&1 | tail -12`
Expected: compile failures on `forget(deviceID:)` and `notPaired` on `RemoteCatalogue.Device`, then `aHostThatUnpairedUsEndsTheTabInsteadOfSuspendingIt` failing with `.suspended` — which is the honest reading of a dishonest input, and the sentence B2 is about.

- [ ] **Step 3: The catalogue keeps the name and learns the third state.** In `RemoteCatalogue`:

```swift
    public struct Device: Equatable {
        public let id: String
        public var name: String
        public var online: Bool
        /// This device is connected and has removed the pairing with this Mac (`presence`'s
        /// `not_paired`). Deliberately not folded into `online`: "offline" is a wait that ends by
        /// itself and this one never does, and the row has to say which.
        public var notPaired: Bool = false
        public var sessions: [RemoteSessionInfo]
    }
```

```swift
    /// A `presence` message: who is online right now, by name.
    ///
    /// A name presence supplies wins -- it is the one the other Mac is announcing now -- but an
    /// *empty* one does not. The relay sends `Name: ""` for a peer it has no live socket for, so
    /// overwriting unconditionally meant every offline Mac lost its name and two sleeping Macs were
    /// two identical blank rows.
    public mutating func applyPresence(_ devices: [RemotePresence]) {
        for p in devices where pairedIDs.contains(p.deviceID) {
            var device = byID[p.deviceID]
                ?? Device(id: p.deviceID, name: p.name, online: p.online, sessions: [])
            if !p.name.isEmpty { device.name = p.name }
            device.online = p.online && !p.notPaired
            device.notPaired = p.notPaired
            // A host's catalogue is dropped when it disconnects, and a host that has removed this
            // Mac has nothing to offer it either -- the relay would refuse the attach.
            if !device.online { device.sessions = [] }
            byID[p.deviceID] = device
        }
    }
```

```swift
    /// Drops one device's rows without touching `pairedIDs`.
    ///
    /// For the `not_paired` answer to an *attach*: it is the first thing a Mac whose peer unpaired
    /// it while its own socket was down ever hears, and until then its rows sat there enabled,
    /// naming sessions on a Mac that no longer serves it. Not a local unpairing -- this Mac has
    /// removed nothing, and `paired.json` is still the truth about what it has agreed to -- so the
    /// next `setPaired` legitimately puts the device back as an offline row.
    public mutating func forget(deviceID: String) {
        byID[deviceID] = nil
    }
```

  and `paletteItems` gains the row, before the online/offline branch:

```swift
        for device in devices {
            if device.notPaired {
                // Named, because the name is how a person knows which Mac to go and re-pair; and
                // disabled, because pressing it would open a tab whose attach the relay refuses.
                items.append(.remoteSession(deviceID: device.id, sessionID: "",
                                            title: device.name,
                                            detail: "no longer paired with this Mac",
                                            isEnabled: false))
            } else if device.online {
```

  `devices`' sort puts it with the offline ones, which is where it belongs: `online` is false for a
  `notPaired` device by the assignment above, so nothing about the ordering needs a second rule.

- [ ] **Step 4: The client ends rather than waits.** In `RemoteClient.Attachment`:

```swift
        /// The relay's word on whether this attachment's host is connected -- and, since the relay
        /// learned to say it, on whether the pairing still exists.
        ///
        /// `notPaired` is the one presence answer that is *final*. The host has removed this Mac:
        /// the session is running and this Mac may not see it, which is neither "offline" (a wait
        /// that ends when the lid opens) nor "ended" (something that stopped). The sentence has
        /// existed since the feature shipped and was reachable only when this Mac did the removing.
        func handlePresence(online: Bool, notPaired: Bool, now: Date) {
            if notPaired {
                end(reason: AttachFailure.unpaired)
                client?.forget(key)
                return
            }
            lock.lock()
            ...unchanged...
        }
```

  and in `RemoteClient.handle`'s `presence` branch:

```swift
            for device in m.devices ?? [] {
                for attachment in attachments(on: device.deviceID) {
                    attachment.handlePresence(online: device.online, notPaired: device.notPaired,
                                              now: now)
                }
            }
```

  `end(reason:)` already reports `.failed` over anything but an ended phase and marks the attachment
  finished, which is exactly right here: a suspended tab is not ended, so it is told.

  The belt, in `retryReattach` — one line, at the top:

```swift
        private func retryReattach(after code: String) -> Bool {
            // `not_paired` is not a race. Waiting it out spends the whole minute to arrive at "No
            // answer from the host", which is a verdict about a session that was answered plainly
            // the first time. It falls through to `handleError`, which now maps it to the sentence.
            guard code == "host_offline" || code == "no_such_session" else { return false }
```

  (already the case — the guard is there today; what changes is `handleError`'s mapping.) In
  `handleError`:

```swift
        func handleError(code: String) {
            if retryReattach(after: code) { return }
            // `not_paired` from a host means that host removed this Mac, which is a different
            // sentence from `AttachFailure.text(code:)`'s "Not paired with this device" -- that one
            // reads as this Mac's own list being wrong, and the user's own list still has the host
            // in it. The one the round wrote for exactly this is `unpaired`.
            let reason = code == "not_paired" ? AttachFailure.unpaired
                                              : AttachFailure.text(code: code)
            report(if: { self.isAwaitingAttach($0.phase) }) { $0.phase = .failed(reason) }
        }
```

- [ ] **Step 5: The badge stops lying.** In `AttachState`:

```swift
    /// The word beside this tab's title, or nil when there is none.
    ///
    /// It was the role and nothing else, so an ended, failed or suspended tab wore `writer` or
    /// `observer` -- a live-looking word on a tab that refuses every keystroke. The badge answers
    /// what this tab *is*: a role while there is one, "offline" while its host is away, and nothing
    /// at all before a role has been granted or after there is nothing left to have one in.
    public var badge: String? {
        switch phase {
        case .live, .reconnecting: return role == .writer ? "writer" : "observer"
        case .suspended: return "offline"
        case .attaching, .snapshot, .ended, .failed: return nil
        }
    }
```

  and its one consumer, `TabController` (`:67`):

```swift
        var badge: String? { remoteState?.badge ?? nil }
```

  (`remoteState` is itself optional, so the double-optional has to be flattened; `?? nil` reads
  worse than `flatMap(\.badge)` and compiles to the same thing — use whichever the file's
  neighbours look like.)

- [ ] **Step 6: A refused relay stops offering rows, and an attach with no socket refuses.** In `RemoteCoordinator.statusChanged`, the `.failed` branch (`:552`) gains what `.offline` already has:

```swift
        if case .failed(let code) = status {
            client?.endAll(reason: AttachFailure.relayRefused(code))
            // The same two lines the `.offline` branch has, and for a stronger reason: `.failed`
            // does not come back without a `connect()`, so everything the other Macs told us is
            // not merely stale, it is the last thing we will ever hear. Two copies of Nyx sharing
            // one config directory reach this by accident -- the second takes the identity, the
            // first is `replaced` -- and the first went on offering enabled rows for the other
            // Mac's sessions, then opened a tab that sat at "Attaching…" for sixty seconds and
            // blamed the host: "No answer from the host", about a Mac that answered nothing
            // because *this* one has no socket.
            catalogue = RemoteCatalogue()
            catalogue.setPaired(paired.namesByID)
        }
```

  and `attach` (`:246`) refuses when there is nothing to attach over:

```swift
    func attach(deviceID: String, sessionID: String, hostName: String, title: String) -> RemoteClient.Outcome? {
        guard let client, let bytes = RemoteID.bytes(base64url: sessionID), bytes.count == 16 else {
            return nil
        }
        // A relay that has refused this device will not carry the `attach`. nil is what the palette
        // treats as "this row cannot act" -- it beeps and stays open, which is the honest answer --
        // rather than opening a tab that spends a minute waiting and then names the wrong Mac.
        if case .failed = connection?.status { return nil }
        return client.attach(hostID: deviceID, hostName: hostName, sessionID: bytes, title: title)
    }
```

  and the `not_paired` answer drops that host's rows, in `received`'s `error` branch, beside the
  routing that is already there:

```swift
        case "error":
            // A host that has removed this Mac answers every attach the same way for ever, and its
            // rows sat in ⌘⇧P enabled the whole time: the relay only broadcasts presence to
            // *mutually* paired peers, so the removed side is the one side that is never told.
            // Task 1 makes the relay say it; this is what a Mac hears from a relay that cannot, and
            // from a host that unpaired it while this Mac's socket was down.
            if message.code == "not_paired", let hostID = message.to {
                catalogue.forget(deviceID: hostID)
                onChange?()
            }
            if message.sessionID == nil, pairing != nil {
                ...unchanged...
```

- [ ] **Step 7: Run the tests and the ladder's first three rungs**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
make bench
```
Expected: `0` warnings, PASS, bench ≥ 180 MB/s. `RemoteCatalogueTests` and `CommandPaletteTests` are
the two files most likely to have an expectation that assumed the old name rule; fix the
expectation, not the rule, and say which in the commit message.

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxRemote/RemoteClient.swift Sources/NyxCore/Remote/RemoteCatalogue.swift \
        Sources/NyxCore/Remote/AttachState.swift Sources/NyxApp/RemoteCoordinator.swift \
        Sources/NyxApp/TabController.swift Tests/NyxRemoteTests/RemoteClientTests.swift \
        Tests/NyxCoreTests/RemoteCatalogueTests.swift Tests/NyxCoreTests/AttachStateTests.swift
git commit -m "$(cat <<'EOF'
A Mac that unpaired you is not a Mac that is asleep

"beta has been offline since 21:17 — waiting for it to come back", said the tab, while beta sat
online two windows away: the pairing had been removed from the other side, the relay could only
report a non-mutual peer as offline-with-no-name, and `.suspended` was the honest reading of a
dishonest input. With `not_paired` on the wire the tab reaches
`AttachFailure.unpaired` -- a sentence that has existed since the feature shipped and was reachable
only when this Mac did the removing -- and so does a re-attach the relay refuses, which used to
spend a minute arriving at "No answer from the host" instead.

Three smaller lies with it. An offline Mac keeps its name (the relay sends `Name: ""` for a peer it
cannot reach and the catalogue wrote it over the one it had, so two sleeping Macs were two identical
blank rows). A relay that has *refused* this device empties the catalogue and refuses an attach, so
two copies of Nyx sharing a config directory stop offering the first one working-looking rows into a
tab that blames the other Mac. And a tab that has ended, failed or been suspended stops wearing a
`writer`/`observer` badge that reads as a live one.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: The palette and the log — rows you can read and press, and a log with names in it

**Files:**
- Modify: `Sources/NyxCore/Remote/RemoteCatalogue.swift` — `detail`'s order, `shortCommand`, the relay-status row's kind
- Modify: `Sources/NyxCore/Palette/CommandPalette.swift` — `moveSelection` and `rank` skip rows that cannot act
- Modify: `Sources/NyxCore/Remote/AuditLine.swift` — `AuditLine.display(_:now:)`
- Modify: `Sources/NyxApp/TabController.swift` — `showRemoteSessions` opens the Remote rows, not the whole palette with a query
- Modify: `Sources/NyxApp/RemoteCoordinator.swift` — `namesOfRemovedDevices` reaches `appendAudit`
- Modify: `Sources/NyxApp/SettingsWindowController.swift` — `setActivityText` (`:429-432`) renders through `AuditLine.display`
- Test: `Tests/NyxCoreTests/RemoteCatalogueTests.swift`, `Tests/NyxCoreTests/CommandPaletteTests.swift`, `Tests/NyxCoreTests/AuditLineTests.swift` (**extended** — it exists, 35 lines, six tests pinning `AuditLine.text`'s six formats, which `everyEventTextRoundTripsThroughDisplay` below depends on)

**Interfaces:**
- Consumes (Task 4): `RemoteCatalogue.Device.notPaired` and its palette row, which this task's ordering and selection rules also apply to.
- Consumes (already in the tree): `RelativeAge.text(from:to:)`, `PaletteItem.isEnabled`, `PaletteItem.action(_:chord:)`, `TerminalAction.openConfig`, `AuditNames.naming(_:names:titles:)`, `AppDelegate.openRemoteSettings(_:)`, `TabController.openPalette(items:)`.
- Produces:

```swift
public extension AuditLine {
    /// One line of `audit.log` as the Remote page shows it: the same words, with the ISO-8601
    /// timestamp replaced by a relative age.
    static func display(_ line: String, now: Date) -> String
}
public extension RemoteCatalogue {
    /// A last command, cut to something a row can hold.
    static func shortCommand(_ command: String, limit: Int = 40) -> String
}
public extension CommandPalette {
    /// The first row `⏎` could actually run, or nil.
    var selected: PaletteItem? { get }      // unchanged signature; now never a disabled row
}
```

- [ ] **Step 1: Write the failing tests.** Appended to `Tests/NyxCoreTests/RemoteCatalogueTests.swift`:

```swift
/// D10. The detail put the unbounded last command in front of the age, so the age -- the field a
/// person uses to choose between two Macs -- is the one the label cut off. The QA's row read
/// `~ · running: zsh · last: for i in $(seq 1 2000); do echo "host scrollback line $i of two
/// thousand"; done · 9 min ago`, and in the picture the age was simply gone.
@Test func theAgeComesBeforeTheLastCommandAndTheCommandIsCutInCore() throws {
    let long = "for i in $(seq 1 2000); do echo \"host scrollback line $i of two thousand\"; done"
    let s = session(cwd: "/home/nik", process: "zsh", lastCommand: long,
                    lastActivity: "2026-09-05T11:58:00Z")
    let text = RemoteCatalogue.detail(for: s, now: now, home: "/home/nik")
    #expect(text == "~ · running: zsh · 2 min ago · last: "
        + RemoteCatalogue.shortCommand(long))
    // The age is in front of the one clause that has no length limit, and the command carries the
    // ellipsis that says it was longer -- so a row cut by the label loses the tail of a command
    // rather than the answer to "when was this last touched".
    let age = try #require(text.range(of: "2 min ago"))
    let command = try #require(text.range(of: "last:"))
    #expect(age.lowerBound < command.lowerBound)
    #expect(text.hasSuffix("…"))
}

@Test func aShortCommandIsNotTouched() {
    #expect(RemoteCatalogue.shortCommand("make test") == "make test")
    #expect(RemoteCatalogue.shortCommand(String(repeating: "x", count: 40)).count == 40)
    #expect(RemoteCatalogue.shortCommand(String(repeating: "x", count: 41)).hasSuffix("…"))
    #expect(RemoteCatalogue.shortCommand(String(repeating: "x", count: 41)).count == 40)
}

/// D4. The relay-status row was the one row in the palette that named the user's problem, and it
/// was disabled -- so searching for the problem gave exactly one row, selected, and ⏎ beeped with
/// the panel still open. It is a verb now: the field it is about is on Settings → Remote.
@Test func theRelayStatusRowOpensSettings() {
    var c = RemoteCatalogue()
    c.setPaired([:])
    c.relayStatusText = "Relay unreachable (nyx.agentforge.cc)"
    let rows = c.paletteItems(now: now)
    #expect(rows.count == 1)
    #expect(rows[0].title == "Relay unreachable (nyx.agentforge.cc)")
    #expect(rows[0].detail == "Settings…")
    #expect(rows[0].isEnabled)
    #expect(rows[0].kind == .action(.openConfig))
    // Still findable by the words a person would type about it.
    #expect(rows[0].searchText.contains("remote"))
}

/// And every other Remote row stays what it was: a session to attach to, or a placeholder that
/// cannot act. Only the status row is a verb about the settings page.
@Test func aSessionRowIsStillASessionRow() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session()])
    #expect(c.paletteItems(now: now)[0].kind == .remoteSession(deviceID: "d1", sessionID: "s1"))
}
```

  to `Tests/NyxCoreTests/CommandPaletteTests.swift`:

```swift
/// D4, the other half. A greyed row was selectable, drawn highlighted, and the thing ⏎ hit: on the
/// wrong-token instance the *only* row was disabled, so ↓ could not leave it either and every ⏎
/// beeped with the panel still open. A palette is a list of verbs; a row that is not one is a
/// landmark, not a destination.
@Test func aDisabledRowIsNeverTheSelection() {
    let items = [
        PaletteItem(title: "iMac (studio)", detail: "offline", kind: .remoteSession(deviceID: "d1", sessionID: ""),
                    isEnabled: false),
        PaletteItem(title: "Mac mini · zsh", detail: "~", kind: .remoteSession(deviceID: "d2", sessionID: "s1")),
        PaletteItem(title: "Mac pro · zsh", detail: "~", kind: .remoteSession(deviceID: "d3", sessionID: "s2")),
    ]
    var p = CommandPalette(items: items)
    #expect(p.selection == 1)
    #expect(p.selected?.title == "Mac mini · zsh")
    p.moveSelection(by: 1)
    #expect(p.selection == 2)
    // Wrapping still wraps -- past the end, round the front, and *over* the disabled row.
    p.moveSelection(by: 1)
    #expect(p.selection == 1)
    p.moveSelection(by: -1)
    #expect(p.selection == 2)
}

/// A list with nothing runnable in it keeps its selection on the first row rather than inventing
/// one: the rows are still worth showing (they are the explanation for the section being empty),
/// and `selected` says there is nothing to run, which is what makes ⏎ a beep instead of an act.
@Test func aListOfOnlyDisabledRowsSelectsTheFirstAndRunsNothing() {
    var p = CommandPalette(items: [
        PaletteItem(title: "Relay rejected this device's token", detail: "",
                    kind: .remoteSession(deviceID: "", sessionID: ""), isEnabled: false),
    ])
    #expect(p.selection == 0)
    #expect(p.selected == nil)
    p.moveSelection(by: 1)
    #expect(p.selection == 0)
}

/// And typing lands on the best row that can act, not on the best row.
@Test func narrowingSkipsToTheFirstRunnableMatch() {
    var p = CommandPalette(items: [
        PaletteItem(title: "relay unreachable", detail: "", kind: .remoteSession(deviceID: "", sessionID: ""),
                    isEnabled: false),
        PaletteItem(title: "relay settings", detail: "", kind: .action(.openConfig)),
    ])
    p.setQuery("relay")
    #expect(p.selected?.title == "relay settings")
}
```

  and appended to the **existing** `Tests/NyxCoreTests/AuditLineTests.swift` — it already holds six
  tests for `AuditLine.text`'s six formats, and `everyEventTextRoundTripsThroughDisplay` below is
  only meaningful while they are there. Its imports are already these two; `private let now` does
  not collide with its `private let date`:

```swift
private let now = ISO8601DateFormatter().date(from: "2026-09-10T18:20:00Z")!

/// §7.4 and D15: the Remote page's "Recent activity" was the file, verbatim --
/// `2026-09-01T10:00:00Z  paired  Nik's MacBook Pro` -- which is the right format for `tail -f` and
/// the wrong one for a box six lines tall on a settings page. The words do not change; the stamp
/// becomes the age, from the same `RelativeAge` the palette's Requests rows use, so one application
/// cannot describe the same moment two ways.
@Test func anAuditLineIsShownWithARelativeAge() {
    #expect(AuditLine.display("2026-09-10T18:16:12Z  removed  alpha", now: now)
        == "3 min ago  removed  alpha")
    #expect(AuditLine.display("2026-09-10T18:19:50Z  attached  alpha → zsh — ~", now: now)
        == "just now  attached  alpha → zsh — ~")
    #expect(AuditLine.display("2026-09-01T10:00:00Z  paired  Nik's MacBook Pro", now: now)
        == "9 days ago  paired  Nik's MacBook Pro")
}

/// A line whose head is not a timestamp is passed through untouched. The file is plain text a
/// person may have opened in an editor, and a page that swallowed a line it did not recognise would
/// be hiding the one line worth reading.
@Test func aLineWithoutATimestampIsLeftAlone() {
    #expect(AuditLine.display("not a log line at all", now: now) == "not a log line at all")
    #expect(AuditLine.display("", now: now) == "")
}

/// The round trip, so the two halves cannot drift: whatever `text` writes, `display` reads.
@Test func everyEventTextRoundTripsThroughDisplay() {
    let at = ISO8601DateFormatter().date(from: "2026-09-10T18:19:00Z")!
    for event: AuditLine.Event in [.paired("beta"), .removed("beta"),
                                   .attached(device: "beta", session: "zsh"),
                                   .tookControl(device: "beta", session: "zsh"),
                                   .detached(device: "beta", session: "zsh"),
                                   .sessionEnded(session: "zsh")] {
        let shown = AuditLine.display(AuditLine.text(event, at: at), now: now)
        #expect(shown.hasPrefix("1 min ago  "), "\(event) -> \(shown)")
        #expect(!shown.contains("2026-"))
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'RemoteCatalogue|CommandPalette|AuditLine' 2>&1 | tail -12`
Expected: `cannot find 'AuditLine.display'`, `no member 'shortCommand'`, and — once those compile —
`aDisabledRowIsNeverTheSelection` failing at `p.selection == 1`, because `rank()` sets it to 0 and
knows nothing about `isEnabled`.

- [ ] **Step 3: The row, the order, the cut, and the line the page reads.** In `AuditLine`, the one
      function the Remote page renders the log through:

```swift
    /// One line of `audit.log` as the Remote page shows it: the same words, with the ISO-8601
    /// timestamp replaced by a relative age.
    ///
    /// The file's format is `tail -f`'s and stays that way -- a sortable absolute stamp is right for
    /// a log somebody greps, and wrong for a box six lines tall on a settings page, where
    /// `2026-09-01T10:00:00Z  paired  Nik's MacBook Pro` is nine characters of information in
    /// thirty-one. Only the head is touched; everything after it is preserved byte for byte,
    /// including the two spaces `text(_:at:)` writes, so the two halves cannot drift into two
    /// formats. A line whose head is not a timestamp -- a file somebody has edited, an empty line --
    /// passes through untouched, because a page that swallowed the line it did not recognise would
    /// be hiding the one line worth reading.
    public static func display(_ line: String, now: Date) -> String {
        guard let head = line.split(separator: " ", maxSplits: 1).first,
              let at = ISO8601DateFormatter().date(from: String(head)) else { return line }
        return RelativeAge.text(from: at, to: now) + line.dropFirst(head.count)
    }
```

  and in `RemoteCatalogue`:

```swift
    /// A last command, cut to something a row can hold.
    ///
    /// It is the one clause of the detail with no bound: a `for` loop pasted into a shell is
    /// eighty characters and pushed everything after it off the row -- including the age, which is
    /// the field a person actually chooses between two Macs with. Cut here rather than by the
    /// label, so the row's own text says the command was longer.
    public static func shortCommand(_ command: String, limit: Int = 40) -> String {
        guard command.count > limit else { return command }
        return String(command.prefix(limit - 1)) + "…"
    }
```

```swift
    public static func detail(for s: RemoteSessionInfo, now: Date, home: String = "") -> String {
        var head = shortenedCwd(s.cwd, home: home)
        if !s.branch.isEmpty {
            head = head.isEmpty ? s.branch : "\(head)  \(s.branch)"
        }
        var tail: [String] = []
        if !s.process.isEmpty { tail.append("running: \(s.process)") }
        // The age *before* the last command, which is the one clause that can be any length. "When
        // was this last touched" is what a person picks a Mac by, and it was what disappeared.
        let rel = relative(s.lastActivity, now: now)
        if !rel.isEmpty { tail.append(rel) }
        if !s.lastCommand.isEmpty { tail.append("last: \(shortCommand(s.lastCommand))") }
        guard !tail.isEmpty else { return head }
        return head.isEmpty ? tail.joined(separator: " · ") : "\(head) · \(tail.joined(separator: " · "))"
    }
```

  and the status row becomes something to press:

```swift
        if let status = relayStatusText {
            // A verb, not a label. It is the one row in the whole palette that names the user's
            // actual problem -- a bad token, an unreachable relay -- and as a disabled row it was
            // the row that beeped: on the wrong-token instance it was the *only* row, so ↓ could
            // not leave it and ⏎ did nothing with the panel still open. Everything it is about is
            // on Settings → Remote, which `.openConfig` opens.
            items.append(PaletteItem(title: status, detail: "Settings…",
                                     searchText: "\(status) remote relay settings",
                                     kind: .action(.openConfig)))
        }
```

- [ ] **Step 4: The selection is a row that can act.** In `CommandPalette`:

```swift
    /// ↑/↓. Wraps at both ends, and steps over rows that cannot act.
    ///
    /// A palette is a list of verbs. The Remote section has three rows that are not -- a Mac that
    /// is asleep, a Mac with nothing open, a Mac that unpaired this one -- and they belong in the
    /// list, because a paired Mac missing from it reads as a broken pairing. Drawn like the rest and
    /// *selectable* like the rest, they were rows people pressed and got a beep from, and the
    /// highlight told them to.
    public mutating func moveSelection(by delta: Int) {
        guard !results.isEmpty else {
            selection = 0
            return
        }
        let count = results.count
        var next = ((selection + delta) % count + count) % count
        let step = delta >= 0 ? 1 : -1
        // At most one lap: a list with nothing runnable in it keeps the selection it had rather
        // than spinning.
        for _ in 0..<count {
            if results[next].item.isEnabled { break }
            next = ((next + step) % count + count) % count
        }
        guard results[next].item.isEnabled else { return }
        selection = next
    }

    private mutating func rank() {
        let ranked = FuzzySearch.rank(query, items, by: \.searchText)
        results = ranked.map { item, match in
            PaletteResult(item: item, positions: match.positions.filter { $0 < item.title.count })
        }
        // Typing narrows the list under whatever was selected, so the selection goes back to the
        // best answer -- the best *runnable* answer, since ⏎ is what it is for.
        selection = results.firstIndex { $0.item.isEnabled } ?? 0
    }
```

  `selected` gains one guard, so a list of only-disabled rows answers honestly:

```swift
    /// The row `⏎` runs, or nil when nothing matched -- or when nothing that matched can act.
    public var selected: PaletteItem? {
        guard results.indices.contains(selection), results[selection].item.isEnabled else {
            return nil
        }
        return results[selection].item
    }
```

  The beep still happens and now comes from one line earlier:
  `CommandPaletteView.swift:309` is `if let item = model.selected { onRun?(item) } else { NSSound.beep() }`,
  and `selected` is nil for a disabled row, so `TabController.run(_:)`'s own
  `guard item.isEnabled` is never reached. The behaviour is what the tests promise — a beep, the
  panel still open — but the guard in `run` is now belt to that braces rather than the thing doing
  it, and should say so in a comment rather than being deleted. `CommandPaletteView` draws
  `selection`'s row highlighted, so a disabled row can no longer be the highlighted one either,
  which is the picture D4 complained about (`command-palette-remote.png`).

- [ ] **Step 5: The menu route opens sessions, not the palette again.** In `TabController`:

```swift
    /// `remote_sessions`: the palette showing **only** the Remote section.
    ///
    /// It used to open the whole palette with "remote" typed into it, and the action's own row --
    /// `Remote Sessions…`, whose search text contains the word -- outranked every session for that
    /// query. So the keyboard route to a remote session was menu, ↓, ⏎, and pressing ⏎ first (the
    /// obvious thing) re-opened the same panel with the same query. There is nothing to rank here:
    /// the list is what the action is named after, plus the one thing to do when it is empty.
    func showRemoteSessions() {
        closeCommandPalette()
        var items = appDelegate?.remote?.paletteItems() ?? []
        // Pairing is the honest next row for a Mac with no paired devices yet, and harmless
        // otherwise: it is the other half of what this feature needs before it works at all.
        if canPerform(.remotePair) {
            items.append(PaletteItem.action(.remotePair, chord: chordFor(.remotePair)))
        }
        openPalette(items: items)
    }
```

  There is no `chordFor`: the chord comes from the same table `toggleCommandPalette` builds
  (`TabController.swift:866`), so the line is
  `PaletteItem.action(.remotePair, chord: KeyBindingTable(user: config.keybinds).binding(for: .remotePair)?.displayName)`
  — written out, or hoisted into the small helper both call sites then share. Read `:866` and match
  it; a second spelling of "which chord is this action on" is how two answers appear.

- [ ] **Step 6: The page reads the log, and Remove keeps the name.** In `SettingsWindowController.setActivityText`:

```swift
    private func setActivityText(lines: [String]) {
        let now = Date()
        let shown = lines.map { AuditLine.display($0, now: now) }
        activityView.string = shown.isEmpty ? "No remote activity yet" : shown.joined(separator: "\n")
        activityView.textColor = shown.isEmpty ? .tertiaryLabelColor : .labelColor
    }
```

  and in `RemoteCoordinator`, the name of a device Remove has just taken out:

```swift
    /// Names of devices unpaired in this run, kept so an audit line raised *by* the unpairing still
    /// has one.
    ///
    /// `AuditNames` falls back to an eight-character id prefix, which is right for a device nobody
    /// ever named and wrong for the one path that reaches it every single time: Remove takes the
    /// name out of `paired`, and the detach it raises is audited on the main queue afterwards --
    /// `RemoteHost` hops it there deliberately, so no amount of reordering inside `removePairing`
    /// can make the name still be there. The QA's log says `detached  8hgFMxB9 → zsh — ~` one
    /// second after `removed  alpha`, about the same Mac.
    private var namesOfRemovedDevices: [String: String] = [:]
```

```swift
    private func appendAudit(_ event: AuditLine.Event) {
        refreshSessionTitles()
        let names = paired.namesByID.merging(namesOfRemovedDevices) { current, _ in current }
        let named = AuditNames.naming(event, names: names, titles: sessionTitles)
        ...unchanged...
```

  The dictionary is written in Task 3 Step 7 and only grows by one entry per Remove, which is a
  pairing a person made by hand: it is not a cache that needs evicting.

- [ ] **Step 7: Run the tests and take the palette pictures**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/nyx-6-palette ./build/Nyx.app/Contents/MacOS/Nyx
```
Expected: `0` warnings, PASS. Then **look at** `command-palette-remote-*.png` — the greyed rows must
no longer be the highlighted one, and the relay row must read as something to press —
`command-palette-mixed-remote-*.png` (the long row now ends in a cut command and keeps its age) and
`settings-remote-{light,dark}.png` (Recent activity in relative ages). `RemoteCatalogueTests`'
`theDetailStringMatchesTheDesignExample` is the one existing test whose expectation moves: update
the string, and say in the commit message that the clause order changed.

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxCore/Remote/RemoteCatalogue.swift Sources/NyxCore/Palette/CommandPalette.swift \
        Sources/NyxCore/Remote/AuditLine.swift Sources/NyxApp/TabController.swift \
        Sources/NyxApp/RemoteCoordinator.swift Sources/NyxApp/SettingsWindowController.swift \
        Tests/NyxCoreTests/RemoteCatalogueTests.swift Tests/NyxCoreTests/CommandPaletteTests.swift \
        Tests/NyxCoreTests/AuditLineTests.swift
git commit -m "$(cat <<'EOF'
The row that names the problem is the row you can press

A palette is a list of verbs, and the Remote section's greyed rows were selectable, drawn
highlighted, and what ⏎ hit. On the instance with a wrong token that was the whole panel: one row,
`Relay rejected this device's token`, selected, and every ⏎ a beep with the panel still open — the
row that named the user's problem was the row that refused to do anything about it. ↑/↓ step over a
row that cannot act, `rank` selects the best *runnable* match, and the relay-status row is now a
verb: it opens Settings → Remote, where the field it is about lives.

Two other routes that went nowhere. `Shell → Remote Sessions…` opened the whole palette with
"remote" typed in, and the action's own row outranked every session for that query, so the keyboard
route to a remote session was menu, ↓, ⏎ — it opens the Remote rows themselves now, plus `Pair with
Another Device…` when there is nothing to list. And a remote row's detail put the unbounded last
command in front of the age, so the age — the field a person chooses between two Macs by — was what
the label cut off; the age goes first and the command is cut in Core, with the ellipsis that says it
was longer.

Recent activity on the Remote page stops being an ISO-8601 dump: `AuditLine.display` keeps the words
and swaps the stamp for `RelativeAge`, the same value the palette's Requests rows use. And Remove
stops writing a raw device id into the log — the name is kept past the unpairing, because the detach
that unpairing raises is audited on the main queue afterwards, when `paired` no longer has it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: The settings fields commit, and the config file is read the way it is written

**Wave 4's task 1 and 2, pulled forward** (spec §5.1 items 1–2, ruling (3) in `decisions.md`): the
relay token is the one field this whole feature depends on and it is always *pasted*, so a window
that throws a paste away is a window that makes remote sessions look broken. Nothing else in this
plan can be tested by hand until it lands.

**Files:**
- Modify: `Sources/NyxApp/SettingsWindowController.swift` — `sendsActionOnEndEditing`, `controlTextDidEndEditing`, the close observer, `commitEdits()`
- Modify: `Sources/NyxApp/ConfigStore.swift` — a watch on the config file itself, re-armed on `.delete`/`.rename`
- Modify: `Sources/NyxCore/Config/ConfigGrammar.swift` — `scalarKeys`, `key(ofLine:)`
- Modify: `Sources/NyxCore/Config/ConfigParser.swift` — `defaultsForKeysAbsent`
- Modify: `Sources/NyxCore/Config/ConfigWriter.swift` — every result ends with one newline
- Test: `Tests/NyxCoreTests/ConfigTests.swift`, `Tests/NyxCoreTests/ConfigWriterTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks. This one is independent of Tasks 1–5 and could run first; it
  is here because the tasks before it are what a person will look at, and this is what lets them.
- Consumes (already in the tree): `Config.defaultFileText`, `ConfigGrammar.lines(_:)`,
  `ConfigParser.parse(_:base:)`, `ConfigStore.write(_:)`, `DispatchSourceFileSystemObject`.
- Produces:

```swift
enum ConfigGrammar {
    /// Every key whose default-file line is a plain scalar `# key = value`.
    static let scalarKeys: [String]
    /// The key a line sets, commented or not, or nil for a blank line or a prose comment.
    static func key(ofLine line: some StringProtocol) -> String?
}
public extension ConfigParser {
    // signature unchanged; `base` now applies only to keys the file still mentions
    static func parse(_ text: String, base: Config = .defaults) -> (config: Config, diagnostics: [ConfigDiagnostic])
}
public extension ConfigWriter {
    // signatures unchanged; every returned text ends with exactly one "\n"
}
```

- [ ] **Step 1: Write the failing Core tests.** Appended to `Tests/NyxCoreTests/ConfigTests.swift`:

```swift
/// D13. The reload parses on top of the config in force, which is right for a line that is present
/// and unparseable -- the field keeps what it had while somebody is mid-edit -- and wrong for a
/// line that is *gone*. Deleting `remote-relay-token` is the gesture a person makes to take a Mac
/// off the relay, and it did nothing until the app was restarted, with the settings page still
/// showing the token as the field's value.
@Test func aKeyDeletedFromTheFileGoesBackToItsDefault() {
    let (before, _) = ConfigParser.parse("remote = on\nremote-relay-token = secret\npadding = 20")
    #expect(before.remoteRelayToken == "secret")
    #expect(before.padding == 20)
    // The same file with the token line removed, parsed on top of what is in force.
    let (after, diagnostics) = ConfigParser.parse("remote = on\npadding = 20", base: before)
    #expect(after.remoteRelayToken == Config.defaults.remoteRelayToken)
    #expect(after.padding == 20)                  // the line that is still there still wins
    #expect(after.remote == .on)
    #expect(diagnostics.isEmpty)
}

/// And the rule it must not break, which is why `base` exists at all: a line that is *present* and
/// unparseable keeps the value in force. A person typing `font-size = 1` and then `font-size = 13`
/// passes through `font-size = ` and must not lose their font on the way.
@Test func anUnparseableLineStillKeepsTheValueInForce() {
    var base = Config.defaults
    base.fontSize = 18
    let (after, diagnostics) = ConfigParser.parse("font-size = enormous", base: base)
    #expect(after.fontSize == 18)
    #expect(diagnostics.count == 1)
}

/// An empty file is every key back to its default, which is what an empty file says.
@Test func anEmptyFileIsTheDefaults() {
    var base = Config.defaults
    base.remoteRelayToken = "secret"
    base.padding = 20
    #expect(ConfigParser.parse("", base: base).config == Config.defaults)
}

/// The additive keys were already handled this way and must stay that way: `keybind`, `palette` and
/// `quick` start empty on every parse, because parsing *appends* to them.
@Test func theAdditiveKeysStillStartEmpty() {
    let (before, _) = ConfigParser.parse("keybind = cmd+t=new_tab\nquick = A | send | echo a")
    #expect(before.keybinds.count == Config.defaults.keybinds.count + 1)
    let (after, _) = ConfigParser.parse("padding = 4", base: before)
    #expect(after.keybinds.count == Config.defaults.keybinds.count)
    #expect(after.quickActions.isEmpty)
}

/// The list `defaultsForKeysAbsent` re-applies from is the list the round-trip test uses, and it
/// now lives in the product rather than in this file -- so the four keys the private copy was
/// missing (`shell-integration`, `multiline-paste`, `fold-keep-lines`, `fold-long-output`) are
/// covered by both at once.
@Test func everyScalarKeyIsDocumentedAtItsCompiledDefault() {
    for key in ConfigGrammar.scalarKeys {
        #expect(Config.defaultFileText.contains("# \(key) ="), "no default line for \(key)")
    }
    #expect(ConfigGrammar.scalarKeys.contains("shell-integration"))
    #expect(ConfigGrammar.scalarKeys.contains("fold-keep-lines"))
    #expect(ConfigGrammar.scalarKeys.contains("fold-long-output"))
    #expect(ConfigGrammar.scalarKeys.contains("multiline-paste"))
    // The additive three are deliberately not in it: their line is an example, and uncommenting it
    // adds an entry, which can never equal `Config.defaults`'s empty collections.
    for key in ["palette", "keybind", "quick"] {
        #expect(!ConfigGrammar.scalarKeys.contains(key))
    }
}

@Test func aLinesKeyIsReadWhetherOrNotItIsCommented() {
    #expect(ConfigGrammar.key(ofLine: "font-size = 13") == "font-size")
    #expect(ConfigGrammar.key(ofLine: "  font-size = 13  ") == "font-size")
    #expect(ConfigGrammar.key(ofLine: "# font-size = 13") == "font-size")
    #expect(ConfigGrammar.key(ofLine: "#font-size = 13") == "font-size")
    #expect(ConfigGrammar.key(ofLine: "# --- Font ---") == nil)
    #expect(ConfigGrammar.key(ofLine: "# Every setting below is shown at its default") == nil)
    #expect(ConfigGrammar.key(ofLine: "") == nil)
}
```

  and, to `Tests/NyxCoreTests/ConfigWriterTests.swift`:

```swift
/// The owner's config file gained `remote = onremote-relay-token = …` on 2026-09-07. The writer
/// returned text with no trailing newline, so the very next thing appended to that file by any
/// other means -- `cat token >> ~/.config/nyx/config`, which is the documented way to set the
/// token -- glued itself onto the last line. One newline, exactly one, on every result.
@Test func everyWrittenFileEndsWithExactlyOneNewline() {
    for text in ["", "font-size = 13", "font-size = 13\n", "font-size = 13\n\n\n",
                 Config.defaultFileText] {
        let out = ConfigWriter.setting("padding", to: "16", in: text)
        #expect(out.hasSuffix("\n"), "no trailing newline for \(text.debugDescription)")
        #expect(!out.hasSuffix("\n\n"), "more than one for \(text.debugDescription)")
        // Idempotent, because `settings` reduces over `setting`: a second pass must not grow it.
        #expect(ConfigWriter.setting("padding", to: "16", in: out) == out)
    }
}

@Test func aListWriteEndsTheSameWay() {
    let out = ConfigWriter.settingList("quick", values: ["A | send | echo a"], in: "padding = 4")
    #expect(out.hasSuffix("\n"))
    #expect(!out.hasSuffix("\n\n"))
}

/// And the parser does not need one, which is the other half of the finding: a file somebody else
/// wrote, or an older Nyx wrote, still parses.
@Test func aFileWithNoTrailingNewlineParses() {
    #expect(ConfigParser.parse("remote = on\nremote-relay = wss://r/v1/ws").config.remote == .on)
    #expect(ConfigParser.parse("padding = 12").config.padding == 12)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'Config' 2>&1 | tail -12`
Expected: `cannot find 'ConfigGrammar.scalarKeys'`; once it exists,
`aKeyDeletedFromTheFileGoesBackToItsDefault` fails with `secret` still in force and
`everyWrittenFileEndsWithExactlyOneNewline` fails on every one of its five inputs.

- [ ] **Step 3: The grammar knows its keys, the parser re-applies a deleted one, and the writer ends the file.** In `ConfigGrammar`:

```swift
    /// Every key whose line in `Config.defaultFileText` is a plain scalar `# key = value`, so that
    /// uncommenting exactly that one line reproduces `Config.defaults`.
    ///
    /// It is the product's list, not a test's: `ConfigParser.defaultsForKeysAbsent` re-applies a
    /// missing key's default *from that documented line*, so a key absent from here is a key a user
    /// can delete from their file and not get back until they restart. `palette`, `keybind` and
    /// `quick` are excluded because they are additive -- a file may hold any number of each, so
    /// their line is necessarily an example rather than "the default", and parsing appends.
    static let scalarKeys = [
        "font-family", "font-size", "line-height", "font-thicken", "theme", "cursor-style",
        "cursor-blink", "scrollback-lines", "padding", "background-opacity", "background-blur",
        "window-decorations", "tab-bar", "shell", "working-directory", "copy-on-select",
        "middle-click-paste", "option-as-meta", "mouse-scroll-alt-screen", "bell",
        "confirm-close-process", "restore-session", "clipboard-read", "word-separators",
        "open-file-command", "shell-integration", "multiline-paste", "fold-keep-lines",
        "fold-long-output", "remote", "remote-device-name", "remote-relay", "remote-relay-token",
        "remote-snapshot-lines", "http-lens", "http-hint", "http-watch-interval", "http-history",
    ]

    /// The key a line sets, whether or not it is commented out, or nil for a blank line, a heading
    /// (`# --- Font ---`) or a sentence of prose.
    ///
    /// One `#` is stripped, with or without the space after it, because that is how the shipped
    /// file writes a documented default; a line whose head is not `key =` is not a setting.
    static func key(ofLine line: some StringProtocol) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard let eq = text.firstIndex(of: "=") else { return nil }
        let key = text[text.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" "), key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return nil }
        return key
    }
```

  (`scalarKeys` replaces the private `scalarDefaultFileKeys` at the top of `ConfigTests.swift`;
  point `theDefaultFileTextParsesBackToTheDefaults` at `ConfigGrammar.scalarKeys` and delete the
  test-local copy. That test is what proves the re-applied defaults are the compiled ones, and with
  the four extra keys in the list it now proves it for them too — **if it fails for one of them, the
  documented default has drifted from the compiled one; fix `Config.defaultFileText`, because the
  file is what a user reads, and say which line moved in the commit message.** Checked while
  writing this plan: `shell-integration = auto`, `multiline-paste = edit`, `fold-keep-lines = 3` and
  `fold-long-output = 0` all match `Config`'s stored defaults today, so this should be green.)

  In `ConfigParser`:

```swift
    public static func parse(_ text: String,
                             base: Config = .defaults) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        applying(text, to: defaultsForKeysAbsent(from: text, in: base))
    }

    /// `base` with every key the file does not mention put back to its default.
    ///
    /// Starting from `base` alone is right for a line that is present and unparseable -- the field
    /// keeps what it had while somebody is typing -- and wrong for a line that is *gone*: deleting
    /// `remote-relay-token` is how a person takes a Mac off the relay, and it did nothing while Nyx
    /// ran, with the settings page still showing the token as the field's value.
    ///
    /// The defaults are re-applied as *text*, from the commented line each key has in
    /// `Config.defaultFileText`, rather than from a second copy of every field: a copy would be a
    /// list to keep in step with the switch below, and the list that drifts is the one nobody
    /// notices. `applying`, not `parse`, or this would recurse through its own synthesised text.
    private static func defaultsForKeysAbsent(from text: String, in base: Config) -> Config {
        guard base != .defaults else { return base }
        let present = Set(ConfigGrammar.lines(text).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return nil }   // a commented key is not set
            return ConfigGrammar.key(ofLine: trimmed)
        })
        let missing = ConfigGrammar.scalarKeys.filter { !present.contains($0) }
        guard !missing.isEmpty else { return base }
        let lines = Config.defaultFileText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in missing.contains { line.hasPrefix("# \($0) =") } }
            .map { $0.dropFirst(2) }
        guard !lines.isEmpty else { return base }
        return applying(lines.joined(separator: "\n"), to: base).config
    }

    private static func applying(_ text: String,
                                 to base: Config) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        // ... today's `parse` body, unchanged, including the three additive keys it resets ...
    }
```

  The `guard base != .defaults` is not an optimisation: a first load has nothing in force, so there
  is nothing to put back, and skipping the synthesised parse keeps launch exactly as fast as it was.
  The diagnostics come only from `applying(text, …)` — the synthesised default text is the product's
  own and must produce none, which is what `theDefaultFileTextParsesBackToTheDefaults` asserts.

  In `ConfigWriter`, one helper and **five** call sites (`:25`, `:29`, `:33` in `setting`; `:61`, `:77` in `settingList`):

```swift
    /// Joins lines back into file text, ending with exactly one newline.
    ///
    /// Every result of this type ends the file properly, because the next thing appended to it may
    /// not be us: `cat ~/projects/nyx-server/token >> ~/.config/nyx/config` is the documented way to
    /// set the relay token, and against a file the settings window had just written it produced
    /// `remote = onremote-relay-token = …` -- one line that parses as one unknown key. Trailing
    /// blank lines collapse to that one newline, which keeps this idempotent: `settings` applies
    /// several keys by reducing over `setting`, so a second pass must not grow the file.
    private static func joined(_ lines: [String]) -> String {
        var lines = lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }
```

  Replace every `return lines.joined(separator: "\n")` in `setting` and `settingList` with
  `return joined(lines)`, and the `guard updated != existing else { return true }` in
  `ConfigStore.write`/`writeList` keeps doing its job — the first write after this lands rewrites
  the file's last byte and reloads once, which is correct and invisible.

  **The existing `ConfigWriterTests` need one mechanical pass, and it is four assertions, not two.**
  Forty-eight of its fifty-two use `contains`, `hasPrefix` or `split(separator:)` from the front and
  are genuinely unaffected. These four are not:

  - `:223` and `:241` (the `let out` is `:240`) — exact comparisons that gain a `\n`;
  - `:41` `#expect(out.hasSuffix("padding = 16"))` and
    `:88` `#expect(write("font-size", "18", into: "font-size=13") == "font-size=18")` — both assert
    the *absence* of a trailing newline, which is the bug, so both change to expect one.

  Change the expectations, never the rule.

- [ ] **Step 4: Run the config tests**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter Config 2>&1 | tail -8`
Expected: PASS. If `theDefaultFileTextParsesBackToTheDefaults` now fails for one of the keys the old private list did not cover (`shell-integration`, `fold-keep-lines`, `fold-long-output`, `multiline-paste`), the documented default has drifted from the compiled one: fix `Config.defaultFileText` — the file is what a user reads — and say which line moved in the commit message.

- [ ] **Step 5: Every field commits.** In `SettingsWindowController`:

```swift
    private func textField(_ key: String, secure: Bool = false, placeholder: String? = nil,
                           width: CGFloat = 220) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(key)
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(controlChanged(_:))
        // The action alone fires on Return and on nothing else, so a *pasted* value -- the relay
        // token, which is the one field of this whole feature that is always pasted -- was thrown
        // away by closing the window. It cost the owner a token on 2026-09-07 and it was still
        // doing it at the QA.
        field.sendsActionOnEndEditing = true
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        controls[key] = field
        return field
    }
```

  the same two lines on `stepperField`'s field (`:797` — it is an `NSTextField` like any other,
  and `remote-snapshot-lines` is one of the four fields the QA measured at
  `sendsActionOnEndEditing=false`), and:

```swift
    /// The same event as `sendsActionOnEndEditing`, deliberately kept alongside it: the two are
    /// belt and braces on the one thing this whole task is about, and AppKit's flag is a property
    /// somebody can turn off without noticing that a delegate method depended on it. The cost is
    /// one redundant `controlChanged` per edit, and `ConfigStore.write`'s
    /// `guard updated != existing else { return true }` (`ConfigStore.swift:75`) makes the second
    /// one a file read and nothing else -- no write, so no reload, so no loop. (There is no
    /// write→reload→write loop either way: `controlChanged` guards on `isRefreshing` (`:838`), and
    /// `refresh()` sets values programmatically, which fires no action at all.)
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSControl else { return }
        controlChanged(field)
    }

    /// The window closing is an end-editing nobody sends: the field still has focus, its value has
    /// never been committed, and the window is gone. Making the window itself first responder ends
    /// the edit, which fires the action above before anything is torn down.
    @objc private func windowIsClosing(_ notification: Notification) {
        commitEdits()
    }

    func commitEdits() {
        guard let window else { return }
        window.makeFirstResponder(window)
    }
```

  with `NSTextFieldDelegate` on the class's conformances (the fields have no delegate today, so
  nothing is displaced), and, in `init` after `window.contentView = buildContent()`:

```swift
        // NotificationCenter rather than `window.delegate = self`. An `NSWindowController` may
        // already be its own window's delegate, and quietly replacing a delegate that is answering
        // other questions is how a window stops remembering where it was. One observer, scoped to
        // this window, cannot collide with anything.
        NotificationCenter.default.addObserver(self, selector: #selector(windowIsClosing(_:)),
                                              name: NSWindow.willCloseNotification, object: window)
```

  with the matching removal, because this controller is not always the application's long-lived one:

```swift
    deinit { NotificationCenter.default.removeObserver(self) }
```

  `UISnapshot.writeSettings` (`UISnapshot.swift:889`) and `StateSnapshot` (`:464`) each build a
  short-lived `SettingsWindowController` over a real `ConfigStore()`, so the close hook now runs in
  the offscreen snapshot path against the user's own config file. It is safe: nothing in that path
  is ever first responder, so `makeFirstResponder(window)` ends no edit and fires no action, and
  `ConfigStore.write` is never reached. The `deinit` is what stops a released controller's observer
  from being called on a window that outlives it.

  and `commitEdits()` also called at the top of `pairAsHost(_:)` and `pairAsClient(_:)`, because a
  token typed and then Paired without Return is the same lost value one step earlier — the pairing
  would open against the empty token the file still holds and be refused by the relay.

- [ ] **Step 6: A file saved in place is noticed.** In `ConfigStore`:

```swift
    private var fileSource: DispatchSourceFileSystemObject?
```

```swift
    func startWatching() {
        stopWatching()
        let dir = ConfigStore.path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = watch(dir)
        // And the file itself. The directory watch catches an editor's write-then-rename, and
        // catches nothing at all when a file is rewritten through its existing inode -- which is
        // what `echo >> ~/.config/nyx/config` does, and what the documented way to set the relay
        // token is. Both watches, debounced together, so one save is still one reload; the file
        // watch is re-armed on `.delete`/`.rename`, which is the case a file watch alone loses.
        fileSource = watch(ConfigStore.path, isFile: true)
        try? FileManager.default.createDirectory(at: ConfigStore.themesDirectory,
                                                 withIntermediateDirectories: true)
        themeSource = watch(ConfigStore.themesDirectory)
    }
```

  `watch` learns which of the two it is arming, because the two answer `.delete`/`.rename`
  differently:

```swift
    private func watch(_ path: URL, isFile: Bool = false) -> DispatchSourceFileSystemObject? {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.handle(src.data, isFile: isFile) }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    private func handle(_ event: DispatchSource.FileSystemEvent, isFile: Bool) {
        if event.contains(.delete) || event.contains(.rename) {
            // The *file* was replaced by a rename, which is every atomic save -- including this
            // class's own `write`. Its descriptor is now stale, so it is re-armed; and the save
            // still has to be read, which is why this falls through to the debounce instead of
            // returning the way the directory case does. Returning here would have been worse than
            // the bug it fixed: `startWatching()` cancels the *directory* source too, and
            // cancelling a source before its own pending event has been delivered loses that
            // event -- so the one reload that used to happen would have stopped happening.
            if isFile {
                fileSource?.cancel()
                fileSource = watch(ConfigStore.path, isFile: true)
            } else {
                // The watched directory itself was removed or replaced (`rm -rf ~/.config/nyx`, an
                // editor that renames directories): every descriptor under it is stale.
                startWatching()
                return
            }
        }
        // `.write`/`.extend` on a directory fires once per entry added, removed or renamed inside
        // it, and on the file once per write to it -- an editor's write-then-rename is two or three
        // such events for one save, coalesced here into one reload.
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
```

  `stopWatching` cancels `fileSource` too; and `reload()` arms the file watch if the file has only just appeared:

```swift
    func reload() {
        (config, diagnostics) = ConfigStore.load(base: config)
        loadThemes()
        // A config file created after launch (a fresh install, `Edit Config File…`) has no watch on
        // it yet: the directory watch is what noticed it appearing.
        if fileSource == nil, FileManager.default.fileExists(atPath: ConfigStore.path.path) {
            fileSource = watch(ConfigStore.path, isFile: true)
        }
        onChange?(config, diagnostics)
    }
```

  And the class's own doc comment (`:6-10`) says the new rule: it is right about rename-based
  editors and silently wrong about in-place ones, which is the sentence that let this survive.
  Replace "Watches the config *directory*, not the file" with "Watches the config directory **and**
  the config file: a directory watch survives an editor's write-then-rename, and only a file watch
  sees a file rewritten through its existing inode -- which is what `echo >>` does, and what the
  documented way to set the relay token is."

  A file watch is I/O, not a decision, and there is nothing here for a unit test to hold: it is proved at rung 6 in Task 11, with the QA's own two commands (`printf '…' >> $NYX_CONFIG/config` and an `os.replace`), and both must now be noticed within a second.

- [ ] **Step 7: Run the ladder's first three rungs**

Run: `swift build 2>&1 | grep -c "warning:"; pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5; make bench`
Expected: `0` warnings, PASS, bench ≥ 180 MB/s.

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxApp/SettingsWindowController.swift Sources/NyxApp/ConfigStore.swift \
        Sources/NyxCore/Config/ConfigGrammar.swift Sources/NyxCore/Config/ConfigParser.swift \
        Sources/NyxCore/Config/ConfigWriter.swift Sources/NyxCore/Config/Config.swift \
        Tests/NyxCoreTests/ConfigTests.swift Tests/NyxCoreTests/ConfigWriterTests.swift
git commit -m "$(cat <<'EOF'
A pasted setting is kept, and a file we did not write is read

Every text field in the settings window fired its action on Return and on nothing else, so a value
that was *pasted* -- the relay token, the one field this whole feature depends on -- was thrown away
by closing the window, silently. `sendsActionOnEndEditing`, `controlTextDidEndEditing` and
`windowWillClose` → `commitEdits()`. It cost the owner a token on 2026-09-07 and it was still doing
it at the QA on 2026-09-10.

Two halves of the same complaint on the way in: a config file rewritten through its existing inode
(`echo >>`, or any editor that saves in place) was never noticed, because only the directory was
watched; and a key *deleted* from the file kept its value until restart, so deleting
`remote-relay-token` did not take the Mac off the relay. The parse now starts from the defaults for
keys the file does not mention -- re-applied as the text `Config.defaultFileText` already documents,
so there is no second copy of the key list to drift -- while a line that is present and unparseable
still keeps the value in force, which is the rule for a value somebody is in the middle of typing.

And the writer ends the file with a newline. It did not, so the next thing appended to that file by
anything else glued itself onto the last line -- which is how the owner's config came to hold
`remote = onremote-relay-token = …` after following the documented way to set the token
(`cat token >> config`). The parser has always tolerated a file without one, and there is now a test
saying so.

`Config.defaultFileText` is staged for the case where uncommenting one of the four keys the old
test-local list did not cover no longer reproduces the compiled default; if nothing there moved, it
is not in the commit.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---


### Task 7: The strip — a button you can see, one accessibility element, a row-height band, and a note with a short form

**Files:**
- Modify: `Sources/NyxCore/Remote/AttachState.swift` — `hostSize`/`paneSize`, the note's threshold and ladder, `stripLabelOptions`
- Create: `Sources/NyxCore/Remote/RemoteAnnouncement.swift`
- Modify: `Sources/NyxApp/RemoteStripView.swift` — `appearance`, `attributedTitle`, the a11y override
- Modify: `Sources/NyxApp/Pane.swift` — the strip's frame at `hitRowHeight`, the sizes into the state, the announcement
- Modify: `Sources/NyxApp/UISnapshot.swift` — the strip states rebuilt from sizes, and a 300 pt width
- Test: `Tests/NyxCoreTests/AttachStateTests.swift`, `Tests/NyxCoreTests/RemoteAnnouncementTests.swift` (new)

**Interfaces:**
- Consumes (plan 1a): `CommandBlockChrome.hitRowHeight(cellHeight:)`, `PromptGutter.hitWidth`. (plan 1b): `Announce.say(_:)`.
- Produces:

```swift
public extension AttachState {
    var hostSize: GridSize?      // stored; from `attached`/`role`
    var paneSize: GridSize?      // stored; this window's grid
    var geometryNote: String? { get }        // computed, longest form, nil under the threshold
    var geometryNoteOptions: [String] { get } // longest first: full, medium, `Host is 132×40`
    static func geometryNote(host: GridSize, pane: GridSize) -> String?   // unchanged signature
    static func geometryNoteOptions(host: GridSize, pane: GridSize) -> [String]
    static let noteColumnSlack = 4
    static let noteRowSlack = 3
}
public enum RemoteAnnouncement {
    static func text(from previous: AttachState?, to current: AttachState) -> String?
}
```

- [ ] **Step 1: Write the failing Core tests.** In `Tests/NyxCoreTests/AttachStateTests.swift`, exactly **three** tests change: the ones that set `geometryNote` directly (`:281`, `:290`, `:301`), because that stored field becomes computed. `aHostScreenBiggerThanThePaneSaysSoOnTheStrip` (`:254-266`) and `aPaneBigEnoughForTheHostGetsNoNote` (`:270-275`) **stay exactly as they are** — every one of their five assertions uses Δ36 columns, Δ10/Δ36 rows, Δ120 columns, or an equal-or-larger pane, so all of them still hold at the new four-column/three-row threshold, and they are the only coverage that the note's *wording* is right. Add the ladder:

```swift
/// §12 called the threshold a product decision and it was one row: a host one row taller than the
/// pane bought a permanent 74-character warning that itself covers a row -- two rows lost to warn
/// about one.
@Test func oneMissingRowIsNotWorthAWarning() {
    #expect(AttachState.geometryNote(host: GridSize(cols: 54, rows: 16),
                                     pane: GridSize(cols: 54, rows: 15)) == nil)
    #expect(AttachState.geometryNote(host: GridSize(cols: 56, rows: 15),
                                     pane: GridSize(cols: 54, rows: 15)) == nil)
    // Three rows or four columns is where a prompt starts genuinely going missing.
    #expect(AttachState.geometryNote(host: GridSize(cols: 54, rows: 18),
                                     pane: GridSize(cols: 54, rows: 15)) != nil)
    #expect(AttachState.geometryNote(host: GridSize(cols: 58, rows: 15),
                                     pane: GridSize(cols: 54, rows: 15)) != nil)
}

/// And when the note is the only clause there was nothing shorter to fall back to, so at 27 columns
/// the reader got "Host is 54×16 — the promp…" and lost the remedy. The note has its own ladder.
@Test func theNoteHasAShortFormSoItNeverTruncatesAwayItsOwnRemedy() {
    var writer = state(phase: .live, role: .writer)
    writer.hostSize = GridSize(cols: 132, rows: 40)
    writer.paneSize = GridSize(cols: 96, rows: 30)
    let options = writer.stripLabelOptions
    #expect(options == [
        "Host is 132×40 — the prompt and cursor may be off screen; enlarge the window",
        "Host is 132×40 — enlarge the window",
        "Host is 132×40",
    ])
    #expect(writer.stripText == options[0])
    #expect(writer.geometryNote == options[0])
}

@Test func theNoteJoinsThePhasesOwnSentenceAndGoesBeforeItTruncates() {
    var observing = state(phase: .live, role: .observer)
    observing.hostSize = GridSize(cols: 132, rows: 40)
    observing.paneSize = GridSize(cols: 96, rows: 30)
    let options = observing.stripLabelOptions
    #expect(options.first == "Observing · Host is 132×40 — the prompt and cursor may be off screen; enlarge the window")
    #expect(options.last == "Observing")
    #expect(options.count == 4)
    #expect(observing.stripButton == "Take control")
}

/// The same answer through the stored sizes rather than the static function -- a different route to
/// `aPaneBigEnoughForTheHostGetsNoNote` (`:270`), which stays where it is and keeps its name.
@Test func aPaneBigEnoughForTheHostGetsNoNoteOnTheStrip() {
    var writer = state(phase: .live, role: .writer)
    writer.hostSize = GridSize(cols: 80, rows: 24)
    writer.paneSize = GridSize(cols: 80, rows: 24)
    #expect(writer.geometryNote == nil)
    #expect(writer.stripText == nil)
    #expect(writer.stripLabelOptions.isEmpty)
}
```

  and a new `Tests/NyxCoreTests/RemoteAnnouncementTests.swift`:

```swift
import Foundation
import Testing
@testable import NyxCore

private func live(_ role: AttachState.Role) -> AttachState {
    var s = AttachState(hostName: "beta", title: "zsh")
    s.phase = .live
    s.role = role
    return s
}

/// §8.1: the strip's state changes are announcement sites. They are the only notice a person gets
/// that a tab has stopped taking their keystrokes -- the change is a colour and a sentence in a row
/// they are not looking at, and nothing else in the window moves.
@Test func aPhaseChangeIsAnnouncedInTheStripsOwnWords() {
    var ended = live(.writer)
    ended.phase = .ended("beta")
    #expect(RemoteAnnouncement.text(from: live(.writer), to: ended)
        == "Session ended on beta · ⌘W to close")
}

@Test func losingTheWriterRoleIsAnnounced() {
    #expect(RemoteAnnouncement.text(from: live(.writer), to: live(.observer))
        == "Observing — Take control")
}

/// The one state with no strip is the one that needs words most: gaining the writer role is the
/// strip *disappearing*, which says nothing at all out loud.
@Test func gainingTheWriterRoleIsAnnouncedEvenThoughTheStripGoes() {
    #expect(RemoteAnnouncement.text(from: live(.observer), to: live(.writer))
        == "You can type in this session")
}

@Test func nothingIsAnnouncedWhenNeitherThePhaseNorTheRoleMoved() {
    var narrower = live(.observer)
    narrower.hostSize = GridSize(cols: 132, rows: 40)
    narrower.paneSize = GridSize(cols: 96, rows: 30)
    #expect(RemoteAnnouncement.text(from: live(.observer), to: narrower) == nil)
}

/// A tab's first state is not a change to announce: every remote tab would open by talking.
@Test func theFirstStateIsNotAnnounced() {
    #expect(RemoteAnnouncement.text(from: nil, to: live(.writer)) == nil)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter 'AttachState|RemoteAnnouncement' 2>&1 | tail -10`
Expected: `cannot assign to property: 'geometryNote' is a get-only property` is what you are aiming for; today it fails with `cannot find 'RemoteAnnouncement'` and `no member 'hostSize'`.

- [ ] **Step 3: The sizes, the threshold and the ladder.** In `AttachState`, replace the stored `geometryNote` with the two sizes:

```swift
    /// The host's grid, from `attached` and from any `role` since, and this pane's own.
    ///
    /// Two sizes rather than a formatted sentence, because the *threshold* and the note's short
    /// forms are decisions -- and a sentence handed in already made cannot be shortened when the
    /// window is too narrow to hold it, which is how a 27-column pane came to read
    /// "Host is 54×16 — the promp…" and lose the remedy.
    public var hostSize: GridSize?
    public var paneSize: GridSize?

    /// What the strip says when the host's screen is meaningfully bigger than the pane showing it.
    public var geometryNote: String? { geometryNoteOptions.first }

    /// The note, longest first. Empty when the host fits.
    public var geometryNoteOptions: [String] {
        guard let hostSize, let paneSize else { return [] }
        return AttachState.geometryNoteOptions(host: hostSize, pane: paneSize)
    }
```

```swift
    /// How much smaller the pane may be before it is worth a sentence.
    ///
    /// §12 left the threshold as a product decision and the code had it at one: a host one row
    /// taller than the pane bought a permanent 74-character warning which itself covers a row, so
    /// warning about one missing row cost two. A few columns of a wrapped line and a couple of rows
    /// below the prompt are things a person can see; four columns or three rows is where the prompt
    /// and the cursor actually go missing.
    public static let noteColumnSlack = 4
    public static let noteRowSlack = 3

    public static func geometryNote(host: GridSize, pane: GridSize) -> String? {
        geometryNoteOptions(host: host, pane: pane).first
    }

    /// Three forms of the same note: what has happened and what fixes it, the remedy alone, and the
    /// numbers alone. The shortest is 14 characters, so even a 27-column strip keeps a whole clause
    /// rather than half of one.
    public static func geometryNoteOptions(host: GridSize, pane: GridSize) -> [String] {
        guard host.cols - pane.cols >= noteColumnSlack || host.rows - pane.rows >= noteRowSlack
        else { return [] }
        let size = "Host is \(host.cols)×\(host.rows)"
        return ["\(size) — the prompt and cursor may be off screen; enlarge the window",
                "\(size) — enlarge the window",
                size]
    }
```

  `stripText`/`stripLabel` keep `joined(...)` with `geometryNote`, and `stripLabelOptions` walks the note's ladder before it gives the note up:

```swift
    /// What the strip may draw, longest first: the view takes the first that fits its width.
    ///
    /// The note is what shortens and then goes, in that order, because the sentence in front of it
    /// is the part that cannot be seen any other way -- and when the note *is* the sentence it
    /// still shortens twice before anything is cut off mid-word.
    public var stripLabelOptions: [String] {
        let base = phaseLabelWithoutNote
        let notes = geometryNoteOptions
        var out: [String] = []
        for note in notes {
            if let base { out.append("\(base) · \(note)") } else { out.append(note) }
        }
        if let base { out.append(base) }
        var seen: Set<String> = []
        return out.filter { seen.insert($0).inserted }
    }

    /// The label's own sentence, before the note is joined to it: `stripLabel` minus the note.
    private var phaseLabelWithoutNote: String? {
        var bare = self
        bare.hostSize = nil
        bare.paneSize = nil
        return bare.stripLabel
    }
```

  and `Sources/NyxCore/Remote/RemoteAnnouncement.swift`:

```swift
import Foundation

/// When a remote tab's state is worth saying out loud, and in what words (§8.1).
///
/// The strip is the only notice a person gets that a tab has stopped taking their keystrokes, and
/// the notice is a colour and a sentence in a row they are not looking at. Nothing else in the
/// window moves: a demoted writer's next twenty keystrokes simply go nowhere.
///
/// Only a phase or a role change, so a window being dragged narrower -- which rewrites the label
/// several times a second -- says nothing, and the words are `stripText`, so the announcement and
/// the strip cannot describe one tab two ways.
public enum RemoteAnnouncement {
    /// What a live writer's tab says when it has just become one. `stripText` is nil there, by
    /// design (a tab that owns its session looks like an ordinary terminal), and the transition
    /// into it is the strip *vanishing* -- which is silence about the one change a person can act on.
    public static let canType = "You can type in this session"

    public static func text(from previous: AttachState?, to current: AttachState) -> String? {
        guard let previous else { return nil }
        guard previous.phase != current.phase || previous.role != current.role else { return nil }
        return current.stripText ?? RemoteAnnouncement.canType
    }
}
```

- [ ] **Step 4: The button becomes visible, and the strip is one element.** In `RemoteStripView.update`, after `shown = …` and before the colours:

```swift
        // The pane's theme decides the band, and anything AppKit draws inside it follows the
        // *window's* appearance instead -- so on a light theme under Dark Mode the button's title
        // measured 1.46:1 against its own fill and its bezel disappeared altogether, leaving "Take
        // control" reading as a label. It is the same trap `BlockHeaderView` documents, and the
        // remote strip is the one place it costs a *control*: `remote_take_control` has no chord,
        // so this button is the only pointer route to it.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
```

  and where the ink is set, the title with it:

```swift
        label.textColor = nsColor(ink, alpha: 1)
        // `contentTintColor` recolours a symbol image, not a title: a *titled* NSButton paints in
        // the system's `labelColor` unless the title is an attributed string. Eight of the twelve
        // strip states differed between appearances because of those two lines; the same ink as the
        // label, which is the colour measured against this exact ground.
        button.attributedTitle = NSAttributedString(
            string: state.stripButton ?? "",
            attributes: [.foregroundColor: nsColor(ink, alpha: 1),
                         .font: button.font ?? NSFont.systemFont(ofSize: 10, weight: .medium)])
        layer?.backgroundColor = nsColor(ground, alpha: 1).cgColor
```

  (`button.title = title` above it stays: `labelWidth(button:)` measures through `intrinsicContentSize`, which needs the plain title set first.)

  And the leaf-or-container answer, replacing the two overrides at the foot of the file:

```swift
    /// Leaf or container, per state -- never both, and never neither.
    ///
    /// It used to answer *both*: an element, role `AXGroup`, vending one child, which is a control a
    /// screen reader can reach twice and describe differently each time. Answering "container,
    /// always" is the other mistake and is worse: three of the eleven strip states have no button
    /// (`attaching`, `reconnecting`, and the live writer carrying only a geometry note), so a view
    /// that is never an element would take "Attaching…", "Reconnecting…" and the geometry note out
    /// of the accessibility tree altogether -- and those are the only three sentences on this strip
    /// that are not also written on a button.
    ///
    /// So: a leaf carrying the whole sentence when there is nothing to press, a container vending
    /// the button when there is. `WorkbenchHintView` is a fair precedent for the
    /// second half only (`WorkbenchHintView.swift:161-165`), because it always has a button.
    override func isAccessibilityElement() -> Bool { !isHidden && button.isHidden }

    override func accessibilityChildren() -> [Any]? {
        isHidden || button.isHidden ? [] : [button]
    }
```

  `setAccessibilityRole(.group)` and `setAccessibilityLabel("Remote session: \(text)")` stay, and now they are read: they describe the leaf, in the three states where the leaf is what there is.

  **Which state gets which is decidable in Core**, so it is asserted at rung 2 rather than waited on for a VoiceOver run that §10 has waived. Append to `Tests/NyxCoreTests/AttachStateTests.swift`:

```swift
/// The a11y rule the strip draws from, stated where a test can reach it: the strip is a leaf
/// exactly when there is nothing on it to press. Three of the eleven pictured states are leaves --
/// and they carry the only three sentences on the strip that are not also a button's title.
@Test func theStripIsALeafExactlyWhenItHasNoButton() {
    #expect(state(phase: .attaching, role: .observer).stripButton == nil)
    #expect(state(phase: .snapshot, role: .observer).stripButton == nil)
    #expect(state(phase: .reconnecting, role: .writer).stripButton == nil)
    var noteOnly = state(phase: .live, role: .writer)
    noteOnly.hostSize = GridSize(cols: 132, rows: 40)
    noteOnly.paneSize = GridSize(cols: 96, rows: 30)
    #expect(noteOnly.stripButton == nil)
    #expect(noteOnly.stripText != nil)                 // a strip with words and no button
    // And the eight that have one, which is the set the `cmp` gate in Step 7 is about.
    #expect(state(phase: .live, role: .observer).stripButton == "Take control")
    #expect(state(phase: .ended("iMac"), role: .writer).stripButton == "Close")
    #expect(state(phase: .failed("Host is offline"), role: .observer).stripButton == "Close")
    #expect(suspendedState().stripButton == "Close")
}
```

- [ ] **Step 5: The band is a row-height target, and the pane hands over sizes and announcements.** In `Pane.swift`:

```swift
    private func layoutStickyStrip() {
        let cell = cellSizePoints
        let left = max(padding, CGFloat(PromptGutter.hitWidth))
        let width = max(0, bounds.width - left - padding)
        let top = bounds.height - padding - cell.height
        // `hitRowHeight`, centred on the row it covers, for the same reason the pinned band uses it
        // (§8.4): at `line-height = 0.8` a cell is 13 pt and this strip carries a button.
        let height = CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cell.height)))
        remoteStrip.frame = NSRect(x: left, y: top + cell.height / 2 - height / 2,
                                   width: width, height: height)
        // The pinned band yields, and yields by whole rows: two 16 pt bands one 13 pt row apart
        // would overlap, so at `line-height 0.8` it steps down two rows rather than one.
        let rowsDown = CGFloat(stickyStripRow) * cell.height
        let centre = top + cell.height / 2 - rowsDown
        stickyStrip.frame = NSRect(x: left, y: centre - height / 2, width: width, height: height)
    }

    /// Which display slot the pinned band sits on: the top row, or far enough below the remote strip
    /// that their two `hitRowHeight` bands do not overlap.
    private var stickyStripRow: Int {
        guard remote != nil, !remoteStrip.isHidden else { return 0 }
        let cell = Double(cellSizePoints.height)
        return max(1, Int(ceil(CommandBlockChrome.hitRowHeight(cellHeight: cell) / max(cell, 1))))
    }
```

  and in `showRemote(_:)`:

```swift
        var shown = state
        // Added here rather than by the client: how big this window is, and how many panes share
        // this tab, are facts about this window -- which `RemoteClient` neither knows nor should.
        shown.hostSize = remote.map { GridSize(cols: $0.attachment.cols, rows: $0.attachment.rows) }
        shown.paneSize = GridSize(cols: cols, rows: rows)
        shown.closesWholeTab = isSolePaneInTab?() ?? true
        shown.today = AttachState.startOfDay(Date(), in: shown.timeZone)
        ...
        guard shown != shownRemoteState else { return }
        // §8.1: the strip is an announcement site, and the wording is Core's. Before the assignment
        // below, which is what makes `shownRemoteState` the previous state.
        if let spoken = RemoteAnnouncement.text(from: shownRemoteState, to: shown) {
            Announce.say(spoken)
        }
        shownRemoteState = shown
```

  `remoteGeometryNote()` is deleted; nothing else calls it.

  And the row the strip covers is blanked in the frame, exactly as the pinned band's row already is
  (`Pane.render`, the `blankRow` at `:2302`). The band is opaque and, at `line-height 0.8`, 16 pt
  over a 13 pt row, so the covered row's ascenders and descenders print above and below it — which
  is the same defect the sticky band's comment at `:2290-2300` documents. It costs nothing: the band
  is opaque, so that row was already unreadable at every line height.

```swift
            // Two rows may be covered now, and each of them is covered by an *opaque* band: the
            // remote strip owns the top one whenever it is showing, and the pinned band owns
            // `stickyStripRow`. A glyph half-drawn around a sentence is worse than no glyph.
            if self.remote != nil, !self.remoteStrip.isHidden, !lines.isEmpty {
                lines[0] = Row(cols: t.cols)
            }
            let blankRow = self.stickyStripRow
```

- [ ] **Step 6: The pictures.** In `UISnapshot.remoteStripStates()`, build `clipped` and `suspendedClipped` from sizes rather than a sentence — **the same numbers the pictures have today** (`UISnapshot.swift:1069-1071`), so the only thing that changes about `remote-strip-clipped-*` is how it is constructed:

```swift
        var clipped = state(.live, .writer)
        clipped.hostSize = GridSize(cols: 132, rows: 40)
        clipped.paneSize = GridSize(cols: 96, rows: 30)
        ...
        // Both clauses at once, which is the case the strip has to choose between when it is narrow.
        var suspendedClipped = suspended
        suspendedClipped.hostSize = clipped.hostSize
        suspendedClipped.paneSize = clipped.paneSize
```

  (`suspendedClipped` copied `clipped.geometryNote` before, `UISnapshot.swift:1089`; it copies the
  two sizes now, which is the same picture by a different route.) Then widen the run:

```swift
        for (paletteName, themePalette) in chromePalettes(default: palette) {
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                for (stateName, state) in remoteStripStates() {
                    write(remoteStrip(state: state, palette: themePalette, appearance),
                          named: "remote-strip-\(stateName)-\(paletteName)-\(name)", into: directory,
                          background: themePalette.background)
                }
                // Every `remote-strip-*` picture is 900 pt wide, so no picture in 811 showed a strip
                // on a narrow pane -- which is the width at which the label has to choose between
                // its clauses (D9c). Two states at 300: the one with both clauses and the one whose
                // note is the whole sentence.
                for (stateName, state) in remoteStripStates()
                where stateName == "clipped" || stateName == "suspended-clipped" {
                    write(remoteStrip(state: state, palette: themePalette, appearance, width: 300),
                          named: "remote-strip-\(stateName)-narrow-\(paletteName)-\(name)",
                          into: directory, background: themePalette.background)
                }
            }
        }
```

  with `remoteStrip(state:palette:_:width:)` taking `width: CGFloat = 900`.

- [ ] **Step 7: Run the tests, take the pictures, and prove the eight pairs are identical**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/nyx-6-strip ./build/Nyx.app/Contents/MacOS/Nyx
cd /tmp/nyx-6-strip && for f in remote-strip-*-dark.png; do
  cmp -s "$f" "${f%-dark.png}-light.png" && echo "IDENTICAL $f" || echo "DIFFERS   $f"
done | sort | uniq -c | head
```
Expected: `0` warnings, PASS, and **every** `remote-strip-*` pair `IDENTICAL` — the eight button-bearing states included. That byte-identity is the guard the whole `<palette>-<appearance>` naming scheme exists to enforce (§10), and it is what the QA measured as 1.46–2.26:1. Then **look at** `remote-strip-observer-nyx-light-dark.png` (the worst case: light theme, Dark Mode) and the two `-narrow-` pictures.

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxCore/Remote/AttachState.swift Sources/NyxCore/Remote/RemoteAnnouncement.swift \
        Sources/NyxApp/RemoteStripView.swift Sources/NyxApp/Pane.swift Sources/NyxApp/UISnapshot.swift \
        Tests/NyxCoreTests/AttachStateTests.swift Tests/NyxCoreTests/RemoteAnnouncementTests.swift
git commit -m "$(cat <<'EOF'
The strip's one button becomes a button

`RemoteStripView` set `contentTintColor`, which a *titled* NSButton ignores, and never pinned its
appearance -- so on a light theme under Dark Mode the title measured 1.46:1 against its own fill and
the bezel vanished entirely, leaving "Take control" reading as a label. It is the only pointer route
to `remote_take_control`, which has no chord. `appearance` plus an `attributedTitle` in the label's
own ink, and all eight button-bearing states now come out byte-identical across appearances, which
is the guard the picture names exist for.

The strip also stopped answering two accessibility questions at once (an element *and* a group
vending a child); the band is `hitRowHeight` like every other one-row target, with the pinned band
stepping down by whole rows so two 16 pt bands cannot overlap at `line-height 0.8`; the geometry
note needs four columns or three rows before it costs a row of its own, and has two shorter forms so
a 27-column strip keeps the remedy instead of truncating it away; and a phase or role change is
announced in the strip's own words (§8.1) -- the only notice there is that a tab has stopped taking
your keystrokes.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: The pairing sheet — one sentence, one spinner, and a button Return can press

**Files:**
- Modify: `Sources/NyxCore/Remote/PairingFlow.swift` — the host's `.idle`/`.opening` wording, `showsProgress`
- Modify: `Sources/NyxApp/PairingSheet.swift` — the progress indicator, the terminal states' default button, ⎋ without a Cancel, the code field's caption
- Modify: `Sources/NyxApp/SettingsWindowController.swift` — the caption under the two Pair buttons
- Test: `Tests/NyxCoreTests/PairingFlowTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:

```swift
public extension PairingFlow {
    static func sheetText(for state: State, side: Side = .host) -> (title: String, body: String, primary: String?)
    /// Whether this state is waiting on something with nothing to show for it.
    static func showsProgress(for state: State, side: Side) -> Bool
}
```

- [ ] **Step 1: Write the failing Core tests.** Append to `Tests/NyxCoreTests/PairingFlowTests.swift`:

```swift
/// The host's first half-second was three sheets: "Pair with another device / Getting a code from
/// the relay", then "Pairing… / Requesting a code from the relay", then the code -- and the middle
/// two are the same wait said twice, in under 400 ms. One title and one sentence, so the transition
/// is invisible, and a spinner so the wait looks like one.
@Test func theHostsTwoWaitingStatesReadIdentically() {
    let idle = PairingFlow.sheetText(for: .idle, side: .host)
    let opening = PairingFlow.sheetText(for: .opening("K7M4QZ", expires: Date()), side: .host)
    #expect(idle.title == "Pair with another device")
    #expect(idle.body == "Getting a code from the relay")
    #expect(idle == opening)
    #expect(idle.primary == nil)
}

@Test func aWaitingStateShowsProgressAndAnActionableOneDoesNot() {
    #expect(PairingFlow.showsProgress(for: .idle, side: .host))
    #expect(PairingFlow.showsProgress(for: .opening("K7M4QZ", expires: Date()), side: .host))
    #expect(PairingFlow.showsProgress(for: .joining(code: "K7M4QZ"), side: .client))
    #expect(PairingFlow.showsProgress(for: .confirming(peerID: "p", peerName: "beta",
                                                        fingerprint: "a-b-c-d", mine: true,
                                                        theirs: false), side: .client))
    // The client's idle sheet is a field waiting for a person, not a wait for the relay.
    #expect(!PairingFlow.showsProgress(for: .idle, side: .client))
    #expect(!PairingFlow.showsProgress(for: .showingCode("K7M4QZ", expires: Date()), side: .host))
    #expect(!PairingFlow.showsProgress(for: .requested(peerID: "p", peerName: "beta"), side: .host))
    #expect(!PairingFlow.showsProgress(for: .paired(peerID: "p", peerName: "beta"), side: .host))
    #expect(!PairingFlow.showsProgress(for: .failed("That code is wrong or has expired"), side: .client))
}

/// Every state still renders something: the reason `sheetText` exists is a host `.idle` that once
/// drew a 75-point empty box with a Cancel button in it.
@Test func noStateRendersBlankOnEitherSide() {
    let states: [PairingFlow.State] = [
        .idle, .opening("K7M4QZ", expires: Date()), .showingCode("K7M4QZ", expires: Date()),
        .joining(code: "K7M4QZ"), .requested(peerID: "p", peerName: "beta"),
        .confirming(peerID: "p", peerName: "beta", fingerprint: "a-b-c-d", mine: false, theirs: false),
        .confirming(peerID: "p", peerName: "beta", fingerprint: "a-b-c-d", mine: true, theirs: false),
        .paired(peerID: "p", peerName: "beta"), .failed("That code is wrong or has expired"),
    ]
    for side in [PairingFlow.Side.host, .client] {
        for state in states {
            let text = PairingFlow.sheetText(for: state, side: side)
            #expect(!text.title.isEmpty, "\(state) on \(side) has no title")
        }
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter Pairing 2>&1 | tail -10`
Expected: the first two fail (`.opening` still says "Pairing… / Requesting a code from the relay"; `showsProgress` does not exist).

- [ ] **Step 3: One sentence, and the progress rule.** In `PairingFlow.sheetText`:

```swift
        case .idle:
            guard side == .client else {
                return ("Pair with another device", "Getting a code from the relay", nil)
            }
            ...
        case .opening:
            // The same words as `.idle`, deliberately. They are the same wait -- the sheet is up and
            // the relay has not answered -- and saying it twice, with a different title each time,
            // made the first four hundred milliseconds of pairing a flicker through three looks.
            // What the user needs there is not a third sentence but a spinner: `showsProgress`.
            return ("Pair with another device", "Getting a code from the relay", nil)
```

  and beside it:

```swift
    /// Whether this state is waiting on something and has nothing to show for it.
    ///
    /// The sheet's own indicator is delayed (see `PairingSheet.progressDelay`) so a relay that
    /// answers in 400 ms -- as the local one does -- never spins at all. This decides *which*
    /// states may spin, in Core, so the sheet cannot spin on one a person is meant to be reading.
    public static func showsProgress(for state: State, side: Side) -> Bool {
        switch state {
        case .idle: return side == .host
        case .opening, .joining: return true
        case .confirming(_, _, _, let mine, let theirs): return mine && !theirs
        case .showingCode, .requested, .paired, .failed: return false
        }
    }
```

- [ ] **Step 4: The sheet spins, and Return works on the last two states.** In `PairingSheet`:

```swift
    private let progress = NSProgressIndicator()
    /// A spinner that appears the instant a sheet does is a flicker, not a signal: the relay
    /// answers in about 400 ms, so anything shorter than this was never a wait worth drawing.
    private static let progressDelay: TimeInterval = 0.3
    private var progressItem: DispatchWorkItem?
```

  in `init`, configured and put in the variable stack beside the code label:

```swift
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        progress.setAccessibilityLabel("Waiting for the relay")
```

  (`variableStack` becomes `NSStackView(views: [codeLabel, progress, codeField, codeHintLabel, codeErrorLabel, fingerprintLabel])` — the hint sits directly under the field and above the error, so a rejected code's message is the line nearest the field. `codeHintLabel` is declared beside `codeErrorLabel` in Step 4's second block.)

  In `update(state:)`, after the body label:

```swift
        // Delayed, and cancelled by any state change: a sheet that reaches `showingCode` inside the
        // delay never spins.
        progressItem?.cancel()
        progress.stopAnimation(nil)
        progress.isHidden = true
        if PairingFlow.showsProgress(for: state, side: side) {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.progress.isHidden = false
                self.progress.startAnimation(nil)
                self.resizeToFitContent()
            }
            progressItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + PairingSheet.progressDelay, execute: item)
        }
```

  and the terminal states keep the primary button, which is the one carrying Return:

```swift
        switch state {
        case .paired, .failed:
            // The word goes on the *primary* button, not onto Cancel. Cancel carries ⎋, so moving
            // "Done"/"Close" there left Return doing nothing at all on the two states where it is
            // the only thing a person wants to press. There is nothing to cancel here either way.
            primaryButton.isHidden = false
            primaryButton.title = text.primary ?? "Close"
            secondaryButton.isHidden = true
        default:
            primaryButton.isHidden = text.primary == nil
            primaryButton.title = text.primary ?? ""
            secondaryButton.isHidden = false
            secondaryButton.title = "Cancel"
        }
```

  `primaryPressed()` gains the two cases it now has to answer (both dismiss):

```swift
        case .paired, .failed: onEvent?(.cancel)
```

  and ⎋ still works with no Cancel button, because the content view answers for it:

```swift
/// The sheet's content, which exists as a class only so that ⎋ dismisses a state whose Cancel
/// button has gone (`.paired`, `.failed`): AppKit finds an escape key equivalent by looking for a
/// *visible* button with one, and answers `cancelOperation` through the responder chain otherwise.
private final class PairingContentView: NSView {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var acceptsFirstResponder: Bool { true }
}
```

  with `content = PairingContentView()` in `init` and `(content as? PairingContentView)?.onCancel = { [weak self] in self?.onEvent?(.cancel) }`.

  The client's code field loses the placeholder that reads as a value (Wave-4 item 9's half that belongs to the pairing flow):

```swift
        // No placeholder. A grey, centred `K7M-4QZ` inside the box reads as a filled value, so
        // people pressed Pair and were told "A code is six letters and digits, like K7M-4QZ" --
        // the message restating the thing that had misled them. The example is a caption instead.
        codeField.placeholderString = nil
        codeHintLabel.stringValue = "Six characters, like K7M-4QZ"
        codeHintLabel.font = .systemFont(ofSize: 11)
        codeHintLabel.textColor = .secondaryLabelColor
        codeHintLabel.alignment = .center
```

  (`codeHintLabel` is a new `private let codeHintLabel = NSTextField(labelWithString: "")`, arranged in `variableStack` between `codeField` and `codeErrorLabel` as above, and hidden in every branch of `update(state:)` that hides `codeField` — the same four places `codeField.isHidden` is set.)

- [ ] **Step 5: The Remote page says which Mac presses which.** In `SettingsWindowController.remotePage()`, under `pairButtons`:

```swift
        // Two buttons and nothing saying which Mac presses which was a fifty-fifty guess in the one
        // flow where guessing wrong shows the other person an error.
        let pairCaption = NSTextField(wrappingLabelWithString:
            "On one Mac press Pair with another device\u{2026}; on the other press Enter a code\u{2026}.")
        pairCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pairCaption.textColor = .secondaryLabelColor
        pairCaption.translatesAutoresizingMaskIntoConstraints = false
```

  added to the subview list and constrained under `pairButtons` (8 pt) with `activityLabel` hung off *it* instead.

- [ ] **Step 6: Tests, pictures**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/nyx-6-pairing ./build/Nyx.app/Contents/MacOS/Nyx
cmp /tmp/nyx-6-pairing/pairing-host-idle-dark.png /tmp/nyx-6-pairing/pairing-host-opening-dark.png
```
Expected: `0` warnings, PASS, and the two host waiting pictures **byte-identical** — which is what "one title and one sentence" means, and what stops the flicker. Then **look at** `pairing-client-idle-{light,dark}.png` (the field is empty with a caption under it, not a grey code inside it) and `pairing-{host,client}-{paired,failed}-*.png` (one button, carrying the state's own word).

  Note: the delayed spinner is not in any picture — `UISnapshot` renders a state synchronously, 300 ms before the indicator appears. That is deliberate: the pictures show the sheet a person actually sees when the relay is quick. The spinner is verified at rung 6 in Task 11, by pairing against a relay and watching it.

- [ ] **Step 7: Commit**

```bash
git add Sources/NyxCore/Remote/PairingFlow.swift Sources/NyxApp/PairingSheet.swift \
        Sources/NyxApp/SettingsWindowController.swift Tests/NyxCoreTests/PairingFlowTests.swift
git commit -m "$(cat <<'EOF'
Pairing stops flickering through three sheets in half a second

The host's `.idle` and `.opening` are the same wait -- the sheet is up, the relay has not answered --
and they said it twice with a different title each time, so the first four hundred milliseconds of
pairing were three different looks and nothing spinning. One title, one sentence (the two pictures
are now byte-identical), and a small spinning indicator that appears only after 300 ms, so a relay
that answers in 400 never spins at all. Which states may spin is `PairingFlow.showsProgress`, in
Core.

Return does something on the last two states: "Done" and "Close" were being moved onto the Cancel
button, which carries ⎋, so the two sheets where pressing Return is the only thing anyone wants had
no default button at all. The word stays on the primary button and ⎋ is answered by the sheet.

The client's `K7M-4QZ` placeholder is gone -- grey, centred, inside the box, it read as a filled
value and got pressed -- and is a caption under the field; and the Remote page says which Mac
presses which of its two Pair buttons.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: The Remote page says what a remote session is

**Files:**
- Create: `Sources/NyxCore/Remote/RemotePageStatus.swift` — the four sentences, `blocksPairing`, and the page's copy
- Modify: `Sources/NyxApp/SettingsWindowController.swift` — the two sentences above the grid, the status line moved under the pairing row, the `Device name` placeholder, the snapshot-lines caption
- Test: `Tests/NyxCoreTests/RemotePageStatusTests.swift` (new)

**Interfaces:**
- Consumes (Task 5): `AuditLine.display(_:now:)`, already drawn into `setActivityText` there — this task does not touch Recent activity again. (Task 8): the pairing caption under the two Pair buttons, which the status line now hangs off.
- Produces:

```swift
public enum RemotePageStatus {
    public static func text(mode: RemoteMode, relay: String, token: String) -> (sentence: String, blocksPairing: Bool)
}
public enum RemotePageCopy {
    public static let what: String     // what a remote session is
    public static let relay: String    // where a relay comes from
    public static func snapshotCost(lines: Int) -> String
}
```

- [ ] **Step 1: Write the failing tests** — `Tests/NyxCoreTests/RemotePageStatusTests.swift`:

```swift
import Testing
@testable import NyxCore

/// Spec §5.3, pulled forward: the owner's Pair button was disabled and the reason was ~300 px away
/// with a table between, so they did not see it. The sentence is decided here and drawn beneath the
/// buttons it explains.
@Test func theFourRemotePageSentencesAreExact() {
    #expect(RemotePageStatus.text(mode: .off, relay: "wss://r/v1/ws", token: "t")
        == ("Remote sessions are off — tick Enable remote sessions to pair.", true))
    #expect(RemotePageStatus.text(mode: .on, relay: "", token: "t")
        == ("Pairing needs a relay — set Relay above.", true))
    #expect(RemotePageStatus.text(mode: .on, relay: "wss://r/v1/ws", token: "  ")
        == ("Pairing needs a relay token — set Relay token above.", true))
    #expect(RemotePageStatus.text(mode: .on, relay: "wss://r/v1/ws", token: "t")
        == ("Ready to pair. Both Macs must reach the same relay.", false))
}

/// Being off outranks having no token: a feature that is switched off has nothing to fail at.
@Test func theSwitchOutranksTheFieldsBelowIt() {
    #expect(RemotePageStatus.text(mode: .off, relay: "", token: "").blocksPairing)
    #expect(RemotePageStatus.text(mode: .off, relay: "", token: "").sentence
        == "Remote sessions are off — tick Enable remote sessions to pair.")
}

/// §7.4: the page had one explanatory sentence, at the very bottom, under the activity log, about
/// the relay's metadata -- a long way from the token field it is about, and nothing at all about
/// what a remote session *is* or where a relay comes from. Both sentences live here so the picture
/// and the page cannot drift.
@Test func thePageExplainsItselfInTwoSentencesFromCore() {
    #expect(RemotePageCopy.what == "A remote session is a Nyx tab on another of your Macs, reached "
        + "through a relay both machines dial out to. Nyx never sends terminal text the relay can read.")
    #expect(RemotePageCopy.relay == "The relay URL and token come from the nyx-server you run; "
        + "Nyx cannot issue them.")
}

/// And what the one number on the page costs, because nothing said: 2,000 lines measured ~85 KB,
/// sealed and sent on every attach.
@Test func theSnapshotCostIsSaidInTheUnitTheUserSetIt() {
    #expect(RemotePageCopy.snapshotCost(lines: 2000)
        == "How much scrollback a Mac attaching to this one receives: about 85 KB at 2000 lines, "
        + "sent once per attach.")
    #expect(RemotePageCopy.snapshotCost(lines: 100).contains("about 4 KB at 100 lines"))
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter RemotePage 2>&1 | tail -8`
Expected: `cannot find 'RemotePageStatus' in scope`.

- [ ] **Step 3: The Core value.** `Sources/NyxCore/Remote/RemotePageStatus.swift`:

```swift
import Foundation

/// Why the Remote page's Pair buttons are disabled, in a sentence that names the remedy — and
/// whether they are disabled at all.
///
/// The owner pressed Pair on 2026-09-07, found it dead, and could not see why: the page's status
/// line was three hundred points above the buttons with a table of paired devices between them.
/// A disabled primary button has to explain itself *beside itself*. Keeping it disabled rather than
/// enabling it and routing to the empty field is the ruling of spec §5.3: an enabled button that
/// does not do what it says is a second lie on top of the first.
public enum RemotePageStatus {
    public static func text(mode: RemoteMode, relay: String,
                            token: String) -> (sentence: String, blocksPairing: Bool) {
        guard mode == .on else {
            return ("Remote sessions are off — tick Enable remote sessions to pair.", true)
        }
        guard !relay.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ("Pairing needs a relay — set Relay above.", true)
        }
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ("Pairing needs a relay token — set Relay token above.", true)
        }
        return ("Ready to pair. Both Macs must reach the same relay.", false)
    }
}

/// The Remote page's own words, in Core so that the page and its picture cannot drift and so the
/// sentences are read once, here, rather than in a layout method.
public enum RemotePageCopy {
    /// What the feature is. The page named the relay's metadata exposure at the very bottom and
    /// never said what a remote session was or where a relay came from -- which is the whole of
    /// what somebody setting this up for the first time needs.
    public static let what = "A remote session is a Nyx tab on another of your Macs, reached "
        + "through a relay both machines dial out to. Nyx never sends terminal text the relay can read."

    public static let relay = "The relay URL and token come from the nyx-server you run; "
        + "Nyx cannot issue them."

    /// What `Snapshot lines` costs. Measured: 2,000 lines of a real session sealed into six frames
    /// of about 85 KB, and it is sent again on every attach.
    public static func snapshotCost(lines: Int) -> String {
        let kb = max(1, Int((Double(lines) * 43.5 / 1024).rounded()))
        return "How much scrollback a Mac attaching to this one receives: about \(kb) KB at "
            + "\(lines) lines, sent once per attach."
    }
}
```

- [ ] **Step 4: The page draws them.** In `remotePage()`, four changes and one move.

  The two sentences, above the grid, so the page explains itself before it asks for anything:

```swift
        let whatLabel = NSTextField(wrappingLabelWithString: RemotePageCopy.what)
        let relayLabel = NSTextField(wrappingLabelWithString: RemotePageCopy.relay)
        for label in [whatLabel, relayLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
        }
```

  added to the subview list, pinned at 18 pt on both edges, `whatLabel` at 16 pt below
  `view.topAnchor` and `relayLabel` 6 pt under it — and `grid.topAnchor` now hangs off
  `relayLabel.bottomAnchor` at 12 pt rather than off `view.topAnchor`.

  `remoteStatusLabel` **moves**: it sat 8 pt under the grid, ~300 pt above the buttons it explains,
  with the paired-devices table between them, which is why the owner pressed a dead Pair button on
  2026-09-07 and could not see why. It is constrained 6 pt under the pairing caption Task 8 puts
  below `pairButtons`, and `activityLabel` hangs off *it*:

```swift
            // Under the buttons it is about. A disabled primary button has to explain itself
            // beside itself (§5.3): this sentence names the one field standing between the user and
            // the button, and at the top of the page it was a sentence about a button nobody could
            // see from there.
            remoteStatusLabel.topAnchor.constraint(equalTo: pairCaption.bottomAnchor, constant: 6),
            remoteStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            remoteStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            activityLabel.topAnchor.constraint(equalTo: remoteStatusLabel.bottomAnchor, constant: 12),
```

  with `pairedLabel.topAnchor` now hanging off `grid.bottomAnchor` at 12 pt, which is the constraint
  the status label used to occupy. **One anchor per view, once**: the old
  `remoteStatusLabel.topAnchor` → `grid.bottomAnchor` and `pairedLabel.topAnchor` →
  `remoteStatusLabel.bottomAnchor` constraints are *deleted*, not added to, or the page lays out
  ambiguously — which is the defect plan 4 exists to fix in the request editor and must not be
  introduced here.

  The `Snapshot lines` caption, in the row under it:

```swift
        let snapshotCaption = NSTextField(wrappingLabelWithString: RemotePageCopy.snapshotCost(
            lines: config.remoteSnapshotLines))
        snapshotCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        snapshotCaption.textColor = .secondaryLabelColor
        snapshotCaption.identifier = NSUserInterfaceItemIdentifier("remote-snapshot-lines.caption")
        controls["remote-snapshot-lines.caption"] = snapshotCaption
```

  as a second grid row under the stepper (`row("", snapshotCaption)`, so it lines up with the
  control rather than the label), and re-read in `refresh` beside the field's own value, because the
  number it quotes is the number the user just typed:

```swift
        (controls["remote-snapshot-lines.caption"] as? NSTextField)?.stringValue =
            RemotePageCopy.snapshotCost(lines: config.remoteSnapshotLines)
```

  (`controls` is `[String: NSControl]` and `NSTextField` is one, which is how `diagnosticsLabel`'s
  siblings already live there.)

  And `Device name`'s placeholder stops reading as a value (§5.1 item 8's app-wide rule, the half of
  it this page owns): `SettingsWindowController.localHostName` is a real machine name — `Никита's
  MacBook Pro` on the owner's Mac — sitting greyed in an empty box, so it reads as the name already
  set. The field keeps the placeholder and the *caption* says what an empty field means:

```swift
            row("Device name", textField("remote-device-name",
                                         placeholder: "e.g. \(SettingsWindowController.localHostName)")),
```

  Two words in front of it is the whole fix, and it is the cheapest half of the rule: `e.g.` cannot
  be mistaken for a value, and the name is still the useful hint (it is what this Mac will announce
  if the field is left empty).

- [ ] **Step 5: The Pair buttons say why they are dead.** `refreshRemoteStatus` currently shows the
      *connection's* sentence, which is the right sentence once the feature runs and the wrong one
      while it cannot. `RemotePageStatus` outranks it whenever it blocks:

```swift
    private func refreshRemoteStatus() {
        // Why the buttons are dead comes first, and names the remedy. What the connection is doing
        // is only interesting once there can be one.
        let gate = RemotePageStatus.text(mode: config.remote, relay: config.remoteRelay,
                                         token: config.remoteRelayToken)
        let text: String
        if gate.blocksPairing {
            text = gate.sentence
        } else {
            let connection: RemoteStatusText.Connection =
                RemoteCoordinatorPolicy.needsToken(config: config) ? .needsToken : .connecting
            text = coordinator?.statusText
                ?? RemoteStatusText.text(mode: config.remote, connection: connection,
                                         deviceName: RemoteDeviceName.resolve(
                                            configured: config.remoteDeviceName,
                                            hostName: SettingsWindowController.localHostName))
        }
        remoteStatusLabel.stringValue = text
        remoteStatusLabel.setAccessibilityValue(text)
        // §5.3: the same sentence on both buttons, so the reason is reachable from the control that
        // is refusing rather than only from the label beside it.
        for control in remotePairControls { control.setAccessibilityHelp(gate.sentence) }
    }
```

  and `refreshRemoteEnabled` keeps `RemoteCoordinatorPolicy.shouldRun` as the enable rule — the two
  agree by construction (`shouldRun` is `remote == .on && !needsToken`, and `blocksPairing` is that
  plus the empty relay, which `shouldRun` does not look at), so **the one thing to check here is
  that a config with a token and no relay URL disables the buttons.** It does not today: `shouldRun`
  is true, the buttons are live, and `pairAsHost` opens a sheet against a relay address that is the
  empty string. `gate` is local to `refreshRemoteStatus`, so `refreshRemoteEnabled`
  (`SettingsWindowController.swift:369-372`) recomputes it rather than reading a field:

```swift
        let gate = RemotePageStatus.text(mode: config.remote, relay: config.remoteRelay,
                                         token: config.remoteRelayToken)
        for control in remotePairControls { control.isEnabled = !gate.blocksPairing }
```

  replacing the two `RemoteCoordinatorPolicy.shouldRun` lines there. It is the same answer in every
  case `shouldRun` covers and the right one in the case it does not.

- [ ] **Step 6: Announce the sentence when it appears.** §8.1 lists the settings window's
      diagnostics label as an announcement site, and this sentence is the one a person is looking for
      after pressing a dead button:

```swift
        if text != remoteStatusLabel.stringValue { Announce.say(text) }
```

  before the assignment in `refreshRemoteStatus`. `Announce.say` is a no-op for an empty string and
  the guard stops the page talking on every refresh, which `remoteChanged()` calls on every presence
  message.

- [ ] **Step 7: Tests, pictures**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/nyx-6-remote ./build/Nyx.app/Contents/MacOS/Nyx
```
Expected: `0` warnings, PASS. Then **look at** `settings-remote-{light,dark}.png` and
`settings-remote-off-{light,dark}.png`: two sentences at the top, the status line immediately under
the two Pair buttons with the caption above it, `Recent activity` in relative ages (Task 5), a
caption under `Snapshot lines` saying what it costs, and `e.g.` in front of the device-name
placeholder. §8.5 names one new case for this wave, `settings-remote-explained` — the two existing
`settings-remote-*` pictures *are* that case once these labels are in them, so retake them rather
than adding a third name, and say so in the commit message.

  Also `cmp` the pair: the settings window is an AppKit surface the theme never touches, so
  `settings-remote-light.png` and `settings-remote-dark.png` are a `<case>-<appearance>` pair and
  are *expected* to differ. Nothing to prove there; the check is that the layout is identical
  between them and that no label is truncated in either.

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxCore/Remote/RemotePageStatus.swift \
        Sources/NyxApp/SettingsWindowController.swift \
        Tests/NyxCoreTests/RemotePageStatusTests.swift
git commit -m "$(cat <<'EOF'
The Remote page says what a remote session is, and why Pair is dead

Two sentences at the top, decided in Core beside `RemotePageStatus` so the page and its picture
cannot drift: what a remote session is, and where a relay comes from. The page had neither. Its one
explanatory sentence was about the relay's metadata exposure, at the very bottom, under the activity
log — a long way from the token field it is about — so somebody setting this up for the first time
was reading a form with no idea what it was a form for.

And the sentence saying why the Pair buttons are disabled moves to underneath them. It was ~300 px
above, with the paired-devices table in between, which is why the owner pressed a dead button on
2026-09-07, could not see the reason, and reported it as a bug: a disabled primary button has to
explain itself beside itself (§5.3). The same sentence is the buttons' accessibility help, and it is
announced when it changes. A token with no relay URL now disables them too — `shouldRun` never
looked at the relay address, so that configuration had two live buttons and a sheet that opened
against an empty address.

`Snapshot lines` says what it costs (about 85 KB at 2,000 lines, measured, sent once per attach) and
`Device name`'s placeholder gains `e.g.`, because a real machine name greyed inside an empty box
reads as the name already set.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: The tab bar offers a remote tab, where a person looks for a new one

**Owner ruling, 2026-09-11.** A remote session can be opened two ways today: `Shell → Remote
Sessions…` (⌘⇧P's Remote rows, Task 5) and the `+` button, which opens a *local* tab. The tab bar is
where a person goes when they want a new tab, and right-clicking it is where they look for the kinds
of new tab there are — and right-clicking it does nothing at all. There are **two** `+` buttons and
neither answers: `TabBarView.rightMouseDown` (`Sources/NyxApp/TabBarView.swift:512-523`) answers
`.newTab` — the `+` *after the last tab* (`TabBarGeometry.swift:137-138`) — and `nil` — the empty
strip — with `break`, and it forwards `.leadingButton` only when the button under the pointer is a
`.quick`, so the leading `+` (`TabBarView.LeadingButton.newTab`, `:113-115`) is silent too. This task
makes all three a menu, and puts the remote sessions in it.

**Files:**
- Create: `Sources/NyxCore/Remote/TabBarMenu.swift` — what the bar's menu offers, and why an item is dead
- Modify: `Sources/NyxApp/TabBarView.swift` — `onBarContextMenu`, and the two silent cases of `rightMouseDown`
- Modify: `Sources/NyxApp/TabController.swift` — the bar menu built from the Core items, and the same item at the end of a tab's own menu
- Modify: `Sources/NyxApp/RemoteCoordinator.swift` — `tabBarMenuItems(now:)`, the gate `paletteItems` already has
- Modify: `Sources/NyxApp/MenuSnapshot.swift` — two pictures, built from the Core items
- Modify: `docs/configuration.md` — one sentence in the remote paragraph
- Test: `Tests/NyxCoreTests/TabBarMenuTests.swift` (new)

**Interfaces:**
- Consumes (Task 5): `RemoteCatalogue.devices`, `RemoteCatalogue.detail(for:now:home:)` and the
  `shortCommand` cut inside it — the menu's session rows are the palette's rows, word for word, so
  the two places a session is offered cannot describe it two ways. Also `TabController.showRemoteSessions`,
  which is where "New Remote Tab…" goes: one spelling of "the Remote rows", not a second list.
- Consumes (Task 9): `RemotePageStatus.text(mode:relay:token:)` — the same four sentences the Remote
  page shows beneath its Pair buttons are what a dead "New Remote Tab…" says here. A fifth wording
  for "you have not set a token" is a fifth thing to keep true.
- **Not** consumed, deliberately: `RemoteCoordinatorPolicy.menuOutcome(config:)`. It answers the
  same question (`disabled` / `openSettings` / `act`) without the sentence, and the sentence is the
  whole point of this item — a greyed row that does not say why is the defect, not the fix. The two
  agree by construction: `menuOutcome` is `disabled` exactly when `remote != .on` and
  `openSettings` exactly when the token is empty, which are two of `blocksPairing`'s three
  branches; the third (a configured token with no relay URL) is the case `shouldRun` never looked at
  and Task 9 Step 5 fixes on the Remote page for the same reason.
- Consumes (already in the tree): `KeyBindingTable.binding(for:)` and
  `MenuShortcut.keyEquivalent(for:)` (`Sources/NyxApp/Actions.swift:46`, the function at `:50`) — the
  helper `MainMenu` applies at `MainMenu.swift:85-89` — `TerminalAction.newTab`,
  `NSMenu.popUpContextMenu` (already used at `TabController.swift:596`), `NSMenuItem.toolTip` and
  `setAccessibilityHelp(_:)`.
- **Not** used: `NSMenuItem.subtitle`. It is **macOS 14.4**, and this package's floor is 14.0
  (`Package.swift:23`) — checked, not assumed: `swiftc -target arm64-apple-macos14.0` answers
  `error: 'subtitle' is only available in macOS 14.4 or newer`. A session row is therefore **one
  line**, with the palette's detail joined to the palette's title by an em dash:
  `Mac mini (office) · zsh — ~/projects/nyx  main · running: swift test · 2 min ago`. No
  `if #available` fork, because the two branches would be two different menus to look at and to
  picture, and no raising of the floor, which is an owner's call and would drop three point
  releases for a second line. The join is `TabBarMenuItem.title`, in Core, so what a row reads is
  a tested value rather than a format string in a view controller.
- Produces:

```swift
/// One row of the tab bar's context menu.
public enum TabBarMenuItem: Equatable {
    case newTab
    case separator
    /// Opens the Remote rows (`TabController.showRemoteSessions`). `reason` is nil when it can act,
    /// and otherwise the sentence saying why it cannot -- `RemotePageStatus`'s, or the relay's
    /// refusal.
    case newRemoteTab(reason: String?)
    /// The sentence from the case above, as a row that *does* something: it opens Settings → Remote.
    /// Present only when `newRemoteTab` is dead.
    case openRemoteSettings(String)
    /// Attach to this session directly. `sessionTitle` and `detail` are the palette's own row
    /// wording; `title` joins them, because a menu row has one line.
    case session(deviceID: String, sessionID: String, sessionTitle: String, detail: String)

    public var title: String { get }
    public var isEnabled: Bool { get }
}

public enum TabBarMenu {
    /// `refusal` is non-nil only when the relay has let go of this device for good.
    public static func items(catalogue: RemoteCatalogue, remote: RemoteMode, relay: String,
                             token: String, refusal: String?, now: Date,
                             home: String = "") -> [TabBarMenuItem]
}
```

- [ ] **Step 1: Write the failing Core tests** — `Tests/NyxCoreTests/TabBarMenuTests.swift`:

```swift
import Foundation
import Testing
@testable import NyxCore

private let now = ISO8601DateFormatter().date(from: "2026-09-11T12:00:00Z")!

private func session(_ id: String, title: String, process: String = "zsh",
                     lastCommand: String = "", minutesAgo: Int = 2) -> RemoteSessionInfo {
    let at = ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    return RemoteSessionInfo(sessionID: id, title: title, cwd: "/home/nik/projects/nyx", repo: "nyx",
                             branch: "main", process: process, lastCommand: lastCommand,
                             lastActivity: at, cols: 80, rows: 24)
}

private func items(_ c: RemoteCatalogue, remote: RemoteMode = .on, relay: String = "wss://r/v1/ws",
                   token: String = "t", refusal: String? = nil) -> [TabBarMenuItem] {
    TabBarMenu.items(catalogue: c, remote: remote, relay: relay, token: token,
                     refusal: refusal, now: now, home: "/home/nik")
}

/// Nothing but a dead `New Remote Tab…` is ever greyed. Stated once, here, and asserted by name
/// rather than by an `allSatisfy` over a rule the type itself defines -- a separator answers
/// `isEnabled == true` precisely so a caller needs no special case, which makes "everything is
/// enabled or a separator" true of every list this builder can produce and therefore worth nothing.
private func disabledTitles(_ rows: [TabBarMenuItem]) -> [String] {
    rows.filter { !$0.isEnabled }.map(\.title)
}

/// The shape every state shares: a new tab, a rule, and the way to a remote one. The bar's menu is
/// not a second command palette -- it is the two kinds of tab there are.
@Test func theMenuAlwaysOffersANewTabAndAWayToARemoteOne() {
    let rows = items(RemoteCatalogue())
    #expect(rows[0] == .newTab)
    #expect(rows[1] == .separator)
    #expect(rows[2] == .newRemoteTab(reason: nil))
    #expect(rows[0].title == "New Tab")
    #expect(rows[2].title == "New Remote Tab\u{2026}")
    #expect(disabledTitles(rows).isEmpty)
}

/// Remote switched off. The item is dead and says the sentence the Remote page says, not a fifth
/// spelling of it -- and the sentence itself is a row that opens the page it names.
@Test func remoteSwitchedOffKillsTheItemInTheRemotePagesOwnWords() {
    let rows = items(RemoteCatalogue(), remote: .off)
    let reason = "Remote sessions are off — tick Enable remote sessions to pair."
    #expect(rows[2] == .newRemoteTab(reason: reason))
    #expect(!rows[2].isEnabled)
    #expect(rows[3] == .openRemoteSettings(reason))
    #expect(rows[3].isEnabled)                       // the reason is the one thing left to press
    #expect(rows[3].title == reason)
    #expect(rows.count == 4)                         // and nothing to attach to below it
    #expect(disabledTitles(rows) == ["New Remote Tab\u{2026}"])
    #expect(reason == RemotePageStatus.text(mode: .off, relay: "", token: "").sentence)
}

/// And `remote = off` is a *greyed row with a sentence*, not an empty menu. Said outright because
/// the obvious thing to copy from `RemoteCoordinator.paletteItems` is its
/// `guard config.remote == .on else { return [] }`, and copying it here would delete the one row
/// that explains why the other one is missing -- which no Core test would catch if this one did not
/// exist, since a menu with two rows in it looks perfectly reasonable.
@Test func remoteSwitchedOffIsAGreyedRowWithAReasonRatherThanNoRowAtAll() {
    let rows = items(RemoteCatalogue(), remote: .off, relay: "", token: "")
    #expect(rows.count == 4)
    #expect(rows.contains { $0.title == "New Remote Tab\u{2026}" })
    #expect(rows.contains { $0.title.hasPrefix("Remote sessions are off") })
}

@Test func anEmptyTokenKillsItWithTheTokensOwnSentence() {
    let rows = items(RemoteCatalogue(), token: "  ")
    let reason = "Pairing needs a relay token — set Relay token above."
    #expect(rows[2] == .newRemoteTab(reason: reason))
    #expect(rows[3] == .openRemoteSettings(reason))
}

/// A relay that has **refused** this device -- `bad_token`, `bad_signature`, `replaced` -- is a
/// different sentence from the configuration's, and it is the connection's. It is also the only
/// socket state that greys the item: it is not coming back without a `connect()`.
@Test func aRefusedRelayKillsItWithTheRefusalsOwnSentence() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session("s1", title: "zsh")])
    let refusal = "Relay refused this device (replaced)"
    let rows = items(c, refusal: refusal)
    #expect(rows[2] == .newRemoteTab(reason: refusal))
    #expect(rows[3] == .openRemoteSettings(refusal))
    #expect(rows.count == 4)
    #expect(disabledTitles(rows) == ["New Remote Tab\u{2026}"])
}

/// And every *other* socket state leaves it alone, which is the whole of T10-3: connecting,
/// reconnecting, backing off, or simply offline and retrying. The item's action is
/// `showRemoteSessions()`, which opens a **list** -- and `RemoteCoordinator.paletteItems` leads that
/// list with the status row precisely so an outage is explained where the user is looking. Greying
/// the route to the explanation at the moment it is wanted is the opposite of the fix.
@Test func aRelayThatIsMerelyBusyLeavesTheItemAndItsSessionsAlone() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session("s1", title: "zsh")])
    // Exactly the configuration of the test above, minus the refusal.
    let rows = items(c, refusal: nil)
    #expect(rows[2] == .newRemoteTab(reason: nil))
    #expect(rows.count == 4)                         // …and row 3 is the session, not a sentence
    #expect(rows[3].title.hasPrefix("Mac mini (office) · zsh — "))
    #expect(disabledTitles(rows).isEmpty)
}

/// Configured, connected, and nothing published. The item lives -- it opens the Remote rows, which
/// is where "no sessions" and "offline" are explained -- and there is nothing under it.
@Test func aWorkingRelayWithNothingOpenStillOffersTheWayIn() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true)])
    let rows = items(c)
    #expect(rows == [.newTab, .separator, .newRemoteTab(reason: nil)])
}

/// The everyday case: one Mac with two sessions, one asleep, one that unpaired this Mac. Only the
/// sessions a person can actually open get a row. The palette shows the other two as placeholders
/// because a paired Mac missing from a *search result* reads as a broken pairing; a context menu is
/// a list of verbs, and "iMac (studio) — offline" is not one.
@Test func onlyReachableSessionsGetARowAndTheyReadLikeThePalettesRows() {
    var c = RemoteCatalogue()
    c.setPaired(["d1": "Mac mini (office)", "d2": "iMac (studio)", "d3": "MacBook"])
    c.applyPresence([
        RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true),
        RemotePresence(deviceID: "d2", name: "iMac (studio)", online: false),
        RemotePresence(deviceID: "d3", name: "MacBook", online: false, notPaired: true),
    ])
    c.applyCatalogue(deviceID: "d1", sessions: [
        session("s1", title: "zsh", process: "swift test", lastCommand: "make test"),
        session("s2", title: "vim Pane.swift", process: "vim", lastCommand: "git status",
                minutesAgo: 60),
    ])
    let rows = items(c)
    #expect(rows.count == 5)
    let firstDetail = RemoteCatalogue.detail(for: session("s1", title: "zsh", process: "swift test",
                                                          lastCommand: "make test"),
                                             now: now, home: "/home/nik")
    #expect(rows[3] == .session(deviceID: "d1", sessionID: "s1", sessionTitle: "Mac mini (office) · zsh",
                                detail: firstDetail))
    // One line, because a menu row is one line: `NSMenuItem.subtitle` is macOS 14.4 and this
    // package's floor is 14.0. The words on either side of the dash are the palette's.
    #expect(rows[3].title == "Mac mini (office) · zsh — \(firstDetail)")
    #expect(rows[4].title.hasPrefix("Mac mini (office) · vim Pane.swift — "))
    #expect(disabledTitles(rows).isEmpty)
    // No row for the sleeping Mac and none for the one that unpaired this one.
    #expect(!rows.contains { $0.title.contains("iMac") })
    #expect(!rows.contains { $0.title.contains("MacBook") })
}

/// The cut is the palette's, because the wording is: a menu row is no more able to hold a pasted
/// `for` loop than a palette row was (D10).
@Test func aSessionRowsDetailIsCutTheSameWayThePalettesIs() {
    let long = String(repeating: "echo hello; ", count: 20)
    var c = RemoteCatalogue()
    c.setPaired(["d1": "iMac"])
    c.applyPresence([RemotePresence(deviceID: "d1", name: "iMac", online: true)])
    c.applyCatalogue(deviceID: "d1", sessions: [session("s1", title: "zsh", lastCommand: long)])
    let rows = items(c)
    guard case .session(_, _, _, let detail) = rows[3] else {
        Issue.record("no session row: \(rows)")
        return
    }
    #expect(detail.hasSuffix("\u{2026}"))
    #expect(detail.contains("2 min ago"))
    #expect(detail.contains(RemoteCatalogue.shortCommand(long)))
    #expect(rows[3].title.hasSuffix(detail))        // the row is the title and this, joined
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter TabBarMenu 2>&1 | tail -8`
Expected: `cannot find 'TabBarMenu' in scope`.

- [ ] **Step 3: The Core builder.** `Sources/NyxCore/Remote/TabBarMenu.swift`:

```swift
import Foundation

/// One row of the tab bar's context menu.
public enum TabBarMenuItem: Equatable {
    case newTab
    case separator
    /// Opens the Remote rows -- the same list `Shell → Remote Sessions…` opens, which is the one
    /// place the offline Macs, the Macs with nothing open and the relay's own status line are
    /// explained. `reason` is nil when it can act, and otherwise the sentence saying why not.
    case newRemoteTab(reason: String?)
    /// That sentence again, as a row that *does* something: it opens Settings → Remote, where the
    /// field it names lives. Present only when `newRemoteTab` is dead.
    ///
    /// A disabled row and nothing else was the defect the palette's relay-status row had (D4): the
    /// one row that names the user's problem was the one row that refused to act on it. The
    /// sentence is on the dead item as well, as help and as a tooltip, so a pointer resting on the
    /// thing that will not work is answered there.
    case openRemoteSettings(String)
    /// Attach to this session directly, without the palette in between: the bar's menu is where a
    /// person who knows which Mac they want goes.
    ///
    /// Two strings, joined by `title` into the one line a menu row has. `NSMenuItem.subtitle` would
    /// have given it the palette's two lines and is **macOS 14.4**, three point releases above this
    /// package's floor (`Package.swift:23`); an `if #available` fork would be two different menus to
    /// read and to picture. Kept apart here rather than pre-joined so a test can assert the detail
    /// is the palette's own -- which is the thing that must not drift.
    case session(deviceID: String, sessionID: String, sessionTitle: String, detail: String)

    public var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .separator: return ""
        case .newRemoteTab: return "New Remote Tab\u{2026}"
        case .openRemoteSettings(let sentence): return sentence
        // An em dash, not the `·` the detail uses internally between its own clauses: the reader
        // has to be able to see where the machine and the session stop and where they were.
        case .session(_, _, let sessionTitle, let detail):
            return detail.isEmpty ? sessionTitle : "\(sessionTitle) \u{2014} \(detail)"
        }
    }

    /// What a menu draws greyed. The separator answers `true` so a caller can say
    /// `item.isEnabled = row.isEnabled` without a special case; `NSMenuItem.separator()` has no
    /// enabled state to set.
    public var isEnabled: Bool {
        if case .newRemoteTab(let reason) = self { return reason == nil }
        return true
    }
}

/// What a right-click on the tab bar offers.
///
/// In Core because every decision in it is one: which of two sentences says why the remote half is
/// dead, whether a Mac's sessions are worth listing, and what a session row reads as. `NyxApp` has
/// no test target, and a menu assembled in a view controller is a menu nothing can ask a question
/// about -- which is how the bar came to have no menu at all for two of the four things a
/// right-click can land on.
public enum TabBarMenu {
    /// `refusal` is the connection's answer, and **only** the one answer that is final: the relay
    /// has let go of this device for a reason reconnecting cannot fix (`bad_token`, `bad_signature`,
    /// `replaced`). It is distinct from `RemotePageStatus`'s, which is the *configuration's*, and
    /// neither can be said in the other's words -- "set Relay token above" is wrong about a relay
    /// that has refused a token it was given, and "Relay refused this device" is wrong about a Mac
    /// that has never been given one.
    ///
    /// **Every other socket state is deliberately not a reason.** Connecting, reconnecting, backing
    /// off, offline-and-retrying: the row's action is "open the list of remote sessions", and that
    /// list leads with the status row saying what the socket is doing
    /// (`RemoteCoordinator.paletteItems`). Greying the route to the explanation at the moment it is
    /// wanted -- which is the moment the relay is struggling -- is the opposite of the fix, and it
    /// would take the session rows with it on every launch.
    public static func items(catalogue: RemoteCatalogue, remote: RemoteMode, relay: String,
                             token: String, refusal: String?, now: Date,
                             home: String = "") -> [TabBarMenuItem] {
        var rows: [TabBarMenuItem] = [.newTab, .separator]
        // The configuration first: a feature that is switched off has nothing to fail at, which is
        // the same ordering `RemotePageStatus` itself applies.
        let gate = RemotePageStatus.text(mode: remote, relay: relay, token: token)
        let reason = gate.blocksPairing ? gate.sentence : refusal
        rows.append(.newRemoteTab(reason: reason))
        if let reason {
            rows.append(.openRemoteSettings(reason))
            // And nothing below it. A configuration that cannot work has no catalogue, and a relay
            // that has refused this device has had its catalogue emptied already (Task 4 Step 6),
            // so the early return is what the loop below would produce anyway -- said outright
            // because a reader should not have to prove that to themselves.
            return rows
        }
        // Only what can actually be opened. The palette lists a sleeping Mac and a Mac with nothing
        // published as greyed placeholders, because in a list you produce by *typing* a paired Mac
        // that is simply missing reads as a broken pairing. A context menu is a list of verbs, and
        // it has "New Remote Tab…" above it for the rest.
        for device in catalogue.devices where device.online && !device.notPaired {
            for session in device.sessions {
                rows.append(.session(deviceID: device.id, sessionID: session.sessionID,
                                     sessionTitle: "\(device.name) · \(session.title)",
                                     detail: RemoteCatalogue.detail(for: session, now: now,
                                                                    home: home)))
            }
        }
        return rows
    }
}
```

- [ ] **Step 4: The bar's two silent cases become a menu.** In `TabBarView`, one callback beside the
      three it already has (`:44-58`):

```swift
    /// A right-click on the bar itself -- the `+` button, or the empty stretch after the last tab.
    /// Both used to do nothing at all, which is the wrong answer twice: the tab bar is where a
    /// person looks for the kinds of new tab there are.
    var onBarContextMenu: ((NSEvent) -> Void)?
```

  and `rightMouseDown` (`:512-523`) stops answering with `break`, in **three** places rather than
  two — the `+` a person clicks is usually the leading one:

```swift
        case .leadingButton(let index):
            let buttons = resolvedLeading.buttons
            switch buttons.indices.contains(index) ? buttons[index] : nil {
            case .quick(let action)?:
                onQuickActionContextMenu?(action, event)
            // The leading `+` and the `≡`, which are the bar's own controls rather than any tab's:
            // a right-click on either is a right-click on the bar. `.addQuickAction` and
            // `.overflow` keep their silence -- the first has a sheet of its own and the second is
            // already a menu, and neither is about opening a tab.
            case .newTab?, .tabList?:
                onBarContextMenu?(event)
            default:
                break
            }
        case .newTab, nil:
            onBarContextMenu?(event)
```

  `Hit.newTab` is the `+` **after the last tab** (`TabBarGeometry.swift:137-138`) and
  `LeadingButton.newTab` is the one at the far left (`TabBarView.swift:113-115`); they are different
  cases arriving by different routes, which is why the first draft of this step covered one of them
  and left the other silent. A tab, a group header and a quick-action chip each keep the menu they
  have.

- [ ] **Step 5: The controller builds it, and a tab's own menu gains the row.** In
      `RemoteCoordinator`, the accessor beside `paletteItems` (`:229-234`) — the same catalogue, and
      deliberately **not** the same gate:

```swift
    /// The tab bar's context menu, from the catalogue the palette's Remote rows come from.
    ///
    /// `paletteItems`' own `guard config.remote == .on else { return [] }` is *not* copied. An empty
    /// list is right for a palette section -- there is nothing to search -- and wrong for a menu,
    /// where the row saying "Remote sessions are off" is the only thing that explains why the other
    /// row is missing. `TabBarMenu` answers the `off` case with a greyed row and its sentence, and
    /// a test says so, because a two-row menu looks perfectly reasonable to a reader.
    func tabBarMenuItems(now: Date = Date()) -> [TabBarMenuItem] {
        TabBarMenu.items(catalogue: catalogue, remote: config.remote, relay: config.remoteRelay,
                         token: config.remoteRelayToken, refusal: relayRefusal,
                         now: now, home: NSHomeDirectory())
    }

    /// The sentence for a relay that has refused this device, or nil for every other state of the
    /// socket -- including connecting, reconnecting and offline, which are sockets that are busy
    /// rather than settled (see `TabBarMenu.items`).
    ///
    /// `statusSentence(droppedWhileOffline:)`, not `statusText`: reading `statusText` **consumes**
    /// `droppedWhileOffline` (`:208-224` -- "the line appears once per outage"), and a right-click
    /// must not be the thing that spends the one showing of that number the Remote page or the
    /// palette was about to give. Passing `0` asks for the same sentence without that clause, which
    /// a menu row has no room for anyway.
    private var relayRefusal: String? {
        guard case .failed = connection?.status else { return nil }
        return statusSentence(droppedWhileOffline: 0)
    }
```

  which means `statusText`'s body is factored in two, with the side effect left in exactly one of
  them:

```swift
    var statusText: String {
        let text = statusSentence(droppedWhileOffline: droppedWhileOffline)
        droppedWhileOffline = 0
        return text
    }

    /// Everything `statusText` says, with the "dropped while offline" clause under the caller's
    /// control, so a reader that is not the page or the palette can ask without spending it.
    private func statusSentence(droppedWhileOffline: Int) -> String {
        // ... today's `statusText` body (`:212-224`), unchanged except that it takes the count as a
        // parameter and does not zero the field ...
    }
```

  In `TabController`, the wiring beside the others (`:129-138`):

```swift
        tabBar.onBarContextMenu = { [weak self] event in self?.showBarMenu(event) }
```

  and the builder, beside `showTabMenu` (`:577`):

```swift
    /// The tab bar's own menu: the two kinds of tab there are, and the remote sessions that are
    /// open right now.
    ///
    /// Built from `TabBarMenu.items`, not assembled here: which row is dead and what it says
    /// instead are decisions, and `NyxApp` has no test target. A coordinator that is nil -- a
    /// window built before the application has one, and every snapshot run -- gets the local half,
    /// which is the honest answer rather than a menu that is missing while something loads.
    private func showBarMenu(_ event: NSEvent) {
        let rows = appDelegate?.remote?.tabBarMenuItems()
            ?? [.newTab, .separator, .newRemoteTab(reason: nil)]
        let menu = NSMenu()
        menu.autoenablesItems = false
        let bindings = KeyBindingTable(user: config.keybinds)
        for row in rows {
            guard row != .separator else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: row.title, action: selector(for: row), keyEquivalent: "")
            item.target = self
            item.isEnabled = row.isEnabled
            switch row {
            case .newTab:
                if let binding = bindings.binding(for: .newTab),
                   let (key, mask) = MenuShortcut.keyEquivalent(for: binding) {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = mask
                }
            case .newRemoteTab(let reason):
                // On the item, so a pointer resting on the thing that will not work is answered
                // there rather than only by the row underneath it.
                item.toolTip = reason
                item.setAccessibilityHelp(reason)
            case .session(let deviceID, let sessionID, _, _):
                // The title already carries the palette's detail -- `TabBarMenuItem.title` joins
                // them, because `NSMenuItem.subtitle` is macOS 14.4 and this package's floor is
                // 14.0. Nothing to set here but the two ids.
                item.representedObject = RemoteRow(deviceID: deviceID, sessionID: sessionID)
            case .openRemoteSettings, .separator:
                break
            }
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: tabBar)
    }

    /// One selector per kind of row. `openRemoteSettings` and the dead `newRemoteTab` share the
    /// page they are about; the dead one is simply not enabled.
    private func selector(for row: TabBarMenuItem) -> Selector? {
        switch row {
        case .newTab: return #selector(menuNewTab(_:))
        case .newRemoteTab: return #selector(menuNewRemoteTab(_:))
        case .openRemoteSettings: return #selector(menuOpenRemoteSettings(_:))
        case .session: return #selector(menuAttachRemote(_:))
        case .separator: return nil
        }
    }

    @objc private func menuNewTab(_ sender: Any?) { newTab() }

    /// The Remote rows, which is exactly what `Shell → Remote Sessions…` opens: one spelling of
    /// "the list of remote sessions", so the menu route and the keyboard route cannot drift.
    @objc private func menuNewRemoteTab(_ sender: Any?) { showRemoteSessions() }

    @objc private func menuOpenRemoteSettings(_ sender: Any?) {
        appDelegate?.openRemoteSettings(nil)
    }

    @objc private func menuAttachRemote(_ sender: Any?) {
        guard let row = (sender as? NSMenuItem)?.representedObject as? RemoteRow,
              let coordinator = appDelegate?.remote else {
            NSSound.beep()
            return
        }
        let described = coordinator.describe(deviceID: row.deviceID, sessionID: row.sessionID)
        openRemote(deviceID: row.deviceID, sessionID: row.sessionID,
                   hostName: described.hostName, title: described.title)
    }

    /// The two ids a session row carries. A box rather than the two strings on
    /// `representedObject`, for the same reason `TabAndGroup` exists: a menu stays open while the
    /// world moves, and an index would be stale by the time it is pressed. Ids are not.
    private final class RemoteRow: NSObject {
        let deviceID: String
        let sessionID: String
        init(deviceID: String, sessionID: String) {
            self.deviceID = deviceID
            self.sessionID = sessionID
        }
    }
```

  `openRemote(deviceID:sessionID:hostName:title:)` is the method the palette's own
  `.remoteSession` row already goes through (`TabController.run`, `:955-965`), so the dedupe, the
  "already open in another window" answer and the tab's title all come for free.

  The row-to-item half of that loop comes out into a method of its own, because a tab's menu needs
  it too — `showBarMenu` becomes
  `for item in menuItems(for: rows, bindings: bindings) { menu.addItem(item) }`:

```swift
    /// Turns the Core rows into `NSMenuItem`s, which is the only thing either caller does with
    /// them. A separator row becomes `NSMenuItem.separator()`.
    private func menuItems(for rows: [TabBarMenuItem],
                           bindings: KeyBindingTable) -> [NSMenuItem] {
        // ... the body of the loop above, appending to an array rather than to a menu ...
    }
```

  And the same offer at the end of a **tab's** menu, so a right-click anywhere on the bar reaches
  it. In `showTabMenu`, after the last item (`:594-595`, `Reset Title`) and before the
  `popUpContextMenu` at `:596`:

```swift
        menu.addItem(.separator())
        for item in remoteTabMenuItems() { menu.addItem(item) }
```

```swift
    /// `New Remote Tab…` and, when it is dead, the sentence saying why: the **tail** of the bar's
    /// own rows, from `.newRemoteTab` onward, through the same builder and the same
    /// row-to-`NSMenuItem` loop. One spelling, so a tab's menu and the bar's cannot disagree about
    /// whether it is dead or why.
    ///
    /// One row was the first draft of this, and it was the D4 defect rebuilt: the bar's menu showed
    /// the greyed item *and* the live sentence beneath it, and a tab's menu showed the greyed item
    /// alone with a tooltip. A greyed row that names the user's problem and offers nothing to do
    /// about it is exactly what this round went and fixed in the palette.
    ///
    /// The session rows are deliberately **not** here: a tab's menu is nine rows about that tab
    /// already, and `New Remote Tab…` opens the list. The bar's own menu is where the sessions are.
    private func remoteTabMenuItems() -> [NSMenuItem] {
        let rows = appDelegate?.remote?.tabBarMenuItems() ?? [.newRemoteTab(reason: nil)]
        let tail = rows.drop { if case .newRemoteTab = $0 { return false } else { return true } }
        let kept = tail.filter { if case .session = $0 { return false } else { return true } }
        return menuItems(for: Array(kept), bindings: KeyBindingTable(user: config.keybinds))
    }
```

- [ ] **Step 6: The pictures.** In `MenuSnapshot.run`, beside `menu-tab-*` (`:56-57`):

```swift
            for (caseName, menu) in tabBarMenus() {
                write(menu: menu, caption: "right-click the tab bar \u{2014} \(caseName)",
                      appearance: appearance, named: "menu-tab-bar-\(caseName)-\(name)",
                      into: directory)
            }
```

  with the two states, built **from the Core items** rather than retyped — `MenuSnapshot`'s other
  menus are reconstructions because their builders need a live controller, and this one does not:

```swift
    /// Two states, which are the two a person meets: a relay that is working with sessions on it,
    /// and the feature switched off. The rows come from `TabBarMenu.items`, so a picture cannot
    /// show a menu the product would not build.
    private static func tabBarMenus() -> [(String, NSMenu)] {
        let now = Date()
        let iso = ISO8601DateFormatter()
        var live = RemoteCatalogue()
        live.setPaired(["d1": "Mac mini (office)", "d2": "iMac (studio)"])
        live.applyPresence([
            RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true),
            RemotePresence(deviceID: "d2", name: "iMac (studio)", online: false),
        ])
        // The same two sessions `remotePalettePanel` builds (`UISnapshot.swift:1135-1146`), copied
        // because that method is `private static` in another file -- so the palette's picture and
        // this one describe the same fixture Macs. `iso` and `now` are its two locals.
        live.applyCatalogue(deviceID: "d1", sessions: [
            RemoteSessionInfo(sessionID: "s1", title: "zsh", cwd: NSHomeDirectory() + "/projects/nyx",
                              repo: "nyx", branch: "feat/remote-sessions", process: "swift test",
                              lastCommand: "make test",
                              lastActivity: iso.string(from: now.addingTimeInterval(-120)),
                              cols: 120, rows: 40),
            RemoteSessionInfo(sessionID: "s2", title: "vim Pane.swift",
                              cwd: NSHomeDirectory() + "/projects/nyx", repo: "nyx", branch: "main",
                              process: "vim", lastCommand: "git status",
                              lastActivity: iso.string(from: now.addingTimeInterval(-3600)),
                              cols: 120, rows: 40),
        ])
        return [
            ("sessions", menu(rows: TabBarMenu.items(catalogue: live, remote: .on,
                                                     relay: "wss://nyx.agentforge.cc/v1/ws",
                                                     token: "t", refusal: nil, now: now,
                                                     home: NSHomeDirectory()))),
            ("off", menu(rows: TabBarMenu.items(catalogue: RemoteCatalogue(), remote: .off,
                                                relay: "", token: "", refusal: nil,
                                                now: now, home: NSHomeDirectory()))),
        ]
    }
```

  `menu(rows:)` is Step 5's loop without the targets and without the chord (a picture needs
  neither) — the titles come from `TabBarMenuItem.title`, so the rows in the picture are the rows
  the product builds.

  **The session rows are long**, because each is the palette's title and its whole detail on one
  line. `MenuSheetView` takes its width from `NSMenu.size.width` (`MenuSnapshot.swift:343`), which
  is AppKit's own measurement of those titles, so the panel grows to fit them; the *height* is
  `rows × 24 + separators × 8` (`:345-348`), which is unaffected because every row is one line.
  Look at the picture and check the two long rows are not cut at the panel's edge — and if the
  stderr warning at `:358` fires, it is the caption width, which the same method already widens
  for.

- [ ] **Step 7: Say it in the documentation, and say what the keyboard does**

  In `docs/configuration.md`, in the remote-sessions paragraph (the one beginning "Remote sessions
  need both `remote = on`"), one sentence:

  > **Right-clicking the tab bar** — either `+`, the `≡`, the empty strip after the last tab, or a
  > tab itself — offers `New Remote Tab…`, which opens the same list `Shell → Remote Sessions…`
  > does. On the bar (not on a tab) the sessions that are open on your other Macs are listed under
  > it and attach when pressed. With remote sessions off, with no relay token, or with a relay that
  > has refused this Mac, the item is greyed and says which; the sentence beneath it opens
  > Settings → Remote.

  **The keyboard path already exists and no new action is needed**: every row of this menu is
  reachable without a mouse — `Shell → Remote Sessions…` (`remote_sessions`, also in ⌘⇧P) opens the
  same Remote rows, `New Tab` is ⌘T, and Settings → Remote is ⌘,. §8.2's rule is that a
  mouse-reachable action needs a keyboard path, not that every *route* needs a second one; this task
  adds a route, not an action, which is why it adds no `TerminalAction` and no row to
  `docs/configuration.md`'s bindings table.

- [ ] **Step 8: Tests, pictures, ladder**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
make bench
./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/nyx-6-barmenu ./build/Nyx.app/Contents/MacOS/Nyx
```
Expected: `0` warnings, PASS, bench ≥ 180 MB/s (nothing here is in the render path). Then **look at**
`menu-tab-bar-sessions-{light,dark}.png` and `menu-tab-bar-off-{light,dark}.png`: the chord on
`New Tab`, the two session rows each reading `<Mac> · <session> — <the palette's detail>` on one
line and not cut at the panel's edge, and — in the `off` pair — a greyed `New Remote Tab…` with the
Remote page's own sentence live beneath it.

  This is chrome on the tab bar, so it is also a **rung 6** item and Task 11 Step 4 carries it: a
  right-click on the `+` button, on the empty strip and on a tab, each through the real
  `rightMouseDown`, with the menu's titles printed — a menu built in a view controller is exactly
  the kind of thing that compiles, tests green, and puts nothing on screen.

- [ ] **Step 9: Commit**

```bash
git add Sources/NyxCore/Remote/TabBarMenu.swift Sources/NyxApp/TabBarView.swift \
        Sources/NyxApp/TabController.swift Sources/NyxApp/RemoteCoordinator.swift \
        Sources/NyxApp/MenuSnapshot.swift Tests/NyxCoreTests/TabBarMenuTests.swift \
        docs/configuration.md
git commit -m "$(cat <<'EOF'
A right-click on the tab bar offers the other kind of tab

There were two ways to open a remote session and neither was where a person looks for a new tab:
`Shell → Remote Sessions…` and the palette. The `+` button makes a local one, and right-clicking the
bar -- the button, or the empty strip after the last tab -- did nothing whatsoever: `rightMouseDown`
answered both of those cases with `break`. Both open a menu now, and so does the end of a tab's own
menu: New Tab with its chord, then `New Remote Tab…`, then the sessions that are open on the other
Macs right now, each attaching directly.

What the menu offers is `TabBarMenu` in Core, because all of it is a decision: a session row reads in
the palette's own words (the same `detail`, the same cut command), only sessions that can actually be
opened get a row -- a menu is a list of verbs, where the palette's greyed "offline" placeholders
belong because a paired Mac missing from a *search result* reads as a broken pairing -- and when the
remote half is dead it says why in the sentence the Remote page says, with that sentence live
underneath as a row that opens the page it names. A disabled row that names the problem and refuses
to act on it is the defect the palette's relay-status row had, and it is not being rebuilt here.

Nothing new is reachable only by mouse: every row has a keyboard route already (⌘T, `remote_sessions`
from the Shell menu and ⌘⇧P, ⌘, for the settings), so this adds a route rather than an action.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: The ladder, and the QA run that found all of this, run again

**Nothing in this task changes the product.** It is the evidence, and it is a task rather than a
paragraph because every defect in `qa-remote.md` reached a shipped build through "it compiles" and
"the tests pass". Two instances, driven the way a person drives them, against both relays.

**Files:**
- Temporary: `Sources/NyxApp/QASmoke.swift` and nine one-line hooks (see Step 3) — **created in this
  task and deleted in Step 7.** Nothing here is committed.
- No product file changes. If this task finds something that needs one, it is a defect against the
  task that introduced it: go back and fix it there, in that task's own commit.

**Interfaces:**
- Consumes: everything Tasks 1–10 produced, through the product's own entry points only —
  `Pane.keyDown`, `Pane.paste`, `NSMenuItem` validation and action, `CommandPalette.moveSelection`
  and its run, `TabController.perform`, `SettingsWindowController`'s real fields and buttons.
- Produces: the task report. No code.

- [ ] **Step 1: Rungs 1–3, on a clean build**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
swift build -c release 2>&1 | grep -cE "error|warning:"
pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel 2>&1 | tail -5
make bench; make bench; make bench
cd ~/projects/nyx-server && PATH=/opt/homebrew/bin:$PATH make vet && PATH=/opt/homebrew/bin:$PATH make test
```
Expected: `0` and `0`; every test passing with a **count** in the report (the QA's baseline was 2111
passing, 1 skipped, and this plan writes tests into **fifteen** files across its eleven tasks — the
fourteen the Files lists name (four of them new: `TranscriptBufferTests`, `RemoteAnnouncementTests`,
`RemotePageStatusTests`, `TabBarMenuTests`) plus `RemoteMessageTests`, which Task 3 Step 3 adds the
absent-`not_paired` case to — so the number must have gone up, and by roughly the number of `@Test`
functions the plan wrote); bench ≥ 180 MB/s on all three runs, which
it must be because **nothing in this plan touches `NyxRender`, `VTParser` or `Terminal.feed`** — a
bench figure below the floor here is a measurement of the machine's load, and the fix is to run it
again in a quiet minute, not to accept it; `ok` for `protocol`, `relay` and `server`.

- [ ] **Step 2: Rungs 4 and 5, and the pictures this plan is responsible for**

Run:
```bash
./scripts/bundle.sh
NYX_UI_SNAPSHOT=/tmp/nyx-6-final ./build/Nyx.app/Contents/MacOS/Nyx
NYX_SNAPSHOT=1 swift test --filter Snapshot 2>&1 | tail -5
cd /tmp/nyx-6-final && ls | wc -l
for f in remote-strip-*-dark.png; do
  cmp -s "$f" "${f%-dark.png}-light.png" && echo "IDENTICAL $f" || echo "DIFFERS   $f"
done | sort | uniq -c
```
Expected: **823** — the QA's 811, plus the eight new narrow strip pictures (Task 7 Step 6, D9c: two
states × `chromePalettes(default:)`, which returns exactly two (`UISnapshot.swift:1278-1281`) × two
appearances), plus the four `menu-tab-bar-{sessions,off}-{light,dark}` (Task 10 Step 6 —
`MenuSnapshot.run` writes into this same directory). If the count is not 823, one of those loops is
not running; check that before reading anything else. **Every** `remote-strip-*` pair `IDENTICAL`,
including all eight button-bearing states that differed at the QA; and `NYX_SNAPSHOT=1` green.

Then **look at**, one at a time, and say in the report what each shows:
`remote-strip-observer-nyx-light-dark.png` (the worst case the QA measured at 1.46:1),
`remote-strip-clipped-narrow-*-*.png`, `command-palette-remote-*.png` (no greyed row highlighted),
`command-palette-mixed-remote-*.png` (the age survives), `pairing-host-idle-*.png` versus
`pairing-host-opening-*.png` (byte-identical), `pairing-client-idle-*.png` (an empty field with a
caption, not a grey code inside it), `pairing-{host,client}-{paired,failed}-*.png` (one button
carrying the state's own word), `settings-remote-{light,dark}.png`,
`settings-remote-off-{light,dark}.png`, and `menu-tab-bar-{sessions,off}-{light,dark}.png` (the two
session rows on one line each, and the greyed row with its live sentence).

- [ ] **Step 3: Rung 6 — build the hook back**

The QA's `NYX_SMOKE_QA=remote` hook **does not exist in the tree**: it was removed at the end of that
run, as it must be (`grep -rn "QASmoke\|NYX_SMOKE_QA" Sources/` finds nothing but one stale mention
in a comment in `Sources/NyxCore/Config/MenuKeyEquivalent.swift`). So it is built again, from the
table in `.superpowers/sdd/2026-09-07-ux-round/qa-remote.md` § *Hooks*, which lists every file it
touched and what it added to each:

| File | What to add back |
|---|---|
| `Sources/NyxApp/QASmoke.swift` | the whole hook: a `NYX_SMOKE_QA=remote` command-file driver, the wire/status/frame taps, a `PairingFlow.State` describer |
| `Sources/NyxApp/AppDelegate.swift` | `QASmoke.start(delegate: self)` in `applicationDidFinishLaunching`; `qaControllers`, `qaSettingsType`, `qaSettingsClose`, `qaDumpRemoteSettings` |
| `TerminalWindowController` / `TabController` / `Pane` / `RemoteStripView` / `SettingsWindowController` / `CommandPaletteView` | the read-only accessors that run's report names, in extensions |
| `Sources/NyxApp/RemoteCoordinator.swift` | three tap lines: `QASmoke.shared?.wire(message)` in `received`, `wireStatus` in `statusChanged`, `frame(…)` in the binary delegate |

Every command must go through the product's own entry point. A probe that reads a view's private
state is a hint the decision belongs in `NyxCore` — and in this plan most of them now do, so the
hook should be *smaller* than the QA's: `AttachState.badge`, `RemoteCatalogue.paletteItems`,
`CommandPalette.selection`, `AuditLine.display`, `RemotePageStatus.text` and
`AttachState.stripLabelOptions` are all answerable by rung 2 and need no accessor at all.

- [ ] **Step 4: Rung 6 — the local relay, with the fix**

```bash
cd ~/projects/nyx-server && PATH=/opt/homebrew/bin:$PATH make run &     # 127.0.0.1:8787, dev-token
S=/private/tmp/claude-501/*/scratchpad/qa6 && mkdir -p $S/a $S/b
for d in $S/a $S/b; do
  printf 'remote = on\nremote-relay = ws://127.0.0.1:8787/v1/ws\nremote-relay-token = dev-token\nremote-device-name = %s\n' "$(basename $d)" > $d/config
done
NYX_CONFIG=$S/a NYX_SMOKE_QA=remote ./build/Nyx.app/Contents/MacOS/Nyx &
NYX_CONFIG=$S/b NYX_SMOKE_QA=remote ./build/Nyx.app/Contents/MacOS/Nyx &
```

Throwaway configs inside the session scratchpad, never `~/.config/nyx`. The nine checks below are
the QA's own measurements re-taken; each one has a **before** number from `qa-remote.md` and an
**after** criterion, and the report gives both.

| # | What | Before (2026-09-10) | After |
|---|---|---|---|
| 1 | Two clients attached, nothing touched, **ten minutes** | `relay-status offline` every 91 s; 3 reconnects in 4m30s | **zero** `relay-status offline`; the relay log prints `online` once per device and nothing after |
| 2 | The writer's role, polled every 3 s through one cycle | 14 × writer, **4 × observer (~12 s)**, 24 × writer | writer for every sample; no `role` message at all while nothing changes |
| 3 | A unique marker echoed once, counted over the whole transcript after 4m30s | **8** on the client against 2 on the host; 3308 rows against 2007 | **2** on the client and 2 on the host; the client's row count equals the host's |
| 4 | Bytes re-encrypted per client per cycle | ~85 KB (six frames, counter back at zero) | **0**: no frame is sent for an idle session, and a resume sends `attached` and `snapshot_end` with nothing between them |
| 5 | Unpair from the host while a client is attached | client says "beta has been offline since 21:17 — waiting for it to come back", `acceptsInput=true`, for ever | the tab says **"This device was removed from your paired devices"**, refuses input, and the host's rows leave ⌘⇧P |
| 6 | Attach while the host is in `vim /tmp/x` | client: `visibleBlocks=1`, `alt=false`, vim's tildes in its primary buffer; after `:q!` the tildes stay | client: the host's block count (7 in the QA), `alt=true` on both, identical rows; `:q!` restores the primary buffer on both sides identically |
| 7 | Resize the host to 132×40 while a client watches | client stays 27×15 and every line wraps | client's grid follows within one debounce; the strip's geometry note appears and disappears with it |
| 8 | Paste a token into Settings → Remote and close the window with ⌘W, no Return | `grep` of the config file shows the old value | the new value is in the file, and the page shows it after the reload |
| 9 | `printf 'remote-device-name = renamed\n' >> $NYX_CONFIG/config` and, separately, an `os.replace` | the append was **never noticed**; only the replace was | **both** noticed within a second; and `grep -v remote-relay-token` written back over the file takes this Mac off the relay without a restart |

Plus the three D-items that only a run can show: ⌘⇧P → the relay-status row → ⏎ opens Settings →
Remote (not a beep); `Shell → Remote Sessions…` → ⏎ opens the top session (not the same palette);
and the pairing sheet's spinner, which is in no picture because `UISnapshot` renders a state
synchronously 300 ms before it appears — pair against the local relay and watch whether it appears
at all (it should not: the local relay answers in ~400 ms, and 300 of those are the delay).

And Task 10's menu, which is the one piece of this plan that is *only* reachable with a pointer and
therefore cannot be checked any other way. Post a right-click through the real `rightMouseDown` at
**four** places — the leading `+`, the `+` after the last tab, the empty strip beyond it, and a tab
itself — and print the titles and the enabled flags of what comes back. Four things to see: a menu
appears in each of the four (it appeared in none of the first three before this plan); the session
rows are the sessions the palette is showing at that moment, in the same words, each on one line;
a **tab's** menu carries `New Remote Tab…` and no session rows; and with `remote = off` in the
instance's config every one of those menus greys that row and carries the Remote page's own sentence
live beneath it. Then press a session row and watch the tab open and attach.

- [ ] **Step 5: Rung 6 — the live relay, with the fix deployed**

Repeat checks 1, 5 and 6 with `remote-relay = wss://nyx.agentforge.cc/v1/ws` and
`remote-relay-token = "$(cat ~/projects/nyx-server/token)"` — **written into the throwaway config
with a shell substitution and never echoed.** This is the run Task 1's deploy exists for, and check
1 over ten minutes is the one that proves the container really is the new build.

Then the compatibility half, which runs the **old relay locally** — **the deployed relay is never
rolled back, and nothing in this step touches `nyx.agentforge.cc`** (controller ruling; the deploy
was pre-approved, a rollback was not):

```bash
cd ~/projects/nyx-server
git worktree add /private/tmp/claude-501/*/scratchpad/relay-prefix <the commit before Task 1's>
cd /private/tmp/claude-501/*/scratchpad/relay-prefix
PATH=/opt/homebrew/bin:$PATH go build -o bin/nyx-relay ./cmd/nyx-relay
./bin/nyx-relay -listen 127.0.0.1:8788 -token dev-token &
```

One throwaway instance pointed at `ws://127.0.0.1:8788/v1/ws`, paired against *that* relay, and two
things recorded: unpairing from the other side leaves `not_paired` **absent**, so the palette row
reads `offline` and the tab reaches `AttachFailure.unpaired` only when it presses the row and the
relay answers `error not_paired` (Task 4 Step 6's belt) — not a crash, not a blank row; and a
forwarded `role` arrives with no `cols`/`rows`, so `handleRole(role, cols: nil, rows: nil)` leaves
the mirror's size exactly as it was rather than resizing it to zero. Kill the relay and
`git worktree remove` the checkout when it is done.

That is the whole degradation claim, exercised. The two Core tests Task 3 and Task 4 wrote for an
absent `not_paired` and an absent `cols`/`rows` prove the same thing at rung 2; this is the rung-6
version, and it is cheap because the old relay is one `go build` away in a worktree.

- [ ] **Step 6: The two instances the QA left behind**

`~/.config/nyx-a` and `~/.config/nyx-b` are paired with each other and are the owner's own test
instances. Run the fresh-pairing check on **them** — unpair through Settings → Remote → Remove, then
pair again from nothing — because that is the pair the owner will use, and leave them paired, as the
QA did. Their `audit.log` files grow; that is what an audit log does. `~/.config/nyx` is never
touched and never paired with.

- [ ] **Step 7: Remove the hook, and prove it is gone**

```bash
rm Sources/NyxApp/QASmoke.swift && git checkout -- Sources/
git status --short
grep -rn "QASmoke\|qaControllers\|NYX_SMOKE_QA\|TEMPORARY QA" Sources/ Tests/
swift build -c release 2>&1 | grep -cE "error|warning:"
./scripts/bundle.sh
```
Expected: `git status --short` shows nothing under `Sources/`; the grep finds only the one stale
mention in `MenuKeyEquivalent.swift`'s comment, which was there before this plan; `0`; and a bundle
that builds. Two commits in this project have had to be amended because `git add -A` swept a hook
in — `git add` by name, always, and check `git diff --stat` before every commit in this plan, not
only this one.

- [ ] **Step 8: The report, and the gate**

There is nothing to commit here. The report says, in this order: which rungs ran and what they
printed (test count, three bench figures, PNG count); the nine before/after rows of Step 4 with both
numbers in each; Step 5's three live-relay rows; Task 1's three deploy lines; the pictures looked at
and what each showed; and every DEGRADED item deferred to the ledger with the reason from the list
below. Then ask the `product-manager` agent, which is the gate (`docs/workflow.md`).

A report that says "tests pass" without a count, or quotes a bench figure from a commit message
instead of a run, is the shape of every report in this project that later turned out to be wrong.

---

## Deferred to the ledger

Written into `.superpowers/sdd/2026-09-07-ux-round/plan-6-ledger.md` at the end of the plan, in the
shape the 1a and 1b ledgers use, so the round's close can pick them up. Every one of them is real;
none of them is a reason a person stops using remote sessions, which is the bar this plan was
written to.

| Item | Why it is not here |
|---|---|
| **D4's better answer for the *other* two disabled rows** — an offline Mac's row could offer "Wake with Wake-on-LAN", and a Mac with nothing open could offer "Open a tab there". | Both are new product features (a magic packet; a remote `new_tab` verb that does not exist on the wire), not clarity fixes. The row stops being selectable, which is the defect. |
| **D6's strip offer** — "Remove this Mac from your paired devices" on a tab that has just been told `not_paired`. | It is a destructive action on a new surface, and the tab already says what happened and how to close it. Settings → Remote → Remove is two clicks away and is the one place unpairing has ever lived. |
| **D15's fingerprint re-check** — the paired table shows an 8-character id and a date, with no way to re-read the fingerprint two Macs confirmed. | It needs a new sheet and a decision about what to show when the peer is offline (the fingerprint is derived from both device ids, so it is computable — but a fingerprint shown without the other person reading theirs aloud is a ritual, not a check). Its own task, with its own picture. |
| **D15's `Device name` placeholder, the *app-wide* half** — the lens field's `.users[0].name` and the quick-action editor's `Caffeine`/`caffeinate -d`. | Spec §5.1 item 8 owns the rule and plan 4 owns those two fields; this plan fixes only the field on its own page, with `e.g.`. Two plans writing the same rule twice is how the two spellings appear. |
| **§12's "a pairing confirmed at the five-minute boundary can leave the other side failed"** | The QA did not reproduce it (it did not sit out five minutes at the deadline) and neither will this plan: it is a `PairingFlow` expiry race that wants a driven clock in `PairingFlowTests`, not a run. One test, in the round's close. |
| **§12's "the palette's Remote rows are a snapshot of the catalogue as it opened"** | Deliberate, and documented as such in `AppDelegate.remoteChanged`: re-ranking the list under the user's cursor moves the row they are about to press. Left as it is. |
| **An exact resume handshake** — the client telling the host, on `attach`, how much of the stream it actually received, so the host can resume on proof rather than on "no chunk was produced while it was held". | It closes the one residual window `attach` names: a chunk delivered in the tens of milliseconds between the client's socket closing and this host being told is sealed, sent, dropped by the relay, and counted, so the resume believes the mirror is whole. Not here because the client cannot answer the question as the code stands — `E2ESession.lastAcceptedCounter` is private, counts frames rather than chunks, and restarts per attachment — so it means a new wire field in four places plus byte accounting on both sides, reset at `snapshot_end`, in the one place an off-by-one is a hole nobody can see. Worth doing if a hole is ever observed; `heldAtSequence` makes that observable, since a resume now happens only when the host can show that nothing was produced. |
| **A client-side ping** | Not needed and not wanted: the relay pings every 30 s and `URLSessionWebSocketTask` answers those itself, which is exactly what Task 1's liveness check reads. A second ping in the other direction would duplicate the relay's timer and add a second way for a healthy connection to be declared dead — which is what `RelayConnection`'s own comment already says, and it is right about that half. |

---

## Self-review against the spec

**Spec coverage.** §7's four polish items, all confirmed by the QA and all sharpened by it: item 1
the strip's button (Task 7, with `appearance` *and* an `attributedTitle`, the measured range
1.46–2.26 : 1 rather than the spec's 1.73–1.82, the `cmp` byte-identity gate over all eight
button-bearing states, and the 300-pt case no picture had); item 2 leaf-or-container (Task 7); item 3
the host's `.idle`/`.opening` progress (Task 8, plus the wording unification and the 300 ms delay the
QA's sub-400 ms measurement made necessary); item 4 the Remote page's two sentences and
`RelativeAge` (Tasks 5 and 9, plus the four things the picture showed: the status sentence moved
beside its buttons, the Pair caption, the `Device name` placeholder, and what `Snapshot lines`
costs). §7.5 the universal binary is **struck** by the owner and is not in this plan. §7's
**Addendum (2026-09-10)** is what makes B1–B4 and the two pulled-forward Wave-4 items binding, and
it is written into the spec in the same commit as this plan.

Wave 4's items **1** and **3** (§5.1, §5.3) are pulled forward by ruling (3): item 1 whole
(Task 6 — `sendsActionOnEndEditing`, `controlTextDidEndEditing`, the window-close commit — plus item
2's trailing newline, which is the same complaint one step later), and item 3 whole (Task 9 —
`RemotePageStatus`'s four exact sentences, drawn beneath the buttons, with the same sentence as both
buttons' accessibility help, and the buttons kept *disabled* per the spec's ruling rather than
enabled-and-routing).

**One task is not from the spec.** Task 10 — the tab bar's context menu — is an owner ruling of
2026-09-11, recorded in §7.6's addendum. It adds no `TerminalAction` and no wire field: every row it
draws is a route to something that already has a keyboard path (⌘T, `remote_sessions`, ⌘,), which is
why §8.2's rule is satisfied without one. What it does add is a fifth place a remote session is
described, so the wording is Task 5's `RemoteCatalogue.detail` and the dead item's sentence is Task
9's `RemotePageStatus` — the two values this round already made the single answer to those two
questions.

§8's edges: §8.1's announcement sites gain two — the strip's phase and role changes
(`RemoteAnnouncement`, Task 7) and the Remote page's status sentence (Task 9) — with the wording in
Core, as the section requires; §8.4's `hitRowHeight` is what the remote strip's band becomes, and
the rule when it shares the top rows with the pinned band is that **the band yields, by whole rows**
(`decisions.md`, plan-6 must-carry: Task 7 Step 5); §8.5's plan-6 row is the `remote-strip-*` retake
with the eight pairs byte-identical, `pairing-host-{idle,opening}` byte-identical, and
`settings-remote-explained` — which is the two existing `settings-remote-*` pictures once the labels
are in them, retaken rather than renamed.

`docs/superpowers/specs/2026-09-05-remote-sessions-design.md` §12 is deliberately open, and this
plan closes five of its bullets: the snapshot now says whether the host is on the alt screen
(Task 3); the geometry note's threshold is decided at four columns or three rows and has a short
form (Task 7); `.failed` clears the catalogue and refuses an attach (Task 4); disabled palette rows
stop being selectable and the status row acts (Task 5); and `not_paired` drops a host's rows
(Task 4). Two of its bullets are left open on purpose and are in the ledger.

**Deliberately not here.** Scrolling a host grid larger than the pane (§12) — the note says so
instead, which is the round's scope. The `Announce` sites belonging to plans 2, 5a and 5b. §8.3's
pane accessibility role, which is a `[verify]` item needing a VoiceOver pass — and **the VoiceOver
gate is waived** for this round by the owner (2026-09-10), so nothing here waits on one; the a11y
work is specified, implemented and tested in Core regardless, because it is cheap and it is the same
code path the smoke hook reads.

**Where the draft this plan was assembled from had drifted from the code, and what changed.** Six
places, all verified at `main` @ `4950075` and at `~/projects/nyx-server` @ `299769f`:

1. **There is no `resume` field, and none is added.** An earlier draft asserted `attached.resume ==
   true` on a resume. The wire is a contract with a second repository — four places per field — and
   the client does not need it: a resume is `attached` followed immediately by `snapshot_end` with no
   frames, and the client's own parser needs no flag to feed nothing. The test asserts the
   observable facts instead (the role it left with, no frames, one audit line).
2. **`RemotePresence.notPaired` needs a hand-written `init(from:)`.** A property's default value does
   *not* satisfy Swift's synthesized `Decodable` — verified on this toolchain — so
   `var notPaired = false` would have thrown `keyNotFound` on every presence message the deployed
   relay has ever sent. Task 3 Step 3 writes the decoder and Task 3 adds the test for an absent flag.
3. **`ConfigStore`'s file watch cannot answer `.delete`/`.rename` the way the directory watch does.**
   The draft added `fileSource = watch(ConfigStore.path)` and left `handle` as it was — which, on
   every atomic save, would have called `startWatching()` and *cancelled the directory source before
   its own pending event was delivered*, so the one reload that used to happen would have stopped
   happening. `watch` and `handle` take an `isFile` flag: the file watch re-arms itself and falls
   through to the debounce.
4. **D16 cannot be fixed by reordering `removePairing`.** `RemoteHost`'s audit closure hops to the
   main queue on purpose (`RemoteCoordinator.swift:119-124`), so the detach is named after
   `paired` has already lost the entry whatever order the lines are in. The name is kept in
   `namesOfRemovedDevices` and merged into the map `appendAudit` passes to `AuditNames`.
5. **`window.delegate = self` is not safe here.** An `NSWindowController` may already be its own
   window's delegate; the close is observed through `NSWindow.willCloseNotification` scoped to that
   window instead, and only `NSTextFieldDelegate` is added to the class (the fields have no delegate
   today, so nothing is displaced).
6. **Line numbers.** The QA's `AttachState.stripLabelOptions:224` is `:205`;
   `RemoteCoordinator.attach:245` is `:246`; `PairingSheet.update`'s terminal-state branch is
   `:179-187`, not `:167-180`; `AttachStateTests` has **three** tests setting `geometryNote`
   directly (`:281`, `:290`, `:301`), not five, plus two asserting the old one-cell threshold. Every
   other file:line the QA cites is exact at HEAD, including the two the whole plan turns on
   (`server/server.go:327`, `relay/hub.go:161`), and `ConfigGrammar` already has no `scalarKeys` and
   no `key(ofLine:)` — both are created in Task 6.

**Decisions this plan had to make, and why.** (0) **The deploy happens in Task 1**, pre-approved by
the owner, and the client tasks still degrade against an old relay: the two Macs update on their own
schedules, and a client that needs a relay field to work at all breaks on the day the container is
restarted. (1) An attachment held through a socket drop is held for **sixty seconds** — the same
number the client gives itself in `RemoteClient.Attachment.reattachWindow`, because the two are one
race seen from its two ends and a host that gave up first would end a tab that was still asking.
(1a) A resume is gated on **two** facts, not one: the attachment was actually held
(`suspendedAt != nil`), and not one chunk was produced while it was away
(`heldAtSequence == registration.sequence`). `existing != nil` alone would have answered a
duplicated `attach` from a device that never dropped with an empty screen, and a boolean set by
`deliver` would have missed every window in which output reaches nobody *because nothing on this
side is watching* — which is precisely the two windows that exist. `presence(online)` is therefore
not a branch at all: a hold is released by the `attach` that replaces the `Attachment`, and by
nothing else. One residual window survives and is named in the code rather than left for a reader to
assume away; the exact handshake that would close it is in the ledger.
(2) A resume writes **no** audit line, in either direction, because nothing was written when the
socket went: one `attached` per attachment, and the detach at the sweep. (3) The **primary** buffer
is always what a snapshot starts from, even when the host is not on the alt screen, so there is one
code path rather than two; off the alt screen the three buffers agree, which Task 2 asserts. (4) An
impossible size on a `role` is **ignored**, not fatal — unlike the same numbers on an `attached`,
because this message arrives at a tab that is already live and ending it would hand anyone who can
replay a `role` a way to close somebody's session. (5) A `notPaired` device keeps its **name** in the
palette and loses its sessions: the name is how a person knows which Mac to go and re-pair. (6) The
badge is `nil` for `.attaching`/`.snapshot` as well as for the two dead phases, because "observer"
there is the default value showing through rather than an answer, and `.suspended` reads **"offline"**
rather than nothing, which is the useful word for a tab whose host has gone. (7) The relay-status
palette row becomes `.action(.openConfig)` rather than gaining a `PaletteItemKind` of its own: the
row's act is to open the page the missing field is on, and `TabController.run` already performs
actions. (8) `showRemoteSessions` opens the Remote rows **plus** `Pair with Another Device…`, so the
one honest next step is in the list for a Mac with nothing paired yet. (9) The remote strip's covered
row is **blanked**, like the pinned band's: the band is opaque and 16 pt over a 13 pt row, so the
covered row's ascenders and descenders printed above and below it — and since the band is opaque the
row was already unreadable, so blanking costs nothing at any line height.
