# Nyx Phase 2A (Daily Driver) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nyx a terminal you can switch to permanently: select and copy text, use the mouse inside TUI programs, work in tabs and splits, and configure font, theme and behaviour from a text file that reloads as you save it.

**Architecture:** Selection lives in `NyxCore` over absolute (scrollback-relative) coordinates so it survives scrolling and is unit-testable without AppKit. The renderer learns one new concept, a set of selected cell ranges per visible row. The app layer is restructured once: today's monolithic `TerminalView` becomes a `Pane` (one terminal) hosted by a `PaneTreeView` (splits) hosted by a `TabController` (tabs), with a `Config` object injected from the top. Everything the user can change lives in one immutable `Config` value that is rebuilt on file change and pushed down the tree.

**Tech Stack:** Swift 5 language mode on the Swift 6.0.3 toolchain, SwiftPM only (no Xcode), swift-testing (`import Testing`), AppKit, Metal, Core Text, `DispatchSource` for file watching.

**Spec:** `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md` — this plan implements §6.1 (mouse, selection, copy/paste), §6.2 (windows, tabs, splits), §6.5 (config and themes), plus the three latent items recorded at the end of §11. Search (§6.3), links and paths (§6.4), shell integration (§6.6) and sessions (§6.7) are phase 2B and are deliberately out of scope here.

## Global Constraints

- Work in `~/projects/nyx` on a branch off `main`. Never touch `~/projects/main`, which is an unrelated repository.
- `// swift-tools-version:5.10`, deployment target macOS 14, no external packages, no Xcode. Metal shaders are compiled at runtime from the string in `Sources/NyxRender/Shaders.swift`.
- Tests use swift-testing: `import Testing`, `@Test`, `#expect`, `#require`. XCTest is not available. Run with `swift test`, filter with `swift test --filter <substring>`.
- `NyxCore` must not import AppKit, Metal, CoreText or QuartzCore. `NyxRender` must not import CNyxPTY or touch PTYs.
- The existing 167 tests must keep passing unchanged unless a task explicitly says otherwise. `NYX_SNAPSHOT=1 swift test --filter Snapshot` must keep passing. Debug and release builds must stay warning-free.
- Throughput must not regress: `make bench` stays at or above 180 MB/s. Re-measure in any task that touches `Sources/NyxCore/Parser` or `Sources/NyxCore/Terminal`.
- Stage files by name. Never `git add -A`. Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_014u6CmMe92XrF1UPpE5QWD8
  ```

## A deliberate deviation from the usual plan format

For `NyxCore` and `NyxRender` this plan gives complete implementation code, as phase 1 did. For the AppKit layer it gives complete **test code, interfaces, behaviour and acceptance criteria**, but describes rather than dictates the view code. Phase 1 demonstrated why: prescribing AppKit source from memory produced two compile errors (a `frame:` label colliding with `NSView`'s designated initialiser, an `override` missing on `doCommand(by:)`) that the implementer had to fix anyway. The implementer has the real SDK; the plan's job there is to pin behaviour exactly, not to guess method signatures. Where a specific API choice matters for correctness, the plan names it.

## File Structure

```
Sources/NyxCore/Selection/Selection.swift        selection model: anchors, modes, normalisation
Sources/NyxCore/Selection/Terminal+Selection.swift  text extraction and hit-testing over the grid
Sources/NyxCore/Mouse/MouseEncoder.swift         mouse events -> bytes for modes 1000/1002/1003
Sources/NyxCore/Config/Config.swift              the parsed configuration value
Sources/NyxCore/Config/ConfigParser.swift        key = value parsing with per-line diagnostics
Sources/NyxCore/Config/KeyBinding.swift          "cmd+shift+d=split_horizontal" parsing, action enum
Sources/NyxCore/Config/Themes.swift              built-in palettes, theme lookup, dark/light pairs
Sources/NyxRender/Renderer.swift                 (modified) selection painting
Sources/NyxApp/Pane.swift                        one terminal: was TerminalView, now a leaf
Sources/NyxApp/PaneTree.swift                    split tree model (value type) + navigation
Sources/NyxApp/PaneTreeView.swift                lays out panes, draws and drags dividers
Sources/NyxApp/TabBarView.swift                  compact custom tab strip
Sources/NyxApp/TabController.swift               tabs: model, titles, activity indicators
Sources/NyxApp/ConfigStore.swift                 loads, watches and republishes Config
Sources/NyxApp/ConfigBanner.swift                non-blocking error banner
Sources/NyxApp/Actions.swift                     the action enum the menu and keybindings both drive
Sources/NyxApp/TerminalWindowController.swift    (modified) hosts TabController
Sources/NyxApp/MainMenu.swift                    (modified) built from Actions
Tests/NyxCoreTests/SelectionTests.swift
Tests/NyxCoreTests/MouseEncoderTests.swift
Tests/NyxCoreTests/ConfigTests.swift
Tests/NyxCoreTests/KeyBindingTests.swift
Tests/NyxCoreTests/ThemesTests.swift
Tests/NyxAppTests/PaneTreeTests.swift            new test target: pure-model app logic
Tests/NyxRenderTests/SelectionRenderTests.swift
```

`Tests/NyxAppTests` requires a new test target in `Package.swift`. The `Nyx` executable target cannot be imported by a test target, so `PaneTree` must live in a library. Task 8 moves the split-tree model into `NyxCore` (it is pure value-type logic with no AppKit dependency) rather than creating a fourth module.

---

### Task 1: Close the three latent items from the phase-1 review

**Files:**
- Modify: `Sources/NyxApp/TerminalView.swift` (the `viewDidMoveToWindow` teardown block, and `render()`)
- Modify: `Sources/NyxCore/Terminal/Terminal.swift` (the `keypadApp` mode declaration)
- Test: none — these are one-line changes in AppKit code with no reachable behaviour in phase 1; the acceptance criterion is that the existing suite stays green.

**Interfaces:**
- Produces: nothing new. This task removes traps before phase 2 code builds on them.

Spec §11 records these three at the end of the phase-2 list. They are unreachable today and become live the moment a view is reparented, which is exactly what Task 9 does.

- [ ] **Step 1: Reset the occlusion flag when the view changes window**

In `viewDidMoveToWindow`, `isOccluded` is left at whatever the old window's state was. Once tabs and splits reparent views, a pane that was occluded keeps `isOccluded == true` in its new window and `resumeLink()` refuses to ever unpause it, so the pane stops redrawing until AppKit happens to post an occlusion notification. Set it from the new window's actual state as part of the teardown/setup, before the display link is created. `NSWindow.occlusionState` contains `.visible` when the window is on screen; treat "not visible" as occluded, and treat a nil window as occluded (there is nothing to draw into).

- [ ] **Step 2: Say that `keypadApp` is tracked but not implemented**

`Terminal.modes.keypadApp` is written by DECKPAM/DECKPNM and read by nobody, and `KeyEncoder` no longer takes it. Application-keypad encoding is real xterm behaviour Nyx does not implement: the numeric keypad sends plain digits where an application expects SS3 sequences. Add a comment on the property saying exactly that and pointing at the phase-2 deferral bullet in the spec. Do not delete the mode — it is set correctly and DECRQM-adjacent code may want it.

- [ ] **Step 3: Note the stale-frame trap in `render()`**

`render()` calls `t.clearDirty()` inside `withTerminal` before it learns whether `renderer.draw` got a drawable; on failure it re-sets the view's dirty flag, which works only because the renderer currently rebuilds every row. Add a comment at that call site saying the retry will repaint rows already marked clean once per-row partial redraw lands, so whoever implements it fixes both together.

- [ ] **Step 4: Verify and commit**

Run: `cd ~/projects/nyx && swift test 2>&1 | tail -2 && swift build 2>&1 | grep -ci warning`
Expected: `167 tests passed`, and `0` warnings.

```bash
git add Sources/NyxApp/TerminalView.swift Sources/NyxCore/Terminal/Terminal.swift
git commit -m "fix(app): reset occlusion on window change, document two known traps"
```

---

### Task 2: Selection model in NyxCore

**Files:**
- Create: `Sources/NyxCore/Selection/Selection.swift`
- Test: `Tests/NyxCoreTests/SelectionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// A position in the terminal's absolute coordinate space: row 0 is the oldest scrollback line,
  /// row `scrollback.count` is the top of the live screen. Columns are cell indices.
  public struct AbsolutePosition: Equatable, Comparable {
      public var row: Int
      public var col: Int
      public init(row: Int, col: Int)
      public static func < (a: AbsolutePosition, b: AbsolutePosition) -> Bool
  }

  public enum SelectionMode: Equatable { case character, word, line, block }

  /// A selection in progress or completed. `anchor` is where the drag started, `head` where it is
  /// now; either may be the earlier of the two.
  public struct Selection: Equatable {
      public var anchor: AbsolutePosition
      public var head: AbsolutePosition
      public var mode: SelectionMode
      public init(anchor: AbsolutePosition, head: AbsolutePosition, mode: SelectionMode)

      /// The earlier and later endpoints, in reading order.
      public var start: AbsolutePosition { min(anchor, head) }
      public var end: AbsolutePosition { max(anchor, head) }
      public var isEmpty: Bool

      /// Half-open column range selected on absolute row `row`, or nil when the row is outside.
      /// For `.block` this is the same column span on every row; otherwise it runs to `cols` on
      /// every row but the last.
      public func columnRange(onRow row: Int, cols: Int) -> Range<Int>?
  }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/SelectionTests.swift`:
```swift
import Testing
@testable import NyxCore

private func pos(_ r: Int, _ c: Int) -> AbsolutePosition { AbsolutePosition(row: r, col: c) }

@Test func positionsOrderByRowThenColumn() {
    #expect(pos(1, 5) < pos(2, 0))
    #expect(pos(1, 4) < pos(1, 5))
    #expect(!(pos(2, 0) < pos(1, 9)))
}

@Test func selectionNormalisesBackwardDrags() {
    let forward = Selection(anchor: pos(1, 2), head: pos(3, 4), mode: .character)
    let backward = Selection(anchor: pos(3, 4), head: pos(1, 2), mode: .character)
    #expect(forward.start == pos(1, 2) && forward.end == pos(3, 4))
    #expect(backward.start == pos(1, 2) && backward.end == pos(3, 4))
}

@Test func emptySelectionSelectsNothing() {
    let s = Selection(anchor: pos(2, 3), head: pos(2, 3), mode: .character)
    #expect(s.isEmpty)
    #expect(s.columnRange(onRow: 2, cols: 10) == nil)
}

@Test func characterSelectionSpansWholeMiddleRows() {
    let s = Selection(anchor: pos(1, 7), head: pos(3, 2), mode: .character)
    #expect(s.columnRange(onRow: 0, cols: 10) == nil)
    #expect(s.columnRange(onRow: 1, cols: 10) == 7..<10)
    #expect(s.columnRange(onRow: 2, cols: 10) == 0..<10)
    #expect(s.columnRange(onRow: 3, cols: 10) == 0..<2)
    #expect(s.columnRange(onRow: 4, cols: 10) == nil)
}

@Test func singleRowCharacterSelection() {
    let s = Selection(anchor: pos(2, 3), head: pos(2, 8), mode: .character)
    #expect(s.columnRange(onRow: 2, cols: 10) == 3..<8)
}

@Test func blockSelectionUsesTheSameColumnsOnEveryRow() {
    let s = Selection(anchor: pos(1, 6), head: pos(3, 2), mode: .block)
    for row in 1...3 { #expect(s.columnRange(onRow: row, cols: 10) == 2..<6) }
    #expect(s.columnRange(onRow: 0, cols: 10) == nil)
    #expect(s.columnRange(onRow: 4, cols: 10) == nil)
}

@Test func blockSelectionOnASingleColumnIsEmpty() {
    let s = Selection(anchor: pos(1, 4), head: pos(3, 4), mode: .block)
    for row in 1...3 { #expect(s.columnRange(onRow: row, cols: 10) == nil) }
}

@Test func lineSelectionTakesWholeRows() {
    let s = Selection(anchor: pos(1, 5), head: pos(2, 1), mode: .line)
    #expect(s.columnRange(onRow: 1, cols: 10) == 0..<10)
    #expect(s.columnRange(onRow: 2, cols: 10) == 0..<10)
    #expect(s.columnRange(onRow: 3, cols: 10) == nil)
}

@Test func columnRangeClampsToTheGridWidth() {
    let s = Selection(anchor: pos(1, 3), head: pos(1, 99), mode: .character)
    #expect(s.columnRange(onRow: 1, cols: 10) == 3..<10)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/projects/nyx && swift test --filter Selection 2>&1 | tail -5`
Expected: compile error, `cannot find 'AbsolutePosition' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/NyxCore/Selection/Selection.swift`:
```swift
/// A position in the terminal's absolute coordinate space: row 0 is the oldest scrollback line and
/// row `scrollback.count` is the top of the live screen. Using absolute rows rather than viewport
/// rows means a selection survives scrolling and new output without any fix-up.
public struct AbsolutePosition: Equatable, Comparable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public static func < (a: AbsolutePosition, b: AbsolutePosition) -> Bool {
        a.row != b.row ? a.row < b.row : a.col < b.col
    }
}

public enum SelectionMode: Equatable { case character, word, line, block }

/// A selection in progress or completed. `anchor` is where the drag started and `head` where it is
/// now; a backwards drag simply has `head < anchor`, and every query goes through `start`/`end`.
public struct Selection: Equatable {
    public var anchor: AbsolutePosition
    public var head: AbsolutePosition
    public var mode: SelectionMode

    public init(anchor: AbsolutePosition, head: AbsolutePosition, mode: SelectionMode) {
        self.anchor = anchor
        self.head = head
        self.mode = mode
    }

    public var start: AbsolutePosition { min(anchor, head) }
    public var end: AbsolutePosition { max(anchor, head) }

    public var isEmpty: Bool {
        switch mode {
        case .block: return start.row > end.row || min(anchor.col, head.col) >= max(anchor.col, head.col)
        case .line: return false
        case .character, .word: return start == end
        }
    }

    /// Half-open column range selected on absolute row `row`, or nil when the row is outside the
    /// selection. Character and word selections run to the end of every row but the last; block
    /// selections use the same column span on every row; line selections take whole rows.
    public func columnRange(onRow row: Int, cols: Int) -> Range<Int>? {
        guard !isEmpty, row >= start.row, row <= end.row, cols > 0 else { return nil }
        switch mode {
        case .block:
            let lo = min(min(anchor.col, head.col), cols)
            let hi = min(max(anchor.col, head.col), cols)
            return lo < hi ? lo..<hi : nil
        case .line:
            return 0..<cols
        case .character, .word:
            let lo = row == start.row ? min(start.col, cols) : 0
            let hi = row == end.row ? min(end.col, cols) : cols
            return lo < hi ? lo..<hi : nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter Selection 2>&1 | tail -3`
Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Selection/Selection.swift Tests/NyxCoreTests/SelectionTests.swift
git commit -m "feat(core): selection model over absolute coordinates"
```

---

### Task 3: Text extraction and hit-testing over the grid

**Files:**
- Create: `Sources/NyxCore/Selection/Terminal+Selection.swift`
- Test: extend `Tests/NyxCoreTests/SelectionTests.swift`

**Interfaces:**
- Consumes: `Selection`, `AbsolutePosition`, `SelectionMode` from Task 2. `Terminal.viewportRow(_:)`, `Terminal.scrollback`, `Terminal.screen.rows`, `Terminal.cols`, `Terminal.rows`, `Terminal.clusterText(of:)`, `Cell.attrs.wideSpacer`, `Row.wrapped`.
- Produces on `Terminal`:
  ```swift
  /// Total number of absolute rows: scrollback plus the live screen.
  public var totalRows: Int { get }
  /// Row at an absolute index, or nil when out of range.
  public func absoluteRow(_ row: Int) -> Row?
  /// Absolute row index of the top visible row, given the current `viewportOffset`.
  public var viewportTopRow: Int { get }
  /// The text a selection covers. Soft-wrapped rows join without a newline; hard rows join with one.
  /// Trailing blanks on each row are trimmed except in block mode, where columns are taken literally.
  public func text(in selection: Selection) -> String
  /// Expands a position to the word around it, using `separators` to decide word boundaries.
  /// Returns the half-open column range and the row it applies to.
  public func wordRange(at position: AbsolutePosition, separators: Set<Character>) -> Range<Int>?
  ```

The word and line selection modes are built by the caller: it asks for `wordRange` and constructs a `.word` selection whose endpoints are that range, so `columnRange` from Task 2 does the rest.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NyxCoreTests/SelectionTests.swift`:
```swift
private let defaultSeparators: Set<Character> = Set(" ()[]{}'\"`,;:|<>")

@Test func absoluteRowsCoverScrollbackThenScreen() {
    let t = makeTerminal(cols: 10, rows: 2, scrollback: 10).run("a\r\nb\r\nc\r\nd")
    #expect(t.scrollback.count == 2)
    #expect(t.totalRows == 4)
    #expect(t.absoluteRow(0)?.cells[0].scalar == "a")
    #expect(t.absoluteRow(3)?.cells[0].scalar == "d")
    #expect(t.absoluteRow(4) == nil)
    #expect(t.viewportTopRow == 2)
    t.scrollViewport(by: 1)
    #expect(t.viewportTopRow == 1)
}

@Test func extractsASingleRowOfText() {
    let t = makeTerminal(cols: 20, rows: 3).run("hello world")
    let s = Selection(anchor: pos(0, 0), head: pos(0, 5), mode: .character)
    #expect(t.text(in: s) == "hello")
}

@Test func extractionTrimsTrailingBlanksOnEachRow() {
    let t = makeTerminal(cols: 20, rows: 3).run("ab\r\ncd")
    let s = Selection(anchor: pos(0, 0), head: pos(1, 20), mode: .character)
    #expect(t.text(in: s) == "ab\ncd")
}

@Test func softWrappedRowsJoinWithoutANewline() {
    let t = makeTerminal(cols: 5, rows: 3).run("abcdefgh")
    #expect(t.screen.rows[0].wrapped)
    let s = Selection(anchor: pos(0, 0), head: pos(1, 5), mode: .character)
    #expect(t.text(in: s) == "abcdefgh")
}

@Test func extractionSkipsWideSpacerCells() {
    let t = makeTerminal(cols: 10, rows: 2).run("a漢b")
    let s = Selection(anchor: pos(0, 0), head: pos(0, 10), mode: .character)
    #expect(t.text(in: s) == "a漢b")
}

@Test func extractionKeepsGraphemeClusters() {
    let t = makeTerminal(cols: 10, rows: 2).run("e\u{0301}x")
    let s = Selection(anchor: pos(0, 0), head: pos(0, 10), mode: .character)
    #expect(t.text(in: s) == "e\u{0301}x")
}

@Test func blockSelectionTakesColumnsLiterally() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdef\r\nghijkl\r\nmnopqr")
    let s = Selection(anchor: pos(0, 1), head: pos(2, 4), mode: .block)
    #expect(t.text(in: s) == "bcd\nhij\nnop")
}

@Test func blockSelectionDoesNotJoinWrappedRows() {
    let t = makeTerminal(cols: 5, rows: 3).run("abcdefgh")
    let s = Selection(anchor: pos(0, 0), head: pos(1, 3), mode: .block)
    #expect(t.text(in: s) == "abc\nfgh")
}

@Test func selectionSpansScrollbackAndScreen() {
    let t = makeTerminal(cols: 10, rows: 2, scrollback: 10).run("one\r\ntwo\r\nthree\r\nfour")
    #expect(t.scrollback.count == 2)
    let s = Selection(anchor: pos(0, 0), head: pos(3, 10), mode: .character)
    #expect(t.text(in: s) == "one\ntwo\nthree\nfour")
}

@Test func wordRangeFindsWordBoundaries() {
    let t = makeTerminal(cols: 30, rows: 2).run("hello  world/path")
    #expect(t.wordRange(at: pos(0, 1), separators: defaultSeparators) == 0..<5)
    #expect(t.wordRange(at: pos(0, 4), separators: defaultSeparators) == 0..<5)
    #expect(t.wordRange(at: pos(0, 8), separators: defaultSeparators) == 7..<17)
}

@Test func wordRangeOnASeparatorSelectsJustIt() {
    let t = makeTerminal(cols: 30, rows: 2).run("a b")
    #expect(t.wordRange(at: pos(0, 1), separators: defaultSeparators) == 1..<2)
}

@Test func wordRangeOnAnEmptyCellIsNil() {
    let t = makeTerminal(cols: 30, rows: 2).run("ab")
    #expect(t.wordRange(at: pos(0, 10), separators: defaultSeparators) == nil)
}

@Test func lineSelectionOfAWrappedLineTakesTheWholeLogicalLine() {
    let t = makeTerminal(cols: 5, rows: 3).run("abcdefgh")
    let s = Selection(anchor: pos(0, 0), head: pos(1, 0), mode: .line)
    #expect(t.text(in: s) == "abcdefgh")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Selection 2>&1 | tail -5`
Expected: compile error, `value of type 'Terminal' has no member 'totalRows'`.

- [ ] **Step 3: Write the implementation**

`Sources/NyxCore/Selection/Terminal+Selection.swift`:
```swift
extension Terminal {
    /// Total number of absolute rows: every scrollback line plus the live screen.
    public var totalRows: Int { scrollback.count + rows }

    /// Row at an absolute index, or nil when out of range.
    public func absoluteRow(_ row: Int) -> Row? {
        guard row >= 0, row < totalRows else { return nil }
        return row < scrollback.count ? scrollback[row] : screen.rows[row - scrollback.count]
    }

    /// Absolute index of the top visible row. `viewportOffset` counts lines scrolled up from live.
    public var viewportTopRow: Int { scrollback.count - viewportOffset }

    /// Visible text of one row restricted to a column range, skipping the trailing halves of wide
    /// glyphs and rendering empty cells as spaces.
    private func rowText(_ row: Row, _ range: Range<Int>) -> String {
        var out = ""
        for x in range where x < row.cells.count {
            let c = row.cells[x]
            if c.attrs.contains(.wideSpacer) { continue }
            out += c.content == 0 ? " " : clusterText(of: c)
        }
        return out
    }

    /// The text a selection covers.
    ///
    /// Rows joined by a soft wrap produce no newline, so copying a wrapped command line gives back
    /// the command rather than the way it happened to be broken on screen. Block selections take
    /// their columns literally and always break lines, which is the whole point of the mode.
    public func text(in selection: Selection) -> String {
        guard !selection.isEmpty else { return "" }
        let first = max(selection.start.row, 0)
        let last = min(selection.end.row, totalRows - 1)
        guard first <= last else { return "" }

        var out = ""
        for absolute in first...last {
            guard let row = absoluteRow(absolute),
                  let range = selection.columnRange(onRow: absolute, cols: cols) else { continue }
            var piece = rowText(row, range)
            if selection.mode != .block {
                while piece.hasSuffix(" ") { piece.removeLast() }
            }
            out += piece
            guard absolute < last else { continue }
            // A soft wrap continues the same logical line; anything else ends it.
            let joins = selection.mode != .block && row.wrapped && range.upperBound >= cols
            if !joins { out += "\n" }
        }
        return out
    }

    /// Expands a position to the word around it. A position on a separator selects just that
    /// separator, which is what double-clicking a bracket should do; an empty cell selects nothing.
    public func wordRange(at position: AbsolutePosition, separators: Set<Character>) -> Range<Int>? {
        guard let row = absoluteRow(position.row), position.col >= 0, position.col < cols else { return nil }

        func text(_ x: Int) -> String {
            let c = row.cells[x]
            if c.attrs.contains(.wideSpacer), x > 0 { return clusterText(of: row.cells[x - 1]) }
            return c.content == 0 ? "" : clusterText(of: c)
        }
        func isSeparator(_ x: Int) -> Bool {
            guard let ch = text(x).first else { return true }
            return separators.contains(ch)
        }

        let here = text(position.col)
        guard !here.isEmpty else { return nil }
        if let ch = here.first, separators.contains(ch) { return position.col..<(position.col + 1) }

        var lo = position.col
        while lo > 0 && !isSeparator(lo - 1) { lo -= 1 }
        var hi = position.col + 1
        while hi < cols && !isSeparator(hi) { hi += 1 }
        return lo..<hi
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter Selection 2>&1 | tail -3`
Expected: 22 tests pass (9 from Task 2, 13 new).

If `lineSelectionOfAWrappedLineTakesTheWholeLogicalLine` fails, check that `.line` mode reaches the soft-wrap join: `columnRange` returns `0..<cols` for line mode, so `range.upperBound >= cols` holds and a `wrapped` row joins. If `blockSelectionDoesNotJoinWrappedRows` fails, check the `selection.mode != .block` guard on `joins`.

- [ ] **Step 5: Run the full suite and commit**

Run: `swift test 2>&1 | tail -2`
Expected: 189 tests pass.

```bash
git add Sources/NyxCore/Selection/Terminal+Selection.swift Tests/NyxCoreTests/SelectionTests.swift
git commit -m "feat(core): selection text extraction and word hit-testing"
```

---

### Task 4: Paint the selection

**Files:**
- Modify: `Sources/NyxRender/Renderer.swift` (`RenderFrame`, `buildInstances`)
- Modify: `Sources/NyxApp/TerminalView.swift` (construct the new field; pass nil for now)
- Test: `Tests/NyxRenderTests/SelectionRenderTests.swift`

**Interfaces:**
- Consumes: `Selection`, `AbsolutePosition` from Task 2; the existing `RenderFrame`.
- Produces: `RenderFrame` gains two fields, and `Palette` gains a selection colour.
  ```swift
  // On RenderFrame, after `preedit`:
  /// Selected column range per visible row, indexed the same way as `lines`. nil means nothing
  /// selected on that row. The view computes these from the absolute selection and the viewport.
  public var selection: [Range<Int>?]
  // On Palette:
  public var selectionBackground: RGB
  public var selectionForeground: RGB?   // nil = keep the cell's own foreground
  ```
  `RenderFrame.init` gains `selection: [Range<Int>?] = []` as its last parameter with a default, so existing call sites keep compiling. An empty array means "no selection anywhere".

Selection paints as a background swap: a selected cell draws `selectionBackground` behind it, and its glyph draws in `selectionForeground` when that is non-nil. This is one more instance per selected cell in the background pass, not a separate draw call.

- [ ] **Step 1: Write the failing test**

`Tests/NyxRenderTests/SelectionRenderTests.swift`:
```swift
import Testing
import Metal
import NyxCore
@testable import NyxRender

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

private func renderSelection(_ selection: [Range<Int>?], cols: Int = 4, rows: Int = 2,
                             edit: (inout [Row]) -> Void = { _ in }) throws -> (FontSet, (Int, Int) -> Pixel) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    var lines = Array(repeating: Row(cols: cols), count: rows)
    edit(&lines)
    var palette = Palette.xtermDefault()
    palette.selectionBackground = RGB(0, 0, 255)
    let frame = RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: palette,
                            cursor: nil, cursorShape: .block, focused: true, preedit: nil,
                            selection: selection)
    let w = fonts.metrics.width * cols, h = fonts.metrics.height * rows
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    let tex = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(r.queue.makeCommandBuffer())
    r.render(frame, to: tex, commandBuffer: cb, padding: 0)
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (fonts, { x, y in
        let i = (y * w + x) * 4
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i])
    })
}

@Test func selectedCellsPaintTheSelectionBackground() throws {
    let (fonts, px) = try renderSelection([1..<3, nil])
    let w = fonts.metrics.width
    #expect(px(w / 2, 2) != Pixel(r: 0, g: 0, b: 255))          // column 0: not selected
    #expect(px(w + w / 2, 2) == Pixel(r: 0, g: 0, b: 255))      // column 1: selected
    #expect(px(2 * w + w / 2, 2) == Pixel(r: 0, g: 0, b: 255))  // column 2: selected
    #expect(px(3 * w + w / 2, 2) != Pixel(r: 0, g: 0, b: 255))  // column 3: not selected
}

@Test func unselectedRowsAreUntouched() throws {
    let (fonts, px) = try renderSelection([0..<4, nil])
    let m = fonts.metrics
    #expect(px(m.width / 2, 2) == Pixel(r: 0, g: 0, b: 255))
    #expect(px(m.width / 2, m.height + 2) != Pixel(r: 0, g: 0, b: 255))
}

@Test func anEmptySelectionArrayPaintsNothing() throws {
    let (fonts, px) = try renderSelection([])
    #expect(px(fonts.metrics.width / 2, 2) != Pixel(r: 0, g: 0, b: 255))
}

@Test func selectionOverridesTheCellBackground() throws {
    let (fonts, px) = try renderSelection([0..<1, nil]) { $0[0].cells[0].bg = .rgb(255, 0, 0) }
    #expect(px(fonts.metrics.width / 2, 2) == Pixel(r: 0, g: 0, b: 255))
}

@Test func selectionForegroundRecolorsTheGlyph() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    var lines = [Row(cols: 2)]
    lines[0].cells[0].content = 0x4D   // "M"
    var palette = Palette.xtermDefault()
    palette.selectionBackground = RGB(0, 0, 0)
    palette.selectionForeground = RGB(0, 255, 0)
    let frame = RenderFrame(cols: 2, rows: 1, lines: lines, graphemes: [], palette: palette,
                            cursor: nil, cursorShape: .block, focused: true, preedit: nil,
                            selection: [0..<1])
    let w = fonts.metrics.width * 2, h = fonts.metrics.height
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    let tex = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(r.queue.makeCommandBuffer())
    r.render(frame, to: tex, commandBuffer: cb, padding: 0)
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var greenest = 0
    for y in 0..<h {
        for x in 0..<fonts.metrics.width {
            let i = (y * w + x) * 4
            greenest = max(greenest, Int(bytes[i + 1]))
        }
    }
    #expect(greenest > 100)   // the glyph took the selection foreground, not the default grey
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SelectionRender 2>&1 | tail -5`
Expected: compile error, `extra argument 'selection' in call` or `value of type 'Palette' has no member 'selectionBackground'`.

- [ ] **Step 3: Add the palette colours**

In `Sources/NyxCore/Terminal/Color.swift`, add to `Palette`:
```swift
    /// Background painted behind selected cells.
    public var selectionBackground: RGB
    /// Foreground for selected cells, or nil to keep each cell's own colour. Themes that pick a
    /// selection background close to the text colour set this; most do not need it.
    public var selectionForeground: RGB?
```
Initialise them in `Palette.init(ansi:foreground:background:cursor:)` — add two parameters with defaults so no existing call site breaks:
```swift
    public init(ansi: [RGB], foreground: RGB, background: RGB, cursor: RGB,
                selectionBackground: RGB? = nil, selectionForeground: RGB? = nil)
```
and default `selectionBackground` to `foreground.scaled(0.35)` when the caller passes nil, which gives a readable tint against any theme's own foreground without the theme having to specify one.

Update the two `Palette.xtermDefault()` and `Theme.nyxDark` sites only if they need a specific colour; both are fine with the derived default.

- [ ] **Step 4: Add the frame field and paint it**

In `RenderFrame`, add `public var selection: [Range<Int>?]` after `preedit`, and add `selection: [Range<Int>?] = []` as the last parameter of `init`, assigning it.

In `Renderer.buildInstances`, inside the per-cell loop, after `resolve` has produced `(fg, bg)` and before the block-cursor override, apply the selection:
```swift
let selected = y < f.selection.count && (f.selection[y]?.contains(x) ?? false)
if selected {
    bg = f.palette.selectionBackground
    if let sf = f.palette.selectionForeground { fg = sf }
}
```
The block-cursor override must still come after this, so the cursor stays visible on top of a selection.

The background rect is currently emitted only when `bg != f.palette.background || blockCursor`; add `|| selected` so a selected cell with the default background still paints.

- [ ] **Step 5: Update the existing call site**

`TerminalView.render()` constructs a `RenderFrame`; it compiles unchanged thanks to the default, but pass `selection: []` explicitly so the field is visible at the call site that Task 6 will fill in.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter SelectionRender 2>&1 | tail -3 && swift test 2>&1 | tail -2`
Expected: 5 new tests pass; full suite green.

- [ ] **Step 7: Commit**

```bash
git add Sources/NyxRender/Renderer.swift Sources/NyxCore/Terminal/Color.swift \
        Sources/NyxApp/TerminalView.swift Tests/NyxRenderTests/SelectionRenderTests.swift
git commit -m "feat(render): paint selected cells"
```

---

### Task 5: Mouse reporting to TUI applications

**Files:**
- Create: `Sources/NyxCore/Mouse/MouseEncoder.swift`
- Test: `Tests/NyxCoreTests/MouseEncoderTests.swift`

**Interfaces:**
- Consumes: `MouseMode` and `TerminalModes` from `Terminal.swift`, `KeyModifiers` from `KeyEncoder.swift`.
- Produces:
  ```swift
  public enum MouseButton: Int, Equatable { case left = 0, middle = 1, right = 2, wheelUp = 64, wheelDown = 65 }
  public enum MouseAction: Equatable { case press, release, drag, move }

  public struct MouseEvent: Equatable {
      public var button: MouseButton
      public var action: MouseAction
      public var col: Int          // 0-based cell column
      public var row: Int          // 0-based cell row, viewport-relative
      public var modifiers: KeyModifiers
      public init(button: MouseButton, action: MouseAction, col: Int, row: Int, modifiers: KeyModifiers)
  }

  public enum MouseEncoder {
      /// Bytes for one mouse event under the terminal's current modes, or nil when the application
      /// has not asked for this event (mouse off, or a motion event in a mode that does not want it).
      public static func encode(_ e: MouseEvent, mode: MouseMode, sgr: Bool) -> [UInt8]?
  }
  ```

Encoding rules, from xterm's `ctlseqs`:
- Button bits: left 0, middle 1, right 2, wheel up 64, wheel down 65. Motion adds 32. Shift adds 4, Alt (meta) 8, Control 16.
- SGR (mode 1006): `CSI < b ; col+1 ; row+1 M` for press/drag, and the same with a final `m` for release. Release keeps the real button number.
- Legacy (no 1006): `CSI M` then three bytes `32+b`, `32+col+1`, `32+row+1`. Release reports button 3, so the byte is `32+3+modifiers`. Coordinates above 223 cannot be encoded; return nil rather than sending a wrong position.
- Mode `.none`: always nil. `.x10`: press only, no modifiers, no release. `.normal` (1000): press and release. `.button` (1002): press, release and drag with a button held. `.any` (1003): also bare motion.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/MouseEncoderTests.swift`:
```swift
import Testing
@testable import NyxCore

private func enc(_ button: MouseButton, _ action: MouseAction, _ col: Int, _ row: Int,
                 _ mods: KeyModifiers = [], mode: MouseMode = .normal, sgr: Bool = true) -> String? {
    MouseEncoder.encode(MouseEvent(button: button, action: action, col: col, row: row, modifiers: mods),
                        mode: mode, sgr: sgr).map { String(decoding: $0, as: UTF8.self) }
}
private let ESC = "\u{1B}"

@Test func mouseOffReportsNothing() {
    #expect(enc(.left, .press, 0, 0, mode: .none) == nil)
}

@Test func sgrPressAndRelease() {
    #expect(enc(.left, .press, 3, 5) == ESC + "[<0;4;6M")
    #expect(enc(.left, .release, 3, 5) == ESC + "[<0;4;6m")
    #expect(enc(.right, .press, 0, 0) == ESC + "[<2;1;1M")
    #expect(enc(.middle, .press, 0, 0) == ESC + "[<1;1;1M")
}

@Test func sgrModifiersAddTheirBits() {
    #expect(enc(.left, .press, 0, 0, [.shift]) == ESC + "[<4;1;1M")
    #expect(enc(.left, .press, 0, 0, [.alt]) == ESC + "[<8;1;1M")
    #expect(enc(.left, .press, 0, 0, [.ctrl]) == ESC + "[<16;1;1M")
    #expect(enc(.left, .press, 0, 0, [.shift, .ctrl]) == ESC + "[<20;1;1M")
}

@Test func wheelReportsAsButtons64And65() {
    #expect(enc(.wheelUp, .press, 2, 2) == ESC + "[<64;3;3M")
    #expect(enc(.wheelDown, .press, 2, 2) == ESC + "[<65;3;3M")
}

@Test func dragAddsTheMotionBit() {
    #expect(enc(.left, .drag, 1, 1, mode: .button) == ESC + "[<32;2;2M")
    #expect(enc(.right, .drag, 1, 1, mode: .button) == ESC + "[<34;2;2M")
}

@Test func bareMotionOnlyInAnyEventMode() {
    #expect(enc(.left, .move, 1, 1, mode: .button) == nil)
    #expect(enc(.left, .move, 1, 1, mode: .normal) == nil)
    #expect(enc(.left, .move, 1, 1, mode: .any) == ESC + "[<35;2;2M")
}

@Test func dragOnlyInButtonAndAnyModes() {
    #expect(enc(.left, .drag, 1, 1, mode: .normal) == nil)
    #expect(enc(.left, .drag, 1, 1, mode: .x10) == nil)
    #expect(enc(.left, .drag, 1, 1, mode: .any) == ESC + "[<32;2;2M")
}

@Test func x10ModeIsPressOnlyAndIgnoresModifiers() {
    #expect(enc(.left, .press, 1, 1, [.ctrl], mode: .x10, sgr: false) == ESC + "[M\u{20}\u{22}\u{22}")
    #expect(enc(.left, .release, 1, 1, mode: .x10, sgr: false) == nil)
}

@Test func legacyEncodingOffsetsBy32() {
    #expect(enc(.left, .press, 0, 0, sgr: false) == ESC + "[M\u{20}\u{21}\u{21}")
    #expect(enc(.left, .press, 3, 5, sgr: false) == ESC + "[M\u{20}\u{24}\u{26}")
}

@Test func legacyReleaseReportsButtonThree() {
    #expect(enc(.left, .release, 0, 0, sgr: false) == ESC + "[M\u{23}\u{21}\u{21}")
    #expect(enc(.right, .release, 0, 0, sgr: false) == ESC + "[M\u{23}\u{21}\u{21}")
}

@Test func legacyEncodingRefusesCoordinatesItCannotRepresent() {
    #expect(enc(.left, .press, 222, 0, sgr: false) != nil)
    #expect(enc(.left, .press, 223, 0, sgr: false) == nil)
    #expect(enc(.left, .press, 0, 223, sgr: false) == nil)
    #expect(enc(.left, .press, 223, 0, sgr: true) == ESC + "[<0;224;1M")
}

@Test func negativeCoordinatesAreRefused() {
    #expect(enc(.left, .press, -1, 0) == nil)
    #expect(enc(.left, .press, 0, -1) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MouseEncoder 2>&1 | tail -5`
Expected: compile error, `cannot find 'MouseEncoder' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/NyxCore/Mouse/MouseEncoder.swift`:
```swift
public enum MouseButton: Int, Equatable {
    case left = 0, middle = 1, right = 2, wheelUp = 64, wheelDown = 65
}

public enum MouseAction: Equatable { case press, release, drag, move }

public struct MouseEvent: Equatable {
    public var button: MouseButton
    public var action: MouseAction
    /// 0-based cell column and viewport-relative row.
    public var col: Int
    public var row: Int
    public var modifiers: KeyModifiers

    public init(button: MouseButton, action: MouseAction, col: Int, row: Int, modifiers: KeyModifiers) {
        self.button = button
        self.action = action
        self.col = col
        self.row = row
        self.modifiers = modifiers
    }
}

/// Encodes mouse events the way xterm does, in either the SGR form (mode 1006) or the original
/// byte-offset form. See xterm's `ctlseqs`, "Mouse Tracking".
public enum MouseEncoder {
    public static func encode(_ e: MouseEvent, mode: MouseMode, sgr: Bool) -> [UInt8]? {
        guard e.col >= 0, e.row >= 0 else { return nil }
        guard wants(e.action, in: mode) else { return nil }

        var code = e.button.rawValue
        if e.action == .drag || e.action == .move { code += 32 }
        // X10 reports the raw button with no modifier bits at all.
        if mode != .x10 {
            if e.modifiers.contains(.shift) { code += 4 }
            if e.modifiers.contains(.alt) { code += 8 }
            if e.modifiers.contains(.ctrl) { code += 16 }
        }

        if sgr {
            let final = e.action == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(e.col + 1);\(e.row + 1)\(final)".utf8)
        }

        // The original encoding has one byte per field, biased by 32, so it cannot express a
        // coordinate past 222. Sending a wrong position is worse than sending nothing.
        guard e.col < 223, e.row < 223 else { return nil }
        // It also has no way to say which button was released: 3 means "some button came up".
        let legacyCode = e.action == .release ? (code - e.button.rawValue) + 3 : code
        guard legacyCode >= 0, legacyCode < 223 else { return nil }
        return Array("\u{1B}[M".utf8) + [UInt8(32 + legacyCode), UInt8(32 + e.col + 1), UInt8(32 + e.row + 1)]
    }

    private static func wants(_ action: MouseAction, in mode: MouseMode) -> Bool {
        switch mode {
        case .none: return false
        case .x10: return action == .press
        case .normal: return action == .press || action == .release
        case .button: return action != .move
        case .any: return true
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MouseEncoder 2>&1 | tail -3`
Expected: 12 tests pass.

If `legacyEncodingRefusesCoordinatesItCannotRepresent` fails at 222, remember the byte is `32 + col + 1`, so the last representable 0-based column is 222 (byte 255).

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Mouse/MouseEncoder.swift Tests/NyxCoreTests/MouseEncoderTests.swift
git commit -m "feat(core): xterm mouse event encoding"
```

---

### Task 6: Selection and mouse in the view

**Files:**
- Modify: `Sources/NyxApp/TerminalView.swift`
- Test: no unit test — this is AppKit event handling. Verified by the acceptance checks in Step 5 and by the snapshot test staying green.

**Interfaces:**
- Consumes: `Selection`, `AbsolutePosition`, `SelectionMode`, `Terminal.text(in:)`, `Terminal.wordRange(at:separators:)`, `Terminal.viewportTopRow`, `Terminal.totalRows`, `MouseEncoder.encode(_:mode:sgr:)`, `MouseEvent`, `MouseButton`, `MouseAction`, `RenderFrame.selection`.
- Produces on `TerminalView`: `var selection: Selection?` and the behaviour below. Task 9 moves this file to `Pane.swift` unchanged.

Behaviour to implement:

**Hit testing.** A point in view coordinates maps to an `AbsolutePosition`: subtract the padding, divide by the cell size in points, clamp the column to `0...cols`, and add `terminal.viewportTopRow` to the row. Note the column clamp is inclusive of `cols`: dragging past the right edge should select to the end of the line, and `Selection.columnRange` already clamps. Clamp the absolute row to `0..<totalRows`.

**When the application wants the mouse.** If `terminal.modes.mouse != .none` and the Option key is *not* held, mouse events go to the application through `MouseEncoder` instead of selecting. Option held is the standard override that lets you select text inside a full-screen program. Send press on `mouseDown`, release on `mouseUp`, drag on `mouseDragged`, and bare motion on `mouseMoved` — the last requires `updateTrackingAreas` to install an `NSTrackingArea` with `.mouseMoved`, `.activeInKeyWindow` and `.inVisibleRect`, and it should only be installed while `modes.mouse == .any` to avoid pointless events. Right and middle buttons go through `rightMouseDown`/`otherMouseDown` and their partners. The wheel reports `wheelUp`/`wheelDown` as presses when the application asked for the mouse and the alternate screen is active; otherwise the existing scrollback behaviour stands.

**Selecting.** Otherwise, `mouseDown` starts a selection with mode chosen by `event.clickCount`: 1 character, 2 word, 3 line. Option held forces `.block` regardless of click count. For a word selection, expand through `wordRange(at:separators:)` and set the anchor and head to that range's ends; for a line selection take the whole row. `mouseDragged` moves the head and, for word and line modes, re-expands so dragging by words keeps whole words. `mouseUp` ends the drag. A click with no drag clears the selection.

**Autoscroll.** While dragging past the top or bottom edge, scroll the viewport by one line per tick and keep extending. Do this from the existing display-link tick rather than a separate timer: if a drag is active and the last mouse point is outside the bounds, call `scrollViewport(by:)` before rendering.

**Copy.** `⌘C` copies `terminal.text(in: selection)` to `NSPasteboard.general` as `.string`, and does nothing when there is no selection. Add it to the Edit menu with key equivalent `c`. When `config.copyOnSelect` is on, also copy on `mouseUp` when the selection is non-empty.

**Middle-click paste.** `otherMouseUp` with button number 2 pastes from `NSPasteboard.general` when `config.middleClickPaste` is on and the application has not taken the mouse.

**Clearing.** Typing anything clears the selection, as does scrolling to the bottom by output. Any change to the selection sets the dirty flag.

**Feeding the renderer.** In `render()`, build the `selection` array: for each visible row index `i`, ask `selection?.columnRange(onRow: terminal.viewportTopRow + i, cols: terminal.cols)`. Compute it inside the `withTerminal` block along with everything else, so it is consistent with the lines being drawn.

- [ ] **Step 1: Hit testing and the selection property**

Add `private(set) var selection: Selection?`, the point-to-position mapping, and the `render()` change that fills `RenderFrame.selection`. Nothing selects yet.

Run: `swift build 2>&1 | grep -c warning` — expect `0`.

- [ ] **Step 2: Mouse-driven selection**

Implement `mouseDown`/`mouseDragged`/`mouseUp` with click counts, Option-forces-block, and word/line expansion. Selection changes call `markDirty()`.

- [ ] **Step 3: Copy, copy-on-select and middle-click paste**

`⌘C` in the Edit menu, `copy(_:)` on the view, the `copyOnSelect` hook on mouse up, and `otherMouseUp` pasting. Until Task 11 lands the config, read the two flags from constants: `copyOnSelect = false`, `middleClickPaste = true`, matching the spec's defaults.

- [ ] **Step 4: Mouse reporting**

Route events through `MouseEncoder` when the application asked for the mouse and Option is not held; install and remove the tracking area with the mode.

- [ ] **Step 5: Verify by hand**

Build and run: `make app && open build/Nyx.app`. Check each:
1. Drag across text: it highlights; `⌘C` then `⌘V` round-trips it.
2. Double-click a word selects the word; triple-click the line; Option-drag makes a rectangle.
3. Select across a wrapped line and paste: the text comes back joined, without the wrap.
4. Select into the scrollback (drag above the top edge): it autoscrolls and keeps extending.
5. Run `vim`, drag: the selection appears (vim has not asked for the mouse in its default macOS config). Then `:set mouse=a` and drag: vim's own visual selection responds instead. Hold Option and drag: Nyx selects again.
6. In vim with `mouse=a`, the scroll wheel scrolls vim.
7. Middle-click pastes.
8. Type after selecting: the selection disappears.

Record the result of each in the report. Any that fails is a bug in this task, not a note for later.

- [ ] **Step 6: Run the suite and commit**

Run: `swift test 2>&1 | tail -2 && NYX_SNAPSHOT=1 swift test --filter Snapshot 2>&1 | tail -2`
Expected: both green.

```bash
git add Sources/NyxApp/TerminalView.swift Sources/NyxApp/MainMenu.swift
git commit -m "feat(app): mouse selection, copy, and mouse reporting to applications"
```

---

### Task 7: Config value and parser

**Files:**
- Create: `Sources/NyxCore/Config/Config.swift`, `Sources/NyxCore/Config/ConfigParser.swift`
- Test: `Tests/NyxCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Config: Equatable {
      public var fontFamily: String            // "Menlo"
      public var fontSize: Double              // 13
      public var lineHeight: Double            // 1.0
      public var themeName: String             // "nyx-dark"
      public var darkThemeName: String?        // set by `theme = dark:a,light:b`
      public var lightThemeName: String?
      public var cursorStyle: CursorShape      // .block
      public var cursorBlink: Bool             // true
      public var scrollbackLines: Int          // 10_000
      public var padding: Double               // 8
      public var backgroundOpacity: Double     // 1.0
      public var backgroundBlur: Double        // 0
      public var shell: String?                // nil = $SHELL
      public var workingDirectory: String      // "inherit" | "home" | an absolute path
      public var copyOnSelect: Bool            // false
      public var middleClickPaste: Bool        // true
      public var optionAsMeta: OptionAsMeta    // .none
      public var mouseScrollAltScreen: Bool    // true = send arrows
      public var bell: BellStyle               // .visual
      public var confirmCloseProcess: Bool     // true
      public var clipboardRead: Bool           // false
      public var tabBar: TabBarVisibility      // .auto
      public var windowDecorations: Bool       // true
      public var wordSeparators: Set<Character>
      public var openFileCommand: String?      // nil = NSWorkspace.open
      public var keybinds: [KeyBinding]        // Task 8
      public var paletteOverrides: [Int: RGB]  // index -> colour
      public static let defaults: Config
  }

  public enum OptionAsMeta: String, Equatable { case none, left, right, both }
  public enum BellStyle: String, Equatable { case visual, sound, none }
  public enum TabBarVisibility: String, Equatable { case auto, always, never }

  public struct ConfigDiagnostic: Equatable {
      public var line: Int      // 1-based
      public var message: String
  }

  public enum ConfigParser {
      /// Parses a config file. Unknown keys and bad values are reported as diagnostics and the
      /// affected setting keeps its default; parsing never fails outright, because a terminal that
      /// refuses to start over a typo is useless.
      public static func parse(_ text: String) -> (config: Config, diagnostics: [ConfigDiagnostic])
  }
  ```

The `keybinds` field is populated by Task 8's parser; until then `ConfigParser` collects `keybind` lines and leaves the array empty. Write Task 7 so adding it is one line.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/ConfigTests.swift`:
```swift
import Testing
@testable import NyxCore

private func parse(_ s: String) -> (Config, [ConfigDiagnostic]) { ConfigParser.parse(s) }

@Test func anEmptyFileGivesTheDefaults() {
    let (c, d) = parse("")
    #expect(c == Config.defaults)
    #expect(d.isEmpty)
}

@Test func commentsAndBlankLinesAreIgnored() {
    let (c, d) = parse("# a comment\n\n   \n# another\n")
    #expect(c == Config.defaults)
    #expect(d.isEmpty)
}

@Test func parsesScalarSettings() {
    let (c, d) = parse("""
    font-family = JetBrains Mono
    font-size = 15
    line-height = 1.2
    padding = 12
    scrollback-lines = 50000
    background-opacity = 0.9
    """)
    #expect(d.isEmpty)
    #expect(c.fontFamily == "JetBrains Mono")
    #expect(c.fontSize == 15)
    #expect(c.lineHeight == 1.2)
    #expect(c.padding == 12)
    #expect(c.scrollbackLines == 50000)
    #expect(c.backgroundOpacity == 0.9)
}

@Test func whitespaceAroundKeysAndValuesIsTrimmed() {
    let (c, _) = parse("   font-size   =   20   ")
    #expect(c.fontSize == 20)
}

@Test func valuesMayContainEqualsSigns() {
    let (c, _) = parse("open-file-command = code -g {file}:{line}")
    #expect(c.openFileCommand == "code -g {file}:{line}")
}

@Test func parsesBooleans() {
    let (c, d) = parse("copy-on-select = true\nmiddle-click-paste = false\ncursor-blink = no\nwindow-decorations = yes")
    #expect(d.isEmpty)
    #expect(c.copyOnSelect)
    #expect(!c.middleClickPaste)
    #expect(!c.cursorBlink)
    #expect(c.windowDecorations)
}

@Test func parsesEnums() {
    let (c, d) = parse("cursor-style = bar\noption-as-meta = both\nbell = none\ntab-bar = always")
    #expect(d.isEmpty)
    #expect(c.cursorStyle == .bar)
    #expect(c.optionAsMeta == .both)
    #expect(c.bell == .none)
    #expect(c.tabBar == .always)
}

@Test func parsesAPlainThemeName() {
    let (c, _) = parse("theme = gruvbox-dark")
    #expect(c.themeName == "gruvbox-dark")
    #expect(c.darkThemeName == nil && c.lightThemeName == nil)
}

@Test func parsesADarkLightThemePair() {
    let (c, d) = parse("theme = dark:nyx-dark,light:nyx-light")
    #expect(d.isEmpty)
    #expect(c.darkThemeName == "nyx-dark")
    #expect(c.lightThemeName == "nyx-light")
}

@Test func parsesWordSeparators() {
    let (c, _) = parse("word-separators = ,;:")
    #expect(c.wordSeparators == Set(",;:"))
}

@Test func parsesPaletteOverrides() {
    let (c, d) = parse("palette = 0=#1a1b26\npalette = 15=#ffffff")
    #expect(d.isEmpty)
    #expect(c.paletteOverrides[0] == RGB(0x1a, 0x1b, 0x26))
    #expect(c.paletteOverrides[15] == RGB(255, 255, 255))
}

@Test func anUnknownKeyIsADiagnosticNotAFailure() {
    let (c, d) = parse("font-size = 15\nnot-a-setting = 3\npadding = 4")
    #expect(c.fontSize == 15)
    #expect(c.padding == 4)
    #expect(d.count == 1)
    #expect(d[0].line == 2)
    #expect(d[0].message.contains("not-a-setting"))
}

@Test func aBadValueKeepsTheDefaultAndReportsTheLine() {
    let (c, d) = parse("\nfont-size = enormous\n")
    #expect(c.fontSize == Config.defaults.fontSize)
    #expect(d.count == 1)
    #expect(d[0].line == 2)
}

@Test func aLineWithNoEqualsIsADiagnostic() {
    let (_, d) = parse("font-size 15")
    #expect(d.count == 1)
    #expect(d[0].line == 1)
}

@Test func outOfRangeNumbersAreClamped() {
    let (c, _) = parse("font-size = 0\nbackground-opacity = 5\nscrollback-lines = -3")
    #expect(c.fontSize >= 4)
    #expect(c.backgroundOpacity == 1.0)
    #expect(c.scrollbackLines == 0)
}

@Test func aLaterLineWinsOverAnEarlierOne() {
    let (c, _) = parse("font-size = 10\nfont-size = 20")
    #expect(c.fontSize == 20)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Config 2>&1 | tail -5`
Expected: compile error, `cannot find 'ConfigParser' in scope`.

- [ ] **Step 3: Write `Config.swift`**

Declare the struct exactly as in the Interfaces block, `Equatable`, with a `static let defaults` carrying every value named in the spec's phase-2 key list. `wordSeparators` defaults to `Set(" ()[]{}'\"`,;:|<>")`.

- [ ] **Step 4: Write `ConfigParser.swift`**

Parse line by line, tracking a 1-based line number. Skip blanks and lines whose first non-space character is `#`. Split on the first `=` only, so values may contain more. Trim both sides. Dispatch on the key with a switch; each case parses its value and either assigns or appends a diagnostic naming the line and what was wrong. Clamp numbers to sane ranges: font size 4...144, line height 0.5...3, padding 0...200, opacity 0...1, blur 0...100, scrollback 0...10_000_000. Booleans accept `true/false/yes/no/1/0`. `theme` takes either a bare name or the `dark:a,light:b` pair. `palette` takes `index=colour` and uses the existing `RGB(spec:)`. Collect `keybind` lines into an array of raw strings for Task 8 and ignore them for now.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter Config 2>&1 | tail -3`
Expected: 16 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Config Tests/NyxCoreTests/ConfigTests.swift
git commit -m "feat(core): configuration value and forgiving parser"
```

---

### Task 8: Key binding syntax and the action list

**Files:**
- Create: `Sources/NyxCore/Config/KeyBinding.swift`
- Modify: `Sources/NyxCore/Config/ConfigParser.swift` (wire `keybind` lines through)
- Test: `Tests/NyxCoreTests/KeyBindingTests.swift`

**Interfaces:**
- Consumes: `KeyModifiers`, `Key` from `KeyEncoder.swift`.
- Produces:
  ```swift
  /// Everything a key or menu item can trigger. The app switches on this in one place.
  public enum TerminalAction: String, Equatable, CaseIterable {
      case newWindow = "new_window", newTab = "new_tab", closePane = "close_pane"
      case nextTab = "next_tab", previousTab = "previous_tab"
      case tab1 = "tab_1", tab2 = "tab_2", tab3 = "tab_3", tab4 = "tab_4", tab5 = "tab_5"
      case tab6 = "tab_6", tab7 = "tab_7", tab8 = "tab_8", tab9 = "tab_9"
      case splitRight = "split_right", splitDown = "split_down"
      case focusLeft = "focus_left", focusRight = "focus_right"
      case focusUp = "focus_up", focusDown = "focus_down"
      case growLeft = "grow_left", growRight = "grow_right", growUp = "grow_up", growDown = "grow_down"
      case toggleZoom = "toggle_zoom"
      case copy = "copy", paste = "paste", clearScreen = "clear_screen"
      case fontBigger = "font_bigger", fontSmaller = "font_smaller", fontReset = "font_reset"
      case openConfig = "open_config", reloadConfig = "reload_config"
  }

  public struct KeyBinding: Equatable {
      public var key: Key
      public var modifiers: KeyModifiers
      public var action: TerminalAction
      public init(key: Key, modifiers: KeyModifiers, action: TerminalAction)

      /// Parses one `keybind` value, e.g. "cmd+shift+d=split_down". Returns nil on any error.
      public static func parse(_ s: String) -> KeyBinding?
      /// The default bindings from spec §6.2.
      public static let defaults: [KeyBinding]
  }
  ```
  `Key` needs `Hashable` for lookup; add the conformance (it is already `Equatable`).

Syntax: `modifier+modifier+key=action`. Modifiers are `cmd`, `ctrl`/`control`, `alt`/`opt`/`option`, `shift`, in any order. Keys are a single character (`d`, `1`, `+`), or a name: `enter`/`return`, `tab`, `escape`/`esc`, `space`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, `up`, `down`, `left`, `right`, `f1`...`f12`. Matching is case-insensitive for names and modifiers; a single-character key keeps its case, so `shift+d` and `D` are distinguishable if someone writes them that way — normalise by lowercasing a single alphabetic character and requiring `shift` to be explicit.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/KeyBindingTests.swift`:
```swift
import Testing
@testable import NyxCore

private func p(_ s: String) -> KeyBinding? { KeyBinding.parse(s) }

@Test func parsesASimpleBinding() {
    let b = p("cmd+t=new_tab")
    #expect(b?.modifiers == [.cmd])
    #expect(b?.key == .char("t"))
    #expect(b?.action == .newTab)
}

@Test func parsesSeveralModifiersInAnyOrder() {
    #expect(p("cmd+shift+d=split_down")?.modifiers == [.cmd, .shift])
    #expect(p("shift+cmd+d=split_down")?.modifiers == [.cmd, .shift])
    #expect(p("ctrl+alt+cmd+shift+k=clear_screen")?.modifiers == [.cmd, .shift, .alt, .ctrl])
}

@Test func acceptsModifierAliases() {
    #expect(p("control+a=copy")?.modifiers == [.ctrl])
    #expect(p("opt+a=copy")?.modifiers == [.alt])
    #expect(p("option+a=copy")?.modifiers == [.alt])
}

@Test func parsesNamedKeys() {
    #expect(p("cmd+enter=toggle_zoom")?.key == .enter)
    #expect(p("cmd+return=toggle_zoom")?.key == .enter)
    #expect(p("cmd+left=focus_left")?.key == .left)
    #expect(p("cmd+pageup=previous_tab")?.key == .pageUp)
    #expect(p("cmd+f5=reload_config")?.key == .f(5))
    #expect(p("cmd+f12=reload_config")?.key == .f(12))
    #expect(p("cmd+escape=close_pane")?.key == .escape)
}

@Test func namedKeysAndModifiersAreCaseInsensitive() {
    #expect(p("CMD+Enter=toggle_zoom")?.key == .enter)
    #expect(p("Cmd+T=new_tab")?.key == .char("t"))
}

@Test func parsesPunctuationKeys() {
    #expect(p("cmd+,=open_config")?.key == .char(","))
    #expect(p("cmd+=+=font_bigger") == nil)   // ambiguous, must be rejected rather than guessed
    #expect(p("cmd+minus=font_smaller") == nil)
}

@Test func rejectsMalformedBindings() {
    #expect(p("") == nil)
    #expect(p("cmd+t") == nil)                 // no action
    #expect(p("=new_tab") == nil)              // no key
    #expect(p("cmd+t=not_an_action") == nil)
    #expect(p("bogus+t=new_tab") == nil)       // unknown modifier
    #expect(p("cmd+nosuchkey=new_tab") == nil)
    #expect(p("cmd+f13=new_tab") == nil)
}

@Test func everyActionNameRoundTrips() {
    for action in TerminalAction.allCases {
        #expect(p("cmd+t=\(action.rawValue)")?.action == action)
    }
}

@Test func theDefaultsCoverTheSpecTable() {
    let d = KeyBinding.defaults
    func has(_ mods: KeyModifiers, _ key: Key, _ action: TerminalAction) -> Bool {
        d.contains { $0.modifiers == mods && $0.key == key && $0.action == action }
    }
    #expect(has([.cmd], .char("t"), .newTab))
    #expect(has([.cmd], .char("w"), .closePane))
    #expect(has([.cmd], .char("d"), .splitRight))
    #expect(has([.cmd, .shift], .char("d"), .splitDown))
    #expect(has([.cmd, .alt], .left, .focusLeft))
    #expect(has([.cmd, .ctrl], .right, .growRight))
    #expect(has([.cmd, .shift], .enter, .toggleZoom))
    #expect(has([.cmd], .char("k"), .clearScreen))
    #expect(has([.cmd], .char(","), .openConfig))
    #expect(has([.cmd], .char("1"), .tab1))
    #expect(has([.cmd], .char("9"), .tab9))
}

@Test func noTwoDefaultsShareAChord() {
    var seen = Set<String>()
    for b in KeyBinding.defaults {
        let chord = "\(b.modifiers.rawValue):\(b.key)"
        #expect(!seen.contains(chord), "duplicate default binding for \(chord)")
        seen.insert(chord)
    }
}

@Test func configCollectsKeybinds() {
    let (c, d) = ConfigParser.parse("keybind = cmd+t=new_tab\nkeybind = cmd+w=close_pane")
    #expect(d.isEmpty)
    #expect(c.keybinds.count == 2)
    #expect(c.keybinds[0].action == .newTab)
}

@Test func abadKeybindIsADiagnostic() {
    let (c, d) = ConfigParser.parse("keybind = cmd+t=nonsense")
    #expect(c.keybinds.isEmpty)
    #expect(d.count == 1 && d[0].line == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter KeyBinding 2>&1 | tail -5`
Expected: compile error, `cannot find 'KeyBinding' in scope`.

- [ ] **Step 3: Add `Hashable` to `Key` and write `KeyBinding.swift`**

`Key` is an enum with an associated `Unicode.Scalar` and `Int`; adding `Hashable` is a one-word change. Write the parser: split on the *last* `=` to separate the chord from the action (so `cmd+,=open_config` works), then split the chord on `+`. The final component is the key; everything before it is modifiers. Reject a chord whose key part is empty or has more than one character and is not a known name — that is what makes `cmd+=+=font_bigger` fail rather than guess.

`KeyBinding.defaults` transcribes the spec §6.2 table. `⌘+` and `⌘-` for font size stay menu-only (they are `NSMenuItem` key equivalents, and the `+`/`-` chord is exactly the ambiguous case above), so the defaults list omits `fontBigger`/`fontSmaller`/`fontReset`; the menu supplies them. Note that in the test.

- [ ] **Step 4: Wire `keybind` through `ConfigParser`**

The `keybind` case parses each value with `KeyBinding.parse` and appends to `config.keybinds`, adding a diagnostic when it returns nil. User bindings come after the defaults so a later duplicate overrides an earlier one; the lookup in Task 12 searches from the end.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "KeyBinding|Config" 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Config Sources/NyxCore/Keys/KeyEncoder.swift Tests/NyxCoreTests/KeyBindingTests.swift
git commit -m "feat(core): key binding syntax and the terminal action list"
```

---

### Task 9: Built-in themes

**Files:**
- Create: `Sources/NyxCore/Config/Themes.swift`
- Delete: `Sources/NyxApp/Theme.swift` (its one palette moves into `Themes`)
- Test: `Tests/NyxCoreTests/ThemesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum Themes {
      /// Every built-in theme, by name.
      public static let builtin: [String: Palette]
      /// Looks up a theme, falling back to `nyx-dark` when the name is unknown.
      public static func palette(named: String) -> Palette
      /// Parses a theme file: the same `key = value` grammar as the config, with keys
      /// `palette`, `foreground`, `background`, `cursor`, `selection`, `selection-foreground`.
      public static func parse(_ text: String) -> Palette?
  }
  ```
  Built-in names from the spec: `nyx-dark`, `nyx-light`, `solarized-dark`, `gruvbox-dark`, `dracula`, `catppuccin-mocha`, `one-dark`.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/ThemesTests.swift`:
```swift
import Testing
@testable import NyxCore

@Test func everySpecifiedThemeExists() {
    for name in ["nyx-dark", "nyx-light", "solarized-dark", "gruvbox-dark", "dracula", "catppuccin-mocha", "one-dark"] {
        #expect(Themes.builtin[name] != nil, "missing theme \(name)")
    }
}

@Test func everyThemeHasAFullPalette() {
    for (name, p) in Themes.builtin {
        #expect(p.colors.count == 256, "\(name) has \(p.colors.count) colours")
    }
}

@Test func everyThemeHasReadableContrast() {
    // A theme whose foreground and background are close is unusable. Compare relative luminance.
    func luminance(_ c: RGB) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }
    for (name, p) in Themes.builtin {
        let a = luminance(p.foreground), b = luminance(p.background)
        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        #expect(ratio > 4.5, "\(name) contrast ratio is \(ratio)")
    }
}

@Test func lightThemesAreActuallyLight() {
    let light = try! #require(Themes.builtin["nyx-light"])
    #expect(Int(light.background.r) + Int(light.background.g) + Int(light.background.b) > 600)
}

@Test func lookupFallsBackToTheDefault() {
    #expect(Themes.palette(named: "no-such-theme") == Themes.palette(named: "nyx-dark"))
}

@Test func parsesAThemeFile() {
    let p = Themes.parse("""
    # my theme
    background = #101010
    foreground = #e0e0e0
    cursor = #ff0000
    selection = #303060
    palette = 1=#ff5555
    palette = 2=#55ff55
    """)
    let theme = try! #require(p)
    #expect(theme.background == RGB(0x10, 0x10, 0x10))
    #expect(theme.foreground == RGB(0xe0, 0xe0, 0xe0))
    #expect(theme.cursor == RGB(255, 0, 0))
    #expect(theme.selectionBackground == RGB(0x30, 0x30, 0x60))
    #expect(theme.colors[1] == RGB(255, 0x55, 0x55))
    #expect(theme.colors[2] == RGB(0x55, 255, 0x55))
}

@Test func aThemeFileWithNoColoursIsRejected() {
    #expect(Themes.parse("# nothing here\n") == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Themes 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Write `Themes.swift`**

Each theme is 16 ANSI colours plus foreground, background, cursor and selection. Use the published palettes for solarized-dark, gruvbox-dark, dracula, catppuccin-mocha and one-dark; `nyx-dark` is the existing Tokyo Night palette moved from `Theme.swift`; `nyx-light` is a light counterpart with the same hues. Verify each against the contrast test rather than trusting transcription — that test exists precisely to catch a mistyped hex.

`Themes.parse` reuses the same line-splitting shape as `ConfigParser`; returning nil when no colour key was recognised is what makes a stray file in the themes directory harmless.

- [ ] **Step 4: Point the app at `Themes`**

Delete `Sources/NyxApp/Theme.swift` and replace its one use in `TerminalView.init` with `Themes.palette(named: "nyx-dark")`. Task 11 replaces that with the configured theme.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter Themes 2>&1 | tail -3 && swift test 2>&1 | tail -2`
Expected: 7 theme tests pass; full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Config/Themes.swift Tests/NyxCoreTests/ThemesTests.swift Sources/NyxApp
git rm Sources/NyxApp/Theme.swift
git commit -m "feat(core): seven built-in themes and theme file parsing"
```

---

### Task 10: Config store — load, watch, republish

**Files:**
- Create: `Sources/NyxApp/ConfigStore.swift`, `Sources/NyxApp/ConfigBanner.swift`
- Test: `Tests/NyxCoreTests/ConfigTests.swift` (extend, for the path resolution and default-file text only)

**Interfaces:**
- Consumes: `Config`, `ConfigParser`, `ConfigDiagnostic`.
- Produces:
  ```swift
  final class ConfigStore {
      /// The current configuration. Replaced atomically on reload; read on the main thread only.
      private(set) var config: Config
      private(set) var diagnostics: [ConfigDiagnostic]
      /// Called on the main thread after every successful or failed reload.
      var onChange: ((Config, [ConfigDiagnostic]) -> Void)?
      init()
      /// `$NYX_CONFIG` if set, else `~/.config/nyx/config`.
      static var path: URL { get }
      /// Writes a commented default file if none exists, then returns the path.
      @discardableResult func createIfMissing() -> URL
      func reload()
      func startWatching()
      func stopWatching()
  }
  ```
  And in `NyxCore`, so the default file text is testable:
  ```swift
  public extension Config {
      /// A commented file listing every setting at its default value, for `⌘,` to create.
      static var defaultFileText: String { get }
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NyxCoreTests/ConfigTests.swift`:
```swift
@Test func theDefaultFileTextParsesBackToTheDefaults() {
    let (c, d) = ConfigParser.parse(Config.defaultFileText)
    #expect(d.isEmpty, "default file has diagnostics: \(d)")
    #expect(c == Config.defaults)
}

@Test func theDefaultFileTextIsFullyCommented() {
    // Every setting line is commented out, so the file documents without overriding. Uncommenting
    // any single line must still parse.
    for line in Config.defaultFileText.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { continue }
        #expect(t.hasPrefix("#"), "uncommented line in the default file: \(t)")
    }
}

@Test func everySettingAppearsInTheDefaultFile() {
    for key in ["font-family", "font-size", "line-height", "theme", "cursor-style", "cursor-blink",
                "scrollback-lines", "padding", "background-opacity", "background-blur", "shell",
                "working-directory", "copy-on-select", "middle-click-paste", "option-as-meta",
                "bell", "confirm-close-process", "clipboard-read", "tab-bar", "window-decorations",
                "word-separators", "open-file-command", "keybind", "palette"] {
        #expect(Config.defaultFileText.contains(key), "default file does not mention \(key)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Config 2>&1 | tail -5`
Expected: `type 'Config' has no member 'defaultFileText'`.

- [ ] **Step 3: Write `Config.defaultFileText`**

A commented file, one section per group, every key present with its default value shown. Because every line is commented, `ConfigParser.parse` of it returns exactly `Config.defaults` with no diagnostics — the first test checks that, which is what stops the file drifting from the code.

- [ ] **Step 4: Write `ConfigStore`**

`path` reads `NYX_CONFIG` from the environment, falling back to `~/.config/nyx/config`. `createIfMissing` creates the directory and writes `Config.defaultFileText`. `reload` reads the file (missing file means defaults, not an error), parses, and replaces `config`/`diagnostics`, then calls `onChange` on the main thread.

Watching: open the *directory* with `open(path, O_EVTONLY)` and a `DispatchSource.makeFileSystemObjectSource` for `.write`, `.rename`, `.delete`, `.extend`. Watch the directory rather than the file because editors replace files by rename, which invalidates a file descriptor watch after the first save. Coalesce with a short debounce (100 ms) so an editor's write-then-rename produces one reload. On `.delete` or `.rename` of the directory itself, re-open the descriptor.

- [ ] **Step 5: Write `ConfigBanner`**

An `NSView` that slides in at the top of a window showing `diagnostics.count` problems and the first message with its line number, plus a button that opens the config file. It disappears on the next clean reload, and is dismissible. Keep it non-blocking: never a modal, never an alert. This is 60 lines of AppKit and has no unit test; its acceptance is Step 7.

- [ ] **Step 6: Wire it into the app**

`AppDelegate` owns one `ConfigStore`, calls `createIfMissing()` and `startWatching()` at launch, and passes the config down when creating windows. `⌘,` runs `createIfMissing()` then opens the file with `NSWorkspace.shared.open`. `⌘⇧,` calls `reload()`.

- [ ] **Step 7: Verify by hand**

1. Launch with no config file: it is created at `~/.config/nyx/config` and the app uses defaults.
2. `⌘,` opens the file in the default editor.
3. Add `font-size = 18`, save: the terminal re-lays out immediately (this only works after Task 11; for now check that `onChange` fires by logging).
4. Add a typo line, save: the banner appears naming the line; the previous settings stay in force.
5. Fix the typo, save: the banner goes away.

- [ ] **Step 8: Run the suite and commit**

```bash
git add Sources/NyxApp/ConfigStore.swift Sources/NyxApp/ConfigBanner.swift \
        Sources/NyxCore/Config/Config.swift Tests/NyxCoreTests/ConfigTests.swift Sources/NyxApp/AppDelegate.swift
git commit -m "feat(app): config file with live reload and a non-blocking error banner"
```

---

### Task 11: Apply the configuration

**Files:**
- Modify: `Sources/NyxApp/TerminalView.swift`, `Sources/NyxApp/TerminalWindowController.swift`
- Test: no unit test; acceptance is Step 4.

**Interfaces:**
- Consumes: `Config`, `Themes`, `ConfigStore`.
- Produces on `TerminalView`: `func apply(_ config: Config)`, which rebuilds whatever changed and leaves the session running. The view keeps its current `Config` and diffs against the new one so applying an unrelated change does not rebuild the font atlas.

What each setting must do when it changes:

| Setting | Effect |
|---|---|
| `font-family`, `font-size`, `line-height`, `font-thicken` | rebuild `FontSet`, `renderer.setFonts`, recompute the grid, resize the session |
| `theme`, `palette` overrides | rebuild the palette, `terminal.palette = ...`, redraw |
| `cursor-style`, `cursor-blink` | update the render frame; DECSCUSR from the application still wins while it is set |
| `scrollback-lines` | applies to new sessions only; note it in the banner text if changed |
| `padding` | recompute the grid and resize |
| `background-opacity`, `background-blur` | window `isOpaque`, `backgroundColor`, and an `NSVisualEffectView` behind the Metal layer when blur > 0 |
| `copy-on-select`, `middle-click-paste`, `word-separators`, `option-as-meta`, `mouse-scroll-alt-screen`, `clipboard-read` | stored and read at the point of use |
| `bell` | `visual` flashes the view briefly, `sound` calls `NSSound.beep()`, `none` does nothing |
| `window-decorations` | window style mask; requires recreating the window, so apply at creation only and note it |

Theme selection: when `darkThemeName`/`lightThemeName` are set, pick by the effective appearance and re-pick on `NSApp.effectiveAppearance` changes (observe `effectiveAppearance` with KVO or handle `viewDidChangeEffectiveAppearance`).

- [ ] **Step 1: Store the config and apply the cheap settings**

Add `private var config: Config` and `func apply(_:)`. Start with the settings that need no rebuild: `copyOnSelect`, `middleClickPaste`, `wordSeparators`, `optionAsMeta`, `mouseScrollAltScreen`, `bell`, `cursorStyle`, `cursorBlink`.

- [ ] **Step 2: Apply font and geometry**

Diff `fontFamily`/`fontSize`/`lineHeight`/`fontThicken`/`padding`; when any changed, rebuild the `FontSet`, call `renderer.setFonts`, recompute the grid and resize the session. Note that `fontSize` is also changed by ⌘+/⌘−; keep the zoom offset separate from the configured size so a reload does not undo a zoom.

- [ ] **Step 3: Apply theme and window appearance**

Resolve the palette from `Themes.palette(named:)` plus `paletteOverrides`, assign it to the terminal under the session lock, and mark dirty. Apply opacity and blur to the window.

- [ ] **Step 4: Verify by hand**

With the app running, edit the config and save after each change; every one must take effect without restarting:
1. `font-family = Menlo` → `font-family = Courier New`: the glyphs change and the grid re-lays out.
2. `font-size = 18`: text grows, the window keeps its pixel size, the shell is told the new grid size (check with `stty size`).
3. `theme = gruvbox-dark`, then `dracula`: colours change immediately, including text already on screen.
4. `padding = 24`: the margin grows and the grid shrinks.
5. `background-opacity = 0.85`: the window goes translucent.
6. `cursor-style = bar`, `cursor-blink = false`.
7. `copy-on-select = true`: selecting copies without ⌘C.
8. `theme = dark:nyx-dark,light:nyx-light`, then toggle macOS appearance: the theme follows.
9. A typo: the banner appears and the previous settings stay.

- [ ] **Step 5: Run the suite and commit**

```bash
git add Sources/NyxApp/TerminalView.swift Sources/NyxApp/TerminalWindowController.swift
git commit -m "feat(app): apply configuration live, including font, theme and geometry"
```

---

### Task 12: Split tree model

**Files:**
- Create: `Sources/NyxCore/Layout/PaneTree.swift`
- Modify: `Package.swift` (add the `NyxAppTests` target is *not* needed — the model lives in `NyxCore`)
- Test: `Tests/NyxCoreTests/PaneTreeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SplitAxis: Equatable { case horizontal, vertical }   // horizontal = side by side

  /// A binary tree of panes. Leaves carry an opaque identifier so the view layer can map them to
  /// its own objects; the model itself knows nothing about views.
  public indirect enum PaneTree: Equatable {
      case leaf(PaneID)
      case split(axis: SplitAxis, ratio: Double, first: PaneTree, second: PaneTree)
  }

  public struct PaneID: Hashable, Equatable {
      public let value: Int
      public init(_ value: Int)
  }

  public extension PaneTree {
      /// Every pane in left-to-right, top-to-bottom order.
      var panes: [PaneID] { get }
      /// Replaces `target` with a split of itself and `new`, along `axis`, `new` second.
      func splitting(_ target: PaneID, axis: SplitAxis, with new: PaneID, ratio: Double) -> PaneTree
      /// Removes `target`; the sibling takes its place. nil when the tree becomes empty.
      func removing(_ target: PaneID) -> PaneTree?
      /// Frames for every pane inside `bounds`, given a divider thickness.
      func layout(in bounds: PaneRect, dividerThickness: Double) -> [PaneID: PaneRect]
      /// The pane to focus when moving `direction` from `from`, or nil at the edge.
      func neighbour(of from: PaneID, direction: FocusDirection, in bounds: PaneRect,
                     dividerThickness: Double) -> PaneID?
      /// Adjusts the ratio of the split that separates `pane` from its neighbour in `direction`.
      func resizing(_ pane: PaneID, direction: FocusDirection, by delta: Double) -> PaneTree
  }

  public enum FocusDirection: Equatable { case left, right, up, down }

  public struct PaneRect: Equatable {
      public var x: Double, y: Double, width: Double, height: Double
      public init(x: Double, y: Double, width: Double, height: Double)
  }
  ```
  `PaneRect` exists so the model stays free of AppKit; the view converts to `NSRect`.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/PaneTreeTests.swift`:
```swift
import Testing
@testable import NyxCore

private func id(_ n: Int) -> PaneID { PaneID(n) }
private let full = PaneRect(x: 0, y: 0, width: 100, height: 100)

@Test func aSingleLeafFillsTheBounds() {
    let t = PaneTree.leaf(id(1))
    #expect(t.panes == [id(1)])
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)] == full)
}

@Test func splittingHorizontallyPutsPanesSideBySide() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.panes == [id(1), id(2)])
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)] == PaneRect(x: 0, y: 0, width: 49, height: 100))
    #expect(l[id(2)] == PaneRect(x: 51, y: 0, width: 49, height: 100))
}

@Test func splittingVerticallyStacksPanes() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .vertical, with: id(2), ratio: 0.5)
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)] == PaneRect(x: 0, y: 0, width: 100, height: 49))
    #expect(l[id(2)] == PaneRect(x: 0, y: 51, width: 100, height: 49))
}

@Test func anUnevenRatioSplitsProportionally() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.25)
    let l = t.layout(in: PaneRect(x: 0, y: 0, width: 102, height: 10), dividerThickness: 2)
    #expect(l[id(1)]?.width == 25)
    #expect(l[id(2)]?.width == 75)
}

@Test func splittingASplitOnlyAffectsTheTargetLeaf() {
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    #expect(t.panes == [id(1), id(2), id(3)])
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)]?.height == 100)
    #expect(l[id(2)]?.height == 49)
    #expect(l[id(3)]?.height == 49)
}

@Test func removingALeafPromotesItsSibling() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.removing(id(2)) == .leaf(id(1)))
    #expect(t.removing(id(1)) == .leaf(id(2)))
}

@Test func removingTheLastLeafEmptiesTheTree() {
    #expect(PaneTree.leaf(id(1)).removing(id(1)) == nil)
}

@Test func removingFromANestedTreeKeepsTheRest() {
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    let after = t.removing(id(3))
    #expect(after?.panes == [id(1), id(2)])
}

@Test func removingAnAbsentPaneChangesNothing() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.removing(id(99)) == t)
}

@Test func focusMovesToTheGeometricNeighbour() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.neighbour(of: id(1), direction: .right, in: full, dividerThickness: 2) == id(2))
    #expect(t.neighbour(of: id(2), direction: .left, in: full, dividerThickness: 2) == id(1))
    #expect(t.neighbour(of: id(1), direction: .left, in: full, dividerThickness: 2) == nil)
    #expect(t.neighbour(of: id(1), direction: .up, in: full, dividerThickness: 2) == nil)
}

@Test func focusCrossesNestedSplits() {
    // 1 on the left; on the right, 2 above 3.
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    #expect(t.neighbour(of: id(2), direction: .down, in: full, dividerThickness: 2) == id(3))
    #expect(t.neighbour(of: id(3), direction: .up, in: full, dividerThickness: 2) == id(2))
    #expect(t.neighbour(of: id(2), direction: .left, in: full, dividerThickness: 2) == id(1))
    #expect(t.neighbour(of: id(3), direction: .left, in: full, dividerThickness: 2) == id(1))
    #expect(t.neighbour(of: id(1), direction: .right, in: full, dividerThickness: 2) != nil)
}

@Test func resizingMovesTheDividerAndKeepsTheTotal() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    let wider = t.resizing(id(1), direction: .right, by: 0.1)
    let l = wider.layout(in: PaneRect(x: 0, y: 0, width: 102, height: 10), dividerThickness: 2)
    #expect(l[id(1)]!.width > 50)
    #expect(l[id(1)]!.width + l[id(2)]!.width == 100)
}

@Test func resizingClampsSoAPaneNeverDisappears() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    var shrunk = t
    for _ in 0..<50 { shrunk = shrunk.resizing(id(1), direction: .left, by: 0.1) }
    let l = shrunk.layout(in: PaneRect(x: 0, y: 0, width: 1000, height: 10), dividerThickness: 2)
    #expect(l[id(1)]!.width > 0)
    #expect(l[id(2)]!.width > 0)
}

@Test func layoutNeverProducesNegativeSizes() {
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .horizontal, with: id(3), ratio: 0.5)
    let l = t.layout(in: PaneRect(x: 0, y: 0, width: 4, height: 4), dividerThickness: 2)
    for (_, r) in l {
        #expect(r.width >= 0 && r.height >= 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PaneTree 2>&1 | tail -5`
Expected: compile error, `cannot find 'PaneTree' in scope`.

- [ ] **Step 3: Write `PaneTree.swift`**

`layout` walks the tree: a split subtracts `dividerThickness` from the axis being divided, gives `ratio` of what remains to `first` and the rest to `second`, and recurses. Round so the two halves plus the divider add back to the parent exactly — the `anUnevenRatioSplitsProportionally` test pins this. Clamp to zero rather than going negative when the bounds are smaller than the dividers.

`neighbour` is geometric rather than structural: lay out the whole tree, take the source rect, and find the pane whose rect is nearest in the requested direction while overlapping on the perpendicular axis. That handles nested splits correctly without special cases, which is why `focusCrossesNestedSplits` passes with no extra code.

`resizing` finds the nearest ancestor split whose axis matches the direction and whose subtree containing `pane` is on the appropriate side, then adjusts its ratio, clamped to `0.05...0.95`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PaneTree 2>&1 | tail -3`
Expected: 14 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Layout/PaneTree.swift Tests/NyxCoreTests/PaneTreeTests.swift
git commit -m "feat(core): split tree model with geometric focus navigation"
```

---

### Task 13: Panes and splits in the window

**Files:**
- Rename: `Sources/NyxApp/TerminalView.swift` → `Sources/NyxApp/Pane.swift` (class `TerminalView` → `Pane`)
- Create: `Sources/NyxApp/PaneTreeView.swift`
- Modify: `Sources/NyxApp/TerminalWindowController.swift`, `Sources/NyxApp/MainMenu.swift`
- Test: acceptance in Step 5.

**Interfaces:**
- Consumes: `PaneTree`, `PaneID`, `PaneRect`, `SplitAxis`, `FocusDirection`, `Config`.
- Produces:
  ```swift
  final class PaneTreeView: NSView {
      init(config: Config, makePane: @escaping () -> Pane?)
      private(set) var focused: PaneID?
      var onAllPanesClosed: (() -> Void)?
      var onFocusedTitleChange: ((String) -> Void)?
      func split(axis: SplitAxis)
      func closeFocusedPane()
      func moveFocus(_ direction: FocusDirection)
      func resizeFocused(_ direction: FocusDirection)
      func toggleZoom()
      func apply(_ config: Config)
      var focusedPane: Pane? { get }
  }
  ```

Behaviour:
- The view owns `tree: PaneTree`, a `[PaneID: Pane]` map, and the divider rects from the last layout. `layout()` asks the model for frames and assigns them, converting `PaneRect` to `NSRect`.
- Dividers are 1 pt lines drawn in the theme's foreground at 20% alpha, with a 6 pt hit area. Dragging one adjusts the containing split's ratio live. Set the cursor to `resizeLeftRight`/`resizeUpDown` over a divider via `resetCursorRects`.
- The focused pane draws a 1 pt border in the theme's cursor colour. Clicking a pane focuses it. `window.makeFirstResponder` follows focus.
- New panes inherit the focused pane's working directory. Get it from the terminal's `cwd` (set by OSC 7); when that is nil, fall back to reading the foreground process's cwd with `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, ...)`. Both are best-effort; fall back to `$HOME`.
- Zoom (`⌘⇧⏎`) makes the focused pane fill the whole tree view, keeping the tree intact; toggling restores it.
- Closing the last pane calls `onAllPanesClosed`, which the window controller turns into closing the window.
- When a pane's process exits, close that pane the same way `⌘W` would.
- `apply(_:)` forwards the config to every pane and re-reads the divider colour.

- [ ] **Step 1: Rename the view to `Pane`**

Pure rename plus the `PaneID` it now carries. Nothing else changes. Verify the app still builds and runs with one pane.

- [ ] **Step 2: Build `PaneTreeView` with layout and focus**

Splitting, closing, focus movement, focus border, click-to-focus. No dividers yet.

- [ ] **Step 3: Dividers**

Draw them, hit-test them, drag them, set the cursor over them.

- [ ] **Step 4: Zoom, cwd inheritance and process exit**

- [ ] **Step 5: Verify by hand**

1. `⌘D` splits right; `⌘⇧D` splits down; both new panes get a working shell.
2. `cd /tmp` then `⌘D`: the new pane starts in `/tmp`.
3. `⌘⌥←→↑↓` moves focus; the focused pane's border follows.
4. Drag a divider: both panes resize live and their shells learn the new size (`stty size` in each).
5. `⌘⌃←→↑↓` resizes by keyboard.
6. `⌘⇧⏎` zooms the focused pane and restores it.
7. `exit` in one pane closes just that pane; the sibling takes the space.
8. `exit` in the last pane closes the window.
9. Split four ways and run `vim` in one: it redraws correctly at its own size.

- [ ] **Step 6: Run the suite and commit**

```bash
git add Sources/NyxApp Tests
git commit -m "feat(app): splits with draggable dividers, focus movement and zoom"
```

---

### Task 14: Tabs

**Files:**
- Create: `Sources/NyxApp/TabController.swift`, `Sources/NyxApp/TabBarView.swift`
- Modify: `Sources/NyxApp/TerminalWindowController.swift`, `Sources/NyxApp/MainMenu.swift`
- Test: acceptance in Step 4.

**Interfaces:**
- Consumes: `PaneTreeView`, `Config`, `TabBarVisibility`.
- Produces:
  ```swift
  final class TabController: NSViewController {
      init(config: Config)
      func newTab()
      func closeCurrentPane()
      func selectTab(at index: Int)
      func nextTab()
      func previousTab()
      func apply(_ config: Config)
      var onAllTabsClosed: (() -> Void)?
      var onTitleChange: ((String) -> Void)?
      var focusedPane: Pane? { get }
  }
  ```

Behaviour:
- One `PaneTreeView` per tab, all in a container; only the selected one is in the hierarchy.
- The tab bar sits above the panes, is 28 pt tall, and follows `config.tabBar`: `auto` hides it with one tab, `always` keeps it, `never` hides it.
- A tab's title is the focused pane's title (OSC 0/2), or the foreground process name plus the last path component of its cwd. Truncate in the middle.
- An unselected tab that produced output shows a dot; a bell shows a bell glyph. Both clear on selection.
- Clicking selects; ⌘1…⌘9 select by index with ⌘9 meaning the last tab; ⌘⇧] / ⌘⇧[ cycle.
- New tabs inherit the focused pane's cwd, same rule as new panes.
- `⌘W` closes the focused pane; when it was the tab's last pane the tab closes; when that was the last tab the window closes.
- Closing a pane whose process has live children other than the shell asks for confirmation when `config.confirmCloseProcess` is on. Detect with `proc_listchildpids`.

- [ ] **Step 1: Tab model, container and switching**

- [ ] **Step 2: Tab bar view with titles, close buttons and indicators**

- [ ] **Step 3: Close confirmation**

- [ ] **Step 4: Verify by hand**

1. `⌘T` opens a tab; the bar appears; `⌘W` closes it and the bar hides again at one tab.
2. `⌘1`…`⌘9` and `⌘⇧]`/`⌘⇧[` switch tabs.
3. A background tab running `while true; do date; sleep 1; done` shows the activity dot; selecting it clears it.
4. `printf '\a'` in a background tab shows the bell indicator.
5. The tab title follows `cd` and the running program.
6. `tab-bar = always` and `never` in the config take effect on save.
7. Run `sleep 100` in a pane and press `⌘W`: it asks before closing. Set `confirm-close-process = false`: it closes without asking.
8. Tabs and splits together: split a tab, switch away and back, the split layout is intact and the focused pane keeps focus.

- [ ] **Step 5: Run the suite and commit**

```bash
git add Sources/NyxApp
git commit -m "feat(app): tabs with a compact tab bar, activity indicators and close confirmation"
```

---

### Task 15: Actions, key bindings and the menu

**Files:**
- Create: `Sources/NyxApp/Actions.swift`
- Modify: `Sources/NyxApp/MainMenu.swift`, `Sources/NyxApp/Pane.swift`, `Sources/NyxApp/AppDelegate.swift`
- Test: acceptance in Step 4.

**Interfaces:**
- Consumes: `TerminalAction`, `KeyBinding`, `Config.keybinds`.
- Produces:
  ```swift
  /// One place that turns a TerminalAction into an effect, used by both the menu and key bindings.
  protocol ActionTarget: AnyObject {
      func perform(_ action: TerminalAction)
      func canPerform(_ action: TerminalAction) -> Bool
  }
  ```

Behaviour:
- `Pane.keyDown` first asks the window's binding table whether the chord matches a `TerminalAction`; if so it performs it and does not send bytes to the shell. Otherwise the existing `KeyEncoder` path runs.
- The binding table is `KeyBinding.defaults` followed by `config.keybinds`, searched from the end so a user binding wins.
- The menu is built from the same `TerminalAction` list so every action is discoverable, with key equivalents shown from the active bindings. Actions with no binding still appear.
- `NSMenuItem` validation goes through `canPerform`, so "Close Pane" greys out when there is nothing to close.

- [ ] **Step 1: Define `ActionTarget` and route every existing action through it**

- [ ] **Step 2: Binding lookup in `Pane.keyDown`**

- [ ] **Step 3: Rebuild the menu from actions, with key equivalents from the bindings**

- [ ] **Step 4: Verify by hand**

1. Every action in the menu works from the menu.
2. Every default binding from spec §6.2 works from the keyboard.
3. Add `keybind = cmd+shift+t=new_tab` to the config, save, and it works without restart.
4. Rebind an existing chord (`keybind = cmd+d=new_tab`) and the new meaning wins.
5. A key with no binding still reaches the shell: `⌘K` clears, but plain `k` types `k`.
6. Menu items grey out when they cannot apply.

- [ ] **Step 5: Run the full suite, the snapshot test, bench, and commit**

Run:
```bash
swift test 2>&1 | tail -2
NYX_SNAPSHOT=1 swift test --filter Snapshot 2>&1 | tail -2
make bench
swift build -c release 2>&1 | grep -ci warning
```
Expected: all tests green, snapshot green, benchmark at or above 180 MB/s, zero warnings.

```bash
git add Sources/NyxApp
git commit -m "feat(app): one action list driving both the menu and configurable key bindings"
```

---

### Task 16: Update the docs and the manual checklist

**Files:**
- Modify: `README.md`, `docs/checklist.md`, `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md`

- [ ] **Step 1: README**

Describe what phase 2A added: selection and copy, mouse in TUI programs, tabs, splits, the config file with live reload, seven themes. Show the config path and one example. Keep it short — the config file documents itself.

- [ ] **Step 2: Checklist**

Add a phase-2A section with the acceptance checks from Tasks 6, 11, 13, 14 and 15, condensed to one line each.

- [ ] **Step 3: Spec**

Tick off what phase 2A delivered in §11 and leave §6.3, §6.4, §6.6 and §6.7 marked as phase 2B. Record anything this plan deliberately did not do.

- [ ] **Step 4: Commit**

```bash
git add README.md docs
git commit -m "docs: record what phase 2A shipped"
```

---

## Self-review notes

**Spec coverage.** §6.1 mouse and copy/paste: Tasks 5, 6. §6.1 cursor from config: Task 11. §6.2 windows, tabs, splits, the keybinding table: Tasks 12, 13, 14, 15. §6.5 config file, live reload, error banner, `⌘,`, every phase-2 key, themes including the dark/light pair: Tasks 7, 8, 9, 10, 11. The three latent items from §11: Task 1.

**Deliberately out of scope, and why.** §6.3 search, §6.4 links and paths, §6.6 shell integration, §6.7 sessions — these are phase 2B. Each is independently useful and none of them blocks daily use, whereas everything in this plan does. Splitting keeps this plan executable and reviewable; a 25-task plan would not be.

**Known ordering constraint.** Task 6 hard-codes `copyOnSelect` and `middleClickPaste` because the config does not exist until Task 7. Task 11 replaces those constants. This is called out in both tasks so a reviewer does not flag it as a defect in Task 6.

**Type consistency check.** `Selection`, `AbsolutePosition`, `SelectionMode` are produced by Task 2 and consumed by Tasks 3, 4 and 6 under the same names. `RenderFrame.selection` is `[Range<Int>?]` in Tasks 4 and 6. `Config` field names in Task 7 match their uses in Tasks 10, 11, 13 and 14. `TerminalAction` cases in Task 8 match the menu and bindings in Task 15. `PaneTree`, `PaneID`, `PaneRect`, `SplitAxis`, `FocusDirection` are produced by Task 12 and consumed by Task 13 under the same names.

**Test-count arithmetic.** Phase 1 ends at 167. This plan adds 9 (Task 2) + 13 (Task 3) + 5 (Task 4) + 12 (Task 5) + 16 (Task 7) + 12 (Task 8) + 7 (Task 9) + 3 (Task 10) + 14 (Task 12) = 91, so the suite should finish at 258. A task that ends with a different total than its own additions predict has broken something.
