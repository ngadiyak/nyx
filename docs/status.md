# Where Nyx stands

An honest inventory as of 2026-09-06, against the spec and against the terminals Nyx has to beat.
Update this when a row changes; the README's "Not there yet" is the user-facing summary of the
same facts.

## Done and verified

| Area | State |
|---|---|
| VT core | Full §4.4 set: C0, ESC, CSI incl. DECSTBM/DECOM/IRM/LNM, SGR complete with `:` subparams, 256/true colour, SGR 58 underline colour, all underline styles, DECSET 1/6/7/12/25/1000–1006/1004/1047–1049/2004/2026, DA1–3, DSR, DECSCUSR, XTWINOPS, DECRQM, DECRQSS, OSC 0/1/2/4/7/8/9/777/10–12/52/104/110–112/133 |
| Unicode | Width table (Unicode 16), combining, VS16, ZWJ clusters, wide/spacer cells, U+FFFD on bad UTF-8 |
| Resize | Primary screen reflows on soft-wrap flags; alt screen truncates; marks survive reflow |
| Keys | xterm encodings, DECCKM, application keypad (by key code), `modifyOtherKeys` levels 1–2 (level 1 is Nyx's own rule; see `KeyEncoder`), ⌥-as-meta, IME and dead keys |
| Mouse | Modes 9/1000/1002/1003, SGR and UTF-8 encodings, ⌥ overrides for selection, wheel → arrows on alt screen |
| Render | Metal, 3 instanced draw calls, glyph atlas with Core Text fallback and colour emoji, per-row redraw cache with measured 2 % rebuild on a spinner, synchronised output with 150 ms expiry, dirty flags cleared only after a presented frame |
| Panes and tabs | Split tree with draggable dividers, focus/resize/zoom chords, tabs with groups (band + name chip, collapsible), inherited cwd, close confirmation, rename, duplicate |
| Shell integration | zsh via a `ZDOTDIR` shim (nothing in `$HOME` modified); OSC 7 + 133 with exit status; bash/fish by a `source` line shown in settings |
| On prompt marks | ⌘↑/⌘↓, status gutter, blocks with a chevron and a hover header (Copy, ⋯ menu), tail folds keyed by command id, live timer, armed notifications, Markdown export, sticky command line with status, blocks restored with the session |
| Editing | Click-to-position the shell caret on one line; multi-line paste opens the editor (`multiline-paste`); ⌘⇧V always does |
| Search | Incremental, per-pane, with an all-tabs scope; visible highlights; current match distinct |
| Palette | ⌘⇧P over actions, themes, tabs, quick actions; fuzzy ranked |
| Links | OSC 8, URLs, paths, `file:line:col`; ⌘-click opens; `open-file-command` |
| Config | Flat file, watched, line-numbered diagnostics, previous config kept on error, settings window that edits the file, deferred settings named in the banner |
| Themes | Seven built-ins held to a contrast floor; user theme files, watched, symlinks followed, name collisions and empty files reported; interface colours derived from the palette |
| Quick actions | `send` / `run` / `toggle` buttons on the bar, editable from the UI, written back to the file; per-project `.nyx` behind a digest-bound approval |
| Sessions | Windows, tabs, splits, cwd and scrollback restored; corrupt or newer snapshot → one window |
| Remote sessions | A paired Mac's shell as a tab: relay-based, end-to-end encrypted (X25519 per attach, signed by an Ed25519 device identity, ChaCha20-Poly1305 with a per-direction counter), six-character pairing code with a four-word fingerprint both people compare, palette Remote section, snapshot-then-live with the host's OSC 133 marks intact, one writer with take-control, an audit log on the host. Verified with two instances against the deployed relay |
| Requests (workbench, request side) | A pasted `curl` offers `⌘E Workbench`; ⌘E, ⌘⇧V, New Request, a block's ⋯ menu and the palette's Requests section all open one command as a form -- method, parameters, headers, body, auth, options -- with secrets masked until revealed, a live preview of exactly what will run, Copy and four exports (HTTPie, fetch, Python requests, Go), Save as Button / Save to Project, and a run whose status, latency, size and body kind land on the block header. The last fifty requests are remembered beside the config file |
| Requests (lenses and the watch, response side) | A finished `curl` opens in `http-lens`; `⌘⇧J` flips it; the ⋯ menu's Lens group has Raw, Pretty JSON, Headers, Body, Filter, Find in Body and Diff with Previous Run, with the filter and the find typed into a field over the block. `Run Every 5 s` / `Watch…` / the workbench's `Repeat` menu put the same request on a schedule: each run is an ordinary block, sent only at a prompt and never while the last one is still going, older runs folded except where the status class changed, the newest opened on the diff, and a header with a thirty-run timeline, `watch every 5 s · run 12 · 200 · 142 ms` and a Stop button. It stops on its plan, on ⌘., on the Stop button, when the pane closes and when you type, and it keeps running -- on the interval, to the count -- while its tab is in the background or its window is minimised. A pane whose shell emits no prompt marks is told why a watch cannot start there rather than being given one that never sends |
| Accessibility | Every drawn control is an accessibility element with role and state |
| Verification | 1952 swift-testing tests, offscreen Metal pixel tests, UI snapshot renderer, an opt-in run against a real relay binary (`NYX_RELAY_BIN`), CI with warning gate, bench floor, launch check and snapshot artifact |

## Not there yet

| Gap | Why it matters | Notes |
|---|---|---|
| Distribution | Nobody else can run it | `scripts/release.sh` is ready; needs a Developer ID certificate and a notarytool profile |
| Automatic update | Nobody finds out about a new version | Sparkle or a hand-rolled appcast; after distribution |
| Throughput 190 vs 300 MB/s | Already beats iTerm2 by an order of magnitude; the target was set to beat Ghostty/Alacritty on the same stream | Table-driven parser, actual-row-width tracking, flat cell storage; each rewrites tested code |
| Kitty keyboard protocol | Neovim, Helix, fish and Claude Code disambiguate keys with it; xterm `modifyOtherKeys` covers most cases today | Phase 3. Five flags with push/pop; cannot be half-honest |
| Ligatures and shaping | Fira Code / JetBrains Mono users expect them; Ghostty and iTerm2 have them | Phase 3. Run-based Core Text shaping changes the atlas key and the row cache |
| Kitty graphics / Sixel | Image previews in `yazi`, `timg`, notebooks | Phase 3 |
| Quick terminal (hotkey window) | iTerm2's most-loved feature | Phase 3 |
| Fast tab/pane switcher by name | Palette lists tabs; a dedicated switcher with fuzzy over titles and cwd is not there | Phase 3 |
| bash / fish shell integration injected automatically | Only zsh gets marks without the user editing an rc file | bash's startup rules differ by login/interactive; fish has no `ZDOTDIR` analogue |
| `vttest` sign-off | Screens 1 and 2 on the checklist have not been run on a screen since phase 1 | Needs a human |
| Latency measurement | "≤ 1 frame" is the target; nothing measures it | A typometer-style probe through the snapshot test would make it a number |
| `Tests/NyxAppTests` | There is no App test target; the answer so far has been to move decisions to Core, which has worked | Keep doing that rather than build an AppKit harness |

## Against the competition

Where Nyx is measurably ahead, and where it is behind, as of today. The product manager compares
by name; so should every feature brief.

| | Nyx | Ghostty | iTerm2 | WezTerm | Warp |
|---|---|---|---|---|---|
| Parser throughput on escape-heavy streams | ~190 MB/s | comparable class | tens of MB/s | comparable class | n/a |
| Idle CPU | 0 % | 0 % | > 0 with some settings | 0 % | > 0 |
| Command blocks: hover header, tail fold, live timer, Markdown export | yes, from OSC 133, no account | marks only | marks + some | marks only | yes, proprietary, breaks in tmux |
| Multi-line paste goes to an editor first | yes | no | no | no | yes |
| Tab groups | yes | no | no | no | no |
| User buttons / project buttons with approval | yes | no | profiles/triggers | Lua | workflows |
| Search across all tabs | yes | no | no | no | no |
| Attach to another Mac's shell over a relay, end-to-end encrypted | yes | no | no | no | cloud sessions, but not this shape: Warp's are its own hosted blocks, not an attach to a shell already running on your other Mac |
| Theme from a file, hot-reloaded, derived interface colours | yes | yes (many built-in) | yes | yes | limited |
| Ligatures | no | yes | yes | yes | yes |
| Kitty keyboard protocol | no | yes | partial | yes | no |
| Images (Kitty/Sixel) | no | yes | yes | yes | no |
| Signed, notarised download | no | yes | yes | yes | yes |
| Native macOS (no Electron, no web view) | yes | yes | yes | no (Rust/wgpu) | no |

Sources for the competitors' rows are their documentation as of the knowledge cutoff; re-check
before quoting them outside this repository.
