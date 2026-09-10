# Configuration reference

The file is `~/.config/nyx/config` (override with `NYX_CONFIG=/path/to/config`). Flat
`key = value`, one per line, `#` comments (a `#` starts a comment only after whitespace, so
`palette = 1=#ff0000` is a colour, not a comment). The file is watched and reloaded on save. A bad
line is reported in the banner at the top of the window with its line number, and every other
setting stays in force. `⌘,` opens the settings window, which edits this file in place;
`⌘⇧,` reloads it by hand.

`Config.defaultFileText` in `Sources/NyxCore/Config/Config.swift` is the commented template Nyx
writes when the file is missing. `ConfigTests` checks that parsing it yields exactly the defaults,
so that template and this page are the two places a new key must be added.

## Keys

| Key | Default | Values / meaning |
|---|---|---|
| `font-family` | `system` | A family name, or `system` for SF Mono (Apple exposes it only through `NSFont.monospacedSystemFont`, so it cannot be named). Glyphs missing from the family come from Core Text fallback |
| `font-size` | `13` | Points |
| `line-height` | `1.0` | Multiplier over the font's natural line height |
| `font-thicken` | `false` | Heavier rasterisation, the "font smoothing" effect |
| `theme` | `nyx-dark` | A theme name, or `dark:<name>,light:<name>` to follow the system appearance |
| `palette` | — | `<0-255>=<#rrggbb>`, one per line, additive. Overrides slots of the active theme. Slots 0–15 also drive Nyx's own interface colours |
| `cursor-style` | `block` | `block`, `underline`, `bar`. A program's DECSCUSR wins while it runs |
| `cursor-blink` | `true` | |
| `scrollback-lines` | `10000` | Per pane. Takes effect for new sessions; the banner says so |
| `padding` | `8` | Points between the window edge and the grid. **At `0` the block spine is drawn in the first text column's leading 3 pt, so the first glyph of every command and output row of a block is clipped** — the mark moves inward as the padding grows and is clear of the text from 3 pt up |
| `background-opacity` | `1.0` | 0–1 |
| `background-blur` | `0` | Blur radius behind a translucent window. A value above 0 implies opacity 0.9 unless `background-opacity` says otherwise |
| `window-decorations` | `true` | |
| `tab-bar` | `always` | `always`, `auto` (hidden with one tab and no buttons), `never` |
| `shell` | `$SHELL`, else `/bin/zsh` | Path to the shell, launched as a login shell |
| `working-directory` | `inherit` | `inherit` (from the current pane, via OSC 7), `home`, or an absolute path |
| `copy-on-select` | `false` | |
| `middle-click-paste` | `true` | |
| `option-as-meta` | `none` | `none`, `left`, `right`, `both`: which ⌥ sends ESC-prefixed bytes instead of composing characters |
| `mouse-scroll-alt-screen` | `true` | On the alternate screen, the wheel sends arrow keys |
| `bell` | `visual` | `visual`, `sound`, `none` |
| `confirm-close-process` | `true` | Ask before closing a pane whose shell has a running child |
| `restore-session` | `true` | Bring back windows, tabs, splits, cwd and scrollback at launch. `no` also deletes the saved session |
| `clipboard-read` | `false` | Allow OSC 52 to *read* the clipboard. Writing is always allowed |
| `word-separators` | `` ()[]{}'"`,;:|<> `` plus space | Characters that end a double-click word |
| `open-file-command` | — | Template run for a clicked path, with `{file}` and `{line}` placeholders. Empty means `NSWorkspace.open`. Not comment-stripped, so `#` is allowed |
| `shell-integration` | `auto` | `auto` injects the OSC 133 hooks for zsh; `off` never touches the shell |
| `multiline-paste` | `edit` | What a paste with newlines does: `edit` opens the editor, `confirm` shows a preview with an Edit button, `direct` sends it straight through |
| `fold-keep-lines` | `3` | Rows of output a folded command keeps visible at its end. `0` hides all of it |
| `fold-long-output` | `0` | Fold a command's output automatically once the next command starts, when it is longer than this many rows. `0` turns it off. A block you unfolded by hand is never re-folded |
| `quick` | — | A button on the tab bar; see below. Additive |
| `keybind` | — | A binding; see below. Additive |
| `remote` | `off` | `off`, `on`. Publishes this Mac's sessions to the relay and accepts attaches from paired devices |
| `remote-device-name` | — | Shown to a paired Mac in place of a name. Empty resolves to the Mac's own name (System Settings → Sharing) at the point of use |
| `remote-relay` | `wss://nyx.agentforge.cc/v1/ws` | The relay's WebSocket URL |
| `remote-relay-token` | — | The relay's shared secret, checked before pairing is even possible. Not comment-stripped, so `#` is allowed |
| `remote-snapshot-lines` | `2000` | Lines of scrollback a host sends a client as the initial snapshot before switching to the live stream. Clamped to 100–20000 |
| `http-lens` | `pretty` | Which lens a finished `curl`'s response opens in: `pretty` (the JSON body reformatted, foldable, with the headers on one line and the phase latencies underneath) or `raw` (the rows exactly as they arrived). Only applies to a JSON body up to 20,000 lines or 2 MB, whichever comes first, and never more than `scrollback-lines` keeps -- a lens is built from the rows the pane still has. Everything else stays raw, and the block's ⋯ menu says so. `⌘⇧J` flips one response between the two without touching this |
| `http-hint` | `true` | Show the `⌘E Workbench` pill at the end of a `curl` that has just been **pasted**, for eight seconds or until the next key press. Typing one by hand does not raise it |
| `http-watch-interval` | `5` | Seconds between the *end* of one watched run and the start of the next -- what the block menu's `Run Every 5 s` row, the workbench's `Repeat ▸ Run 10 times` and the `Watch…` popover all open on. Clamped to 1–3600; the popover accepts 0.5–3600 for one series without changing the setting. A watch needs `shell-integration`: it only ever types at a prompt, so a pane whose shell marks none refuses to start one and says so |
| `http-history` | `50` | How many requests the palette's Requests section remembers. `0` turns the feature off. Clamped to 0–500 |

Booleans accept `true`/`false`, `yes`/`no`, `1`/`0`, `on`/`off`.

**Links open on ⌘-click** — the convention iTerm2 and Ghostty both use. A plain click still means
selection, hovering underlines what would open and turns the pointer into a hand, and the tooltip
there says `⌘-click to open`; right-clicking a link offers **Open Link** and **Copy Link**. What
counts as a link: an `http`/`https`/`mailto`/`ssh`/`sftp`/`ftp`/`irc` URL, an OSC 8 hyperlink (the
URI the program named, not the label it shows), an e-mail address, and a path that *exists* on disk
— with the `:line:column` a compiler printed after it, handed to `open-file-command`. A URL that
wrapped at the right margin opens as one URL, and a URL inside a lens row is clickable like any
other.

Remote sessions need both `remote = on` and a non-empty `remote-relay-token`: without the token the
relay closes the socket before the handshake, so connecting would be a guaranteed failure reported
as an outage. Changing any of the five keys rebuilds the connection and ends every open remote tab
with a reason. The device identity, the paired list and the audit log live in `remote/` beside the
config file; see the README's "Remote sessions".

## Themes

Built in: `nyx-dark` (default), `nyx-light`, `solarized-dark`, `gruvbox-dark`, `dracula`,
`catppuccin-mocha`, `one-dark`. Every built-in passes the floor in `ThemesTests`: nothing invisible
against the background, no colour indistinguishable from the foreground, every bright variant more
legible than its normal. Three ports deviate from upstream to clear that floor; each deviation is
documented on the palette in `Themes.swift`.

**Your own theme** is a file in `~/.config/nyx/themes/` (beside the config, so it moves with
`NYX_CONFIG`). The theme's name is the filename without its extension; a name matching a built-in
replaces it. Keys:

```
foreground           = #c0caf5
background           = #1a1b26
cursor               = #c0caf5
selection            = #33467c
selection-foreground = #c0caf5
palette              = 0=#15161e
palette              = 1=#f7768e
...
```

Rules that follow from the code:

- The directory is watched. Saving a file recolours the grid and the chrome of every window.
- Symlinks are followed. Hidden files are skipped.
- A file with no colours in it is reported in the banner rather than becoming a theme.
- A theme name the config asks for that no file or built-in provides is reported as
  `no theme named "…"` and `nyx-dark` is used.
- Colours you leave out come from `nyx-dark`, not from the built-in you are replacing. Nyx does not
  hold your file to the contrast floor.
- Interface colours (selection, search highlight, accent, tab tints) are derived from the sixteen
  ANSI slots, so a palette restyles the whole window.

## Key bindings

```
keybind = <modifier>+<modifier>+<key>=<action>
```

Modifiers: `cmd`, `ctrl` (or `control`), `alt` (or `opt`, `option`), `shift`. Keys: a single
character (lowercase; add `shift` explicitly), or one of `enter`/`return`, `tab`, `escape`/`esc`,
`space`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, `up`, `down`,
`left`, `right`, `f1`…`f12`. The chord is split at the *last* `=`, so `cmd+,=open_config` works.
A user binding beats a default for the same chord; the last line in the file wins.

A chord names a **physical key, not a character**. Once ⌘ is held, the key is read from its
position on the keyboard — the letter on the keycap — so `cmd+c` is the C key on a Russian,
Greek or Hebrew layout as much as on a US one, and `cmd+shift+d` matches whatever glyph shift
produces there. Write the key as the unshifted ASCII character it carries (`cmd+shift+=`, not
`cmd++`) and put `shift` in the modifiers. Without ⌘, a key press is text: it reaches the shell
as the character the layout makes, so typing Cyrillic sends Cyrillic.

**Control chords are physical too.** ⌃C sends 0x03 — and interrupts — on a Russian, Greek or
Hebrew layout, where the C key types `с`, `ψ` or `ב`. The rule, in order: **the control byte the
layout's own character names, and only when it names none, the byte the same physical key gives on
a US keyboard.** So ⌃Z is 0x1A, ⌃D is 0x04 and ⌃[ is Escape wherever those keycaps are, and ⌃ü on
a German layout is Escape because `ü` sits on the `[` key.

Which of the two answers a chord gets is worth being concrete about, because both happen on Latin
layouts:

- German ⌃⇧- is **DEL**, because ⇧- types `?` there and `?` names DEL. The character wins; the
  keycap's `_` (0x1F) is not consulted.
- German ⌃⇧6 is **RS** (0x1E), because ⇧6 types `&`, which names nothing, so the `^` on the US
  keycap answers. This changed: it used to send `&`. The same rule reaches ⌃@ and ⌃? on layouts
  that put something else on ⇧2 and ⇧/ — RussianWin types `"` and `,` there.
- With ctrl alone a plain ASCII character is never re-read: on RussianWin the `/` keycap types `.`,
  and ⌃. is `.`, not 0x1F.

The digit row carries xterm's aliases on every layout: ⌃2 is NUL, ⌃3 to ⌃7 are Escape, FS, GS, RS
and US, and ⌃8 is DEL, while ⌃1, ⌃9 and ⌃0 send their digit. The numeric keypad is left out of all
of this — ⌃keypad-2 is `2` — because keypad keys carry no second legend and xterm does not modify
them either.

Typing and ⌥ chords are untouched: ⌥`с` with `option-as-meta` set sends ESC and the two UTF-8 bytes
of `с`, not ESC `c`. An application that turns on xterm's `modifyOtherKeys` gets the layout's own
code point in the report (⌃C on a Cyrillic layout is `CSI 27;5;1089~`, U+0441), which is what
xterm, Ghostty and iTerm2 all report there.

| Action | Default | What it does |
|---|---|---|
| `new_window` | ⌘N | |
| `new_tab` | ⌘T | Inherits the working directory |
| `close_pane` | ⌘W | Closes the pane; the last pane closes the tab; the last tab closes the window |
| `next_tab` / `previous_tab` | ⌘⇧] / ⌘⇧[ | |
| `tab_1` … `tab_9` | ⌘1 … ⌘9 | |
| `split_right` / `split_down` | ⌘D / ⌘⇧D | |
| `focus_left` / `focus_right` / `focus_up` / `focus_down` | ⌘⌥ arrows | |
| `grow_left` / `grow_right` / `grow_up` / `grow_down` | ⌘⌃ arrows | Resize the focused pane |
| `toggle_zoom` | ⌘⇧⏎ | Focused pane fills the tab, and back |
| `copy` / `paste` | ⌘C / ⌘V | Paste is bracketed when the program asked for it |
| `paste_with_editor` | ⌘⇧V | Open the clipboard in the editor first |
| `clear_screen` | ⌘K | Clears screen and scrollback (`ED 3`) |
| `font_bigger` / `font_smaller` / `font_reset` | ⌘+ / ⌘- / ⌘0 | Zoom in also answers to ⌘= — the same key without shift — and to the keypad's `+` |
| `open_config` / `reload_config` | ⌘, / ⌘⇧, | ⌘, opens the settings window |
| `previous_prompt` / `next_prompt` | ⌘↑ / ⌘↓ | Moves the block cursor one command back or forward and brings the viewport to it; the block it lands on is lit exactly as a hovered one. Scrolled back, ⌘↑ goes to the command filling the screen and ⌘↓ to the one after it. ⌘↓ past the newest command goes to the prompt you are typing at, with no block lit; a second ⌘↓ there beeps, as does ⌘↑ at the oldest command. Needs shell integration |
| `select_command_output` / `copy_command_output` | — | The output of the block the keyboard is on — moved by ⌘↑/⌘↓, and the last command when nothing has moved it |
| `find` / `find_next` / `find_previous` | ⌘F / ⌘G / ⌘⇧G | The bar has an "All tabs" scope toggle |
| `command_palette` | ⌘⇧P | Actions, themes, tabs, quick actions |
| `edit_and_run_command` | ⌘E | Opens the line being typed — or, at an empty prompt, the command of the block the keyboard is on — in the editor |
| `rename_tab` | ⌘⇧R | |
| `group_tab` / `ungroup_tab` / `toggle_tab_group` | ⌘⌃G / — / — | |
| `fold_command` / `fold_all_long_output` | ⌘⇧↑ / — | Folds the block the keyboard is on, keeping its last lines / folds every long one |
| `copy_block_markdown` | — | That block and its output as a fenced Markdown block |
| `save_command_output` | — | Writes that block's output to a file the user chooses |
| `notify_when_done` | — | Arm a notification for the command running now, however short it turns out |
| `save_scrollback` | — | Writes the transcript to a file the user chooses |
| `new_request` | — | Opens the request workbench on a blank request: method, URL, parameters, headers, body, auth and options as a form |
| `remote_sessions` | — | Opens the command palette's Remote section. Settings → Remote also gets you there |
| `remote_pair` | — | Opens the pairing sheet, either side |
| `remote_take_control` | — | On an observed remote tab, takes over as writer |
| `toggle_http_lens` | ⌘⇧J | Flips the block the keyboard is on — or the last response in the pane — between `pretty` and `raw`. Greyed when the pane has no request to show |
| `stop_watch` | ⌘. | Stops the watch running in this pane, while the block the keyboard is on is the series' newest run. Greyed in the menu and absent from the palette when there is no such series; the strip's **Stop** button has no such rule and always stops the series it belongs to, so the two agree whenever the cursor is on that run. `⌘K` (clear the pane) also stops a running series and *forgets* it — every run's block id names rows that are gone, so a kept header would sit on a stranger's command |

⌘↑ / ⌘↓ move the block cursor — the block Nyx draws as hovered and every block action acts on;
it clears with ⌘K and follows the screen when you scroll.

The menu is generated from `ActionCatalog.sections`, so every action is discoverable there with
its current chord, and the settings window's Keys page lists them all.

The Edit menu also carries AppKit's own **Undo ⌘Z**, **Redo ⌘⇧Z**, **Cut ⌘X** and
**Select All ⌘A**. Those four are not actions and cannot be rebound: they go to whatever has the
keyboard. In a text field — the search bar, the Rename Tab sheet, the request editor — they edit
that field; over the terminal grid, Select All selects the whole scrollback and the rest are greyed
out. `copy` and `paste` travel the same route, which is why ⌘C and ⌘V work inside Nyx's own fields
instead of reaching the shell behind them.

## Quick actions

```
quick = <name> | <kind> | <command>
quick = <name> | <command>              # kind defaults to send
```

| Kind | Behaviour |
|---|---|
| `send` | Types the command into the focused pane and runs it, as if you typed it (it lands in history) |
| `run` | Opens a new tab and runs it there |
| `toggle` | Starts it in the background; pressing again stops it. Made for `caffeinate -d` |

Buttons appear on the tab bar in file order, and in the command palette. The `+` on the bar and
the button's context menu add, edit, duplicate, reorder and remove them; those edits are written
back to the config file as ordinary `quick =` lines.

**Project actions.** A file named `.nyx` at a directory's root may contain `quick =` lines and
nothing else (other keys are ignored). When a pane's working directory enters that project, Nyx
shows a bar offering to review the file; approval is recorded against the file's digest, so an
edit, or a `git pull` that brings one in, revokes it until you look again. A cloned repository can
never put a command behind a button on its own.

## The request history

Every curl that finishes in a pane is remembered in `~/.config/nyx/requests` (beside the config;
`NYX_REQUEST_HISTORY` moves it), and the command palette lists them under the Requests section --
`GET api.example.com/users`, with `Request · 2 min ago` beside it. Choosing one opens it in the
request workbench, ready to change something and run again. What is stored is the request as it was
written: Nyx's own `-sSi -w …` measurement flags are taken off before a line is remembered.

One request per line, newest first, as `<unix seconds><tab><the command line>`. Re-running a request
moves its line to the top rather than adding a second one; sameness is what the command *is*, so
`--silent` and `-s` are one entry. A line that is not a curl with a URL is not kept.

The file is written at mode `0600` and holds the command lines exactly as they ran, credentials
included -- the same words as your shell history, and for the same reason: what comes back out of
the palette has to be the request that worked. What the palette *shows* is masked. `http-history`
(default `50`) says how many are kept; turning it down forgets the extra requests immediately.

## Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `NYX_CONFIG` | app, tests | Path of the config file; the themes directory, `session.json`, `requests` and `remote/` sit beside it. Two config directories is how two Nyx instances on one Mac get two identities |
| `NYX_RELAY_BIN` | tests | Path of the `nyx-relay` binary; the relay integration tests launch it locally and skip without it |
| `NYX_SESSION` | app | Path of the session file, overriding the one beside the config |
| `NYX_REQUEST_HISTORY` | app | Path of the request history file, overriding the one beside the config |
| `NYX_UI_SNAPSHOT=<dir>` | app | Render every piece of chrome to PNGs in `<dir>` and exit. See `docs/testing.md` |
| `NYX_RENDER_STATS=1` | app | Print row-cache statistics per pane |
| `NYX_SNAPSHOT=1` | tests | Enable the end-to-end pixel snapshot test |
| `NYX_SIGN_IDENTITY`, `NYX_NOTARY_PROFILE` | `scripts/release.sh` | Developer ID identity and notarytool keychain profile |
| `NYX_SHELL_INTEGRATION_DIR`, `NYX_ZDOTDIR` | the shell shim | Set by Nyx for the zsh shim; tell an rc file that it is running inside Nyx and where the user's own `ZDOTDIR` was |

Nyx also sets `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Nyx` and
`TERM_PROGRAM_VERSION` in every session.
