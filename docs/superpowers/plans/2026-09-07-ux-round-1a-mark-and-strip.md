# UX round, plan 1a — the mark and the strip

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A command block is drawn as one system — one 3 pt mark that is both the gutter cap and the spine and the only mouse route to folding, and one 20 pt strip of labelled pills whose contents are decided by a single table in `NyxCore` — so that nothing costs a column at idle, hovering never removes a fact, and every control on the block says what it does.

**Architecture:** `CommandBlockChrome` becomes the single authority: `widthClass(freeColumns:)`, the two drop ladders (`pills(_:at:)` and `readout(_:at:)`) that reproduce §2.6's table cell by cell, `stripContent`/`stripPlan`/`stripPlacement` for what is drawn and where it begins, `gutterCap` for the mark's shape, and the four geometry numbers (`spineWidth`, `spineLeadingInset`, `hitRowHeight`, `stripFrameHeight`) that the Metal spine, the AppKit cap and every one-row hit target all read. `PromptGutterView` draws caps instead of capsules, a new `StripPillView` draws every pill with its own hover, pressed and on art, `BlockHeaderView` becomes a layout of one `StripPlan`, `Renderer` draws the spine at the same two numbers as the cap, and `Pane` converts events and places views. `OverlayControls`, `overlayPlacement`, the bare `▾` pill, the in-grid chevron and `foldBlock(atPointInPadding:)` are deleted in the tasks that move their last callers.

**Tech Stack:** Swift 6.0.3 in Swift 5 language mode, SwiftPM, swift-testing, AppKit, Metal. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-07-ux-round-design.md` — §1 (the bar), §2.1–§2.7 (this plan), §8.4 (row heights), §8.5 (pictures), §10 (testing for 1a), the Coverage appendix, and the **Addendum** items 1, 2 and 3, which are binding on this plan. Reasoning behind the table: `.superpowers/sdd/2026-09-07-ux-round/findings-design.md` §3.

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY: no AppKit, Metal, CoreText or QuartzCore, and — the house rule this plan keeps — **no CoreGraphics type either**: every geometry number it hands out is a `Double`, the way `PromptGutter` already does, and the AppKit layer converts at the call site. (This is the one deviation from §2.1's literal `CGFloat` signatures.)
- `NyxRender` learns nothing about *chrome*: no strip, no pill, no hover. It does read `CommandBlockChrome.spineLeadingInset` and `.spineWidth` for the spine it already draws, which §2.1 requires in as many words — "the renderer reads the same two numbers, so the Metal spine and the AppKit cap cannot drift apart" — and which costs no new dependency (`NyxRender` already imports `NyxCore` and already calls `CommandBlockChrome.summaryColumns`). Decision logic goes in `NyxCore` behind a pure interface and is unit-tested; the AppKit layer converts events and draws.
- Tests are **swift-testing** (`import Testing`, `@Test`, `#expect`, `#require`). XCTest is not available. **Hoist mutating calls out of `#expect`/`#require`** — the macro captures the receiver immutably and the error points at the macro expansion.
- Test runner hang fix: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`. Never wait on a background test run.
- The build stays **warning-free** (library and tests), and **`make bench` stays at or above 180 MB/s** — nothing in this plan touches the parser or the row cache, so a drop is a bug.
- Swift 6.0.3 in Swift 5 language mode, `// swift-tools-version:5.10`, macOS 14.
- **Geometry, verbatim (§2.2, §2.3)** — *superseded in three places by the spec amendments of
  2026-09-10: the pill hairline is `Palette.pillHairline` (from 0.30, pushed to 1.6:1 idle and 3:1
  hovered) and not a flat `@ 0.22`; the dot cap is **12** and not 30; the no-output mark's 40 % is
  nominal, raised per theme to 3:1. Read §2.2 and §2.3 for the shipped numbers.* gutter hit width 20 pt, independent of `padding`, allowed to overlap the first text column; drawn mark 3 pt wide × `cellHeight` tall at `spineLeadingInset(padding:) = min(4, max(0, padding - 3))`; strip height 20 pt; pill height 20 pt, corner radius 6 pt; glyph pill width 24 pt; label pill width = text width + 16 pt; pill text `NSFont.systemFont(ofSize: 11, weight: .medium)`; pill glyphs `⋯` and `▾` drawn as paths 8 pt wide; gap between pills 6 pt; trailing inset 8 pt; pill fill `palette.foreground @ 0.14`, hairline `palette.foreground @ 0.22`, **pressed fill `palette.foreground @ 0.26`** (Addendum 3); leading edge 8 pt of solid strip ground then a 2-cell gradient to transparent; strip ground is the row's own hover tint, not `palette.background`; dots filled, 7 pt, on a 10 pt pitch, the running run a **filled accent** dot; dot cap 30, past it the leading dot becomes `+N`.
- **Width classes, verbatim (§2.6):** W3 ≥ 34, W2 18–33, W1 8–17, W0 < 8 free columns after the command's last glyph.
- **Copy that must not change:** the summary vocabulary (`exit 1 · 8.8s`, `200 · 142 ms · 1.2 KB · json`, `11 runs · p50 140 ms · p95 190 ms · 2 failures`) may be dropped from, never re-worded. Pill labels and help, verbatim: `Copy` / `Copy this command’s output`; `Stop` / `Stop watching this request`; `Fold` / `Fold this command’s output`; `Actions ▾` and `⋯` / `Command actions`.
- Every tinted control resolves through `SummaryTone.color(in:)` / `RGB.readable(_:on:towards:)`; floors are 4.5:1 for text and 3:1 for a shape that is the only cue.
- **A new piece of chrome gets a snapshot case in the same commit** (`docs/testing.md`), named `<case>-<palette>-<appearance>`.
- Commit trailers on **every** commit:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (the only trailer since 2026-09-09; the earlier `Claude-Session` line is superseded)
- `git add` **by name**; never `git add -A`. Never touch `CLAUDE.md`, `.claude/`, `docs/testing.md`, `docs/workflow.md`, `docs/checklist.md`.
- Plan 1b (`BlockCursor`, ⌘⇧A, the re-targeted actions) is a **separate plan**. Nothing here adds a `TerminalAction`, and nothing here waits for one.

## File map

| File | Responsibility after this plan |
|---|---|
| `Sources/NyxCore/Shell/CommandBlock.swift` | The whole decision table: `WidthClass`, `Pill`, `StripContent`, `StripPlan`, `StripPlacement`, `GutterCap`, the two ladders, and the four geometry numbers. `OverlayControls`, `OverlayPlacement`, `overlayPlacement` and `SummaryPlacement.Variant.chevronOnly` are gone from it. |
| `Sources/NyxCore/Shell/PromptGutter.swift` | The gutter's hit geometry only: `hitWidth`, `markedRow(atY:…)`. `maximumWidth`, `markWidth`, `markInset`, `minimumPadding`, `width(padding:)` and `markRect(gutterWidth:)` are gone. |
| `Sources/NyxCore/Shell/StickyPrompt.swift` | Which command is pinned (now gated by `CommandBlockChrome.isAllowed`) and what the band reads and says to VoiceOver. |
| `Sources/NyxApp/PromptGutterView.swift` | Draws `GutterCap`s and the hover chevron; owns the 20 pt hit area, the tooltips, the cursor rects and the accessibility elements. |
| `Sources/NyxApp/StripPillView.swift` (new) | One pill: fill, hairline, label or 8 pt path glyph, hover / pressed / on art, cursor rect, accessibility. |
| `Sources/NyxApp/BlockHeaderView.swift` | Lays out one `StripPlan` — dots, `+N`, readout, pills — measures it for Core, paints the ground and the fade, opens the ⋯ menu. |
| `Sources/NyxApp/WatchDotsView.swift` | 7 pt filled dots on a 10 pt pitch, the running one filled accent. |
| `Sources/NyxApp/StickyPromptView.swift` | The pinned band: opaque ground, bottom divider, leading `↑`, truthful label. |
| `Sources/NyxApp/Pane.swift` | Converts events, builds the caps and the placement per frame, places the views. No `if` about which control survives. |
| `Sources/NyxRender/Renderer.swift` | The spine at `CommandBlockChrome.spineLeadingInset` × `spineWidth`, and a summary with no chevron. |
| `Sources/NyxApp/{UISnapshot,GridSnapshot,StateSnapshot}.swift` | The §8.5 pictures for this plan. |

---

### Task 1: `CommandBlockChrome` — the decision table and the geometry

**Files:**
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift` — add to `enum CommandBlockChrome` (lines 109-210) and **replace `:111-112`**: the existing `spineWidth: Double = 2` becomes `= 3`, and `spineGap: Double = 4` is **deleted** (it has no caller anywhere in the tree — the renderer computes its own `padding - 3`, which `spineLeadingInset` replaces). Leave `OverlayControls` and `overlayPlacement` in place; Task 3 deletes them with their last caller.
- Modify: `Sources/NyxCore/HTTP/ResponseLens.swift` (`chipTitle`, beside `title` at `:26`)
- Modify: `Sources/NyxCore/HTTP/WatchSeries.swift` (`WatchHeader.hiddenRuns` at `:453-467`; `headerText`'s running sentence at `:381-401`; `header(dots:)` at `:476`)
- Test: `Tests/NyxCoreTests/CommandBlockChromeTests.swift` (new)
- Test: `Tests/NyxCoreTests/WatchSeriesTests.swift`, `Tests/NyxCoreTests/ResponseLensTests.swift` (add cases)

**Interfaces:**
- Consumes: `BlockHeader` (`summary`, `tone`, `folded`, `hasOutput`, `isRunning`, `failed`, `isHTTP`, `lens`, `lensTooLarge`, `bodyIsJSON`, `watch`), `WatchHeader`, `WatchSeries.Dot`, `SummaryTone`, `Row`, `Cell`, `CellAttrs.wideSpacer`.
- Produces (every later task reads these exact names):

```swift
public extension CommandBlockChrome {
    enum WidthClass: Equatable { case w3, w2, w1, w0 }
    static func widthClass(freeColumns: Int) -> WidthClass
    static func lastUsedColumn(of row: Row) -> Int
    static func freeColumns(cols: Int, lastUsedColumn: Int) -> Int

    enum Pill: Equatable, Hashable {
        enum FoldLabel: Equatable, Hashable { case fold, unfold }
        enum Actions: Equatable, Hashable { case labelled, glyph }
        enum Glyph: Equatable, Hashable { case ellipsis, chevronDown }
        case fold(FoldLabel)
        case copy(enabled: Bool)
        case lens(name: String, on: Bool)
        case stop
        case actions(Actions)
        var title: String                 // "Fold" / "Unfold" / "Copy" / the lens name / "Stop" / "Actions" / ""
        var glyph: Glyph?                 // .ellipsis only, for `.actions(.glyph)`
        var trailingChevron: Bool         // an 8 pt `▾` path after the title
        var help: String                  // tooltip and setAccessibilityHelp
        var accessibilityLabel: String
    }
    struct StripContent: Equatable {
        let readout: String
        let readoutTone: SummaryTone
        let dots: [WatchSeries.Dot]
        let overflowDot: String?
        let pills: [Pill]
    }
    struct StripPlan: Equatable {
        let content: StripContent
        let firstColumn: Int
        let overlapsCommand: Bool
        var readout: String { content.readout }
        var readoutTone: SummaryTone { content.readoutTone }
        var dots: [WatchSeries.Dot] { content.dots }
        var overflowDot: String? { content.overflowDot }
        var pills: [Pill] { content.pills }
    }
    struct StripPlacement: Equatable { let row: Int; let plan: StripPlan }

    static func pills(_ header: BlockHeader, at width: WidthClass) -> [Pill]
    static func readout(_ header: BlockHeader, at width: WidthClass) -> String
    static func stripContent(_ header: BlockHeader, at width: WidthClass) -> StripContent?
    static func stripPlan(_ content: StripContent, widthClass: WidthClass,
                          lastUsedColumn: Int, cols: Int, stripColumns: Int) -> StripPlan?
    static func stripPlacement(_ header: BlockHeader,
                               commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                               cols: Int,
                               measure: (StripContent) -> Int) -> StripPlacement?
    /// Whether the in-grid summary gives way to this strip (§2.5).
    static func suppressesSummary(_ plan: StripPlan, stripRow: Int, summaryRow: Int?) -> Bool

    struct GutterCap: Equatable {
        enum Shape: Equatable { case solid, bar, hollow, faded, chevronDown, chevronRight }
        let shape: Shape
        let tone: SummaryTone
        let isPressable: Bool
    }
    static func gutterCap(_ header: BlockHeader, hasStarted: Bool, hovered: Bool) -> GutterCap?

    /// Replaces the file's own `spineWidth: Double = 2` (`CommandBlock.swift:111`). `Double`, not
    /// the spec's `CGFloat`: `NyxCore` contains no CoreGraphics type anywhere today, `PromptGutter`
    /// is already `Double`, and the AppKit layer converts at the call site as it already does.
    static let spineWidth: Double              // 3
    static func spineLeadingInset(padding: Double) -> Double
    static func hitRowHeight(cellHeight: Double) -> Double
    static let stripHeight: Double             // 20
    static func stripFrameHeight(cellHeight: Double) -> Double
    static func stripGroundHeight(cellHeight: Double) -> Double
    static let foldColumnWidth: Double         // 20
}
public extension ResponseLens { var chipTitle: String }
public extension WatchHeader { var hiddenRuns: Int }   // stored, defaults to 0 in `init`
```

**Two deviations from §2.1's sketch, both deliberate, both recorded here so a reviewer does not read them as drift:**
1. §2.1 writes `stripPlan(_ header:, freeColumns:)`. The measured pill width has to enter Core somewhere or the placement becomes a guess in a view, so the decision is split: `stripContent` answers the table (no pixels, the four classes, the two ladders) and `stripPlan`/`stripPlacement` answer the placement from the view's measurement in columns. Both are pure, both are in Core, both are tested.
2. §2.1 writes `gutterCap(_ header:, hovered:, folded:)`. `folded` is already on the header, and a second opinion about it is exactly the class of bug this wave exists to remove, so it is read from `header.folded`; `hasStarted` is passed instead, because the prompt you are typing at has a prompt mark, no status and must draw **nothing** (today's `GutterMark.isDrawn(hasStarted:)`), which no field of `BlockHeader` can say.

- [ ] **Step 1: Write the failing tests** — `Tests/NyxCoreTests/CommandBlockChromeTests.swift`

```swift
import Testing
@testable import NyxCore

private func header(summary: String = "8.8s", state: BlockHeader.State = .finished,
                    folded: Bool = false, hasOutput: Bool = true,
                    http: HTTPSummary? = nil, isHTTP: Bool = false,
                    lens: ResponseLens? = nil, lensTooLarge: Bool = false, json: Bool = false,
                    watch: WatchHeader? = nil) -> BlockHeader {
    BlockHeader(id: 7, state: state, folded: folded, hasOutput: hasOutput, anyFolds: false,
                notifyArmed: false, summary: summary, httpSummary: http, isHTTP: isHTTP,
                lens: lens, lensTooLarge: lensTooLarge, bodyIsJSON: json, watch: watch)
}

private func pills(_ h: BlockHeader, _ w: CommandBlockChrome.WidthClass) -> [CommandBlockChrome.Pill] {
    CommandBlockChrome.stripContent(h, at: w)?.pills ?? []
}

private func readout(_ h: BlockHeader, _ w: CommandBlockChrome.WidthClass) -> String {
    CommandBlockChrome.stripContent(h, at: w)?.readout ?? ""
}

// MARK: - Width classes

/// The four boundaries of §2.6, from both sides. A free-column count is what the whole table is
/// indexed by, so an off-by-one here silently draws the wrong strip on every block in the pane.
@Test func theWidthClassBoundariesAreExact() {
    #expect(CommandBlockChrome.widthClass(freeColumns: 34) == .w3)
    #expect(CommandBlockChrome.widthClass(freeColumns: 33) == .w2)
    #expect(CommandBlockChrome.widthClass(freeColumns: 18) == .w2)
    #expect(CommandBlockChrome.widthClass(freeColumns: 17) == .w1)
    #expect(CommandBlockChrome.widthClass(freeColumns: 8) == .w1)
    #expect(CommandBlockChrome.widthClass(freeColumns: 7) == .w0)
    #expect(CommandBlockChrome.widthClass(freeColumns: 0) == .w0)
    #expect(CommandBlockChrome.widthClass(freeColumns: -3) == .w0)
}

/// D19: `Renderer.lastUsed` stops at the last cell with content, and the second half of a wide
/// glyph has none -- so a command line ending in 世 was counted one column short and the strip
/// began on top of it.
@Test func aTrailingWideCellCountsItsSpacer() {
    var row = Row(cols: 10)
    var lead = Cell(); lead.content = 0x4E16; lead.attrs.insert(.wide)
    var spacer = Cell(); spacer.attrs.insert(.wideSpacer)
    row.cells[4] = lead
    row.cells[5] = spacer
    #expect(CommandBlockChrome.lastUsedColumn(of: row) == 5)
    #expect(CommandBlockChrome.freeColumns(cols: 10, lastUsedColumn: 5) == 4)
    #expect(CommandBlockChrome.lastUsedColumn(of: Row(cols: 10)) == -1)
    #expect(CommandBlockChrome.freeColumns(cols: 10, lastUsedColumn: -1) == 10)
}

// MARK: - §2.6's table, row by row
//
// Every cell of the table in the spec, asserted here. These are the tests the two ladders exist to
// pass: the ladder text in `findings-design` §3.3 contradicts its own table, and the ruling is that
// the table is what ships.

@Test func theTableHoveredFinished() {
    let h = header(summary: "8.8s")
    #expect(pills(h, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(CommandBlockChrome.stripContent(h, at: .w0) == nil)
    #expect(readout(h, .w3) == "8.8s")
    #expect(readout(h, .w1) == "8.8s")
}

@Test func theTableHoveredFailed() {
    let h = header(summary: "exit 1 · 8.8s", state: .failed(status: 1))
    #expect(pills(h, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(readout(h, .w3) == "exit 1 · 8.8s")
    #expect(readout(h, .w2) == "exit 1 · 8.8s")
    #expect(readout(h, .w1) == "exit 1")
    #expect(CommandBlockChrome.stripContent(h, at: .w1)?.readoutTone == .failure)
}

@Test func theTableHoveredRunning() {
    let h = header(summary: "12s", state: .running(elapsed: 12))
    #expect(pills(h, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(readout(h, .w1) == "12s")
}

/// Folded keeps `Unfold` past `Copy`: the pill says what the block currently is, and Copy is the
/// one control the ⋯ menu certainly still carries.
@Test func theTableFolded() {
    let h = header(summary: "8.8s", folded: true)
    #expect(pills(h, .w3) == [.fold(.unfold), .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.fold(.unfold), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
}

@Test func theTableHTTP() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms · 1.2 KB · json", tone: .success),
                   isHTTP: true, json: true)
    #expect(pills(h, .w3) == [.lens(name: "Pretty", on: false), .fold(.fold),
                              .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.lens(name: "Pretty", on: false), .actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(readout(h, .w3) == "200 · 142 ms · 1.2 KB · json")
    #expect(readout(h, .w2) == "200 · 142 ms")
    #expect(readout(h, .w1) == "200")
}

/// A lens already open lights the chip and names itself; the body no longer has to be JSON, because
/// the chip is also how the reader gets back out.
@Test func theTableLensed() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                   isHTTP: true, lens: .pretty, json: true)
    #expect(pills(h, .w3).first == .lens(name: "Pretty", on: true))
    let raw = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                     isHTTP: true, lens: .raw, json: false)
    #expect(pills(raw, .w3).first == .lens(name: "Raw", on: true))
    // Nothing a lens can do anything with, and none open: no chip at all rather than an inert one.
    let big = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                     isHTTP: true, lensTooLarge: true, json: true)
    #expect(pills(big, .w3) == [.fold(.fold), .copy(enabled: true), .actions(.labelled)])
}

/// Stop is present at every width, and a watched block never takes the lens chip -- the two would
/// be competing for the one rung under Actions, and the lens stays in the menu.
@Test func theTableWatchedRunning() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 100 ms", tone: .success),
                   isHTTP: true, json: true,
                   watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                      dots: [.success, .success, .success, .running],
                                      showsStop: true, tone: .success))
    #expect(pills(h, .w3) == [.stop, .copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.stop, .actions(.labelled)])
    #expect(pills(h, .w1) == [.stop, .actions(.glyph)])
    #expect(pills(h, .w0) == [.stop])
    #expect(readout(h, .w3) == "run 12 · 200 · 100 ms · every 5 s")
    #expect(readout(h, .w2) == "run 12 · 200")
    #expect(readout(h, .w1) == "run 12")
    #expect(readout(h, .w0) == "")
    // The timeline is the widest thing here and goes at the first squeeze.
    #expect(CommandBlockChrome.stripContent(h, at: .w3)?.dots.count == 4)
    #expect(CommandBlockChrome.stripContent(h, at: .w2)?.dots.isEmpty == true)
}

/// A finished series keeps its failure count when it drops its percentiles: "11 runs" alone reads
/// as a series that went fine.
@Test func theTableWatchedFinished() {
    let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                   isHTTP: true, json: true,
                   watch: WatchHeader(text: "11 runs · p50 140 ms · p95 190 ms · 2 failures",
                                      dots: [.success, .failure], showsStop: false, tone: .failure))
    #expect(pills(h, .w3) == [.copy(enabled: true), .actions(.labelled)])
    #expect(pills(h, .w2) == [.actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(CommandBlockChrome.stripContent(h, at: .w0) == nil)
    #expect(readout(h, .w2) == "11 runs · 2 failures")
    #expect(readout(h, .w1) == "11 runs")
}

@Test func theTableNoOutput() {
    let h = header(summary: "8.8s", hasOutput: false)
    #expect(pills(h, .w3) == [.actions(.labelled)])
    #expect(pills(h, .w2) == [.actions(.labelled)])
    #expect(pills(h, .w1) == [.actions(.glyph)])
    #expect(CommandBlockChrome.stripContent(h, at: .w0) == nil)
}

/// The two invariants §2.6 states in words, over every row of the table at every width.
@Test func stopAndActionsAndTheStatusAreNeverDropped() {
    let watched = header(summary: "", http: HTTPSummary(text: "200", tone: .success), isHTTP: true,
                         json: true,
                         watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                            dots: [.running], showsStop: true, tone: .success))
    for width in [CommandBlockChrome.WidthClass.w3, .w2, .w1, .w0] {
        #expect(pills(watched, width).contains(.stop), "\(width)")
    }
    for h in [header(summary: "exit 1 · 8.8s", state: .failed(status: 1)),
              header(summary: "8.8s"), header(summary: "8.8s", folded: true),
              header(summary: "8.8s", hasOutput: false)] {
        for width in [CommandBlockChrome.WidthClass.w3, .w2, .w1] {
            let list = pills(h, width)
            #expect(list.contains(.actions(.labelled)) || list.contains(.actions(.glyph)), "\(width)")
            // Whatever the strip says, it says the status: the summary it suppresses said no more.
            #expect(!readout(h, width).isEmpty, "\(width)")
        }
    }
}

/// `Actions ▾` collapses to `⋯` before any pill is dropped, and never the other way round.
@Test func actionsCollapsesBeforeAnyPillIsDropped() {
    let h = header(summary: "8.8s")
    #expect(pills(h, .w3).last == .actions(.labelled))
    #expect(pills(h, .w2).last == .actions(.labelled))
    #expect(pills(h, .w1).last == .actions(.glyph))
}

// MARK: - Where the strip begins

@Test func theStripIsRightAlignedAfterTheLastGlyph() throws {
    let content = try #require(CommandBlockChrome.stripContent(header(summary: "8.8s"), at: .w3))
    let plan = CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 20,
                                            cols: 80, stripColumns: 30)
    #expect(plan?.firstColumn == 50)
    #expect(plan?.overlapsCommand == false)
}

/// Never inside a word: a strip whose leading column would land on the command's own text is no
/// strip at all, and the gutter still folds.
@Test func aStripThatWouldBeginInsideAWordIsRefused() throws {
    let content = try #require(CommandBlockChrome.stripContent(header(summary: "8.8s"), at: .w3))
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 55,
                                         cols: 80, stripColumns: 30) == nil)
    // Touching is still colliding: the first free column is `lastUsedColumn + 1`.
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 50,
                                         cols: 80, stripColumns: 30) == nil)
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: 49,
                                         cols: 80, stripColumns: 30)?.firstColumn == 50)
}

/// The one exception: the lone Stop of the W0 row, over the tail of the command, on an opaque pill.
@Test func onlyTheW0StopOverlapsTheCommand() throws {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.running], showsStop: true, tone: .success))
    let content = try #require(CommandBlockChrome.stripContent(watching, at: .w0))
    let plan = CommandBlockChrome.stripPlan(content, widthClass: .w0, lastUsedColumn: 79,
                                            cols: 80, stripColumns: 8)
    #expect(plan?.overlapsCommand == true)
    #expect(plan?.firstColumn == 72)
    #expect(plan?.pills == [.stop])
}

/// A strip wider than the pane hangs off the left edge: no strip, at any width class.
@Test func aStripWiderThanThePaneIsRefused() throws {
    let content = try #require(CommandBlockChrome.stripContent(header(summary: "8.8s"), at: .w3))
    #expect(CommandBlockChrome.stripPlan(content, widthClass: .w3, lastUsedColumn: -1,
                                         cols: 20, stripColumns: 21) == nil)
}

/// The placement walks the command's rows from the last upwards, the way the summary does: a
/// wrapped `curl` fills its first rows and leaves room on its last.
@Test func thePlacementTakesTheLowestRowWithRoom() {
    let h = header(summary: "8.8s")
    let placement = CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 9), (absoluteRow: 5, lastUsedColumn: 78)],
        cols: 80, measure: { _ in 20 })
    #expect(placement?.row == 4)
    #expect(placement?.plan.firstColumn == 60)
}

/// §2.5's hard case: a wrapped watched command whose last row is full puts its lone `Stop` there,
/// and the summary belongs on the row above -- so the strip does **not** speak for it, and hovering
/// must not take `run 12 · 200 · 100 ms · every 5 s` off the screen.
@Test func aW0StopDoesNotSpeakForTheSummaryOnAnotherRow() throws {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.running], showsStop: true, tone: .success))
    let rows = [(absoluteRow: 4, lastUsedColumn: 10), (absoluteRow: 5, lastUsedColumn: 79)]
    let placement = try #require(CommandBlockChrome.stripPlacement(
        watching, commandRows: rows, cols: 80, measure: { $0.pills == [.stop] ? 8 : 60 }))
    #expect(placement.row == 5)
    #expect(placement.plan.pills == [.stop])
    let summaryRow = CommandBlockChrome.summaryPlacement(commandRows: rows, textCount: 32,
                                                         cols: 80)?.row
    #expect(summaryRow == 4)
    #expect(!CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                  summaryRow: summaryRow))
    // …and a strip that did land on the summary's own row, with something to say, speaks for it:
    // two sentences on one row is the row saying the same thing twice.
    let onTheRow = try #require(CommandBlockChrome.stripPlacement(
        watching, commandRows: [rows[0]], cols: 80, measure: { _ in 60 }))
    #expect(CommandBlockChrome.suppressesSummary(onTheRow.plan, stripRow: onTheRow.row,
                                                 summaryRow: 4))
}

/// No row with room and nothing to stop: no strip anywhere, which is what keeps the in-grid summary
/// on screen (§2.5).
@Test func noRoomAnywhereMeansNoStrip() {
    let h = header(summary: "8.8s")
    #expect(CommandBlockChrome.stripPlacement(h,
        commandRows: [(absoluteRow: 4, lastUsedColumn: 79)], cols: 80, measure: { _ in 20 }) == nil)
    #expect(CommandBlockChrome.stripPlacement(h, commandRows: [], cols: 80,
                                              measure: { _ in 20 }) == nil)
}

// MARK: - The gutter cap

@Test func theCapShapesCarryTheState() {
    let done = CommandBlockChrome.gutterCap(header(summary: "8.8s"), hasStarted: true, hovered: false)
    #expect(done?.shape == .solid)
    #expect(done?.tone == .success)
    #expect(done?.isPressable == true)
    let failed = CommandBlockChrome.gutterCap(header(summary: "exit 1", state: .failed(status: 1)),
                                              hasStarted: true, hovered: false)
    #expect(failed?.shape == .bar)
    #expect(failed?.tone == .failure)
    let running = CommandBlockChrome.gutterCap(header(summary: "12s", state: .running(elapsed: 12)),
                                               hasStarted: true, hovered: false)
    #expect(running?.shape == .hollow)
    #expect(running?.tone == .running)
    // A command that printed nothing: a record, at 40 % alpha, and not a button.
    let quiet = CommandBlockChrome.gutterCap(header(summary: "8.8s", hasOutput: false),
                                             hasStarted: true, hovered: false)
    #expect(quiet?.shape == .faded)
    #expect(quiet?.isPressable == false)
    // The prompt being typed at has a prompt mark and has run nothing: no cap at all.
    #expect(CommandBlockChrome.gutterCap(header(summary: "", hasOutput: false),
                                         hasStarted: false, hovered: false) == nil)
}

@Test func hoveringTurnsTheCapIntoAChevron() {
    let open = CommandBlockChrome.gutterCap(header(summary: "8.8s"), hasStarted: true, hovered: true)
    #expect(open?.shape == .chevronDown)
    let folded = CommandBlockChrome.gutterCap(header(summary: "8.8s", folded: true),
                                              hasStarted: true, hovered: true)
    #expect(folded?.shape == .chevronRight)
    // Nothing to fold, nothing to promise: hovering a no-output mark changes nothing.
    let quiet = CommandBlockChrome.gutterCap(header(summary: "8.8s", hasOutput: false),
                                             hasStarted: true, hovered: true)
    #expect(quiet?.shape == .faded)
}

// MARK: - Geometry

/// The mark leaves the window's resize margin at the shipping padding and never leaves the window
/// at `padding = 0`, where it draws over the first text column's leading 3 points instead.
@Test func theSpineInsetMovesOffTheWindowEdge() {
    #expect(CommandBlockChrome.spineWidth == 3)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 0) == 0)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 3) == 0)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 8) == 4)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 64) == 4)
}

/// §8.4: every hit target that is one text row tall is 13 pt at `line-height = 0.8`. The floor is
/// on the target, never on the drawn mark.
@Test func theHitHeightIsFlooredAndTheDrawnMarkIsNot() {
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: 13) == 16)
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: 16) == 16)
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: 24) == 24)
    // Addendum 2: the strip's frame clears both floors; its painted ground stays one row tall, so
    // a 20 pt band cannot cover three rows of a `line-height 0.8` grid.
    #expect(CommandBlockChrome.stripFrameHeight(cellHeight: 13) == 20)
    #expect(CommandBlockChrome.stripFrameHeight(cellHeight: 24) == 24)
    #expect(CommandBlockChrome.stripGroundHeight(cellHeight: 13) == 13)
}
```

  And in `Tests/NyxCoreTests/ResponseLensTests.swift`:

```swift
/// The chip carries the lens' *name*, and it is the short head of the menu's own wording -- never a
/// third spelling of the same lens.
@Test func everyLensHasAChipTitle() {
    #expect(ResponseLens.raw.chipTitle == "Raw")
    #expect(ResponseLens.pretty.chipTitle == "Pretty")
    #expect(ResponseLens.headers.chipTitle == "Headers")
    #expect(ResponseLens.body.chipTitle == "Body")
    #expect(ResponseLens.filter(".a").chipTitle == "Filter")
    #expect(ResponseLens.grep("x").chipTitle == "Find")
    #expect(ResponseLens.diff(previousCommandID: 3).chipTitle == "Diff")
    for lens in [ResponseLens.raw, .pretty, .headers, .body, .filter(""), .grep(""),
                 .diff(previousCommandID: 0)] {
        #expect(lens.title.hasPrefix(lens.chipTitle) || lens.chipTitle == "Find",
                "\(lens.chipTitle) is not the head of \(lens.title)")
    }
}
```

  And in `Tests/NyxCoreTests/WatchSeriesTests.swift`:

```swift
/// The running sentence is ordered the way the readout ladder drops it: the run number first, the
/// interval last, because the interval is the first thing a narrow strip gives up (§2.6).
@Test func theRunningHeaderPutsTheIntervalLast() {
    var series = WatchSeries(plan: WatchPlan(interval: 5, stop: .never), command: "curl x",
                             startedAt: 0)
    series.runStarted(id: 1, at: 0)
    series.runFinished(id: 1, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 1)
    #expect(series.headerText == "run 1 · 200 · 100 ms · every 5 s")
    let header = series.header(dots: 30)
    #expect(header.hiddenRuns == 0)
}

/// The timeline stops being silent about its cap: thirty dots and a `+N` in front of them.
@Test func theTimelineSaysHowManyRunsItIsNotShowing() {
    var series = WatchSeries(plan: WatchPlan(interval: 1, stop: .never), command: "curl x",
                             startedAt: 0)
    for id in UInt32(1)...48 {
        series.runStarted(id: id, at: Double(id))
        series.runFinished(id: id, status: 200, exitStatus: 0, timeTotal: 0.1, body: "",
                           at: Double(id) + 0.1)
    }
    let header = series.header(dots: 30)
    #expect(header.dots.count == 30)
    #expect(header.hiddenRuns == 18)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter CommandBlockChrome`
Expected: FAIL — `type 'CommandBlockChrome' has no member 'widthClass'` and the rest.

- [ ] **Step 3: Implement in `Sources/NyxCore/Shell/CommandBlock.swift`**

```swift
public extension CommandBlockChrome {
    /// Free columns after the command's last glyph. W3 ≥ 34, W2 18…33, W1 8…17, W0 < 8 (§2.6).
    enum WidthClass: Equatable { case w3, w2, w1, w0 }

    static func widthClass(freeColumns: Int) -> WidthClass {
        switch freeColumns {
        case 34...: return .w3
        case 18...33: return .w2
        case 8...17: return .w1
        default: return .w0
        }
    }

    /// The last column of a row that has anything in it -- **counting the second half of a wide
    /// glyph**, which has no content of its own. `Renderer.lastUsed` ignores it (D19), and a strip
    /// placed from that count began on top of the 世 it was avoiding.
    static func lastUsedColumn(of row: Row) -> Int {
        var last = -1
        for (column, cell) in row.cells.enumerated()
        where cell.content != 0 || cell.attrs.contains(.wideSpacer) {
            last = column
        }
        return last
    }

    static func freeColumns(cols: Int, lastUsedColumn: Int) -> Int {
        max(0, cols - lastUsedColumn - 1)
    }

    /// One control on the strip. What each one says is here rather than in the view, because a
    /// tooltip that disagrees with a VoiceOver label is two controls with one shape.
    enum Pill: Equatable, Hashable {
        public enum FoldLabel: Equatable, Hashable { case fold, unfold }
        public enum Actions: Equatable, Hashable { case labelled, glyph }
        public enum Glyph: Equatable, Hashable { case ellipsis, chevronDown }
        case fold(FoldLabel)
        /// `enabled` is `BlockHeader.hasOutput`: the pill and the ⋯ menu's `Copy Output` row answer
        /// to one bit. The table gives a block with nothing to copy the no-output row, so no plan
        /// built today carries a disabled Copy -- and if one ever does, it draws as disabled rather
        /// than beeping.
        case copy(enabled: Bool)
        case lens(name: String, on: Bool)
        case stop
        case actions(Actions)

        public var title: String {
            switch self {
            case .fold(.fold): return "Fold"
            case .fold(.unfold): return "Unfold"
            case .copy: return "Copy"
            case .lens(let name, _): return name
            case .stop: return "Stop"
            case .actions(.labelled): return "Actions"
            case .actions(.glyph): return ""
            }
        }

        public var glyph: Glyph? { if case .actions(.glyph) = self { return .ellipsis } else { return nil } }

        /// A `▾` after the title, drawn as an 8 pt path rather than set as a 5 pt text glyph -- the
        /// measured reason the old chevron read as "weak because of size" (design §2.7).
        public var trailingChevron: Bool {
            switch self {
            case .actions(.labelled), .lens: return true
            default: return false
            }
        }

        public var help: String {
            switch self {
            case .fold(.fold): return "Fold this command\u{2019}s output"
            case .fold(.unfold): return "Unfold this command\u{2019}s output"
            case .copy: return "Copy this command\u{2019}s output"
            case .lens: return "Choose how this response is shown"
            case .stop: return "Stop watching this request"
            case .actions: return "Command actions"
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .lens(let name, let on): return on ? "Response lens: \(name)" : "Show this response as \(name)"
            case .actions: return "Command actions"
            default: return title
            }
        }
    }

    /// What is on the strip, before anyone knows where it goes.
    struct StripContent: Equatable {
        public let readout: String
        public let readoutTone: SummaryTone
        public let dots: [WatchSeries.Dot]
        public let overflowDot: String?
        public let pills: [Pill]
        public init(readout: String, readoutTone: SummaryTone, dots: [WatchSeries.Dot],
                    overflowDot: String?, pills: [Pill]) {
            self.readout = readout; self.readoutTone = readoutTone; self.dots = dots
            self.overflowDot = overflowDot; self.pills = pills
        }
    }

    /// That content, placed: which column it begins at and whether it is allowed to sit on the
    /// command's own text.
    struct StripPlan: Equatable {
        public let content: StripContent
        public let firstColumn: Int
        public let overlapsCommand: Bool
        public init(content: StripContent, firstColumn: Int, overlapsCommand: Bool) {
            self.content = content; self.firstColumn = firstColumn; self.overlapsCommand = overlapsCommand
        }
        public var readout: String { content.readout }
        public var readoutTone: SummaryTone { content.readoutTone }
        public var dots: [WatchSeries.Dot] { content.dots }
        public var overflowDot: String? { content.overflowDot }
        public var pills: [Pill] { content.pills }
    }

    struct StripPlacement: Equatable {
        public let row: Int
        public let plan: StripPlan
        public init(row: Int, plan: StripPlan) { self.row = row; self.plan = plan }
    }

    /// The pills, longest kept first: `Stop` → `Actions` (which collapses from `Actions ▾` to
    /// `⋯` before any pill is dropped) → the lens chip when HTTP, or `Unfold` when folded → `Copy`
    /// → `Fold` → the dots. `Stop` and `Actions` are present at every width.
    ///
    /// A watched block takes `Stop` and never the lens chip: the two would share the one rung under
    /// Actions, and the lens stays in the ⋯ menu (§3.13). A watched block shows no fold pill
    /// either -- §2.6's two watch rows have none, because a series' newest run is the thing being
    /// read.
    static func pills(_ header: BlockHeader, at width: WidthClass) -> [Pill] {
        let watching = header.watch?.showsStop == true
        let watched = header.watch != nil
        let lensable = header.isHTTP && !header.lensTooLarge && (header.bodyIsJSON || header.lens != nil)
        // W0 is the row that costs a column of the user's own text, so only the one control with a
        // running side effect earns it.
        guard width != .w0 else { return watching ? [.stop] : [] }
        guard width != .w1 else { return watching ? [.stop, .actions(.glyph)] : [.actions(.glyph)] }

        // The rung under Actions: whichever of Stop, the lens chip and Unfold applies, and Copy
        // when none does. At W3 the rest of the ladder is added below it.
        var list: [Pill] = []
        if watching {
            list.append(.stop)
        } else if !watched, lensable {
            list.append(.lens(name: (header.lens ?? .pretty).chipTitle, on: header.lens != nil))
        } else if header.folded, header.hasOutput {
            list.append(.fold(.unfold))
        }
        if width == .w3 {
            // Fold is the widest labelled duplicate of a control the gutter already offers, so it
            // is the first pill to go; a folded block already carries `Unfold` above.
            if header.hasOutput, !watched, !header.folded { list.append(.fold(.fold)) }
            if header.hasOutput { list.append(.copy(enabled: header.hasOutput)) }
        } else if list.isEmpty, header.hasOutput, !watched {
            // W2 with no Stop, no chip and nothing folded: Copy is what the rung carries.
            list.append(.copy(enabled: header.hasOutput))
        }
        list.append(.actions(.labelled))
        return list
    }

    /// The readout, longest first: the whole sentence → drop the interval and the percentiles →
    /// drop the timing and the size → drop the run count → **the status or exit code alone, never
    /// dropped while a strip is drawn at all**.
    ///
    /// Dropping only ever removes whole ` · ` groups: §1 protects the vocabulary, so the sentence
    /// is cut, never re-worded. The one non-positional rule is a finished series' failure count --
    /// `11 runs` on its own says a series went fine, which is the sentence's whole news.
    static func readout(_ header: BlockHeader, at width: WidthClass) -> String {
        let parts = header.summary.components(separatedBy: " \u{b7} ")
        switch width {
        case .w3: return header.summary
        case .w2:
            if parts.count > 2, let first = parts.first, let last = parts.last, isFailureCount(last) {
                return first + " \u{b7} " + last
            }
            return parts.prefix(2).joined(separator: " \u{b7} ")
        case .w1: return parts.first ?? ""
        case .w0: return ""
        }
    }

    private static func isFailureCount(_ part: String) -> Bool {
        part.hasSuffix(" failure") || part.hasSuffix(" failures")
    }

    static func stripContent(_ header: BlockHeader, at width: WidthClass) -> StripContent? {
        let list = pills(header, at: width)
        guard !list.isEmpty else { return nil }
        // Thirty circles is the widest thing on the strip and the least of what it says, so the
        // timeline goes at the first squeeze -- the sentence beside it still carries the run number
        // and the last status.
        let dots = width == .w3 ? (header.watch?.dots ?? []) : []
        let hidden = width == .w3 ? (header.watch?.hiddenRuns ?? 0) : 0
        return StripContent(readout: readout(header, at: width), readoutTone: header.tone,
                            dots: dots, overflowDot: hidden > 0 ? "+\(hidden)" : nil, pills: list)
    }

    /// Where a measured strip begins, or nil when it may not be drawn on this row at all.
    static func stripPlan(_ content: StripContent, widthClass: WidthClass,
                          lastUsedColumn: Int, cols: Int, stripColumns: Int) -> StripPlan? {
        guard stripColumns > 0, stripColumns <= cols else { return nil }
        let first = cols - stripColumns
        // The only content W0 ever produces is the lone Stop, and stopping a runaway watch must
        // always be one click: it is drawn over the command's tail on an opaque pill.
        let overlaps = widthClass == .w0
        guard overlaps || first > lastUsedColumn else { return nil }
        return StripPlan(content: content, firstColumn: max(0, first), overlapsCommand: overlaps)
    }

    /// Whether the strip on `stripRow` speaks for the summary that would have gone on
    /// `summaryRow`, and may therefore replace it.
    ///
    /// Two rows of a wrapped command are two different width classes: a watched `curl` whose last
    /// row is full places its lone `Stop` there (W0, no readout at all) while the summary belongs
    /// on the roomier row above. Suppressing on "a strip exists somewhere on this block" then took
    /// `run 12 · 200 · 100 ms · every 5 s` off the screen the moment the pointer arrived -- the
    /// exact defect §2.5 exists to end. So: the same row, and something to say.
    static func suppressesSummary(_ plan: StripPlan, stripRow: Int, summaryRow: Int?) -> Bool {
        !plan.readout.isEmpty && stripRow == summaryRow
    }

    /// Which row of the command carries the strip, walked from the last upwards -- the same ladder
    /// and the same rows the summary uses, because a wrapped `curl` fills its first rows and leaves
    /// room on its last. `measure` is the view's own width for that content, in columns.
    static func stripPlacement(_ header: BlockHeader,
                               commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                               cols: Int,
                               measure: (StripContent) -> Int) -> StripPlacement? {
        for row in commandRows.reversed() {
            let width = widthClass(freeColumns: freeColumns(cols: cols, lastUsedColumn: row.lastUsedColumn))
            guard let content = stripContent(header, at: width),
                  let plan = stripPlan(content, widthClass: width, lastUsedColumn: row.lastUsedColumn,
                                       cols: cols, stripColumns: measure(content)) else { continue }
            return StripPlacement(row: row.absoluteRow, plan: plan)
        }
        return nil
    }

    /// The mark at the head of the spine: what shape it is, what colour, and whether it can be
    /// pressed. Shape rather than colour alone, because colour is the one thing a mark cannot say
    /// on its own (a11y 6.2).
    struct GutterCap: Equatable {
        public enum Shape: Equatable {
            /// A rounded capsule inset from the row's top and bottom: the command succeeded.
            case solid
            /// The full row height, square ends, so failures join up down a scrolling screen and
            /// carry more ink than successes -- the state that has to be findable.
            case bar
            /// A stroked capsule: still running.
            case hollow
            /// `solid` at 40 % and not pressable: a command that printed nothing to fold.
            case faded
            case chevronDown, chevronRight
        }
        public let shape: Shape
        public let tone: SummaryTone
        public let isPressable: Bool
        public init(shape: Shape, tone: SummaryTone, isPressable: Bool) {
            self.shape = shape; self.tone = tone; self.isPressable = isPressable
        }
    }

    static func gutterCap(_ header: BlockHeader, hasStarted: Bool, hovered: Bool) -> GutterCap? {
        // The prompt you are typing at carries a prompt mark and no status. Nothing is drawn there:
        // a mark that appeared the instant you pressed return would be a spinner, and the gutter is
        // a record.
        guard hasStarted else { return nil }
        // The command's own outcome, not the response's: a `curl` that reported 404 exited 0, and
        // the gutter says what the command did. The strip's tone is where a 404 goes red.
        let tone: SummaryTone = header.failed ? .failure : (header.isRunning ? .running : .success)
        guard header.hasOutput else { return GutterCap(shape: .faded, tone: tone, isPressable: false) }
        if hovered {
            return GutterCap(shape: header.folded ? .chevronRight : .chevronDown, tone: tone,
                             isPressable: true)
        }
        if header.failed { return GutterCap(shape: .bar, tone: tone, isPressable: true) }
        if header.isRunning { return GutterCap(shape: .hollow, tone: tone, isPressable: true) }
        return GutterCap(shape: .solid, tone: tone, isPressable: true)
    }

    /// The mark and the spine are one shape: the renderer and the gutter view read these two
    /// numbers, so the Metal spine and the AppKit cap cannot drift apart.
    /// **Replaces `CommandBlock.swift:111-112`**, which declared `spineWidth: Double = 2` beside a
    /// `spineGap: Double = 4` that the renderer never read (it computed `padding - 3` by hand).
    /// `spineGap` is deleted outright: it has no callers, and `spineLeadingInset` is the number the
    /// gap was standing in for.
    static let spineWidth: Double = 3
    /// 4 pt at the shipping `padding = 8`, which is outside the window's resize margin; 0 at
    /// `padding = 0`, where the mark draws over the first text column's leading 3 pt rather than
    /// off the window (Addendum 2).
    static func spineLeadingInset(padding: Double) -> Double { min(4, max(0, padding - 3)) }
    /// Every row-height *hit* target, clamped so `line-height = 0.8` cannot make it 13 pt (§8.4).
    /// The *drawn* mark stays `cellHeight` tall.
    static func hitRowHeight(cellHeight: Double) -> Double { max(cellHeight, 16) }
    static let stripHeight: Double = 20
    /// The strip's frame: tall enough for its pills and never below the hit floor. Decided here
    /// rather than from `stack.fittingSize`, which is what `Pane.blockHeaderChanged` used.
    static func stripFrameHeight(cellHeight: Double) -> Double {
        max(stripHeight, hitRowHeight(cellHeight: cellHeight))
    }
    /// What the strip actually *paints*: one row, whatever its frame is. A 20 pt opaque band on a
    /// 13 pt grid covers three rows of somebody's output (Addendum 2).
    static func stripGroundHeight(cellHeight: Double) -> Double { cellHeight }
    /// Column 0's fold triangle, widened to the same 20 pt the gutter uses, for the same reason.
    static let foldColumnWidth: Double = 20
}
```

  In `Sources/NyxCore/HTTP/ResponseLens.swift`, beside `title`:

```swift
    /// The short head of `title`, for the strip's chip: `Pretty JSON` is a menu row and `Pretty` is
    /// a 44 pt pill. One value, so a lens cannot end up with a third spelling.
    public var chipTitle: String {
        switch self {
        case .raw: return "Raw"
        case .pretty: return "Pretty"
        case .headers: return "Headers"
        case .body: return "Body"
        case .filter: return "Filter"
        case .grep: return "Find"
        case .diff: return "Diff"
        }
    }
```

  The doc comment at `WatchSeries.swift:84-88` says the menu row ("every 5 s") and the header the user then reads ("watch every 5 s") "have to be the same words". With the re-order they finally are, because the header's leading `watch ` **goes**: the dots and the `Stop` pill say a watch is running, and the verb's home is the menu titles and the popover (§3.14). Update the comment to say so — a comment left describing the old sentence is the next reader's bug report.

  In `Sources/NyxCore/HTTP/WatchSeries.swift`: add `public let hiddenRuns: Int` to `WatchHeader` with `hiddenRuns: Int = 0` last in `init` (so every existing caller compiles); set it in `header(dots:)` as `hiddenRuns: max(0, runs.count - n)`; and re-order the running `headerText` so the interval is last:

```swift
        var parts: [String] = []
        if !runs.isEmpty { parts.append("run \(runs.count)") }
        if let last = lastCompletedRun {
            if let status = last.status { parts.append("\(status)") }
            if let time = HTTPSummary.timeText(last.timeTotal) { parts.append(time) }
            if last.exitStatus != 0 { parts.append("exit \(last.exitStatus)") }
        }
        // Last, not first: the readout ladder drops from the right, and the interval is the first
        // thing a narrow strip can do without (§2.6's W2 cell reads `run 12 · 200`).
        parts.append(plan.title)
        return parts.joined(separator: " \u{b7} ")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter "CommandBlockChrome|WatchSeries|ResponseLens"`
Expected: PASS. Then `swift build 2>&1 | grep -c warning:` → `0`, and `swift test --no-parallel` for the whole suite (the `headerText` re-order touches `WatchSeriesTests` and `GridScene.watchHeader`; fix any assertion that names the old order **by updating the expectation, not the code**).

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Shell/CommandBlock.swift Sources/NyxCore/HTTP/ResponseLens.swift \
        Sources/NyxCore/HTTP/WatchSeries.swift Tests/NyxCoreTests/CommandBlockChromeTests.swift \
        Tests/NyxCoreTests/WatchSeriesTests.swift Tests/NyxCoreTests/ResponseLensTests.swift
git commit -m "$(cat <<'MSG'
One table for the block's chrome: four widths, two ladders, one mark

`CommandBlockChrome` answers what is drawn on a block and where, instead of four call sites
answering separately. `widthClass` indexes §2.6's table by the free columns after the command's
last glyph -- counting the second half of a wide glyph, which `Renderer.lastUsed` does not, so a
strip could begin on top of the 世 it was avoiding. Two ladders reproduce the table cell by cell:
pills drop `Stop` → `Actions` (which collapses to `⋯` before any pill goes) → the lens chip or
`Unfold` → `Copy` → `Fold` → the dots, and the readout drops the interval and the percentiles, then
the timing and the size, then the run count -- never the status, which is the inverse of today,
where a recoverable Copy outlived the unrecoverable exit code.

`gutterCap` gives the mark a shape per state rather than a colour alone, and `spineWidth`,
`spineLeadingInset`, `hitRowHeight` and `stripFrameHeight` are the four numbers the Metal spine, the
AppKit cap and every one-row hit target will read, so they cannot drift apart.

A watch's running sentence is re-ordered to `run 12 · 200 · 100 ms · every 5 s`: the ladder drops
from the right, and the interval is the first thing a narrow strip can do without. `WatchHeader`
gains `hiddenRuns`, so a timeline at 48 runs can say `+18` instead of capping in silence.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: The gutter is the head of the spine

**Files:**
- Modify: `Sources/NyxCore/Shell/PromptGutter.swift:60-95` (`hitWidth` and `markedRow`; delete `maximumWidth`, `markWidth`, `markInset`, `minimumPadding`, `width(padding:)`, `markRect(gutterWidth:)`)
- Modify: `Sources/NyxApp/PromptGutterView.swift` (whole file: caps, the hover chevron, the 20 pt target)
- Modify: `Sources/NyxRender/Renderer.swift:503-517` (the spine at `spineLeadingInset` × `spineWidth`)
- Modify: `Sources/NyxApp/Pane.swift` — `render()`'s gutter arrays (`:1707-1717`, `:1955-1980`, `:2223-2226`), `layoutGutter()` (`:3501-3507`), `layoutStickyStrip()`'s `left` (`:3567-3570`), and `mouseUp`'s call to `foldBlock(atPointInPadding:)` (`:2693-2695`, and the method at `:2704-2721`, both **deleted**)
- Modify: `Sources/NyxApp/{UISnapshot,StateSnapshot,GridSnapshot}.swift` — the three places that build a `PromptGutterView`
- Test: `Tests/NyxCoreTests/PromptGutterTests.swift` — add the two cases below and **delete `:85-94`** (`theGutterFitsInsideThePadding`) and **`:354-379`** (`theGutterIsWiderThanItsMark`), which assert `width(padding:)`, `maximumWidth` and `markRect(gutterWidth:)`, every one of which this task removes; `Tests/NyxRenderTests/BlockChromeRenderTests.swift`

**Interfaces:**
- Consumes: `CommandBlockChrome.GutterCap`, `.spineWidth`, `.spineLeadingInset(padding:)`, `.hitRowHeight(cellHeight:)`, `.gutterCap(_:hasStarted:hovered:)`; `GutterMarkLabel.text(mark:folded:hasOutput:line:)`; `BlockHeader`.
- Produces:

```swift
public enum PromptGutter {
    /// The hit area, 20 pt, independent of `padding` and allowed to overlap the first text column.
    public static let hitWidth: Double = 20
    /// Which marked row a point belongs to, with the rows' clamped rects overlapping: the nearer
    /// centre wins, and a tie goes to the upper row.
    public static func markedRow(atY y: Double, cellHeight: Double, padding: Double,
                                 hitHeight: Double, markedRows: [Int]) -> Int?
    public static func row(atY:cellHeight:padding:rows:) -> Int?    // unchanged, still used by the view
}

final class PromptGutterView: NSView {   // NyxApp
    var onSelectRow: ((Int, Bool) -> Void)?
    @discardableResult
    func update(caps: [Int: CommandBlockChrome.GutterCap], labels: [Int: String],
                palette: Palette, cellHeight: CGFloat, padding: CGFloat, topPadding: CGFloat) -> Bool
}
```

- [ ] **Step 1: Write the failing Core test** — add to `Tests/NyxCoreTests/PromptGutterTests.swift`

```swift
/// The target is 20 pt whatever the padding is. At the shipping `padding = 8` the real target was
/// 8 pt wide and 13 pt tall at `line-height 0.8` -- half what the code claimed (a11y 6.1).
@Test func theGutterTargetIsTwentyPointsWhateverThePadding() {
    #expect(PromptGutter.hitWidth == 20)
}

/// A clamped 16 pt rect on a 13 pt row overhangs its neighbours. Two prompts with nothing between
/// them therefore have overlapping targets, and the point goes to the nearer centre.
@Test func overlappingMarkTargetsGoToTheNearerCentre() {
    let rows = [3, 4]
    // Row 3's centre is 45.5, row 4's is 58.5, and the 16 pt rects overlap between 50.5 and 53.5.
    #expect(PromptGutter.markedRow(atY: 46, cellHeight: 13, padding: 0, hitHeight: 16,
                                   markedRows: rows) == 3)
    #expect(PromptGutter.markedRow(atY: 53, cellHeight: 13, padding: 0, hitHeight: 16,
                                   markedRows: rows) == 4)
    // Exactly between the two centres: the upper row, deterministically.
    #expect(PromptGutter.markedRow(atY: 52, cellHeight: 13, padding: 0, hitHeight: 16,
                                   markedRows: rows) == 3)
    // Above both rects: the pane's, not the gutter's.
    #expect(PromptGutter.markedRow(atY: 10, cellHeight: 13, padding: 0, hitHeight: 16,
                                   markedRows: rows) == nil)
    // An unmarked row claims nothing however close the point is to its middle.
    #expect(PromptGutter.markedRow(atY: 6, cellHeight: 13, padding: 0, hitHeight: 16,
                                   markedRows: [3]) == nil)
    // The top padding shifts every rect with it.
    #expect(PromptGutter.markedRow(atY: 46 + 8, cellHeight: 13, padding: 8, hitHeight: 16,
                                   markedRows: rows) == 3)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter PromptGutter`
Expected: FAIL — `type 'PromptGutter' has no member 'hitWidth'`.

- [ ] **Step 3: Implement the Core half**

```swift
public enum PromptGutter {
    /// The **hit area**: 20 points, the same target the fold triangles of §2.4 get, independent of
    /// `padding` and allowed to overlap the first text column. `PromptGutterView.hitTest` already
    /// hands back every point that is not on a mark, so the columns of text under it keep their
    /// clicks; what changes is that a pointer reaching for a mark no longer has to find 8 points of
    /// padding at the window's own resize margin.
    ///
    /// The *drawn* mark is `CommandBlockChrome.spineWidth` wide at `spineLeadingInset`, which is
    /// where the Metal spine is: one shape, one fact.
    public static let hitWidth: Double = 20

    /// The marked row a point falls on, or nil for a point that belongs to the pane.
    ///
    /// Each marked row's target is `hitHeight` tall, centred on the row -- `hitRowHeight` clamps it
    /// to 16 pt, so at `line-height 0.8` it overhangs the rows above and below. Those are usually
    /// output rows with no mark of their own; where two marks' rects genuinely overlap (two prompts
    /// with nothing between them) the nearer centre wins, and an exact tie goes to the upper row so
    /// the answer never depends on the order `markedRows` arrives in.
    public static func markedRow(atY y: Double, cellHeight: Double, padding: Double,
                                 hitHeight: Double, markedRows: [Int]) -> Int? {
        guard cellHeight > 0, hitHeight > 0 else { return nil }
        var best: (row: Int, distance: Double)?
        for row in markedRows.sorted() {
            let centre = padding + (Double(row) + 0.5) * cellHeight
            let distance = abs(y - centre)
            guard distance <= hitHeight / 2 else { continue }
            if best == nil || distance < best!.distance { best = (row, distance) }
        }
        return best?.row
    }
}
```

- [ ] **Step 4: Run the Core test to verify it passes**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter PromptGutter`
Expected: PASS.

- [ ] **Step 5: Draw the caps — rewrite `PromptGutterView`'s state, drawing, hit test and accessibility**

```swift
    private var caps: [Int: CommandBlockChrome.GutterCap] = [:]
    private var labels: [Int: String] = [:]
    private var palette = Palette.xtermDefault()
    private var cellHeight: CGFloat = 1
    private var panePadding: CGFloat = 8
    private var topPadding: CGFloat = 0

    private var hitHeight: CGFloat {
        CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cellHeight)))
    }
    private var markX: CGFloat {
        CGFloat(CommandBlockChrome.spineLeadingInset(padding: Double(panePadding)))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local),
              PromptGutter.markedRow(atY: Double(local.y), cellHeight: Double(cellHeight),
                                     padding: Double(topPadding), hitHeight: Double(hitHeight),
                                     markedRows: Array(caps.keys)) != nil
        else { return nil }
        return self
    }

    @discardableResult
    func update(caps: [Int: CommandBlockChrome.GutterCap], labels: [Int: String],
                palette: Palette, cellHeight: CGFloat, padding: CGFloat, topPadding: CGFloat) -> Bool {
        let changed = caps != self.caps || labels != self.labels || palette != self.palette
            || cellHeight != self.cellHeight || padding != self.panePadding
            || topPadding != self.topPadding
        guard changed else { return false }
        let previous = pressableRows()
        let geometryMoved = cellHeight != self.cellHeight || topPadding != self.topPadding
            || padding != self.panePadding
        self.caps = caps; self.labels = labels; self.palette = palette
        self.cellHeight = cellHeight; self.panePadding = padding; self.topPadding = topPadding
        needsDisplay = true
        removeAllToolTips()
        for (row, _) in caps {
            addToolTip(rect(of: row), owner: (labels[row] ?? "") as NSString, userData: nil)
        }
        return pressableRows() != previous || geometryMoved
    }

    /// The target: 20 pt wide, `hitRowHeight` tall, centred on the row. The rect the *tooltip*, the
    /// *cursor rect* and the *accessibility element* all use, so the three cannot disagree about
    /// where a mark is.
    private func rect(of row: Int) -> NSRect {
        let centre = topPadding + (CGFloat(row) + 0.5) * cellHeight
        return NSRect(x: 0, y: centre - hitHeight / 2, width: CGFloat(PromptGutter.hitWidth),
                      height: hitHeight)
    }

    private func pressableRows() -> [Int] { caps.filter { $0.value.isPressable }.keys.sorted() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cellHeight > 0 else { return }
        let width = CGFloat(CommandBlockChrome.spineWidth)
        for (row, cap) in caps {
            let y = topPadding + CGFloat(row) * cellHeight
            let colour = nsColor(cap.tone.color(in: palette), alpha: cap.shape == .faded ? 0.4 : 1)
            switch cap.shape {
            case .solid, .faded:
                // Inset top and bottom, so a cap reads as one command's mark and a run of them
                // reads as several -- the bar below is the shape that joins up.
                let box = NSRect(x: markX, y: y + 2, width: width, height: max(1, cellHeight - 4))
                colour.setFill()
                NSBezierPath(roundedRect: box, xRadius: width / 2, yRadius: width / 2).fill()
            case .bar:
                // The full row: a failure carries more ink than a success, because a failure is
                // what has to be findable while scrolling (design §3.2, over a11y 6.2's half mark).
                colour.setFill()
                NSBezierPath(rect: NSRect(x: markX, y: y, width: width, height: cellHeight)).fill()
            case .hollow:
                let box = NSRect(x: markX, y: y + 2, width: width, height: max(1, cellHeight - 4))
                colour.setStroke()
                let ring = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: width / 2, yRadius: width / 2)
                ring.lineWidth = 1
                ring.stroke()
            case .chevronDown, .chevronRight:
                // The only new mark this wave draws, and only under the pointer: an 8 pt path, in
                // the block's own colour, in place of the cap. Nothing is added at idle.
                colour.setFill()
                chevron(pointingDown: cap.shape == .chevronDown,
                        in: NSRect(x: markX, y: y + (cellHeight - 8) / 2, width: 8, height: 8)).fill()
            }
        }
    }

    /// A filled triangle, drawn as a path rather than set as a glyph: the 5 pt `▾` in a 20 pt pill
    /// is exactly what the design review measured as "weak because of size".
    private func chevron(pointingDown: Bool, in box: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        if pointingDown {
            path.move(to: NSPoint(x: box.minX, y: box.minY))
            path.line(to: NSPoint(x: box.maxX, y: box.minY))
            path.line(to: NSPoint(x: box.midX, y: box.maxY))
        } else {
            path.move(to: NSPoint(x: box.minX, y: box.minY))
            path.line(to: NSPoint(x: box.minX, y: box.maxY))
            path.line(to: NSPoint(x: box.maxX, y: box.midY))
        }
        path.close()
        return path
    }
```

  `mouseDown`, `accessibilityChildren` and `resetCursorRects` change to the same shape: resolve the row through `PromptGutter.markedRow(atY:…)` with `Array(caps.keys)`, hand a press on a non-pressable cap back to the pane exactly as today (`forwardingToPane`), and build each element and cursor rect from `rect(of:)`. The `label(for:row:)` helper is replaced by `labels[row]`, whose text is still `GutterMarkLabel.text(...)` — built in the pane, where the header is.

- [ ] **Step 6: Draw the spine at the same two numbers — `Sources/NyxRender/Renderer.swift`**

```swift
        for spine in f.blockSpines {
            guard !spine.rows.isEmpty else { continue }
            let top = Float(padding + spine.rows.lowerBound * m.height)
            let height = Float(spine.rows.count * m.height)
            // The head of this shape is the gutter's cap, drawn by AppKit at the same x and the
            // same width: `CommandBlockChrome` owns both numbers, so a green line with beads on it
            // 1.5 pt apart cannot come back. At `padding = 0` the inset is 0 and the spine takes
            // the first text column's leading 3 pt rather than not being drawn at all -- a block
            // with no spine is a block with no left edge (Addendum 2).
            // The old `guard padding >= 4 else { continue }` goes with this: a block with no left
            // edge is not a quieter block, it is a block with no left edge.
            let x = Float(CommandBlockChrome.spineLeadingInset(padding: Double(padding)))
            instances.append(rect(x, top, Float(CommandBlockChrome.spineWidth), height, spine.color))
        }
```

  And rewrite the two `BlockChromeRenderTests` cases that assert the old geometry:

```swift
/// The spine is 3 pt wide at `spineLeadingInset`, which is 4 pt in at the shipping padding -- off
/// the window's resize margin and exactly where the gutter's cap is drawn.
@Test func aSpineIsThreePointsWideBesideItsRows() throws {
    let (fonts, _, px) = try render(padding: 8, spines: [(rows: 0..<2, color: spineColor)])
    let y = 8 + fonts.metrics.height / 2
    #expect(px(4, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(6, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(2, y) != Pixel(r: 0, g: 255, b: 0))
    #expect(px(8, y) != Pixel(r: 0, g: 255, b: 0))
    #expect(px(4, 8 + fonts.metrics.height * 2 + fonts.metrics.height / 2) != Pixel(r: 0, g: 255, b: 0))
}

/// `padding = 0` is a setting the settings window ships. The spine takes the first column's leading
/// 3 pt there rather than disappearing: without it a block loses its left edge entirely, which is
/// what the second snapshot pass found (Addendum 2).
@Test func atZeroPaddingTheSpineTakesTheFirstColumnsLeadingEdge() throws {
    let (fonts, _, px) = try render(padding: 0, spines: [(rows: 0..<3, color: spineColor)])
    let y = fonts.metrics.height / 2
    #expect(px(0, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(2, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(4, y) != Pixel(r: 0, g: 255, b: 0))
}
```

  (`theSpineLeavesTheLeftmostPaddingToTheGutter` is **deleted**: the spine and the cap are now deliberately the same shape at the same x, and the test asserted the opposite.)

- [ ] **Step 7: Wire the pane**

In `render()`'s frame builder, replace the four gutter arrays with two dictionaries built from the blocks that are already being walked for `summaries`:

```swift
        var gutterCaps: [Int: CommandBlockChrome.GutterCap] = [:]
        var gutterLabels: [Int: String] = [:]
        // … inside the `blocks.compactMap` that builds the headers, after `header` is made:
        if let cap = CommandBlockChrome.gutterCap(header,
                                                  hasStarted: t.commandDidStart(atAbsoluteRow: block.region.promptRow),
                                                  hovered: self.hoveredBlock?.id == block.region.id) {
            gutterCaps[promptSlot] = cap
            gutterLabels[promptSlot] = GutterMarkLabel.text(
                mark: block.failed ? .failed : (block.isRunning ? .running : .succeeded),
                folded: header.folded, hasOutput: header.hasOutput, line: promptSlot + 1)
        }
```

  and after the lock:

```swift
        if gutter.update(caps: gutterCaps, labels: gutterLabels, palette: frame.palette,
                         cellHeight: cellSizePoints.height, padding: padding, topPadding: padding) {
            window?.invalidateCursorRects(for: gutter)
        }
```

  Three more callers of the deleted `PromptGutter.width(padding:)`: `GridSnapshot.swift:466` (the gutter composite's own width, which becomes `CGFloat(PromptGutter.hitWidth)`), `GridSnapshot.swift:482` (the sticky strip's `left`, which becomes `max(padding, CGFloat(PromptGutter.hitWidth))` exactly as `Pane.layoutStickyStrip` does), and the comment at `GridSnapshot.swift:97`, which cites `PromptGutter.width(padding:)` as one of the two numbers the extreme-metric composites exist for — it now cites `PromptGutter.hitWidth` and `CommandBlockChrome.spineLeadingInset`.

  `layoutGutter()` becomes a fixed 20 pt column that is never hidden (`gutter.frame = NSRect(x: 0, y: 0, width: CGFloat(PromptGutter.hitWidth), height: bounds.height)`), and `layoutStickyStrip()`'s `left` becomes `max(padding, CGFloat(PromptGutter.hitWidth))`. `Terminal.gutterMarks`, `foldStates`, `commandStates` and `startStates` keep their tests and their other callers; the pane simply stops asking for the per-row arrays. **Delete** `Pane.foldBlock(atPointInPadding:)` and its call in `mouseUp`: the padding is not a control and never said it was.

  The three snapshot builders (`UISnapshot:266-280`, `StateSnapshot:85-104`, `GridSnapshot:462-478`) change to the new `update(caps:labels:…)` with a fixture dictionary — Task 8 gives them their own cases; here they only have to compile and keep rendering something.

- [ ] **Step 8: Build, test, look**

Run: `swift build 2>&1 | grep -c warning:` → `0`; `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel`; `make bench` (three times, ≥ 180).
Then `./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/shots-1a-2 ./build/Nyx.app/Contents/MacOS/Nyx` and **read** `gutter-marks-*.png` and `composite-gutter-*.png`: one mark per command, 3 pt wide, continuous into the spine below it, no second mark 1.5 pt away.

- [ ] **Step 9: Commit**

```bash
git add Sources/NyxCore/Shell/PromptGutter.swift Sources/NyxApp/PromptGutterView.swift \
        Sources/NyxRender/Renderer.swift Sources/NyxApp/Pane.swift Sources/NyxApp/UISnapshot.swift \
        Sources/NyxApp/StateSnapshot.swift Sources/NyxApp/GridSnapshot.swift \
        Tests/NyxCoreTests/PromptGutterTests.swift Tests/NyxRenderTests/BlockChromeRenderTests.swift
git commit -m "$(cat <<'MSG'
One mark, not two: the gutter cap is the head of the spine

The capsule (4.5 pt, drawn by AppKit at x≈1) and the spine (1 pt, drawn by Metal at x≈5) were two
marks in one colour 1.5 points apart, and the design review read them as a green line with beads on
it. They are now one shape: 3 pt wide at `spineLeadingInset`, cap and spine reading the same two
numbers out of `CommandBlockChrome`, continuous from the prompt row down every row the block owns.

The shape carries the state, because colour is the one thing a mark cannot say on its own: a
succeeded command gets an inset cap, a failed one the full-row bar (failure is what has to be
findable while scrolling), a running one a hollow cap, and a command that printed nothing a 40 %
cap that is not a button. On hover of any row of the block the cap becomes an 8 pt chevron -- the
only new drawing at all, and nothing is added at idle, where the gutter had no hover art whatever.

The target is 20 pt wide and `hitRowHeight` tall, independent of the padding, where it was 8 × 13 at
the shipping defaults against a comment claiming 14. Where two clamped targets overlap the nearer
centre wins. `padding = 0` no longer means no spine: it takes the first column's leading 3 pt.

And a click in the left padding no longer folds anything: `foldBlock(atPointInPadding:)` is deleted.
The padding is not a control and never said it was.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: The strip — 20 pt, labelled pills, right-aligned after the last glyph

**Files:**
- Create: `Sources/NyxApp/StripPillView.swift`
- Modify: `Sources/NyxApp/BlockHeaderView.swift` (rebuilt on `StripPlan`)
- Modify: `Sources/NyxApp/WatchDotsView.swift` (7 pt filled dots on a 10 pt pitch, running filled accent, the `+N` label)
- Modify: `Sources/NyxApp/Pane.swift` — the strip placement inside `render()` (`:2085-2115`), `blockHeaderChanged` (`:3192-3216`), `headerForHoveredBlock` (`:4133`)
- Modify: `Sources/NyxApp/UISnapshot.swift:1104-1114` — `blockStrip` sizes the view `height: rowHeight`, which is where the *pictures* of clipped pills come from: `Pane.blockHeaderChanged` (`:3207-3213`) has taken `max(rowHeight, size.height)` since the last round, so the app's frame already clears its pills and the spec's `Pane.swift:3090` citation is stale. What changes in the app is that the height is `CommandBlockChrome.stripFrameHeight` — a Core number that also clears the 16 pt floor at `line-height 0.8` — instead of an AppKit `fittingSize`, and that the painted ground is `stripGroundHeight`. What changes in the pictures is that the snapshot stops sizing the strip to one row, so a clipped pill in a picture after this task is a real defect rather than the tool's.
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift` — **delete** `OverlayControls` (`:212-236`), `OverlayPlacement` (`:238-246`), `overlayPlacement` (`:194-209`) and `BlockHeader.showsCopy/showsSummary/showsTimeline/showsStop/showsLens` (`:516-547`)
- Modify: `Sources/NyxApp/GridSnapshot.swift`, `Sources/NyxApp/UISnapshot.swift`, `Sources/NyxApp/StateSnapshot.swift` — the `OverlayControls` call sites
- Test: `Tests/NyxCoreTests/CommandBlockTests.swift` (delete the `overlayPlacement` block, `:262-380`), `Tests/NyxCoreTests/BlockHeaderTests.swift` (delete the `shows*(at:)` cases, `:425-462`)

**Interfaces:**
- Consumes: `CommandBlockChrome.{StripContent, StripPlan, StripPlacement, Pill, stripPlacement, stripFrameHeight, stripGroundHeight}`, `SummaryTone.color(in:)`, `Palette.{foreground, background, accent, textOn(_:), noteForeground, blockHoverBackground}`.
- Produces:

```swift
final class StripPillView: NSView {                                    // NyxApp
    static let height: CGFloat = 20, radius: CGFloat = 6
    static let glyphPillWidth: CGFloat = 24, glyphWidth: CGFloat = 8
    static let labelPadding: CGFloat = 16, chevronGap: CGFloat = 4, gap: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    var onPress: (() -> Void)?
    var pill: CommandBlockChrome.Pill?                                  // read by the snapshot
    func configure(_ pill: CommandBlockChrome.Pill, palette: Palette, opaque: Bool)
    func setPressedForSnapshot(_ pressed: Bool)                         // StateSnapshot's `press`
    override var intrinsicContentSize: NSSize
}

final class BlockHeaderView: NSView {                                   // NyxApp, rebuilt
    var onAction: ((BlockAction, UInt32) -> Void)?
    var onToggleFold: ((UInt32, Bool) -> Void)?
    var onNeedsPreviousRun: ((UInt32) -> Bool)?
    /// The measured width of one plan's content, in points, cached per content and font.
    func width(of content: CommandBlockChrome.StripContent, font: NSFont) -> CGFloat
    func update(header: BlockHeader?, plan: CommandBlockChrome.StripPlan?, palette: Palette,
                font: NSFont, groundHeight: CGFloat)
}
```

- [ ] **Step 1: Write the failing Core test for the placement the pane will use**

Add to `Tests/NyxCoreTests/CommandBlockChromeTests.swift`:

```swift
/// The whole point of the two-stage placement: the strip that is measured is the strip that is
/// drawn, and the row it lands on is chosen from the *measured* width rather than from a guess.
@Test func thePlacementMeasuresTheContentItPlaces() {
    let h = header(summary: "8.8s")
    var measured: [Int] = []
    let placement = CommandBlockChrome.stripPlacement(
        h, commandRows: [(absoluteRow: 4, lastUsedColumn: 20)], cols: 80,
        measure: { content in measured.append(content.pills.count); return 24 })
    #expect(placement?.plan.firstColumn == 56)
    #expect(measured == [3])          // W3: Fold, Copy, Actions -- measured once
}

/// A watch on a full command line still gets its Stop, and only its Stop.
@Test func aFullCommandLineStillStopsAWatch() {
    let watching = header(summary: "", isHTTP: true,
                          watch: WatchHeader(text: "run 12 · 200 · 100 ms · every 5 s",
                                             dots: [.running], showsStop: true, tone: .success))
    let placement = CommandBlockChrome.stripPlacement(
        watching, commandRows: [(absoluteRow: 4, lastUsedColumn: 79)], cols: 80,
        measure: { _ in 8 })
    #expect(placement?.plan.pills == [.stop])
    #expect(placement?.plan.overlapsCommand == true)
}
```

- [ ] **Step 2: Run it to verify it fails, then make it pass**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter CommandBlockChrome`
Expected: FAIL on the measured count (Task 1 measures once per row, so if this fails on anything else, the ladder is being asked twice). Fix the implementation, not the test, and re-run to PASS.

- [ ] **Step 3: Write `StripPillView`**

```swift
import AppKit
import NyxCore

/// One control on the hover strip: a 20 pt pill with a 6 pt radius, a label or an 8 pt path glyph,
/// and its own hover, pressed and on art.
///
/// Not an `NSButton`. An `.inline` bezel's hovered art is AppKit's own tracking and is unreachable
/// without a window -- which is why the round had no hovered strip picture at all -- and its
/// pressed art moves 11/255 on a dark theme, which is not a press anybody sees. Drawing the pill
/// here makes every state a value this view holds, so `StateSnapshot` can render it and a person
/// can see it.
final class StripPillView: NSView {
    static let height: CGFloat = 20
    static let radius: CGFloat = 6
    static let glyphPillWidth: CGFloat = 24
    static let glyphWidth: CGFloat = 8
    static let labelPadding: CGFloat = 16
    static let chevronGap: CGFloat = 4
    static let gap: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    var onPress: (() -> Void)?
    private(set) var pill: CommandBlockChrome.Pill?
    private var palette = Palette.xtermDefault()
    private var opaque = false
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    func configure(_ pill: CommandBlockChrome.Pill, palette: Palette, opaque: Bool) {
        guard pill != self.pill || palette != self.palette || opaque != self.opaque else { return }
        // The views are pooled: a pill that was hovered or held down as `Copy` must not come back
        // as a lit `Stop` on the next block the pointer lands on. Reused view, fresh state.
        if pill != self.pill { hovered = false; pressed = false }
        self.pill = pill
        self.palette = palette
        self.opaque = opaque
        toolTip = pill.help
        setAccessibilityLabel(pill.accessibilityLabel)
        setAccessibilityHelp(pill.help)
        // A disabled pill reports as disabled rather than as a button that beeps -- the gutter's
        // no-output mark already answers this way, through `press: nil`.
        setAccessibilityEnabled(isEnabled)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// `.copy(enabled: false)` is the one pill that can arrive inert: it draws dimmed, does not
    /// press, and offers no pointing hand.
    private var isEnabled: Bool {
        if case .copy(let enabled) = pill { return enabled }
        return true
    }

    /// `StateSnapshot` presses a pill by name; `NSButton.highlight(true)` has no equivalent here.
    func setPressedForSnapshot(_ pressed: Bool) { self.pressed = pressed; needsDisplay = true }

    override var intrinsicContentSize: NSSize {
        guard let pill else { return NSSize(width: 0, height: StripPillView.height) }
        guard pill.glyph == nil else {
            return NSSize(width: StripPillView.glyphPillWidth, height: StripPillView.height)
        }
        var width = ceil((pill.title as NSString)
            .size(withAttributes: [.font: StripPillView.font]).width) + StripPillView.labelPadding
        if pill.trailingChevron { width += StripPillView.chevronGap + StripPillView.glyphWidth }
        return NSSize(width: width, height: StripPillView.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pill else { return }
        let on = { if case .lens(_, let on) = pill { return on } else { return false } }()
        let enabled = isEnabled
        let box = NSRect(x: 0, y: 0, width: bounds.width, height: StripPillView.height)
            .offsetBy(dx: 0, dy: (bounds.height - StripPillView.height) / 2)
        let path = NSBezierPath(roundedRect: box, xRadius: StripPillView.radius,
                                yRadius: StripPillView.radius)
        // An "on" chip is the accent fill everything else in Nyx uses for "on" (the search bar's
        // scope toggle, a running quick action); the rest are a wash of the theme's own foreground,
        // which reads on every palette because it *is* the palette.
        let ink: RGB
        if on {
            nsColor(palette.accent, alpha: 1).setFill(); path.fill()
            ink = palette.textOn(palette.accent)
        } else {
            let alpha = pressed ? 0.26 : (hovered ? 0.20 : 0.14)
            if opaque {
                // The W0 `Stop`, drawn over the command's tail: an opaque pill reads as a control
                // on top of text, where a translucent one reads as text colliding with text.
                nsColor(palette.background, alpha: 1).setFill(); path.fill()
            }
            nsColor(palette.foreground, alpha: alpha).setFill(); path.fill()
            nsColor(palette.foreground, alpha: 0.22).setStroke()
            path.lineWidth = 1
            path.stroke()
            ink = enabled ? tint(of: pill) : palette.noteForeground
        }
        var x = box.minX + StripPillView.labelPadding / 2
        if let glyph = pill.glyph {
            drawGlyph(glyph, in: NSRect(x: box.midX - StripPillView.glyphWidth / 2,
                                        y: box.midY - StripPillView.glyphWidth / 2,
                                        width: StripPillView.glyphWidth,
                                        height: StripPillView.glyphWidth), colour: ink)
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: StripPillView.font,
                                                         .foregroundColor: nsColor(ink, alpha: 1)]
        let size = (pill.title as NSString).size(withAttributes: attributes)
        (pill.title as NSString).draw(at: NSPoint(x: x, y: box.midY - size.height / 2),
                                      withAttributes: attributes)
        x += ceil(size.width)
        if pill.trailingChevron {
            drawGlyph(.chevronDown,
                      in: NSRect(x: x + StripPillView.chevronGap,
                                 y: box.midY - StripPillView.glyphWidth / 2,
                                 width: StripPillView.glyphWidth, height: StripPillView.glyphWidth),
                      colour: ink)
        }
    }

    /// `Stop` is the one pill with a running side effect and keeps the theme's own red; everything
    /// else is the foreground. Through `SummaryTone`, so gruvbox-dark's 2.82:1 cannot recur.
    private func tint(of pill: CommandBlockChrome.Pill) -> RGB {
        if case .stop = pill { return SummaryTone.failure.color(in: palette) }
        return palette.foreground
    }

    private func drawGlyph(_ glyph: CommandBlockChrome.Pill.Glyph, in box: NSRect, colour: RGB) {
        nsColor(colour, alpha: 1).setFill()
        switch glyph {
        case .chevronDown:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: box.minX, y: box.midY - 2))
            path.line(to: NSPoint(x: box.maxX, y: box.midY - 2))
            path.line(to: NSPoint(x: box.midX, y: box.midY + 3))
            path.close()
            path.fill()
        case .ellipsis:
            // Three 2 pt dots across the 8 pt box: a path, not a `⋯` set at 5 pt in a 20 pt pill.
            for offset in [CGFloat(0), 3, 6] {
                NSBezierPath(ovalIn: NSRect(x: box.minX + offset, y: box.midY - 1,
                                            width: 2, height: 2)).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        // No hand over a pill that cannot be pressed: the pointing hand is a promise, and this
        // round exists to make it a true one everywhere.
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
```

- [ ] **Step 4: Rebuild `BlockHeaderView` around one `StripPlan`**

- State becomes `plan: CommandBlockChrome.StripPlan?` and `header: BlockHeader?`; the seven `NSButton`s and the `NSStackView` go. Subviews: `dots` (`WatchDotsView`), `overflow` (an `NSTextField` label for `+N`), `readout` (`NSTextField`), and a reused pool of `StripPillView`s.
- `layout()` places them right-aligned by hand: from the trailing edge inwards, 8 pt inset, then each pill at its `intrinsicContentSize` with 6 pt gaps, then the readout, then `+N`, then the dots. No Auto Layout, so the measured width and the drawn width are the same arithmetic.
- `width(of:font:)` returns exactly that sum (leading 8 pt + dots + `+N` + readout at `font`'s advance × `readout.count` + pills + gaps + 8 pt trailing), cached in the existing `WidthKey` dictionary re-keyed on `(pills, readoutCount, dots, overflowDot, font, size)` with the same 64-entry cap. This is what `Pane` hands to `CommandBlockChrome.stripPlacement`'s `measure`.
- `update(header:plan:palette:font:groundHeight:)` sets the appearance pin (unchanged: `NSAppearance(named: palette.isLight ? .aqua : .darkAqua)`), configures the pills from `plan.pills`, wires each `onPress` (see below), colours the readout with `plan.readoutTone.color(in: palette)`, and paints the ground:

```swift
        // The row's own hover tint over the terminal's background, not `palette.background`: a
        // background band on a tinted row reads as a floating rectangle (design §2.7). Opaque,
        // because the grid underneath has already drawn the tint *and the text*.
        // `blockHoverBackground` is the tint already composited over the theme's background --
        // the same opaque colour the renderer paints across the hovered rows -- so the band matches
        // the row it sits on instead of floating above it.
        let ground = nsColor(palette.blockHoverBackground, alpha: 1).cgColor
        fadeLayer.colors = [nsColor(palette.background, alpha: 0).cgColor, ground, ground]
```

  keeping the existing two-cell gradient, `paintedHeight` (now `CommandBlockChrome.stripGroundHeight(cellHeight:)`) and `placeFadeStops()`. A plan with `overlapsCommand` sets `opaque: true` on its pills and **no** gradient — the pill itself is the ground.
- Presses: `.copy` → `onAction(.copyOutput, id)`; `.stop` → `onAction(.stopWatch, id)`; `.fold` → `onToggleFold(id, ⌥ held)`; `.actions` → `morePressed()` (unchanged, still built from `menuHeader()`); `.lens` → Task 4.
- `accessibilityLabel()` stays `"Command block: \(summary)"`, and the pills are the elements.

- [ ] **Step 5: 7 pt dots and the `+N` — `WatchDotsView`**

```swift
    /// 7 pt on a 10 pt pitch (§2.3). The old 6 pt on an 8 pt pitch put thirty circles in 238 pt and
    /// read as dirt; the running one was a hollow amber ring, which shares a hue with redirect and
    /// smudged at that size. It is now a **filled accent** dot -- the same "this is the live one"
    /// colour the rest of the app uses.
    static let diameter: CGFloat = 7
    static let pitch: CGFloat = 10
```

  `draw` fills every dot, taking `palette.accent` for `.running` and `dot.tone.color(in: palette)` for the rest; `intrinsicContentSize` becomes `CGFloat(dots.count) * pitch - (pitch - diameter)`. The `+N` label is **not** in this view: `BlockHeaderView` draws it as a text field in the readout's font at the dots' own tone, so it reads as a label and not as a dot.

- [ ] **Step 6: Place the strip in the pane**

Inside `render()`'s `summaries` walk, the hovered block's branch becomes:

```swift
                // Where the summary would go if there were no strip at all, asked first so the
                // suppression rule can compare the two rows. (Task 5 removes `chevronCount:`; until
                // then it is still on the signature.)
                let summaryHere = text.isEmpty ? nil : CommandBlockChrome.summaryPlacement(
                    commandRows: candidates, textCount: text.count,
                    chevronCount: header.chevron.count, cols: t.cols)
                if self.hoveredBlock?.id == block.region.id, self.hoveredBlock?.headerRow != nil,
                   cellWidth > 0,
                   let placement = CommandBlockChrome.stripPlacement(
                        header, commandRows: candidates, cols: t.cols,
                        measure: { Int((self.blockHeader.width(of: $0, font: overlayFont) / cellWidth).rounded(.up)) }),
                   let slot = slotOf[placement.row] {
                    headers[slot] = header
                    stripSlots[block.region.id] = slot
                    self.hoverStripPlan = placement.plan
                    notesSpokenFor.insert(slot)
                    notesSpokenFor.insert(promptSlot)
                    // §2.5: the summary gives way only to a strip **on its own row that says at
                    // least as much**. A wrapped watched command whose last row is full places its
                    // lone `Stop` there and keeps its sentence on the row above; at W0, and on a
                    // row that had no room at all, there is no strip and the summary stays.
                    if CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                            summaryRow: summaryHere?.row) {
                        return nil
                    }
                }
```

  `candidates` already carries `lastUsedColumn` per row; change the two loops that compute it (here and in `workbenchHintPlacement`) to `CommandBlockChrome.lastUsedColumn(of: lines[slot])` so the wide-cell rule is not re-implemented. `hoverOverlayControls` is replaced by `hoverStripPlan: CommandBlockChrome.StripPlan?`, and `blockHeaderChanged` places the view:

```swift
        let cell = cellSizePoints
        let height = CGFloat(CommandBlockChrome.stripFrameHeight(cellHeight: Double(cell.height)))
        let top = bounds.height - padding - CGFloat(row + 1) * cell.height
        blockHeader.update(header: header, plan: plan, palette: palette, font: font,
                           groundHeight: CGFloat(CommandBlockChrome.stripGroundHeight(cellHeight: Double(cell.height))))
        blockHeader.frame = NSRect(x: padding + CGFloat(plan.firstColumn) * cell.width,
                                   y: top - (height - cell.height) / 2,
                                   width: CGFloat(cols - plan.firstColumn) * cell.width,
                                   height: height)
```

  (`cols` is the pane's own column count, kept for layout; do not take the session lock again here — `blockHeaderChanged` runs after it has been released.)

- [ ] **Step 7: Delete `OverlayControls` and everything that fed it**

`OverlayControls`, `OverlayPlacement`, `CommandBlockChrome.overlayPlacement` and `BlockHeader.showsCopy/showsSummary/showsTimeline/showsStop/showsLens` are removed with their doc comments, and so are the tests that assert them (`CommandBlockTests:262-380`, `BlockHeaderTests:425-462`) — they assert a ladder that no longer exists, and the new ladder's tests are Task 1's. `workbenchHintPlacement` loses its `overlayPlacement` call and asks directly:

```swift
        // The pill shows itself, with no pointer near it, so a command line with no room simply
        // gets no pill -- the hover strip is the only chrome that may cover text.
        let free = CommandBlockChrome.freeColumns(cols: t.cols, lastUsedColumn: row.lastUsedColumn)
        guard columns <= free else { continue }
```

  The three snapshot files lose their `OverlayControls` loops. In `GridSnapshot` that is **eight** sites, not two, and every one of them measures through the `BlockHeaderView.width(for:header:font:)` this task replaced with `width(of:font:)`:

| site | becomes |
|---|---|
| `:113` `name(of: OverlayControls) -> String` | `name(of: CommandBlockChrome.WidthClass) -> String`, emitting **exactly** `w3`, `w2`, `w1`, `w0` — plan 1b's `cmp` and §8.5's names both depend on `composite-strip-w3-finished-*` and `-w1-` |
| `:136` `Case.hoverStripOnLens` | **folded into** `StripState.lensed` |
| `:140` `Case.hoverStripWatching(runs:)` | **survives**: the 4-, 30- and (new) 48-run pictures are about the timeline's own width and its `+N` cap, which one cell of the state matrix cannot say |
| `:596` `GridScene.commandIDs: [OverlayControls: UInt32]` | `[CommandBlockChrome.WidthClass: UInt32]` |
| `:603` `GridScene.hoverControls: OverlayControls` | `hoverWidth: CommandBlockChrome.WidthClass` |
| `:622`, `:886` `strip: (slot: Int, controls: OverlayControls, header: BlockHeader)?` | `strip: (slot: Int, plan: CommandBlockChrome.StripPlan, header: BlockHeader)?` |
| `:660-661` `stripCells: [OverlayControls: Int]`, measured per control set | one measurement per width class, through `probe.width(of: content, font: probeFont)` |
| `:691-692` `byControls: [OverlayControls: UInt32]`, one command per control level | one command per width class, from `GridScene.commandFitting(_ width:)` |
| `:926-927` `stripColumns: [OverlayControls: Int]` fed to `overlayPlacement` | the `measure:` closure fed to `CommandBlockChrome.stripPlacement`, the same closure `Pane` passes |

  `GridSnapshot.Case.hoverStrip(OverlayControls)` becomes `hoverStrip(CommandBlockChrome.WidthClass, GridScene.StripState)`, where

```swift
    /// Which row of §2.6's table a composite is a picture of.
    enum StripState: String, CaseIterable {
        case finished, failed, running, folded, http, lensed
        case watchRunning = "watch-running", watchFinished = "watch-finished", noOutput = "no-output"
    }
```

  lives beside `GridScene`, and `GridScene.commandFitting(_ controls:)` becomes `commandFitting(_ width: CommandBlockChrome.WidthClass)` — a command line whose free columns land in that class (40, 24, 12 and 4 free columns for W3, W2, W1 and W0). Here they are called with `.finished` only, so the picture set does not grow before Task 8 loops over the nine states; `UISnapshot.blockStripStates()` is re-keyed the same way, from `OverlayControls` to `WidthClass`.

- [ ] **Step 8: Build, test, look**

Run: `swift build 2>&1 | grep -c warning:` → `0`; `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel`; `make bench` ≥ 180.
`NYX_UI_SNAPSHOT=/tmp/shots-1a-3 ./build/Nyx.app/Contents/MacOS/Nyx` and read `block-header-*.png` and `composite-strip-*.png`: no pill clipped top or bottom, `Copy`'s descender clear of the edge, the `⋯` a real ellipsis rather than a 5 pt glyph, and the strip beginning after the command's last glyph with the fade doing the work.

- [ ] **Step 9: Commit**

```bash
git add Sources/NyxApp/StripPillView.swift Sources/NyxApp/BlockHeaderView.swift \
        Sources/NyxApp/WatchDotsView.swift Sources/NyxApp/Pane.swift \
        Sources/NyxCore/Shell/CommandBlock.swift Sources/NyxApp/GridSnapshot.swift \
        Sources/NyxApp/UISnapshot.swift Sources/NyxApp/StateSnapshot.swift \
        Tests/NyxCoreTests/CommandBlockTests.swift Tests/NyxCoreTests/BlockHeaderTests.swift \
        Tests/NyxCoreTests/CommandBlockChromeTests.swift
git commit -m "$(cat <<'MSG'
The strip says what it does: 20 points, labelled pills, and the status last to go

The strip's pills came out clipped flat in every picture -- because `UISnapshot` sized the view to
one row, while the pane itself had grown to `max(rowHeight, fittingSize.height)` in the last round.
Both now take one number from Core, `stripFrameHeight`, which also clears the 16 pt floor at
`line-height 0.8`; what the strip *paints* is `stripGroundHeight`, one row, so an opaque band cannot
cover the rows above and below. At its narrower levels the strip offered two identical grey circles
and had dropped the exit code before dropping the second menu. It is now `StripPlan`, drawn: a 20 pt band
centred on the row, 20 pt pills with a 6 pt radius, labels at 11 pt medium, and `⋯` and `▾` as 8 pt
paths rather than 5 pt glyphs in a 24 pt pill.

Which pills survive is `CommandBlockChrome`'s table, not the view's: `Stop` and `Actions` are on
every width, `Actions ▾` collapses to `⋯` before any pill is dropped, and the readout gives up the
interval, then the percentiles, then the timing, then the run count -- never the status. The strip
is right-aligned into the free columns after the command's last glyph and never begins inside a
word; where it does not fit there is no strip and the in-grid summary stays, so hovering a block can
no longer remove the thing you were reading. The summary gives way only to a strip on its own row
that says at least as much (`suppressesSummary`) -- a wrapped watched `curl` whose last row is full
puts its lone `Stop` down there and keeps its sentence on the row above. The one exception is a running watch's `Stop` on a full
command line, which is drawn over the tail on an opaque pill: stopping a runaway watch is one click
at every width.

Pills are drawn rather than `NSButton`s, because an `.inline` bezel's hover art needs a window and
its pressed art moves 11/255 -- the round had no hovered strip picture at all. Hover, pressed and
the accent "on" chip are now this view's own state, and the snapshot can render them.

`OverlayControls`, `OverlayPlacement`, `overlayPlacement` and the five `shows…(at:)` rules are
deleted with their last callers.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: The lens chip carries the lens' name

**Files:**
- Modify: `Sources/NyxApp/BlockHeaderView.swift` (the `.lens` pill's press: the lens menu)
- Modify: `Sources/NyxApp/StripPillView.swift` (nothing new — the accent "on" art landed in Task 3; this task proves it)
- Modify: `Sources/NyxApp/UISnapshot.swift` (`block-header-lens-chip-{off,on,body,raw}` cases)
- Test: `Tests/NyxCoreTests/CommandBlockChromeTests.swift`, `Tests/NyxCoreTests/ReadableColourTests.swift`

**Interfaces:**
- Consumes: `CommandBlockChrome.Pill.lens(name:on:)`, `ResponseLens.chipTitle`, `BlockHeader.actions` (the Lens group), `Palette.accent`, `Palette.textOn(_:)`.
- Produces: nothing new in Core. `BlockHeaderView` gains `private func lensMenu(for header: BlockHeader) -> NSMenu`, built from the same `header.actions` rows the ⋯ menu uses, so the chip and the menu cannot offer different lenses.

**The one decision this task makes:** the chip carries a trailing `▾`, so pressing it **opens the lens menu** rather than toggling pretty ↔ raw the way `{ }` did. A control that draws a chevron and does not open anything is the class of lie this round exists to remove; `toggle_http_lens` (⌘⇧J) keeps the toggle, and it is the keyboard path §8.2 already lists.

- [ ] **Step 1: Write the failing tests**

```swift
/// The chip names the lens rather than drawing `{ }`, and it names the one that is *on* -- a chip
/// reading `Pretty` beside a response being read through `Headers` is the control lying about the
/// thing it controls.
@Test func theChipNamesTheLensThatIsOn() {
    func chip(_ lens: ResponseLens?) -> CommandBlockChrome.Pill? {
        let h = header(summary: "", http: HTTPSummary(text: "200 · 142 ms", tone: .success),
                       isHTTP: true, lens: lens, json: true)
        return CommandBlockChrome.pills(h, at: .w3).first
    }
    #expect(chip(nil) == .lens(name: "Pretty", on: false))
    #expect(chip(.pretty) == .lens(name: "Pretty", on: true))
    #expect(chip(.headers) == .lens(name: "Headers", on: true))
    #expect(chip(.body) == .lens(name: "Body", on: true))
    #expect(chip(.grep("alpha")) == .lens(name: "Find", on: true))
    // The chevron says a menu opens; every chip carries one, because every lens has neighbours.
    #expect(CommandBlockChrome.Pill.lens(name: "Pretty", on: false).trailingChevron)
}
```

  And, in `Tests/NyxCoreTests/ReadableColourTests.swift`, the floor the "on" state has to clear in every theme (D6, snapshot §3.4, where gruvbox-dark's lit `{ }` measured 2.82:1):

```swift
/// The lens chip's on-state is `accent` filled with `textOn(accent)` ink. That ink is the only
/// thing on a filled chip, so it is text and holds to 4.5:1 -- in all seven built-in themes, which
/// is where the old lit `{ }` failed at 2.82:1.
@Test func theLensChipsInkIsReadableOnItsOwnFillInEveryTheme() {
    for (name, palette) in Themes.builtin {
        let ratio = RGB.contrast(palette.textOn(palette.accent), palette.accent)
        #expect(ratio >= 4.5, "\(name): \(ratio)")
    }
}
```

  and, in the same file, the two ratios the *unlit* pills rest on — the `Stop` pill is the one with a tinted ink, and the hairline is the only thing separating a pill from the hover-tinted row behind it:

```swift
/// `Stop` is drawn in the theme's failure colour on a `foreground @ 0.14` wash over the row's hover
/// tint. It is text, so 4.5:1; the hairline is a shape, so 1.6:1 against the fill it outlines
/// (§2.3). Measured in all seven built-ins, because "readable in nyx-dark" is how gruvbox's lit
/// `{ }` shipped at 2.82:1.
@Test func theStripsUnlitPillsAreReadableInEveryTheme() {
    for (name, palette) in Themes.builtin {
        let ground = RGB.blend(palette.blockHoverBackground, into: palette.foreground, amount: 0.14)
        #expect(RGB.contrast(SummaryTone.failure.color(in: palette), ground) >= 4.5, "\(name) Stop")
        #expect(RGB.contrast(palette.foreground, ground) >= 4.5, "\(name) label")
        let hairline = RGB.blend(palette.blockHoverBackground, into: palette.foreground, amount: 0.22)
        #expect(RGB.contrast(hairline, ground) >= 1.6, "\(name) hairline")
    }
}
```

  (If `RGB.contrast` or `RGB.blend` are spelled differently in `ReadableColourTests`' existing cases, use that spelling — the file already measures ratios and blends, and its helpers are the ones to reuse. A theme that fails is a **finding**, not a licence to lower the floor: the fix is the alpha, and §9 forbids moving a hue.)

- [ ] **Step 2: Run them to verify they fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter "CommandBlockChrome|ReadableColour"`
Expected: FAIL on `theChipNamesTheLensThatIsOn` if Task 1's `pills` used the wrong default, and on the contrast case if any theme's `textOn(accent)` is under the floor — in which case the fix is in `Palette.textOn`, not in the test.

- [ ] **Step 3: Implement the chip's press**

```swift
    /// The lens rows of the ⋯ menu, on their own, under the chip that names them. Built from
    /// `header.actions` rather than from a second list, so the chip cannot offer a lens the menu
    /// does not -- the failure `BlockHeader.showsLens` and the menu had before them.
    private func lensMenu(for header: BlockHeader) -> NSMenu {
        let menu = NSMenu()
        for entry in header.actions {
            guard case .setLens = entry.action else { continue }
            let item = NSMenuItem(title: header.title(for: entry.action),
                                  action: #selector(menuPressed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuEntry(action: entry.action, id: header.id)
            item.isEnabled = entry.enabled
            item.state = header.isChecked(entry.action) ? .on : .off
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
```

  wired from the `.lens` pill's `onPress` as `lensMenu(for: menuHeader() ?? header).popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: pillView)` — `menuHeader()` because `Diff with Previous Run` is the row whose `enabled` is answered late.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter "CommandBlockChrome|ReadableColour"` → PASS; then the whole suite and `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 5: Picture it**

Add to `UISnapshot.blockStripStates`' replacement (Task 3 re-keyed it on `WidthClass`): `("lens-chip-off", …)`, `("lens-chip-on", …)`, `("lens-chip-body", …)`, `("lens-chip-raw", …)` at `.w3`, so the chip is rendered lit and unlit in both built-in themes and both appearances. Run `NYX_UI_SNAPSHOT=/tmp/shots-1a-4 ./build/Nyx.app/Contents/MacOS/Nyx` and **read** them: the lit chip must be legible as *ink on accent*, not as a dimmer version of the unlit one — the exact finding that `-on-` and `-body-` were indistinguishable.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxApp/BlockHeaderView.swift Sources/NyxApp/UISnapshot.swift \
        Tests/NyxCoreTests/CommandBlockChromeTests.swift Tests/NyxCoreTests/ReadableColourTests.swift
git commit -m "$(cat <<'MSG'
The lens control says which lens: a chip with a name, lit in the accent

`{ }` promised pretty JSON and said nothing about which of seven lenses a response was being read
through -- and lit, it was *dimmer* than unlit in gruvbox-dark, at 2.82:1. The chip now carries the
lens' own name (`Raw`, `Pretty`, `Headers`, `Body`, `Filter`, `Find`, `Diff`, from
`ResponseLens.chipTitle`, the short head of the menu's own wording), and its on-state is the filled
accent with `textOn(accent)` ink -- the pattern the search bar's scope toggle and a running quick
action already use. The floor is 4.5:1 on its own fill, asserted in all seven themes.

Its trailing `▾` is honest: pressing the chip opens the lens rows of the ⋯ menu, built from
`BlockHeader.actions` so the chip cannot offer a lens the menu does not. ⌘⇧J still toggles.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: One column folds, and the summary stops pretending to be a control

**Files:**
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift` — delete `BlockHeader.chevron` and `summaryWithChevron` (`:495-508`); `summaryPlacement` loses its `chevronCount:` parameter and `SummaryPlacement.Variant` (`:152-167`, `:250-268`)
- Modify: `Sources/NyxApp/GridSnapshot.swift` (its `summaryPlacement` call loses `chevronCount:`)
- Modify: `Sources/NyxApp/Pane.swift` — the summary text (`:2117-2135`), `toggleFoldOnSummary` and its call (`:2686-2689`, `:2722-2730`, **deleted**), `hoveredRect`'s summary rect (`:3167-3171`, **deleted**), `accessibilityChildren`'s summary elements (`:466-475`, **deleted**), the lens container cursor rects (`:3172-3183`) and `toggleLensFold(at:)` (`:3670-3693`), `unfoldPlaceholder(at:)` (`:3696-3703`), and the placeholder's accessibility frame (`:478-490`)
- Modify: `README.md:28-32`
- Test: `Tests/NyxCoreTests/CommandBlockTests.swift` (the four `summaryPlacement` cases at `:218-247`), `Tests/NyxCoreTests/BlockHeaderTests.swift` (the chevron assertions)

**Interfaces:**
- Consumes: `CommandBlockChrome.foldColumnWidth`, `.hitRowHeight(cellHeight:)`.
- Produces:

```swift
public extension CommandBlockChrome {
    /// The hit box of a column-0 fold triangle, in points, relative to the text area's leading
    /// edge. A tuple of `Double`s rather than a `CGSize`: `NyxCore` has no CoreGraphics type in it.
    static func foldTriangleHit(cellHeight: Double) -> (width: Double, height: Double)
}
public static func summaryPlacement(commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                                    textCount: Int, cols: Int) -> SummaryPlacement?
public struct SummaryPlacement: Equatable { public let row: Int; public let columns: Range<Int> }
```

- [ ] **Step 1: Write the failing tests**

```swift
/// The summary is a readout. It keeps its right alignment and loses its chevron, so the only
/// chevron-shaped things left on screen are controls: the gutter cap under the pointer and the
/// column-0 triangles.
@Test func theSummaryIsARowOfTextAndNoLongerAControl() {
    let placement = CommandBlockChrome.summaryPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 9)], textCount: 10, cols: 40)
    #expect(placement == SummaryPlacement(row: 4, columns: 30..<40))
    // A command line that reaches into the summary's columns takes the whole summary with it: there
    // is no chevron-only fallback any more, because the chevron was the control and the gutter is.
    #expect(CommandBlockChrome.summaryPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 39)], textCount: 10, cols: 40) == nil)
    #expect(CommandBlockChrome.summaryPlacement(
        commandRows: [(absoluteRow: 4, lastUsedColumn: 39), (absoluteRow: 5, lastUsedColumn: 12)],
        textCount: 10, cols: 40) == SummaryPlacement(row: 5, columns: 30..<40))
}

/// Column 0's triangle gets the same 20 pt the gutter gets, for the same reason: it is one cell
/// wide (about 8 pt) and one row tall (13 pt at `line-height 0.8`), which is not a target.
@Test func theFoldTriangleGetsTheSameTargetTheGutterHas() {
    #expect(CommandBlockChrome.foldColumnWidth == 20)
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: 13) == (width: 20, height: 16))
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: 24) == (width: 20, height: 24))
}
```

  And in `BlockHeaderTests`, replace every `#expect(h.chevron == …)` with an assertion on the summary alone, e.g. `#expect(h.summary == "exit 1 · 8.8s")`, and delete `aJustStartedCommandHasNoChevron`'s chevron lines while keeping its `hasOutput` and `.toggleFold` assertions — the rule they guard (a `sleep 10` one second in has nothing to fold) still decides the gutter cap and the `Fold` pill.

- [ ] **Step 2: Run to verify they fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter "CommandBlock|BlockHeader"`
Expected: FAIL — `extra argument 'chevronCount'` and `no member 'foldTriangleHit'`.

- [ ] **Step 3: Implement**

```swift
    /// Which row of a command carries its summary, and which columns.
    ///
    /// It used to fall back to a row with room for the chevron alone, because the chevron was the
    /// only thing on that row that folded the block. It no longer folds anything -- the gutter cap
    /// does, at every width, and it costs no columns -- so a row with no room for the whole summary
    /// simply carries none, and the reader loses a nicety rather than a control (§2.4).
    public static func summaryPlacement(commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                                        textCount: Int, cols: Int) -> SummaryPlacement? {
        for row in commandRows.reversed() {
            if let columns = summaryColumns(textCount: textCount, cols: cols,
                                            lastUsedColumn: row.lastUsedColumn) {
                return SummaryPlacement(row: row.absoluteRow, columns: columns)
            }
        }
        return nil
    }

    /// A column-0 triangle's target: 20 pt wide, `hitRowHeight` tall. The same 20 pt the gutter
    /// uses, so the two fold controls on screen are the same size (§2.4, §8.4).
    public static func foldTriangleHit(cellHeight: Double) -> (width: Double, height: Double) {
        (width: foldColumnWidth, height: hitRowHeight(cellHeight: cellHeight))
    }
```

  In `Pane.render()` the summary becomes `let text = header.summary` and the placement call drops `chevronCount:`; the `placement.text == .full ? text : header.chevron` ternary goes with it.

  In `Pane`, delete `toggleFoldOnSummary` and its `mouseUp` branch, the `summaryColumnsOnScreen` entry in `hoveredRect` (so the summary has **no** pointing hand) and the summary's `DrawnControlElement`s in `accessibilityChildren` (the fold control VoiceOver reaches is the gutter's, which is a real element with a real label). `summaryColumnsOnScreen` itself stays: `GridSnapshot` and the renderer both still need to know where the summary was placed.

  The two column-0 controls get their box:

```swift
        // A lens container line's triangle is the control; the rest of the line is text, and a
        // reader dragging across it is selecting (Wave 2 refines the drag; the box is the same).
        let hit = CommandBlockChrome.foldTriangleHit(cellHeight: Double(cell.height))
        for (visible, entry) in foldRowsOnScreen.enumerated() {
            guard case .lens(let id, let line) = entry,
                  lensBuffers[id]?.line(line)?.node != nil else { continue }
            let centre = bounds.height - padding - (CGFloat(visible) + 0.5) * cell.height
            rects.append(NSRect(x: padding, y: centre - CGFloat(hit.height) / 2,
                                width: CGFloat(hit.width), height: CGFloat(hit.height)))
        }
```

  and `toggleLensFold(at:)` gains the same guard (`Double(point.x - padding) < hit.width`), while `unfoldPlaceholder(at:)` keeps its whole-row target and finally gets a pointing hand:

```swift
        // The placeholder row is a control end to end: it has no content worth selecting, and it is
        // the one affordance the PM's read found already legible. It had no pointing hand (a11y
        // 6.13), which is the one thing that said so.
        for (visible, entry) in foldRowsOnScreen.enumerated() {
            guard case .fold(let id, _, _) = entry, id != 0 else { continue }
            let centre = bounds.height - padding - (CGFloat(visible) + 0.5) * cell.height
            rects.append(NSRect(x: padding, y: centre - CGFloat(hit.height) / 2,
                                width: max(0, bounds.width - padding * 2), height: CGFloat(hit.height)))
        }
```

  The placeholder's existing accessibility element gets the same `hit.height`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel` → PASS, `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 5: Say it in the README**

`README.md:28-32` currently tells the reader to click a chevron that no longer folds. Replace with:

```markdown
- A command and its output are a block: one 3 pt mark down the left of the rows it owns, and
  `exit 1 · 8.8s` at the end of its command line. The mark is the fold control — press it to fold
  the output down to its last three lines, press it again to put it back, ⌥-click to select the
  output. `⌘⇧↑` folds from the keyboard, and hovering the block raises a strip of labelled
  controls — `Fold`, `Copy`, `Actions ▾` — at whatever width the command leaves room for.
```

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Shell/CommandBlock.swift Sources/NyxApp/GridSnapshot.swift \
        Sources/NyxApp/Pane.swift README.md Tests/NyxCoreTests/CommandBlockTests.swift \
        Tests/NyxCoreTests/BlockHeaderTests.swift Tests/NyxCoreTests/CommandBlockChromeTests.swift
git commit -m "$(cat <<'MSG'
Six routes to fold become four, and two of them carry a word

Every `▸`/`▾` that means "fold" is now a control at column 0 or in the gutter, and the in-grid
summary -- which was a readout wearing a chevron -- keeps its right alignment and loses it. That
ends the contradiction between two places in `Pane` about which chevron gets a pointing hand: the
hand is now truthful everywhere, on the gutter cap, on a column-0 triangle and on every strip pill,
and nowhere else. The fold placeholder, which is a control end to end, finally has one.

A column-0 triangle's target is the same 20 pt × `hitRowHeight` box the gutter mark gets: it was one
cell wide and one row tall, which at `line-height 0.8` is 8 × 13.

`summaryPlacement` loses its chevron-only fallback with the chevron. It existed because the chevron
was the only control on that row; the gutter cap folds at every width and costs no columns, so a
crowded command line now loses a nicety instead of a control.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: The sticky strip stops printing on top of the output

**Files:**
- Modify: `Sources/NyxCore/Shell/StickyPrompt.swift` (the `isAllowed` gate; `StickyPromptLabel.accessibilityLabel`)
- Modify: `Sources/NyxApp/StickyPromptView.swift` (opaque ground, divider, leading `↑`, the truthful label, `hitRowHeight`)
- Modify: `Sources/NyxApp/Pane.swift` — `render()` blanks the covered row (`:2223-2235`), `layoutStickyStrip()` (`:3567-3578`)
- Test: `Tests/NyxCoreTests/StickyPromptTests.swift`

**Interfaces:**
- Consumes: `CommandBlockChrome.isAllowed(altScreen:mouseReporting:hasMarks:)`, `.hitRowHeight(cellHeight:)`, `BlockHeader.summary`, `SummaryTone`.
- Produces:

```swift
public extension StickyPromptLabel {
    /// `Pinned command: swift build … · exit 1 · 8.8s. Scrolls back to it.`
    static func accessibilityLabel(text: String, summary: String) -> String
}
final class StickyPromptView: NSView {   // NyxApp
    func update(text: String?, summary: String, tone: SummaryTone, palette: Palette, font: NSFont)
}
```

  `failed:` leaves the signature: the band's colour comes from `tone`, which already distinguishes a failed command from a 404 the command reported successfully, and a second flag is a second opinion.

- [ ] **Step 1: Write the failing tests**

```swift
/// Addendum 1: block chrome steps aside for a full-screen program -- spines, summaries and the
/// gutter all do, and the pinned strip did not, so vim was drawn under a band naming the command
/// that started it (and, on the alternate screen, one whose exit status was gone).
@Test func nothingIsPinnedWhileAFullScreenProgramOwnsTheDisplay() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "swift build\r\n" + mark("C"))
    for line in 1...40 { t.feed("compiling \(line)\r\n") }
    t.feed(mark("D;0"))
    #expect(t.stickyPrompt() != nil)
    t.feed("\u{1B}[?1049h")            // vim takes the screen
    #expect(t.stickyPrompt() == nil)
    t.feed("\u{1B}[?1049l")
    #expect(t.stickyPrompt() != nil)
    // And while a TUI owns the mouse, for the same reason `CommandBlockChrome.isAllowed` says so.
    t.feed("\u{1B}[?1000h")
    #expect(t.stickyPrompt() == nil)
}

/// The band said "Running command" for a command that finished half an hour ago (a11y 7.1). It
/// says what it is and what pressing it does, and carries the same summary the strip shows.
@Test func thePinnedBandSaysWhatItIsAndWhatItDid() {
    #expect(StickyPromptLabel.accessibilityLabel(text: "$ swift build", summary: "exit 1 · 8.8s")
        == "Pinned command: $ swift build · exit 1 · 8.8s. Scrolls back to it.")
    #expect(StickyPromptLabel.accessibilityLabel(text: "$ ls", summary: "")
        == "Pinned command: $ ls. Scrolls back to it.")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter StickyPrompt`
Expected: FAIL — a pinned prompt on the alternate screen, and no `accessibilityLabel`.

- [ ] **Step 3: Implement the Core half**

```swift
    func stickyPrompt(viewportTop: Int? = nil) -> StickyPrompt? {
        // The same gate the spine, the summary and the gutter obey. A band naming the command that
        // started vim, drawn over vim, is the chrome-that-does-not-step-aside bug this project
        // avoids everywhere else (Addendum 1).
        guard CommandBlockChrome.isAllowed(altScreen: modes.altScreen,
                                           mouseReporting: modes.mouse != .none,
                                           hasMarks: shellEmitsPromptMarks) else { return nil }
        …unchanged…
    }
```

```swift
public extension StickyPromptLabel {
    /// What VoiceOver hears. "Running command: …" was said of commands that had finished, which is
    /// the label describing the wrong half of the state it was built from.
    static func accessibilityLabel(text: String, summary: String) -> String {
        let sentence = summary.isEmpty ? text : "\(text) \u{b7} \(summary)"
        return "Pinned command: \(sentence). Scrolls back to it."
    }
}
```

- [ ] **Step 4: Implement the view and the blanked row**

```swift
    func update(text: String?, summary: String, tone: SummaryTone, palette: Palette, font: NSFont) {
        // The `guard let text, !text.isEmpty else { hide }` at the top of this method is unchanged,
        // so everything below is inside the unwrap: `text` is a `String` by the time the label is
        // built and `StickyPromptLabel.accessibilityLabel` never sees an optional. `text` is
        // already `StickyPromptLabel.text(command:exitStatus:columns:)`'s answer -- the collapsed,
        // cut command line the band draws -- so the spoken sentence and the drawn one are one
        // string, cut once.
        …
        setAccessibilityRole(.button)
        setAccessibilityLabel(StickyPromptLabel.accessibilityLabel(text: text, summary: summary))
        label.textColor = nsColor(palette.foreground, alpha: 1)
        note.textColor = nsColor(tone.color(in: palette), alpha: 1)
        // Opaque, and pinned to the palette's own appearance: `foreground @ 0.10` over live text is
        // why every scrolled composite showed a pinned command and the output beneath it printed on
        // top of each other.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
        layer?.backgroundColor = nsColor(palette.background, alpha: 1).cgColor
        divider.layer?.backgroundColor = nsColor(palette.foreground, alpha: 0.20).cgColor
        arrow.colour = palette.foreground        // drawn at 0.55 in `draw`
        isHidden = false
    }
```

  `divider` is a 1 px subview along the bottom edge; `arrow` is a small `NSView` drawing an 8 pt `↑` path in `palette.foreground @ 0.55` at the leading edge, before the label — the band had no bezel, no chevron, no pin and no divider, and was a click target end to end. The label's leading constraint moves to `arrow.trailingAnchor + 6`.

  `layoutStickyStrip()` gives the band `CommandBlockChrome.hitRowHeight(cellHeight: cell.height)`, centred on the row it covers, so it is never 13 pt tall:

```swift
        let height = CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cell.height)))
        let centre = top + cell.height / 2 - CGFloat(stickyRow) * cell.height
        stickyStrip.frame = NSRect(x: left, y: centre - height / 2, width: width, height: height)
```

  And `render()` blanks the row underneath, which is the fix the ground alone does not make (the band is one row tall over a grid that keeps drawing that row's glyphs at the same pixels when the band is one point taller or shorter than a cell):

```swift
            // `stickyPromptRow` has been computed since the strip existed and read only by the
            // click handler. The row the band covers is blanked in the frame, so the pinned command
            // and the output beneath it cannot print on top of each other.
            if sticky != nil, blankRow < lines.count {
                lines[blankRow] = Row(cols: t.cols)
            }
```

  `lines` is built as a `let` in the frame pass today; it becomes a `var` for this one assignment, which is one row of an array the frame already owns. `blankRow` is the display slot the band sits on — `0`, or `1` when the remote strip is up, the same arithmetic `layoutStickyStrip` uses. Add a `PartialRedrawTests` scenario for a frame whose top row is blanked, so the row cache is exercised with it.

- [ ] **Step 5: Run the tests, build, look**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel` → PASS; `swift build 2>&1 | grep -c warning:` → `0`; `make bench` ≥ 180.
`NYX_UI_SNAPSHOT=/tmp/shots-1a-6 …` and **read** `composite-sticky-*.png`: no text of the covered row anywhere inside the band, a visible bottom divider, and an `↑` that says the band is a control.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Shell/StickyPrompt.swift Sources/NyxApp/StickyPromptView.swift \
        Sources/NyxApp/Pane.swift Tests/NyxCoreTests/StickyPromptTests.swift \
        Tests/NyxRenderTests/PartialRedrawTests.swift
git commit -m "$(cat <<'MSG'
The pinned command stops printing on top of the output it names

`foreground @ 0.10` over live text, with nothing blanking the row underneath: the worst defect in
the picture set, and it recurred in every scrolled composite. The band is now opaque
`palette.background` with its appearance pinned to the theme, `Pane.render` blanks the row it
covers (`stickyPromptRow` has existed since the strip did and was read only by the click handler),
and a 1 px bottom divider says where it ends.

It also says it is a control at all -- a leading `↑` drawn as a path -- and it stops lying about
what it names: "Running command: …" was said of commands that had finished, and it now reads
`Pinned command: swift build … · exit 1 · 8.8s. Scrolls back to it.` in the block's own tone.

And it steps aside for a full-screen program. Spines, summaries and the gutter all obeyed
`CommandBlockChrome.isAllowed`; the pinned band did not, so vim was drawn under a band naming the
command that started it. Its height goes through `hitRowHeight`, so it is never 13 pt tall.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 7: The row-height floor everywhere, and the two settings that break every metric

**Files:**
- Modify: `Sources/NyxApp/Pane.swift` — the workbench pill's frame (`:2245-2252`), and an audit of every remaining `cellSizePoints.height`-as-hit-height
- Modify: `Sources/NyxApp/GridSnapshot.swift:95-110` (the extreme-metric composites, renamed to §8.5's names and extended)
- Test: `Tests/NyxCoreTests/CommandBlockChromeTests.swift`

**Interfaces:**
- Consumes: `CommandBlockChrome.{hitRowHeight, stripFrameHeight, stripGroundHeight, foldTriangleHit, spineLeadingInset, spineWidth}`, `PromptGutter.hitWidth`.
- Produces: nothing new. This task is the sweep that makes §8.4 true and Addendum 2 provable.

**The audit (§8.4's list, and where each one is now).** Every hit target that is one text row tall:

| target | where it is decided | landed in |
|---|---|---|
| the gutter mark | `PromptGutterView.rect(of:)` → `hitRowHeight` | Task 2 |
| the strip | `CommandBlockChrome.stripFrameHeight` (frame) / `stripGroundHeight` (paint) | Task 3 |
| a column-0 fold triangle on a lens container row | `CommandBlockChrome.foldTriangleHit` | Task 5 |
| a fold placeholder row | `foldTriangleHit(…).height`, full width | Task 5 |
| the sticky band | `hitRowHeight` in `layoutStickyStrip` | Task 6 |
| the in-grid summary | **no target at all** — it is a readout (§2.4) | Task 5 |
| the `⌘E Workbench` pill | `hitRowHeight` in `render()` | **this task** |

- [ ] **Step 1: Write the failing test**

```swift
/// §8.4, in one place: at `line-height = 0.8` every one-row target is 13 pt, and every one of them
/// goes through the same clamp. A config value cannot take the floor away.
@Test func everyOneRowTargetClearsSixteenPointsAtTheSmallestRow() {
    let cell = 13.0                 // 13 pt is a 16 pt font at `line-height = 0.8`
    #expect(CommandBlockChrome.hitRowHeight(cellHeight: cell) == 16)
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: cell).height == 16)
    #expect(CommandBlockChrome.foldTriangleHit(cellHeight: cell).width == 20)
    #expect(CommandBlockChrome.stripFrameHeight(cellHeight: cell) == 20)
    #expect(PromptGutter.hitWidth == 20)
    // …and the *drawn* things are not clamped, or the marks go lumpy and two blocks' marks collide
    // (the ruling in §2.2 against `findings-design` §3.2).
    #expect(CommandBlockChrome.stripGroundHeight(cellHeight: cell) == 13)
}

/// Addendum 2: a 20 pt opaque band on a 13 pt grid covers three rows of somebody's output. The
/// frame may be 20 pt -- `hitTest` rejects anything outside it -- but what it *paints* is one row.
@Test func theStripPaintsOneRowHoweverTallItsFrameIs() {
    for cell in [13.0, 16, 17, 24] {
        #expect(CommandBlockChrome.stripGroundHeight(cellHeight: cell) == cell, "\(cell)")
        #expect(CommandBlockChrome.stripFrameHeight(cellHeight: cell) >= 20, "\(cell)")
    }
}

/// `padding = 0` is a shipped setting. The gutter's target does not depend on the padding at all,
/// and the mark moves onto the first text column's leading edge rather than off the window.
@Test func zeroPaddingKeepsBothTheTargetAndTheMark() {
    #expect(PromptGutter.hitWidth == 20)
    #expect(CommandBlockChrome.spineLeadingInset(padding: 0) == 0)
    #expect(CommandBlockChrome.spineWidth == 3)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter CommandBlockChrome`
Expected: PASS for the clauses Tasks 1–6 already satisfy and FAIL for any that do not — if it all passes, the sweep below is still required, and the failing evidence is the picture in Step 4, not this test.

- [ ] **Step 3: Finish the sweep in `Pane`**

```swift
        if let hint {
            let size = workbenchHint.intrinsicContentSize
            let origin = overlayOrigin(forHeaderRow: hint.slot)
            // The pill is a control on a row, and a row is 13 pt at `line-height 0.8` (§8.4).
            let height = CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cellSizePoints.height)))
            workbenchHint.frame = NSRect(x: origin.x - size.width,
                                         y: origin.y + (cellSizePoints.height - height) / 2,
                                         width: size.width, height: height)
        }
```

  Then `grep -n "cellSizePoints.height" Sources/NyxApp/Pane.swift` and check each remaining hit: a *drawn* rect (a tint, a selection, a cursor rect over text) stays `cellSizePoints.height`; a *pressable* rect takes `hitRowHeight`. Write the verdict for each line into the commit message, so the sweep is reviewable without re-deriving it.

- [ ] **Step 4: Picture both extremes**

In `GridSnapshot.run`, the two tweaked-config passes take §8.5's names and cover the strip, the gutter and the sticky band at each extreme:

```swift
        for (label, change) in [("lineheight-08", { (c: inout Config) in c.lineHeight = 0.8 }),
                                ("padding-0", { (c: inout Config) in c.padding = 0 })] {
            var tweaked = config
            change(&tweaked)
            guard let canvas = GridCanvas(cols: 84, rows: 20, config: tweaked) else { continue }
            for (name, kind) in [("strip", Case.hoverStrip(.w3, .finished)), ("gutter", Case.gutter),
                                 ("sticky", Case.sticky)] {
                write(canvas: canvas, palette: dark, appearance: .darkAqua, case: kind,
                      into: directory, named: "composite-block-\(label)-\(name)-nyx-dark-dark")
            }
        }
```

  Run the set and **read the six**: at `line-height 0.8` the strip's ground covers one row and its pills are not clipped; at `padding = 0` the gutter's marks are on screen and each block still has a 3 pt left edge.

- [ ] **Step 5: Build, test, bench**

Run: `swift build 2>&1 | grep -c warning:` → `0`; `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel`; `make bench` ≥ 180.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxApp/Pane.swift Sources/NyxApp/GridSnapshot.swift \
        Tests/NyxCoreTests/CommandBlockChromeTests.swift
git commit -m "$(cat <<'MSG'
Nothing in a block is 13 points tall any more, and neither setting breaks it

`line-height = 0.8` is a shipped config value and makes every one-row hit target 13 pt: the gutter
mark, the fold placeholder, a lens container row, the pinned band and the workbench pill were all
that, and the second snapshot pass found the 20 pt strip covering three rows of output at the same
setting. All of them now go through `CommandBlockChrome.hitRowHeight`, clamped in Core and tested
there; the strip's frame clears the floor while what it *paints* stays one row.

`padding = 0` is the other end: it used to remove the gutter and every spine at once, leaving a
block with no left edge. The target no longer depends on the padding, and the mark takes the first
text column's leading 3 pt.

Both extremes are pictured for the strip, the gutter and the pinned band -- until now the chrome had
only ever been rendered at its defaults.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

### Task 8: The pictures, the probe in the built app, and the ladder

**Files:**
- Modify: `Sources/NyxApp/UISnapshot.swift` (the gutter caps and the strip states by width class)
- Modify: `Sources/NyxApp/StateSnapshot.swift` (`press` finds a `StripPillView`; every pill hovered and pressed)
- Modify: `Sources/NyxApp/GridSnapshot.swift` (`Case.hoverStrip(WidthClass)`, the nine states, the TUI-suppressed strip)
- Modify: `Sources/NyxApp/AppDelegate.swift` (**temporary** `NYX_SMOKE_QA=blockchrome` hook, removed in Step 6)
- Modify: `docs/architecture.md` (the "where to add things" rows for a strip pill and a gutter shape)

**Interfaces:**
- Consumes: everything Tasks 1–7 produced.
- Produces: the §8.5 plan-1a picture set, and no code that survives the commit except the snapshot cases and the doc rows.

- [ ] **Step 1: The gutter's caps, in every state**

In `UISnapshot`, replace the single four-mark gutter with the twelve §8.5 cases:

```swift
                // `gutter-cap-<state>-<presentation>-<palette>-<appearance>`: the four shapes, each
                // idle, hovered and folded. The hovered ones are the only new marks this wave draws
                // and the only ones that had no picture at all -- `gutter-marks-hovered-*` came out
                // byte-identical to idle, which was the finding, not the tool.
                for (stateName, header, started) in gutterCapStates() {
                    for (presentation, hovered, folded) in [("idle", false, false),
                                                            ("hovered", true, false),
                                                            ("folded", true, true)] {
                        // `BlockHeader.folded` is a `let`, so the folded case is a second header
                        // rather than a mutation -- `gutterCapStates` takes the flag and builds it.
                        let shown = folded ? gutterCapHeader(stateName, folded: true) : header
                        guard let cap = CommandBlockChrome.gutterCap(shown, hasStarted: started,
                                                                     hovered: hovered) else { continue }
                        let view = PromptGutterView(frame: NSRect(x: 0, y: 0,
                                                                  width: CGFloat(PromptGutter.hitWidth),
                                                                  height: cell))   // `cell` is the row height
                        view.appearance = NSAppearance(named: appearance)
                        view.update(caps: [0: cap], labels: [0: "Command on line 1 \(stateName)."],
                                    palette: themePalette, cellHeight: cell, padding: 8, topPadding: 0)
                        view.layoutSubtreeIfNeeded()
                        write(view, named: "gutter-cap-\(stateName)-\(presentation)-\(suffix)",
                              into: directory, background: themePalette.background)
                    }
                }
```

  with `gutterCapStates()` returning `("succeeded", header, started)`, `("failed", …)`, `("running", …)`, `("no-output", …)` — the four headers built the way `blockHeaderStates()` builds its own — and `gutterCapHeader(_ state: String, folded: Bool) -> BlockHeader` building the same four through the `BlockHeader` initialiser with `folded:` set, because the property is a `let`.

- [ ] **Step 2: The strip, at every width class, in every state**

`UISnapshot.blockStripStates()` is re-keyed from `OverlayControls` to `CommandBlockChrome.WidthClass` and produces `block-header-<state>-<class>-<palette>-<appearance>`; `GridSnapshot` gains the composite matrix §8.5 asks for:

```swift
                // `composite-strip-<class>-<state>-<palette>-<appearance>`: §2.6's table as
                // pictures, over a command line whose length puts the block in that width class.
                // Thirty-six per palette-appearance pair, most of which `cmp` will pair off -- the
                // point is that no cell of the table ships unlooked-at.
                for width in [CommandBlockChrome.WidthClass.w3, .w2, .w1, .w0] {
                    for state in GridScene.StripState.allCases {
                        write(canvas: canvas, palette: palette, appearance: appearance,
                              case: .hoverStrip(width, state), into: directory,
                              named: "composite-strip-\(name(of: width))-\(state.rawValue)-\(suffix)")
                    }
                }
```

  `GridScene.StripState` and `GridScene.commandFitting(_ width:)` both landed in Task 3; what this task adds is the loop over all nine states, and the fixture blocks behind the four that had none (`folded`, `lensed`, `watch-finished`, `no-output`).

  Two more composites: `composite-strip-suppressed-tui-<palette>-<appearance>` (the existing `.tui` case with the pointer over a block: no strip, no spine, no cap — the rule that keeps vim behaving as it did), and the retaken `composite-sticky-*`.

- [ ] **Step 3: Hovered and pressed, for every pill**

In `StateSnapshot`, `press(_:in:)` learns the new control, and the hovered art becomes reachable because the pill owns it:

```swift
    /// Puts a named pill into its pressed art. `StripPillView` is not an `NSButton` -- deliberately,
    /// see the view's own comment -- so `highlight(true)` has nothing to press.
    private static func press(_ title: String, in view: NSView) {
        let pills = UISnapshot.descendants(of: view).compactMap { $0 as? StripPillView }
        if let pill = pills.first(where: { $0.pill?.title == title }) {
            pill.setPressedForSnapshot(true)
            return
        }
        let buttons = UISnapshot.descendants(of: view).compactMap { $0 as? NSButton }
        guard let button = buttons.first(where: { $0.title == title || $0.attributedTitle.string == title })
        else {
            FileHandle.standardError.write(
                "pressed-state snapshot: nothing titled \"\(title)\" in \(type(of: view))\n"
                    .data(using: .utf8)!)
            return
        }
        button.highlight(true)
    }
```

  and each of `Fold`, `Unfold`, `Copy`, `Stop`, `Actions`, `⋯` and the lens chip is written as `block-header-hovered-<pill>-…` and `block-header-pressed-<pill>-…` (the hovered art through the pill's own `mouseEntered`, driven with a synthesised `NSEvent` exactly as the tab bar's hover sweep does).

  **And `gutter-marks-hovered-*` is retired** (`StateSnapshot.swift:82-105`). It fakes a hover by calling `gutter.mouseMoved(with:)`, and the rewritten `PromptGutterView` has no `mouseMoved` at all — the hover is a `GutterCap` the pane computes, so that case would go on printing a picture byte-identical to idle for ever, which is the failure the case was written to expose in the first place. The state it was standing in for is Step 1's `gutter-cap-<state>-hovered-<palette>-<appearance>`, driven by the real `gutterCap(_:hasStarted:hovered:)`; delete the block and say so in the commit.

- [ ] **Step 4: Rung 6 — drive it in the built app**

Add to `AppDelegate.applicationDidFinishLaunching`, gated on `ProcessInfo.processInfo.environment["NYX_SMOKE_QA"] == "blockchrome"`, a block that opens a window, gets its `Pane`, feeds a fixture transcript through the session (four blocks: a succeeded one, a failed one, a running one, and a `curl` with a watch), and then:

1. moves the pointer onto each block through the real `mouseMoved` at a command line of each width class, printing `SMOKE strip w3 -> pills=[Fold, Copy, Actions] firstColumn=…`;
2. calls `Pane.hitTest` at the centre of every pill and presses it, printing which `BlockAction` fired (`SMOKE press Copy -> copyOutput id=3`);
3. presses the gutter cap at nine points — the four corners, the four edge midpoints and the centre of `rect(of:)` — printing how many of the nine reached the gutter (`SMOKE gutter 9/9`; the G1 probe that measured six of nine sample points per pill reaching the old strip is the same shape, and this is the gutter's turn to be measured that way);
4. presses the left padding at `x = 2` on a block's output row and prints what happened — **it must print `SMOKE padding -> nothing`**;
5. presses the in-grid summary and prints the same;
6. `exit(0)`.

Run: `./scripts/bundle.sh && NYX_SMOKE_QA=blockchrome ./build/Nyx.app/Contents/MacOS/Nyx`, and paste its output into the task report. A hover that resolves no strip, a pill that fires nothing, a gutter under 9/9 or a padding press that folds anything is a failure of this plan, not of the probe.

- [ ] **Step 5: The ladder**

- `swift build 2>&1 | grep -c warning:` → `0` (library **and** tests).
- `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel` — record the test count.
- `make bench` three times — record the figures, floor 180.
- `NYX_SNAPSHOT=1 swift test --filter Snapshot`.
- `NYX_UI_SNAPSHOT=/tmp/shots-1a ./build/Nyx.app/Contents/MacOS/Nyx`, then `cmp -r` a second run against the first (deterministic), then **read**: every `gutter-cap-*`, one of each identical `<palette>-<appearance>` pair of `composite-strip-*`, every pair that differs, `block-header-hovered-*`, `block-header-pressed-*`, `composite-sticky-*`, `composite-strip-suppressed-tui-*`, `composite-block-lineheight-08-*` and `composite-block-padding-0-*`, at 1:1 and at 3× for the pills.
- Ask the `design-reviewer` agent over the picture set, then the `product-manager` agent, which is the last gate.

- [ ] **Step 6: Remove the hook and commit**

`git diff --stat` must not show `AppDelegate.swift`. Two commits in this repo have already had to be amended because a hook was swept in.

```bash
git add Sources/NyxApp/UISnapshot.swift Sources/NyxApp/StateSnapshot.swift \
        Sources/NyxApp/GridSnapshot.swift docs/architecture.md
git commit -m "$(cat <<'MSG'
Every cell of the table, and every state of the mark, as a picture

§2.6 is a nine-by-four table and none of its cells had ever been rendered: the strip had pictures of
three control sets on a flat fill, and the gutter had four marks with no hovered, folded or
no-output state at all -- `gutter-marks-hovered-*` came out byte-identical to idle, which was the
finding. This adds `gutter-cap-{succeeded,failed,running,no-output}-{idle,hovered,folded}`, the
strip at each width class in each of the nine states over a real grid, every pill hovered and
pressed (reachable now that a pill draws its own states), the strip suppressed while a TUI owns the
screen, and the retaken pinned band.

`gutter-marks-hovered-*` is retired with the `mouseMoved` it faked its hover through: the gutter's
hover is a `GutterCap` the pane computes, and `gutter-cap-*-hovered-*` is the same state drawn by
the real rule.

Rung 6: a temporary `NYX_SMOKE_QA=blockchrome` hook hovered each width class through the real
`mouseMoved`, pressed every pill, pressed the gutter cap at nine points and pressed the left padding
-- which now does nothing, as designed. The hook is removed; the numbers are in the task report.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
)"
```

---

## Self-review

**Spec coverage.** Every requirement of §2.1–§2.7, §8.4, §8.5 (plan 1a's row), §10 (plan 1a's paragraph) and Addendum 1–3, with the task that carries it:

| requirement | task |
|---|---|
| §2.1 `CommandBlockChrome` is the single authority; `WidthClass`, `StripPlan`, `Pill`, `gutterCap`, `spineWidth`, `spineLeadingInset`, `hitRowHeight` | 1 |
| §2.1 views read the plan and draw it; no `if` about which control survives stays in a view | 3, 4 |
| §2.1 `Pane.foldBlock(atPointInPadding:)` deleted | 2 |
| §2.2 20 pt hit width independent of padding; `PromptGutter.maximumWidth`, `markWidth`, `markInset`, `minimumPadding`, `width(padding:)`, `markRect(gutterWidth:)` and their tests gone; `CommandBlockChrome.spineGap` gone with them | 1, 2 |
| §2.2 drawn mark 3 pt × `cellHeight`, the head of the spine; the 1 pt Metal spine and the 4.5 pt capsule stop being two marks | 2 |
| §2.2 `spineLeadingInset`; overlapping targets go to the nearer centre | 1, 2 |
| §2.2 shape carries state (solid / bar / hollow / 40 % and not pressable) | 1, 2 |
| §2.2 the hover chevron, the only new mark; nothing added at idle | 1, 2 |
| §2.2 ⌥-click still selects; `GutterMarkLabel` unchanged | 2 (the label text is untouched) |
| §2.3 every geometry number, the pill fill, hairline and pressed fill, the fade, the ground | 3 |
| §2.3 `firstColumn` never inside a word; `overlapsCommand` only for the W0 `Stop` | 1, 3 |
| §2.3 labels and help, verbatim | 1 |
| §2.3 dots 7 pt on a 10 pt pitch, running filled accent, `+N` past the cap | 1 (`hiddenRuns`), 3 |
| §2.3 the lens chip carries the name, accent when on | 1, 4 |
| §2.4 fold triangles share column 0 with a 20 pt × `hitRowHeight` box; the summary loses its chevron and its click; the placeholder gets a pointing hand | 5 |
| §2.5 the summary is suppressed only by a strip on its own row that says at least as much (`suppressesSummary`) | 3 |
| §2.6 the table, both ladders, `Stop`/`Actions`/the status never dropped | 1 |
| §2.6 `OverlayControls` deleted in the task that moves its last caller | 3 |
| §2.7 blanked row, opaque ground, divider, leading `↑`, truthful label and VoiceOver sentence | 6 |
| §8.4 every one-row target through `hitRowHeight` | 2, 3, 5, 6, 7 |
| §8.5 plan 1a's cases | 4, 7, 8 |
| §10 Core tests: width classes at the four boundaries, every cell of the table, both ladders, `firstColumn` with a trailing wide cell, `overlapsCommand`, `spineLeadingInset` at 0/3/8/64, `GutterCap` × hovered × folded, `hitRowHeight`, the sticky label | 1, 2, 5, 6, 7 |
| §10 rung 6 `NYX_SMOKE_QA=blockchrome`, removed before the commit | 8 |
| Addendum 1 the sticky strip obeys `isAllowed`, Core test on the alt screen | 6 |
| Addendum 2 `max(20, hitRowHeight)` covering no more rows than §2.3 allows; `padding = 0` keeps the target and the spine | 2, 3, 7 |
| Addendum 3 the hover glyph and the pill hover are new drawing; pressed fill `foreground @ 0.26` | 2, 3 |

**Deliberate deviations, each argued where it is made:** `Double` rather than §2.1's `CGFloat` for every number `NyxCore` hands out, because `NyxCore` contains no CoreGraphics type anywhere and `PromptGutter` is already `Double` — the AppKit layer converts at the call site (Task 1, and the Global Constraints); the two-stage `stripContent`/`stripPlan` split of §2.1's sketch (Task 1); `gutterCap` taking `hasStarted` and reading `folded` off the header (Task 1); `Unfold`'s help sentence saying "Unfold" where §2.3 gives one line for both labels (Task 1); the lens chip opening the lens menu rather than toggling, because it draws a `▾` (Task 4); `WatchSeries.headerText` re-ordered so the interval is last, and its leading `watch ` dropped, which is what §2.6's W3 watch cell reads, what makes the readout ladder positional, and what §3.14 leaves the verb's home as the menu titles and the popover (Task 1).

**Not in this plan, by the spec's own split:** `BlockCursor`, ⌘⇧A, the eight re-targeted actions, the four re-titled ones, `scroll_to_sticky_prompt`, the finish announcement and the `BlockAction → TerminalAction?` chords are **plan 1b** (§2.8). The lens field's anchoring, the `Body too large` chip, the watch vocabulary and the container-drag rule are **wave 2** (§3). Nothing here waits for either.
