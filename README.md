# Nyx

A fast, light, native terminal for macOS. Swift + Metal, no dependencies, no Xcode required.

    make run        # build & launch from SwiftPM
    make test       # unit tests (swift-testing)
    make app        # build/Nyx.app
    make install    # copy to /Applications
    make bench      # parser throughput

Design: `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md`
Working rules and two traps that cost hours: `CLAUDE.md`
Architecture, configuration reference, verification, workflow, status: `docs/`

## What it does

**Panes and tabs.** Splits with draggable dividers (`⌘D`, `⌘⇧D`), focus with `⌘⌥`+arrows, resize
with `⌘⌃`+arrows, zoom a pane to the window with `⌘⇧⏎`. Tabs with groups — a group is a tinted
band around its own tabs with its name as a chip; click the name to collapse it. New panes and tabs
inherit the working directory.

**Shell integration, installed automatically.** Nyx points `ZDOTDIR` at its own startup files,
which source yours and then add `OSC 133` hooks; nothing in your home directory is modified, and
`shell-integration = off` turns it off. Everything below depends on it.

**Because it knows where commands begin and end:**

- A command and its output are a block: a spine beside the rows it owns, and `exit 1 · 8.8s ▾`
  at the end of its command line. Click the chevron to fold the output down to its last three
  lines (⌥-click hides all of it); click the placeholder to bring it back. `⌘⇧↑` folds from the
  keyboard. The status mark in the gutter folds on click too, and is the fallback when a command
  line leaves no room even for the chevron.
- Hover a block and it shows what you can do to it: Copy, and a `⋯` menu with the command, the
  output, both as a Markdown block, the output to a file, run again, edit and run.
- A running command counts up on its own row. "Notify When Done" on it asks for a notification
  whatever it takes, however long or short; otherwise you get one when something took a while
  and you were elsewhere.
- `⌘↑` / `⌘↓` jump between prompts; a gutter marks each command green or red; the command line
  you are reading stays pinned at the top, with its status, while you scroll its output.
- Blocks come back after a relaunch, because the session's scrollback is saved with its marks.

**Editing what you are about to run.** Click anywhere in the command line to put the shell's caret
there. Paste several lines and they open in an editor first — a shell's line editor is a poor place
to change one value in the middle of a long request. `⌘⇧V` opens the editor for any paste.

**Finding things.** `⌘F` searches the buffer, with a toggle that widens it to every pane in every
tab. `⌘⇧P` is a palette over actions, themes, tabs, your own buttons and paired Macs' sessions.
With nothing typed it lists them in menu order rather than shortest-name-first, so the sections
you opened it to see are where you left them; length still breaks ties once you start typing.

**Buttons for what you run constantly.** `quick = Caffeine | toggle | caffeinate -d` puts a button
on the tab bar that starts a background process and stops it when pressed again — no tab spent
babysitting it. `send` types a command into the current pane, `run` opens a tab for it. Add and
edit them from the `+` on the bar; they are written back to the config file as ordinary lines.

**The rest.** Selection that understands paths, URLs and `file:line:column`; clickable links;
mouse reporting for TUIs; true colour, every underline style, ligature-free monospace with proper
font fallback and colour emoji; seven themes with separate light and dark choices; a settings
window that edits the config file rather than shadowing it.

**About the themes.** Every built-in has to clear the same floor: nothing invisible against the
background, no colour indistinguishable from ordinary text, and every bright variant more legible
than its normal — the rules are in `ThemesTests.swift`, and Nyx's own interface colours (search
highlights, selection, the accent) are derived from each theme's sixteen rather than hard-coded,
so `palette = N=#rrggbb` in your config restyles the whole interface and not just the grid. Three
of the ports deviate from upstream where upstream fails that floor, and each says so in
`Themes.swift`. The largest is
**`solarized-dark`**: the canonical xterm mapping fills five of its bright slots with Solarized's
greyscale ramp, which puts a bright black *pixel-identical to the background* (1.00:1, invisible)
and a bright yellow that is a grey. Those five slots are brighter mixes of Solarized's own accent
hues here, the foreground is base1 rather than base0 (5.6:1 rather than 4.8:1), and the selection is
lifted off base03. `catppuccin-mocha` moves bright white to Text (upstream made it dimmer than
white), and `nyx-dark` replaces Tokyo Night's bright row (three duplicates, an orange in the yellow
slot, and a bright cyan darker than cyan). Every one of those changes is named, with its before and
after, in the doc comment on the theme itself.

**Your own themes.** A file in `~/.config/nyx/themes/` is a theme, named after the file (the
extension is ignored), holding the same `palette`, `foreground`, `background`, `cursor`,
`selection` and `selection-foreground` keys the config uses. Name it after a built-in to replace
that one — your `gruvbox-dark` beats ours. The directory is watched, so saving the file recolours
every open window, and the derived interface colours follow whatever sixteen you gave. A file with
no colours in it is reported in the banner rather than becoming a theme that silently keeps every
default. Nyx does not hold your file to the floor above: it is your terminal, and a palette pasted
from a scheme you like should come out as that scheme.

**Sessions.** Quitting remembers every window, tab and split, each pane's working directory and its
scrollback; the next launch puts them back. `restore-session = no` turns it off. A snapshot that
cannot be read — corrupt, or from a newer Nyx — opens one ordinary window rather than nothing.

## Remote sessions

A shell running on one of your Macs, in a tab on another, end-to-end encrypted through a relay that
cannot read a byte of it.

**Setting it up, on both Macs.** `⌘,` → Remote → tick "Enable remote sessions", give this Mac a
name, and paste the relay token. The token is your relay's one shared secret: `deploy.sh` in the
`nyx-server` repository generates it into `token` on first deploy and prints it, and the same
string goes into every device you own. The config file does the same thing — `remote = on`,
`remote-relay-token = …`, and `remote-relay` for the relay's URL (default
`wss://nyx.agentforge.cc/v1/ws`). Nothing is published until both the switch and the token are set;
the page's status line says which is missing.

**Pairing** happens once per pair of Macs. On one: "Pair with another device…", which shows a
six-character code good for five minutes. On the other: "Enter a code…", and type it. Both then
show the same four words. Read them aloud; if they match, press Confirm on each. That comparison is
the whole security of the pairing — the words are derived from both devices' public keys, so a
relay that substituted a key of its own produces two different sets, and it is the person who
refuses, not the software. Paired Macs are listed on the Remote page and can be removed there,
which tears down anything that device still has open.

**Attaching.** `⌘⇧P` has a Remote section (the `remote_sessions` action opens the palette on it)
listing every shell open on every paired Mac: its directory, branch, what is running, what was last
run and how long ago. Choose one and it opens as a tab titled `⟵ machine · title` — the last
`remote-snapshot-lines` lines of that session's scrollback first, then the live stream. Command
blocks, folds, `⌘↑`, the status gutter and the sticky prompt all work in it: the snapshot carries
the host shell's own OSC 133 marks, not flattened text, so a remote tab is a Nyx tab rather than a
picture of one. The grid is the host's — the person sitting in front of it owns that window size —
so a larger window leaves space around it and a smaller one clips the right and the bottom.

**Writer and observer.** The first Mac to attach is the writer and types into the session; every
one after is an observer, with a strip over the top row saying so and a "Take control" button that
swaps the two. An observer's keystrokes reach nothing at all. The host's own user is never blocked
and never asked for permission — their keyboard always works — and closing a remote tab detaches
without touching their session. The host records every event in `~/.config/nyx/remote/audit.log`:
who paired, attached, took control, detached, and when a session ended. The last twenty lines are
on the Remote page.

**What the relay sees:** which of your devices are online, which of them are paired, and the
catalogue rows the palette shows — session titles, directories, branches, the running process and
the last command line. **What it cannot see:** terminal contents, in either direction. Each attach
agrees a fresh X25519 key pair signed by the device's long-lived Ed25519 identity, and the bytes
are ChaCha20-Poly1305 with a per-direction counter, so the relay routes ciphertext it can neither
read nor replay. The identity and the paired list are files under `~/.config/nyx/remote/`; the
identity is `0600` and never leaves the Mac.

## Configuration

`~/.config/nyx/config`, flat `key = value`, watched and reloaded on save. A bad line is reported in
a strip at the top of the window and leaves every other setting in force. `⌘,` opens the settings
window; the Keys page lists every action with its current chord.

## Building

Swift 6.0.3 toolchain, Swift 5 language mode, macOS 14 or later. SwiftPM only — Metal shaders are
compiled at runtime from source, so no Xcode is required. `swift test --no-parallel` (the runner
intermittently hangs when parallel; see `CLAUDE.md`).

## Looking at the interface without a screen

Screen recording is unavailable in the development environment, so the chrome renders offscreen:

    ./scripts/bundle.sh
    NYX_UI_SNAPSHOT=/tmp/shots ./build/Nyx.app/Contents/MacOS/Nyx

writes the tab bar at various tab counts and widths, the search bar, the palette, both sheets, the
settings pages and every theme to PNGs. CI runs the same thing and uploads the result, so a change
to the interface can be reviewed as pictures. The terminal grid itself is covered by the offscreen
Metal renderer in `Tests/NyxRenderTests`.

## Not there yet

Honest list.

**Distribution.** `scripts/bundle.sh` produces an ad-hoc signed app, which runs on the machine that
built it and nowhere else — Gatekeeper refuses an ad-hoc signature everywhere. `scripts/release.sh`
signs, notarises and staples properly, and is ready to run, but it needs an Apple Developer account:
a Developer ID certificate and a notarytool keychain profile. Neither can be faked, so the script
checks for them and says what is missing rather than producing something that looks shippable.

**No automatic update.** Nothing tells you a new version exists.

**Throughput** is 190 MB/s against a design target of 300. The remaining work is known — a
table-driven parser and a flat cell grid — and is not started.

## Snapshot test

`Tests/NyxRenderTests/SnapshotTests.swift` is an opt-in end-to-end regression test: it drives a
real `zsh` through `TerminalSession` into the `Renderer` and reads pixels back from the rendered
Metal texture. It exercises the full pipeline (PTY → parser → `Terminal` → `Renderer` → texture)
with real programs — a shell prompt with SGR attributes, Cyrillic/CJK/emoji, an alt-screen editor
session (`vim`), a resize, and a scrollback scroll — which is what caught a glyph-orientation bug
that every unit test missed. It asserts, from the rendered pixels, that the frame isn't blank and
that a capital "L" has more ink in its lower half than its upper half (the orientation check unit
tests missed), then writes PNGs to `build/snapshots/` for human inspection.

It's skipped by default so `make test` stays fast and deterministic. Run it with:

    NYX_SNAPSHOT=1 swift test --filter Snapshot
