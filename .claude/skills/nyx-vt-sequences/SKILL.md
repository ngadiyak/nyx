---
name: nyx-vt-sequences
description: Use when adding or changing an escape sequence, a DECSET/DECRST mode, a terminal reply (DA, DSR, DECRQM, OSC query), a key or mouse encoding, or when a TUI program (vim, htop, fzf, tmux, Claude Code) misbehaves in Nyx.
---

# Escape sequences, modes and replies

The parser (`VTParserOf`) is a DEC state machine that knows nothing about screens; it calls
`TerminalActions` on `Terminal`. Everything a sequence *does* is in `Terminal.swift`
(`execute`, `csi`, `esc`, `osc`, `setMode`, `dcs*`). Replies go into `terminal.responses`; things
the app must act on go into `terminal.events`.

## Steps

1. **Quote the source.** `ctlseqs` for xterm, the VT510 manual for DEC, the kitty/Sixel specs for
   extensions. Write the exact bytes in and the expected screen, reply or mode out. The
   `vt-conformance` agent does this for you when the answer is not obvious.
2. **Test first**, in the matching `Tests/NyxCoreTests/Terminal*Tests.swift` or `KeyEncoderTests`:
   ```swift
   @Test func repRepeatsTheLastGraphic() {
       let t = makeTerminal(cols: 10, rows: 1).run("a\u{1B}[3b")
       #expect(t.line(0) == "aaaa")
       #expect(t.cur == (4, 0))
   }
   ```
   Assert what the user sees (`line`, `cell(x,y).attrs`, `responseText`, `events`), not only
   internal state. Add a case where the sequence is split across two `feed` calls if it has
   parameters.
3. **Implement** in `Terminal`: the `case` in `csi`/`esc`/`osc`, or the mode in `setMode` *and*
   its `DECRQM` reply *and* its reset in RIS/`DECSTR` if it has one. New parameters use
   `CSIParams` (`:` subparameters supported; missing parameter defaults are the caller's job).
4. **Mark dirty.** Any cell you touch must set `row.dirty`; a scroll or region move marks the whole
   region (`scrollUp`/`scrollDown` already do). If absolute row indices change meaning
   (`ED 3`, RIS, alt-screen), bump `scrollbackGeneration`; on resize, deliberately do not.
5. **New per-row state** (`Row` fields) must be carried through reflow in `Terminal+Resize.swift`
   (`Line(cells:mark:exitStatus:commandStatus:commandDuration:)`) and considered in the session
   transcript (`Transcript`, `SessionSnapshot`) or it silently vanishes on resize or relaunch.
6. **Bench.** `make bench` three times; the parser and `feed` are the hot path. A new `switch`
   case in `print` or in the ground state is measurable.
7. **Record it**: `docs/status.md`'s VT row, and the spec's §4.4 if it was promised there.

## Modes: the whole checklist

`TerminalModes` field → `setMode` on/off → `DECRQM` reply value → reset in RIS → `XTSAVE`/
`XTRESTORE` if it is a DECSET → read by whoever acts on it (`KeyEncoder`, `MouseEncoder`, `Pane`,
`Renderer`). A mode that is set and read by nobody is the §11 keypad defect again.

## Keys and mouse: the encoder test is half the evidence

`KeyEncoder.encode` and `MouseEncoder.encode` are pure and tested. The built app reaches them
from `Pane.keyDown` **and** from `insertText` after the input context handles the event, and from
`mouseDown`/`mouseDragged`/`scrollWheel` via `report(_:_:_:)`; a terminal-mode question
(application keypad, cursor keys, `modifyOtherKeys`, pixel mouse) must be decided before the
input context sees the event. Evidence for a key or mouse change is a temporary hook that posts an
`NSEvent` through the real handler and prints what reached the PTY (`docs/testing.md`, rung 6),
not an encoder test alone. Say in the report which path the evidence covers.

## Common mistakes

- A reply written to `events` instead of `responses` (nothing writes it to the PTY).
- Forgetting `DECAWM`/pending-wrap interaction when printing at the last column.
- Wide characters: a 2-column glyph is `.wide` + `.wideSpacer`; overwriting either half must clear
  the other.
- Handling a private-marker CSI (`?`) in the same `case` as the public one. Check
  `intermediates`.
- Capping: OSC over 64 KB is dropped whole; do not buffer more.
- 8-bit C1 is not recognised by design; bytes ≥ 0x80 are UTF-8. Do not add it.
