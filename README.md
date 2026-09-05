# Nyx

A fast, light, native terminal for macOS. Swift + Metal, no dependencies, no Xcode required.

    make run        # build & launch from SwiftPM
    make test       # unit tests (swift-testing)
    make app        # build/Nyx.app
    make install    # copy to /Applications
    make bench      # parser throughput

Design: `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md`
Working rules and two traps that cost hours: `CLAUDE.md`

## What it does

**Panes and tabs.** Splits with draggable dividers (`⌘D`, `⌘⇧D`), focus with `⌘⌥`+arrows, resize
with `⌘⌃`+arrows, zoom a pane to the window with `⌘⇧⏎`. Tabs with groups — a group is a tinted
band around its own tabs with its name as a chip; click the name to collapse it. New panes and tabs
inherit the working directory.

**Shell integration, installed automatically.** Nyx points `ZDOTDIR` at its own startup files,
which source yours and then add `OSC 133` hooks; nothing in your home directory is modified, and
`shell-integration = off` turns it off. Everything below depends on it.

**Because it knows where commands begin and end:**

- `⌘↑` / `⌘↓` jump between prompts.
- A gutter marks each command green or red by its exit status.
- How long each command took is written dim at the end of its own line — no hovering, no folding.
- A command's output folds to one line and unfolds again.
- The command line you are reading stays pinned at the top while you scroll its output.
- Right-click a command to run it again, or to edit it first.
- A notification when a long command finishes while you are looking elsewhere.

**Editing what you are about to run.** Click anywhere in the command line to put the shell's caret
there. Paste several lines and they open in an editor first — a shell's line editor is a poor place
to change one value in the middle of a long request. `⌘⇧V` opens the editor for any paste.

**Finding things.** `⌘F` searches the buffer, with a toggle that widens it to every pane in every
tab. `⌘⇧P` is a palette over actions, themes, tabs and your own buttons.

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
