# Command blocks v2 — design

**Date:** 2026-09-05. **Status:** draft for review.
**Parent spec:** `2026-09-03-nyx-terminal-design.md` §6.6 (shell integration), §11 (phase 3:
"блоки команд"). **Brief:** `.superpowers/sdd/nyx-brief.md` — "multi-line commands shown as a
request/response block, foldable, re-runnable" is marked done there; this document is the second
pass, prompted by the user's own verdict on the first: *the request and response blocks should
hide and show with buttons in the terminal, more explicitly than now.*

## 1. Goal

A command and its output are already one thing in the model (`CommandRegion`) and on screen
(`CommandBlock`: a spine and a summary). What is missing is the part a person sees and reaches for:

- nothing on screen says a block can be folded — the only control is a 2 pt spine in the padding,
  and none of the fold actions has a key;
- a folded block is a dim italic line, with no status, no preview and no way back but a blind click;
- a fold hides *all* of the output, and the lines people want are the last ones;
- a running command shows nothing but an amber spine; there is no elapsed time and no way to ask
  for a notification before the ten-second heuristic decides for you;
- folds are addressed by absolute row and vanish once the scrollback ring is full, which reads as
  "it unfolded by itself";
- a block cannot be copied as a unit, so the thing people do most with a `curl` response — paste it
  into a chat or a ticket — takes a drag-selection.

After this change a block explains itself: a chevron on its command row says it folds, hovering it
shows what can be done to it, folding keeps the tail, a running one counts up, and every one of
those has a keyboard route, a menu entry and a test.

Decisions the user made (2026-09-05): chevron always visible with buttons on hover; a fold keeps
the last three lines by default; automatic folding is off by default.

## 2. Non-goals

- Output lenses (JSON pretty-printing, header/body split of `curl -i`) and block-to-block diff.
  They build on this package and get their own spec.
- A block palette over history and the "explain this failure" command. Same.
- Blocks without shell integration. Everything here needs OSC 133; without it the terminal behaves
  exactly as it does today, and the settings window already says how to get marks in bash/fish.
- Blocks on the alternate screen or while a program reports the mouse. `CommandBlockChrome.isAllowed`
  is unchanged and gates everything below, overlay included.
- Restoring *folds* across a relaunch. Blocks are restored (§5.8); which of them were folded is not.

## 3. Approaches considered

**A. Header as a virtual row (Warp).** Insert a chrome row above each command holding the buttons.
Rejected: it takes a screen row per block, changes the viewport mapping for every block on screen
(not only folded ones), and puts chrome *in* the grid, which is the model Warp chose and the reason
its blocks break under tmux.

**B. Everything in Metal.** Chevron, buttons and hover state drawn by `buildChrome`, hit-tested by
the pane. Consistent with the spine, but buttons need hover feedback, tooltips and accessibility
elements, all of which AppKit gives for free and Metal chrome would reimplement; and none of it
could be looked at through `UISnapshot`.

**C. Chevron in Metal, buttons as an AppKit overlay (chosen).** The always-visible part — the
chevron beside the summary — is one more glyph in the summary the renderer already draws, so it
costs nothing and is on screen for every block. The hover-only part is one `NSView` per pane,
placed over the hovered block's command row like `StickyPromptView` is placed over the top row:
real buttons, real tooltips, real accessibility, rendered by `UISnapshot` in every state. The grid
underneath is untouched.

## 4. User-visible behaviour

### 4.1 The command row

Right-aligned on the command row, in the block's colour, always: `exit 1 · 8.8s ▾`. Open blocks end
in `▾`, folded ones in `▸`. A running command shows the elapsed time once it has run for one
second: `12s ▾`, updated once a second. A successful command that took under half a second shows
only the chevron. The summary is never drawn over the command's own text (existing rule).

The chevron and the summary text are one click target: a click toggles the fold, ⌥-click toggles a
*full* fold (§4.3). The cursor is a pointing hand over it.

### 4.2 Hover

Moving the pointer over any row of a block:

- tints every visible row of that block with `Palette.blockHoverBackground` — the theme's accent
  blended into the background at about 6 % (amended 2026-09-05: the foreground axis is collinear
  with one-dark's selection colour, and a raw cursor colour is unvetted), well under the selection
  colour, and drawn *under* every row's own background so a selection or a search hit on a hovered
  row stays visible;
- shows the header overlay on the block's command row, right-aligned, replacing the Metal summary
  on that row while it is shown. Contents, left to right: the summary text, **Copy**, **⋯**, and
  the chevron as a button. Buttons have tooltips and accessibility labels. If the command row is
  above the viewport the overlay is not shown (nothing to attach it to) but the tint still is.

A pane narrower than the smallest strip shows no strip at all, by design: the chevron on the command
row, the status mark in the gutter, `⌘⇧↑` and the right-click menu all still fold the block, and a
strip drawn anyway would cover the command it describes.

The overlay hides when the pointer leaves the block, leaves the pane, or when block chrome becomes
disallowed (alt screen, mouse reporting). Scrolling with the pointer still moves the hover with the
rows underneath, the same way the hovered link does.

**Copy** copies the output as plain text. **⋯** opens a menu:

```
Copy Command
Copy Output
Copy as Markdown
Save Output…
─────────────
Run This Command Again
Edit and Run This Command…
─────────────
Fold Output / Unfold Output
Fold Everything Long / Unfold Everything
─────────────
Notify When Done            (running commands only, checkmark when armed)
```

The right-click menu on any row of a block gets the same block group above the existing entries,
so the mouse route and the menu route cannot disagree.

### 4.3 Folding

A fold keeps the command row, then a placeholder row, then the last `fold-keep-lines` rows of
output (default 3):

```
$ make test                                          exit 1 · 8.8s ▸
▸ … 1,231 lines hidden
  FAILED: Tests/NyxCoreTests/FoldTests.swift:41
  1 failure, 1,002 passed
$ █
```

The placeholder is a button: clicking it unfolds. ⌥-click on the chevron, or "Fold Output" with ⌥
held, folds *everything*, placeholder only. When the output has `fold-keep-lines + 1` rows or fewer
a tail fold would hide at most one line and add one, so it becomes a full fold.

A running command may be folded; its tail keeps showing the newest lines, which is a live `tail -f`
of a noisy build.

Keyboard: `fold_command` gets **⌘⇧↑** by default (toggle, the command at the top of the viewport
or the last finished one — unchanged rule). `fold_all_long_output` stays a toggle with no default
chord and is in the ⋯ menu, the Go menu and the palette.

### 4.4 Automatic folding

`fold-long-output = 0` (off). When set to N, a finished command whose output is longer than N rows
is tail-folded at the moment the *next* command starts running (its `C` mark arrives), never while
it is the newest thing on screen. A block the user has unfolded by hand is not folded again.

### 4.5 Running commands and notifications

"Notify When Done" arms a notification for that command regardless of how long it ends up running
and whether the window is focused. `notify_when_done` is also an action (no default chord) that
arms it for the currently running command, so a build can be armed from the keyboard before
switching away. The notification carries the command line, its status and duration, as today.

### 4.6 Sticky prompt

The pinned strip gains the block's summary at its right edge (`exit 1 · 8.8s`), and its existing
click still jumps to the command.

### 4.7 Copy as Markdown

````
```
$ curl -s https://api.example.com/v1/things
{"items":[…]}
```
````

The command line with a `$ ` prefix and the output, plain text, one fence. No metadata: the target
is a chat message or a ticket, and people delete metadata before pasting.

### 4.8 Blocks survive a relaunch

The scrollback transcript written at quit gains the OSC 133 marks (`A`, `B` with column, `C`,
`D;status`) so a restored session has its blocks, gutter marks and summaries. Durations are not
restored (nothing in the buffer knows them once the process is gone), so restored summaries show
status only.

### 4.9 Failure has a face

- No shell integration: no chevrons, no overlay, no tint; the fold actions beep and their menu
  items are disabled with the existing "needs shell integration" reason.
- A block whose output is empty: chevron is not drawn, fold beeps, Copy is disabled.
- Chrome disallowed mid-hover (a TUI starts): the overlay disappears on the next frame.

## 5. Design

### 5.1 Command identity (`NyxCore/Terminal`)

`Row.commandID: UInt32` (0 = none). `Terminal` keeps `nextCommandID`, starting at 1, and stamps the
row on `OSC 133 ; A`. Reflow (`Terminal+Resize`) carries it beside `promptMark`. `Row.reset` clears
it. IDs are monotonic, which is what makes the rest cheap: "is this fold still alive" is
`id >= terminal.oldestCommandID`, and `oldestCommandID` is the id on the first prompt row, found by
walking from row 0 to the first prompt (bounded by one command's output, done only when there are
folds to prune).

`CommandRegion` gains `id: UInt32`. `Terminal.command(containingAbsoluteRow:)` fills it from the
prompt row. `Terminal.promptRow(ofCommand id:)` walks the visible rows first, then the buffer,
and is used only by actions that start from an id (a menu item, a pending notification).

`Terminal.runningCommand: (id: UInt32, startedAt: Double)?` exposes what `commandStartedAt` already
holds, so the pane can show elapsed time and the watcher can identify what finished.

### 5.2 Folding v2 (`NyxCore/Shell/OutputFolding.swift`)

```swift
public enum FoldShape: Equatable { case tail(keep: Int), all }
public struct OutputFolding: Equatable {
    private var folds: [UInt32: FoldShape]
    private var openedByHand: Set<UInt32>          // §4.4: never auto-folded again
    func shape(of id: UInt32) -> FoldShape?
    mutating func fold(_ id: UInt32, _ shape: FoldShape)
    mutating func unfold(_ id: UInt32)             // records openedByHand
    mutating func toggle(_ id: UInt32, keep: Int)  // open ↔ tail
    mutating func toggleFull(_ id: UInt32)         // open ↔ all
    mutating func prune(olderThan oldest: UInt32)
    mutating func autoFold(finished region: CommandRegion, longerThan: Int, keep: Int)
}
```

`DisplayRow` gains nothing: a tail fold is `.row(prompt)`, `.fold(id, hidden)`, then `.row` for each
kept line. `effectiveShape(region, keep)` applies the small-output rule (§4.3) in one place.
`displayRows(from:count:folding:)` and `foldedCommand(containingOutputRow:)` read
`row.commandID` instead of the prompt-row set; the "no folds → no walk" fast path is unchanged.

The placeholder row text becomes `▸ … 1,231 lines hidden`. `foldPlaceholderRow` is unchanged
otherwise.

### 5.3 Block header model (`NyxCore/Shell/CommandBlock.swift`)

```swift
public struct BlockHeader: Equatable {
    public enum State: Equatable { case running(elapsed: Double), finished, failed(status: Int32) }
    public let id: UInt32
    public let state: State
    public let folded: Bool
    public let hasOutput: Bool
    public let summary: String            // "exit 1 · 8.8s", "12s", ""
    public var chevron: String            // "▾" / "▸", "" when !hasOutput
    public var summaryWithChevron: String // what the renderer draws
    public var actions: [BlockAction]     // what the ⋯ menu lists, in order, with enabled flags
}
public enum BlockAction: Equatable { case copyCommand, copyOutput, copyMarkdown, saveOutput,
    runAgain, editAndRun, toggleFold, toggleFoldAll, notifyWhenDone(armed: Bool) }
```

`CommandBlock.header(now:folding:notifyArmed:)` builds it. The visible-rows and `showsHeader`
logic is unchanged. `Terminal.block(atAbsoluteRow:)` is used for hover and returns the id.

The hover decision — which block, if any, the pointer is over, and whether the overlay may show —
is `BlockHover.resolve(pointerRow:, blocks:, allowed:) -> BlockHover?` with `id`, `rows`
(visible range for the tint) and `headerRow` (nil when the command row is off screen).

### 5.4 Export (`NyxCore/Shell/BlockExport.swift`)

`BlockExport.markdown(command: String, output: String) -> String` and
`Terminal.commandText(of:)` / `outputText(of:)` (plain text via `Transcript.plainText` over the
region's rows, trailing blank lines trimmed). "Save Output…" writes `outputText`.

### 5.5 Notifications (`NyxCore/Shell/CommandWatcher.swift`)

`FinishedCommand` gains `id`. `CommandNotificationRule.shouldNotify(finished:, armed: Set<UInt32>,
windowFocused: Bool, minimumDuration:) -> Bool`: armed wins over both duration and focus. The
pane keeps the armed set and clears an id when it fires or its block leaves the buffer.

### 5.6 Automatic folding trigger

The watcher already observes the running → not running transition; the pane also observes
not running → running (a new `C`), and on that edge asks `folding.autoFold(finished:
lastFinishedCommand, longerThan: config.foldLongOutput, keep: config.foldKeepLines)` when the
setting is above zero.

### 5.7 Config, actions, bindings (`NyxCore/Config`, per `nyx-config-keys`)

| Key | Default | Meaning |
|---|---|---|
| `fold-keep-lines` | `3` | Rows of output a fold keeps visible at the end. `0` folds everything |
| `fold-long-output` | `0` | Auto-fold output longer than this many rows once the next command starts. `0` = off |

Both live in `ConfigDiff` as a "folding" flag; `Pane.apply` re-reads them (an existing fold keeps
its shape). Settings → Behaviour gets two steppers.

Actions: `copy_block_markdown` ("Copy Last Command as Markdown"), `save_command_output`
("Save Last Command Output…"), `notify_when_done` ("Notify When the Running Command Finishes").
All three in `ActionCatalog` under Go, in the palette, disabled with a reason when there is no
block / no running command. Binding: `⌘⇧↑ = fold_command`. The bindings table in
`docs/configuration.md` gains the row; the collision check is against that table.

### 5.8 Transcript marks (`NyxCore/Session/Transcript.swift`)

For rows with `promptMark`, the transcript emits the marks in OSC 133 form at the right column
(`A` at column 0 before the row's text, `B` at `inputStartColumn`, `C` at column 0, `D;status`
at column 0 of the row carrying it). `Terminal.feed` of the result reproduces `promptMark`,
`inputStartColumn`, `exitStatus` and `commandStatus`; ids are re-assigned on the way in, which is
fine because nothing persisted refers to them. `Transcript.Options.plainText` emits none of it.

### 5.9 Rendering (`NyxRender`, per `nyx-rendering`)

- `RenderFrame.highlightedRows: Range<Int>?` — the hovered block's visible rows. Drawn in
  `buildChrome` as one translucent rect in the background bucket (blending is already on), so it
  is outside the row cache and needs no `RowKey` change. A `PartialRedrawTests` scenario proves
  hover on → off leaves the cache-using renderer pixel-identical to a full rebuild.
- `blockSummaries` text now ends in the chevron. `▾`/`▸` (U+25BE/U+25B8) come through Core Text
  fallback like any other glyph. A pixel test asserts the chevron has ink in the summary's last
  cell.
- `Palette.blockHoverBackground`: background blended toward `Palette.accent`, the first amount from
  6 % to 20 % that is ≥ 4 units off `background`, ≥ 8 units off `selectionBackground` and keeps
  `foreground` at ≥ 4.5:1; a test holds every built-in theme and a synthetic saturated-cursor theme
  to that.

### 5.10 The pane (`NyxApp/Pane.swift`, `NyxApp/BlockHeaderView.swift`)

What stays in the pane is conversion and placement:

- `updateHover` (already per-cell, already under the lock once) also asks
  `BlockHover.resolve` and, on change, updates `hoveredBlock`, marks dirty and repositions the
  overlay. `clearHover` clears it.
- `render()` fills `highlightedRows` from `hoveredBlock`, builds each visible block's
  `BlockHeader` and passes `summaryWithChevron` to `blockSummaries`, suppressing it on the row the
  overlay covers. It records the summary's cell range per row so a click can be resolved to the
  chevron target.
- A 1 Hz `Timer` runs only while a running block's command row is on screen; it calls
  `markDirty`. Nothing runs when no command is running, so idle CPU stays at 0.
- `mouseUp` checks, in order: fold placeholder, chevron/summary target, spine, caret move.
- `BlockHeaderView` (new) is built like `StickyPromptView`: hidden by default, `hitTest` passes
  through while hidden, `update(header:palette:font:)` compares before it applies. Its buttons
  are `NSButton`s with tooltips; the ⋯ menu is built from `header.actions` so the list and its
  enabled flags come from Core. Snapshot cases: finished, failed, running, folded, no-output, in
  light and dark.
- The chevron in Metal gets a `DrawnControlElement` per visible header ("Fold output of `make
  test`", role button) so VoiceOver reaches what the mouse reaches.
- `contextMenu(at:)` adds the block group from `header.actions` above the existing items.
- `StickyPromptView.update` gains the summary string.

### 5.11 Tests

Core (`Tests/NyxCoreTests`):
- `CommandIDTests`: ids assigned on `A`, monotonic, survive reflow, cleared by reset, present on
  `CommandRegion`; `oldestCommandID` after ring eviction.
- `OutputFoldingTests` (rewritten): tail keeps the last N, small-output rule, full fold, toggle
  cycles, `openedByHand` blocks auto-fold, prune by id, `displayRows` with a tail fold and with a
  viewport starting inside one, snap-out-of-fold with a tail.
- `BlockHeaderTests`: summary and chevron per state, elapsed formatting at 0.4 s / 1 s / 90 s,
  action list and enabled flags per state.
- `BlockHoverTests`: pointer on command row, on output, on the row after the block, header row nil
  when the command is above the viewport, nothing when chrome is disallowed.
- `BlockExportTests`: markdown shape, trailing blanks trimmed, multi-row command lines.
- `CommandNotificationRuleTests`: armed beats duration and focus; unarmed keeps today's rule.
- `TranscriptTests`: marks round-trip through `feed`, plain text has none.
- `ConfigTests` / `ConfigDiffTests` / `KeyBindingTests` / `ActionCatalogTests` for the keys,
  actions and the new chord.

Render (`Tests/NyxRenderTests`): hover tint pixel test, chevron pixel test, partial-redraw scenario.

UI (`UISnapshot`): `block-header-{finished,failed,running,folded,no-output}-{dark,light}.png`,
`sticky-prompt-summary.png`.

Rung 6, one temporary hook in `AppDelegate`: open a window, run `printf` with the marks through
the session, call `updateHover` with a point on the block, print whether the overlay is visible and
its accessibility children; post ⌘⇧↑ to `keyDown` and print `folding`; call the ⋯ menu's copy item
and print the pasteboard. Removed before commit.

## 6. Performance

- The per-frame cost is unchanged when nothing is hovered and nothing is folded: `highlightedRows`
  is nil, summaries are built exactly as today plus one glyph.
- Hover work happens on cell change only (existing guard), and asks `visibleBlocks`, which walks
  visible rows only.
- Prune walks from row 0 to the first prompt, only when folds exist; the old prune read one row per
  fold. Both are far below a frame.
- `make bench` is unaffected: the parser path gains one store on `A`.

## 7. Documentation

README "Because it knows where commands begin and end" is rewritten around the block; the
`docs/configuration.md` tables gain the two keys, three actions and the chord; `docs/status.md`
"Command blocks" row and the competition table ("hover header, tail fold, live timer, markdown
export: Nyx yes, others no/partial"); `docs/architecture.md` "Where to add things" gets a
"block header state" row; §11 of the parent spec records the phase-3 block item as closed.

## 8. Open questions resolved by default

- Chevron glyphs `▾`/`▸` rather than `▼`/`▶`: the small forms sit on the text line without
  looking like a button in the grid.
- The overlay uses the pane background as its own, so it reads as part of the row rather than a
  floating box; a 1 px hairline in `noteForeground` on its left edge separates it from command
  text that reaches under it.
- `Copy` in the overlay copies output, not the command: output is what a person wants nine times
  in ten, and the command is one click from `⋯`.
