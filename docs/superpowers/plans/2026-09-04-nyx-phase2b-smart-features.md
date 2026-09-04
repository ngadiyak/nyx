# Nyx phase 2B — smart features

**Goal:** cash in what the VT core already parses but nothing uses, and add the four features a
terminal is judged on next to that. Five items, requested together.

**Spec:** `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md` §6.3 (search), §6.4 (links and
paths), §6.6 (shell integration). Items 4 and 5 are new and specified here.

**Global constraints:** `NyxCore` imports no AppKit/Metal/CoreText/QuartzCore. swift-testing only
(no XCTest). Warning-free build. Swift 6.0.3 in Swift 5 language mode, macOS 14. Bench must stay
at or above 180 MB/s. Every feature's decision logic goes in `NyxCore` behind a pure interface and
is unit-tested; the AppKit layer converts events and draws — the environment denies Accessibility,
so anything left in a view handler is unverifiable here.

## State before this phase

Verified present and working: bracketed paste, synchronized output (2026), focus reporting (1004),
every underline style including SGR 58 coloured underlines, font fallback via
`CTFontCreateForString`, colour emoji through a separate shader path, `COLORTERM=truecolor`.

Verified parsed but **unused** — this is what items 1 and 2 cash in:
- `Row.promptMark` carries OSC 133 A/B/C/D as 1/2/3/4 and survives reflow
  (`Terminal+Resize.swift:109`). The exit status in `D;<status>` is **dropped** — item 1 must
  capture it.
- OSC 8 hyperlink ids are stored per cell (`Cell.swift`) and nothing hit-tests them.

## Item 1 — Prompt marks (`feat/prompt-marks`)

Core: `Sources/NyxCore/Shell/PromptMarks.swift`
- `PromptMarkKind` enum over the raw 1–4, so call sites stop using magic numbers.
- `Row.exitStatus: Int32?`, set from `D;<status>`, carried through reflow beside `promptMark`.
- `CommandRegion { promptRow, commandRow, outputRows, endRow, exitStatus }` in absolute
  (scrollback-relative) coordinates, so it survives scrolling like `Selection` does.
- `Terminal.previousPrompt(before:)`, `nextPrompt(after:)`, `command(containing:)`.

App:
- Actions `jump_previous_prompt` / `jump_next_prompt` (⌘↑ / ⌘↓), `select_command_output`,
  `copy_last_command_output`.
- Status gutter: a narrow column drawing a mark per command row, green for exit 0, red otherwise.
- Notification when a command finishes while its window is unfocused, carrying the command and its
  status. Only for commands that ran longer than a few seconds — a notification per `ls` is noise.

## Item 2 — Links and paths (`feat/links`)

Core: `Sources/NyxCore/Text/LinkScanner.swift`
- Ranges for bare URLs, and for paths including the `file:line[:col]` form compilers print.
- OSC 8 ranges read from cell attributes, which take priority over anything matched by pattern.
- Pure over a row's text plus its cells; no AppKit.

App: hover underlines the link under the pointer and sets the pointing-hand cursor; ⌘-click opens
it with `NSWorkspace` (the decision recorded in the spec). A path opens in the user's editor via
`open`; `open-file-command` overrides that.

## Item 3 — Search (`feat/search`)

Core: `Sources/NyxCore/Search/BufferSearch.swift`
- Literal and case-insensitive matching over scrollback plus screen, returning absolute ranges.
- `next(from:)` / `previous(from:)` wrapping at the ends.
- Incremental: searching for a longer query must reuse the previous result set rather than
  rescanning a 10k-line buffer per keystroke.

App: `⌘F` bar over the pane, highlight every match, current match distinct, `⏎`/`⇧⏎` to step,
`⎋` to dismiss and restore the selection that was there before.

## Item 4 — Command palette (`feat/palette`)

Core: `Sources/NyxCore/Palette/FuzzyMatch.swift`
- Subsequence scoring with bonuses for word starts and runs, so `nt` ranks "New Tab" above
  "Next Tab" only if the acronym matches better — tested against a fixed ranking.

App: `⌘⇧P` opens a list over the pane, sourced from `ActionCatalog.allMenuActions` plus themes and
open tabs. Typing filters, `⏎` runs, `⎋` dismisses.

## Item 5 — Smart selection (`feat/smart-selection`)

Core: `Sources/NyxCore/Text/SmartSelection.swift`
- Double-click picks the whole token under the pointer by pattern — URL, path, `file:line`, commit
  hash, IP address, quoted string — and falls back to the current word-separator rule when nothing
  matches.
- Shares its pattern table with `LinkScanner` so a thing that is clickable and a thing that is
  selectable are the same thing.

## Order

1, then 5 and 2 together (they share the pattern table), then 3, then 4. Each lands with its own
tests and commit; review after each pair.
