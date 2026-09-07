# UX round — design

**Date:** 2026-09-07. **Status:** draft for the owner's read; the decisions in it were delegated
("сам реши исходя из того как будет лучше приложению") and are recorded in
`.superpowers/sdd/2026-09-07-ux-round/decisions.md`.
**Audit inputs:** `inventory.md`, `findings-a11y.md`, `findings-design.md`, `findings-pm.md`,
`snapshot-machinery-report.md` (same directory), plus yesterday's `design-review.md` UX-round
ledger and the PM's UX list in `progress.md`.
**Precedence when two inputs disagree:** `decisions.md` → `findings-design.md` §3 → a11y → PM.
Every disagreement that mattered is written down where it applies, with the ruling.

---

## 1. Goal, the bar, and what is in scope

The owner's standing complaint about the block — the surface Nyx is used through more than any
other — is "некрасиво и неочевидно как работает": four separate presentations of one command (an
AppKit gutter capsule, a Metal spine, an in-grid summary with a chevron, an AppKit hover strip)
that encode the same fact twice 1.5 pt apart, offer six routes to fold in three glyphs at three x
positions, label nothing below `Copy`, drop the status code before dropping a second menu, and
*remove* information when the pointer arrives. This round does not patch those findings one by
one; it makes the block one system with one Core decision table, and then walks the rest of the
chrome — lenses, shell integration, settings, tab bar, palette, search, banners, remote — until
each surface explains itself without a manual.

**The bar.** Warp for block interactions: labelled hover verbs, whole-row targets, the metadata
bound to the block rather than stranded at the far margin. Ghostty for restraint: nothing costs a
terminal column or a scrap of attention while the pointer is elsewhere. Where the two conflict,
**restraint wins at idle and clarity wins on hover** (`decisions.md` §2). Nyx's own advantage over
both is stated once and built once: *the gutter mark is the fold control, it costs no columns at
idle, and it grows a label on hover* — iTerm2's mark column with Warp's verbs and Ghostty's silence
when nobody is pointing at it.

**In scope:** drawn chrome outside the terminal grid, its Core decision logic, its keyboard paths,
its VoiceOver labels and its pictures. Readability floors on existing palettes (4.5:1 for text,
3:1 for a UI shape that is the only cue).

**Out of scope:** the theme palettes themselves (only the floors, never a hue), the app icon, VT
behaviour, and anything that needs a new product feature rather than clarity (`decisions.md` §5).
**Not to be touched**, on the PM's ruling: the lens as an idea, the `⌘E Workbench` pill, the
request workbench's form, automatic zsh injection through `ZDOTDIR`, and the summary vocabulary
(`exit 1 · 8.8s`, `200 · 142 ms · 1.2 KB · json`, `11 runs · p50 140 ms · p95 190 ms · 2 failures`)
— move it, re-tone it, never re-word it.

**Architecture, unchanged and binding** (`CLAUDE.md`): every decision below is a value or a pure
function in `NyxCore`, unit-tested; `NyxApp` converts events and draws; `NyxRender` learns nothing
about chrome; the build stays warning-free and `make bench` stays at or above 180 MB/s. Six waves,
in this order, each landing on its own commits: block chrome → lenses and watch → shell
integration → settings and sheets → tab bar, palette, search, banners → remote strip and pairing.

---

## 2. Wave 1 — block chrome as one system

### 2.1 The decision that replaces four presentations

`CommandBlockChrome` (`Sources/NyxCore/Shell/CommandBlock.swift`) becomes the single authority for
what is drawn where and what is clickable. Today it answers `overlayPlacement` and
`summaryPlacement` separately and the pane fills the gaps; after this wave it answers one question:

```swift
public enum CommandBlockChrome {
    /// Free columns after the command's last glyph, once the trailing wide-cell spacer is counted
    /// (D19: `Renderer.lastUsed` ignores a trailing `.wideSpacer`, so the count is taken here).
    public enum WidthClass: Equatable { case w3, w2, w1, w0 }
    public static func widthClass(freeColumns: Int) -> WidthClass   // w3 ≥ 34, w2 18…33, w1 8…17, w0 < 8

    public struct StripPlan: Equatable {
        public let readout: String            // the summary sentence, never re-worded
        public let readoutTone: SummaryTone
        public let dots: [WatchSeries.Dot]    // empty when dropped
        public let overflowDot: String?       // "+18" when the 30-dot cap bites
        public let pills: [Pill]              // leading → trailing, already dropped to fit
        public let firstColumn: Int           // never inside a word; nil-equivalent when W0
    }
    public enum Pill: Equatable {
        case fold(FoldLabel)                  // .fold / .unfold, .labelled or .bare
        case copy(enabled: Bool)
        case lens(name: String, on: Bool)     // "Pretty" / "Raw" / "Headers" / "Body" / "Filter" / "Grep" / "Diff"
        case stop
        case actions(Actions)                 // .labelled ("Actions ▾") / .glyph ("⋯")
    }
    public static func stripPlan(_ header: BlockHeader, freeColumns: Int) -> StripPlan?
    public static func gutterCap(_ header: BlockHeader, hovered: Bool, folded: Bool) -> GutterCap
    /// Every row-height hit target, clamped so `line-height = 0.8` cannot make it 13 pt.
    public static func hitRowHeight(cellHeight: CGFloat) -> CGFloat   // max(cellHeight, 16)
}
```

`BlockHeaderView`, `PromptGutterView` and `Pane` read `StripPlan` and `GutterCap` and draw them.
No `if` about which control survives, which glyph to use, or where the strip begins stays in a
view. `Pane.foldBlock(atPointInPadding:)` (`Pane.swift:2701`) is **deleted**: a click in the left
padding no longer folds anything, because the padding is not a control and never said it was.

### 2.2 The gutter is the head of the spine

- **Hit width 20 pt**, independent of `padding` and allowed to overlap the first text column
  (`PromptGutter.hitWidth = 20`; `hitTest` already hands unmarked points back, `PromptGutterView.swift:46`).
  This replaces `maximumWidth = 14` and the wrong comment at `PromptGutter.swift:64-68`; at the
  shipping `padding = 8` the real target today is **8 pt wide and 13 pt tall at `line-height 0.8`**
  (a11y 6.1), which is half what the code claims.
- **Drawn mark 3 pt wide × `hitRowHeight(cellHeight:)` tall**, in the block's tone, and it is the
  **head of the spine** — same 3 pt, same colour, continuous down the block's rows. The separate
  1 pt Metal spine and the 4.5 pt capsule stop existing as two marks: one shape, one fact, no more
  "a green line with beads on it" at x ≈ 1 pt (PM §1, design §2.7 MUST).
- **The mark moves off the window edge**: its leading inset is 4 pt, so it is no longer inside the
  window's resize margin.
- **Shape carries state**, not colour alone (a11y 6.2): succeeded = solid cap; failed = solid cap
  **plus a full-row bar**; running = hollow cap; no output = cap at 40 % alpha and **not pressable**.
  *Disagreement:* a11y 6.2 proposed a half-height mark for success; `findings-design` §3.2 gives the
  four shapes above. **Ruling: design §3.2** — failure is the state that must be findable while
  scrolling, so failure gets the extra ink, not success.
- **On hover of any row of the block**, the cap becomes an 8 pt `▾` (or `▸` when folded) in the same
  colour. That is the only new mark this wave draws; nothing is added at idle.
- ⌥-click still selects the block's output; the tooltip and `GutterMarkLabel.text` keep saying so,
  and `select_command_output` now names a block (§8.2).

### 2.3 The strip

Geometry, exact (design §3.2):

| thing | value |
|---|---|
| strip height | 20 pt, centred on the command row (fixes `Pane.swift:3090`'s 16 pt frame that sliced every pill's cap and descender) |
| pill height | 20 pt, corner radius 6 pt |
| glyph pill width | 24 pt |
| label pill width | text width + 16 pt |
| gap between pills | 6 pt |
| trailing inset | 8 pt |
| pill fill | `palette.foreground @ 0.14` |
| pill hairline | `palette.foreground @ 0.22`, ≥ 1.6:1 against the fill |
| leading edge | 8 pt of solid strip ground, then a 2-cell gradient to transparent |
| strip ground | the row's own hover tint, not `palette.background` — a `background` band on a tinted row reads as a floating rectangle |
| dots | filled, 7 pt, on a 10 pt pitch; the running run is a **filled accent** dot, not a hollow amber ring (which shares a hue with redirect and reads as a smudge at 6 pt) |
| dot cap | 30 dots; past it the leading dot is replaced by the label `+18` — the cap stops being silent (D16) |

**The strip is right-aligned into the free columns *after the command's last glyph* and never
begins inside a word.** `StripPlan.firstColumn` is a column index, computed in Core from the
command row's last used cell; if the plan does not fit, there is no strip on that row and the
gutter still folds. This kills `…'{"service":"we8.8s ⋯ ▾` (snapshot report §3.5) without the
two-cell fade pretending to be a gap.

Every tinted control resolves through `SummaryTone.color(in:)` / `RGB.readable(_:on:towards:)`, so
gruvbox-dark's lit `{ }` at 2.82:1 (snapshot §3.4) cannot recur.

**The lens control is a chip carrying the lens name**, not `{ }`: `Pretty`, `Raw`, `Headers`,
`Body`, `Filter`, `Grep`, `Diff`, with a trailing `▾` when the menu offers others. Off = the same
pill fill as its neighbours. On = **filled `palette.accent` with `palette.textOn(accent)` ink** —
the pattern `SearchBarView.updateScopeTint` (`:181-186`) and `tabbar-toggle-running` already use.
`ResponseLens` gains `chipTitle: String` so the name is decided in Core.

### 2.4 One control folds

**Fold triangles share one column.** Every `▸`/`▾` that means "fold" — a fold placeholder row, a
lens container line, and nothing else — is drawn at **column 0 of the text area**, 8 pt, in the
row's tone. The in-grid command-row summary keeps its right alignment and **loses its chevron**;
it is a readout, not a control, and it stops being clickable. That removes the contradiction
between `Pane.swift:3053` and `:2016` about which chevron gets a pointing hand, and it means the
pointing hand is now truthful everywhere: column-0 triangles and strip pills have it, the summary
does not (and the placeholder row, which is a control, finally gets one — a11y 6.13).

So the routes to fold, after the wave: **the gutter cap** (mouse), **a column-0 triangle on a
placeholder or lens container row** (mouse), **the strip's `Fold`/`Unfold` pill** (a labelled
duplicate, wide widths only), **⌘⇧↑ on the block cursor** (keyboard). The bare `▾` pill is
deleted. Six down to four, and two of them are labelled.

### 2.5 The strip never hides what it replaces

`Pane.swift:2100` suppresses the in-grid summary while the strip is up. Since the strip at
`.minimal` also dropped the summary, hovering a block *removed* the thing you were reading — worst
on a watched block, which showed only `Stop ⋯ ▾` (snapshot §3.3, PM §16). The decision table below
makes the status the **last thing dropped**, so the suppression is safe: whatever the summary said,
the strip says at least as much.

### 2.6 The decision table

Width class = free columns after the command's last glyph. **W3 ≥ 34, W2 18–33, W1 8–17, W0 < 8.**

| State | W3 | W2 | W1 | W0 |
|---|---|---|---|---|
| idle (any) | gutter cap + spine; summary at the row end, no chevron | same | same | same — nothing costs a column at idle |
| hovered, finished | `‹summary› [Fold] [Copy] [Actions ▾]` | `‹summary› [Copy] [Actions ▾]` | `‹summary› [⋯]` | no strip; cap → `▾` |
| hovered, failed | `exit 1 · 8.8s [Fold] [Copy] [Actions ▾]` (`.failure` tone) | `exit 1 · 8.8s [Copy] [Actions ▾]` | `exit 1 [⋯]` | cap → `▾` |
| hovered, running | `12s [Fold] [Copy] [Actions ▾]` | `12s [Copy] [Actions ▾]` | `12s [⋯]` | cap → `▾` |
| folded | `‹summary› [Unfold] [Copy] [Actions ▾]` | `‹summary› [Unfold] [Actions ▾]` | `‹summary› [⋯]` | cap → `▸` |
| hovered, HTTP | `200 · 142 ms · 1.2 KB · json [Pretty ▾] [Fold] [Copy] [Actions ▾]` | `200 · 142 ms [Pretty ▾] [Actions ▾]` | `200 [⋯]` | cap → `▾` |
| lensed | as HTTP, the lens chip filled accent | as HTTP | `200 [⋯]` | cap → `▾` |
| watched, running | `●●●○ run 12 · 200 · 100 ms · every 5 s [Stop] [Copy] [Actions ▾]` | `run 12 · 200 [Stop] [Actions ▾]` | `run 12 [Stop] [⋯]` | `[Stop]` alone over the tail |
| watched, finished | `●●●● 11 runs · p50 140 · p95 190 · 2 failures [Copy] [Actions ▾]` | `11 runs · 2 failures [Actions ▾]` | `11 runs [⋯]` | — |
| no output | `‹summary› [Actions ▾]` | same | `[⋯]` | — |

**Drop order, right to left:** dots → `Copy` → the `Fold`/`Unfold` label → `Actions ▾` collapses to
`⋯` → interval and percentiles → run count. **Never dropped: `Stop`, and the status or exit code,
which is the last thing to go.** That is the inverse of today, where a recoverable `Copy` outlived
the unrecoverable status and two identical grey circles outlived it too.

`OverlayControls`' three levels (`.full`/`.noCopy`/`.minimal`) are replaced by `WidthClass` and the
per-pill drop rule; the enum stays only as long as its callers need one commit to move.

### 2.7 The sticky strip

The single worst defect in the picture set (snapshot §3.2, PM's #1): `foreground @ 0.10` over live
text with **nothing blanking the row underneath**, so a pinned command and the output beneath it
print on top of each other in every scrolled composite. Four changes, all small:

1. `Pane.render` **blanks the covered row** — `Pane.stickyPromptRow` already computes it
   (`:105`, written `:2221`) and is read only by the click handler (`:3642`).
2. The band's ground becomes **opaque** `palette.background`, with the strip's own appearance pin.
3. A **1 px bottom divider** at `palette.foreground @ 0.20`.
4. A **leading `↑` glyph** at 8 pt in `palette.foreground @ 0.55`, so the band says it is a control
   at all — today it has no bezel, no chevron, no pin and no divider, and the whole thing is a
   click target (design §2.8).

And the label stops lying: `StickyPromptLabel` says "Running command" for a finished one
(a11y 7.1). It takes `BlockHeader.summary` and `SummaryTone` instead, so the pinned line reads
`swift build … · exit 1 · 8.8s` in the failure tone.

### 2.8 Keyboard: `BlockCursor` and one route

Eight block-scoped actions currently use **five different rules** for "which block": `commandToFold()`,
`lastFinishedCommand`, pointer-or-hovered-or-last, and newest-run-is-last
(a11y §11.1). The pointer path and the keyboard path therefore target different blocks silently
(PM §5). One value in Core replaces all five:

```swift
public struct BlockCursor: Equatable {
    public var commandID: CommandID?
    public static func afterViewportMove(_ current: Self, visible: [CommandID], fallback: CommandID?) -> Self
    public static func moved(_ current: Self, by: Direction, among: [CommandID]) -> Self
}
```

"The block the keyboard is on." Moved by ⌘↑/⌘↓ (which already move the viewport and now also move
the cursor), reset to `commandToFold()`'s answer when the viewport moves for another reason, and
targeted by `fold_command`, `select_command_output`, `copy_command_output`, `copy_block_markdown`,
`save_command_output`, `edit_and_run_command`, `toggle_http_lens` and `stop_watch`.

`block_actions` (**⌘⇧A**, free; Warp's chord) pops the block menu at the cursor's row, built through
the same path as `morePressed` — `BlockHeader.actions` plus `menuHeader()`, so `hasPreviousRun` is
filled the way the two mouse paths already fill it. That is the **one** keyboard route to
everything the strip offers; no other new chord is added, and the five "which block" rules retire.
The menu is also assigned to `view.menu` so VO-⇧-M finds it.

*Disagreement:* the PM's model of a fixed, full-width, labelled Warp-style header row per block was
considered and rejected — it costs a terminal row per block and re-flows the transcript, which
`decisions.md` §2 rules out at idle. **Ruling: decisions.md §1/§2.**

---

## 3. Wave 2 — lenses and watch polish

Prioritised by the PM at the end of the curl-workbench round; the lens as an idea is untouched.

1. **Clearing the Filter field returns to the previous lens**, not to raw. `LensChoices` keeps
   `previous: ResponseLens?` per block; clearing restores it. (PM's first item; today an empty
   field drops the reader to raw and loses the pretty view they were reading.)
2. **Drag-select works on container lines.** Today a mouse-down anywhere on a foldable lens line
   folds it, so no drag can start there. The fold acts on **mouse-up without movement** and only
   within the column-0 triangle's `hitRowHeight` row; a drag past 3 pt starts a selection.
3. **Unfolded containers show a triangle** (D15): `▾` at column 0 on every foldable line, not only
   on folded ones, in the row's tone at 8 pt — the same column the block's placeholder triangles
   use (§2.4).
4. **The lens chip's on-state** is the filled accent chip of §2.3 (D6, snapshot §3.4). Measured
   again in all seven themes; the floor is 4.5:1 for the chip's ink on its own fill.
5. **A refused `Repeat` keeps the form.** `RequestEditor` holds the sheet open when
   `Pane.reportWatchRefused()` fires, instead of closing and losing everything the user typed
   (carried from the curl round's Task 6 as a UX-round minor).
6. **Series tone versus run facts** (D7): the series sentence takes the **series** tone (any failure
   → `.failure`), and the newest run's own facts — `200`, `100 ms` — keep **their** tone inside it.
   *Disagreement:* the PM asked for plain foreground with the dots carrying colour;
   `findings-design` §3.2 gives the mixed-tone rule. **Ruling: findings-design** — a sentence that
   says "the latest run was a 200" must not be red, and a wholly plain sentence throws away the
   one glance that tells you a series went wrong.
7. **`Run with jq` on a non-idempotent method** does not silently re-send. When the request's method
   is not `GET`/`HEAD`/`OPTIONS`, the button becomes `Run with jq…` and asks first:
   "This request is a `POST`. Running it again with `jq` sends it again." / `Send Again` ·
   `Cancel`. The decision (`RequestRun.isIdempotent(_:)`) is in Core. The pipeline text and its
   `'` → `'\''` escaping move from `Pane.presentLensField` (`:1078`) into `RequestRun`.
8. **jq missing.** If `jq` is not on `PATH`, the button is replaced by the sentence
   `Not supported here — and jq is not installed.` No offer to run something that will print
   `command not found`. (`ShellTool.isOnPath` in Core, resolved once per session by the app and
   passed in.)
9. **Grep results** (D13) keep their colour, cite the line number **of the response as shown**, and
   end with a count line: `17 matching lines`. Decided in `LensRendering`.
10. **The redirect chain prints before the final response** (D14), so `↪ 301 → …` reads in the
    order the requests happened.
11. **The Filter/Find field is anchored and closable.** It sits immediately under the command row of
    the block it filters — not floating mid-pane 700 pt from its own message — carries the block's
    command as a caption prefix (`Filter · curl https://…`), and has a `✕` at 20 × 20 pt as well as
    ⎋. Placement comes from `Pane.lensFieldFrame` reading the block's row, not the viewport centre.
12. **The timeline says when it is capped** — the `+18` leading label of §2.3 (D16).
13. **The `⋯` menu and the lens chip agree on non-JSON.** `BlockHeader.showsLens(at:)` already gates
    the chip on `bodyKind == .json`; the menu's `Pretty JSON` row is gated on the same value and
    disabled with the reason `Pretty JSON — the body is not JSON` rather than offered and inert.
    Likewise when `lensTooLarge`, the chip does not vanish silently: the strip shows a disabled
    chip labelled `Body too large` (PM §15, snapshot §3.9).

---

## 4. Wave 3 — shell integration for bash and fish, and telling the user

The PM's ruling, adopted: **every differentiator Nyx has over Ghostty is behind OSC 133 marks, and
today only zsh gets them, silently.** Without marks there are no blocks, no gutter, no spine, no
summary, no fold, no `Copy`, no `⋯` menu, no lens, no watch, no `edit_and_run_command` routing into
the workbench and no sticky prompt — and nothing on screen says so. `manualInstallCommand` and
`isAutomatic` exist in `ShellIntegration.swift` with **zero callers**, and the comment on the first
of them promises a settings window that does not exist. So this wave lands *before* Wave 1 is worth
anything to a bash or fish user.

### 4.1 Marks for bash and fish

The scripts are already in the bundle (`Resources/shell-integration/{bash,fish}/…`). What is missing
is the injection. **[spec decision]** — none of the audit files chooses a mechanism:

- **fish:** prepend a Nyx directory to `XDG_DATA_DIRS`, containing `fish/vendor_conf.d/nyx.fish`,
  which sources `nyx-integration.fish`. fish sources every `vendor_conf.d` on start, for
  interactive and non-interactive shells alike, and the user's own config is not touched. If
  `XDG_DATA_DIRS` was already set, ours is prepended and the original travels in
  `NYX_XDG_DATA_DIRS` so a nested shell can restore it — the same courtesy `ZDOTDIR` already gets.
- **bash:** launch with `--posix` and `ENV` pointing at our shim, which turns POSIX mode back off,
  sources the user's `~/.bashrc` (or the login files, per `-l`), then sources
  `nyx-integration.bash`, and finally unsets `ENV`. This is the one hook bash honours for both
  interactive-login and interactive-non-login shells; the alternative, `--rcfile`, silently
  suppresses `~/.bashrc` for login shells and is how other terminals break people's prompts.
- Both paths keep `ShellIntegration.environment`'s existing guarantee: **if anything is missing,
  return the environment unchanged**. A terminal that will not start a shell because it could not
  find its own helper file is far worse than one without prompt marks.
- `isAutomatic` becomes true for `.zsh`, `.bash`, `.fish`; `.other` stays false and keeps
  `manualInstallCommand`'s line.

### 4.2 A Shell page in Settings, and `manualInstallCommand` with a caller

New settings page **Shell**, between Behaviour and Keys. It carries, all decided in Core by a new
`ShellIntegrationStatus` value (`shell: ShellKind`, `mode:`, `isAutomatic:`, `marksSeen: Bool`):

- **`shell-integration`** — the existing `auto` / `off` pop-up.
- A status sentence, exact strings:
  - automatic and marks seen: `Prompt marks are live. Blocks, folding, Copy Output, the pinned command and watches all work here.`
  - automatic and no marks yet: `Nyx installs prompt marks into fish automatically. This window has not seen one yet — open a new tab if this is the first launch after an update.`
  - a shell with no shim: `Your shell is ksh. Nyx has no hooks for it, so blocks, folding, Copy Output, the ⋯ menu, the pinned command and watches are all off.`
  - `shell-integration = off`: `Prompt marks are off by your setting. Blocks, folding, Copy Output, the ⋯ menu, the pinned command and watches are all off.`
- **The manual line**, shown whenever `isAutomatic` is false and `manualInstallCommand` returns
  something: a caption `Paste this into your startup file, then open a new tab:`, the line itself in
  the monospaced font in a selectable field, and a `Copy` button. This is `manualInstallCommand`'s
  first caller.

### 4.3 Saying it where it bites

- **A one-time note banner** the first time a pane's shell finishes starting with no marks:
  `Nyx could not add prompt marks to ksh — blocks, folding and watches are off in this pane.`
  with a `Shell Settings…` button and a `✕`. Note kind, quiet styling (§7.4), announced (§8.1),
  and remembered per shell so it is shown once, not once per tab.
- **The "Cannot watch" alert is corrected.** Today it says *"Set `shell-integration = auto` and
  open a new tab"* — which is already the default, so a fish user follows the instruction, is
  refused identically, and has no next move (PM §2). New text:
  - message: `Cannot watch a request in this pane`
  - informative: `A watch sends its next run only when the shell is back at a prompt, and this shell does not tell Nyx where its prompts are. Nyx adds prompt marks to zsh, bash and fish by itself; this pane is running ksh.`
  - buttons: `Shell Settings…` (default) · `OK`.
  The three sentences are built in Core from `ShellIntegrationStatus` so the alert cannot drift
  from the page.

---

## 5. Wave 4 — settings and sheets

1. **Every text field commits on end-editing and on window close.** `SettingsWindowController.textField`
   sets only `action`, so a paste followed by closing the window is lost silently — which is exactly
   how the owner lost a relay token on 2026-09-07. Fix: `sendsActionOnEndEditing = true` on every
   field, `controlTextDidEndEditing` routed to `controlChanged`, and `windowWillClose` calling
   `commitEdits()` (which makes the window first responder before saving, so an in-flight edit ends).
2. **`ConfigWriter` ends the file with a newline.** `setting(_:to:in:)` joins with `"\n"` and
   returns, so an appended key can glue onto the previous line — the owner's config gained
   `remote = onremote-relay-token = …` this way. The writer appends a trailing newline; the parser
   tolerates a file without one. Both tested in Core.
3. **A disabled primary button explains itself beside itself** (the Pair case, `decisions.md`). The
   Remote page's status sentence currently sits ~300 px above the buttons it explains, with a table
   between, which is why the owner did not see it. A new Core value `RemotePageStatus` answers
   `(sentence, blocksPairing)`; the sentence is drawn in `secondaryLabelColor` **immediately beneath
   the pairing row**, and it names the remedy: `Pairing needs a relay token — set Relay token above.`
   `setAccessibilityHelp` carries the same sentence on both buttons.
   *Disagreement:* `decisions.md` offers "or keep the buttons enabled and route to the token field".
   **[spec decision]** Keep them disabled with the reason beneath: an enabled button that does not
   do what it says is a second lie on top of the first.
4. **The Keys page stops being clipped and stops looking editable.** The table's height is
   `min(intrinsic, page height − footer)` inside a scroll view, so no row is sliced with 180 pt of
   empty page below it; a caption above it reads `These come from your config file. Edit Config File… changes them.`
   A Keys *editor* is out of scope (§9).
5. **The Behaviour page gets headers and labels.** Six unlabelled checkboxes under one lone
   `Requests` header become three labelled groups — `Windows and tabs`, `Commands`, `Requests` —
   and `Watch every: 5 seconds` is re-labelled `Default for a new watch: 5 seconds` so it stops
   reading as a global poll interval (D17). `Response body: Pretty JSON` takes `ResponseLens`'
   own titles rather than a third hand-written spelling (`SettingsWindowController.swift:156`).
6. **Every sheet has a default button.** `pairing-client-idle-*` and `pairing-host-code-*` have
   none; `Pair`, `Done` and `Start` get `keyEquivalent = "\r"`, and every sheet gets a `Cancel`
   with `"\u{1b}"`.
7. **The request editor's preview snaps to whole glyph rows.** Its height becomes
   `floor(available / lineHeight) * lineHeight`, so the box can no longer be cut mid-glyph-row
   despite the comment at `RequestEditor.swift:186` claiming it is not. The Options page's
   horizontal stack gains a trailing constraint so it stops landing anywhere across ~200 pt of
   slack — the one non-deterministic picture in 422 (snapshot §3.8).
8. **The quick-action editor's value versus placeholder, and its validation sentence.** Placeholder
   text is drawn in `tertiaryLabelColor` (AppKit's default grey reads as a filled value on light
   themes), and validation stops being a beep: `QuickActionEditorModel.problem` in Core returns
   `A button needs a name and a command.` shown in a label under the fields and announced.
9. **An invalid pairing code becomes a `PairingFlow.State`.** `PairingSheet.readableErrorColor` /
   `setCodeError` / `invalidCodeMessage` (`:38`, `:219`, `:227`) are the one pairing state Core
   cannot express, so it has no picture and no announcement. New case
   `.codeRejected(message: String)` with the text `That is not one of our codes — they look like K7M-4QZ.`
   **[spec decision]** The client's `K7M-4QZ` placeholder is **deleted** and becomes a caption under
   the field (`Six characters, like K7M-4QZ`): a placeholder that reads as a filled value gets
   pressed (PM §13).
10. **The watch popover** gets one left edge at 20 pt, a `Cancel` (⎋) beside the default `Start`
    (⏎), its problem sentence in `labelColor` beside a red `exclamationmark.triangle` (D4) and
    **announced** (a11y 4.2), a labelled condition row (`Stop when:`), the invalid field marked with
    a red focus ring, and one new sentence saying what a watch does to the terminal:
    `Each run appears as a new block at the prompt; older runs fold themselves.`
11. **`commitEdits` restores focus.** `RequestEditor.commitEdits` (`:617`) drops first responder to
    nil, so VoiceOver loses its place on every button press; it restores focus to the control that
    was pressed.
12. **Copy with credentials says so.** The request editor's `Copy` puts secrets on the clipboard from
    a sheet whose whole posture is that they are masked. It gains
    `setAccessibilityHelp("Copies the command with its secrets in the clear")`, the same words as a
    tooltip, and an announcement on press: `Copied, with credentials in the clear.`
    *Disagreement:* the PM asked for the button to be split into `Copy` (redacted) and
    `Copy with Secrets…`. That changes what the workbench form does, which the PM's own do-not-touch
    list protects, and it is a product decision rather than a clarity fix. **Ruling: help text and
    announcement now; the split is listed in §9.**

---

## 6. Wave 5 — tab bar, palette, search, banners

### 6.1 Tab bar

- **A tab has a floor and the bar overflows.** `TabBarGeometry.minimumTabWidth = 120`; when the
  tabs no longer fit at the floor, the ones that do not fit move into the `≡` list rather than
  every tab shrinking to `nyx…sh`. At 12 tabs today four titles are stubs and two pairs are
  indistinguishable (snapshot §3.7).
- **Titles truncate at the tail, not the middle.** `TabTitle.truncatedInMiddle` (`:796`) eats the
  distinguishing half of `nyx — zsh` / `nyx — vim`, and puts `…` next to a full stop in
  `tail….log`. Tail truncation, and never an ellipsis adjacent to a `.`.
- **The `≡` list is an action**: `tab_list`, "All Tabs…", Window section, so the only escape hatch
  from a crowded bar has a keyboard path and a truthful label.
- **The close `✕` is revealed on hover or on the selected tab**, and its hit rect is **20 × 20 pt**
  (`TabBarGeometry.closeHitRect`; the glyph stays 14 pt). Today a permanent `✕` on twelve tabs is
  louder than Safari or Ghostty, and a 14 pt overshoot *selects* the tab (a11y 1.1).
  `TabBarGeometry.Hit` gains a hovered slot; `TabBarView.mouseMoved` (`:323`), which today sets only
  a tooltip, drives it.
- **The collapsed group chip keeps the expanded pill's polarity** (ink 9.36:1, not 3.37:1 on a
  2.43:1 fill, which reads as disabled) and signals collapse with `▸` plus the tab count.
- **One `+` on the bar.** **[spec decision]** The trailing `+` is New Tab and keeps the glyph alone.
  The leading dashed `+` becomes a labelled chip **`+ Button`** while there is room for it, and
  `New Button…` is always in the `≡` menu, so the two ~1000 px-apart identical glyphs stop existing
  (PM §1). It is also an action: `new_quick_action`, "New Button…", Shell section.
- **Quick actions yield before tabs.** Today the 140 pt chips keep full width while tabs drop to
  60 pt and the chips get their *own* overflow. `TabBarGeometry` (not `TabBarView.resolvedLeading`,
  `:153`) decides the order: chips move into the overflow chip **before** any tab goes below the
  floor. This moves live layout geometry out of the view, per `CLAUDE.md`.
- **The group band is quieter than selection**: band fill `foreground @ 0.08`, selection `@ 0.16`.
  Today the band is louder than the thing it contains.
- **The remote badge stops sharing the group pill's shape** (`:752`) and becomes an outline pill.
- **Labels stop quoting literal chords.** `TabBarLabels` takes `chord: (TerminalAction) -> String?`
  the way `PaletteSource.items` does (`CommandPalette.swift:175`), so "(⌘T)" and "(⌘⇧P)" follow a
  rebinding and the false "Close … (⌘W)" claim (⌘W is `close_pane`) is dropped.
- `TabBarGeometry.barHeight` ignores `grouping`, so `headerHeight` is always 0 and `Hit.groupHeader`
  is unreachable dead geometry (a11y 11.3) — deleted or wired, whichever the code says.
- **A close-with-process alert names the process** (PM §9): `“vim” is still running. Closing this tab will end it.`

### 6.2 Command palette

- **Selection is legible.** The band is 1.41–2.71:1 against the row in all seven themes — under the
  3:1 floor everywhere, under 1.5 in one-dark and solarized-dark — and it is the *only* cue. Fixed
  in the palette's colour derivation: `accent` at an alpha that clears **3:1 against
  `panelBackground`**, plus a **2 pt leading accent bar**.
- **Section headers** — `Actions`, `Buttons`, `Themes`, `Tabs`, `Remote`, `Requests` — since
  `PaletteSource.items` already orders by section; today the only cue that `dracula` is a theme is
  the word "Theme" right-aligned 900 px away.
- **"No results"**, because today an unknown query gives a blank rectangle:
  `No results for "zzqq"` on the first line and, on a second, the honest inventory
  `The palette searches actions, buttons, themes, tabs, remote sessions and past requests.`
- **A truthful placeholder.** `Run a command, pick a theme, switch to a tab` promises a shell-command
  source that does not exist. It becomes `Search actions, buttons, themes, tabs and past requests`.
- **Keywords**, so the user's vocabulary reaches the feature: **[spec decision]**
  `TerminalAction.keywords: [String]` in `ActionCatalog`, searched alongside `title` and
  `configName` — `json`, `pretty` → *Toggle Pretty Response*; `curl`, `http`, `request` → *New
  Request…*; `ssh`, `remote` → *Remote Sessions…*; `fold`, `collapse` → *Fold Command Output*.
- **`.selectedChildrenChanged`** posted from `CommandPaletteView.refresh()` on every ↑/↓, so the
  selection is not silent (a11y 2.1). Row role goes to `.staticText` inside the existing list
  container [verify with one VoiceOver pass].
- Disabled rows stop being selectable (carried from the remote-sessions spec's §12).

### 6.3 Search bar

- **The readout is announced.** `1 of 2` / `no results` is a value on an unfocused label today, so
  it reaches nobody (a11y 3.1). It is announced through `Announce` (§8.1) on every change, and
  mirrored into the field's `accessibilityValue`.
- **`toggle_search_scope`**, "Search All Tabs", Edit section, `canPerform` = a search is open. The
  scope toggle is the model everything else copies (state carried three ways) and it is the one
  control on the bar with no keyboard path.
- **Prev/Next are disabled at zero matches** instead of enabled and beeping.
- **The scope carries a word at width**: at ≥ 420 pt the toggle reads `All Tabs` / `This Pane`
  beside the `square.on.square` glyph, which by itself does not say "all tabs".
- The bar's ground is already `background @ 0.96`; the composite that made it look translucent was
  the snapshot compositor's missing ground (design §0), and the machinery fix lands with the wave.
  The **opacity is raised to 1.0 anyway** — iTerm2's and Warp's find bars are opaque, and this bar
  lands in the same corner as the sticky strip.

### 6.4 Banners

Split by kind, because today a missing `./deploy.sh`, a config syntax error and a note are one
amber band with one `Edit Config` button — and for the quick-action case that button is the wrong
remedy (PM §14, snapshot §3.6).

| kind | symbol | text | buttons |
|---|---|---|---|
| config error | `exclamationmark.triangle.fill` | first problem `(+N more)` | `Edit Config`, `✕` |
| note | `info.circle` | the note | `✕` |
| quick-action failure | `bolt.slash` | `"Deploy" could not run — ./deploy.sh not found` | `Edit Button…`, `✕` |
| project actions | `folder.badge.questionmark` | what changed, in `ProjectActionsGate`'s words | `Review…` (default), `Ignore` |

**Native quiet styling**: a `controlBackgroundColor` band with a 1 px bottom divider,
`secondaryLabelColor` text and a tinted symbol — not a full-bleed saturated `systemBlue` band,
which reads as a web cookie bar. **The banner pins its appearance** to the palette the way
`BlockHeaderView` and `LensFieldView` do, so `Edit Config` stops being drawn with a button ground in
dark and bare in light. The `✕` gets a 20 × 20 pt frame (a11y 8.2) and its label says the banner
self-dismisses on a clean reload. The project bar's `Review…` is the default button — it is the
security surface, and giving Review and Ignore identical weight is a decision the app should not
be making for the user.

### 6.5 Two shared fixes that land here

- **`DrawnControlElement.showMenu`** (a11y 1.5): `Accessibility.swift:37-41` implements press only,
  so the tab, group, quick-action and overflow menus are unreachable by VO-⇧-M. An optional
  `showMenu` closure and `accessibilityPerformShowMenu()`.
- **Menu items show their chords.** Every item in the block menu has an empty `keyEquivalent`
  (`BlockHeaderView.swift:323-324`, `Pane.swift:2977-2978`) although the lower half of the same
  menu sets them (`:3013-3018`). A `BlockAction → TerminalAction?` mapping **in Core** gives each
  item its bound chord, which is also what makes ⌘⇧A's menu teach the chords it duplicates.

---

## 7. Wave 6 — remote strip and pairing

1. **The strip's button becomes visible.** `RemoteStripView.update` never pins `appearance` and sets
   `contentTintColor`, which does not colour a *titled* button — the exact trap `BlockHeaderView`'s
   own comment documents, and the reason eight of eleven strip states measure **1.73–1.82 : 1**
   when theme and appearance disagree (snapshot §3.1). Two lines:
   `appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)` and an `attributedTitle`.
2. **Leaf or container, not both.** `RemoteStripView` sets an accessibility role that makes it a
   leaf while also vending children (`:173` vs `:175-177`); `WorkbenchHintView` (`:160-162`) answers
   the opposite question correctly. Drop the override [verify].
3. **The host's `.idle`/`.opening` shows progress.** "Getting a code from the relay" with no
   indicator; an `NSProgressIndicator` (spinning, small) beside the sentence, and the sentence text
   comes from `PairingFlow.sheetText` so no state renders blank.
4. **The Remote page says what a remote session is and where a relay comes from.** Two sentences
   above the controls, decided in Core beside `RemotePageStatus` so the snapshot cannot drift:
   `A remote session is a Nyx tab on another of your Macs, reached through a relay both machines dial out to. Nyx never sends terminal text the relay can read.`
   and `The relay URL and token come from the nyx-server you run; Nyx cannot issue them.`
   Recent activity stops being a raw ISO-8601 dump and uses a relative date.

---

## 8. Cross-cutting

### 8.1 `Announce`

Nothing in Nyx ever posts an accessibility notification — a command finishing, the palette's
selection, the search readout, both banners and the watch popover's refusal are all silent
(a11y 0.2). One helper in `NyxApp`:

```swift
enum Announce { static func say(_ text: String) }   // .announcementRequested on NSApp
```

**Wording stays in Core** — `ConfigDiagnostic`, `SearchSession.readout`, `BlockHeader.summary`,
`WatchPlanEditorModel.problem`, `ProjectActionsGate`, `ShellIntegrationStatus`,
`QuickActionEditorModel.problem` — so an announcement and the thing on screen cannot say different
words. Sites: command finished, palette selection (`.selectedChildrenChanged` from
`CommandPaletteView.refresh()`), search readout, config banner shown, project bar shown, watch
refusal, quick-action validation, copy-with-credentials, pairing rejection. Plus `.layoutChanged`
from `TabBarView.setTabs` and `PromptGutterView.update`.

### 8.2 New `TerminalAction`s

Every mouse-reachable action must have a keyboard path (`decisions.md` §3), and for anything drawn
inside a pane or on the tab bar a `TerminalAction` is the **only** possible fix: `Pane.keyDown`
sends a bare ⇥ to the PTY and `PaneTreeView`/`TabBarView` decline first responder, so there is no
key-view loop over pane chrome and there cannot be one (a11y 0.1).

| Action (`configName`) | Section | Title | Default chord | `canPerform` | Retires |
|---|---|---|---|---|---|
| `block_actions` | Go | `Command Actions…` | ⌘⇧A | the block cursor resolves to a block | the whole ⋯ menu (26 items), Copy, Stop, the lens chip, the dots |
| `tab_actions` | Window | `Tab Actions…` | — | always | tab / group / quick-action context menus |
| `tab_list` | Window | `All Tabs…` | — | more than one tab | the `≡` button |
| `new_quick_action` | Shell | `New Button…` | — | always | the `+ Button` chip, the overflow chip's home |
| `toggle_search_scope` | Edit | `Search All Tabs` | — | a search is open | the scope toggle |
| `scroll_to_sticky_prompt` | Go | `Go to the Pinned Command` | — | a sticky prompt is showing | the sticky strip's click |
| `review_project_actions` | Shell | `Review This Folder's Actions…` | — | `ProjectActionsGate.needsApproval` | the project bar's `Review…` |
| `dismiss_banner` | Nyx | `Dismiss the Notice` | — | a banner is up | the banner `✕` |

⌘⏎ activates `Run with jq` while the lens field has focus; that is a field key equivalent, not an
action. Every row goes into `ActionCatalog`, the menu bar, `docs/configuration.md` and the palette;
`canPerform` is the same answer the menu bar and the palette's `enabled` closure already share.

Legitimately pointer-only after this round, and deliberately so: a lens selection drag, the palette
scroller, click-outside-to-close, and the `⌘E Workbench` pill (⌘E does the same thing).

### 8.3 The pane's accessibility role — [verify]

`Pane` declares `.textArea` **and** vends `accessibilityChildren` (`:433`, `:437`, `:459`). If
VoiceOver treats a text area as a leaf, every in-pane element — gutter marks, fold placeholders,
the strip — is unreachable and `Pane.accessibilityChildren`'s careful work is invisible. **One
VoiceOver pass decides:**

- **If children are reachable today:** change nothing; add a comment recording the pass and its
  date beside `:433`.
- **If they are not:** the pane becomes `.group`, and its **first child** is a `.textArea` carrying
  the transcript value, with the chrome elements as siblings after it. That keeps ⌘C, selection and
  the VoiceOver text-navigation commands working on the transcript while making the chrome exist.

The same pass answers a11y 2.2 (palette row role) and 9.1 (remote strip leaf-or-container).

### 8.4 Row-height targets at `line-height 0.8`

Every hit target that is one text row tall is 13 pt at `line-height = 0.8` — the gutter mark, the
in-grid summary, fold placeholders, lens container rows, the sticky strip. All of them go through
`CommandBlockChrome.hitRowHeight(cellHeight:) = max(cellHeight, 16)`, clamped in Core and tested
there, so the floor cannot be lost to a config value.

### 8.5 `UISnapshot` cases each wave must add

The compositor gains three capabilities before Wave 1's pictures can be trusted (in flight now, per
`decisions.md`): the **ground bug** (`GridSnapshot.draw` composites with `cacheDisplay`, so
layer-painted grounds are lost — composite through `layer.render(in:)` or have each chrome view
paint its ground in `draw(_:)`), **hovered and pressed states**, and **menus and alerts**.

| wave | cases |
|---|---|
| 1 | `composite-strip-{w3,w2,w1,w0}-{finished,failed,running,folded,http,lensed,watch-running,watch-finished,no-output}-<palette>-<appearance>`; `gutter-cap-{succeeded,failed,running,no-output}-{idle,hovered,folded}-…`; `composite-sticky-…` retaken; every strip pill `hovered:` and `pressed:`; `block-menu-{plain,http,watched}` (26 rows) |
| 2 | `lens-container-{folded,unfolded}`; `lens-chip-{off,on}` in all seven themes; `lens-field-anchored`; `lens-field-jq-{missing,non-idempotent}`; `watch-timeline-capped`; `grep-count` |
| 3 | `settings-shell-{automatic,manual,off}-{light,dark}`; `banner-no-marks`; `alert-cannot-watch` |
| 4 | `settings-{keys,behaviour,remote}-…` retaken; `sheet-quick-action-{send,run}`; `pairing-code-rejected-{light,dark}`; `watch-plan-editor-{valid,invalid}` retaken; `request-editor-options-*` (now deterministic) |
| 5 | `tabbar-{12,20}-tabs` retaken; `tabbar-hover-close`; `tabbar-group-collapsed`; `palette-{sections,no-results,selection}` in all seven themes; `search-bar-{scope-word,zero-matches}`; `banner-{config,note,quick-action,project}-{light,dark}` |
| 6 | `remote-strip-*` retaken (the eight button states must become byte-identical across appearances); `pairing-host-{idle,opening}`; `settings-remote-explained` |

`settings-remote-*` is rendered from the real `~/.config/nyx` and is therefore not reproducible
across machines; it moves to a fixture `HOME` in Wave 4 (design §2.6).

### 8.6 Note, not a wave: `make app` is not universal

The owner could not install Nyx on an Intel Mac: `make app` builds for the host architecture only,
so a copied bundle is refused on x86_64. `make release`/`make app` should build
`--arch arm64 --arch x86_64` and the result be checked with `lipo -info`. The code has no
architecture-specific paths. Cheap, not UX, and not part of any wave here — recorded so it is not
lost.

---

## 9. Deliberately left out

- **Tab drag-reorder.** Every competitor including Ghostty has it, and Nyx's only route to
  reordering a tab is to put it in a group (PM §9). It is left out of this round because it is a
  new interaction model rather than a clarity fix: drop targets, group boundaries, the overflow
  list, autoscroll at the edges and what happens when a drag crosses a collapsed group are all
  product decisions, and it touches `TabController`'s ordering and group membership rather than
  drawn chrome. **Scheduled as its own task immediately after this round**, with its own spec.
- **Full focus-ring navigation of chrome** (`decisions.md` §3). There is no key-view loop over a
  pane and there cannot be one while ⇥ belongs to the shell; `TerminalAction`s are the answer, and
  §8.2 gives one to everything that lacked a path.
- **A Keys editor.** The Keys page will say honestly that it reads the config file (§5.4). Recording
  a chord, showing user overrides and filtering ~60 rows is a feature, not clarity — and Ghostty
  ships no Keys UI at all and is more honest for it.
- **Theme palette changes.** Only the readability floors (4.5:1 text, 3:1 for a shape that is the
  only cue) and the derivation of the palette-selection band; no hue in any of the seven built-in
  themes moves.
- **The `/` filter key.** Struck from the curl-workbench spec by the PM: a bare key that means one
  thing under the pointer and another everywhere else is a trap.
- **Splitting the request editor's `Copy` into redacted and `Copy with Secrets…`** (§5.12). It
  changes what the workbench form does, which is on the do-not-touch list; help text and an
  announcement land now, the split is a product decision for the next round.
- **First-run onboarding.** The PM is right that the first launch teaches nothing, but a tour is a
  new product feature, out of scope by `decisions.md` §5. What this round does instead: the tab bar
  is always there (already committed), the palette's placeholder and empty state tell the truth
  (§6.2), the quick-action `+` carries a word (§6.1), and Wave 3 tells a bash or fish user why half
  the app is missing.

---

## 10. Testing

The ladder is `docs/testing.md`; **nothing in a wave counts as done until it has been looked at as
a picture and, where it has an AppKit edge, driven in the built app.** Per wave:

**Wave 1 — block chrome.** Core: `CommandBlockChrome.widthClass` at the four boundaries (33/34,
17/18, 7/8); `stripPlan` for every row of §2.6's table, asserting the drop order and that `Stop`
and the status are never dropped; `firstColumn` never inside a word, including with a trailing wide
cell (D19); `GutterCap` for the four states × hovered × folded; `hitRowHeight` at `line-height 0.8`;
`BlockCursor.moved`/`afterViewportMove`; `StickyPromptLabel` for a finished command;
`BlockAction → TerminalAction?`. App: the §8.5 Wave-1 snapshots, read at 1:1 and at 3× for the
pills. Rung 6: a temporary `NYX_SMOKE_QA=blockchrome` hook that, in the built app, hovers each width
class through `Pane.hitTest`, presses each pill, presses the gutter cap at nine points, and prints
which action fired — the same shape as the G1 probe that found the 16 pt frame; removed before the
commit.

**Wave 2 — lenses and watch.** Core: `LensChoices.previous` restored on clear; `LensRendering` grep
colours, line numbers and count; the redirect-chain order; `WatchSeries.headerTexts` series-tone vs
run-facts; `RequestRun.isIdempotent`; the `| jq` pipeline text and its escaping. App: the Wave-2
snapshots; rung 6 extends the curl-workbench smoke hook — filter, clear, container drag, `Run with
jq` on a POST, a `jq`-less `PATH`.

**Wave 3 — shell integration.** Core: `ShellIntegration.environment` for bash and fish, with and
without an existing `XDG_DATA_DIRS`, with missing resources (must return the base environment
unchanged), `isAutomatic`, `manualInstallCommand`, and `ShellIntegrationStatus`' four sentences.
Rung 6 is the real gate here: **launch the built app with `SHELL=/bin/bash` and with
`SHELL=/opt/homebrew/bin/fish`, run a command in each, and confirm a gutter mark, a fold and a
`Copy` — a passing unit test proves nothing about a shell that will not start.** Then the same with
`shell-integration = off` and with `SHELL=/bin/ksh`, confirming the banner and the corrected alert.

**Wave 4 — settings and sheets.** Core: `ConfigWriter` trailing newline and a parser tolerating a
file without one; `RemotePageStatus`; `QuickActionEditorModel.problem`;
`PairingFlow.State.codeRejected`; `WatchPlanEditorModel` problem wording. App: the Wave-4 snapshots,
including five consecutive runs of `request-editor-options-light` proving it byte-identical.
Rung 6: paste a token into Settings → Remote, close the window without pressing Return, reopen, and
read the value back — the owner's exact 2026-09-07 report.

**Wave 5 — tab bar, palette, search, banners.** Core: `TabBarGeometry` at the 120 pt floor with
2/8/12/20 tabs and with and without quick actions, asserting chips overflow before tabs;
`closeHitRect`; tail truncation and the no-`…`-beside-`.` rule; `TabBarLabels` with an injected
`chord:`; palette section ordering, `keywords`, the no-results text and the selection contrast
against all seven `panelBackground`s; `SearchSession` prev/next gating. App: the Wave-5 snapshots.
Rung 6: `Announce` verified with VoiceOver on for the palette, the search readout and both banners.

**Wave 6 — remote.** App: the eight remote-strip button states must come out **byte-identical across
appearances**, the guard the whole `<palette>-<appearance>` naming scheme exists to enforce. Core:
`PairingFlow.sheetText` renders no state blank; `RemotePageStatus` sentences.

**Every wave, every time.** `swift build` with **zero warnings**; `pkill -9 -f swiftpm-testing-helper;
swift test --no-parallel`; **`make bench` ≥ 180 MB/s** (nothing in this round touches the render
path, so a drop is a bug); `NYX_UI_SNAPSHOT=… ./build/Nyx.app/Contents/MacOS/Nyx` and read the
PNGs, using the `<palette>-<appearance>` rule and `cmp` to cut the set to the distinct pictures.

**Gates.** Each wave is reviewed by the `design-reviewer` over its pictures, by a VoiceOver pass
for anything in §8.2 or §8.3, and by the `product-manager` last — a wave is not done until he says
so (`docs/workflow.md`, `CLAUDE.md`).
