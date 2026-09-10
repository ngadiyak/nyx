# UX Round — Plan 1b: The Keyboard on a Block

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One value in Core — `BlockCursor` — says which block the keyboard is on; ⌘↑/⌘↓ move it, it is drawn exactly as a hovered block, the eight block-scoped actions all target it, ⌘⇧A pops the block's own menu at its row with every chord shown, the sticky strip gets a keyboard path, and a command that mattered is announced when it finishes.

**Architecture:** `BlockCursor` (`moved`, `afterViewportMove`), `BlockTarget.resolve` and `BlockHover.choose` are pure values in `NyxCore/Shell`, unit-tested; `Pane` holds one `BlockCursor`, moves it in `jumpToPrompt`, re-anchors it in the frame pass when the viewport moved for another reason, and hands the winner to the chrome plan-1a already draws. `block_actions` and `scroll_to_sticky_prompt` are ordinary `TerminalAction`s through the full checklist (`.claude/skills/nyx-config-keys/SKILL.md`: case → `ActionCatalog.sections` → `KeyBinding.defaults` → `TabController.perform`/`canPerform` → `docs/configuration.md` → tests). `BlockAction.terminalAction` gives every menu row its chord. Nothing here draws a new pixel: plan 1a's `StripPlan`/`GutterCap` are what the cursor makes visible.

**Tech Stack:** Swift 6.0.3 in Swift 5 mode, SwiftPM, swift-testing, AppKit, Metal (unchanged); no new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-07-ux-round-design.md` — §2.8 is this plan; §8.2's first two rows, §8.5's plan-1b pictures, §8.1's finish rule and §10's "Plan 1b" paragraph are its edges. The reasoning is `.superpowers/sdd/2026-09-07-ux-round/findings-a11y.md` §11.1–§11.2 (five rules for "which block"; ⌘⇧A as the one route).

**Assumes plan 1a has landed** (`docs/superpowers/plans/2026-09-07-ux-round-1a-*.md`, spec §2.1–§2.7): `CommandBlockChrome.WidthClass`, the strip plan and its `Pill`s, `GutterCap` and the gutter-cap rule, `spineWidth`, `spineLeadingInset(padding:)` and `hitRowHeight(cellHeight:)` exist under whatever exact parameter lists 1a rules on, `OverlayControls` **has been deleted**, the gutter's hover glyph is drawn, `PromptGutter.hitWidth = 20`, `Pane.foldBlock(atPointInPadding:)` is gone, and the sticky strip is opaque with `StickyPromptLabel` fed from `BlockHeader.summary`/`SummaryTone`. Every task's Interfaces block names what it consumes from 1a. Nothing in this plan changes any of it.

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY; `NyxRender` learns nothing about the cursor — the cursor's block is drawn by the *same* chrome path a hovered block is, with no new render input.
- Tests are swift-testing (`import Testing`, `@Test`, `#expect`); hoist mutating calls out of `#expect`/`#require`. Hang fix: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`.
- Warning-free build (library and tests); `make bench` ≥ 180 MB/s. **Nothing in this plan may add per-frame work to `Pane.render` beyond one `Array.contains` over the frame's own block ids**; `Terminal.commandToFold()` is called from the frame pass only on the frame where the cursor's block has just left the screen.
- `BlockCursor` rules, verbatim (§2.8): clamps at both ends rather than wrapping; from a cleared cursor `.previous` takes the last element and `.next` the first; a block trimmed out of `among` by scrollback is gone, and the move starts from the nearest surviving id in the direction of travel; on a viewport move for another reason the cursor keeps its block while that block is still in `visible`, otherwise takes `fallback`, and clears when `fallback` is nil. **Controller ruling (2026-09-07), binding:** a cleared or off-screen cursor is seeded from the viewport before a ⌘↑/⌘↓ press — `commandToFold()`'s block — so a scrolled-back pane goes up from where the reader is rather than jumping to the newest block.
- Presentation rule, verbatim (§2.8): the cursor's block is drawn exactly as a hovered one — row tint, gutter chevron, and the strip of §2.6 at the block's own width class. The pointer wins while it is inside the pane; the cursor's presentation returns when the pointer leaves or the next ⌘↑/⌘↓ arrives, and it is cleared when the cursor clears. **Nothing new is drawn at idle: a pane nobody has pressed ⌘↑ in has no cursor.**
- Titles, verbatim: `Command Actions…` (`block_actions`, Go, **⌘⇧A**), `Go to the Pinned Command` (`scroll_to_sticky_prompt`, Go, no chord), `Copy Command Output`, `Copy Command as Markdown`, `Save Command Output…`, `Edit This Command…`. The ellipsis is `\u{2026}`, as everywhere else in `ActionCatalog`. `fold_command`, `select_command_output`, `toggle_http_lens` and `stop_watch` keep their titles and change only their target.
- Announcement rule, verbatim (§8.1): the focused pane only, and only when the command ran ≥ 2 s or exited non-zero; the sentence is `BlockHeader.summary`. Wording stays in Core.
- Every new action goes the whole way (`.claude/skills/nyx-config-keys/SKILL.md`, "Adding an action"): `TerminalAction` case → `ActionCatalog.sections` → `KeyBinding.defaults` → `TabController.perform` **and** `canPerform` → `docs/configuration.md` bindings table → `ActionCatalogTests`/`KeyBindingTests`.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (the only trailer since 2026-09-09; the earlier `Claude-Session` line is superseded) and
  `git add` by name. Never touch `CLAUDE.md`, `.claude/`, `docs/testing.md`, `docs/workflow.md`, `docs/status.md`, `README.md`.

---

### Task 1: `BlockCursor`, the hover's source, and the one target rule

**Files:**
- Create: `Sources/NyxCore/Shell/BlockCursor.swift`
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift` — `BlockHover` gains `source`, a cursor resolver and the pointer-versus-cursor rule
- Test: `Tests/NyxCoreTests/BlockCursorTests.swift` (new), `Tests/NyxCoreTests/BlockHoverTests.swift` (extended)

**Interfaces:**
- Consumes (plan 1a, spec §2.1–§2.6): nothing at runtime. The one obligation is negative — `OverlayControls`, `OverlayPlacement` and `overlayPlacement` are deleted by 1a and must not be reintroduced; `BlockHover` is the type 1a's strip and gutter already read to decide *which* block is lit, and this task only adds a field to it.
- Consumes (already in the tree): `CommandRegion`, `CommandBlock`, `Terminal.promptRows`, `Terminal.region(containing:memo:)`, `CommandRegionMemo`.
- Produces:

```swift
/// The block the keyboard is on. `CommandID` in the spec is this codebase's `UInt32` block id.
public struct BlockCursor: Equatable {
    public enum Direction: Equatable { case previous, next }
    public var commandID: UInt32?
    public init(commandID: UInt32? = nil)
    public var isEmpty: Bool
    public static func moved(_ current: Self, by direction: Direction, among ids: [UInt32]) -> Self
    public static func afterViewportMove(_ current: Self, visible: [UInt32], fallback: UInt32?) -> Self
    /// Where a ⌘↑/⌘↓ press starts from when the cursor is not on the screen the reader is looking
    /// at. nil = nothing to seed, so the press is an ordinary `moved`.
    public static func seed(_ current: Self, visible: [UInt32], viewportBlock: UInt32?) -> Self?
}
public enum BlockTarget {
    public static func resolve(cursor: BlockCursor, exists: (UInt32) -> Bool, fallback: UInt32?) -> UInt32?
}
public extension Terminal {
    /// Every block the keyboard can be on, oldest first.
    var blockCursorIDs: [UInt32] { get }
}
public extension BlockHover {
    enum Source: Equatable { case pointer, cursor }          // nested in the struct, not an extension
    var source: Source { get }                               // stored; defaults to .pointer
    static func resolve(cursor: BlockCursor, blocks: [CommandBlock], allowed: Bool) -> BlockHover?
    static func choose(pointer: BlockHover?, cursor: BlockHover?,
                       pointerInside: Bool, cursorMovedLast: Bool) -> BlockHover?
}
```

- [ ] **Step 1: Write the failing tests** — `Tests/NyxCoreTests/BlockCursorTests.swift`:

```swift
import Testing
@testable import NyxCore

private let ids: [UInt32] = [10, 20, 30, 40]

@Test func movingStepsOneBlockAtATime() {
    let start = BlockCursor(commandID: 30)
    #expect(BlockCursor.moved(start, by: .previous, among: ids).commandID == 20)
    #expect(BlockCursor.moved(start, by: .next, among: ids).commandID == 40)
}

/// Clamps rather than wraps: ⌘↑ at the oldest block must not jump to the newest, which is the
/// other end of a thousand rows of scrollback.
@Test func movingClampsAtBothEnds() {
    #expect(BlockCursor.moved(BlockCursor(commandID: 10), by: .previous, among: ids).commandID == 10)
    #expect(BlockCursor.moved(BlockCursor(commandID: 40), by: .next, among: ids).commandID == 40)
}

@Test func fromAClearedCursorPreviousTakesTheNewestAndNextTheOldest() {
    #expect(BlockCursor.moved(BlockCursor(), by: .previous, among: ids).commandID == 40)
    #expect(BlockCursor.moved(BlockCursor(), by: .next, among: ids).commandID == 10)
}

/// A block trimmed out of the buffer by scrollback is gone. The move re-anchors on the nearest
/// survivor in the direction of travel rather than stepping from a block that no longer exists --
/// stepping would silently skip whichever block took its place.
@Test func aTrimmedBlockReAnchorsOnTheNearestSurvivorInTheDirectionOfTravel() {
    let gone = BlockCursor(commandID: 25)
    #expect(BlockCursor.moved(gone, by: .previous, among: ids).commandID == 20)
    #expect(BlockCursor.moved(gone, by: .next, among: ids).commandID == 30)
}

@Test func aTrimmedBlockPastTheEndsClampsToTheEnds() {
    #expect(BlockCursor.moved(BlockCursor(commandID: 5), by: .previous, among: ids).commandID == 10)
    #expect(BlockCursor.moved(BlockCursor(commandID: 99), by: .next, among: ids).commandID == 40)
}

@Test func movingInAPaneWithNoBlocksClearsTheCursor() {
    #expect(BlockCursor.moved(BlockCursor(commandID: 30), by: .previous, among: []).commandID == nil)
}

// MARK: - Where a press starts from

/// ⌘↑ in a pane scrolled back two thousand rows must go up *from where the reader is*, not from
/// the bottom of the session. A cursor that is cleared -- or on a block that has scrolled away --
/// is seeded from the viewport's own block, and the press lands on that seed rather than stepping
/// over the output filling the screen. The second press steps.
@Test func cursorSeedsFromTheViewportWhenCleared() {
    #expect(BlockCursor.seed(BlockCursor(), visible: [20, 30], viewportBlock: 20)?.commandID == 20)
}

@Test func aCursorAlreadyOnScreenIsNotSeeded() {
    #expect(BlockCursor.seed(BlockCursor(commandID: 30), visible: [20, 30], viewportBlock: 20) == nil)
}

@Test func aCursorScrolledOffTheScreenSeedsFromTheViewport() {
    #expect(BlockCursor.seed(BlockCursor(commandID: 99), visible: [20, 30], viewportBlock: 30)?.commandID == 30)
}

/// Seeding onto the block the cursor already names would be a press that does nothing, so it is
/// declined and the press steps instead.
@Test func seedingIsDeclinedWhenItWouldNotMoveTheCursor() {
    #expect(BlockCursor.seed(BlockCursor(commandID: 20), visible: [30], viewportBlock: 20) == nil)
}

@Test func thereIsNothingToSeedFromInAPaneWithNoBlocks() {
    #expect(BlockCursor.seed(BlockCursor(), visible: [], viewportBlock: nil) == nil)
}

@Test func afterAViewportMoveTheCursorKeepsAVisibleBlock() {
    let kept = BlockCursor.afterViewportMove(BlockCursor(commandID: 20), visible: [20, 30], fallback: 30)
    #expect(kept.commandID == 20)
}

@Test func afterAViewportMoveABlockOffScreenTakesTheFallback() {
    let moved = BlockCursor.afterViewportMove(BlockCursor(commandID: 20), visible: [30, 40], fallback: 40)
    #expect(moved.commandID == 40)
}

@Test func afterAViewportMoveWithNoFallbackTheCursorClears() {
    let cleared = BlockCursor.afterViewportMove(BlockCursor(commandID: 20), visible: [30], fallback: nil)
    #expect(cleared.commandID == nil)
}

/// A pane nobody has pressed ⌘↑ in has no cursor, and scrolling must not give it one: the cursor
/// is drawn, so growing one on a scroll would light a block the user never asked about.
@Test func aClearedCursorStaysClearedThroughAViewportMove() {
    let still = BlockCursor.afterViewportMove(BlockCursor(), visible: [10, 20], fallback: 20)
    #expect(still.commandID == nil)
}

// MARK: - Which blocks the cursor may sit on

private func session(_ script: [(command: String, output: [String], status: Int32)]) -> Terminal {
    let t = Terminal(cols: 40, rows: 10, scrollbackLimit: 500)
    func mark(_ letter: String, _ status: Int32? = nil) -> String {
        "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
    }
    for step in script {
        t.feed(mark("A") + "$ " + mark("B") + step.command + "\r\n" + mark("C"))
        for line in step.output { t.feed(line + "\r\n") }
        t.feed(mark("D", step.status))
    }
    t.feed(mark("A") + "$ ")   // the prompt being typed at: no output, no status, not a block
    return t
}

/// The prompt you are typing at has an id and has run nothing. Landing ⌘↑ on it would raise a
/// strip with no summary and no Copy -- the first thing anybody pressing ⌘↑ would see.
@Test func theBlocksTheCursorMaySitOnExcludeThePromptBeingTypedAt() {
    let t = session([(command: "echo one", output: ["one"], status: 0),
                     (command: "make lint", output: ["Error 1"], status: 1),
                     (command: "echo three", output: ["three"], status: 0)])
    let cursorIDs = t.blockCursorIDs
    #expect(cursorIDs.count == 3)
    let promptID = t.command(containingAbsoluteRow: t.totalRows - 1)?.id
    #expect(promptID != nil && !cursorIDs.contains(promptID!))
    #expect(cursorIDs == cursorIDs.sorted())
}

@Test func aShellWithNoIntegrationOffersNoBlocksToSitOn() {
    let t = Terminal(cols: 40, rows: 10, scrollbackLimit: 100)
    t.feed("hello\r\nworld\r\n")
    #expect(t.blockCursorIDs.isEmpty)
}
```

  and, appended to `Tests/NyxCoreTests/BlockHoverTests.swift`:

```swift
// MARK: - The cursor's block is drawn as a hovered one

@Test func theCursorsBlockHoversItselfAndSaysSo() {
    let hover = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    #expect(hover?.id == 2)
    #expect(hover?.rows == 3..<19)
    #expect(hover?.headerRow == 3)
    #expect(hover?.source == .cursor)
}

@Test func aCursorOnABlockThatIsNotOnScreenHoversNothing() {
    #expect(BlockHover.resolve(cursor: BlockCursor(commandID: 99), blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(cursor: BlockCursor(), blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: false) == nil)
}

@Test func thePointerWinsWhileItIsInsideThePane() {
    let pointer = BlockHover.resolve(pointerRow: 1, blocks: blocks(), allowed: true)
    let cursor = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    let chosen = BlockHover.choose(pointer: pointer, cursor: cursor,
                                   pointerInside: true, cursorMovedLast: false)
    #expect(chosen?.id == 1)
    #expect(chosen?.source == .pointer)
}

/// Inside the pane but on no block at all: the pointer still wins, so the cursor's strip does not
/// appear under a pointer resting two rows below the last block.
@Test func aPointerInsideThePaneOnNoBlockShowsNothing() {
    let cursor = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    #expect(BlockHover.choose(pointer: nil, cursor: cursor,
                              pointerInside: true, cursorMovedLast: false) == nil)
}

@Test func theCursorReturnsWhenThePointerLeavesOrTheChordArrives() {
    let pointer = BlockHover.resolve(pointerRow: 1, blocks: blocks(), allowed: true)
    let cursor = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    #expect(BlockHover.choose(pointer: pointer, cursor: cursor,
                              pointerInside: false, cursorMovedLast: false)?.id == 2)
    #expect(BlockHover.choose(pointer: pointer, cursor: cursor,
                              pointerInside: true, cursorMovedLast: true)?.id == 2)
}

@Test func placingAHoverOnDisplayRowsKeepsItsSource() {
    let hover = try! #require(BlockHover.resolve(cursor: BlockCursor(commandID: 2),
                                                 blocks: blocks(), allowed: true))
    let display: [DisplayRow] = (0..<19).map { .row(12 + $0) }
    #expect(hover.placed(onDisplayRows: display, viewportTop: 12)?.source == .cursor)
    #expect(hover.attachingHeader(to: nil).source == .cursor)
}

// MARK: - Which block an action acts on

@Test func anActionTargetsTheCursorWhenThereIsOne() {
    #expect(BlockTarget.resolve(cursor: BlockCursor(commandID: 7), exists: { _ in true },
                                fallback: 9) == 7)
}

@Test func anActionFallsBackWhenTheCursorIsClearedOrItsBlockIsGone() {
    #expect(BlockTarget.resolve(cursor: BlockCursor(), exists: { _ in true }, fallback: 9) == 9)
    #expect(BlockTarget.resolve(cursor: BlockCursor(commandID: 7), exists: { _ in false },
                                fallback: 9) == 9)
    #expect(BlockTarget.resolve(cursor: BlockCursor(), exists: { _ in true }, fallback: nil) == nil)
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter BlockCursor 2>&1 | tail -20`
Expected: compile failure — `cannot find 'BlockCursor' in scope`, `value of type 'Terminal' has no member 'blockCursorIDs'`, `no member 'source'`.

- [ ] **Step 3: Write `Sources/NyxCore/Shell/BlockCursor.swift`**

```swift
import Foundation

/// The block the keyboard is on.
///
/// Eight block-scoped actions used to answer "which block" five different ways -- `commandToFold()`,
/// `lastFinishedCommand`, pointer-or-hovered-or-last, and newest-run-is-last -- so the pointer path
/// and the keyboard path targeted different blocks with nothing on screen to say which. Each of the
/// five was individually correct, which is why no unit test could have found it. One value replaces
/// them: moved by ⌘↑/⌘↓, re-anchored when the viewport moves for another reason, drawn as a hovered
/// block so it can never be a trap, and cleared when there is nothing to be on.
public struct BlockCursor: Equatable {
    public enum Direction: Equatable { case previous, next }

    /// The block, or nil for a pane nobody has pressed ⌘↑ in. nil is drawn as nothing at all.
    public var commandID: UInt32?

    public init(commandID: UInt32? = nil) { self.commandID = commandID }

    public var isEmpty: Bool { commandID == nil }

    /// One step, among the blocks the pane has, oldest first.
    ///
    /// Clamps rather than wraps: ⌘↑ held down at the top of a session must stop there, not appear
    /// a thousand rows away at the bottom. From a cleared cursor the first ⌘↑ takes the newest
    /// block and the first ⌘↓ the oldest, which is where each of those gestures already looks.
    ///
    /// A cursor whose block has been trimmed out of the scrollback re-anchors on the nearest
    /// survivor *in the direction of travel* rather than stepping from an id that no longer names
    /// anything: stepping from a hole skips whichever block now sits there.
    public static func moved(_ current: Self, by direction: Direction, among ids: [UInt32]) -> Self {
        guard let first = ids.first, let last = ids.last else { return BlockCursor() }
        guard let id = current.commandID else {
            return BlockCursor(commandID: direction == .previous ? last : first)
        }
        if let index = ids.firstIndex(of: id) {
            let step = direction == .previous ? index - 1 : index + 1
            return BlockCursor(commandID: ids[min(max(step, 0), ids.count - 1)])
        }
        switch direction {
        case .previous: return BlockCursor(commandID: ids.last(where: { $0 < id }) ?? first)
        case .next: return BlockCursor(commandID: ids.first(where: { $0 > id }) ?? last)
        }
    }

    /// The viewport moved for a reason other than ⌘↑/⌘↓ -- a scroll, new output, a fold.
    ///
    /// `fallback` is `Terminal.commandToFold()`'s answer. The cursor keeps its block while that
    /// block is still on screen, otherwise takes the fallback, and clears when there is no
    /// fallback either. A *cleared* cursor stays cleared: the cursor is drawn, and a pane that
    /// grew one on a scroll would light a block nobody asked about.
    public static func afterViewportMove(_ current: Self, visible: [UInt32], fallback: UInt32?) -> Self {
        guard let id = current.commandID else { return current }
        if visible.contains(id) { return current }
        return BlockCursor(commandID: fallback)
    }

    /// Where a ⌘↑/⌘↓ press starts from.
    ///
    /// A cursor that is cleared, or on a block that is not on the screen the reader is looking at,
    /// is seeded from that screen: `viewportBlock` is `commandToFold()`'s answer -- the block at
    /// the top of a scrolled-back viewport, the newest one at the bottom of the session. Without
    /// it, ⌘↑ in a pane wheeled back two thousand rows would take the newest block and throw the
    /// viewport to the bottom, where `previous_prompt` has always gone to the prompt above what
    /// the reader can see.
    ///
    /// The press then **lands on the seed** rather than stepping past it -- the same thing `moved`
    /// does with an id scrollback has trimmed, for the same reason: the block filling the screen is
    /// the one the reader means, and stepping over it skips the output they are in the middle of.
    /// A second press steps.
    ///
    /// nil when there is nothing to seed from, or when the seed is where the cursor already is, in
    /// which case the caller runs `moved` as usual.
    public static func seed(_ current: Self, visible: [UInt32], viewportBlock: UInt32?) -> Self? {
        if let id = current.commandID, visible.contains(id) { return nil }
        guard let seed = viewportBlock, seed != 0, seed != current.commandID else { return nil }
        return BlockCursor(commandID: seed)
    }
}

/// Which block a block-scoped action acts on: one rule, with the fallback each caller names.
///
/// The cursor is the answer whenever it names a block that is still in the buffer. The fallback is
/// only what a pane with *no cursor at all* means -- `commandToFold()` for the six ordinary
/// actions, the last request in the pane for the two that need a response -- and it is one
/// documented line per caller instead of five rules spread over four files.
public enum BlockTarget {
    public static func resolve(cursor: BlockCursor, exists: (UInt32) -> Bool,
                               fallback: UInt32?) -> UInt32? {
        if let id = cursor.commandID, exists(id) { return id }
        return fallback
    }
}

public extension Terminal {
    /// Every block the keyboard can be on, oldest first.
    ///
    /// A block is one the shell has actually run: it has output or a status. The prompt the user is
    /// typing at has an id and neither, and landing ⌘↑ on it would raise a strip with no summary,
    /// no Copy and nothing to fold -- the first thing anyone pressing ⌘↑ would see.
    ///
    /// Walks the buffer, so it belongs on a keystroke and not in a frame; `promptRows` says the
    /// same about itself. One `CommandRegionMemo` keeps it linear in the rows rather than
    /// quadratic in the block lengths.
    var blockCursorIDs: [UInt32] {
        guard shellEmitsPromptMarks else { return [] }
        let memo = CommandRegionMemo()
        var ids: [UInt32] = []
        for row in promptRows {
            guard let region = region(containing: row, memo: memo), region.id != 0,
                  region.outputStart != nil || region.exitStatus != nil else { continue }
            ids.append(region.id)
        }
        return ids
    }
}
```

- [ ] **Step 4: Add the source to `BlockHover`** in `Sources/NyxCore/Shell/CommandBlock.swift` — the stored field, the two new statics, and `source` carried through the two transforms that already exist:

```swift
public struct BlockHover: Equatable {
    /// What raised this hover. The pointer and the keyboard light a block the same way -- the
    /// cursor would be a trap otherwise -- but only one of them can be answered by moving a mouse,
    /// so the pane has to know which it is looking at.
    public enum Source: Equatable { case pointer, cursor }

    public let id: UInt32
    public let rows: Range<Int>
    public let headerRow: Int?
    public let source: Source

    public init(id: UInt32, rows: Range<Int>, headerRow: Int?, source: Source = .pointer) {
        self.id = id; self.rows = rows; self.headerRow = headerRow; self.source = source
    }

    public func attachingHeader(to row: Int?) -> BlockHover {
        BlockHover(id: id, rows: rows, headerRow: row, source: source)
    }

    public static func resolve(pointerRow: Int?, blocks: [CommandBlock], allowed: Bool) -> BlockHover? {
        guard allowed, let pointerRow,
              let block = blocks.first(where: { $0.visibleRows.contains(pointerRow) }),
              block.region.id != 0 else { return nil }
        return BlockHover(id: block.region.id, rows: block.visibleRows,
                          headerRow: block.showsHeader ? block.visibleRows.lowerBound : nil,
                          source: .pointer)
    }

    /// The block the keyboard is on, hovered exactly as the pointer would hover it.
    public static func resolve(cursor: BlockCursor, blocks: [CommandBlock],
                               allowed: Bool) -> BlockHover? {
        guard allowed, let id = cursor.commandID, id != 0,
              let block = blocks.first(where: { $0.region.id == id }) else { return nil }
        return BlockHover(id: id, rows: block.visibleRows,
                          headerRow: block.showsHeader ? block.visibleRows.lowerBound : nil,
                          source: .cursor)
    }

    /// Which of the two is drawn. The pointer wins while it is inside the pane; the cursor's
    /// presentation returns when the pointer leaves, and takes precedence for as long as ⌘↑/⌘↓ was
    /// the last thing pressed -- otherwise a pointer resting anywhere in the pane would make the
    /// chord look broken.
    public static func choose(pointer: BlockHover?, cursor: BlockHover?,
                              pointerInside: Bool, cursorMovedLast: Bool) -> BlockHover? {
        if let cursor, cursorMovedLast || !pointerInside { return cursor }
        return pointer
    }
}
```

  and, in the `placed(onDisplayRows:viewportTop:)` extension, the returned hover becomes
  `BlockHover(id: id, rows: slots, headerRow: headerSlot, source: source)`.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5`
Expected: PASS, and the whole suite still green (`BlockHoverTests`' existing cases compile unchanged because `source` defaults to `.pointer`).

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Shell/BlockCursor.swift Sources/NyxCore/Shell/CommandBlock.swift \
        Tests/NyxCoreTests/BlockCursorTests.swift Tests/NyxCoreTests/BlockHoverTests.swift
git commit -m "$(cat <<'EOF'
One rule for which block: BlockCursor, and a hover that says who raised it

Five rules answered "which block" for eight actions -- commandToFold, lastFinishedCommand,
pointer-or-hovered-or-last, newest-run-is-last -- each individually correct, which is why the
keyboard and the pointer could target different blocks with nothing on screen to say so.

`BlockCursor` is that answer as one value: clamped at both ends, taking the newest block from a
cleared cursor on ⌘↑ and the oldest on ⌘↓, re-anchoring on the nearest survivor when its block has
been trimmed out of the scrollback, seeded from the viewport when a press finds it cleared or off
the screen the reader is looking at, and re-anchored on `commandToFold()` when the viewport moves
for a reason it did not cause. A cleared cursor stays cleared through a scroll: it is drawn, and a
pane that grew one on a scroll would light a block nobody asked about. `Terminal.blockCursorIDs` says which blocks
it may sit on -- the ones that have run, never the prompt being typed at.

`BlockHover` gains a source and `choose`: the pointer wins while it is inside the pane, the cursor
returns when it leaves or the next ⌘↑/⌘↓ arrives. `BlockTarget.resolve` is the one rule the eight
actions will target, with the fallback each caller names.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The cursor in the pane, and a picture of it

**Files:**
- Modify: `Sources/NyxApp/Pane.swift` — the stored cursor and its two flags (beside `hoveredBlock`, `:136`); `jumpToPrompt(forward:)` (`:3487`); the frame pass's hover resolution (`:2001`); `clearScreen()` (`:4219`); `updateHover(at:)` / `clearHover()` (`:3096`)
- Modify: `Sources/NyxApp/GridSnapshot.swift` — `GridScene.keyboardCursor`, the hover decision in `build()`, and the two `composite-block-cursor-*` cases
- Test: no new unit test — every decision this task makes is Task 1's, already tested. The proof is the two pictures here and the rung-6 hook in Task 6.

**Interfaces:**
- Consumes (Task 1): `BlockCursor`, `BlockCursor.moved(_:by:among:)`, `BlockCursor.seed(_:visible:viewportBlock:)`, `BlockCursor.afterViewportMove(_:visible:fallback:)`, `Terminal.blockCursorIDs`, `BlockHover.resolve(cursor:blocks:allowed:)`, `BlockHover.choose(pointer:cursor:pointerInside:cursorMovedLast:)`.
- Consumes (plan 1a, spec §2.1–§2.6): the chrome that draws a hovered block — `CommandBlockChrome`'s strip plan and `StripPlan`, its gutter-cap rule and `GutterCap`, and `CommandBlockChrome.WidthClass` — all of which key off `Pane.hoveredBlock` and `GridScene`'s equivalent exactly as they do today. `OverlayControls` is gone; nothing here mentions it. From `GridSnapshot`: 1a's `GridScene.commandFitting(_ widthClass: CommandBlockChrome.WidthClass) -> UInt32?` — the fixture command line that leaves exactly that width class free, which is today's `commandFitting(_ controls: OverlayControls) -> UInt32?` (`GridSnapshot.swift:729`) re-typed when `OverlayControls` goes; it stays optional, and `BlockCursor(commandID:)` takes the optional as it is — and 1a's `composite-strip-<width>-<state>-*` names, which the `cmp` in Step 6 compares against.
- Produces: `Pane.blockCursor` (`private(set) var blockCursor: BlockCursor`), read by Tasks 3, 4 and 6 and by the rung-6 hook.

- [ ] **Step 1: The state and the chord.** In `Pane.swift`, beside `hoveredBlock`:

```swift
    /// The block the keyboard is on. Moved by ⌘↑/⌘↓, re-anchored by the frame pass when the
    /// viewport moved for another reason, and drawn exactly as a hovered block -- a cursor nobody
    /// can see is a trap. `private(set)` because the rule is `BlockCursor`'s and nothing outside
    /// this file may set it, but every block-scoped action and the QA hook read it.
    private(set) var blockCursor = BlockCursor()
    /// The viewport move ⌘↑/⌘↓ just made, which must not re-anchor the cursor it came from.
    /// Consumed by the next frame.
    private var blockCursorScrolledViewport = false
    /// ⌘↑/⌘↓ was the last thing pressed, so the cursor's block is drawn even with the pointer
    /// resting inside the pane. Cleared by the next pointer move.
    private var blockCursorWinsOverPointer = false
```

  and `jumpToPrompt(forward:)` becomes the cursor's mover:

```swift
    /// ⌘↑ / ⌘↓: one block back or forward, and the viewport brought to it.
    ///
    /// The block the chord lands on *is* the block cursor, so "where ⌘↑ took me" and "which block
    /// ⌘⇧A, Copy Output and ⌘. will act on" are one answer. It reports false only when there is
    /// nowhere to go and nothing moved -- the caller beeps rather than doing nothing silently.
    ///
    /// A cursor that is not on the screen in front of the reader is seeded from that screen first,
    /// so a pane wheeled back two thousand rows still goes *up from where the reader is* rather
    /// than to the newest block at the bottom -- which is where `previous_prompt` has always gone.
    /// `displayBlockRows` is the last frame's own blocks, which is exactly "the screen the reader
    /// is looking at"; `blockCursorIDs` walks the buffer, which is a keystroke's work and not a
    /// frame's -- the trade `promptRows` documents about itself, and the reason both calls are
    /// here rather than in `render`.
    @discardableResult
    func jumpToPrompt(forward: Bool) -> Bool {
        let onScreen = Array(displayBlockRows.keys)
        let outcome: (moved: Bool, cursor: BlockCursor) = session.withTerminal { t in
            let ids = t.blockCursorIDs
            let next = BlockCursor.seed(self.blockCursor, visible: onScreen,
                                        viewportBlock: t.commandToFold()?.id)
                ?? BlockCursor.moved(self.blockCursor, by: forward ? .next : .previous, among: ids)
            guard let id = next.commandID, let row = t.promptRow(ofCommand: id) else {
                return (false, next)
            }
            let scrolled = t.scrollToAbsoluteRow(row)
            return (scrolled || next != self.blockCursor, next)
        }
        blockCursor = outcome.cursor
        blockCursorScrolledViewport = true
        blockCursorWinsOverPointer = true
        if outcome.moved { markDirty() }
        return outcome.moved
    }
```

- [ ] **Step 2: Re-anchoring, and choosing what is drawn.** In `render()`, replace the single `self.hoveredBlock = self.resolveBlockHover(...)` assignment (`:2001`) with:

```swift
            // The viewport moved for a reason this cursor did not cause -- a scroll, new output, a
            // fold -- so the cursor re-anchors. Guarded twice on purpose: `BlockCursor` is the rule
            // and re-checks visibility itself, but `commandToFold()` walks the buffer and must not
            // be called on a frame where the answer cannot change. In steady state this is one
            // `contains` over the frame's own ids.
            let viewportSignature = (t.viewportTopRow, t.totalRows)
            if viewportSignature != self.lastViewportSignature {
                self.lastViewportSignature = viewportSignature
                if self.blockCursorScrolledViewport {
                    self.blockCursorScrolledViewport = false
                } else if let id = self.blockCursor.commandID {
                    // Built here and not above: on a frame where the viewport did not move -- which
                    // is almost every frame -- this allocates nothing at all.
                    let visibleIDs = blocks.map(\.region.id)
                    if !visibleIDs.contains(id) {
                        self.blockCursor = BlockCursor.afterViewportMove(self.blockCursor,
                                                                         visible: visibleIDs,
                                                                         fallback: t.commandToFold()?.id)
                    }
                }
            }
            let previousHover = self.hoveredBlock
            let pointerHover = self.resolveBlockHover(in: t, blocks: blocks, allowed: chromeAllowed,
                                                      viewportTop: windowTop)
            var cursorHover = BlockHover.resolve(cursor: self.blockCursor, blocks: blocks,
                                                 allowed: chromeAllowed)
            if !self.foldRowsOnScreen.isEmpty {
                cursorHover = cursorHover?.placed(onDisplayRows: self.foldRowsOnScreen,
                                                  viewportTop: windowTop)
            }
            self.hoveredBlock = BlockHover.choose(pointer: pointerHover, cursor: cursorHover,
                                                  pointerInside: self.pointerIsInsidePane,
                                                  cursorMovedLast: self.blockCursorWinsOverPointer)
```

  with, beside `lastPointerPoint` (`:3062`):

```swift
    /// `(viewportTopRow, totalRows)` as the last frame saw them. The cursor re-anchors when this
    /// moves and it was not ⌘↑/⌘↓ that moved it. A tuple and not a string: it is compared on every
    /// frame, and a frame must not allocate to find out that nothing happened.
    private var lastViewportSignature = (-1, -1)

    /// Whether the pointer is in this pane at all, which is what decides between the pointer's
    /// hover and the keyboard's.
    private var pointerIsInsidePane: Bool {
        guard let point = lastPointerPoint else { return false }
        return bounds.contains(point)
    }
```

- [ ] **Step 3: The pointer takes the presentation back.** In `updateHover(at:)`, on the path that records the point, and in `clearHover()`:

```swift
        // A pointer move hands the presentation back to the pointer; ⌘↑/⌘↓ takes it again.
        blockCursorWinsOverPointer = false
```

  and in `clearScreen()`, after the feed:

```swift
        // Every id in the buffer names rows that are gone. A cursor kept across ⌘K would sit on a
        // stranger's command, exactly as a kept watch header would.
        blockCursor = BlockCursor()
```

- [ ] **Step 4: The picture.** In `GridSnapshot.swift`, `GridScene` gains

```swift
    /// The block the keyboard is on. A picture of the cursor sets this and leaves `hovered` nil:
    /// the strip has to come up with no pointer in the scene at all.
    var keyboardCursor = BlockCursor()
```

  and `build()` decides the raised block **once**, before the block loop, through the same Core rule the pane uses:

```swift
        // `hovered` stops being read directly anywhere below: it is the *pointer's* input to
        // `choose` and nothing else, and `raised` is the answer. Three places read it, and a
        // picture with only one of them switched over is a picture of a bug.
        let raised = BlockHover.choose(
            pointer: hovered.flatMap { id in
                blocks.first { $0.region.id == id }
                    .map { BlockHover(id: id, rows: $0.visibleRows,
                                      headerRow: $0.showsHeader ? $0.visibleRows.lowerBound : nil) }
            },
            cursor: BlockHover.resolve(cursor: keyboardCursor, blocks: blocks, allowed: chromeAllowed),
            pointerInside: hovered != nil,
            cursorMovedLast: !keyboardCursor.isEmpty)?.id
```

  and every reader of `hovered` below becomes a reader of `raised`. There are three:

  1. the strip's condition inside the block loop — `if raised == block.region.id {`;
  2. the **row tint**, `RenderFrame.highlightedRows` (`GridSnapshot.swift:1005`), whose closure over `hovered` becomes

```swift
                                highlightedRows: raised.flatMap { id in
                                    blocks.first { $0.region.id == id }.flatMap {
                                        DisplayRows.slots(coveredBy: $0.visibleRows,
                                                          commandID: id, in: display,
                                                          viewportTop: windowTop)
                                    }
                                })
```

  3. the **gutter cap**: after plan 1a the cap's `hovered:` argument is answered from the raised block's id (`Pane.render` asks `self.hoveredBlock?.id == block.region.id`, `1a Task 2`), and whatever field 1a's `Built` carries that id in is filled from `raised` here, not from `hovered`.

  Miss any of the three and `composite-block-cursor-*` renders a strip with no tint under it and no hover glyph in the gutter — which Step 6's `cmp` then reports as a difference against the pointer's picture.

- [ ] **Step 5: The two cases.** In `GridSnapshot.Case`, `case blockCursor(CommandBlockChrome.WidthClass)`; in `write`'s switch,

```swift
        case .blockCursor(let widthClass):
            // No pointer anywhere in this scene: the strip is up because ⌘↑ put the cursor here.
            scene.keyboardCursor = BlockCursor(commandID: scene.commandFitting(widthClass))
```

  and in `run(into:config:)`, inside the appearance loop:

```swift
                for (widthClass, label) in [(CommandBlockChrome.WidthClass.w3, "w3"),
                                            (CommandBlockChrome.WidthClass.w1, "w1")] {
                    write(canvas: canvas, palette: palette, appearance: appearance,
                          case: .blockCursor(widthClass), into: directory,
                          named: "composite-block-cursor-\(label)-\(suffix)")
                }
```

- [ ] **Step 6: Render and look at them**

Run:
```bash
swift build 2>&1 | grep -c warning; ./scripts/bundle.sh
NYX_UI_SNAPSHOT=/tmp/nyx-1b ./build/Nyx.app/Contents/MacOS/Nyx
cmp /tmp/nyx-1b/composite-block-cursor-w3-nyx-dark-dark.png \
    /tmp/nyx-1b/composite-strip-w3-finished-nyx-dark-dark.png
cmp /tmp/nyx-1b/composite-block-cursor-w1-nyx-dark-dark.png \
    /tmp/nyx-1b/composite-strip-w1-finished-nyx-dark-dark.png
```
Expected: **byte-identical, and that is the assertion** — §2.8 says the cursor's block is drawn *exactly* as a hovered one, so a difference is a bug, and identity proves the whole presentation came up with no pointer in the scene. A difference here is almost always one of Step 4's three readers of `hovered` left unswitched: `cmp` says which byte, and the tint (row-wide) and the gutter cap (3 pt at the left margin) are told apart at a glance. Then Read the four PNGs (both appearances) and check the tint covers the block's rows, the gutter cap is the hover glyph, and the strip is the one §2.6's table gives that width class.

- [ ] **Step 7: Commit**

```bash
git add Sources/NyxApp/Pane.swift Sources/NyxApp/GridSnapshot.swift
git commit -m "$(cat <<'EOF'
⌘↑ and ⌘↓ move a cursor you can see

The pane holds one `BlockCursor`. ⌘↑/⌘↓ move it among the blocks that have run and bring the
viewport to the one they land on, so "where the chord took me" and "which block the next action
acts on" are the same answer. Any other viewport move -- a scroll, new output, a fold -- re-anchors
it through `BlockCursor.afterViewportMove`, and only on the frame where its block has actually left
the screen, so the frame pass pays one `contains` and never a buffer walk.

It is drawn as a hovered block, because a cursor nobody can see is a trap: the same tint, the same
gutter chevron and the same strip, chosen by `BlockHover.choose`. The pointer wins while it is
inside the pane; the cursor takes the presentation back when the pointer leaves or the chord is
pressed again. ⌘K clears it -- every id it could hold names rows that are gone.

`composite-block-cursor-{w3,w1}` come out byte-identical to their hovered twins, with no pointer
anywhere in the scene, which is the check that the two paths really are one drawing.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The eight actions target the cursor, and four titles stop saying "Last"

**Files:**
- Modify: `Sources/NyxCore/Config/ActionCatalog.swift` — four titles (`:44`, `:56`, `:57`, and `editAndRunCommand` at `:49`)
- Modify: `Sources/NyxApp/Pane.swift` — the two target helpers; `toggleFoldOfCurrentCommand()` (`:3762`), `selectCommandOutput()` (`:3878`), `performOnBlockCursor(_:)` replacing `copyLastCommandOutput()` (`:3892`), `copyLastCommandAsMarkdown()` (`:3906`), `saveLastCommandOutput()` (`:3919`) and `editAndRunLastCommand()` (`:4371`); `lensTargetBlock()` (`:967`) deleted; `toggleLensOfCurrentBlock()` (`:957`); `hasResponseToLens` (`:906`); `latestRequestBlock()` (`:1271`) taking a terminal; `canStopWatch` (`:1263`)
- Modify: `Sources/NyxApp/TabController.swift` — `perform` (`:1493`–`:1519`, `:1558`), `canPerform` (`:1606`, `:1623`, `:1627`)
- Modify: `docs/configuration.md` — the five rows whose scope sentence is now "the block the keyboard is on"
- Test: `Tests/NyxCoreTests/ActionCatalogTests.swift`

**Interfaces:**
- Consumes (Task 1): `BlockTarget.resolve(cursor:exists:fallback:)`. (Task 2): `Pane.blockCursor`.
- Consumes (plan 1a, spec §2.1–§2.6): nothing new. §2.3's `Stop` pill label (`Stop watching this request`) was 1a's; this task is what makes the pill's scope and ⌘.'s scope the same block, which is the other half of a11y 6.9.
- Consumes (already in the tree): `Pane.perform(_ action: BlockAction, on id: UInt32)` — the one implementation of every block act, which these actions now call rather than re-implement.
- Produces: `Pane.hasBlockTarget: Bool` and `Pane.performOnBlockCursor(_ action: BlockAction) -> Bool`, used by Task 4's `canPerform` and `showBlockActions`.

- [ ] **Step 1: Write the failing title test** — in `Tests/NyxCoreTests/ActionCatalogTests.swift`:

```swift
/// The menu bar must not say "Last" for an action that targets the block the keyboard is on: the
/// user can put the cursor three blocks up, and a row promising the *last* command would be a
/// menu that lies about what pressing it does.
@Test func theBlockScopedTitlesNameTheBlockRatherThanTheLastOne() {
    let scoped: [TerminalAction] = [.selectCommandOutput, .copyCommandOutput, .copyBlockMarkdown,
                                    .saveCommandOutput, .editAndRunCommand, .foldCommand,
                                    .toggleHTTPLens, .stopWatch]
    for action in scoped {
        #expect(!action.title.contains("Last"), "\(action.configName) still says Last")
    }
    #expect(TerminalAction.copyCommandOutput.title == "Copy Command Output")
    #expect(TerminalAction.copyBlockMarkdown.title == "Copy Command as Markdown")
    #expect(TerminalAction.saveCommandOutput.title == "Save Command Output\u{2026}")
    #expect(TerminalAction.editAndRunCommand.title == "Edit This Command\u{2026}")
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter theBlockScopedTitles 2>&1 | tail -10`
Expected: FAIL — `copy_command_output still says Last`.

- [ ] **Step 3: Change the four titles** in `ActionCatalog.swift`:

```swift
        case .copyCommandOutput: return "Copy Command Output"
        case .editAndRunCommand: return "Edit This Command\u{2026}"
        case .copyBlockMarkdown: return "Copy Command as Markdown"
        case .saveCommandOutput: return "Save Command Output\u{2026}"
```

Run: `swift test --no-parallel --filter ActionCatalog 2>&1 | tail -5` → PASS (`actionTitlesAreDistinct` still holds; none of the four collides).

- [ ] **Step 4: The two target helpers** in `Pane.swift`, beside `blockCursor`:

```swift
    /// The block a block-scoped action acts on: the one the keyboard is on, else the one
    /// `commandToFold()` names -- the running command at the bottom, or the command at the top of
    /// the screen when scrolled back. One rule with one documented fallback, where there were five.
    private func targetBlockID(in t: Terminal) -> UInt32? {
        BlockTarget.resolve(cursor: blockCursor,
                            exists: { t.promptRow(ofCommand: $0) != nil },
                            fallback: t.commandToFold()?.id)
    }

    private func targetBlock(in t: Terminal) -> CommandRegion? {
        guard let id = targetBlockID(in: t), let row = t.promptRow(ofCommand: id) else { return nil }
        return t.command(containingAbsoluteRow: row)
    }

    /// The block the two request actions act on. The cursor's, when it is a request; otherwise the
    /// last request in the pane, which is the same answer for the same reason it always was --
    /// "the response you were just looking at".
    private func targetRequestBlockID(in t: Terminal) -> UInt32? {
        BlockTarget.resolve(cursor: blockCursor,
                            exists: { self.requestCache.isRequest(id: $0) && t.promptRow(ofCommand: $0) != nil },
                            fallback: self.latestRequestBlock(in: t))
    }

    /// Whether any block-scoped action has something to act on. What the menu bar and the palette
    /// gate `block_actions` and the other eight rows on.
    var hasBlockTarget: Bool { session.withTerminal { self.targetBlock(in: $0) != nil } }

    /// `copy_command_output`, `copy_block_markdown`, `save_command_output` and
    /// `edit_and_run_command` are the same acts as the ⋯ menu rows of the same name, on the same
    /// block. One implementation, so a chord and a row cannot drift apart -- `Copy Output` on a
    /// lensed response copies what is on the screen either way, which four separate copies of this
    /// code did not.
    @discardableResult
    func performOnBlockCursor(_ action: BlockAction) -> Bool {
        guard let id = session.withTerminal({ self.targetBlockID(in: $0) }) else { return false }
        perform(action, on: id)
        return true
    }
```

- [ ] **Step 5: Point the eight at it.** In `Pane.swift`:

```swift
    /// `fold_command`: folds the block the keyboard is on, and unfolds it again.
    @discardableResult
    func toggleFoldOfCurrentCommand() -> Bool {
        let commandID: UInt32? = session.withTerminal { t in
            // The same predicate the gutter cap and the menu row use, so ⌘⇧↑ cannot fold a
            // screenful of blank rows a command has not filled in yet.
            guard let region = self.targetBlock(in: t),
                  t.commandHasOutput(atAbsoluteRow: region.promptRow) else { return nil }
            return region.id
        }
        guard let id = commandID, id != 0 else { return false }
        toggleFold(ofCommand: id, full: NSEvent.modifierFlags.contains(.option))
        return true
    }

    /// `select_command_output`: the output of the block the keyboard is on -- the same block ⌘⇧↑
    /// folds, and the same one ⌥-clicking its gutter mark selects.
    @discardableResult
    func selectCommandOutput() -> Bool {
        let selection: Selection? = session.withTerminal { t in
            guard let region = self.targetBlock(in: t) else { return nil }
            return t.selectionForOutput(of: region)
        }
        guard let selection else { return false }
        session.withTerminal { t in _ = selectionController.replace(with: selection, in: t) }
        markDirty()
        return true
    }
```

  delete `copyLastCommandOutput()`, `copyLastCommandAsMarkdown()`, `saveLastCommandOutput()`, `editAndRunLastCommand()` and `lensTargetBlock()` outright, and rewrite the request three:

```swift
    var hasResponseToLens: Bool {
        session.withTerminal { self.targetRequestBlockID(in: $0) != nil }
    }

    /// `⌘⇧J` and the lens chip: pretty ↔ raw, on the block the keyboard is on when that is a
    /// request, else the last request in the pane.
    @discardableResult
    func toggleLensOfCurrentBlock() -> Bool {
        guard let id = session.withTerminal({ self.targetRequestBlockID(in: $0) }) else { return false }
        guard !lensIsTooLarge(id) else { return false }
        setLens(lenses.lens(of: id) == nil ? .pretty : nil, on: id)
        return true
    }

    /// The last block in the pane whose command was a request. Takes the terminal rather than
    /// opening the session itself: every caller now asks it from inside a `withTerminal` block.
    private func latestRequestBlock(in t: Terminal) -> UInt32? {
        t.promptRows.reversed().compactMap { row -> UInt32? in
            guard let region = t.command(containingAbsoluteRow: row), region.id != 0,
                  self.requestCache.isRequest(id: region.id) else { return nil }
            return region.id
        }.first
    }

    /// Whether `⌘.` has a series to stop here: the block the keyboard is on must be the series'
    /// newest run. With no cursor that is the old rule word for word -- the newest run is the last
    /// request in the pane, so a watch scrolled away from cannot be killed by a chord pressed for
    /// something else -- and with one, the chord and the strip's `Stop` pill finally name the same
    /// series (a11y 6.9). A series that has not run anything yet passes: nothing can be later than
    /// nothing.
    var canStopWatch: Bool {
        guard let series = watch, !series.isFinished else { return false }
        guard let newest = series.runs.last?.id else { return true }
        return session.withTerminal { self.targetRequestBlockID(in: $0) } == newest
    }
```

  In `TabController.perform`:

```swift
        case .selectCommandOutput: if focusedPane?.selectCommandOutput() != true { NSSound.beep() }
        case .copyCommandOutput: if focusedPane?.performOnBlockCursor(.copyOutput) != true { NSSound.beep() }
        case .editAndRunCommand: if focusedPane?.performOnBlockCursor(.editAndRun) != true { NSSound.beep() }
        case .copyBlockMarkdown: if focusedPane?.performOnBlockCursor(.copyMarkdown) != true { NSSound.beep() }
        case .saveCommandOutput: if focusedPane?.performOnBlockCursor(.saveOutput) != true { NSSound.beep() }
```

  and in `canPerform`, the marks-gated group gains the target:

```swift
        case .previousPrompt, .nextPrompt, .foldAllLongOutput:
            // A shell with no integration emits no marks, and these do nothing without them.
            return focusedPane?.hasPromptMarks ?? false
        case .selectCommandOutput, .copyCommandOutput, .foldCommand, .copyBlockMarkdown,
             .saveCommandOutput:
            // Marks, and a block for the cursor to be on. Greyed rather than beeping.
            return focusedPane?.hasBlockTarget ?? false
```

- [ ] **Step 6: Prove the old names are gone and the suite is green**

Run:
```bash
grep -rn "copyLastCommandOutput\|copyLastCommandAsMarkdown\|saveLastCommandOutput\|editAndRunLastCommand\|lensTargetBlock" Sources Tests
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
```
Expected: the grep prints nothing, the warning count is `0`, the suite passes.

- [ ] **Step 7: Rewrite the scope sentences** in `docs/configuration.md` (the rows at `:132`, `:135`, `:138`, `:139`, `:140`, `:147`, `:148`):

```markdown
| `select_command_output` / `copy_command_output` | — | The output of the block the keyboard is on — moved by ⌘↑/⌘↓, and the last command when nothing has moved it |
| `edit_and_run_command` | ⌘E | Opens the command of the block the keyboard is on in the editor |
| `fold_command` / `fold_all_long_output` | ⌘⇧↑ / — | Folds the block the keyboard is on, keeping its last lines / folds every long one |
| `copy_block_markdown` | — | That block and its output as a fenced Markdown block |
| `save_command_output` | — | Writes that block's output to a file the user chooses |
| `toggle_http_lens` | ⌘⇧J | Flips the block the keyboard is on — or the last response in the pane — between `pretty` and `raw`. Greyed when the pane has no request to show |
| `stop_watch` | ⌘. | Stops the watch running in this pane, while the block the keyboard is on is the series' newest run. Greyed in the menu and absent from the palette when there is no such series; the strip's **Stop** button names the same series, so the two no longer diverge. `⌘K` (clear the pane) also stops a running series and *forgets* it — every run's block id names rows that are gone, so a kept header would sit on a stranger's command |
```

  and, under the table, the sentence that says which block: `⌘↑ / ⌘↓ move the block cursor — the block Nyx draws as hovered and every block action acts on; it clears with ⌘K and follows the screen when you scroll.`

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxCore/Config/ActionCatalog.swift Sources/NyxApp/Pane.swift \
        Sources/NyxApp/TabController.swift Tests/NyxCoreTests/ActionCatalogTests.swift \
        docs/configuration.md
git commit -m "$(cat <<'EOF'
Eight actions, one block: the cursor is what they act on, and the titles stop saying Last

`fold_command`, `select_command_output`, `copy_command_output`, `copy_block_markdown`,
`save_command_output`, `edit_and_run_command`, `toggle_http_lens` and `stop_watch` all resolve
through `BlockTarget.resolve` on the block cursor. The fallback for a pane nobody has pressed ⌘↑ in
is one documented line per caller -- `commandToFold()` for the six, the last request in the pane
for the two that need a response -- so the old behaviour is unchanged where there is no cursor, and
`lensTargetBlock`'s pointer clause, which silently disagreed with every other rule, is gone.

Four of the four now target a block the user chose, so `Copy Last Command Output` becomes
`Copy Command Output`, `Copy Last Command as Markdown` becomes `Copy Command as Markdown`,
`Save Last Command Output…` becomes `Save Command Output…` and `Edit Command Line…` becomes
`Edit This Command…`. The other four keep their titles.

The four copies of "copy/save/edit this block" in the pane are deleted: the chords call
`perform(_:on:)`, the same implementation the ⋯ menu rows call, so `Copy Output` on a lensed
response copies what is on the screen from either route. ⌘. and the strip's `Stop` name the same
series now, which is the second half of a11y 6.9, and `docs/configuration.md` says so.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `block_actions` (⌘⇧A), `view.menu`, and `scroll_to_sticky_prompt`

**Files:**
- Modify: `Sources/NyxCore/Config/KeyBinding.swift` — two `TerminalAction` cases, one default binding
- Modify: `Sources/NyxCore/Config/ActionCatalog.swift` — two titles, two rows in the Go section
- Modify: `Sources/NyxApp/Pane.swift` — `blockMenuHeader(for:needsPreviousRun:)` and `blockMenu(for:)` extracted from `contextMenu(at:)` (`:2942`); `showBlockActions()`, `blockMenuAnchor(forCommand:)`, `displaySlot(ofCommand:)`, `updateBlockMenu()`; `hasStickyPrompt`; `scrollToStickyPrompt()` (`:3648`) made internal and answering a `Bool`
- Modify: `Sources/NyxApp/TabController.swift` — `perform`, `canPerform`
- Modify: `docs/configuration.md` — two rows in the bindings table
- Test: `Tests/NyxCoreTests/KeyBindingTests.swift`, `Tests/NyxCoreTests/ActionCatalogTests.swift`

**Interfaces:**
- Consumes (Task 2): `Pane.blockCursor`. (Task 3): `Pane.hasBlockTarget`, `targetBlockID(in:)`.
- Consumes (plan 1a, spec §2.1–§2.6): §2.3's rule that `Actions ▾` and `⋯` "open the menu `block_actions` opens" — this task is the other end of that sentence, and the menu it pops is the one `BlockHeaderView.morePressed` builds. 1a's `StripPlan.pills` decides whether that pill is drawn; ⌘⇧A does not care, because the menu exists at every width class including W0, where no strip is drawn at all.
- Consumes (already in the tree): `BlockHeader.actions`, `BlockHeader.title(for:)`, `BlockHeader.isChecked(_:)`, `BlockAction.startsGroup`, `Pane.previousRun(of:)`, `Pane.blockActionFromMenu(_:)`, `Pane.BlockMenuEntry`.
- Produces: `Pane.blockMenu(for id: UInt32) -> NSMenu?` and `Pane.blockMenuHeader(for id: UInt32, needsPreviousRun: Bool) -> BlockHeader?`, both used by Task 5 (chords) and Task 6 (the announcement's sentence, and the QA hook).

- [ ] **Step 1: Write the failing tests** — in `Tests/NyxCoreTests/ActionCatalogTests.swift`:

```swift
/// The one keyboard route to everything the hover strip offers. Without a chord it is not a route.
@Test func theBlockAndStickyActionsAreInTheGoSectionWithTheirTitles() {
    #expect(TerminalAction.blockActions.title == "Command Actions\u{2026}")
    #expect(TerminalAction.scrollToStickyPrompt.title == "Go to the Pinned Command")
    #expect(TerminalAction.blockActions.configName == "block_actions")
    #expect(TerminalAction.scrollToStickyPrompt.configName == "scroll_to_sticky_prompt")
    let go = ActionCatalog.sections.first { $0.title == "Go" }
    #expect(go?.actions.contains(.blockActions) == true)
    #expect(go?.actions.contains(.scrollToStickyPrompt) == true)
}
```

  and in `Tests/NyxCoreTests/KeyBindingTests.swift`, inside `theDefaultsCoverTheSpecTable`:

```swift
    #expect(has([.cmd, .shift], .char("a"), .blockActions))
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter "GoSection|theDefaultsCover" 2>&1 | tail -10`
Expected: compile failure — `type 'TerminalAction' has no member 'blockActions'`.

- [ ] **Step 3: The two actions, all the way through the checklist.** `KeyBinding.swift`:

```swift
    case blockActions = "block_actions"
    case scrollToStickyPrompt = "scroll_to_sticky_prompt"
```

  and, in `defaults` (⌘⇧A is free; `noTwoDefaultsShareAChord` is the guard, and it is Warp's chord for the same act):

```swift
        KeyBinding(key: .char("a"), modifiers: [.cmd, .shift], action: .blockActions),
```

  `ActionCatalog.swift`:

```swift
        case .blockActions: return "Command Actions\u{2026}"
        case .scrollToStickyPrompt: return "Go to the Pinned Command"
```

  and the Go section becomes (`.blockActions` first in the block group, because it is the row that contains all the others; `.scrollToStickyPrompt` beside the two prompt jumps, which is the other thing that moves the screen to a command):

```swift
        Section(title: "Go", groups: [
            Group([.commandPalette]),
            Group([.previousPrompt, .nextPrompt, .scrollToStickyPrompt]),
            Group([.blockActions, .selectCommandOutput, .copyCommandOutput, .copyBlockMarkdown,
                   .saveCommandOutput]),
            Group([.editAndRunCommand]),
            Group([.foldCommand, .foldAllLongOutput]),
            Group([.notifyWhenDone]),
            Group([.toggleHTTPLens, .stopWatch]),
            Group([.remoteTakeControl]),
        ]),
```

- [ ] **Step 4: One builder for the block menu.** In `Pane.swift`, extract from `contextMenu(at:)`:

```swift
    /// The header a block's menu is built from: the one the frame drew, plus the one answer that is
    /// too expensive to have per frame.
    ///
    /// Reaches blocks the frame never built a header for -- one whose prompt row is scrolled off
    /// the top still has every output row on screen, and the block cursor can be on it -- so the
    /// request summary is read here as well as in `render`.
    func blockMenuHeader(for id: UInt32, needsPreviousRun: Bool = true) -> BlockHeader? {
        // Asked before the lock: finding the previous run of this request parses command lines out
        // of the cache, and this is a menu press rather than a frame.
        let previousRun = needsPreviousRun ? self.previousRun(of: id) : nil
        let header: BlockHeader? = session.withTerminal { t in
            guard let row = t.promptRow(ofCommand: id),
                  let region = t.command(containingAbsoluteRow: row) else { return nil }
            let block = CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true)
            let httpSummary = self.requestSummary(for: block, in: t)
            return block.header(now: t.now(), folding: self.folding,
                                notifyArmed: self.armedNotifications.contains(id),
                                anyFolds: !self.folding.isEmpty,
                                hasOutput: t.commandHasOutput(atAbsoluteRow: region.promptRow),
                                httpSummary: httpSummary,
                                isHTTP: self.requestCache.isRequest(id: id),
                                lens: self.lenses.lens(of: id),
                                lensTooLarge: self.lensIsTooLarge(id),
                                bodyIsJSON: self.bodyIsJSON(id),
                                hasPreviousRun: previousRun != nil,
                                watch: self.watchHeader(forBlock: id),
                                watchInterval: self.config.httpWatchInterval)
        }
        drainPendingRecord()
        return header
    }

    /// One block's menu: `BlockHeader.actions` in order, a separator wherever `startsGroup`, the
    /// title from `title(for:)` and the tick from `isChecked`. The ⋯ button, the right-click menu,
    /// ⌘⇧A and `view.menu` all pop *this*, so the four routes cannot offer different things.
    func blockMenu(for id: UInt32) -> NSMenu? {
        guard let header = blockMenuHeader(for: id) else { return nil }
        let menu = NSMenu()
        for (index, entry) in header.actions.enumerated() {
            if index > 0 && entry.action.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: header.title(for: entry.action),
                                  action: #selector(blockActionFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = BlockMenuEntry(action: entry.action, id: id)
            item.isEnabled = entry.enabled
            item.state = header.isChecked(entry.action) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
```

  and `contextMenu(at:)`'s block half becomes the four lines that move those items into the bigger menu:

```swift
        if let point, let id = commandID(under: point), let block = blockMenu(for: id) {
            for item in block.items {
                block.removeItem(item)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
```

- [ ] **Step 5: ⌘⇧A pops it at the cursor's row, and VoiceOver finds it.** In `Pane.swift`:

```swift
    /// `block_actions`: the block menu, at the row of the block the keyboard is on.
    ///
    /// The one keyboard route to everything the strip offers -- Copy, Stop, the lens chip, the
    /// dots, and the twenty-odd rows that never had one. Nothing is removed from the strip; this
    /// is the route that did not exist, because `Pane.keyDown` sends a bare ⇥ to the PTY and no
    /// key-view loop over a pane's chrome is possible (a11y 0.1).
    @discardableResult
    func showBlockActions() -> Bool {
        guard let id = session.withTerminal({ self.targetBlockID(in: $0) }),
              let menu = blockMenu(for: id) else { return false }
        menu.popUp(positioning: nil, at: blockMenuAnchor(forCommand: id), in: self)
        return true
    }

    /// Where the menu drops from: the leading edge of the block's own command row, so the menu
    /// belongs to the block visibly as well as logically. A block scrolled off the top anchors at
    /// the top of the pane rather than off-screen.
    private func blockMenuAnchor(forCommand id: UInt32) -> NSPoint {
        let cell = cellSizePoints
        guard let slot = displaySlot(ofCommand: id), cell.height > 0 else {
            return NSPoint(x: CGFloat(padding), y: bounds.height)
        }
        // The view is unflipped: y grows upward, and a menu that drops down from a row starts at
        // that row's bottom edge.
        return NSPoint(x: CGFloat(padding),
                       y: bounds.height - CGFloat(padding) - CGFloat(slot + 1) * cell.height)
    }

    /// Which slot on screen a block's command row landed in, through whatever folds and lenses the
    /// last frame drew. nil when the block is not on screen at all.
    private func displaySlot(ofCommand id: UInt32) -> Int? {
        guard let promptRow = displayBlockRows[id] else { return nil }
        guard !foldRowsOnScreen.isEmpty else {
            let slot = promptRow - session.withTerminal { $0.viewportTopRow }
            return (0..<rows).contains(slot) ? slot : nil
        }
        return foldRowsOnScreen.firstIndex {
            if case .row(let absolute) = $0 { return absolute == promptRow }
            return false
        }
    }

    /// The cursor's menu, hung on the view so VoiceOver's VO-⇧-M finds it (a11y 6.4).
    ///
    /// Rebuilt on ⌘↑/⌘↓ and nowhere else: building a menu costs a header, a request summary and a
    /// previous-run search, which is a keystroke's work and not a frame's. `rightMouseDown` never
    /// calls `super`, so this menu cannot steal the right-click one; and a menu left standing after
    /// its block was trimmed does nothing dangerous, because `perform(_:on:)` resolves the id and
    /// beeps when the block has gone.
    private func updateBlockMenu() {
        menu = blockCursor.commandID.flatMap { blockMenu(for: $0) }
    }
```

  called from `jumpToPrompt` (after `blockCursor = outcome.cursor`) and from `clearScreen()` (after the cursor is cleared).

  The sticky strip's click gains its action:

```swift
    /// Whether the sticky strip is up, which is what `scroll_to_sticky_prompt` is enabled by.
    var hasStickyPrompt: Bool { stickyPromptRow != nil }

    /// The strip's click and `scroll_to_sticky_prompt`: go to the command it names. The point of
    /// pinning it is to be able to get back to where the output started.
    @discardableResult
    func scrollToStickyPrompt() -> Bool {
        guard let row = stickyPromptRow else { return false }
        session.withTerminal { t in _ = t.scrollToAbsoluteRow(row) }
        onFocusRequested?()
        markDirty()
        return true
    }
```

  In `TabController.perform`:

```swift
        case .blockActions: if focusedPane?.showBlockActions() != true { NSSound.beep() }
        case .scrollToStickyPrompt: if focusedPane?.scrollToStickyPrompt() != true { NSSound.beep() }
```

  and in `canPerform`:

```swift
        case .blockActions:
            // The cursor has to resolve to a block. Greyed on a shell with no integration and on a
            // pane where nothing has run.
            return focusedPane?.hasBlockTarget ?? false
        case .scrollToStickyPrompt:
            // Only while a command is actually pinned at the top.
            return focusedPane?.hasStickyPrompt ?? false
```

- [ ] **Step 6: Run the tests and build**

Run: `swift build 2>&1 | grep -c "warning:"; pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5`
Expected: `0` warnings, PASS — including `everyActionAppearsInTheMenuExactlyOnce` and `noTwoDefaultsShareAChord`, which are what say the two new actions were added everywhere and that ⌘⇧A collides with nothing.

- [ ] **Step 7: Document the two chords** — in `docs/configuration.md`'s bindings table, after the `command_palette` row:

```markdown
| `block_actions` | ⌘⇧A | Opens the block menu — every action the hover strip offers — on the block the keyboard is on, at its own row |
| `scroll_to_sticky_prompt` | — | Scrolls back to the command pinned at the top of the pane |
```

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxCore/Config/KeyBinding.swift Sources/NyxCore/Config/ActionCatalog.swift \
        Sources/NyxApp/Pane.swift Sources/NyxApp/TabController.swift \
        Tests/NyxCoreTests/ActionCatalogTests.swift Tests/NyxCoreTests/KeyBindingTests.swift \
        docs/configuration.md
git commit -m "$(cat <<'EOF'
⌘⇧A: the block's own menu, at the block the keyboard is on

The hover strip could not be raised without a pointer, and its ⋯ menu -- twenty-six rows, the only
route to Copy, Stop, the lens and the dots for a keyboard user -- had no chord at all. `Pane.keyDown`
sends a bare ⇥ to the PTY and `PaneTreeView` declines first responder, so a `TerminalAction` is the
only fix there can be (a11y 0.1, 6.4).

`block_actions` (⌘⇧A, free, and Warp's chord for the same act) pops the menu at the cursor's row,
built through one `blockMenu(for:)` that the ⋯ button, the right-click menu and `view.menu` now all
share -- three copies of the same loop, one of which is what the snapshot machinery had to retype.
The menu is also hung on the view, so VO-⇧-M finds it; it is rebuilt on ⌘↑/⌘↓ and nowhere else,
because a menu costs a header and a previous-run search.

`scroll_to_sticky_prompt` gives the sticky strip's click the keyboard path §2.7 promised it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Every menu row shows its chord

**Files:**
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift` — `BlockAction.terminalAction`
- Modify: `Sources/NyxApp/Pane.swift` — `blockMenu(for:)` sets the key equivalent
- Modify: `Sources/NyxApp/BlockHeaderView.swift` — `bindings`, and `morePressed`'s items (`:317`–`:325`)
- Modify: `Sources/NyxApp/MenuSnapshot.swift` — `menu(for:)` reads the same map, so the pictures show the chords the app shows
- Test: `Tests/NyxCoreTests/BlockHeaderTests.swift`

**Interfaces:**
- Consumes (Task 3): the four re-titled `TerminalAction`s — `Copy Command Output` and the chord beside it now describe the same block, which is why the map is worth showing at all. (Task 4): `Pane.blockMenu(for:)`.
- Consumes (plan 1a, spec §2.1–§2.6): nothing drawn. §2.3 gives the `Actions ▾` / `⋯` pill the label `Command actions`; the chords land inside the menu that pill opens.
- Consumes (already in the tree): `KeyBindingTable.binding(for:)`, `MenuShortcut.keyEquivalent(for:)`, `Pane.bindings` (`:2358`, set at `:327` and `:569`).
- Produces: `BlockAction.terminalAction: TerminalAction?`, read by all three menu builders and by the pictures.

- [ ] **Step 1: Write the failing tests** — appended to `Tests/NyxCoreTests/BlockHeaderTests.swift`:

```swift
// MARK: - The chord a menu row carries

@Test func theMenuRowsThatAreAlsoActionsNameThem() {
    #expect(BlockAction.copyOutput.terminalAction == .copyCommandOutput)
    #expect(BlockAction.copyMarkdown.terminalAction == .copyBlockMarkdown)
    #expect(BlockAction.saveOutput.terminalAction == .saveCommandOutput)
    #expect(BlockAction.editAndRun.terminalAction == .editAndRunCommand)
    #expect(BlockAction.toggleFold.terminalAction == .foldCommand)
    #expect(BlockAction.toggleFoldAll.terminalAction == .foldAllLongOutput)
    #expect(BlockAction.toggleLens.terminalAction == .toggleHTTPLens)
    #expect(BlockAction.stopWatch.terminalAction == .stopWatch)
    #expect(BlockAction.notifyWhenDone(armed: false).terminalAction == .notifyWhenDone)
}

/// A row whose act has no action shows no chord. The lens rows in particular: ⌘⇧J *toggles* pretty
/// against raw, so printing it beside `Pretty JSON` would be a promise that is wrong half the time.
@Test func theRowsWithNoActionOfTheirOwnCarryNoChord() {
    var rows: [BlockAction] = [.copyCommand, .runAgain, .openInWorkbench, .saveAsButton,
                               .saveToProject, .setLens(.raw), .setLens(.pretty),
                               .setLens(.filter("")), .copyBody, .copyHeaders, .lensUnavailable,
                               .runEvery(seconds: 5), .watch(WatchPlan(interval: 5, stop: .never))]
    rows += ExportFormat.allCases.map { BlockAction.copyAs($0) }
    for row in rows { #expect(row.terminalAction == nil, "\(row.title) should carry no chord") }
}

/// Whatever a row names must be a real menu-bar action, or the chord printed beside it comes from
/// a table nothing else can reach.
@Test func everyChordedRowIsAnActionTheMenuBarAlsoOffers() {
    let header = BlockHeader(id: 1, state: .finished, folded: false, hasOutput: true,
                             anyFolds: true, notifyArmed: false, summary: "8.8s",
                             httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                             isHTTP: true, bodyIsJSON: true, hasPreviousRun: true)
    for entry in header.actions {
        guard let action = entry.action.terminalAction else { continue }
        #expect(ActionCatalog.allMenuActions.contains(action), "\(action.configName) is not in the menu")
    }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter Chord 2>&1 | tail -10`
Expected: compile failure — `value of type 'BlockAction' has no member 'terminalAction'`.

- [ ] **Step 3: The map**, in `CommandBlock.swift` beside `BlockAction.startsGroup`:

```swift
    /// The `TerminalAction` this row *is*, when there is one, so the menu can print its chord.
    ///
    /// Every item in the block menu used to be built with an empty `keyEquivalent`, so the one
    /// place a user could learn that ⌘⇧↑ folds, ⌘E edits and ⌘. stops a watch was the menu bar --
    /// where the rows are named for a block the user cannot see (a11y 6.10). Decided here rather
    /// than in the three views that build this menu, which is three chances to disagree.
    ///
    /// The lens rows deliberately have none: ⌘⇧J toggles pretty against raw, so printing it beside
    /// `Pretty JSON` would promise the wrong act half the time.
    var terminalAction: TerminalAction? {
        switch self {
        case .copyOutput: return .copyCommandOutput
        case .copyMarkdown: return .copyBlockMarkdown
        case .saveOutput: return .saveCommandOutput
        case .editAndRun: return .editAndRunCommand
        case .toggleFold: return .foldCommand
        case .toggleFoldAll: return .foldAllLongOutput
        case .toggleLens: return .toggleHTTPLens
        case .stopWatch: return .stopWatch
        case .notifyWhenDone: return .notifyWhenDone
        case .copyCommand, .runAgain, .openInWorkbench, .copyAs, .saveAsButton, .saveToProject,
             .setLens, .copyBody, .copyHeaders, .runEvery, .watch, .lensUnavailable:
            return nil
        }
    }
```

  declared `public var terminalAction: TerminalAction?` in the `public enum BlockAction`.

- [ ] **Step 4: The three builders print it.** In `Pane.blockMenu(for:)`, after `item.state = …`:

```swift
            // The chord, where the row has one. `MenuShortcut` is the same converter the menu bar
            // and the right-click menu use, and `binding(for:)` answers honestly when the user has
            // rebound the chord to something else.
            if let action = entry.action.terminalAction, let binding = bindings.binding(for: action),
               let (key, mask) = MenuShortcut.keyEquivalent(for: binding) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mask
            }
```

  In `BlockHeaderView`, a stored table and the same four lines in `morePressed`:

```swift
    /// The bindings in force, for the chords the menu rows print. Set by the pane whenever the
    /// config changes, never read from a global -- a rebound key must show up on the next press.
    var bindings = KeyBindingTable(user: [])
```

  and in `Pane`, beside both `bindings = KeyBindingTable(user: …)` assignments (`:327`, `:569`):

```swift
        blockHeader.bindings = bindings
```

  In `MenuSnapshot.menu(for:)`, the **same four lines**, from the snapshot's own table:

```swift
    private static func menu(for header: BlockHeader, config: Config) -> NSMenu {
        let bindings = KeyBindingTable(user: config.keybinds)
        …
            if let action = entry.action.terminalAction, let binding = bindings.binding(for: action),
               let (key, mask) = MenuShortcut.keyEquivalent(for: binding) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mask
            }
```

  `MenuShortcut` (`Sources/NyxApp/Actions.swift:31`) and not a `case .char(let c)` of its own: `fold_command`'s default is `.up` with `[.cmd, .shift]` (`KeyBinding.swift:173`), which a character-only match drops — the snapshot would print no chord on `Fold Output` while the app prints ⌘⇧↑, which is exactly the disagreement between the picture and the product this task exists to end. The same applies to `MenuSnapshot.contextMenu(over:config:)`'s existing `actionItem`, which re-derives the mask the same way and switches to `MenuShortcut.keyEquivalent(for:)` in this step — same module, one converter, and the right-click picture stops lying about ⌘⇧↑ too.

  `blockMenus()`, `contextMenu(over:config:)` and their two call sites in `run(into:config:)` pass `config` through.

- [ ] **Step 5: Run the tests and take the pictures**

Run:
```bash
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5
swift build 2>&1 | grep -c "warning:"; ./scripts/bundle.sh
NYX_UI_SNAPSHOT=/tmp/nyx-1b-menus ./build/Nyx.app/Contents/MacOS/Nyx
```
Expected: PASS, `0` warnings. Then Read `menu-block-finished-{light,dark}.png`, `menu-block-http-dark.png`, `menu-block-watched-dark.png` and `menu-context-block-dark.png`. Exactly three rows carry a chord, because exactly three of the nine mapped actions have a default binding (`KeyBinding.defaults`, `KeyBinding.swift:140-182`): **`Fold Output ⌘⇧↑`**, **`Edit and Run This Command… ⌘E`** and **`Stop Watching ⌘.`** — right-aligned, and ⌘⇧↑ is the one that proves `MenuShortcut` was used. `Copy Output`, `Copy as Markdown`, `Save Output…`, `Fold Everything Long` and `Notify When Done` carry none, because their actions are unbound by default; no lens row carries one either, and the row pitch unchanged (`MenuSheetView` asserts its height against `menu.size` and prints to stderr if a chord changed the metrics). These are the pictures spec §8.5 calls `block-menu-{plain,http,watched}`; they ship under the existing `menu-block-*` names, which is what `MenuSnapshot` already writes, and they are reconstructions at AppKit's own metrics — the addendum's last paragraph says why a live capture is impossible here.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Shell/CommandBlock.swift Sources/NyxApp/Pane.swift \
        Sources/NyxApp/BlockHeaderView.swift Sources/NyxApp/MenuSnapshot.swift \
        Tests/NyxCoreTests/BlockHeaderTests.swift
git commit -m "$(cat <<'EOF'
The block menu teaches its own chords

Every item in the block menu was built with an empty key equivalent, so ⌘⇧A's twenty-six rows --
now the only keyboard route to the strip -- would have taught nobody that ⌘⇧↑ folds, ⌘E edits and
⌘. stops the watch (a11y 6.10). `BlockAction.terminalAction` maps the nine rows that are also
actions; the lens rows deliberately map to nothing, because ⌘⇧J toggles pretty against raw and
printing it beside `Pretty JSON` would be right half the time.

Decided in Core, so the ⋯ button, the right-click menu, ⌘⇧A and the snapshot all read one map,
and a test says every action it names is in the menu bar too.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: A command that mattered says so, and the ladder

**Files:**
- Create: `Sources/NyxCore/Shell/BlockAnnouncement.swift`, `Sources/NyxApp/Announce.swift`
- Modify: `Sources/NyxApp/Pane.swift` — the announcement site in `checkForFinishedCommand()` (`:3856`)
- Modify: `Sources/NyxApp/AppDelegate.swift`, `Sources/NyxApp/TerminalWindowController.swift` — the temporary `NYX_SMOKE_QA=blockcursor` hook and the temporary accessor it needs, **both removed before the commit**
- Test: `Tests/NyxCoreTests/BlockAnnouncementTests.swift`

**Interfaces:**
- Consumes (Task 2): `Pane.blockCursor`. (Task 3): `Pane.performOnBlockCursor(_:)`, `Pane.canStopWatch`. (Task 4): `Pane.blockMenuHeader(for:needsPreviousRun:)`, `Pane.showBlockActions()`, `Pane.blockMenu(for:)`.
- Consumes (plan 1a, spec §2.1–§2.6): `BlockHeader.summary` is the sentence — the same words 1a's `StripPlan.readout` shows and 1a's sticky strip shows, so the announcement, the strip and the pinned line cannot say three different things about one command.
- Produces: `Announce.say(_:)` in `NyxApp`, which plans 5a and 5b use for the palette's selection, the search readout and the four banners (§8.1's site list); `BlockAnnouncement.text(for:summary:paneIsFocused:)`.

- [ ] **Step 1: Write the failing test** — `Tests/NyxCoreTests/BlockAnnouncementTests.swift`:

```swift
import Testing
@testable import NyxCore

private func region(status: Int32?, seconds: Double?) -> CommandRegion {
    CommandRegion(promptRow: 0, outputStart: 1, endRow: 5, exitStatus: status,
                  duration: seconds, id: 1)
}

/// Announcing every command talks over the user; announcing none is a11y 0.2. The rule is the
/// commands that were worth waiting for and the ones that went wrong.
@Test func aQuickSuccessIsNotAnnounced() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 0.4), summary: "0.4s",
                                   paneIsFocused: true) == nil)
}

@Test func aCommandThatRanTwoSecondsIsAnnouncedWithTheSummaryTheStripShows() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 2), summary: "2.0s",
                                   paneIsFocused: true) == "2.0s")
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 1.99), summary: "2.0s",
                                   paneIsFocused: true) == nil)
}

@Test func aFailureIsAnnouncedHoweverShort() {
    #expect(BlockAnnouncement.text(for: region(status: 1, seconds: 0.1),
                                   summary: "exit 1 \u{b7} 0.1s", paneIsFocused: true)
            == "exit 1 \u{b7} 0.1s")
}

/// The focused pane only: four panes in a window, three of them building, is four voices.
@Test func nothingIsAnnouncedInAnUnfocusedPane() {
    #expect(BlockAnnouncement.text(for: region(status: 1, seconds: 9), summary: "exit 1 \u{b7} 9s",
                                   paneIsFocused: false) == nil)
}

@Test func nothingIsAnnouncedWhileTheCommandIsStillRunning() {
    #expect(BlockAnnouncement.text(for: region(status: nil, seconds: nil), summary: "12s",
                                   paneIsFocused: true) == nil)
}

@Test func nothingIsAnnouncedWithoutASummaryToSay() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 9), summary: "",
                                   paneIsFocused: true) == nil)
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter Announce 2>&1 | tail -10`
Expected: compile failure — `cannot find 'BlockAnnouncement' in scope`.

- [ ] **Step 3: Write the rule and the helper.** `Sources/NyxCore/Shell/BlockAnnouncement.swift`:

```swift
import Foundation

/// Whether a finished command is worth saying out loud, and in what words.
///
/// Nothing in Nyx ever posted an accessibility notification: a command finishing was silent, which
/// for a VoiceOver user is a terminal that never tells them anything happened (a11y 0.2).
/// Announcing *every* command is the opposite mistake -- it talks over the person typing the next
/// one -- so the rule is the commands you waited for and the ones that went wrong.
///
/// The words are `BlockHeader.summary`: what the strip shows, what the pinned line shows, and now
/// what is spoken, so the three cannot describe one command three ways.
public enum BlockAnnouncement {
    /// Below this a command finished while you were still reading the line you typed.
    public static let minimumDuration: Double = 2

    public static func text(for region: CommandRegion, summary: String,
                            paneIsFocused: Bool) -> String? {
        guard paneIsFocused, !summary.isEmpty else { return nil }
        // Still running: it has neither a status nor a duration, and "12s" is a clock, not news.
        guard region.exitStatus != nil || region.duration != nil else { return nil }
        guard region.failed || (region.duration ?? 0) >= minimumDuration else { return nil }
        return summary
    }
}
```

  `Sources/NyxApp/Announce.swift`:

```swift
import AppKit

/// One place that speaks to VoiceOver.
///
/// `.announcementRequested` on the application, because the thing being announced is not a change
/// to any one element's value -- a command finishing belongs to the pane, a banner to the window.
/// The wording never lives here: it comes from Core (`BlockHeader.summary`, `ConfigDiagnostic`,
/// `SearchSession`'s readout, `WatchPlanEditorModel.problem`), so what is spoken and what is on the
/// screen cannot drift apart.
enum Announce {
    static func say(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
```

- [ ] **Step 4: Say it where the command finishes.** In `Pane.checkForFinishedCommand()`, after `armedNotifications.remove(finished.id)` and *before* the `CommandNotificationRule` guard (the two are independent: a notification is for a window you are not looking at, an announcement is for the pane you are in):

```swift
        // The focused pane only, and only a command that ran two seconds or failed. The sentence is
        // the block's own summary, so the announcement and the strip say the same words.
        if let region = session.withTerminal({ $0.command(containingAbsoluteRow: finished.promptRow) }),
           let header = blockMenuHeader(for: region.id, needsPreviousRun: false),
           let spoken = BlockAnnouncement.text(for: region, summary: header.summary,
                                               paneIsFocused: window?.isKeyWindow == true
                                                   && window?.firstResponder === self) {
            Announce.say(spoken)
        }
```

- [ ] **Step 5: Run the tests and the build**

Run: `swift build 2>&1 | grep -c "warning:"; pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -5`
Expected: `0` warnings, PASS.

- [ ] **Step 6: Rung 6 — drive the real keys in the built app.** Temporarily add to `TerminalWindowController` `var qaTabs: TabController? { tabs }`, and to `AppDelegate.applicationDidFinishLaunching`, immediately after `openInitialWindows()`:

```swift
        if ProcessInfo.processInfo.environment["NYX_SMOKE_QA"] == "blockcursor" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let tabs = self?.controllers.first?.qaTabs,
                      let pane = tabs.focusedPane else { print("SMOKE blockcursor no-pane"); exit(1) }

                func key(_ chars: String, _ mods: NSEvent.ModifierFlags, _ code: UInt16) -> NSEvent {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
                }
                let up = key("\u{f700}", [.command], 126)
                let down = key("\u{f701}", [.command], 125)
                let chordA = key("a", [.command, .shift], 0)

                // Four blocks, one of them long enough to scroll inside, and a request that cannot
                // connect -- so every state exists without a server: an ordinary command, a
                // screenful of output, a failure, and a finished HTTP block.
                for line in ["echo one\r", "seq 200\r", "make-nothing\r",
                             "curl -sS http://127.0.0.1:1/ ; true\r"] {
                    pane.send(Array(line.utf8))
                    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                }
                func command(of id: UInt32?) -> String {
                    guard let id else { return "<none>" }
                    return pane.commandLine(ofCommand: id)
                }

                // Scrolled back into `seq 200`'s output, which is where `previous_prompt` has
                // always gone up from. The first ⌘↑ must seed from *this* screen -- the `seq 200`
                // block -- and not take the newest block and throw the viewport to the bottom.
                pane.scrollForQA(toAbsoluteRow: 20)
                pane.keyDown(with: up)
                print("SMOKE blockcursor seed id=\(pane.blockCursor.commandID.map(String.init) ?? "nil") "
                      + "cmd=\(command(of: pane.blockCursor.commandID))")
                pane.keyDown(with: up)
                print("SMOKE blockcursor up2 id=\(pane.blockCursor.commandID.map(String.init) ?? "nil") "
                      + "cmd=\(command(of: pane.blockCursor.commandID))")

                // `copy_command_output` must hit *that* block, not the last one.
                NSPasteboard.general.clearContents()
                tabs.perform(.copyCommandOutput)
                print("SMOKE blockcursor copy=\(NSPasteboard.general.string(forType: .string) ?? "<empty>")")

                // ⌘. is scoped to the cursor: refused two blocks up, accepted on the run itself.
                if let requestID = pane.blockCursorIDsForQA.last {
                    pane.perform(.runEvery(seconds: 3600), on: requestID)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    print("SMOKE blockcursor stop-away canStop=\(pane.canStopWatch)")
                    // Back down to the run: echo one → seq 200 → make-nothing → curl.
                    for _ in 0..<3 { pane.keyDown(with: down) }
                    print("SMOKE blockcursor stop-on-run cursor=\(pane.blockCursor.commandID ?? 0) "
                          + "canStop=\(pane.canStopWatch)")
                    tabs.perform(.stopWatch)
                }

                // The menu ⌘⇧A pops, and its chords. Popping it runs a modal tracking loop, so an
                // Escape is queued first and a watchdog kills the process if the menu eats it.
                let rows = pane.blockMenu(for: pane.blockCursor.commandID ?? 0)?.items.map {
                    "\($0.title)\($0.keyEquivalent.isEmpty ? "" : " [\($0.keyEquivalent)]")"
                } ?? []
                print("SMOKE blockcursor menu rows=\(rows.count) \(rows.joined(separator: " | "))")
                print("SMOKE blockcursor view.menu rows=\(pane.menu?.items.count ?? -1)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSApp.postEvent(key("\u{1b}", [], 53), atStart: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    print("SMOKE blockcursor menu-stuck"); exit(2)
                }
                pane.keyDown(with: chordA)
                print("SMOKE blockcursor chord-returned")
                exit(0)
            }
        }
```

  with the three temporary accessors the probe needs on `Pane`, also removed afterwards:

```swift
    var blockCursorIDsForQA: [UInt32] { session.withTerminal { $0.blockCursorIDs } }
    func commandLine(ofCommand id: UInt32) -> String
    func scrollForQA(toAbsoluteRow row: Int) {
        session.withTerminal { _ = $0.scrollToAbsoluteRow(row) }
        markDirty()
    }
```

Run: `./scripts/bundle.sh && NYX_SMOKE_QA=blockcursor ./build/Nyx.app/Contents/MacOS/Nyx 2>&1 | grep SMOKE`

Expected, and each line is checked rather than glanced at:
- `seed cmd=seq 200` — the first ⌘↑ in a pane scrolled back went up from the screen the reader is on, **not** to the curl at the bottom. That is the whole of the seeding rule, and the regression it guards against is invisible to a unit test because both answers are "a block".
- `up2 cmd=echo one` — the second press steps, one block, and the two ids differ.
- `copy=one` — `copy_command_output` hit the block the cursor is on, **not** the curl's output at the bottom. That is the five-rules bug; no unit test can see it, because each of the five rules was correct on its own.
- `stop-away canStop=false` and `stop-on-run … canStop=true`: ⌘. is scoped to the block the keyboard is on.
- `menu rows=` is 20-odd for the request block, and exactly three rows print a chord — `Edit and Run This Command… [⌘E]`, `Fold Output [⌘⇧↑]`, `Stop Watching [⌘.]`. No lens row and no `Copy Output`/`Save Output…` carries one: their actions have no default binding (Task 5, Step 5). `view.menu rows=` matches `menu rows=`.
- `chord-returned` prints, not `menu-stuck`: ⌘⇧A really popped a menu and the Escape dismissed it.
- **By eye, once:** comment out the `exit(0)`, run it again, and with the sticky strip up (the pane is still scrolled back into `seq 200`) press ⌘⇧A by hand. The menu's top edge must sit on the cursor block's own row. The sticky strip covers the first row of the pane, so an off-by-one in `blockMenuAnchor`/`displaySlot` shows up here and nowhere else.

- [ ] **Step 7: Remove the hook and prove it is gone**

Run: `grep -rn "NYX_SMOKE_QA\|qaTabs\|blockCursorIDsForQA\|scrollForQA\|commandLine(ofCommand" Sources Tests; git status --short`
Expected: nothing from the grep, and `git status` showing only the files this plan means to change.

- [ ] **Step 8: The rest of the ladder**

Run:
```bash
swift build 2>&1 | grep -c "warning:"
pkill -9 -f swiftpm-testing-helper; swift test --no-parallel 2>&1 | tail -3
make bench
./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/nyx-1b-final ./build/Nyx.app/Contents/MacOS/Nyx
cmp /tmp/nyx-1b-final/composite-block-cursor-w3-nyx-dark-dark.png \
    /tmp/nyx-1b-final/composite-strip-w3-finished-nyx-dark-dark.png
```
Expected: `0` warnings; the test count printed and every test passing; `make bench` ≥ 180 MB/s (nothing here touches the render path — a drop is a bug, per §10); the two `composite-block-cursor-*` pictures byte-identical to their hovered twins. Then **look at the pictures**: `composite-block-cursor-{w3,w1}-{nyx-dark,nyx-light}-{light,dark}` (the cursor's block lit with no pointer) and `menu-block-{finished,http,watched}-{light,dark}` plus `menu-context-block-dark` (the chords). Report the test count and the bench figure in the task report, as `docs/testing.md` requires.

- [ ] **Step 9: Commit**

```bash
git add Sources/NyxCore/Shell/BlockAnnouncement.swift Sources/NyxApp/Announce.swift \
        Sources/NyxApp/Pane.swift Tests/NyxCoreTests/BlockAnnouncementTests.swift
git commit -m "$(cat <<'EOF'
A command that mattered says so

Nothing in Nyx had ever posted an accessibility notification, so for a VoiceOver user a command
finishing was silence (a11y 0.2). Announcing every command is the opposite mistake, so
`BlockAnnouncement` is the rule: the focused pane only, and only a command that ran two seconds or
exited non-zero. The sentence is `BlockHeader.summary` -- the words the strip shows and the pinned
line shows -- so the three cannot describe one command three ways.

`Announce.say` is the one place that speaks; the wording stays in Core, and the palette, the search
readout and the banners join it in their own plans.

Rung 6 drove ⌘↑ twice, `copy_command_output`, ⌘. and ⌘⇧A in the built app: the copy took the block
two presses up rather than the last one, ⌘. refused two blocks away from its run and stopped it on
the run, and ⌘⇧A popped the block's own menu with its chords in it. The hook is removed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review against the spec

**Spec coverage.** §2.8's `BlockCursor` (Task 1), its visibility as a hovered block and the pointer-versus-cursor rule (Tasks 1–2), the eight re-targeted actions and the four "Last" titles (Task 3), `block_actions` ⌘⇧A through the same `morePressed` path plus `view.menu` (Task 4), the `BlockAction → TerminalAction?` chords (Task 5), `scroll_to_sticky_prompt` (Task 4), §8.1's finish announcement and `Announce` (Task 6), §8.2's first two rows through the whole action checklist (Tasks 3–4, docs in both), §8.5's plan-1b pictures — `composite-block-cursor-{w3,w1}` (Task 2) and the block menus with chords (Task 5) — and §10's plan-1b paragraph in full: `BlockCursor.moved` both directions, from cleared, at both ends, with a trimmed id; `afterViewportMove` in its three states; `BlockAction → TerminalAction?` for every row of the menu; `BlockAnnouncement.text` at the 2 s and non-zero-exit boundaries; and the `NYX_SMOKE_QA=blockcursor` hook printing which block each of ⌘↑↑, ⌘⇧A, `copy_command_output` and ⌘. hit.

**Deliberately not here.** §8.1's other announcement sites (palette selection, search readout, banners, watch refusal, `.layoutChanged` from the tab bar and the gutter) belong to plans 5a/5b and 2; this plan only builds the helper they call. §8.3 (the pane's accessibility role) is a `[verify]` item needing a VoiceOver pass and is not assigned to a plan. Everything §2.1–§2.7 draws is plan 1a's and is consumed unchanged.

**Naming reconciled with the spec.** The spec writes `CommandID`; this codebase's block id is `UInt32` and there is no such typealias, so the signatures use `UInt32`. The spec calls the menu pictures `block-menu-{plain,http,watched}`; `MenuSnapshot` already writes that set as `menu-block-{finished,http,lensed,watched,too-large}`, so Task 5 retakes those rather than renaming a working case.

**Chords the menu really shows.** Only three of the nine rows `BlockAction.terminalAction` maps carry one, because only `fold_command` (⌘⇧↑), `edit_and_run_command` (⌘E) and `stop_watch` (⌘.) have a default binding; `copy_command_output`, `copy_block_markdown`, `save_command_output`, `fold_all_long_output` and `notify_when_done` are unbound out of the box and print nothing until a user binds them. ⌘⇧J appears on no row at all: `.toggleLens` is the lens chip's act and is not a member of `BlockHeader.actions` — the menu's lens rows are `.setLens(…)`, which map to no action on purpose. Tasks 5 and 6 state the same three chords, and ⌘⇧↑ is the one that catches a builder that matched only `case .char`.

**Decisions this plan had to make, and why.** (0) A cleared or off-screen cursor is seeded from the viewport before a press, and the press **lands on the seed** rather than stepping past it: the literal seed-then-step would take ⌘↑ to the block *above* the one whose output fills the screen, skipping the block the reader is inside — where `previous_prompt` goes to that block's own prompt today. `BlockCursor.moved` already re-anchors a trimmed id the same way, so this is the type's own rule and not a second one. The controller's ruling (seed from the viewport, then move) is followed in its stated intent — ⌘↑ goes up from where the reader is — and one line in Task 2 Step 1 (`?? BlockCursor.moved(…)` becoming an unconditional `moved` on the seeded cursor) reverses this if the literal reading is preferred. (1) ⌘↑/⌘↓ are the cursor's mover and the viewport follows the block they land on — the alternative, leaving `previous_prompt` to walk prompt rows and letting the cursor trail behind it, keeps the two answers the spec exists to unify apart. (2) A cursor whose block was trimmed *lands* on the nearest survivor rather than stepping past it, because stepping from a hole skips whichever block took its place. (3) A cleared cursor stays cleared through a viewport move, so a pane nobody has pressed ⌘↑ in never grows a lit block. (4) `stop_watch` and `toggle_http_lens` keep a request-shaped fallback for a pane with no cursor, which is today's behaviour word for word; the pointer clause in `lensTargetBlock` is what goes.
