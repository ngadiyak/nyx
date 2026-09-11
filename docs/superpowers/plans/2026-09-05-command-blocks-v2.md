# Command Blocks v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a command block something a person can see and act on: a chevron and summary on the command row, a hover header with buttons, tail folds keyed by a stable command id, a live timer and an armed notification for a running command, copy-as-Markdown, and blocks that survive a relaunch.

**Architecture:** Every decision is a value type in `NyxCore` with tests (`Row.commandID`, `OutputFolding` keyed by id, `BlockHeader`, `BlockHover`, `BlockExport`, `CommandNotificationRule`). `NyxRender` gains one chrome input (`highlightedRows`) and one more glyph in the summary. `NyxApp` converts hover and clicks, places a `BlockHeaderView` overlay over the hovered block's command row the way `StickyPromptView` sits over the top row, and drives a 1 Hz timer only while a command runs.

**Tech Stack:** Swift 6.0.3 in Swift 5 language mode, SwiftPM only, swift-testing (`import Testing`, `@Test`, `#expect`; no XCTest), AppKit, Metal, macOS 14.

**Spec:** `docs/superpowers/specs/2026-09-05-command-blocks-v2-design.md`

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY; never AppKit, Metal, CoreText, QuartzCore. `NyxRender` never imports CNyxPTY.
- Tests are swift-testing only. A **mutating** call inside `#expect`/`#require` does not compile: hoist it to a local first (see `CLAUDE.md`).
- `swift test` may hang in `swiftpm-testing-helper` before any test runs. Kill and re-run in the foreground: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`. Never wait on a background test run.
- Warning-free build: `swift build 2>&1 | grep -c warning:` must print `0`.
- `make bench` at or above 180 MB/s (run three times; ±3 is noise).
- Anything `Renderer.buildRow` reads must be in `RowKey` or `FrameKey`, or be drawn in `buildChrome` outside the row cache (`.claude/skills/nyx-rendering/SKILL.md`).
- A new config key touches every row of the table in `.claude/skills/nyx-config-keys/SKILL.md`; a new action touches `TerminalAction`, `ActionCatalog.sections`, `KeyBinding.defaults` (if bound), `TabController.perform` and `canPerform`, and `docs/configuration.md`.
- Every drawn control is an accessibility element (`Accessibility.swift`); every new piece of chrome gets a `UISnapshot` case per state in the same commit.
- Nothing is "done" until the ladder in `docs/testing.md` has run, the PNGs were looked at, the AppKit edge was driven through a temporary env-var hook that is then removed, and the `product-manager` agent has said APPROVED.
- Commit messages: a plain sentence title, a body with why and the verification figures, ending with the attribution trailer the session prescribes. `git add` by name; never `git add -A`.
- Branch: `feat/blocks-v2` off `main`. Working-tree files that are not part of this plan (`docs/*.md`, `.claude/`, `README.md`, `CLAUDE.md` changes already present) are left alone and not swept into commits.

---

## File map

| File | Responsibility | Tasks |
|---|---|---|
| `Sources/NyxCore/Terminal/Row.swift` | `commandID` field, cleared on reset | 1 |
| `Sources/NyxCore/Terminal/Terminal.swift` | id counter, stamp on `A`, `runningCommand`, `oldestCommandID`, `promptRow(ofCommand:)` | 1 |
| `Sources/NyxCore/Terminal/Terminal+Resize.swift` | carry `commandID` through reflow | 1 |
| `Sources/NyxCore/Shell/PromptMarks.swift` | `CommandRegion.id`, `outputText(of:)` | 1, 4 |
| `Sources/NyxCore/Shell/OutputFolding.swift` | `FoldShape`, id-keyed folds, tail display rows, auto-fold | 2 |
| `Sources/NyxCore/Config/*` | `fold-keep-lines`, `fold-long-output`, actions, chord | 3, 8 |
| `Sources/NyxCore/Shell/CommandBlock.swift` | `BlockHeader`, `BlockAction`, `BlockHover` | 4 |
| `Sources/NyxCore/Shell/BlockExport.swift` (new) | Markdown export | 4 |
| `Sources/NyxCore/Terminal/Color.swift` | `Palette.blockHoverBackground` | 5 |
| `Sources/NyxRender/Renderer.swift` | `highlightedRows`, chrome tint | 5 |
| `Sources/NyxCore/Shell/CommandWatcher.swift` | `FinishedCommand.id`, `CommandNotificationRule` | 6 |
| `Sources/NyxCore/Session/Transcript.swift` | OSC 133 marks in the transcript | 7 |
| `Sources/NyxApp/Pane.swift` | hover, chevron target, tint, timer, auto-fold, arming, actions | 9 |
| `Sources/NyxApp/BlockHeaderView.swift` (new) | the overlay with buttons and the ⋯ menu | 10 |
| `Sources/NyxApp/StickyPromptView.swift`, `UISnapshot.swift`, `SettingsWindowController.swift`, `TabController.swift` | summary on the strip, snapshot cases, settings rows, `perform` | 3, 8, 10 |
| `docs/*.md`, `README.md`, spec §11 | documentation | 11 |

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/nik/projects/nyx
git checkout -b feat/blocks-v2 main
```

- [ ] **Step 2: Confirm the baseline is green**

Run: `swift build 2>&1 | grep -c warning:` → expected `0`.
Run: `swift test --no-parallel 2>&1 | tail -3` → expected a line like `✔ Test run with 1002 tests passed`. Write the count down; the final report quotes it.

---

### Task 1: A stable id for every command

**Files:**
- Modify: `Sources/NyxCore/Terminal/Row.swift` (fields at lines 19–39, `reset` at 65–69)
- Modify: `Sources/NyxCore/Terminal/Terminal.swift` (stored properties near line 104; `case 133:` near line 1161; helpers near `recordCommandDuration`, line 1282)
- Modify: `Sources/NyxCore/Terminal/Terminal+Resize.swift` (`struct Line` line 83; carry at 96–99; restore at 127–130)
- Modify: `Sources/NyxCore/Shell/PromptMarks.swift` (`CommandRegion` line 31; `command(containingAbsoluteRow:)` line 128)
- Test: `Tests/NyxCoreTests/CommandIDTests.swift` (new)

**Interfaces:**
- Produces: `Row.commandID: UInt32` (0 = no command); `CommandRegion.id: UInt32`; `Terminal.runningCommand: (id: UInt32, startedAt: Double)?`; `Terminal.oldestCommandID: UInt32` (0 when the buffer has no prompt); `Terminal.promptRow(ofCommand id: UInt32) -> Int?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NyxCoreTests/CommandIDTests.swift
import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

/// Two finished commands and a prompt being typed at:
///   0 $ echo one   1 one   2 $ false   3 $ (typing)
private func session() -> Terminal {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "false\r\n" + mark("C") + mark("D", 1))
    t.feed(mark("A") + "$ ")
    return t
}

@Test func everyPromptGetsItsOwnIncreasingID() {
    let t = session()
    let ids = [0, 2, 3].map { t.absoluteRow($0)!.commandID }
    #expect(ids == [1, 2, 3])
    #expect(t.absoluteRow(1)!.commandID == 0)   // output rows carry none
}

@Test func theRegionCarriesItsPromptID() {
    let t = session()
    #expect(t.command(containingAbsoluteRow: 1)?.id == 1)
    #expect(t.command(containingAbsoluteRow: 2)?.id == 2)
}

/// A prompt redrawn on the same row -- zsh after a resize, or after `^L` -- is the same command.
@Test func aSecondAOnTheSameRowKeepsTheID() {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "\r" + mark("A") + "$ " + mark("B"))
    #expect(t.absoluteRow(0)!.commandID == 1)
    t.feed("x\r\n" + mark("A") + "$ ")
    #expect(t.absoluteRow(1)!.commandID == 2)
}

@Test func theIDSurvivesReflow() {
    let t = session()
    t.resize(cols: 8, rows: 6)
    let ids = (0..<t.totalRows).compactMap { row -> UInt32? in
        let id = t.absoluteRow(row)!.commandID
        return id == 0 ? nil : id
    }
    #expect(ids == [1, 2, 3])
}

@Test func theRunningCommandIsKnownWhileItRuns() {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    var clock = 5.0
    t.now = { clock }
    t.feed(mark("A") + "$ " + mark("B") + "sleep\r\n")
    #expect(t.runningCommand == nil)          // typed, not yet running
    t.feed(mark("C"))
    #expect(t.runningCommand?.id == 1)
    #expect(t.runningCommand?.startedAt == 5.0)
    clock = 7
    t.feed(mark("D", 0) + mark("A") + "$ ")
    #expect(t.runningCommand == nil)
}

@Test func theOldestIDFollowsTheRing() {
    let t = makeTerminal(cols: 20, rows: 3, scrollback: 4)
    for i in 1...6 {
        t.feed(mark("A") + "$ " + mark("B") + "c\(i)\r\n" + mark("C") + "out\r\n" + mark("D", 0))
    }
    t.feed(mark("A") + "$ ")
    // Seven prompts, two rows each, in a buffer of 4 + 3 rows: the first ones are gone.
    #expect(t.oldestCommandID > 1)
    #expect(t.oldestCommandID <= 7)
    #expect(t.absoluteRow(t.promptRow(ofCommand: t.oldestCommandID)!)!.commandID == t.oldestCommandID)
    #expect(t.promptRow(ofCommand: 1) == nil)
}

@Test func anEmptyBufferHasNoOldestCommand() {
    #expect(makeTerminal().oldestCommandID == 0)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter CommandID 2>&1 | grep -E 'error|failed' | head`
Expected: compile errors, `value of type 'Row' has no member 'commandID'`.

- [ ] **Step 3: Add the field and the counter**

In `Row.swift`, after `exitStatus` (line 39):

```swift
    /// Which command this prompt row starts, numbered from 1 in the order prompts appeared; 0 on
    /// every other row. Absolute row indices shift on every eviction once the scrollback ring is
    /// full, so a fold or a pending notification keyed by row would drift onto whatever text moved
    /// into that index. The id is the thing that stays put. Monotonic on purpose: "is this command
    /// still in the buffer" is then a comparison against the oldest id, not a search.
    public var commandID: UInt32 = 0
```

and in `reset(cols:fill:)` add `commandID = 0` after `commandDuration = nil`.

In `Terminal.swift`, next to `commandStartedAt` (line 104):

```swift
    /// The id the next `OSC 133 ; A` will stamp on its row. See `Row.commandID`.
    private var nextCommandID: UInt32 = 1
    /// The id of the command whose `C` mark has arrived and whose `D` has not, with the clock
    /// reading when it started. nil at a prompt, and after `D`.
    public private(set) var runningCommand: (id: UInt32, startedAt: Double)?
```

In `case 133:` after `screen.rows[screen.cursor.y].promptMark |= mark`:

```swift
            if mark == 1 && screen.rows[screen.cursor.y].commandID == 0 {
                screen.rows[screen.cursor.y].commandID = nextCommandID
                nextCommandID &+= 1
            }
```

Replace `if mark == 4 { commandStartedAt = now() }` with:

```swift
            if mark == 4 {
                commandStartedAt = now()
                var owner: UInt32 = 0
                withOwningPromptRow { row in owner = self.absoluteRow(row)?.commandID ?? 0 }
                // The `C` normally lands on the row after the command line, but a command that
                // prints nothing before its prompt returns can put it on the prompt row itself.
                if owner == 0 { owner = screen.rows[screen.cursor.y].commandID }
                runningCommand = owner == 0 ? nil : (owner, commandStartedAt!)
            }
```

and inside the `if mark == 8 {` block, as its last statement (after the `if let started { ... }` block, not inside it): `runningCommand = nil`.

Add the two lookups after `recordCommandStatus`:

```swift
    /// The id on the first prompt in the buffer, or 0 when there is none. Walks from row 0 to the
    /// first prompt, which is bounded by one command's output and is asked only when there are
    /// folds or armed notifications to prune.
    public var oldestCommandID: UInt32 {
        for row in 0..<totalRows {
            if let id = absoluteRow(row)?.commandID, id != 0 { return id }
        }
        return 0
    }

    /// The absolute row of the prompt carrying `id`, or nil once it has left the buffer. Visible
    /// rows first: a click or a menu item almost always names a command on screen.
    public func promptRow(ofCommand id: UInt32) -> Int? {
        guard id != 0 else { return nil }
        let top = max(0, viewportTopRow)
        for row in top..<min(totalRows, top + rows) where absoluteRow(row)?.commandID == id { return row }
        for row in stride(from: totalRows - 1, through: 0, by: -1) where absoluteRow(row)?.commandID == id {
            return row
        }
        return nil
    }
```

In the reset path (line 675, where `shellEmitsPromptMarks = false`) add `runningCommand = nil`.

- [ ] **Step 4: Carry the id through reflow**

In `Terminal+Resize.swift`: add `var commandID: UInt32` to `struct Line`; declare `var currentCommandID: UInt32 = 0` beside `currentMark`; in the accumulation loop add `if currentCommandID == 0 { currentCommandID = row.commandID }`; pass `commandID: currentCommandID` into `Line(...)` and reset `currentCommandID = 0` with the others; on rebuild set `row.commandID = line.commandID` beside `row.promptMark = line.mark`. If the file rewraps a `Line` across several physical rows, put the id on the **first** of them only, next to where `promptMark` is placed.

- [ ] **Step 5: Put the id on the region**

In `PromptMarks.swift`: add `public let id: UInt32` to `CommandRegion` after `promptRow`, with `id: UInt32 = 0` as a defaulted initializer parameter **placed last** so existing call sites compile. In `command(containingAbsoluteRow:)` pass `id: absoluteRow(start)?.commandID ?? 0`.

- [ ] **Step 6: Run the tests**

Run: `swift test --no-parallel --filter CommandID 2>&1 | tail -3`
Expected: `7 tests passed`.
Run: `swift test --no-parallel 2>&1 | tail -3` → everything still green.
Run: `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/NyxCore/Terminal/Row.swift Sources/NyxCore/Terminal/Terminal.swift \
        Sources/NyxCore/Terminal/Terminal+Resize.swift Sources/NyxCore/Shell/PromptMarks.swift \
        Tests/NyxCoreTests/CommandIDTests.swift
git commit -m "Give every command an id that outlives its row number"
```

---

### Task 2: Folding by id, keeping the tail

**Files:**
- Rewrite: `Sources/NyxCore/Shell/OutputFolding.swift`
- Modify: `Sources/NyxApp/Pane.swift` — every caller listed below, so the build stays green
- Modify: `Tests/NyxCoreTests/StickyPromptTests.swift` (lines 79–101 use `fold(promptRow:)` and `.fold(2, …)`)
- Modify: `Tests/NyxCoreTests/ScrollbackTrimTests.swift:199` (`folding.prune(in: t)`)
- Rewrite: `Tests/NyxCoreTests/OutputFoldingViewportTests.swift`
- Create: `Tests/NyxCoreTests/OutputFoldingTests.swift`

**Interfaces:**
- Consumes: `Row.commandID`, `CommandRegion.id`, `Terminal.oldestCommandID` (Task 1).
- Produces:

```swift
public enum FoldShape: Equatable { case tail(keep: Int); case all }
public enum DisplayRow: Equatable { case row(Int); case fold(commandID: UInt32, hiddenRows: Int) }
public struct OutputFolding: Equatable {
    public init()
    public var isEmpty: Bool
    public func shape(of id: UInt32) -> FoldShape?
    public func isFolded(_ id: UInt32) -> Bool
    public mutating func fold(_ id: UInt32, _ shape: FoldShape)
    public mutating func unfold(_ id: UInt32)
    public mutating func unfoldAll()
    public mutating func toggle(_ id: UInt32, keep: Int)
    public mutating func toggleFull(_ id: UInt32)
    public mutating func prune(olderThan oldest: UInt32)
    @discardableResult public mutating func autoFold(_ region: CommandRegion, longerThan threshold: Int, keep: Int) -> Bool
    public mutating func foldLongOutput(in terminal: Terminal, longerThan threshold: Int, keep: Int)
    public static func effectiveShape(_ shape: FoldShape, outputRows: Int) -> FoldShape
    public static func hiddenRange(of region: CommandRegion, shape: FoldShape) -> Range<Int>
    public static func placeholder(hiddenRows: Int) -> String   // "▸ … 1,231 lines hidden"
}
extension Terminal {
    func displayRows(from top: Int, count: Int, folding: OutputFolding) -> [DisplayRow]
    func displayRows(in range: Range<Int>, folding: OutputFolding) -> [DisplayRow]
    func foldedCommand(containingOutputRow row: Int, folding: OutputFolding) -> (region: CommandRegion, hidden: Range<Int>)?
    @discardableResult func snapViewportOutOfFold(movingUp: Bool, folding: OutputFolding) -> Bool
    func foldPlaceholderRow(hiddenRows: Int) -> Row
}
```

- [ ] **Step 1: Write the failing tests for the pure rules**

```swift
// Tests/NyxCoreTests/OutputFoldingTests.swift
import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

private func region(output: Int, id: UInt32 = 7) -> CommandRegion {
    CommandRegion(promptRow: 10, outputStart: output == 0 ? nil : 11, endRow: 10 + output,
                  exitStatus: 0, duration: 1, id: id)
}

@Test func aTailFoldHidesEverythingButTheLastLines() {
    let hidden = OutputFolding.hiddenRange(of: region(output: 10), shape: .tail(keep: 3))
    #expect(hidden == 11..<18)          // rows 18, 19, 20 stay visible
}

@Test func aFullFoldHidesAllOfTheOutput() {
    #expect(OutputFolding.hiddenRange(of: region(output: 10), shape: .all) == 11..<21)
}

/// Hiding one line behind a one-line placeholder is a net loss, so a short output folds fully.
@Test func outputTooShortForATailFoldsFully() {
    #expect(OutputFolding.effectiveShape(.tail(keep: 3), outputRows: 4) == .all)
    #expect(OutputFolding.effectiveShape(.tail(keep: 3), outputRows: 5) == .tail(keep: 3))
    #expect(OutputFolding.effectiveShape(.tail(keep: 0), outputRows: 50) == .all)
}

@Test func toggleGoesOpenTailOpen() {
    var f = OutputFolding()
    f.toggle(7, keep: 3)
    #expect(f.shape(of: 7) == .tail(keep: 3))
    f.toggle(7, keep: 3)
    #expect(f.shape(of: 7) == nil)
}

@Test func toggleFullGoesOpenAllOpenAndOverridesATail() {
    var f = OutputFolding()
    f.fold(7, .tail(keep: 3))
    f.toggleFull(7)
    #expect(f.shape(of: 7) == .all)
    f.toggleFull(7)
    #expect(f.shape(of: 7) == nil)
}

@Test func pruneDropsCommandsOlderThanTheOldestInTheBuffer() {
    var f = OutputFolding()
    f.fold(3, .all)
    f.fold(9, .all)
    f.prune(olderThan: 5)
    #expect(!f.isFolded(3))
    #expect(f.isFolded(9))
}

@Test func autoFoldFoldsLongOutputAndLeavesShortAlone() {
    var f = OutputFolding()
    let folded = f.autoFold(region(output: 300), longerThan: 200, keep: 3)
    #expect(folded)
    #expect(f.shape(of: 7) == .tail(keep: 3))
    let short = f.autoFold(region(output: 10, id: 8), longerThan: 200, keep: 3)
    #expect(!short)
    #expect(f.shape(of: 8) == nil)
}

/// A block the user opened by hand stays open: refolding it would be the terminal arguing.
@Test func autoFoldNeverRefoldsWhatTheUserOpened() {
    var f = OutputFolding()
    f.fold(7, .tail(keep: 3))
    f.unfold(7)
    let folded = f.autoFold(region(output: 300), longerThan: 200, keep: 3)
    #expect(!folded)
}

@Test func thePlaceholderNamesTheCountWithAChevron() {
    #expect(OutputFolding.placeholder(hiddenRows: 2431) == "\u{25B8} \u{2026} 2,431 lines hidden")
    #expect(OutputFolding.placeholder(hiddenRows: 1) == "\u{25B8} \u{2026} 1 line hidden")
}
```

- [ ] **Step 2: Rewrite the viewport tests against ids**

Replace `Tests/NyxCoreTests/OutputFoldingViewportTests.swift` wholesale. Keep its `session()` fixture (three commands; the middle one, `build`, has ten rows of output at rows 3–12 and is command id 2; `tail` is id 3 with eight rows at 14–21). Replace `folded(_ rows: Int...)` with:

```swift
private func folded(_ ids: UInt32..., shape: FoldShape = .all) -> OutputFolding {
    var folding = OutputFolding()
    for id in ids { folding.fold(id, shape) }
    return folding
}
```

Then the tests, one per rule:

```swift
@Test func nothingFoldedIsThePlainRange() {
    let rows = session().displayRows(from: 0, count: 6, folding: OutputFolding())
    #expect(rows == (0..<6).map { .row($0) })
}

@Test func aFullFoldReplacesTheOutputWithOnePlaceholder() {
    let rows = session().displayRows(from: 0, count: 6, folding: folded(2))
    #expect(rows[2] == .row(2))
    #expect(rows[3] == .fold(commandID: 2, hiddenRows: 10))
    #expect(rows[4] == .row(13))
}

@Test func aTailFoldKeepsTheLastLinesAfterThePlaceholder() {
    let rows = session().displayRows(from: 0, count: 8, folding: folded(2, shape: .tail(keep: 3)))
    #expect(rows[2] == .row(2))
    #expect(rows[3] == .fold(commandID: 2, hiddenRows: 7))
    #expect(rows[4] == .row(10))
    #expect(rows[5] == .row(11))
    #expect(rows[6] == .row(12))
    #expect(rows[7] == .row(13))
}

@Test func aViewportStartingInsideHiddenRowsStartsOnThePlaceholder() {
    let t = session()
    let rows = t.displayRows(from: 5, count: 4, folding: folded(2, shape: .tail(keep: 3)))
    #expect(rows.first == .fold(commandID: 2, hiddenRows: 7))
    #expect(rows[1] == .row(10))
}

@Test func aViewportStartingInTheKeptTailIsOrdinary() {
    let rows = session().displayRows(from: 11, count: 3, folding: folded(2, shape: .tail(keep: 3)))
    #expect(rows == [.row(11), .row(12), .row(13)])
}

@Test func theViewportIsAlwaysFilledPastAFold() {
    let rows = session().displayRows(from: 0, count: 6, folding: folded(2))
    #expect(rows.count == 6)
}

@Test func thePlaceholderRowIsDimItalicBrightBlack() {
    let t = session()
    let row = t.foldPlaceholderRow(hiddenRows: 10)
    let text = String(row.cells.prefix(30).map { $0.content == 0 ? " " : Character(UnicodeScalar($0.content)!) })
        .trimmingCharacters(in: .whitespaces)
    #expect(text == OutputFolding.placeholder(hiddenRows: 10))
    #expect(row.cells[0].fg == .indexed(8))
    #expect(row.cells[0].attrs.contains(.dim))
    #expect(row.cells[0].attrs.contains(.italic))
}

@Test func searchHitsInsideAFoldAreNotDrawn() {
    let t = session()
    let display = t.displayRows(from: 0, count: 6, folding: folded(2))
    let matches = [SearchMatch(row: 5, columns: 0..<3), SearchMatch(row: 13, columns: 0..<4)]
    let ranges = SearchHighlights.visibleRanges(matches, displayRows: display, cols: 40)
    #expect(ranges[3].isEmpty)              // the placeholder slot
    #expect(ranges[4] == [0..<4])           // row 13 landed in slot 4
}

@Test func scrollingDownOutOfAFoldLandsPastTheHiddenRows() {
    let t = session()
    _ = t.scrollToAbsoluteRow(6, margin: 0)
    let moved = t.snapViewportOutOfFold(movingUp: false, folding: folded(2, shape: .tail(keep: 3)))
    #expect(moved)
    #expect(t.viewportTopRow == 10)
}

@Test func scrollingUpOutOfAFoldLandsOnTheCommand() {
    let t = session()
    _ = t.scrollToAbsoluteRow(6, margin: 0)
    let moved = t.snapViewportOutOfFold(movingUp: true, folding: folded(2))
    #expect(moved)
    #expect(t.viewportTopRow == 2)
}

@Test func aViewportNotInsideAFoldDoesNotMove() {
    let t = session()
    _ = t.scrollToAbsoluteRow(11, margin: 0)
    #expect(!t.snapViewportOutOfFold(movingUp: false, folding: folded(2, shape: .tail(keep: 3))))
}

@Test func foldedCommandCoversHiddenRowsOnly() {
    let t = session()
    let f = folded(2, shape: .tail(keep: 3))
    #expect(t.foldedCommand(containingOutputRow: 2, folding: f) == nil)      // the prompt
    #expect(t.foldedCommand(containingOutputRow: 5, folding: f)?.region.id == 2)
    #expect(t.foldedCommand(containingOutputRow: 5, folding: f)?.hidden == 3..<10)
    #expect(t.foldedCommand(containingOutputRow: 11, folding: f) == nil)     // kept tail
}

@Test func foldLongOutputFoldsOnlyWhatIsLongerThanTheThreshold() {
    let t = session()
    var f = OutputFolding()
    f.foldLongOutput(in: t, longerThan: 9, keep: 3)
    #expect(f.isFolded(2))
    #expect(!f.isFolded(3))
}
```

Note the `SearchMatch` initializer: check `Sources/NyxCore/Search/BufferSearch.swift` for its exact labels and use those.

Update `StickyPromptTests.swift` lines 79–101: `folding.fold(promptRow: 2)` becomes `folding.fold(2, .all)` (the `build` command in that fixture is the second prompt; confirm with `t.command(containingAbsoluteRow: 2)?.id` if the fixture differs), `.fold(2, let hidden)` becomes `.fold(commandID: 2, hiddenRows: let hidden)` — i.e. `if case .fold(2, let hidden) = $0` keeps working because the labels are positional in a pattern; adjust only if the compiler objects. `ScrollbackTrimTests.swift:199`: `folding.prune(in: t)` becomes `folding.prune(olderThan: t.oldestCommandID)`; read the surrounding assertion and keep its intent (a fold on an evicted command is dropped).

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --no-parallel --filter OutputFolding 2>&1 | grep -E 'error' | head -5`
Expected: compile errors about `FoldShape` and `fold(_:_:)`.

- [ ] **Step 4: Rewrite `OutputFolding.swift`**

```swift
import Foundation

/// How much of a command's output a fold hides.
public enum FoldShape: Equatable {
    /// Everything but the last `keep` rows. The tail is where the error and the summary line are,
    /// which is what a person folding a build actually wants to keep.
    case tail(keep: Int)
    case all
}

/// One row as the viewport should show it.
public enum DisplayRow: Equatable {
    case row(Int)
    /// A folded command's hidden output, standing in for `hiddenRows` rows. Carries the command's
    /// id so clicking it can unfold the right block after the rows underneath have shifted.
    case fold(commandID: UInt32, hiddenRows: Int)
}

/// Which commands' output is collapsed, and how.
///
/// Keyed by `Row.commandID` rather than by prompt row: once the scrollback ring is full every new
/// line shifts every absolute row, and a fold keyed by row would collapse whatever moved into its
/// index -- and vanish from the command it was on. The id stays with the command.
public struct OutputFolding: Equatable {
    private var folds: [UInt32: FoldShape] = [:]
    /// Commands the user unfolded by hand. Automatic folding leaves them alone: a block that
    /// re-collapses after you opened it is the terminal arguing with you.
    private var openedByHand: Set<UInt32> = []

    public init() {}

    public var isEmpty: Bool { folds.isEmpty }

    public func shape(of id: UInt32) -> FoldShape? { folds[id] }
    public func isFolded(_ id: UInt32) -> Bool { folds[id] != nil }

    public mutating func fold(_ id: UInt32, _ shape: FoldShape) {
        guard id != 0 else { return }
        folds[id] = shape
    }

    public mutating func unfold(_ id: UInt32) {
        folds[id] = nil
        openedByHand.insert(id)
    }

    public mutating func unfoldAll() {
        folds.removeAll()
    }

    /// Open ↔ tail. A block already folded fully opens too: the chevron means "show me".
    public mutating func toggle(_ id: UInt32, keep: Int) {
        if folds[id] != nil { unfold(id) } else { fold(id, .tail(keep: keep)) }
    }

    /// Open ↔ all. From a tail fold this tightens rather than opens: ⌥ means "more hidden".
    public mutating func toggleFull(_ id: UInt32) {
        if folds[id] == .all { unfold(id) } else { fold(id, .all) }
    }

    /// Drops folds for commands that have left the buffer, so the set cannot grow over a session.
    public mutating func prune(olderThan oldest: UInt32) {
        folds = folds.filter { $0.key >= oldest }
        openedByHand = openedByHand.filter { $0 >= oldest }
    }

    /// `fold-long-output`: folds `region` if its output is longer than `threshold` rows and the user
    /// has not opened it by hand. Returns whether it folded.
    @discardableResult
    public mutating func autoFold(_ region: CommandRegion, longerThan threshold: Int, keep: Int) -> Bool {
        guard threshold > 0, region.id != 0, region.outputRows.count > threshold,
              !openedByHand.contains(region.id), folds[region.id] == nil else { return false }
        folds[region.id] = .tail(keep: keep)
        return true
    }

    /// "Tidy up the screen": every finished command longer than `threshold` rows, folded.
    public mutating func foldLongOutput(in terminal: Terminal, longerThan threshold: Int, keep: Int) {
        for promptRow in terminal.promptRows {
            guard let region = terminal.command(containingAbsoluteRow: promptRow),
                  region.id != 0, region.outputRows.count > threshold else { continue }
            folds[region.id] = .tail(keep: keep)
        }
    }

    /// A tail that would hide one row behind a one-row placeholder has hidden nothing; below
    /// `keep + 1` rows the fold is a full one.
    public static func effectiveShape(_ shape: FoldShape, outputRows: Int) -> FoldShape {
        guard case .tail(let keep) = shape, keep > 0, outputRows > keep + 1 else { return .all }
        return shape
    }

    /// The absolute rows a fold hides for `region`, after the small-output rule.
    public static func hiddenRange(of region: CommandRegion, shape: FoldShape) -> Range<Int> {
        let output = region.outputRows
        guard !output.isEmpty else { return output.lowerBound..<output.lowerBound }
        switch effectiveShape(shape, outputRows: output.count) {
        case .all: return output
        case .tail(let keep): return output.lowerBound..<(output.upperBound - keep)
        }
    }

    /// What the placeholder row says: the same chevron the command row uses, so the two read as one
    /// control, then the count. Thousands are grouped by hand so the text does not depend on the
    /// machine's locale.
    public static func placeholder(hiddenRows: Int) -> String {
        "\u{25B8} \u{2026} \(grouped(hiddenRows)) \(hiddenRows == 1 ? "line" : "lines") hidden"
    }

    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var out = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return number < 0 ? "-" + out : out
    }
}

public extension Terminal {
    /// The folded command whose *hidden* rows cover `row`, and those rows. A prompt row and a kept
    /// tail row are never inside a fold.
    func foldedCommand(containingOutputRow row: Int, folding: OutputFolding)
        -> (region: CommandRegion, hidden: Range<Int>)? {
        guard !folding.isEmpty, shellEmitsPromptMarks,
              let region = command(containingAbsoluteRow: row),
              let shape = folding.shape(of: region.id) else { return nil }
        let hidden = OutputFolding.hiddenRange(of: region, shape: shape)
        return hidden.contains(row) ? (region, hidden) : nil
    }

    /// Exactly what a viewport `count` rows tall shows from absolute row `top`. With nothing folded
    /// it is the plain range and no buffer walk, which is the path every ordinary frame takes.
    func displayRows(from top: Int, count: Int, folding: OutputFolding) -> [DisplayRow] {
        guard count > 0 else { return [] }
        guard !folding.isEmpty else { return (0..<count).map { .row(top + $0) } }

        var out: [DisplayRow] = []
        var row = max(0, top)
        if let (region, hidden) = foldedCommand(containingOutputRow: row, folding: folding) {
            out.append(.fold(commandID: region.id, hiddenRows: hidden.count))
            row = hidden.upperBound
        }
        while out.count < count && row < totalRows {
            out.append(.row(row))
            let line = absoluteRow(row)
            guard let id = line?.commandID, id != 0, let shape = folding.shape(of: id),
                  let region = command(containingAbsoluteRow: row), region.promptRow == row else {
                row += 1
                continue
            }
            let hidden = OutputFolding.hiddenRange(of: region, shape: shape)
            guard !hidden.isEmpty else { row += 1; continue }
            // A wrapped command line lies between the prompt and its output; it belongs to the
            // command, not to what it printed, and stays on screen.
            var next = row + 1
            while next < hidden.lowerBound && out.count < count {
                out.append(.row(next))
                next += 1
            }
            if out.count < count { out.append(.fold(commandID: id, hiddenRows: hidden.count)) }
            row = hidden.upperBound
        }
        return out
    }

    /// The rows to draw for a range of the buffer; used where a fixed count is not wanted.
    func displayRows(in range: Range<Int>, folding: OutputFolding) -> [DisplayRow] {
        guard !folding.isEmpty else { return range.map { .row($0) } }
        return displayRows(from: range.lowerBound, count: range.count, folding: folding)
            .filter { if case .row(let r) = $0 { return range.contains(r) } else { return true } }
    }

    /// Moves the viewport off hidden rows in the direction the user was scrolling, so a fold of two
    /// thousand rows is not two thousand wheel clicks. Returns whether it moved.
    @discardableResult
    func snapViewportOutOfFold(movingUp: Bool, folding: OutputFolding) -> Bool {
        guard let (region, hidden) = foldedCommand(containingOutputRow: viewportTopRow, folding: folding)
        else { return false }
        return scrollToAbsoluteRow(movingUp ? region.promptRow : hidden.upperBound, margin: 0)
    }

    /// The placeholder as a row of cells, so it is drawn through the ordinary row path and nothing
    /// in NyxRender learns what a fold is. Dim and italic in the theme's own bright black: a note
    /// about the buffer, not something a program printed.
    func foldPlaceholderRow(hiddenRows: Int) -> Row {
        var row = Row(cols: cols)
        var cell = Cell()
        cell.fg = .indexed(8)
        cell.attrs = [.dim, .italic]
        for (column, scalar) in OutputFolding.placeholder(hiddenRows: hiddenRows).unicodeScalars.enumerated() {
            guard column < cols else { break }
            cell.content = scalar.value
            row.cells[column] = cell
        }
        return row
    }
}

/// Where the rows of a folded viewport ended up.
public enum DisplayRows {
    /// Absolute row → screen row. Hidden rows are absent, so a highlight on hidden text is drawn
    /// nowhere rather than on whatever now sits at that index.
    public static func indexByAbsoluteRow(_ rows: [DisplayRow]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        map.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard case .row(let absolute) = row else { continue }
            map[absolute] = index
        }
        return map
    }
}
```

`displayRowCount(in:folding:)` is deleted; grep confirms nothing outside the file used it.

- [ ] **Step 5: Keep the pane compiling, minimally**

In `Pane.swift`:
- line 616: `if !self.folding.isEmpty { self.folding.prune(in: t) }` → `if !self.folding.isEmpty { self.folding.prune(olderThan: t.oldestCommandID) }`.
- line 649: `case .fold(_, let hidden)` is unchanged (positional pattern).
- `foldBlock(atPointInPadding:)` (line 1090): return `region.id` instead of `region.promptRow`; `folding.toggle(promptRow: promptRow)` → `folding.toggle(id, keep: config.foldKeepLines)` — until Task 3 lands, use the literal `3` and leave a `// Task 3: config.foldKeepLines` comment that Task 3 removes.
- `unfoldPlaceholder(at:)` (line 1702): `case .fold(let promptRow, _)` → `case .fold(let id, _)` and `folding.unfold(promptRow: promptRow)` → `folding.unfold(id)`.
- `gutterClicked` (line 1713): return `region.id`; `folding.toggle(promptRow:)` → `folding.toggle(id, keep: 3)`.
- `toggleFoldOfCurrentCommand` (line 1742): return `region.id`; same toggle.
- `foldAllLongOutput` (line 1767): `folding.foldLongOutput(in: t, longerThan: Pane.longOutputThreshold, keep: 3)`.
- The block at line 607–612 that calls `unfoldAll()` on a generation change stays.

- [ ] **Step 6: Run everything**

Run: `swift test --no-parallel 2>&1 | tail -3` → all green; note the new count.
Run: `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/NyxCore/Shell/OutputFolding.swift Sources/NyxApp/Pane.swift \
        Tests/NyxCoreTests/OutputFoldingTests.swift Tests/NyxCoreTests/OutputFoldingViewportTests.swift \
        Tests/NyxCoreTests/StickyPromptTests.swift Tests/NyxCoreTests/ScrollbackTrimTests.swift
git commit -m "Folds follow the command, not the row, and keep the tail"
```

---

### Task 3: The two config keys

**Files:**
- Modify: `Sources/NyxCore/Config/Config.swift` (fields near line 66; `defaultFileText` Behaviour block near line 124)
- Modify: `Sources/NyxCore/Config/ConfigParser.swift` (cases near line 119)
- Modify: `Sources/NyxCore/Config/ConfigDiff.swift`
- Modify: `Sources/NyxApp/Pane.swift` (`apply`, line 292; the three literal `3`s from Task 2)
- Modify: `Sources/NyxApp/SettingsWindowController.swift` (`behaviourPage` line 113; the `set(...)` block near line 420)
- Modify: `docs/configuration.md` (settings table after `multiline-paste`, line 45)
- Test: `Tests/NyxCoreTests/ConfigTests.swift`, `Tests/NyxCoreTests/ConfigDiffTests.swift`

**Interfaces:**
- Produces: `Config.foldKeepLines: Int` (default 3, clamp 0…100), `Config.foldLongOutput: Int` (default 0, clamp 0…1_000_000), `ConfigDiff.foldingChanged: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `ConfigTests.swift`:

```swift
@Test func theFoldSettingsAreRead() {
    #expect(Config.defaults.foldKeepLines == 3)
    #expect(Config.defaults.foldLongOutput == 0)
    #expect(ConfigParser.parse("fold-keep-lines = 5").config.foldKeepLines == 5)
    #expect(ConfigParser.parse("fold-long-output = 200").config.foldLongOutput == 200)
    #expect(ConfigParser.parse("fold-keep-lines = many").diagnostics.count == 1)
    #expect(ConfigParser.parse("fold-long-output = -4").config.foldLongOutput == 0)
}
```

Append to `ConfigDiffTests.swift`:

```swift
@Test func foldSettingsSetOnlyFoldingChanged() {
    var c = Config.defaults
    c.foldKeepLines = 5
    let diff = ConfigDiff(from: .defaults, to: c)
    #expect(diff.foldingChanged)
    #expect(!diff.fontChanged && !diff.geometryChanged && !diff.paletteChanged)
    #expect(!diff.isEmpty)
    #expect(diff.deferredNotes.isEmpty)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter 'theFoldSettingsAreRead|foldSettingsSetOnlyFoldingChanged' 2>&1 | grep error | head -3`
Expected: `has no member 'foldKeepLines'`.

- [ ] **Step 3: Add the fields, parser cases, default text, diff flag**

`Config.swift`, after `multilinePaste`:

```swift
    /// Rows of output a fold keeps visible at the end. Three, because the error and the summary
    /// line of nearly every tool are in its last lines; 0 hides everything.
    public var foldKeepLines: Int = 3
    /// Fold finished output longer than this many rows once the next command starts. Off by
    /// default: a terminal that hides things on its own has to earn that first.
    public var foldLongOutput: Int = 0
```

`ConfigParser.swift`, after the `multiline-paste` case:

```swift
            case "fold-keep-lines":
                if let i = Int(value) { config.foldKeepLines = min(max(i, 0), 100) } else { badValue() }
            case "fold-long-output":
                if let i = Int(value) { config.foldLongOutput = min(max(i, 0), 1_000_000) } else { badValue() }
```

`defaultFileText`, after `# multiline-paste = edit`:

```
        # A folded command keeps its last few lines of output; 0 hides them all.
        # fold-keep-lines = 3
        # Fold output longer than this many rows once the next command starts. 0 is off.
        # fold-long-output = 0
```

`ConfigDiff.swift`: add `public var foldingChanged: Bool` with a doc comment `/// \`fold-keep-lines\`, \`fold-long-output\`: read on the next fold; nothing on screen is rebuilt.`; set it in `init`; include it in `isEmpty`'s expression. No deferred note.

- [ ] **Step 4: Read the keys in the pane and the settings window**

`Pane.swift`: replace the Task 2 literal `3`s with `config.foldKeepLines`, and `Pane.longOutputThreshold` stays as the manual "fold all long" threshold. In `apply`, nothing further: `config` is replaced at the top of `apply`, and every fold reads it at the moment of folding.

`SettingsWindowController.swift`: in `behaviourPage()` add two rows before the `note:`:

```swift
            row("Folded output keeps", stepperField("fold-keep-lines", min: 0, max: 100, step: 1)),
            row("Auto-fold output over", stepperField("fold-long-output", min: 0, max: 100_000, step: 50)),
```

and in the block that fills controls from the config (near line 420):

```swift
        set("fold-keep-lines", Double(c.foldKeepLines), decimals: 0)
        set("fold-long-output", Double(c.foldLongOutput), decimals: 0)
```

Check how `stepperChanged`/`fieldChanged` write the value (`ConfigWriter.setting(_:to:in:)`) — integer keys are written through the same path as `scrollback-lines`, so nothing else is needed.

`docs/configuration.md`, two rows after `multiline-paste`:

```
| `fold-keep-lines` | `3` | Rows of output a folded command keeps visible at its end. `0` hides all of it |
| `fold-long-output` | `0` | Fold a command's output automatically once the next command starts, when it is longer than this many rows. `0` turns it off. A block you unfolded by hand is never re-folded |
```

- [ ] **Step 5: Run the tests**

Run: `swift test --no-parallel --filter Config 2>&1 | tail -3` → green, including `theDefaultFileTextParsesBackToTheDefaults`.
Run: `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Config/Config.swift Sources/NyxCore/Config/ConfigParser.swift \
        Sources/NyxCore/Config/ConfigDiff.swift Sources/NyxApp/Pane.swift \
        Sources/NyxApp/SettingsWindowController.swift docs/configuration.md \
        Tests/NyxCoreTests/ConfigTests.swift Tests/NyxCoreTests/ConfigDiffTests.swift
git commit -m "Two settings for folding: how much tail to keep, and when to fold on its own"
```

---

### Task 4: The header, the hover and the export, as values

**Files:**
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift`
- Modify: `Sources/NyxCore/Shell/PromptMarks.swift` (`commandText(of:)` lives in `CommandWatcher.swift`; add `outputText(of:)` beside it)
- Create: `Sources/NyxCore/Shell/BlockExport.swift`
- Test: `Tests/NyxCoreTests/BlockHeaderTests.swift`, `Tests/NyxCoreTests/BlockHoverTests.swift`, `Tests/NyxCoreTests/BlockExportTests.swift` (all new)

**Interfaces:**
- Consumes: `CommandBlock`, `CommandRegion.id`, `Terminal.runningCommand`, `OutputFolding.shape(of:)`, `DurationText`.
- Produces:

```swift
public enum BlockAction: Equatable {
    case copyCommand, copyOutput, copyMarkdown, saveOutput
    case runAgain, editAndRun
    case toggleFold, toggleFoldAll
    case notifyWhenDone(armed: Bool)
    public var title: String                 // menu wording, see below
}
public struct BlockHeader: Equatable {
    public enum State: Equatable { case running(elapsed: Double), finished, failed(status: Int32) }
    public let id: UInt32
    public let state: State
    public let folded: Bool
    public let hasOutput: Bool
    public var summary: String               // "exit 1 · 8.8s", "12s", ""
    public var chevron: String               // "▾" open, "▸" folded, "" without output
    public var summaryWithChevron: String    // summary + " " + chevron, or just the chevron
    public var actions: [(action: BlockAction, enabled: Bool)]
    public var isRunning: Bool
}
public extension CommandBlock {
    func header(now: Double, folding: OutputFolding, notifyArmed: Bool, anyFolds: Bool) -> BlockHeader
}
public struct BlockHover: Equatable {
    public let id: UInt32
    public let rows: Range<Int>        // visible rows to tint
    public let headerRow: Int?         // nil when the command row is off screen
    public static func resolve(pointerRow: Int?, blocks: [CommandBlock], allowed: Bool) -> BlockHover?
}
public enum BlockExport {
    public static func markdown(command: String, output: String) -> String
}
public extension Terminal {
    func outputText(of region: CommandRegion) -> String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NyxCoreTests/BlockHeaderTests.swift
import Testing
@testable import NyxCore

private func region(id: UInt32 = 4, output: Int = 5, status: Int32? = 0, duration: Double? = 8.8,
                    started: Bool = true) -> CommandRegion {
    // A region with no status and no duration is a running command; it started at clock 0.
    CommandRegion(promptRow: 0, outputStart: started ? 1 : nil, endRow: max(0, output),
                  exitStatus: status, duration: duration, id: id,
                  startedAt: (status == nil && duration == nil) ? 0 : nil)
}

private func block(_ region: CommandRegion) -> CommandBlock {
    CommandBlock(region: region, visibleRows: 0..<6, showsHeader: true)
}

@Test func aFinishedCommandSummarisesStatusAndTimeWithAnOpenChevron() {
    let h = block(region(status: 1)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false)
    #expect(h.state == .failed(status: 1))
    #expect(h.summary == "exit 1 · 8.8s")
    #expect(h.chevron == "\u{25BE}")
    #expect(h.summaryWithChevron == "exit 1 · 8.8s \u{25BE}")
}

@Test func aQuickSuccessShowsOnlyTheChevron() {
    let h = block(region(duration: 0.2)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false)
    #expect(h.summary == "")
    #expect(h.summaryWithChevron == "\u{25BE}")
}

@Test func aFoldedBlockPointsRight() {
    var f = OutputFolding()
    f.fold(4, .all)
    let h = block(region()).header(now: 100, folding: f, notifyArmed: false, anyFolds: true)
    #expect(h.folded)
    #expect(h.chevron == "\u{25B8}")
}

@Test func aRunningCommandCountsUpAfterOneSecond() {
    let running = region(status: nil, duration: nil)
    let early = block(running).header(now: 0.4, folding: OutputFolding(), notifyArmed: false, anyFolds: false)
    #expect(early.summary == "")
    #expect(early.isRunning)
    let later = block(running).header(now: 12.3, folding: OutputFolding(), notifyArmed: false, anyFolds: false)
    #expect(later.state == .running(elapsed: 12.3))
    #expect(later.summary == "12s")
}

@Test func aCommandWithoutOutputHasNoChevronAndNoOutputActions() {
    let h = block(region(output: 0, started: false)).header(now: 100, folding: OutputFolding(),
                                                            notifyArmed: false, anyFolds: false)
    #expect(!h.hasOutput)
    #expect(h.chevron == "")
    #expect(h.actions.first { $0.action == .copyOutput }?.enabled == false)
    #expect(h.actions.first { $0.action == .toggleFold }?.enabled == false)
}

@Test func theMenuListsActionsInTheSpecifiedOrder() {
    let h = block(region(status: nil, duration: nil)).header(now: 5, folding: OutputFolding(),
                                                             notifyArmed: true, anyFolds: false)
    #expect(h.actions.map(\.action) == [
        .copyCommand, .copyOutput, .copyMarkdown, .saveOutput,
        .runAgain, .editAndRun,
        .toggleFold, .toggleFoldAll,
        .notifyWhenDone(armed: true),
    ])
}

@Test func notifyWhenDoneIsOfferedOnlyWhileRunning() {
    let done = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false)
    #expect(!done.actions.contains { if case .notifyWhenDone = $0.action { return true } else { return false } })
}

@Test func titlesFollowTheState() {
    #expect(BlockAction.toggleFold.title == "Fold Output")
    #expect(BlockAction.notifyWhenDone(armed: false).title == "Notify When Done")
    var f = OutputFolding()
    f.fold(4, .all)
    let h = block(region()).header(now: 100, folding: f, notifyArmed: false, anyFolds: true)
    #expect(h.title(for: .toggleFold) == "Unfold Output")
    #expect(h.title(for: .toggleFoldAll) == "Unfold Everything")
}
```

```swift
// Tests/NyxCoreTests/BlockHoverTests.swift
import Testing
@testable import NyxCore

private func blocks() -> [CommandBlock] {
    let a = CommandRegion(promptRow: 10, outputStart: 11, endRow: 14, exitStatus: 0, duration: 1, id: 1)
    let b = CommandRegion(promptRow: 15, outputStart: 16, endRow: 30, exitStatus: 1, duration: 1, id: 2)
    // Viewport top is absolute row 12: block a shows rows 0..<3 without its header, b shows 3..<19.
    return [CommandBlock(region: a, visibleRows: 0..<3, showsHeader: false),
            CommandBlock(region: b, visibleRows: 3..<19, showsHeader: true)]
}

@Test func thePointerOnAnyRowOfABlockHoversThatBlock() {
    let hover = BlockHover.resolve(pointerRow: 7, blocks: blocks(), allowed: true)
    #expect(hover?.id == 2)
    #expect(hover?.rows == 3..<19)
    #expect(hover?.headerRow == 3)
}

@Test func aBlockWhoseCommandIsOffScreenTintsButHasNoHeaderRow() {
    let hover = BlockHover.resolve(pointerRow: 1, blocks: blocks(), allowed: true)
    #expect(hover?.id == 1)
    #expect(hover?.headerRow == nil)
}

@Test func nothingIsHoveredOutsideEveryBlockOrWhenChromeIsDisallowed() {
    #expect(BlockHover.resolve(pointerRow: 19, blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(pointerRow: nil, blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(pointerRow: 7, blocks: blocks(), allowed: false) == nil)
}
```

```swift
// Tests/NyxCoreTests/BlockExportTests.swift
import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

@Test func markdownIsOneFenceWithThePromptedCommandAndTheOutput() {
    let md = BlockExport.markdown(command: "curl -s https://x.test/v1", output: "{\"ok\":true}")
    #expect(md == "```\n$ curl -s https://x.test/v1\n{\"ok\":true}\n```\n")
}

@Test func aCommandThatAlreadyStartsWithAPromptIsNotDoubled() {
    #expect(BlockExport.markdown(command: "$ ls", output: "a").hasPrefix("```\n$ ls\n"))
    #expect(BlockExport.markdown(command: "% ls", output: "a").hasPrefix("```\n% ls\n"))
}

@Test func emptyOutputLeavesOnlyTheCommand() {
    #expect(BlockExport.markdown(command: "true", output: "") == "```\n$ true\n```\n")
}

@Test func outputTextTrimsTrailingBlankLines() {
    let t = makeTerminal(cols: 20, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo hi\r\n" + mark("C") + "hi\r\n\r\n\r\n" + mark("D", 0)
           + mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)!
    #expect(t.outputText(of: region) == "hi")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter 'BlockHeader|BlockHover|BlockExport' 2>&1 | grep error | head -3`
Expected: `cannot find 'BlockHover'`, `no member 'header'`.

- [ ] **Step 3: Implement the header and hover**

Append to `Sources/NyxCore/Shell/CommandBlock.swift`:

```swift
/// What can be done to a block, in the order the ⋯ menu lists it.
public enum BlockAction: Equatable {
    case copyCommand, copyOutput, copyMarkdown, saveOutput
    case runAgain, editAndRun
    case toggleFold, toggleFoldAll
    case notifyWhenDone(armed: Bool)

    /// The neutral title. `BlockHeader.title(for:)` adjusts the two fold titles to the state.
    public var title: String {
        switch self {
        case .copyCommand: return "Copy Command"
        case .copyOutput: return "Copy Output"
        case .copyMarkdown: return "Copy as Markdown"
        case .saveOutput: return "Save Output\u{2026}"
        case .runAgain: return "Run This Command Again"
        case .editAndRun: return "Edit and Run This Command\u{2026}"
        case .toggleFold: return "Fold Output"
        case .toggleFoldAll: return "Fold Everything Long"
        case .notifyWhenDone: return "Notify When Done"
        }
    }

    /// Where a separator goes in the menu: before the first action of each group after the first.
    public var startsGroup: Bool {
        switch self {
        case .runAgain, .toggleFold, .notifyWhenDone: return true
        default: return false
        }
    }
}

/// Everything the command row and the hover overlay say about one block, decided once.
public struct BlockHeader: Equatable {
    public enum State: Equatable {
        case running(elapsed: Double)
        case finished
        case failed(status: Int32)
    }

    public let id: UInt32
    public let state: State
    public let folded: Bool
    public let hasOutput: Bool
    /// Whether any block in the pane is folded, which is what "Unfold Everything" needs to know.
    public let anyFolds: Bool
    public let notifyArmed: Bool
    /// "exit 1 · 8.8s" for a failure, "8.8s" for a slow success, "12s" for a command still going,
    /// and nothing for a quick success -- a status that appears the instant you press return is
    /// noise. Computed by `CommandBlock.header(now:...)`, stored here so the view compares one value.
    public let summary: String

    public init(id: UInt32, state: State, folded: Bool, hasOutput: Bool, anyFolds: Bool,
                notifyArmed: Bool, summary: String) {
        self.id = id; self.state = state; self.folded = folded; self.hasOutput = hasOutput
        self.anyFolds = anyFolds; self.notifyArmed = notifyArmed; self.summary = summary
    }

    public var isRunning: Bool { if case .running = state { return true } else { return false } }

    public var chevron: String {
        guard hasOutput else { return "" }
        return folded ? "\u{25B8}" : "\u{25BE}"
    }

    /// What the renderer draws at the end of the command row: the summary, a space, the chevron.
    public var summaryWithChevron: String {
        switch (summary.isEmpty, chevron.isEmpty) {
        case (true, true): return ""
        case (true, false): return chevron
        case (false, true): return summary
        case (false, false): return summary + " " + chevron
        }
    }

    /// The ⋯ menu, in order, each with whether it can do anything right now.
    public var actions: [(action: BlockAction, enabled: Bool)] {
        var list: [(BlockAction, Bool)] = [
            (.copyCommand, true), (.copyOutput, hasOutput), (.copyMarkdown, true), (.saveOutput, hasOutput),
            (.runAgain, !isRunning), (.editAndRun, !isRunning),
            (.toggleFold, hasOutput), (.toggleFoldAll, true),
        ]
        if isRunning { list.append((.notifyWhenDone(armed: notifyArmed), true)) }
        return list.map { (action: $0.0, enabled: $0.1) }
    }

    public func title(for action: BlockAction) -> String {
        switch action {
        case .toggleFold: return folded ? "Unfold Output" : "Fold Output"
        case .toggleFoldAll: return anyFolds ? "Unfold Everything" : "Fold Everything Long"
        default: return action.title
        }
    }
}

`BlockHeader` is `Equatable` while holding a tuple array only because `actions` is computed; the
stored fields are all `Equatable`.

public extension CommandBlock {
    /// The header for this block at clock reading `now`.
    func header(now: Double, folding: OutputFolding, notifyArmed: Bool, anyFolds: Bool) -> BlockHeader {
        let state: BlockHeader.State
        let summary: String
        if isRunning {
            let elapsed = max(0, now - (region.startedAt ?? now))
            state = .running(elapsed: elapsed)
            summary = elapsed >= 1 ? DurationText.short(elapsed) : ""
        } else if let status = region.exitStatus, status != 0 {
            state = .failed(status: status)
            summary = self.summary()
        } else {
            state = .finished
            summary = self.summary()
        }
        return BlockHeader(id: region.id, state: state, folded: folding.isFolded(region.id),
                           hasOutput: !region.outputRows.isEmpty, anyFolds: anyFolds,
                           notifyArmed: notifyArmed, summary: summary)
    }
}
```

`region.startedAt` does not exist yet: add `public let startedAt: Double?` to `CommandRegion` (defaulted `nil`, the last initializer parameter after `id`), filled in `command(containingAbsoluteRow:)` with `runningCommand?.id == id ? runningCommand?.startedAt : nil`. The test fixture above sets it to 0 for a running region, which is why `12s` comes out at `now: 12.3`.

Hover:

```swift
/// Which block the pointer is over, and where its chrome goes. Pure so the answer for "pointer on
/// the row after the last block" or "chrome disallowed while a TUI runs" is a test, not a guess.
public struct BlockHover: Equatable {
    public let id: UInt32
    /// Visible rows to tint.
    public let rows: Range<Int>
    /// The visible row to attach the overlay to, nil when the command line is above the viewport.
    public let headerRow: Int?

    public static func resolve(pointerRow: Int?, blocks: [CommandBlock], allowed: Bool) -> BlockHover? {
        guard allowed, let pointerRow,
              let block = blocks.first(where: { $0.visibleRows.contains(pointerRow) }),
              block.region.id != 0 else { return nil }
        return BlockHover(id: block.region.id, rows: block.visibleRows,
                          headerRow: block.showsHeader ? block.visibleRows.lowerBound : nil)
    }
}
```

`BlockExport.swift`:

```swift
import Foundation

/// A block as something to paste somewhere else.
public enum BlockExport {
    /// One fence: the command with a `$ ` prefix, then the output. No metadata -- the target is a
    /// chat message or a ticket, and people delete metadata before pasting.
    public static func markdown(command: String, output: String) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompted = trimmedCommand.hasPrefix("$ ") || trimmedCommand.hasPrefix("% ")
            ? trimmedCommand : "$ " + trimmedCommand
        var body = "```\n" + prompted + "\n"
        if !output.isEmpty { body += output + "\n" }
        return body + "```\n"
    }
}

public extension Terminal {
    /// The output rows as plain text, trailing blank lines dropped.
    func outputText(of region: CommandRegion) -> String {
        let rows = region.outputRows
        guard !rows.isEmpty else { return "" }
        var lines = rows.map { rowText(absoluteRow: $0).text }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
```

`rowText(absoluteRow:)` is what `commandText(of:)` already uses; it lives in `Sources/NyxCore/Text/Terminal+RowText.swift` and returns a `RowText` whose `.text` is the string.

`commandText(of:)` keeps the prompt string ("$ …"), which is why the markdown export does not add a second `$`.

- [ ] **Step 4: Run the tests**

Run: `swift test --no-parallel --filter 'BlockHeader|BlockHover|BlockExport|CommandBlock' 2>&1 | tail -3` → green.
Run: `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Shell/CommandBlock.swift Sources/NyxCore/Shell/PromptMarks.swift \
        Sources/NyxCore/Shell/BlockExport.swift Tests/NyxCoreTests/BlockHeaderTests.swift \
        Tests/NyxCoreTests/BlockHoverTests.swift Tests/NyxCoreTests/BlockExportTests.swift
git commit -m "What a block's header says and offers, decided in Core"
```

---

### Task 5: The hover tint and the chevron on screen

**Files:**
- Modify: `Sources/NyxCore/Terminal/Color.swift` (after `noteForeground`, line 336)
- Modify: `Sources/NyxRender/Renderer.swift` (`RenderFrame` lines 5–66; `buildChrome` line 472)
- Test: `Tests/NyxCoreTests/ThemesTests.swift` (the contrast loop near line 215), `Tests/NyxRenderTests/BlockChromeRenderTests.swift`, `Tests/NyxRenderTests/PartialRedrawTests.swift`

**Interfaces:**
- Produces: `RenderFrame.highlightedRows: Range<Int>?` (visible rows; `nil` = none); `Palette.blockHoverBackground: RGB`.

- [ ] **Step 1: Write the failing tests**

In `ThemesTests.swift`, inside the loop that checks `noteForeground` for every built-in:

```swift
        #expect(RGB.distance(p.blockHoverBackground, p.background) >= 4,
                "\(name): the hover tint is invisible")
        #expect(RGB.distance(p.blockHoverBackground, p.selectionBackground) >= 8,
                "\(name): the hover tint looks like a selection")
        #expect(RGB.contrast(p.foreground, p.blockHoverBackground) >= 4.5,
                "\(name): text on a hovered block is \(RGB.contrast(p.foreground, p.blockHoverBackground)):1")
```

(`RGB.distance` exists: `everyBandIsVisiblyOffTheSurfaceUnderIt` uses it.)

In `BlockChromeRenderTests.swift`, extend `render(...)` with `highlighted: Range<Int>? = nil` passed as `highlightedRows: highlighted` to the `RenderFrame`, and add:

```swift
/// The tint sits under the glyphs across the block's rows and nowhere else.
@Test func hoveredRowsAreTintedAndOthersAreNot() throws {
    let (fonts, w, px) = try render(padding: 0, highlighted: 0..<2)
    let mid = w / 2
    let tinted = px(mid, fonts.metrics.height / 2)
    let plain = px(mid, fonts.metrics.height * 2 + fonts.metrics.height / 2)
    #expect(tinted != Pixel(r: 0, g: 0, b: 0))
    #expect(plain == Pixel(r: 0, g: 0, b: 0))
}

/// The chevron is a real glyph at the end of the summary, in the summary's colour.
@Test func theSummaryEndsInAChevron() throws {
    let (fonts, w, px) = try render(cols: 12, padding: 0,
                                    summaries: [(row: 0, text: "8.8s \u{25BE}", color: RGB(0, 255, 0))])
    let lastCell = (w - fonts.metrics.width)..<w
    var ink = 0
    for x in lastCell { for y in 0..<fonts.metrics.height where px(x, y).g > 100 { ink += 1 } }
    #expect(ink > 4)
}
```

In `PartialRedrawTests.swift`, add a scenario next to the existing ones (follow the file's pattern of a cache-using renderer versus a rebuild-everything renderer over a sequence of frames):

```swift
/// Hover on, hover off: the tint is chrome outside the row cache, so both renderers agree and no
/// row is rebuilt for it.
@Test func hoverTintNeverStalesTheCache() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let t = makeTerminal(cols: 10, rows: 4, scrollback: 10).run("one\r\ntwo\r\nthree\r\n")
    let cached = try Renderer(device: device, fonts: fonts)
    let fresh = try Renderer(device: device, fonts: fonts)
    let tex1 = try makeTexture(device, cols: 10, rows: 4, fonts: fonts)
    let tex2 = try makeTexture(device, cols: 10, rows: 4, fonts: fonts)
    var f = frame(of: t)
    _ = try pixels(cached, f, to: tex1)
    t.clearDirty()
    f = frame(of: t); f.highlightedRows = 0..<2
    let a = try pixels(cached, f, to: tex1)
    let b = try pixels(fresh, frame(of: t, trackDirty: false).with(highlighted: 0..<2), to: tex2)
    #expect(firstDifference(a, b, width: tex1.width) == nil)
    f.highlightedRows = nil
    let c = try pixels(cached, f, to: tex1)
    let d = try pixels(fresh, frame(of: t, trackDirty: false), to: tex2)
    #expect(firstDifference(c, d, width: tex1.width) == nil)
}
```

`makeTerminal` here is the render-test-local helper if one exists in that file; otherwise construct `Terminal(cols:rows:scrollbackLimit:)` directly. Add a tiny private extension in the test file: `extension RenderFrame { func with(highlighted: Range<Int>?) -> RenderFrame { var f = self; f.highlightedRows = highlighted; return f } }`.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter 'Themes|BlockChromeRender|PartialRedraw' 2>&1 | grep error | head -3`
Expected: `no member 'blockHoverBackground'`, `extra argument 'highlightedRows'`.

- [ ] **Step 3: The palette colour**

`Color.swift`, after `noteForeground`:

```swift
    /// The tint behind every row of the block under the pointer: says "these rows are one thing"
    /// without competing with the selection colour, which is chosen to be seen. Foreground blended
    /// into background a little, pushed further only in themes where a little is invisible.
    public var blockHoverBackground: RGB {
        var amount = 0.06
        while amount < 0.20, RGB.distance(RGB.blend(foreground, into: background, amount: amount), background) < 4 {
            amount += 0.02
        }
        return RGB.blend(foreground, into: background, amount: amount)
    }
```

- [ ] **Step 4: The frame field and the chrome rect**

`RenderFrame`: add after `blockSummaries`:

```swift
    /// The visible rows of the block under the pointer, tinted as one. nil when nothing is hovered,
    /// which is the state of every frame the mouse is not moving through. Chrome, not a row input:
    /// drawn in `buildChrome`, outside the row cache.
    public var highlightedRows: Range<Int>?
```

with `highlightedRows: Range<Int>? = nil` as the initializer parameter placed before `dirtyRows` and assigned.

`buildChrome`, at the very top before the spine loop (so the tint is under every other chrome instance):

```swift
        // The hovered block's tint: one translucent rect across the grid's width, under the glyphs
        // (the background bucket draws first) and outside the row cache (nothing per row changed).
        if let rows = f.highlightedRows, !rows.isEmpty {
            let top = Float(padding + max(0, rows.lowerBound) * m.height)
            let height = Float(min(rows.count, f.rows - max(0, rows.lowerBound)) * m.height)
            let width = Float(f.cols * m.width)
            var tint = rect(Float(padding), top, width, height, f.palette.blockHoverBackground)
            tint.color.w = 1
            instances.append(tint)
        }
```

`rect(_:_:_:_:_:)` builds an opaque instance; the derived colour is already blended toward the background, so alpha 1 is correct and blending is not needed. Confirm the background bucket (`instances`) is encoded before `glyphs` in `render`; it is (spines already rely on it).

- [ ] **Step 5: Run the tests**

Run: `swift test --no-parallel --filter 'Themes|BlockChromeRender|PartialRedraw' 2>&1 | tail -3` → green.
Run: `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Terminal/Color.swift Sources/NyxRender/Renderer.swift \
        Tests/NyxCoreTests/ThemesTests.swift Tests/NyxRenderTests/BlockChromeRenderTests.swift \
        Tests/NyxRenderTests/PartialRedrawTests.swift
git commit -m "A hovered block is tinted as one thing, and the summary ends in a chevron"
```

---

### Task 6: Notifications that can be armed

**Files:**
- Modify: `Sources/NyxCore/Shell/CommandWatcher.swift`
- Test: `Tests/NyxCoreTests/CommandWatcherTests.swift`

**Interfaces:**
- Produces: `FinishedCommand.id: UInt32`; `CommandWatcher.observe(bottomPromptRow:outputStarted:runningID:now:) -> FinishedCommand?` (the old signature is kept as an overload with `runningID: 0`); `CommandNotificationRule.shouldNotify(_ finished: FinishedCommand, armed: Set<UInt32>, windowFocused: Bool, minimumDuration: Double) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `CommandWatcherTests.swift`:

```swift
// MARK: - Arming a notification for one command

@Test func theFinishedCommandCarriesItsID() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, runningID: 42, now: 0)
    let finished = w.observe(bottomPromptRow: 5, outputStarted: false, runningID: 0, now: 30)
    #expect(finished?.id == 42)
    #expect(finished?.duration == 30)
}

/// The watcher reports short commands too, so an armed one can be noticed; the rule decides.
@Test func anArmedCommandIsReportedHoweverShort() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, runningID: 42, now: 0)
    let finished = w.observe(bottomPromptRow: 5, outputStarted: false, runningID: 0, now: 2)
    #expect(finished?.id == 42)
    #expect(finished?.duration == 2)
}

@Test func armedBeatsDurationAndFocus() {
    let quick = FinishedCommand(promptRow: 0, duration: 2, id: 42)
    #expect(CommandNotificationRule.shouldNotify(quick, armed: [42], windowFocused: true, minimumDuration: 10))
    #expect(!CommandNotificationRule.shouldNotify(quick, armed: [], windowFocused: true, minimumDuration: 10))
    #expect(!CommandNotificationRule.shouldNotify(quick, armed: [], windowFocused: false, minimumDuration: 10))
}

@Test func anUnarmedLongCommandNotifiesOnlyWhenTheWindowIsNotFocused() {
    let long = FinishedCommand(promptRow: 0, duration: 30, id: 7)
    #expect(CommandNotificationRule.shouldNotify(long, armed: [], windowFocused: false, minimumDuration: 10))
    #expect(!CommandNotificationRule.shouldNotify(long, armed: [], windowFocused: true, minimumDuration: 10))
}
```

The existing tests call `observe(bottomPromptRow:outputStarted:now:)` and assert `nil` for short commands; keep that overload's behaviour (it filters by `minimumDuration`) so they still pass, and make the new four-argument overload return every finished command.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter CommandWatcher 2>&1 | grep error | head -3`
Expected: `extra argument 'runningID'`.

- [ ] **Step 3: Implement**

`FinishedCommand`: add `public let id: UInt32` and `id: UInt32 = 0` as the last init parameter.

`CommandWatcher`: add `private var trackedID: UInt32 = 0`. New method:

```swift
    /// As `observe(bottomPromptRow:outputStarted:now:)`, but reports *every* finished command with
    /// its id, leaving "is it worth a notification" to `CommandNotificationRule` -- which can then
    /// say yes to a two-second command the user armed by hand.
    public mutating func observe(bottomPromptRow: Int?, outputStarted: Bool, runningID: UInt32,
                                 now: Double) -> FinishedCommand? {
        defer { wasRunning = outputStarted }
        if outputStarted {
            if !wasRunning { startedAt = now }
            trackedPrompt = bottomPromptRow
            if runningID != 0 { trackedID = runningID }
            return nil
        }
        guard wasRunning, let started = startedAt, let row = trackedPrompt else {
            startedAt = nil; trackedPrompt = nil; trackedID = 0
            return nil
        }
        let finished = FinishedCommand(promptRow: row, duration: now - started, id: trackedID)
        startedAt = nil; trackedPrompt = nil; trackedID = 0
        return finished
    }
```

Rewrite the old three-argument `observe` as `observe(bottomPromptRow:outputStarted:runningID: 0, now:)` followed by `guard let f, f.duration >= minimumDuration else { return nil }; return f`.

Add:

```swift
/// Whether a finished command is worth interrupting the user about.
public enum CommandNotificationRule {
    /// Armed by hand wins over everything: the user asked. Otherwise the old rule -- long enough
    /// to have looked away from, and the window not in front.
    public static func shouldNotify(_ finished: FinishedCommand, armed: Set<UInt32>,
                                    windowFocused: Bool, minimumDuration: Double) -> Bool {
        if finished.id != 0 && armed.contains(finished.id) { return true }
        return !windowFocused && finished.duration >= minimumDuration
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --no-parallel --filter CommandWatcher 2>&1 | tail -3` → green.

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Shell/CommandWatcher.swift Tests/NyxCoreTests/CommandWatcherTests.swift
git commit -m "A notification can be armed for one command, however short"
```

---

### Task 7: Blocks survive a relaunch

**Files:**
- Modify: `Sources/NyxCore/Session/Transcript.swift` (`transcript(rows:options:)`, line 47)
- Test: `Tests/NyxCoreTests/TranscriptTests.swift`

**Interfaces:**
- Consumes: `Row.promptMark`, `Row.inputStartColumn`, `Row.exitStatus`.
- Produces: a transcript whose `feed` reproduces `promptMark`, `inputStartColumn`, `exitStatus`, `commandStatus` (and therefore `commandID`, re-assigned in order). `Transcript.Options.plainText` emits no marks.

- [ ] **Step 1: Write the failing tests**

Append to `TranscriptTests.swift`:

```swift
private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

@Test func promptMarksRoundTripThroughTheTranscript() {
    let original = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    original.feed(mark("A") + "$ " + mark("B") + "make\r\n" + mark("C") + "ok\r\n" + mark("D", 3))
    original.feed(mark("A") + "$ ")
    let restored = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    restored.feed(original.transcript())

    #expect(restored.shellEmitsPromptMarks)
    #expect(restored.promptMarks(atAbsoluteRow: 0) == [.promptStart, .commandStart])
    #expect(restored.absoluteRow(0)?.inputStartColumn == 2)
    #expect(restored.promptMarks(atAbsoluteRow: 1).contains(.outputStart))
    let region = restored.command(containingAbsoluteRow: 0)
    #expect(region?.exitStatus == 3)
    #expect(region?.outputRows == 1..<2)
    #expect(region?.id == 1)
}

@Test func aPlainTextTranscriptCarriesNoMarks() {
    let t = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "ls\r\n" + mark("C") + "a\r\n" + mark("D", 0) + mark("A") + "$ ")
    #expect(!t.transcript(options: .plainText).contains("133;"))
}
```

`PromptMarks` option-set names: `.promptStart` (A), `.commandStart` (B), `.outputStart` (C), `.commandDone` (D) — confirm against `PromptMarks.swift` lines 15–25.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter Transcript 2>&1 | tail -5` → the two new tests fail (`restored.shellEmitsPromptMarks` is false).

- [ ] **Step 3: Emit the marks**

In `transcript(rows:options:)`, inside the per-row loop, before `var column = 0`:

```swift
            // The shell's own marks, put back where they were, so a restored session still knows
            // where each command began and how it ended. `D` first: it belongs to the command
            // above, and a restored `D` after this row's `A` would close the wrong one.
            if options.includeAttributes {
                let marks = PromptMarks(rawValue: row.promptMark)
                if marks.contains(.commandDone) {
                    out += row.exitStatus.map { "\u{1b}]133;D;\($0)\u{7}" } ?? "\u{1b}]133;D\u{7}"
                }
                if marks.contains(.promptStart) { out += "\u{1b}]133;A\u{7}" }
                if marks.contains(.outputStart) { out += "\u{1b}]133;C\u{7}" }
            }
```

and inside the column loop, at the top of each iteration before `let cell = row.cells[column]`:

```swift
                if options.includeAttributes, column == row.inputStartColumn { out += "\u{1b}]133;B\u{7}" }
```

Also after the loop, for the case where `inputStartColumn` is past the last content column (a prompt with nothing typed yet, where `B` sits at the end): `if options.includeAttributes, let b = row.inputStartColumn, b > lastContentColumn { out += String(repeating: " ", count: b - lastContentColumn - 1) + "\u{1b}]133;B\u{7}" }`.

The parser's `case 133:` writes `C` on the cursor row; a `C` at column 0 of the output row is exactly where zsh puts it. `D` on the parser side calls `recordCommandStatus`, which walks back to the owning prompt — the same path as live.

- [ ] **Step 4: Run the tests**

Run: `swift test --no-parallel --filter Transcript 2>&1 | tail -3` → green, existing round-trip tests included.
Run: `swift test --no-parallel --filter Session 2>&1 | tail -3` → green (session restore feeds this transcript).

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Session/Transcript.swift Tests/NyxCoreTests/TranscriptTests.swift
git commit -m "A restored session keeps its command blocks"
```

---

### Task 8: Actions, chord, menu and palette

**Files:**
- Modify: `Sources/NyxCore/Config/KeyBinding.swift` (`TerminalAction` cases line 24; `defaults` line 164)
- Modify: `Sources/NyxCore/Config/ActionCatalog.swift` (titles line 57; `sections` Go section line 101)
- Modify: `Sources/NyxApp/TabController.swift` (`perform` line 1341; `canPerform` line 1388)
- Modify: `Sources/NyxApp/Pane.swift` (three new methods; full wiring lands in Task 9, but the methods compile here)
- Modify: `docs/configuration.md` (bindings table lines 115–122)
- Test: `Tests/NyxCoreTests/KeyBindingTests.swift`, `Tests/NyxCoreTests/ActionCatalogTests.swift`

**Interfaces:**
- Produces: `TerminalAction.copyBlockMarkdown = "copy_block_markdown"`, `.saveCommandOutput = "save_command_output"`, `.notifyWhenDone = "notify_when_done"`; default binding `⌘⇧↑ → .foldCommand`; `Pane.copyLastCommandAsMarkdown() -> Bool`, `Pane.saveLastCommandOutput() -> Bool`, `Pane.armNotificationForRunningCommand() -> Bool`, `Pane.hasRunningCommand: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `KeyBindingTests.swift`:

```swift
@Test func foldCommandHasADefaultChord() {
    let table = KeyBindingTable(user: [])
    #expect(table.binding(for: .foldCommand) == KeyBinding(key: .up, modifiers: [.cmd, .shift], action: .foldCommand))
}

@Test func theNewBlockActionsParseFromTheConfigSpelling() {
    #expect(p("cmd+shift+m=copy_block_markdown")?.action == .copyBlockMarkdown)
    #expect(p("cmd+shift+s=save_command_output")?.action == .saveCommandOutput)
    #expect(p("cmd+shift+n=notify_when_done")?.action == .notifyWhenDone)
}
```

(`table.binding(for:)` is what `Pane.actionItem` uses; if the table's lookup has a different name, use that one.) `ActionCatalogTests.everyActionAppearsInTheMenuExactlyOnce` fails automatically until the cases are in `sections`; no new test is needed there, but add:

```swift
@Test func blockActionsSitTogetherInTheGoMenu() {
    let go = ActionCatalog.sections.first { $0.title == "Go" }!
    #expect(go.actions.contains(.copyBlockMarkdown))
    #expect(go.actions.contains(.saveCommandOutput))
    #expect(go.actions.contains(.notifyWhenDone))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter 'KeyBinding|ActionCatalog' 2>&1 | grep error | head -3`
Expected: `has no member 'copyBlockMarkdown'`.

- [ ] **Step 3: Add the cases, titles, sections and chord**

`KeyBinding.swift` line 24–25:

```swift
    case foldCommand = "fold_command", foldAllLongOutput = "fold_all_long_output"
    case copyBlockMarkdown = "copy_block_markdown", saveCommandOutput = "save_command_output"
    case notifyWhenDone = "notify_when_done"
    case saveScrollback = "save_scrollback"
```

`defaults` (line 164, before the closing `]`):

```swift
        KeyBinding(key: .up, modifiers: [.cmd, .shift], action: .foldCommand),
```

`ActionCatalog.swift` titles:

```swift
        case .copyBlockMarkdown: return "Copy Last Command as Markdown"
        case .saveCommandOutput: return "Save Last Command Output\u{2026}"
        case .notifyWhenDone: return "Notify When the Running Command Finishes"
```

Go section:

```swift
            Group([.selectCommandOutput, .copyCommandOutput, .copyBlockMarkdown, .saveCommandOutput]),
            Group([.editAndRunCommand]),
            Group([.foldCommand, .foldAllLongOutput]),
            Group([.notifyWhenDone]),
```

- [ ] **Step 4: Wire the pane methods and `perform`**

`Pane.swift`, next to `copyLastCommandOutput()`:

```swift
    /// `copy_block_markdown`: the last finished command and its output, fenced, for a chat or a ticket.
    @discardableResult
    func copyLastCommandAsMarkdown() -> Bool {
        let markdown: String? = session.withTerminal { t in
            guard let region = t.lastFinishedCommand else { return nil }
            return BlockExport.markdown(command: t.commandText(of: region), output: t.outputText(of: region))
        }
        guard let markdown else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        return true
    }

    /// `save_command_output`: the last finished command's output to a file the user names.
    @discardableResult
    func saveLastCommandOutput() -> Bool {
        let id: UInt32? = session.withTerminal { $0.lastFinishedCommand?.id }
        guard let id else { return false }
        saveOutput(ofCommand: id)
        return true
    }

    /// The output of one block, through a save panel. Shared by the action and the ⋯ menu.
    func saveOutput(ofCommand id: UInt32) {
        guard let window else { return }
        let text: String = session.withTerminal { t in
            guard let row = t.promptRow(ofCommand: id), let region = t.command(containingAbsoluteRow: row)
            else { return "" }
            return t.outputText(of: region)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "output.txt"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = []
        panel.message = "Save this command\u{2019}s output."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Commands whose end the user asked to be told about, by id. See `CommandNotificationRule`.
    private var armedNotifications: Set<UInt32> = []

    var hasRunningCommand: Bool { session.withTerminal { $0.runningCommand != nil } }

    /// `notify_when_done`: arm a notification for the command running now. Returns false at a prompt.
    @discardableResult
    func armNotificationForRunningCommand() -> Bool {
        guard let id: UInt32 = session.withTerminal({ $0.runningCommand?.id }) else { return false }
        setNotification(armed: !armedNotifications.contains(id), forCommand: id)
        return true
    }

    func setNotification(armed: Bool, forCommand id: UInt32) {
        if armed { armedNotifications.insert(id) } else { armedNotifications.remove(id) }
        markDirty()
    }
```

`TabController.perform`:

```swift
        case .copyBlockMarkdown: if focusedPane?.copyLastCommandAsMarkdown() != true { NSSound.beep() }
        case .saveCommandOutput: if focusedPane?.saveLastCommandOutput() != true { NSSound.beep() }
        case .notifyWhenDone: if focusedPane?.armNotificationForRunningCommand() != true { NSSound.beep() }
```

`canPerform`: add `.copyBlockMarkdown, .saveCommandOutput` to the `hasPromptMarks` case list; add `case .notifyWhenDone: return focusedPane?.hasRunningCommand ?? false`.

`docs/configuration.md` bindings table: change the `fold_command` row to `| \`fold_command\` / \`fold_all_long_output\` | ⌘⇧↑ / — | Fold the current command's output, keeping its last lines / fold every long one |` and add:

```
| `copy_block_markdown` | — | The last command and its output as a fenced Markdown block |
| `save_command_output` | — | Writes the last command's output to a file the user chooses |
| `notify_when_done` | — | Arm a notification for the command running now, however short it turns out |
```

- [ ] **Step 5: Run the tests and the build**

Run: `swift test --no-parallel --filter 'KeyBinding|ActionCatalog' 2>&1 | tail -3` → green.
Run: `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/NyxCore/Config/KeyBinding.swift Sources/NyxCore/Config/ActionCatalog.swift \
        Sources/NyxApp/TabController.swift Sources/NyxApp/Pane.swift docs/configuration.md \
        Tests/NyxCoreTests/KeyBindingTests.swift Tests/NyxCoreTests/ActionCatalogTests.swift
git commit -m "Fold has a key; Markdown, save-output and notify-when-done are actions"
```

---

### Task 9: The pane: hover, chevron, tint, timer, auto-fold, notifications

**Files:**
- Modify: `Sources/NyxApp/Pane.swift` — `render()` (line 573), `updateHover`/`clearHover` (line 1320), `mouseUp` (line 1063), `checkForFinishedCommand` (line 1811), stored properties (line 80–95)

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces (for Task 10): `Pane.hoveredBlock: BlockHover?`; `Pane.headerForHoveredBlock: BlockHeader?`; `Pane.perform(_ action: BlockAction, on id: UInt32)`; `Pane.toggleFold(ofCommand id: UInt32, full: Bool)`; `Pane.overlayOrigin(forHeaderRow: Int) -> NSPoint` (top-right of the row, in view coordinates).

No unit tests target this file (there is no App test target, on purpose); rung 6 in Task 11 drives it. Keep every `if` here a conversion; the decisions were made in Core.

- [ ] **Step 1: Stored state**

After `foldRowsOnScreen`:

```swift
    /// The block under the pointer, resolved by `BlockHover` on each cell the pointer crosses.
    private(set) var hoveredBlock: BlockHover?
    /// The headers built for the last frame, by visible row, so a click on a summary can be resolved
    /// and the overlay can be fed without another walk.
    private var headersOnScreen: [Int: BlockHeader] = [:]
    /// The cell range of each summary on its row, for the chevron click target.
    private var summaryColumnsOnScreen: [Int: Range<Int>] = [:]
    /// Ticks once a second while a running command's row is on screen, so its elapsed time moves.
    private var runningTimer: Timer?
    /// Whether a command was running at the last check, to notice the moment a new one starts.
    private var commandWasRunning = false
```

- [ ] **Step 2: Build headers and the tint in `render()`**

Replace the `summaries = blocks.compactMap { ... }` block with:

```swift
            let now = t.now()
            var headers: [Int: BlockHeader] = [:]
            var summaryColumns: [Int: Range<Int>] = [:]
            summaries = blocks.compactMap { block -> (row: Int, text: String, color: RGB)? in
                guard block.showsHeader, let row = screenRow(block.region.promptRow) else { return nil }
                let header = block.header(now: now, folding: self.folding,
                                          notifyArmed: self.armedNotifications.contains(block.region.id),
                                          anyFolds: !self.folding.isEmpty)
                headers[row] = header
                let text = header.summaryWithChevron
                guard !text.isEmpty else { return nil }
                summaryColumns[row] = (t.cols - text.count)..<t.cols
                // The overlay draws its own copy of the summary while it covers this row.
                if self.hoveredBlock?.headerRow == row { return nil }
                return (row: row, text: text,
                        color: block.failed ? failedColor : t.palette.noteForeground)
            }
            self.headersOnScreen = headers
            self.summaryColumnsOnScreen = summaryColumns
            anyRunningOnScreen = blocks.contains { $0.isRunning && $0.showsHeader }
```

declare `var anyRunningOnScreen = false` beside `var sticky`, and pass `highlightedRows: self.hoveredBlock?.rows` into the `RenderFrame(...)` call. After the frame is built (outside the lock), manage the timer:

```swift
        if anyRunningOnScreen, runningTimer == nil {
            runningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.markDirty() }
        } else if !anyRunningOnScreen, let timer = runningTimer {
            timer.invalidate()
            runningTimer = nil
        }
```

Invalidate the timer in `viewWillMove(toWindow:)`'s teardown next to `displayLink?.invalidate()` (lines 382 and 393).

The auto-fold trigger and notification arming go in `checkForFinishedCommand`:

```swift
    private func checkForFinishedCommand() {
        let now = Date.timeIntervalSinceReferenceDate
        let bottom: (row: Int?, started: Bool, runningID: UInt32, previous: CommandRegion?) = session.withTerminal { t in
            guard t.totalRows > 0, let region = t.command(containingAbsoluteRow: t.totalRows - 1)
            else { return (nil, false, 0, nil) }
            return (region.promptRow, region.outputStart != nil, t.runningCommand?.id ?? 0,
                    region.outputStart != nil ? t.lastFinishedCommand : nil)
        }
        // The moment a new command starts running is when the one before it is "done with", and
        // the only moment automatic folding is allowed to touch it.
        if bottom.started, !commandWasRunning, config.foldLongOutput > 0, let previous = bottom.previous,
           folding.autoFold(previous, longerThan: config.foldLongOutput, keep: config.foldKeepLines) {
            markDirty()
        }
        commandWasRunning = bottom.started
        guard let finished = commandWatcher.observe(bottomPromptRow: bottom.row, outputStarted: bottom.started,
                                                    runningID: bottom.runningID, now: now) else { return }
        let armed = armedNotifications
        armedNotifications.remove(finished.id)
        guard CommandNotificationRule.shouldNotify(finished, armed: armed,
                                                   windowFocused: window?.isKeyWindow == true,
                                                   minimumDuration: commandWatcher.minimumDuration) else { return }
        let described: (text: String, status: Int32?) = session.withTerminal { t in
            guard let region = t.command(containingAbsoluteRow: finished.promptRow) else { return ("", nil) }
            return (t.commandText(of: region), region.exitStatus)
        }
        CommandNotifier.shared.post(title: CommandNotification.title(failed: (described.status ?? 0) != 0),
                                    body: CommandNotification.body(command: described.text,
                                                                   exitStatus: described.status))
    }
```

Also prune armed ids alongside folds in `render()`: `if !armedNotifications.isEmpty { armedNotifications = armedNotifications.filter { $0 >= t.oldestCommandID } }`.

- [ ] **Step 3: Hover**

In `updateHover(at:)`, after `lastHoverCell = cell` and before the link hit-test:

```swift
        let hover: BlockHover? = session.withTerminal { t in
            let allowed = CommandBlockChrome.isAllowed(altScreen: t.modes.altScreen,
                                                      mouseReporting: t.modes.mouse != .none,
                                                      hasMarks: t.shellEmitsPromptMarks)
            guard allowed else { return nil }
            let visible = self.visibleRow(at: point)
            return BlockHover.resolve(pointerRow: visible, blocks: t.visibleBlocks(rows: t.rows), allowed: true)
        }
        if hover != hoveredBlock {
            hoveredBlock = hover
            blockHeaderChanged()
            markDirty()
        }
```

With folds on screen `visibleBlocks` reports absolute-derived visible rows while the pointer row is a display slot; map through `foldRowsOnScreen` the way `absoluteRow(forVisibleRow:in:)` does: compute `absolute = absoluteRow(forVisibleRow: visible, in: t)` and pass `pointerRow: absolute.map { $0 - max(0, t.viewportTopRow) }`. In `clearHover()`, set `hoveredBlock = nil`, call `blockHeaderChanged()`, and `markDirty()` when it was non-nil. `blockHeaderChanged()` is defined in Task 10; declare it here as an empty `private func blockHeaderChanged() {}` that Task 10 fills.

Add the pointing-hand rect for the summary: in `updateHoverCursor()`, when `hoveredBlock?.headerRow` is a row with `summaryColumnsOnScreen[row]`, add that rect to `hoveredRect` (make `hoveredRect` an array `[NSRect]` and loop in `resetCursorRects`).

- [ ] **Step 4: The chevron as a click target, and the fold API by id**

In `mouseUp`, before the spine check:

```swift
        if wasEmpty, event.clickCount == 1,
           toggleFoldOnSummary(at: convert(event.locationInWindow, from: nil),
                               full: event.modifierFlags.contains(.option)) { return }
```

```swift
    /// A click on a block's summary -- `exit 1 · 8.8s ▾` -- folds and unfolds it. ⌥ folds fully.
    private func toggleFoldOnSummary(at point: NSPoint, full: Bool) -> Bool {
        guard let row = visibleRow(at: point), let columns = summaryColumnsOnScreen[row],
              let header = headersOnScreen[row], header.hasOutput else { return false }
        let column = Int((Double(point.x) - Double(padding)) / Double(cellSizePoints.width))
        guard columns.contains(column) else { return false }
        toggleFold(ofCommand: header.id, full: full)
        return true
    }

    /// The one place a fold is toggled from a control, so every route agrees on the shape.
    func toggleFold(ofCommand id: UInt32, full: Bool) {
        if full { folding.toggleFull(id) } else { folding.toggle(id, keep: config.foldKeepLines) }
        onFocusRequested?()
        markDirty()
    }
```

Route `foldBlock(atPointInPadding:)`, `gutterClicked`, `toggleFoldOfCurrentCommand` through `toggleFold(ofCommand:full:)` (the gutter and spine pass `full: false`; the keyboard action passes `full: NSEvent.modifierFlags.contains(.option)`).

- [ ] **Step 5: `perform(_:on:)` for the menu**

```swift
    /// Every block action, from the ⋯ menu and the context menu, by command id.
    func perform(_ action: BlockAction, on id: UInt32) {
        let region: CommandRegion? = session.withTerminal { t in
            t.promptRow(ofCommand: id).flatMap { t.command(containingAbsoluteRow: $0) }
        }
        guard let region else { NSSound.beep(); return }
        switch action {
        case .copyCommand:
            let text = session.withTerminal { $0.commandText(of: region) }
            copyToPasteboard(text)
        case .copyOutput:
            let text = session.withTerminal { $0.outputText(of: region) }
            copyToPasteboard(text)
        case .copyMarkdown:
            let md = session.withTerminal { BlockExport.markdown(command: $0.commandText(of: region),
                                                                 output: $0.outputText(of: region)) }
            copyToPasteboard(md)
        case .saveOutput: saveOutput(ofCommand: id)
        case .runAgain:
            let command = session.withTerminal { $0.commandText(of: region) }
            guard !command.isEmpty else { NSSound.beep(); return }
            send(Array((command + "\r").utf8))
        case .editAndRun:
            if !editAndRunCommand(atAbsoluteRow: region.promptRow) { NSSound.beep() }
        case .toggleFold: toggleFold(ofCommand: id, full: NSEvent.modifierFlags.contains(.option))
        case .toggleFoldAll: _ = foldAllLongOutput()
        case .notifyWhenDone(let armed): setNotification(armed: !armed, forCommand: id)
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var headerForHoveredBlock: BlockHeader? {
        guard let row = hoveredBlock?.headerRow else { return nil }
        return headersOnScreen[row]
    }

    /// Top-right corner of a visible row, in view coordinates, for placing the overlay.
    func overlayOrigin(forHeaderRow row: Int) -> NSPoint {
        let cell = cellSizePoints
        return NSPoint(x: bounds.width - padding, y: bounds.height - padding - CGFloat(row + 1) * cell.height)
    }
```

`rerunFromMenu` (line 2058) becomes `perform(.runAgain, on:)` once the context menu carries ids (Task 10); leave it in place until then.

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | grep -E 'warning:|error:' | head` → nothing.
Run: `swift test --no-parallel 2>&1 | tail -3` → green (Core unchanged in this task; this is a compile check).

- [ ] **Step 7: Commit**

```bash
git add Sources/NyxApp/Pane.swift
git commit -m "The pane knows which block the pointer is on, and what a click on its chevron means"
```

---

### Task 10: The overlay, the menus, the strip, the pictures

**Files:**
- Create: `Sources/NyxApp/BlockHeaderView.swift`
- Modify: `Sources/NyxApp/Pane.swift` (`init` line 130; `blockHeaderChanged()`; `contextMenu(at:)` line 1245; accessibility children; sticky update line 747)
- Modify: `Sources/NyxApp/StickyPromptView.swift` (`update(text:failed:palette:font:)` gains `summary:`)
- Modify: `Sources/NyxApp/UISnapshot.swift` (`run` line 27; `stickyPrompt` line 298)
- Modify: `Sources/NyxCore/Shell/StickyPrompt.swift` — no change needed; the summary text comes from `BlockHeader.summary`.

**Interfaces:**
- Produces: `BlockHeaderView.update(header: BlockHeader?, palette: Palette, font: NSFont)`; `BlockHeaderView.onAction: ((BlockAction, UInt32) -> Void)?`; `BlockHeaderView.onToggleFold: ((UInt32, Bool) -> Void)?` (id, full).

- [ ] **Step 1: The view**

```swift
// Sources/NyxApp/BlockHeaderView.swift
import AppKit
import NyxCore

/// The strip that appears over a hovered block's command row: its summary, Copy, ⋯ and the chevron.
///
/// Drawn over the row like `StickyPromptView` is drawn over the top row, and for the same reason:
/// the grid is what the shell sized itself to, and a header row inserted into it would resize the
/// session and break under tmux. Real buttons rather than Metal chrome so tooltips, hover feedback
/// and accessibility come from AppKit, and so the snapshot renderer can draw every state.
///
/// What the strip says and which actions it offers is `BlockHeader` in NyxCore. What is here is
/// layout, colours and the click.
final class BlockHeaderView: NSView {
    var onAction: ((BlockAction, UInt32) -> Void)?
    var onToggleFold: ((UInt32, Bool) -> Void)?

    private let summary = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let moreButton = NSButton(title: "\u{22EF}", target: nil, action: nil)
    private let chevronButton = NSButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()
    private let hairline = NSView()
    private var header: BlockHeader?
    private var palette = Palette.xtermDefault()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        for button in [copyButton, moreButton, chevronButton] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.target = self
            button.setButtonType(.momentaryPushIn)
        }
        copyButton.action = #selector(copyPressed)
        copyButton.toolTip = "Copy this command\u{2019}s output"
        moreButton.action = #selector(morePressed)
        moreButton.toolTip = "More actions for this command"
        moreButton.setAccessibilityLabel("More actions")
        chevronButton.action = #selector(chevronPressed)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        stack.setViews([summary, copyButton, moreButton, chevronButton], in: .center)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        addSubview(hairline)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// nil hides the strip. Compared before applied: this is called once per frame.
    func update(header: BlockHeader?, palette: Palette, font: NSFont) {
        guard let header else {
            if !isHidden { isHidden = true; self.header = nil }
            return
        }
        let changed = header != self.header || palette != self.palette || summary.font != font
        self.header = header
        self.palette = palette
        guard changed else { isHidden = false; return }
        summary.stringValue = header.summary
        summary.font = font
        let failed: Bool = { if case .failed = header.state { return true } else { return false } }()
        summary.textColor = nsColor(failed ? palette.readable(1) : palette.noteForeground, alpha: 1)
        summary.isHidden = header.summary.isEmpty
        copyButton.isEnabled = header.hasOutput
        chevronButton.title = header.chevron
        chevronButton.isHidden = !header.hasOutput
        chevronButton.toolTip = header.folded ? "Unfold this command\u{2019}s output" : "Fold this command\u{2019}s output (\u{2325}: hide all of it)"
        chevronButton.setAccessibilityLabel(header.title(for: .toggleFold))
        for button in [copyButton, moreButton, chevronButton] { button.contentTintColor = nsColor(palette.foreground, alpha: 1) }
        layer?.backgroundColor = nsColor(palette.background, alpha: 1).cgColor
        hairline.layer?.backgroundColor = nsColor(palette.noteForeground, alpha: 1).cgColor
        isHidden = false
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { stack.fittingSize }

    @objc private func copyPressed() { if let header { onAction?(.copyOutput, header.id) } }
    @objc private func chevronPressed() {
        guard let header else { return }
        onToggleFold?(header.id, NSEvent.modifierFlags.contains(.option))
    }

    @objc private func morePressed() {
        guard let header else { return }
        let menu = NSMenu()
        for (index, entry) in header.actions.enumerated() {
            if index > 0 && entry.action.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: header.title(for: entry.action), action: #selector(menuPressed(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = entry.enabled
            if case .notifyWhenDone(let armed) = entry.action { item.state = armed ? .on : .off }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    @objc private func menuPressed(_ sender: NSMenuItem) {
        guard let header, header.actions.indices.contains(sender.tag) else { return }
        onAction?(header.actions[sender.tag].action, header.id)
    }

    override func isAccessibilityElement() -> Bool { false }   // the buttons are the elements
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { header.map { "Command block: \($0.summary)" } }
}
```

`nsColor(_:alpha:)` exists in the app target (StickyPromptView uses it); if it is file-private there, move it to `Accessibility.swift`'s neighbour `Colors.swift` or make it `internal`.

- [ ] **Step 2: Host it in the pane**

In `Pane.init` after `addSubview(stickyStrip)`:

```swift
        blockHeader.onAction = { [weak self] action, id in self?.perform(action, on: id) }
        blockHeader.onToggleFold = { [weak self] id, full in self?.toggleFold(ofCommand: id, full: full) }
        addSubview(blockHeader)
```

with `private let blockHeader = BlockHeaderView(frame: .zero)` beside `stickyStrip`. Fill `blockHeaderChanged()`:

```swift
    /// Places the overlay over the hovered block's command row, or hides it.
    private func blockHeaderChanged() {
        guard let row = hoveredBlock?.headerRow, let header = headersOnScreen[row] else {
            blockHeader.update(header: nil, palette: session.withTerminal { $0.palette },
                               font: .monospacedSystemFont(ofSize: effectiveFontSize, weight: .regular))
            return
        }
        blockHeader.update(header: header, palette: session.withTerminal { $0.palette },
                           font: .monospacedSystemFont(ofSize: effectiveFontSize, weight: .regular))
        let size = blockHeader.intrinsicContentSize
        let origin = overlayOrigin(forHeaderRow: row)
        blockHeader.frame = NSRect(x: origin.x - size.width, y: origin.y,
                                   width: size.width, height: cellSizePoints.height)
        window?.invalidateCursorRects(for: self)
    }
```

Call `blockHeaderChanged()` at the end of `render()` (after `stickyStrip.update`) so a running command's timer and a fold toggle refresh the overlay's text; `update` compares before it applies, so this is cheap.

- [ ] **Step 3: The context menu carries the block group**

In `contextMenu(at:)`, replace the `if let point, let row = commandRow(under: point)` block with:

```swift
        if let point, let id = commandID(under: point) {
            let header: BlockHeader? = session.withTerminal { t in
                guard let row = t.promptRow(ofCommand: id),
                      let region = t.command(containingAbsoluteRow: row) else { return nil }
                let block = CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true)
                return block.header(now: t.now(), folding: self.folding,
                                    notifyArmed: self.armedNotifications.contains(id), anyFolds: !self.folding.isEmpty)
            }
            if let header {
                for (index, entry) in header.actions.enumerated() {
                    if index > 0 && entry.action.startsGroup { menu.addItem(.separator()) }
                    let item = NSMenuItem(title: header.title(for: entry.action),
                                          action: #selector(blockActionFromMenu(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = BlockMenuEntry(action: entry.action, id: id)
                    item.isEnabled = entry.enabled
                    if case .notifyWhenDone(let armed) = entry.action { item.state = armed ? .on : .off }
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
        }
```

with:

```swift
    private final class BlockMenuEntry: NSObject {
        let action: BlockAction; let id: UInt32
        init(action: BlockAction, id: UInt32) { self.action = action; self.id = id }
    }

    private func commandID(under point: NSPoint) -> UInt32? {
        session.withTerminal { t in
            guard t.shellEmitsPromptMarks else { return nil }
            let position = self.position(topLeft(point), in: t)
            let id = t.command(containingAbsoluteRow: position.row)?.id ?? 0
            return id == 0 ? nil : id
        }
    }

    @objc private func blockActionFromMenu(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? BlockMenuEntry else { return }
        perform(entry.action, on: entry.id)
    }
```

Set `menu.autoenablesItems = false` for this menu, and in `validateMenuItem` return `item.isEnabled` for `blockActionFromMenu`. Delete `editAndRunFromMenu`, `rerunFromMenu` and `commandRow(under:)` (now unused; `editAndRunCommand(atAbsoluteRow:)` stays).

- [ ] **Step 4: Accessibility for the chevron drawn in Metal**

In `Pane`, add:

```swift
    override func accessibilityChildren() -> [Any]? {
        var children = subviews.filter { !$0.isHidden } as [Any]
        let cell = cellSizePoints
        for (row, columns) in summaryColumnsOnScreen {
            guard let header = headersOnScreen[row], header.hasOutput else { continue }
            let frame = NSRect(x: padding + CGFloat(columns.lowerBound) * cell.width,
                               y: bounds.height - padding - CGFloat(row + 1) * cell.height,
                               width: CGFloat(columns.count) * cell.width, height: cell.height)
            children.append(DrawnControlElement.make(
                label: "\(header.title(for: .toggleFold)) of the command on line \(row + 1)",
                role: .button, frame: frame, in: self,
                press: { [weak self] in self?.toggleFold(ofCommand: header.id, full: false) }))
        }
        return children
    }
```

If `Pane` already overrides `accessibilityChildren` for the search bar or the sticky strip, merge into it rather than adding a second override.

- [ ] **Step 5: The sticky strip gets the summary**

`StickyPromptView.update(text:failed:palette:font:)` → `update(text:summary:failed:palette:font:)`: add a second label `note` right-aligned (`trailingAnchor` −6, `centerY`), coloured `palette.noteForeground` (or `readable(1)` when failed), set to `summary`, hidden when empty; include `summary` in `shown`. In `Pane.render()`, compute the summary for the pinned command: after `sticky = (...)`, look up `t.command(containingAbsoluteRow: pinned.row)` (already `region`), build `CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true).header(now:..., folding: self.folding, notifyArmed: false, anyFolds: !self.folding.isEmpty).summary`, and pass it. Update the `UISnapshot.stickyPrompt` call and the `StickyPromptView` callers.

- [ ] **Step 6: Snapshot cases**

In `UISnapshot.run`, after the sticky prompt cases:

```swift
        for (name, header) in blockHeaderStates() {
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let view = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
                view.appearance = NSAppearance(named: appearance)
                view.update(header: header, palette: palette, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                let size = view.intrinsicContentSize
                view.frame = NSRect(x: 0, y: 0, width: size.width, height: 20)
                view.layoutSubtreeIfNeeded()
                write(view, named: "block-header-\(name)-\(appearance == .aqua ? "light" : "dark")",
                      into: directory, background: palette.background)
            }
        }
        write(stickyPrompt(palette: palette, failed: true, summary: "exit 2 \u{b7} 8.8s"),
              named: "sticky-prompt-summary", into: directory, background: palette.background)
```

```swift
    private static func blockHeaderStates() -> [(String, BlockHeader)] {
        [
            ("finished", BlockHeader(id: 1, state: .finished, folded: false, hasOutput: true, anyFolds: false, notifyArmed: false, summary: "8.8s")),
            ("failed", BlockHeader(id: 2, state: .failed(status: 1), folded: false, hasOutput: true, anyFolds: false, notifyArmed: false, summary: "exit 1 \u{b7} 8.8s")),
            ("running", BlockHeader(id: 3, state: .running(elapsed: 12), folded: false, hasOutput: true, anyFolds: false, notifyArmed: true, summary: "12s")),
            ("folded", BlockHeader(id: 4, state: .finished, folded: true, hasOutput: true, anyFolds: true, notifyArmed: false, summary: "8.8s")),
            ("no-output", BlockHeader(id: 5, state: .finished, folded: false, hasOutput: false, anyFolds: false, notifyArmed: false, summary: "")),
        ]
    }
```

(`BlockHeader.init` must be `public` with exactly these labels; Task 4 defines it so.)

- [ ] **Step 7: Build, render, look**

Run: `swift build 2>&1 | grep -E 'warning:|error:' | head` → nothing.
Run: `./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/shots ./build/Nyx.app/Contents/MacOS/Nyx && ls /tmp/shots | grep -E 'block-header|sticky-prompt-summary'` → eleven files.
Read each `block-header-*.png` and `sticky-prompt-summary.png` with the Read tool. Check: the summary is legible in both appearances, the chevron is the small triangle, the running state shows `12s` with a checkmark-able ⋯, the no-output state shows Copy disabled and no chevron, nothing is clipped.

- [ ] **Step 8: Commit**

```bash
git add Sources/NyxApp/BlockHeaderView.swift Sources/NyxApp/Pane.swift Sources/NyxApp/StickyPromptView.swift \
        Sources/NyxApp/UISnapshot.swift
git commit -m "Hover a block and it shows what you can do to it"
```

---

### Task 11: Prove it on a real path, document it, get it reviewed

**Files:**
- Temporary: `Sources/NyxApp/AppDelegate.swift` (removed before commit)
- Modify: `README.md` ("Because it knows where commands begin and end"), `docs/status.md` (Done table "On prompt marks" row; competition table "Command blocks" row), `docs/architecture.md` ("Where to add things": a row `A block header state | \`BlockHeader\` in \`Shell/CommandBlock.swift\` | \`BlockHeaderView\`, \`Pane.blockHeaderChanged\` | \`BlockHeaderTests\`, a \`UISnapshot\` case`), `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md` §11 (mark "блоки команд" closed on 2026-09-05 with a pointer to the v2 spec)

- [ ] **Step 1: Rung 6 hook**

In `AppDelegate.applicationDidFinishLaunching`, gated on `ProcessInfo.processInfo.environment["NYX_SMOKE_QA"] == "blocks"`: open a window, get its focused `Pane`, feed the session a scripted transcript with marks (`printf` of the same bytes `CommandIDTests.session()` uses, through `session.feed` or by writing to the PTY), then:

1. Call `pane.updateHover(at:)` with a point on the block's output row (expose a `func smokeHover(_ p: NSPoint)` temporarily) and print `pane.hoveredBlock` and whether `blockHeader.isHidden` is false and its `accessibilityChildren()` count.
2. Post a `⌘⇧↑` `NSEvent` to `pane.keyDown` and print `pane.folding` (temporary accessor) — expected `.tail(keep: 3)` on the last finished command's id.
3. Call `pane.perform(.copyMarkdown, on: id)` and print `NSPasteboard.general.string(forType: .string)` — expected a fenced block starting with `$ `.
4. Call `pane.perform(.notifyWhenDone, on: runningID)` while a `sleep 2` runs and print whether `CommandNotifier.shared.post` was reached (temporary print in `post`).
5. `exit(0)`.

Run: `./scripts/bundle.sh && NYX_SMOKE_QA=blocks ./build/Nyx.app/Contents/MacOS/Nyx 2>&1 | grep SMOKE`. Paste the printed lines into the task report.

- [ ] **Step 2: Remove the hook**

Delete the hook and every temporary accessor. Run: `git diff --stat` → only documentation files below may appear.

- [ ] **Step 3: The ladder**

```
swift build 2>&1 | grep -c warning:                      # 0
pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel 2>&1 | tail -3
make bench; make bench; make bench                       # each ≥ 180
NYX_UI_SNAPSHOT=/tmp/shots ./build/Nyx.app/Contents/MacOS/Nyx   # look at block-header-*, sticky-prompt-*
NYX_SNAPSHOT=1 swift test --filter Snapshot 2>&1 | tail -3
NYX_RENDER_STATS=1 ./build/Nyx.app/Contents/MacOS/Nyx    # hover a block for a few seconds: rebuilt rows stay ~0 % while nothing prints
```

- [ ] **Step 4: Documentation**

README, replace the bullets under "Because it knows where commands begin and end" with:

```
- A command and its output are a block: a spine beside the rows it owns, and `exit 1 · 8.8s ▾`
  at the end of its command line. Click the chevron to fold the output down to its last three
  lines (⌥-click hides all of it); click the placeholder to bring it back. `⌘⇧↑` folds from the
  keyboard.
- Hover a block and it shows what you can do to it: Copy, and a `⋯` menu with the command, the
  output, both as a Markdown block, the output to a file, run again, edit and run.
- A running command counts up on its own row. "Notify When Done" on it asks for a notification
  whatever it takes, however long or short; otherwise you get one when something took a while
  and you were elsewhere.
- `⌘↑` / `⌘↓` jump between prompts; a gutter marks each command green or red; the command line
  you are reading stays pinned at the top, with its status, while you scroll its output.
- Blocks come back after a relaunch, because the session's scrollback is saved with its marks.
```

`docs/status.md`: in the Done table replace the "On prompt marks" row's state with `⌘↑/⌘↓, status gutter, blocks with a chevron and a hover header (Copy, ⋯ menu), tail folds keyed by command id, live timer, armed notifications, Markdown export, sticky command line with status, blocks restored with the session`. In the competition table replace the "Command blocks" row with `| Command blocks: hover header, tail fold, live timer, Markdown export | yes, from OSC 133, no account | marks only | marks + some | marks only | yes, proprietary, breaks in tmux |`.

Spec §11: after the "Этап 3" paragraph add `**Блоки команд закрыты 2026-09-05** второй итерацией: \`docs/superpowers/specs/2026-09-05-command-blocks-v2-design.md\`.`

- [ ] **Step 5: Commit the docs**

```bash
git add README.md docs/status.md docs/architecture.md docs/superpowers/specs/2026-09-03-nyx-terminal-design.md
git commit -m "Docs: blocks v2, what a user sees and where the code lives"
```

- [ ] **Step 6: Reviews**

Dispatch `code-reviewer` on `git diff main...feat/blocks-v2` with the spec path. Fix Critical and Important findings, commit each fix with its own sentence. Then dispatch `design-reviewer` with the `block-header-*` and `sticky-prompt-*` PNGs. Then dispatch `product-manager` with the spec, the branch and the rung-6 output. Merge only on APPROVED:

```bash
git checkout main
git merge --no-ff feat/blocks-v2 -m "Merge blocks v2: a block you can see, fold, copy and be told about

<test count> tests, bench <n> MB/s at merge."
git push origin main
```

---

## Self-review against the spec

- §4.1 command row: Task 4 (`summaryWithChevron`), Task 5 (chevron glyph), Task 9 (click target, ⌥). ✔
- §4.2 hover tint + overlay + ⋯ menu + context menu: Tasks 4, 5, 9, 10. ✔
- §4.3 tail fold, placeholder button, small-output rule, running block foldable, ⌘⇧↑: Tasks 2, 8, 9. ✔
- §4.4 auto-fold on next `C`, never re-fold by-hand: Tasks 2, 3, 9. ✔
- §4.5 armed notification + action: Tasks 6, 8, 9. ✔
- §4.6 sticky summary: Task 10. ✔
- §4.7 Markdown: Task 4, 8, 9. ✔
- §4.8 transcript marks: Task 7. ✔
- §4.9 failure faces: `canPerform` (Task 8), `hasOutput` gating (Task 4/10), `isAllowed` gating in hover (Task 9). ✔
- §5.9 partial-redraw scenario, pixel tests, palette test: Task 5. ✔
- §5.11 test list: every named file has a task; `CommandIDTests`, `OutputFoldingTests`, `BlockHeaderTests`, `BlockHoverTests`, `BlockExportTests`, `CommandNotificationRule` tests (inside `CommandWatcherTests`), `TranscriptTests`, config/diff/binding/catalog tests. ✔
- §7 docs: Task 11. ✔

Type consistency checked: `FoldShape`, `OutputFolding.toggle(_:keep:)`, `toggleFull(_:)`, `prune(olderThan:)`, `autoFold(_:longerThan:keep:)`, `BlockHeader(id:state:folded:hasOutput:anyFolds:notifyArmed:summary:)`, `CommandBlock.header(now:folding:notifyArmed:anyFolds:)`, `BlockHover.resolve(pointerRow:blocks:allowed:)`, `CommandRegion(promptRow:outputStart:endRow:exitStatus:duration:id:startedAt:)`, `FinishedCommand(promptRow:duration:id:)`, `CommandWatcher.observe(bottomPromptRow:outputStarted:runningID:now:)`, `Pane.perform(_:on:)`, `Pane.toggleFold(ofCommand:full:)`, `BlockHeaderView.update(header:palette:font:)` are used with the same names in every task that mentions them.
