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
other — is "некрасиво и неочевидно как работает": four presentations of one command (an AppKit
gutter capsule, a Metal spine, an in-grid summary with a chevron, an AppKit hover strip) that
encode the same fact twice 1.5 pt apart, offer six routes to fold in three glyphs at three x
positions, label nothing below `Copy`, drop the status code before dropping a second menu, and
*remove* information when the pointer arrives. This round does not patch those findings one by one;
it makes the block one system with one Core decision table, then walks the rest of the chrome —
lenses, shell integration, settings, tab bar, palette, search, banners, remote — until each surface
explains itself without a manual.

**The bar.** Warp for block interactions: labelled hover verbs, whole-row targets, the metadata
bound to the block rather than stranded at the far margin. Ghostty for restraint: nothing costs a
terminal column or a scrap of attention while the pointer is elsewhere. Where they conflict,
**restraint wins at idle and clarity wins on hover** (`decisions.md` §2). Nyx's own advantage is
stated once and built once: *the gutter mark is the fold control, it costs no columns at idle, and
it grows a label on hover* — iTerm2's mark column with Warp's verbs and Ghostty's silence.

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
each landing on its own commits. Order (owner's ruling of 2026-09-10 — the lens and watch polish
goes last, after every design and UX fix): block chrome → shell integration → settings and sheets →
tab bar, palette, search, banners → remote strip and pairing → lenses and watch.

**Eight plans, not six.** Waves 1 and 5 are each too large for one plan of ≤ 10 tasks, so each
splits at a seam that leaves both halves shippable: **1a** the mark and the strip (the block drawn
as one system) and **1b** the keyboard on a block (one "which block" rule, one chord); **5a** the
tab bar and **5b** palette, search and banners. Waves 2, 3, 4 and 6 each fit one plan; the task
groupings that keep them under ten are named in their headings.

---

## 2. Wave 1 — block chrome as one system

**Plan 1a (§2.1–§2.7), eight tasks:** the `CommandBlockChrome` decision table; the gutter mark as
the head of the spine; the strip's geometry and pills; the lens chip; the fold column and the
summary losing its chevron; the sticky strip; `hitRowHeight` everywhere (§8.4); the pictures and
the rung-6 hook. Every pointer route is correct without any of 1b.
**Plan 1b (§2.8), six tasks:** `BlockCursor`; re-targeting and re-titling the eight block-scoped
actions; `block_actions` ⌘⇧A and `view.menu`; the `BlockAction → TerminalAction?` chords in the
menu (moved here from §6.5, because ⌘⇧A's menu is what has to teach them);
`scroll_to_sticky_prompt`; the finish announcement (§8.1). It touches no pixel 1a draws, and 1a is
what makes its target visible.

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
        public let readout: String            // the summary sentence, abbreviated per §2.6, never re-worded
        public let readoutTone: SummaryTone
        public let dots: [WatchSeries.Dot]    // empty when dropped
        public let overflowDot: String?       // "+N" when the 12-dot cap bites
        public let pills: [Pill]              // leading → trailing, already dropped to fit
        public let firstColumn: Int           // never inside a word
        public let overlapsCommand: Bool      // the strip's last rung, at any width — see §2.3
    }
    public enum Pill: Equatable {
        case fold(FoldLabel)                  // .fold ("Fold") / .unfold ("Unfold") — always a word;
                                              // the bare `▾` pill is deleted (§2.4)
        case copy
        case lens(name: String, on: Bool)     // ResponseLens.chipTitle: Raw/Pretty/Headers/Body/Filter/Find/Diff
        case stop
        case actions(Actions)                 // .labelled ("Actions ▾") / .glyph ("⋯")
    }
    /// `nil` when no strip is placed on that row: W0, or a plan that does not fit the free
    /// columns. The gutter still folds, and the in-grid summary is *not* suppressed (§2.5).
    public static func stripPlan(_ header: BlockHeader, freeColumns: Int) -> StripPlan?
    public static func gutterCap(_ header: BlockHeader, hovered: Bool, folded: Bool) -> GutterCap
    /// The mark and the spine are one shape: 3 pt wide, `spineLeadingInset` from the pane's left
    /// edge. The renderer reads the same two numbers, so the Metal spine and the AppKit cap cannot
    /// drift apart.
    public static let spineWidth: CGFloat = 3
    public static func spineLeadingInset(padding: CGFloat) -> CGFloat  // min(4, max(0, padding - 3))
    /// Every row-height *hit* target, clamped so `line-height = 0.8` cannot make it 13 pt. The
    /// *drawn* mark stays `cellHeight` tall (§2.2).
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
- **Drawn mark 3 pt wide × `cellHeight` tall**, in the block's tone, and it is the **head of the
  spine** — same 3 pt, same colour, continuous down the block's rows. The separate 1 pt Metal
  spine and the 4.5 pt capsule stop existing as two marks: one shape, one fact, no more "a green
  line with beads on it" at x ≈ 1 pt (PM §1, design §2.7 MUST).
  *Disagreement:* `findings-design` §3.2 gives the drawn mark `max(cellHeight, 16)`.
  **Ruling: drawn = `cellHeight`, hit = `hitRowHeight` (§8.4).** A 16 pt mark on a 13 pt row at
  `line-height 0.8` makes the spine lumpy and collides two blocks' marks; the height that must be
  clamped is the one the mouse sees. The clamped rect may overhang the rows above and below —
  usually output rows, which have no mark — and where two marks' rects do overlap (two prompts with
  nothing between them) the point goes to the **nearer centre**, decided in Core.
- **The mark moves off the window edge**: its leading inset is `spineLeadingInset(padding:)` =
  `min(4, max(0, padding - 3))` — 4 pt at the shipping `padding = 8`, so it is no longer inside the
  window's resize margin, and 0 pt at `padding = 0`, where it may draw over the first text column
  rather than off the window.
- **Shape carries state**, not colour alone (a11y 6.2): succeeded = solid cap; failed = solid cap
  **plus a full-row bar**; running = hollow cap; no output = cap at 40 % alpha and **not pressable**.

  **Amended 2026-09-10 (final review, I1) — the shipped shapes, all four in one 3 pt column.**
  Success is a filled column inset 2 pt from the row's top, so it reads as one command's mark.
  **Failure drops the inset**: its column runs the whole row and joins the marks above and below it,
  which is where "plus a full-row bar" lands once the spine is drawn for every block rather than for
  failures alone — the extra ink is the two points a success gives up, and it is the one shape
  difference that survives being read at 3 pt. Running is success's rect *stroked*; no output is
  success's rect at `Palette.fadedMark`. The 40 % is **nominal**: 40 % of a green over a near-white
  ground measured 1.78:1, so `fadedMark` raises it per theme until it clears **3:1 against the harder
  of the plain background and the hover tint** (the tint became the harder one when D6 moved it under
  the gutter), capped at the solid mark's own colour. **All seven** built-ins end above 40 %: the
  nominal step reads in none of them (the success mark at 40 % measures 1.61:1 to 2.61:1 against the
  harder ground), so 40 % is the direction and 3:1 is the rule.
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
| pill text | `NSFont.systemFont(ofSize: 11, weight: .medium)` — the same font measures the width, so Core is given the measured width and never guesses (`BlockHeaderView.width(for:header:font:)` keeps its measuring cache) |
| pill glyphs | `⋯` and `▾` drawn as paths 8 pt wide inside the 24 pt pill, not as text — the 5 pt glyph in a 20 pt pill is why design §2.7 measured the chevron "weak because of size" |
| gap between pills | 6 pt |
| trailing inset | 8 pt |
| pill fill | `palette.foreground @ 0.14` |
| pill hairline | `Palette.pillHairline(on:minimum:)`: `foreground @ 0.30` over the fill's own ground, pushed further toward `foreground` until it clears **1.6:1 idle** and **3:1 hovered or pressed** (D4 moved hover onto the hairline; a flat `@ 0.22` cleared 1.6 in no theme's pressed state). Stroked inside the pill's box, not on it |
| leading edge | 8 pt of solid strip ground, then a 2-cell gradient to transparent |
| strip ground | the row's own hover tint, not `palette.background` — a `background` band on a tinted row reads as a floating rectangle |
| dots | filled, 7 pt, on a 10 pt pitch; the running run is a **filled accent** dot, not a hollow amber ring (which shares a hue with redirect and reads as a smudge at 6 pt) |
| dot cap | **12 dots** (amended 2026-09-10, below); past it the leading dot is replaced by the label `+N` (`+36` at 48 runs), in the readout's font at the dots' own tone — the cap stops being silent (D16) |

**Amended 2026-09-10, after the plan-1a design review: the dot cap is 12, not 30.** Thirty dots on
a 10 pt pitch is 300 pt — 41 % of a 730 pt window, thirty-four columns — for information nobody
reads dot-by-dot, and the extra dots carry none even when drawn, because amber and red are not
separable by eye at 8 pt. §2.6's amendment had just made the dots outlive `Copy`, which only pays
off if they are cheap enough for the rest of the ladder to survive them. Twelve is a minute of a
five-second watch, still shows the shape of a flapping endpoint, and stops the strip growing without
bound: measured, the W3 watch cell goes from 92 to 70 columns at 30 runs and from 94 to 71 at 48. It
does **not** narrow an eleven-run series' cell — that one was already under the old cap and is 67
columns either way, of which the sentence is thirty-three — so W3's threshold stays where it is, and
the full series belongs to the ⋯ menu or the watch panel rather than to a 20 pt strip.

**The strip is right-aligned into the free columns *after the command's last glyph* and never
begins inside a word.** `StripPlan.firstColumn` is a column index, computed in Core from the
command row's last used cell; if the plan does not fit, there is no strip on that row and the
gutter still folds. This kills `…'{"service":"we8.8s ⋯ ▾` (snapshot report §3.5) without the
two-cell fade pretending to be a gap. **The exception is the strip's last rung** (`StripPlan.overlapsCommand`): where nothing fits beside
the command, the narrowest rung is drawn *over the command's tail* on an **opaque** ground with no
gradient, which reads as a control on top of text rather than as text colliding with text. It
carries the two pills §2.6 never drops — `Stop` while a watch is running, and `Actions` collapsed to
`⋯` — and the narrowest readout when the in-grid summary is not already showing the sentence on that
row.

**Amended 2026-09-10 (PM P1, design D2).** The exception was the lone `Stop` of §2.6's W0 row and
nothing else. Measured from the pictures, that left a *hovered* block with no controls at all
wherever the leftover gap after the in-grid summary was smaller than a lone `⋯` at 40 pt — a failed
block at 14–18 free columns of 84, one in sixteen of them, and every HTTP block at 29–33. A lone `⋯`
is the route to every action on the block, including the lens rows, and earns the same exception;
the lens chip does not, because it *says* something rather than doing it, and thirteen columns of
somebody's command line is not a price for a readout. A W0 row is unchanged: there the only pill
that may cost a column is `Stop`.

**Labels and help, exact.** `Copy` — help `Copy this command's output` (a11y 6.7). `Stop` — label
and help `Stop watching this request` (a11y 6.9; the pill's scope and ⌘.'s scope stop diverging in
§2.8, where both target the block cursor). `Fold`/`Unfold` — help `Fold this command's output`.
`Actions ▾` and `⋯` — label `Command actions`, and both open the menu `block_actions` opens.

Every tinted control resolves through `SummaryTone.color(in:)` / `RGB.readable(_:on:towards:)`, so
gruvbox-dark's lit `{ }` at 2.82:1 (snapshot §3.4) cannot recur.

**The lens control is a chip carrying the lens name**, not `{ }`: `Raw`, `Pretty`, `Headers`,
`Body`, `Filter`, `Find`, `Diff`, with a trailing `▾` when the menu offers others. Off = the same
pill fill as its neighbours. On = **filled `palette.accent` with `palette.textOn(accent)` ink** —
the pattern `SearchBarView.updateScopeTint` (`:181-186`) and `tabbar-toggle-running` already use.
`ResponseLens` gains `chipTitle: String` — those seven strings exactly — so the name is decided in
Core; `ResponseLens.title` keeps the longer menu wording it already has (`Pretty JSON`,
`Find in Body…`, `Diff with Previous Run`), and `chipTitle` is its short head, never a third
spelling.

### 2.4 One control folds

**Amended 2026-09-10, after the plan-1a design review: a *lens* fold triangle sits at its own
indent, not at column 0.** A disclosure triangle for tree-structured content belongs to the row it
folds — Chrome DevTools, Xcode's variable view and every JSON viewer put it there — and column 0
for a deeply nested key strands the control ten columns from the thing it controls. Column 0 is the
right rule for a *block-level* fold, where the row stands for the whole of a command's output and
has no indent of its own; it is the wrong rule for a nested one. So: a fold placeholder's triangle
is at column 0, a lens container's is at its indent (`LensBuffer.foldMarkerColumn`), and both keep
the same 20 pt × `hitRowHeight` target. The one genuine inconsistency inside the deviation — a
folded value on a key line takes its triangle *after* the key while a standalone container takes it
*leading* the line — is left to plan 2, which owns the lenses; leading for both is the answer.

**Fold triangles share one column.** Every `▸`/`▾` that means "fold" — a fold placeholder row, a
lens container line, and nothing else — is drawn at **column 0 of the text area** (a lens
container's at its own indent, per the amendment above), in the row's
tone, as a glyph in the pane's own font at the pane's own cell size (these are Metal glyphs in the
grid: "8 pt" applies only to the AppKit gutter cap's chevron in §2.2, which is a drawn path).
Their hit box is column 0's cell, widened to **20 pt** and `hitRowHeight` tall — the same 20 pt the
gutter uses, for the same reason. The in-grid command-row summary keeps its right alignment and
**loses its chevron**;
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
the strip says at least as much. Precisely: the in-grid summary is suppressed **only on a row where
`stripPlan` actually returned a plan**. At W0, and on any row where the plan did not fit, the strip
is absent and the summary stays — so hovering can never take a fact off the screen.

### 2.6 The decision table

Width class = free columns after the command's last glyph. **W3 ≥ 34, W2 18–33, W1 8–17, W0 < 8.**

| State | W3 | W2 | W1 | W0 |
|---|---|---|---|---|
| idle (any) | gutter cap + spine; summary at the row end, no chevron | same | same | same — nothing costs a column at idle |
| hovered, finished | `‹summary› [Fold] [Copy] [Actions ▾]` | `‹summary› [Copy] [Actions ▾]` | `‹summary› [⋯]` | no strip; cap → `▾` |
| hovered, failed | `exit 1 · 8.8s [Fold] [Copy] [Actions ▾]` (`.failure` tone) | `exit 1 · 8.8s [Copy] [Actions ▾]` | `exit 1 [⋯]` | cap → `▾` |
| hovered, running | `12s [Fold] [Copy] [Actions ▾]` | `12s [Copy] [Actions ▾]` | `12s [⋯]` | cap → `▾` |
| folded | `‹summary› [Unfold] [Copy] [Actions ▾]` | `‹summary› [Unfold] [Actions ▾]` | `‹summary› [⋯]` | cap → `▸` |
| hovered, HTTP | `200 · 142 ms · 1.2 KB · json [Pretty ▾] [Fold] [Copy] [Actions ▾]` | `200 · 142 ms [Pretty ▾] [Actions ▾]` | `200 [Pretty ▾] [⋯]` | cap → `▾` |
| lensed | as HTTP, the lens chip filled accent | as HTTP | as HTTP | cap → `▾` |
| watched, running | `●●●○ run 12 · 200 · 100 ms · every 5 s [Stop] [Actions ▾]` | `run 12 · 200 [Stop] [Actions ▾]` | `run 12 [Stop] [⋯]` | `[Stop]` alone over the tail |
| watched, finished | `●●●● 11 runs · p50 140 · p95 190 · 2 failures [Actions ▾]` | `11 runs · 2 failures [Actions ▾]` | `11 runs [⋯]` | — |
| no output | `‹summary› [Actions ▾]` | same | `[⋯]` | — |

**Reading the table.** `‹summary›` is `BlockHeader.summary`, unchanged in wording. A `—` in the W0
column means what the finished row's cell says: **no strip, the gutter cap alone** (`▾` unfolded,
`▸` folded). A command that printed nothing still has a cap — faded and not pressable, because the
cap is the block's identity and a block that ran is a fact (F3); what it has no chevron for is the
folding it cannot do. `[Stop]` over the tail is the one exception — the
`overlapsCommand` case of §2.3.

**Two ladders, not one.** `findings-design` §3.3 states a single right-to-left drop order that its
own table contradicts (the table drops `Fold` before `Copy`, and keeps `Unfold` past `Copy`).
**Ruling: the table is what ships**, reproduced by two ladders, both in Core, both asserted cell by
cell against it.

*Pills, kept longest first:* `Stop` → `Actions` (which collapses from `Actions ▾` to `⋯` before any
pill is dropped) → the lens chip when HTTP, or `Unfold` when folded → the dots → `Copy` → `Fold`.
`Stop` and `Actions` are present at every width. A block that is both watched and HTTP takes
`Stop`, never the lens chip: the two never share the strip, and the lens stays in the menu (§3.13).

**Amended 2026-09-10, after the plan-1a picture set (task 8, F4).** Two rungs moved, and the two
rows above with them. The **lens chip now outlives `Fold` and `Copy`** — it is the lens's only
visible state, and `Copy Output` is a row of the ⋯ menu — because a pasted `curl` is long, the strip
a person actually gets is a rung or two below W3, and the chip was the first thing dropped: it
appeared in *no* composite of the whole set. The **dots now outlive `Copy`** for the same kind of
reason — a timeline is the series' whole shape and there is a second route to the pasteboard, so a
watched block carries no `Copy` at any width. Measured, §2.6's W3 cells need far more than the
band's 34 free columns: 58 for the HTTP row and **67 of an 84-column pane** for the watch rows —
thirty-three of them the sentence, thirteen the eleven dots and the rest `[Stop] [Actions ▾]`, all
measured through the view's own `width(of:font:)`. (`GridSnapshot.pictureFreeColumns` leaves the
watch pictures **76**, which is the cell's 67 plus slack: the fixture is choosing a command length,
and a length that lands the row exactly on the cell's own width has nothing left over if a pill's
label ever measures a point wider. The cell is 67; 76 is the picture's margin.)

*Readout, longest first:* the full sentence → drop the interval (`every 5 s`) and the percentiles →
drop the timing and size (`142 ms`, `1.2 KB`, `json`) → drop the run count → **the status or exit
code alone, never dropped while a strip is drawn at all.** The inverse of today, where a
recoverable `Copy` outlived the unrecoverable status and two grey circles outlived it too.

`OverlayControls`' three levels (`.full`/`.noCopy`/`.minimal`) are replaced by `WidthClass` and the
two ladders, and **the enum is deleted in the same task that moves its last caller** — it does not
survive this wave under any condition.

### 2.7 The sticky strip

The single worst defect in the picture set (snapshot §3.2, PM's #1): `foreground @ 0.10` over live
text with **nothing blanking the row underneath**, so a pinned command and the output beneath it
print on top of each other in every scrolled composite. Four changes, all small:

1. `Pane.render` **blanks the covered row** — `Pane.stickyPromptRow` already computes it
   (`:105`, written `:2221`) and is read only by the click handler (`:3642`).
2. The band's ground becomes **opaque** `palette.background`, with the strip's own appearance pin.
3. A **1 px bottom divider** at `palette.foreground @ 0.20`.
4. A **leading `↑` glyph** drawn as a path 8 pt wide in `palette.foreground @ 0.55`, so the band
   says it is a control at all — today it has no bezel, no chevron, no pin and no divider, and the
   whole thing is a click target (design §2.8). Its own height goes through
   `hitRowHeight(cellHeight:)` (§8.4), so the band is never 13 pt tall.

And the label stops lying: `StickyPromptLabel` says "Running command" for a finished one
(a11y 7.1). It takes `BlockHeader.summary` and `SummaryTone` instead, so the pinned line reads
`swift build … · exit 1 · 8.8s` in the failure tone. Its VoiceOver label is
`Pinned command: <summary>. Scrolls back to it.`

The click keeps working and gains a keyboard path: **`scroll_to_sticky_prompt`** (§8.2), which
lands with plan 1b.

### 2.8 Keyboard: `BlockCursor` and one route

Eight block-scoped actions currently use **five different rules** for "which block": `commandToFold()`,
`lastFinishedCommand`, pointer-or-hovered-or-last, and newest-run-is-last
(a11y §11.1). The pointer path and the keyboard path therefore target different blocks silently
(PM §5). One value in Core replaces all five:

```swift
public struct BlockCursor: Equatable {
    public enum Direction: Equatable { case previous, next }
    public var commandID: CommandID?
    /// The viewport moved for a reason other than ⌘↑/⌘↓ (a scroll, new output, a fold). `fallback`
    /// is `commandToFold()`'s answer: the cursor keeps its block while that block is still in
    /// `visible`, otherwise takes `fallback`, and clears when `fallback` is nil.
    public static func afterViewportMove(_ current: Self, visible: [CommandID], fallback: CommandID?) -> Self
    /// Clamps at both ends rather than wrapping; from a cleared cursor `.previous` takes the last
    /// element and `.next` the first; a block trimmed out of `among` by scrollback is gone, and the
    /// move starts from the nearest surviving id in the direction of travel.
    public static func moved(_ current: Self, by: Direction, among: [CommandID]) -> Self
}
```

"The block the keyboard is on." Moved by ⌘↑/⌘↓ (which already move the viewport and now also move
the cursor), reset by `afterViewportMove` when the viewport moves for another reason, and
targeted by `fold_command`, `select_command_output`, `copy_command_output`, `copy_block_markdown`,
`save_command_output`, `edit_and_run_command`, `toggle_http_lens` and `stop_watch`.

**The cursor is visible, or it is a trap.** `BlockHover` gains a source — `.pointer` or `.cursor` —
and the cursor's block is drawn exactly as a hovered one: row tint, gutter chevron, and the strip
of §2.6 at the block's own width class. The pointer wins while it is inside the pane; the cursor's
presentation returns when the pointer leaves or the next ⌘↑/⌘↓ arrives, and it is cleared when the
cursor clears. Nothing new is drawn at idle: a pane nobody has pressed ⌘↑ in has no cursor.

**The titles stop saying "Last"** in the same commit, or the menu bar lies: `Copy Last Command
Output` → **`Copy Command Output`**, `Copy Last Command as Markdown` → **`Copy Command as
Markdown`**, `Save Last Command Output…` → **`Save Command Output…`**, `Edit Command Line…` →
**`Edit This Command…`**. The other four keep their titles and change only their target, and
`docs/configuration.md`'s scope sentences — including the documented divergence of ⌘. from the
`Stop` button — are rewritten to "the block the keyboard is on".

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
**Nine tasks:** 1+3 (fold state), 2 (drag), 4+12+14 (chip, cap label, watch vocabulary), 5, 6, 7+8
(jq), 9+10 (rendering), 11 (the field), 13.

1. **Clearing the Filter field returns to the previous lens**, not to raw. `LensChoices` keeps
   `previous: ResponseLens?` per block; clearing restores it. (PM's first item; today an empty
   field drops the reader to raw and loses the pretty view they were reading.)
2. **Drag-select works on container lines.** Today a mouse-down anywhere on a foldable lens line
   folds it, so no drag can start there. The fold acts on **mouse-up without movement** and only
   inside the column-0 triangle's hit box of §2.4 (20 pt wide × `hitRowHeight` tall); a drag past
   3 pt starts a selection, and a press anywhere else on the line starts one immediately. The fold
   **placeholder** row keeps its whole-row target — it has no content worth selecting, and it is
   the one affordance PM §4 found already legible.
3. **Unfolded containers show a triangle** (D15): `▾` at column 0 on every foldable line, not only
   on folded ones, in the row's tone, at the pane's cell size — the same column and the same glyph
   size as the block's placeholder triangles (§2.4).
4. **The lens chip's on-state** is the filled accent chip of §2.3 (D6, snapshot §3.4). Measured
   again in all seven themes; the floor is 4.5:1 for the chip's ink on its own fill.
5. **A refused `Watch ▾` (today's `Repeat ▾`, item 14) keeps the form.** `RequestEditor` holds the
   sheet open when `Pane.reportWatchRefused()` fires, instead of closing and losing everything the
   user typed (carried from the curl round's Task 6 as a UX-round minor).
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
    command as a caption prefix (`Filter · curl https://…`; the command is cut at the **tail** with
    a `…` at whatever width the field has, never in the middle), and has a `✕` at 20 × 20 pt as
    well as ⎋. Placement comes from `Pane.lensFieldFrame` reading the block's row, not the viewport
    centre. `Run with jq` gets the VoiceOver label `Run this filter through jq in the shell` and
    the ⌘⏎ key equivalent of §8.2 (a11y 6.16).
12. **The timeline says when it is capped** — the `+N` leading label of §2.3 (D16).
13. **The `⋯` menu and the lens chip agree on non-JSON.** `BlockHeader.showsLens(at:)` already gates
    the chip on `bodyKind == .json`; the menu's `Pretty JSON` row is gated on the same value and
    disabled with the reason `Pretty JSON — the body is not JSON` rather than offered and inert.
    Likewise when `lensTooLarge`, the chip does not vanish silently: the strip shows a disabled
    chip labelled `Body too large` (PM §15, snapshot §3.9).
14. **One verb for the schedule feature** (PM §7: "four names … a user who used Repeat cannot find
    it again"). The verb is **Watch**: the request editor's `Repeat ▾` → **`Watch ▾`** (presets
    `Watch every…`, `Watch 10 times`, `Watch until 200`); the block menu's `Run Every N s` →
    **`Watch Every N s`**, its `Watch…` unchanged; Settings' `Watch every:` →
    **`Default for a new watch:`** (§5.5). All from one Core value, `WatchVocabulary`, so a fifth
    spelling cannot be hand-written. A label change only; the PM asked for this one by name.

---

## 4. Wave 3 — shell integration for bash and fish, and telling the user

The PM's ruling, adopted: **every differentiator Nyx has over Ghostty is behind OSC 133 marks, and
today only zsh gets them, silently.** Without marks there are no blocks, gutter, spine, summary,
fold, `Copy`, `⋯` menu, lens, watch, `edit_and_run_command` routing or sticky prompt — and nothing
on screen says so. `manualInstallCommand` and `isAutomatic` have **zero callers**, and the comment
on the first promises a settings window that does not exist.

*Order:* `decisions.md`'s PM ruling says this is "its own wave in this round, before the
block-chrome redesign is worth anything to those users", which reads two ways. **Ruling: it stays
third in the numbering and is not pulled in front of Wave 1** — block chrome is decision 1 of the
round and the owner's own complaint, the two waves have no dependency on each other, and "worth
anything to those users" is a statement about value, not about sequence. If the owner would rather
a bash user see blocks sooner, this wave can move to the front unchanged: nothing in it reads
`CommandBlockChrome`.

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
`ShellIntegrationStatus` value — `shell: ShellKind` (the existing enum, gaining
`name: String` = "zsh"/"bash"/"fish"/the binary's own name for `.other`),
`mode: ShellIntegrationMode` (the existing `.auto`/`.off`), `isAutomatic: Bool` (from
`ShellIntegration.isAutomatic(shellPath:mode:)`), `marksSeen: Bool` (this window has seen an
OSC 133 A since it opened), and the derived `sentence: String` and `manualLine: String?`:

- **`shell-integration`** — the existing `auto` / `off` pop-up.
- A status sentence, exact strings; `<shell>` is `shell.name`, so the same value fills the page,
  the banner and the alert:
  - automatic and marks seen: `Prompt marks are live. Blocks, folding, Copy Output, the pinned command and watches all work here.`
  - automatic and no marks yet: `Nyx installs prompt marks into <shell> automatically. This window has not seen one yet — open a new tab if this is the first launch after an update.`
  - a shell with no shim: `Your shell is <shell>. Nyx has no hooks for it, so blocks, folding, Copy Output, the ⋯ menu, the pinned command and watches are all off.`
  - `shell-integration = off`: `Prompt marks are off by your setting. Blocks, folding, Copy Output, the ⋯ menu, the pinned command and watches are all off.`
- **The manual line**, shown whenever `isAutomatic` is false and `manualInstallCommand` returns
  something: a caption `Paste this into your startup file, then open a new tab:`, the line itself in
  the monospaced font in a selectable field, and a `Copy` button. This is `manualInstallCommand`'s
  first caller.

### 4.3 Saying it where it bites

- **A one-time note banner** the first time a pane's shell finishes starting with no marks:
  `Nyx could not add prompt marks to <shell> — blocks, folding and watches are off in this pane.`
  with a `Shell Settings…` button and a `✕`. Note kind, quiet styling (**§6.4**), announced
  (§8.1), and remembered **per shell path for the life of the process** — once per run of Nyx for
  a given shell, not once per tab, and not persisted to disk (a user who changes shells in a new
  session is told again, which is the case where the sentence is news).
- **The "Cannot watch" alert is corrected.** Today it says *"Set `shell-integration = auto` and
  open a new tab"* — which is already the default, so a fish user follows the instruction, is
  refused identically, and has no next move (PM §2). New text:
  - message: `Cannot watch a request in this pane`
  - informative: `A watch sends its next run only when the shell is back at a prompt, and this shell does not tell Nyx where its prompts are. Nyx adds prompt marks to zsh, bash and fish by itself; this pane is running <shell>.` — and, when `mode == .off`, the second sentence is instead `Prompt marks are off by your setting.`
  - buttons: `Shell Settings…` (default) · `OK`.
  The three sentences are built in Core from `ShellIntegrationStatus` so the alert cannot drift
  from the page.

---

## 5. Wave 4 — settings and sheets

**Nine tasks:** 1+2 (the config round trip), 3, 4, 5, 6+7 (sheets and the request editor's
layout), 8, 9, 10, 11+12+13 (focus, credentials, the Appearance sentences).

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
   the pairing row**, and it names the remedy. All four sentences, exact:
   - `remote = off`: `Remote sessions are off — tick Enable remote sessions to pair.` (blocks)
   - no relay URL: `Pairing needs a relay — set Relay above.` (blocks)
   - no relay token: `Pairing needs a relay token — set Relay token above.` (blocks)
   - ready: `Ready to pair. Both Macs must reach the same relay.` (does not block)

   `setAccessibilityHelp` carries the same sentence on both buttons.
   *Disagreement:* `decisions.md` offers "or keep the buttons enabled and route to the token field".
   **[spec decision]** Keep them disabled with the reason beneath: an enabled button that does not
   do what it says is a second lie on top of the first.
4. **The Keys page stops being clipped and stops looking editable.** The table's height is
   `min(intrinsic, page height − footer)` inside a scroll view, so no row is sliced with 180 pt of
   empty page below it; a caption above it reads `These come from your config file. Edit Config File… changes them.`
   A Keys *editor* is out of scope (§9).
5. **The Behaviour page gets headers and labels.** Six unlabelled checkboxes under one lone
   `Requests` header become **four** labelled groups (not three: the rows do not divide into three
   honest headings, and a heading that lies is the defect being fixed) — **Windows and tabs**
   (`restore-session`, `confirm-close-process`, `bell`), **Text and the mouse** (`copy-on-select`,
   `middle-click-paste`, `mouse-scroll-alt-screen`, `clipboard-read` with its footnote,
   `option-as-meta`, `multiline-paste`), **Commands** (`fold-keep-lines`, `fold-long-output`) and
   **Requests** (`http-lens`, `http-hint`, `http-watch-interval`, `http-history`).
   `Watch every: 5 seconds` is re-labelled
   `Default for a new watch: 5 seconds` so it stops reading as a global poll interval (D17, §3.14).
   `Response body: Pretty JSON` takes `ResponseLens.title` rather than a third hand-written
   spelling (`SettingsWindowController.swift:156`).
6. **Every sheet has a default button.** `pairing-client-idle-*` and `pairing-host-code-*` have
   none; `Pair`, `Done` and `Start` get `keyEquivalent = "\r"`, and every sheet gets a `Cancel`
   with `"\u{1b}"`.
7. **The request editor's preview snaps to whole glyph rows.** Its height becomes
   `floor(available / lineHeight) * lineHeight`, so the box can no longer be cut mid-glyph-row
   despite the comment at `RequestEditor.swift:186` claiming it is not. The Options page's
   horizontal stack gains a trailing constraint so it stops landing anywhere across ~200 pt of
   slack — the one non-deterministic picture in 422 (snapshot §3.8).
8. **The quick-action editor's value versus placeholder, and its validation sentence.** Placeholder
   text is drawn in `placeholderTextColor` (AppKit's default grey reads as a filled value on light
   themes), and validation stops being a beep: `QuickActionEditorModel.problem` in Core returns
   `A button needs a name and a command.` shown in a label under the fields and announced.
   **The placeholder rule is app-wide** and lands here at once: the lens field's `.users[0].name`,
   Remote's `Device name` and token field, the quick-action editor's `Caffeine` / `caffeinate -d`
   (design §2.5, §2.6, snapshot §3.9); the pairing sheet's is deleted outright by item 9.
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
13. **The Appearance page says how its three theme pop-ups interact** (PM §12). One caption under
    them, decided in Core beside `ThemeCatalog`:
    `Theme is used unless Dark theme and Light theme are set; then Nyx follows the system appearance.`
    The foot note stops naming three of eight rows: **[spec decision]** the task first drives every
    row in the built app, then writes either `Everything on this page applies as soon as you change
    it.` or a sentence naming the rows that need a new tab — from that answer, not from the current
    guess. Also here: the foot diagnostics label is announced when it appears (a11y 5.3, §8.1).

---

## 6. Wave 5 — tab bar, palette, search, banners

**Plan 5a (§6.1 + the `showMenu` fix of §6.5), eight tasks:** the width floor and overflow; tail
truncation; the hovered slot and the revealed `✕`; the `+ Button` chip; chips yielding before tabs;
the group band, collapsed chip and remote badge; `TabBarLabels` with an injected `chord:`, the three
new actions and the close-with-process alert; `showMenu` and the pictures. It ships on its own: the
bar stays legible past eight tabs and every control on it has a keyboard path.
**Plan 5b (§6.2–§6.4), nine tasks:** the palette's selection band; section headers; the empty state
and placeholder; keywords; `.selectedChildrenChanged` and disabled rows; the search readout
announcement and `toggle_search_scope`; prev/next gating and the scope word; the banner split by
kind with its native styling; `review_project_actions` / `dismiss_banner` and the pictures.

### 6.1 Tab bar

- **A tab has a floor and the bar overflows.** `TabBarGeometry.minimumTabWidth = 120`; when the
  tabs no longer fit at the floor, the ones that do not fit move into the `≡` list rather than
  every tab shrinking to `nyx…sh`. At 12 tabs today four titles are stubs and two pairs are
  indistinguishable (snapshot §3.7).
- **Titles truncate at the tail, not the middle.** `TabTitle.truncatedInMiddle` (`:796`) eats the
  distinguishing half of `nyx — zsh` / `nyx — vim`, and puts `…` next to a full stop in
  `tail….log`. Tail truncation: keep the head, append `…`. **Never an ellipsis adjacent to a `.`** —
  if the cut falls immediately after a `.`, back the cut up one character at a time until it does
  not (`TabTitle.truncatedAtTail`, tested with `tail.log`, `a.b.c.d.log` and a title that is all
  full stops).
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
  The leading dashed `+` becomes a labelled chip **`+ Button`** (dashed outline kept, 20 pt tall,
  its own width = text + 16 pt), and `New Button…` is always in the `≡` menu, so the two
  ~1000 px-apart identical glyphs stop existing (PM §1). **When the bar runs out of room the chip
  is dropped entirely** — it never degrades to a bare `+`, because a bare `+` is the defect. Order
  of yielding: quick-action chips → the `+ Button` chip → tabs down to the floor → tabs into the
  `≡` list. It is also an action: `new_quick_action`, "New Button…", Shell section.
- **Every drawn control on the bar has a ≥ 20 pt hit rect** — the `≡` (a 12 pt glyph today), the
  overflow chip, the `+`s and the `✕` — decided in `TabBarGeometry`.
- **The hovered tab is tinted** `foreground @ 0.06`: the bar has no hover state at all today
  (design §2.1). The same `Hit` hovered slot drives it and the revealed `✕`.
- **Tab, group and quick-action menus get a keyboard path**: `tab_actions`, "Tab Actions…", Window
  section (§8.2), popping the same menu `TabController.showTabMenu` builds for the selected tab —
  whose item titles and `enabled:` rules move into Core with it (inventory C.4).
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
- **The dead group-header geometry is deleted**, not wired (a11y 11.3). `barHeight`'s own comment
  says a group now names itself in a slot in front of its own tabs and the bar is one height
  always, so `Hit.groupHeader`, `groupHeaderRect`, `TabBarMetrics.groupHeaderHeight` and every
  `headerHeight:` parameter go, and `barHeight` loses its unused `grouping:` argument.
- **A close-with-process alert names the process** (PM §9): `“vim” is still running. Closing this tab will end it.`

### 6.2 Command palette

- **Selection is legible.** The band is 1.41–2.71:1 against the row in all seven themes — under the
  3:1 floor everywhere, under 1.5 in one-dark and solarized-dark — and it is the *only* cue. Fixed
  in the palette's colour derivation: `accent` at an alpha that clears **3:1 against
  `panelBackground`**, plus a **2 pt leading accent bar**.
- **Section headers** — `Actions`, `Buttons`, `Themes`, `Tabs`, `Remote`, `Requests` — since
  `PaletteSource.items` already orders by section; today the only cue that `dracula` is a theme is
  the word "Theme" right-aligned 900 px away. **`Buttons` is the round's one word for quick
  actions** (`+ Button`, `New Button…`, `Edit Button…`, `Save as Button…`), so the row detail word
  changes from `Quick Action` to `Button` in the same task; the config key `quick-action` and the
  docs keep their spelling, because renaming a config key is not a clarity fix.
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
which reads as a web cookie bar. **The banner pins its appearance** the way `BlockHeaderView` and
`LensFieldView` do, so `Edit Config` stops being drawn with a button ground in dark and bare in
light. The `✕` gets a 20 × 20 pt frame (a11y 8.2) and the label
`Dismiss this notice. It also goes away by itself the next time the config file loads cleanly.`,
plus keyboard paths for it and `Review…` (`dismiss_banner`, `review_project_actions`, §8.2). The
project bar's `Review…` is the default button — it is the security surface, and giving Review and
Ignore identical weight is a decision the app should not make for the user. Both of its wordings
(new and changed) are pictured, not only `changed` (design §6.11).

### 6.5 A shared fix that lands here

**`DrawnControlElement.showMenu`** (a11y 1.5): `Accessibility.swift:37-41` implements press only,
so the tab, group, quick-action and overflow menus are unreachable by VO-⇧-M. An optional
`showMenu` closure and `accessibilityPerformShowMenu()`, with plan **5a**, where those menus live.

(The other shared fix — **menu items showing their chords**, a `BlockAction → TerminalAction?`
mapping in Core, so the block menu stops leaving `keyEquivalent` empty at
`BlockHeaderView.swift:323-324` and `Pane.swift:2977-2978` while the lower half of the same menu
sets it at `:3013-3018` — has moved to plan **1b**: ⌘⇧A's menu has to teach the chords it
duplicates, so it cannot wait for Wave 5.)

---

## 7. Wave 6 — remote strip, pairing, and the universal binary

**Five tasks**, the last of which is not UX at all and rides this branch on the owner's ruling
(`decisions.md`, 2026-09-07).

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
   Recent activity stops being a raw ISO-8601 dump and uses a relative date (`RelativeAge`, the
   value the palette's Requests rows already use).
5. **`make release` and `make app` build a universal binary.** The owner could not install Nyx on
   an Intel Mac: both build for the host architecture only, so a copied bundle is refused on
   x86_64. Both gain `--arch arm64 --arch x86_64`, and the recipe asserts the result — `lipo -info
   build/Nyx.app/Contents/MacOS/Nyx` naming both slices, `file` agreeing, the make step failing if
   either does not. The code has no architecture-specific paths; `docs/testing.md` gains a line
   under the build rung saying a release bundle is universal and how to check it.

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
words. Sites: **a command finishing** (see the rule below), palette selection
(`.selectedChildrenChanged` from `CommandPaletteView.refresh()`), search readout, config banner
shown, project bar shown, the no-marks banner (§4.3), watch refusal, quick-action validation,
copy-with-credentials, pairing rejection, and the settings window's foot diagnostics label when it
appears (a11y 5.3). Plus `.layoutChanged` from `TabBarView.setTabs` and `PromptGutterView.update`.

**When a finish is announced — [spec decision].** Announcing every command talks over the user;
announcing none is a11y 0.2. The rule, in Core as `BlockAnnouncement.text(for:) -> String?` and
tested there: the **focused pane only**, and only when the command **ran ≥ 2 s or exited
non-zero**. The sentence is `BlockHeader.summary` — the words the strip shows.

### 8.2 New `TerminalAction`s

Every mouse-reachable action must have a keyboard path (`decisions.md` §3), and for anything drawn
inside a pane or on the tab bar a `TerminalAction` is the **only** possible fix: `Pane.keyDown`
sends a bare ⇥ to the PTY and `PaneTreeView`/`TabBarView` decline first responder, so there is no
key-view loop over pane chrome and there cannot be one (a11y 0.1).

| Action (`configName`) | Plan | Section | Title | Default chord | `canPerform` | Gives a keyboard path to |
|---|---|---|---|---|---|---|
| `block_actions` | 1b | Go | `Command Actions…` | ⌘⇧A | the block cursor resolves to a block | the whole ⋯ menu (26 items) and, through it, `Copy`, `Stop`, the lens chip and the dots — none of which are removed from the strip |
| `scroll_to_sticky_prompt` | 1b | Go | `Go to the Pinned Command` | — | a sticky prompt is showing | the sticky strip's click |
| `tab_actions` | 5a | Window | `Tab Actions…` | — | always | tab / group / quick-action context menus |
| `tab_list` | 5a | Window | `All Tabs…` | — | more than one tab | the `≡` button |
| `new_quick_action` | 5a | Shell | `New Button…` | — | always | the `+ Button` chip, the overflow chip's home |
| `toggle_search_scope` | 5b | Edit | `Search All Tabs` | — | a search is open | the scope toggle |
| `review_project_actions` | 5b | Shell | `Review This Folder's Actions…` | — | `ProjectActionsGate.needsApproval` | the project bar's `Review…` |
| `dismiss_banner` | 5b | Nyx | `Dismiss the Notice` | — | a banner is up | the banner `✕` |

**Eight existing actions change their target** (plan 1b, §2.8): `fold_command`,
`select_command_output`, `copy_command_output`, `copy_block_markdown`, `save_command_output`,
`edit_and_run_command`, `toggle_http_lens`, `stop_watch` — all onto `BlockCursor`; four are
re-titled in the same commit because they say "Last", and `select_command_output` gains the block
it never named (§2.2).

⌘⏎ activates `Run with jq` while the lens field has focus; that is a field key equivalent, not an
action. Every row goes into `ActionCatalog`, the menu bar, `docs/configuration.md` and the palette
(with `keywords`, §6.2); `canPerform` is the answer the menu bar and the palette's `enabled`
closure already share.

Legitimately pointer-only after this round: a lens selection drag, the palette scroller,
click-outside-to-close, the `⌘E Workbench` pill (⌘E does the same). Also not defects, per a11y
§0.1: every control inside a window of its own — the request editor's buttons and tables, the
settings buttons, the save panels — which are ⇥- and space-reachable already.

### 8.3 The pane's accessibility role — [verify]

`Pane` declares `.textArea` **and** vends `accessibilityChildren` (`:433`, `:437`, `:459`). If
VoiceOver treats a text area as a leaf, every in-pane element — gutter marks, fold placeholders,
the strip — is unreachable and `Pane.accessibilityChildren`'s careful work is invisible. **One
VoiceOver pass decides:** if children are reachable today, change nothing and record the pass and
its date in a comment beside `:433`; if they are not, the pane becomes `.group` with its **first
child** a `.textArea` carrying the transcript value and the chrome elements as siblings after it,
which keeps ⌘C, selection and text navigation on the transcript while making the chrome exist. The
same pass answers a11y 2.2 (palette row role) and 9.1 (remote strip leaf-or-container).

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

| plan | cases |
|---|---|
| 1a | `composite-strip-{w3,w2,w1,w0}-{finished,failed,running,folded,http,lensed,watch-running,watch-finished,no-output}-<palette>-<appearance>`; `gutter-cap-{succeeded,failed,running,no-output}-{idle,hovered,folded}-…`; `composite-sticky-…` retaken; every strip pill `hovered:` and `pressed:`; `composite-strip-suppressed-tui` (the strip while a TUI owns the screen) and `composite-block-lineheight-08` + `-padding-0` (design §6.4, §6.5) |
| 1b | `composite-block-cursor-{w3,w1}` (the cursor's block drawn as hovered, no pointer); `block-menu-{plain,http,watched}` (26 rows, with chords) |
| 2 | `lens-container-{folded,unfolded}`; `lens-chip-{off,on}` in all seven themes; `lens-field-anchored`; `lens-field-jq-{missing,non-idempotent}`; `watch-timeline-capped`; `grep-count` |
| 3 | `settings-shell-{automatic,manual,off}-{light,dark}`; `banner-no-marks`; `alert-cannot-watch` |
| 4 | `settings-{keys,behaviour,appearance,remote}-…` retaken (with the page strip, so a picture says which page it is — design §6.8); `sheet-quick-action-{send,run}`; `pairing-code-rejected-{light,dark}`; `watch-plan-editor-{valid,invalid,after-n-runs}` retaken; `request-editor-{options,reveal-secrets}-*` (options now deterministic) |
| 5a | `tabbar-{12,20}-tabs` retaken; `tabbar-hover-{tab,close}`; `tabbar-group-collapsed`; `tabbar-add-button-chip`; `tabbar-overflow-chip`; `menu-{tab,group,quick-action}` |
| 5b | `palette-{sections,no-results,selection}` in all seven themes; `palette-eleven-results`; `search-bar-{scope-word,zero-matches}`; `banner-{config,note,quick-action,project-new,project-changed}-{light,dark}`; `alert-project-review` |
| 6 | `remote-strip-*` retaken (the eight button states must become byte-identical across appearances); `pairing-host-{idle,opening}`; `settings-remote-explained` |

`settings-remote-*` is rendered from the real `~/.config/nyx` and is therefore not reproducible
across machines; it moves to a fixture `HOME` in Wave 4 (design §2.6).

### 8.6 The universal binary

`make app` building for the host architecture only is the last task of Wave 6 (§7.5), not a
free-floating note: the owner asked about an Intel Mac on 2026-09-07 and ruled that it rides this
branch.

---

## 9. Deliberately left out

- **Tab drag-reorder.** Every competitor including Ghostty has it, and Nyx's only route to
  reordering a tab is to put it in a group (PM §9). Left out because it is a new interaction model,
  not a clarity fix: drop targets, group boundaries, the overflow list, autoscroll at the edges and
  a drag crossing a collapsed group are product decisions, and it touches `TabController`'s
  ordering rather than drawn chrome. **Its own task immediately after this round**, with its own spec.
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
- **A watch that is visible outside its pane, and a clickable timeline** (PM §8). Both are new
  product surfaces — a background signal needs a rule for what it may interrupt, and a dot that
  opens its run needs per-run data the block does not keep. This round only gets the timeline back
  on screen (§2.6) and stops it lying about its cap (§3.12).
- **An automatic "your long command finished" alert** (PM §3). `notify_when_done` stays a
  deliberate act; what lands is the announcement of §8.1, which costs nothing to a user who is not
  listening.
- **Search-match colours** (design §2.4: the current match is *darker* than the others, inverting
  the platform convention). Drawn by the renderer's highlight path, and this round does not touch
  the render path — the bench guarantee in §10 exists to prove it did not.
- **A settings search field, "Restore Defaults", page shortcuts, a font preview** (PM §12): four
  features, none of them a lie being corrected. The window's real defects — a lost paste, a clipped
  table, unlabelled groups, a hidden reason — are all fixed in Wave 4.
- **Everything a11y marked "nice"** rather than must- or should-fix: the settings tab strip's own
  label, the `Settings...` three-dot title, the config note's prefix, the ⏎-means-two-things
  tooltips. One-line changes with no complaint behind them, and the round is already eight plans.

---

## 10. Testing

The ladder is `docs/testing.md`; **nothing in a wave counts as done until it has been looked at as
a picture and, where it has an AppKit edge, driven in the built app.** Per wave:

**Plan 1a — the mark and the strip.** Core: `CommandBlockChrome.widthClass` at the four boundaries
(33/34, 17/18, 7/8); `stripPlan` for **every cell of §2.6's table**, asserting both ladders and
that `Stop`, `Actions` and the status are never dropped, with the one measured exception named
(`theStopInvariantHoldsExceptInAPaneNoCurlFitsIn`); `firstColumn` never inside a word,
including with a trailing wide cell (D19); `overlapsCommand` for the last rung at any width, and
non-empty pills at every tail position wide enough for a strip;
`spineLeadingInset` at `padding` 0, 3, 8 and 64; `GutterCap` for the four states × hovered ×
folded; `hitRowHeight` at `line-height 0.8`; `StickyPromptLabel` for a finished command.
App: the §8.5 plan-1a snapshots, read at 1:1 and at 3× for the pills. Rung 6: a temporary
`NYX_SMOKE_QA` hook that, in the built app, hovers each width class through
`Pane.hitTest`, presses each pill, presses the gutter cap, presses the left padding
(which must now do **nothing**), and prints which action fired — the same shape as the G1 probe
that found the 16 pt frame; removed before the commit.

**Plan 1b — the keyboard on a block.** Core: `BlockCursor.moved` (both directions, from cleared, at
both ends, with a trimmed id) and `afterViewportMove` (block still visible / gone / no fallback);
`BlockAction → TerminalAction?` for every row of the menu; `BlockAnnouncement.text(for:)` at the
2 s and non-zero-exit boundaries. App: `composite-block-cursor-*` and `block-menu-*`. Rung 6: a
temporary `NYX_SMOKE_QA=blockcursor` hook that presses ⌘↑ twice, then ⌘⇧A, `copy_command_output`
and ⌘. in the built app and prints which block each one hit — the five-rules bug is invisible to a
unit test because the five rules were each individually correct.

**Wave 2 — lenses and watch.** Core: `LensChoices.previous` restored on clear; `LensRendering` grep
colours, line numbers and count; the redirect-chain order; `WatchSeries.headerTexts` series-tone vs
run-facts; `RequestRun.isIdempotent`; the `| jq` pipeline text and its escaping; `WatchVocabulary`'s
four labels. App: the Wave-2 snapshots; rung 6 extends the curl-workbench smoke hook — filter,
clear, container drag (a drag that must select and a click that must fold, at the same point),
`Run with jq` on a POST, a `jq`-less `PATH`.

**Wave 3 — shell integration.** Core: `ShellIntegration.environment` for bash and fish, with and
without an existing `XDG_DATA_DIRS`, with missing resources (must return the base environment
unchanged), `isAutomatic`, `manualInstallCommand`, and `ShellIntegrationStatus`' four sentences
with `<shell>` substituted. App: the Wave-3 snapshots (the Shell page in three states, the banner,
the alert). Rung 6 is the real gate here: **launch the built app with `SHELL=/bin/bash` and with
`SHELL=/opt/homebrew/bin/fish`, run a command in each, and confirm a gutter mark, a fold and a
`Copy` — a passing unit test proves nothing about a shell that will not start.** Then the same with
`shell-integration = off` and with `SHELL=/bin/ksh`, confirming the banner and the corrected alert.

**Wave 4 — settings and sheets.** Core: `ConfigWriter` trailing newline and a parser tolerating a
file without one; `RemotePageStatus`' four sentences and its `blocksPairing`;
`QuickActionEditorModel.problem`; `PairingFlow.State.codeRejected`; `WatchPlanEditorModel` problem
wording; the Appearance caption beside `ThemeCatalog`. App: the Wave-4 snapshots, including five
consecutive runs of `request-editor-options-light` proving it byte-identical.
Rung 6: paste a token into Settings → Remote, close the window without pressing Return, reopen, and
read the value back — the owner's exact 2026-09-07 report; and press every row of Appearance to
find which ones need a new tab, which is what item 13's sentence is written from.

**Plan 5a — the tab bar.** Core: `TabBarGeometry` at the 120 pt floor with 2/8/12/20 tabs, with and
without quick actions, asserting chips overflow before the `+ Button` chip and both before any tab
goes below the floor; `closeHitRect` and the ≥ 20 pt rule for every drawn control; tail truncation
and the no-`…`-beside-`.` rule; `TabBarLabels` with an injected `chord:`; the hovered slot. App:
the plan-5a snapshots. Rung 6: hover and press the `✕` on a 12-tab bar in the built app (a 14 pt
overshoot must no longer *select* the tab), and reach the tab menu with VO-⇧-M.

**Plan 5b — palette, search, banners.** Core: palette section ordering and headers, `keywords`, the
no-results text, and the selection band's contrast against all seven `panelBackground`s;
`SearchSession` prev/next gating and readout; the four banner kinds' symbol, text and buttons. App:
the plan-5b snapshots. Rung 6: `Announce` verified with VoiceOver **on** for the palette selection,
the search readout and all four banners.

**Wave 6 — remote and the universal binary.** App: the eight remote-strip button states must come
out **byte-identical across appearances**, the guard the whole `<palette>-<appearance>` naming
scheme exists to enforce. Core: `PairingFlow.sheetText` renders no state blank; `RemotePageStatus`
sentences. Rung 6: run the built app with a light theme under Dark Mode and read the strip's button
with the eye, not the picture. **The binary:** `make app` then `lipo -info` and `file` on
`build/Nyx.app/Contents/MacOS/Nyx`, both naming `x86_64` and `arm64`; the make step must fail if
they do not, and `docs/testing.md` gains the line.

**Every wave, every time.** `swift build` with **zero warnings**; `pkill -9 -f swiftpm-testing-helper;
swift test --no-parallel`; **`make bench` ≥ 180 MB/s** (nothing in this round touches the render
path, so a drop is a bug); `NYX_UI_SNAPSHOT=… ./build/Nyx.app/Contents/MacOS/Nyx` and read the
PNGs, using the `<palette>-<appearance>` rule and `cmp` to cut the set to the distinct pictures.

**Gates.** Each plan is reviewed by the `design-reviewer` over its pictures, by a VoiceOver pass
for anything in §8.2 or §8.3, and by the `product-manager` last — a plan is not done until he says
so (`docs/workflow.md`, `CLAUDE.md`).

---

## Appendix — Coverage

Every must-fix in the three findings files, and the section that carries it. A `§9` entry means the
spec drops it on purpose and says why there. Should-fixes are covered too where the spec takes
them; they are not listed unless the spec's treatment differs from what the finding asked for.

**`findings-a11y.md`**

| finding | spec |
|---|---|
| 0.1 no key-view loop over pane chrome; `TerminalAction` is the only fix | §8.2 (preamble) |
| 0.2 nothing ever posts an accessibility notification | §8.1, with the finish rule |
| 2.1 palette selection never announced | §6.2 |
| 3.1 `3 of 47` announced to nobody | §6.3 |
| 6.1 gutter target 8 pt at the defaults, comment claims 14 | §2.2 (20 pt, independent of padding) |
| 6.4 the strip cannot be raised without a pointer | §2.8 (`BlockCursor` + ⌘⇧A), §8.2 |
| 6.12 pane is `.textArea` **and** vends children [verify] | §8.3 |
| 7.1 sticky strip says "Running command" for a finished one | §2.7 |
| 8.1 project-actions bar pointer-only and silent | §6.4, §8.1, §8.2 (`review_project_actions`) |
| 6.2 success/failure by colour alone (should) | §2.2 — **design §3.2's shapes, not a11y's half-height mark**; ruling recorded there |
| 6.9 `Stop` shares a name with ⌘. at a different scope (should) | §2.3 (label) + §2.8 (one target) |
| 11.1 five rules for "which block" | §2.8 |
| 11.3 dead group-header geometry | §6.1 — deleted, not wired |
| 5.1 the Keys page cannot change a key (should, product) | §5.4 honest caption; the editor is §9 |
| 5.3 settings foot diagnostics never heard (should) | §8.1 site list, §5.13 |

**`findings-design.md`** (MUSTs, plus §3 as a system)

| finding | spec |
|---|---|
| §0 compositor loses layer-painted grounds | §8.5 — machinery, in flight before Wave 1's pictures |
| §2.1 tab titles collapse to stubs | §6.1 |
| §2.6 disabled Pair with its reason across the page | §5.3 |
| §2.7 two green marks 1.5 pt apart, padding-click folds | §2.2, §2.1 (`foldBlock(atPointInPadding:)` deleted) |
| §2.7 pills clipped flat by a 16 pt frame | §2.3 (20 pt strip) |
| §2.7 two identical grey circles; status dropped first | §2.6 (`Actions ▾`, the two ladders) |
| §2.7 the strip cuts the command mid-token | §2.3 (`firstColumn`) |
| §2.8 sticky strip: no affordance, nothing blanks the row | §2.7 |
| §2.10 remote strip button invisible cross-appearance | §7.1 |
| §3.2 geometry and colour rules | §2.2, §2.3 — one deviation (drawn mark height), ruled in §2.2 |
| §3.3 the decision table | §2.6 verbatim; the single drop order it contradicts is replaced by two ladders, ruled there |
| §6 states with no picture | §8.5 (TUI-suppressed, `line-height 0.8`, `padding 0`, reveal-secrets, the four menus, the alerts, the page strip, project-bar wordings) |

**`findings-pm.md`** ("the five to fix first", then the numbered findings it raised alone)

| finding | spec |
|---|---|
| the five to fix first: 1 sticky strip, 2 shell integration past zsh, 3 the block's controls as pixels, 4 the palette's first sentence and empty state, 5 the tab bar past eight tabs | §2.7 · §4 (a whole wave, placed before the block chrome because it is what makes the block exist for those users) · §2.2–§2.6 · §6.2 · §6.1, with drag-reorder in §9 |
| §1 two identical `+` glyphs, unlabelled `≡` | §6.1 |
| §5 `Copy` gone at narrow widths with no replacement | §2.6 — `Actions ▾`/`⋯` is never dropped and always carries Copy Output |
| §7 `Copy` copies credentials in the clear | §5.12; the split is §9 |
| §7 four names for the schedule feature | §3.14 |
| §8 a watch is invisible outside its pane | §9 |
| §9 close-with-process does not name the process | §6.1 |
| §12 three theme pop-ups with no explanation; foot note names three of eight rows | §5.13 |
| §13 the pairing placeholder reads as a value | §5.9 |
| §14 three banners, one amber band, one wrong button | §6.4 |
| §15 the lens field floats, has no close, never says which block | §3.11; `Body too large` is §3.13 |
| §16 hovering destroys information | §2.5 |
| §17 the block menu has never been pictured | §8.5 (plan 1b) |

## Addendum (2026-09-07, after the second snapshot-machinery pass, commit ef659cd)

Seven findings from the new pictures, assigned to plans; each is binding on its plan:

1. **Plan 1a.** The sticky strip is drawn over a full-screen program: `Pane.render` gates spines, summaries and the gutter on `CommandBlockChrome.isAllowed` but not `sticky`, and `stickyPrompt()` still returns a pinned command on the alternate screen (and loses the exit status there). The sticky strip obeys the same gate; a Core test on the alt screen.
2. **Plan 1a.** `line-height = 0.8` makes the 20 pt strip cover three rows; `padding = 0` removes the gutter *and* the spines. The strip's height is `max(20, hitRowHeight)` centred on its row and never covers more than the rows §2.3 allows; at `padding = 0` the gutter hit area still exists (it may overlap the first text column, §2.2) and the spine is drawn in the first column's leading 3 pt.
3. **Plan 1a / 5a.** No hover art exists anywhere on the tab bar or the gutter (five tab-bar hover pictures and one gutter picture are byte-identical to idle); pressing a strip pill changes 11/255 on a dark theme. §2.2's hover glyph and §6.1's hovered-tab tint are therefore new drawing, not adjustments; a pressed pill darkens its fill to `foreground @ 0.26`.
4. **Plan 2.** Changing a watch condition does not re-validate its value (`Status class is` + `200` opens into an error; `Body contains` + `200` enables Start). `WatchPlanEditorModel` re-validates on every field change.
5. **Plan 4.** Both destructive alerts default to the destructive answer (`Approve` on the project-actions review, `Close` on close-with-process). The default button is the safe one (`Cancel` / `Keep Running`); `Approve` is never the default.
6. **Plan 5b.** The search readout truncates: `1234 of 5678` draws as `1234 of 567`. The readout's width is measured from the widest count it can show.
7. **Plan 5a.** The tab, group, quick-action and overflow menus are the only user-facing verb lists not held in `NyxCore` as data (`MenuSnapshot` had to retype their titles). A `TabBarAction` enum with `title`/`isEnabled` in Core, built into `NSMenu` by the view, the way `BlockAction` already is; the snapshot reads the enum.

Menus cannot be captured live in this environment (`popUp` needs a window, an offscreen window runs a modal loop, screen capture is denied); `MenuSnapshot` reconstructs them at AppKit's measured metrics from the real `NSMenu`. Alerts are the real thing.
