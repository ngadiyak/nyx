# Curl Workbench — Response Side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An HTTP block's output can be read through lenses (pretty JSON with folding, headers, body, a jq-style filter, grep, a diff against the previous run) and a request can be watched, repeated or polled, each run an ordinary block with a timeline and latency percentiles on the newest one.

**Architecture:** `JSONDocument` (tolerant tree, pretty printer with fold points, path subset), `ResponseLens` → `[LensLine]`, `LensBuffer` → `Row`s, `LensChoices` keyed by command id like `OutputFolding`, and a new `DisplayRow.lens` case mapped by `Terminal.displayRows`; `WatchSeries` is a clock-injected state machine. `Pane` computes lens rows off the main thread, caches them per (command id, content version, lens), draws them through the ordinary row path, and schedules watch runs by typing the command when the shell is at a prompt. Builds on the request plan (`2026-09-06-curl-workbench-request.md`): `HTTPExchange`, `CurlDetection`, `RequestRun`, `RequestEditor`'s `onWatch`, the `toggle_http_lens` / `stop_watch` actions and `http-lens` / `http-watch-interval` keys already exist.

**Tech Stack:** Swift 6.0.3 in Swift 5 mode, SwiftPM, swift-testing, AppKit, Metal (unchanged); no new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-06-curl-workbench-design.md` (§6.2, §6.3, §7 and the Core half of §10 are this plan's).

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY. `NyxRender` learns nothing about lenses: lens rows are `Row`s.
- Tests are swift-testing; hoist mutating calls out of `#expect`. Hang fix: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`.
- Warning-free build (library and tests); `make bench` ≥ 180 MB/s; lens computation never runs on the render path — the pane's frame builder only reads cached rows.
- Limits, verbatim: lenses apply to bodies up to 2 MB or 20,000 lines; above that the block stays raw and the menu says "Body too large for lenses — Save Output…". A 2 MB JSON body pretty-prints under 200 ms off-thread.
- Watch rules, verbatim: the next run is sent only when the shell is at a prompt; if the previous run is still running when the interval elapses the series waits for it and then runs immediately; a series stops on its plan, on ⌘. while its block is the latest HTTP block, on the Stop button, when the pane closes, and when the user types anything at the prompt. Every run but the newest is folded `.all` by the series (respecting `openedByHand`), except a run whose status class differs from the previous run's.
- Copy: `LensLine` styles are `key`, `string`, `number`, `literal`, `header`, `added`, `removed`, `dim`, `match`; the fold placeholder inside a lens reads `▸ {…} 12 keys` / `▸ […] 40 items`.
- Commit trailers on every commit (`Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, `Claude-Session: https://claude.ai/code/session_01YHJ5Uc1qA7f7FHixuhp8Gy`); `git add` by name; never touch `CLAUDE.md`, `.claude/`, `docs/testing.md`, `docs/workflow.md`, `docs/checklist.md`.

---

### Task 1: `JSONDocument` — tree, pretty printer, fold points, path subset

**Files:**
- Create: `Sources/NyxCore/HTTP/JSONDocument.swift`, `Sources/NyxCore/HTTP/JSONPath.swift`
- Test: `Tests/NyxCoreTests/JSONDocumentTests.swift`, `Tests/NyxCoreTests/JSONPathTests.swift`

**Interfaces:**
```swift
public indirect enum JSONValue: Equatable {
    case object([(key: String, value: JSONValue)])   // order preserved; make Equatable via a Member struct
    case array([JSONValue]); case string(String); case number(String)   // numbers kept as written
    case bool(Bool); case null
}
public enum JSONDocument {
    public static func parse(_ text: String) -> JSONValue?          // own recursive-descent parser: preserves key order and number spelling; tolerant of a trailing newline and a UTF-8 BOM; rejects everything else
    public struct PrettyLine: Equatable {
        public let text: String                                     // with 2-space indent already applied
        public let depth: Int
        public let spans: [(range: Range<Int>, style: LensStyle)]   // over `text`'s Character offsets
        public let node: NodePath?                                  // set on the opening line of an object/array: the fold key
        public let childCount: Int                                  // keys or items, for the placeholder
    }
    public static func pretty(_ value: JSONValue) -> [PrettyLine]
    public static func pretty(_ value: JSONValue, folded: Set<NodePath>) -> [PrettyLine]   // a folded node prints one line: `"key": ▸ {…} 12 keys` (or `▸ […] 40 items`) with style .dim on the placeholder
}
public struct NodePath: Hashable { public let steps: [Step]; public enum Step: Hashable { case key(String), index(Int) } }
public enum LensStyle: Equatable { case key, string, number, literal, header, added, removed, dim, match }
public enum JSONPath {
    public indirect enum Expr: Equatable { case identity; case key(String); case index(Int); case slice(Int?, Int?); case iterate(optional: Bool); case keys; case length; case recurse(String); case pipe(Expr, Expr); case chain([Expr]) }
    public static func parse(_ s: String) -> Expr?     // `.a.b`, `.a["k y"]`, `.a[0]`, `.a[-1]`, `.a[1:3]`, `.a[]`, `.a[]?.b`, `keys`, `length`, `.[] | .id`, `..name`; anything else nil
    public static func evaluate(_ expr: Expr, on value: JSONValue) -> [JSONValue]   // jq semantics for the subset: iterate fans out; missing key → null unless optional
    public static let unsupportedMessage = "Not supported here — Run with jq"
}
```
- [ ] **Step 1: Tests** — parse: `keepsKeyOrderAndNumberSpelling` (`{"b":1.50,"a":2}`), `rejectsTrailingGarbage`, `acceptsBOMAndNewline`, `nestedDeep` (1,000 levels does not crash — use an explicit stack or depth guard that returns nil above 512). pretty: `objectPrintsTwoSpaceIndent` (exact lines for `{"a":[1,{"b":null}]}`), `spansCoverKeysStringsNumbersLiterals`, `foldedNodePrintsPlaceholder` (`"a": ▸ […] 2 items`), `openingLinesCarryNodePathAndChildCount`, `emptyContainersStayOnOneLine` (`"x": {}`). path: `parsesTheSubset` (one assertion per form), `rejectsOtherJq` (`select(.a)`, `map(.x)`, `.a as $x`), `evaluateKey`, `evaluateIterateFansOut`, `optionalIterateOnNonArrayIsEmpty`, `sliceAndNegativeIndex`, `keysAndLength`, `recurseFindsAllNamed`, `pipe`.
- [ ] **Step 2–4:** fail, implement, pass; a benchmark-style test `prettyPrintsTwoMegabytesQuickly` builds a 2 MB array and asserts `pretty` under 200 ms (`ContinuousClock`), marked `.timeLimit(.minutes(1))`.
- [ ] **Step 5: Commit** — "JSONDocument: a tree that keeps order, a printer that can fold, a path subset".

---

### Task 2: `ResponseLens` — lens lines for every lens

**Files:**
- Create: `Sources/NyxCore/HTTP/ResponseLens.swift`
- Test: `Tests/NyxCoreTests/ResponseLensTests.swift`

**Interfaces:**
```swift
public enum ResponseLens: Equatable {
    case raw, pretty, headers, body
    case filter(String)                    // JSONPath text
    case grep(String)                      // literal, case-insensitive
    case diff(previousCommandID: UInt32)
    public var title: String               // "Raw", "Pretty JSON", "Headers", "Body", "Filter…", "Find in Body…", "Diff with Previous Run"
}
public struct LensLine: Equatable {
    public var text: String
    public var spans: [(range: Range<Int>, style: LensStyle)]
    public var node: NodePath?             // foldable
    public var depth: Int
    public init(_ text: String, spans: [...] = [], node: NodePath? = nil, depth: Int = 0)
}
public struct LensInput: Equatable {
    public var exchange: HTTPExchange
    public var previous: HTTPExchange?     // for .diff
    public var folded: Set<NodePath>
}
public enum LensRendering {
    public static let maxBodyBytes = 2 * 1024 * 1024
    public static let maxBodyLines = 20_000
    public static func isTooLarge(_ exchange: HTTPExchange) -> Bool
    public static func lines(for lens: ResponseLens, input: LensInput) -> [LensLine]?    // nil = show raw (too large, or .filter on a non-JSON body, or .diff without a previous)
    public static func filterError(_ text: String, body: JSONValue?) -> String?           // JSONPath.unsupportedMessage or nil
}
```
Rules: `.pretty` = one `header` line `▸ N headers · content-type: …` (folded by default, `node = NodePath(steps: [.key("$headers")])`; unfolded prints each header as `name: value` with `.header` style) then the pretty body (or the raw body lines when not JSON) then the latency line `142 ms · DNS 3 · connect 12 · TLS 40 · TTFB 120` as `.dim` (omitting parts the sentinel lacks; absent entirely without a sentinel). `.headers` = the final head line, its headers, then for each redirect a `.dim` line `↪ 301 → https://…`. `.body` = pretty body or raw lines. `.filter(p)` = `pretty(evaluate)` for each result separated by nothing (multiple results print consecutively); on parse failure `lines` returns nil and `filterError` explains. `.grep(s)` = body lines containing `s` (case-insensitive) as `"\(lineNumber): \(line)"` with `.match` spans on every occurrence, or one `.dim` line `no matches for "s"`. `.diff` = LCS line diff between `pretty(previous.body)` and `pretty(current.body)` (Myers or a simple DP capped at 5,000×5,000; above that fall back to "changed/unchanged" by line hash): first a `.dim` summary `N lines changed · status A → B · X ms → Y ms`, then lines prefixed `- ` (`.removed`), `+ ` (`.added`), `  ` (unchanged, `.dim` when more than 3 lines from a change: collapse runs of unchanged lines beyond 3 either side into `  … N unchanged lines` `.dim`).

- [ ] **Step 1: Tests** — `prettyStartsWithFoldedHeaders`, `prettyEndsWithLatency`, `prettyOnTextBodyIsRawLines`, `headersListRedirects`, `filterPrintsEachResult`, `filterErrorForUnsupported`, `filterOnTextBodyIsNil`, `grepNumbersAndHighlights`, `grepNoMatches`, `diffSummaryAndMarks` (a 3-line change in a 20-line body: summary says 3, context collapsed), `diffWithoutPreviousIsNil`, `tooLargeIsNil` (20,001 lines).
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5: Commit** — "Response lenses: pretty, headers, body, filter, grep, diff".

---

### Task 3: `LensBuffer`, `LensChoices` and the display mapping

**Files:**
- Create: `Sources/NyxCore/HTTP/LensBuffer.swift`, `Sources/NyxCore/HTTP/LensChoices.swift`
- Modify: `Sources/NyxCore/Shell/OutputFolding.swift` — `DisplayRow.lens(commandID: UInt32, line: Int)`; `Terminal.displayRows(from:count:folding:lenses:)` (new parameter with a default so existing callers compile) maps a lensed command's output rows to `.lens` entries; `foldedCommand`/fold placeholders take precedence over a lens for a folded block (a folded HTTP block shows the fold placeholder, not lens lines); `DisplayRows.indexByAbsoluteRow`, `cursorSlot`, `slots(coveredBy:…)` treat `.lens` like `.fold` (not an absolute row); `snapViewportOutOfFold` gains the lens case (a viewport whose top is inside a lensed region snaps to the region's prompt or its end).
- Test: `Tests/NyxCoreTests/LensBufferTests.swift`, `Tests/NyxCoreTests/LensDisplayRowsTests.swift` (mirror every `OutputFoldingDisplayTests` case with a lens instead of a fold), `LensChoicesTests`

**Interfaces:**
```swift
public struct LensChoices: Equatable {
    public init()
    public func lens(of id: UInt32) -> ResponseLens?                 // nil = raw
    public mutating func set(_ lens: ResponseLens?, for id: UInt32)
    public func folded(in id: UInt32) -> Set<NodePath>
    public mutating func toggleFold(_ node: NodePath, in id: UInt32)
    public mutating func prune(olderThan oldest: UInt32)
    public var isEmpty: Bool
    public var lensedIDs: Set<UInt32>
}
public struct LensBuffer: Equatable {
    public let commandID: UInt32
    public let lens: ResponseLens
    public let lines: [LensLine]
    public let contentVersion: UInt64        // the terminal's, when built — stale when it differs
    public init(commandID:lens:lines:contentVersion:)
    public func row(_ index: Int, cols: Int, palette: LensPalette) -> Row    // wraps nothing: a line longer than cols is cut; the last drawn cell gets `…`
    public var lineCount: Int
    public func line(_ index: Int) -> LensLine?
    public func text(lines: Range<Int>) -> String                            // for copy
}
public struct LensPalette: Equatable {    // Color per LensStyle, in terminal Color terms (indexed): key 4, string 2, number 3, literal 5, header 6, added 2, removed 1, dim 8, match = inverse attr
    public static let standard: LensPalette
}
public extension Terminal {
    func lensedCommand(containingOutputRow row: Int, lenses: LensChoices, buffers: (UInt32) -> LensBuffer?) -> (region: CommandRegion, buffer: LensBuffer)?
    func displayRows(from top: Int, count: Int, folding: OutputFolding, lenses: LensChoices = LensChoices(), buffers: (UInt32) -> LensBuffer? = { _ in nil }) -> [DisplayRow]
}
```
Display rule: for a command with a lens buffer (not folded), the display shows its prompt and command-line rows as `.row`, then `.lens(id, 0…n-1)`, then continues at `region.endRow + 1`. A lensed region with a buffer whose `contentVersion` is stale is still shown (the pane replaces the buffer when the new one is ready). The buffer callback returns nil when no buffer exists yet → the rows show raw.

- [ ] **Step 1: Tests** — choices (`setAndGet`, `toggleFold`, `prune`), buffer (`rowCutsWithEllipsis`, `stylesBecomeColours`, `textOfRange`), display (`lensReplacesOutputRows` — a 5-row output with a 3-line lens yields prompt + 3 lens entries + the next command's prompt; `lensLongerThanOutput` — 2-row output, 10-line lens; `foldWinsOverLens`; `viewportStartingInsideALens` — top inside the region shows lens lines from the right offset; `cursorSlotOnLensedRegionIsNil`; `indexByAbsoluteRowSkipsLens`; `snapOutOfLens`; `noBufferShowsRaw`; `unchangedWhenChoicesEmpty` — byte-identical to the fold-only path).
- [ ] **Step 2–4:** fail, implement, pass; `make bench` unchanged (the no-lens path must add at most one `isEmpty` check).
- [ ] **Step 5: Commit** — "Lens rows in the display: a block's output shown through a lens".

---

### Task 4: Lenses in the pane

**Files:**
- Modify: `Sources/NyxApp/Pane.swift`:
  - state: `lenses = LensChoices()`, `lensBuffers: [UInt32: LensBuffer]`, `lensQueue = DispatchQueue(label: "nyx.lens", qos: .userInitiated)`, `exchanges` cache from the request plan's Task 5;
  - when an HTTP block finishes (the exchange cache gets a new entry) and `config.httpLens == .pretty` and `bodyKind == .json` and `!LensRendering.isTooLarge`, set `lenses.set(.pretty, for: id)`;
  - `rebuildLens(for id:)`: capture `LensInput` (exchange, previous exchange for `.diff`, folded set) and the terminal's `contentVersion`, compute `LensRendering.lines` on `lensQueue`, then on main store the `LensBuffer` and `markDirty()` (rows moved → `renderer.invalidateSlots` the same way a fold opening does);
  - frame building: pass `lenses` and `{ self.lensBuffers[$0] }` to `displayRows`; `.lens(id, i)` → `lensBuffers[id]!.row(i, cols:, palette: LensPalette.standard)`;
  - mouse: a click on a lens line whose `node != nil` toggles the fold (`lenses.toggleFold`, then `rebuildLens`); the pointer over such a line shows a hand cursor; a drag starting on a lens row selects lens lines by (line, column) in a `LensSelection` (NyxCore: `struct LensSelection { commandID, anchor: (line, col), head: (line, col) }` with `text(from: LensBuffer)`), drawn through `RenderFrame.selection` for those slots, and ⌘C copies its text; a drag that starts on a transcript row clears it;
  - hover overlay: `BlockHeader.isHTTP` blocks get a `{ }` control in `OverlayControls.full/.noCopy` (Core: `BlockHeaderView` draws it; `BlockAction.toggleLens`), ⋯ menu group "Lens" with one item per `ResponseLens` case (checkmark on the active one; `Filter…` and `Find in Body…` open a one-line field over the block's command row — a `NSTextField` sheetless popover — evaluating as you type, and showing `JSONPath.unsupportedMessage` with a `Run with jq` button that sends `<the block's command line> | jq '<expr>'` to the shell when the expression is outside the subset; `Diff with Previous Run` enabled when the previous HTTP block with the same `CurlCommand` (parsed equality ignoring `other`) exists), plus "Copy Body", "Copy Headers"; "Body too large for lenses — Save Output…" replaces the group when `isTooLarge`;
  - `toggle_http_lens` action → the block under the pointer, else the last HTTP block: pretty ↔ raw;
  - `Copy Output` on a lensed block copies `buffer.text(lines: 0..<lineCount)`.
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift` (`BlockAction.toggleLens`, `.setLens(ResponseLens)`, `.copyBody`, `.copyHeaders`; `BlockHeader.lens: ResponseLens?`, `BlockHeader.lensTooLarge: Bool`; `actions` gains the Lens group for HTTP blocks), `Sources/NyxApp/BlockHeaderView.swift` (`{ }` control), `Sources/NyxApp/TabController.swift` (`.toggleHTTPLens` → `focusedPane?.toggleLensOfCurrentBlock()`).
- Test: `BlockHeaderTests` (`lensGroupForHTTPBlocks`, `tooLargeReplacesTheGroup`, `activeLensIsChecked`), `LensSelectionTests` (`textAcrossLines`, `columnsClampToLineLength`), snapshots `block-lens-{pretty,headers,filter,grep,diff}-{dark,light}` (built from a fixture exchange through `LensBuffer.row` into a `RenderFrame` and the offscreen renderer — the same path `UISnapshot` uses for rendered grids), `block-header-http-lens-dark`.

- [ ] **Step 1: Core tests and changes** (`BlockAction`, `BlockHeader`, `LensSelection`).
- [ ] **Step 2: Pane wiring** as listed. The frame builder must not block on `lensQueue`; assert by reading the code path and by a `render-performance`-style check: `make bench` and a 2 MB JSON block scrolled 100 times with no frame over 16 ms (log frame times under `NYX_SMOKE_QA`).
- [ ] **Step 3: Snapshots** looked at: the `{ }` control fits the strip at every `OverlayControls` level, pretty JSON colours read in both appearances, the fold placeholder reads `▸ […] 40 items`.
- [ ] **Step 4: Commit** — "Lenses in the pane: pretty JSON you can fold, filter, grep and diff".

---

### Task 5: `WatchSeries`

**Files:**
- Create: `Sources/NyxCore/HTTP/WatchSeries.swift`
- Test: `Tests/NyxCoreTests/WatchSeriesTests.swift`

**Interfaces:**
```swift
public struct WatchPlan: Equatable {
    public enum Stop: Equatable { case never, count(Int), until(Condition) }
    public enum Condition: Equatable { case status(Int), statusClass(Int), statusNot(Int), bodyContains(String), bodyLacks(String)
        public func holds(status: Int?, body: String) -> Bool
        public var title: String }   // "until 200", "until 2xx", "until not 503", "until body contains \"ok\""
    public let interval: Double
    public let stop: Stop
    public init(interval: Double, stop: Stop)
    public var title: String                                   // "every 5 s", "10 times", "every 5 s until 200"
}
public struct WatchSeries: Equatable {
    public struct Run: Equatable { public let id: UInt32; public let status: Int?; public let exitStatus: Int32; public let timeTotal: Double?; public let at: Double }
    public enum Dot: Equatable { case success, redirect, failure, running }
    public struct Stats: Equatable { public let count: Int; public let min: Double; public let p50: Double; public let p95: Double; public let max: Double; public let failures: Int
        public var text: String }                              // "20 runs · p50 138 ms · p95 210 ms · 1 failure"
    public enum Phase: Equatable { case waiting(until: Double), running(id: UInt32), finished(reason: Finish) }
    public enum Finish: Equatable { case count, condition, stopped, userTyped, paneClosed }
    public let plan: WatchPlan
    public let command: String                                  // the exact line sent each run
    public init(plan: WatchPlan, command: String, startedAt: Double)
    public var runs: [Run]
    public var phase: Phase
    public mutating func runStarted(id: UInt32, at: Double)
    public mutating func runFinished(id: UInt32, status: Int?, exitStatus: Int32, timeTotal: Double?, body: String, at: Double)   // records; decides finished vs waiting(until: at + interval)
    public func shouldSend(now: Double, shellAtPrompt: Bool) -> Bool   // waiting, due, and at a prompt
    public mutating func stop(_ reason: Finish)
    public var isFinished: Bool
    public var stats: Stats?                                    // nil under 2 runs with timings
    public func timeline(last n: Int) -> [Dot]
    public var headerText: String                               // running: "watch every 5 s · run 12 · 200 · 142 ms"; finished: stats.text or "stopped after 3 runs"
    public func shouldFold(runAt index: Int) -> Bool            // every run but the last, unless its status class differs from the run before it
}
```
Percentiles: nearest-rank over sorted `timeTotal`s. `runFinished` with `.count(n)` finishes when `runs.count == n`; `.until(c)` finishes when `c.holds`; `.never` waits.

- [ ] **Step 1: Tests** — `waitsIntervalAfterTheRunEnds` (not after it starts), `doesNotSendWhileRunning`, `doesNotSendAwayFromPrompt`, `countStops`, `untilStopsWhenConditionHolds`, `untilKeepsGoingOtherwise`, `statsPercentiles` (known 20 values → p50/p95 exact), `timelineDots`, `foldsAllButLast`, `keepsARunWhoseStatusClassChanged`, `userTypedStops`, `headerTexts`.
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5: Commit** — "WatchSeries: when to run again, when to stop, what the header says".

---

### Task 6: Watching in the pane

**Files:**
- Modify: `Sources/NyxApp/Pane.swift`:
  - `watch: WatchSeries?` (one per pane), `watchTimer` (a 250 ms `Timer` alive only while a series is waiting), `startWatch(plan:command:)`, `stopWatch(_ reason:)`;
  - on each timer tick and on each frame where the bottom prompt state changed: `if watch.shouldSend(now:, shellAtPrompt:)` → `send(command + "\r")`, `watch.runStarted(id:)` when `Terminal.runningCommand` appears; when the block finishes (the exchange cache) → `watch.runFinished(...)`, then apply `shouldFold` through `folding.fold(id, .all)` for the previous run, set the newest run's lens to `.diff(previousCommandID:)` when JSON (else the default), `markDirty()`;
  - any key press that reaches `send` from the keyboard while a series is waiting → `stopWatch(.userTyped)`; `close`/deinit → `.paneClosed`;
  - `BlockHeader` for the newest run of an active/finished series carries `watch: WatchHeader?` (Core: `struct WatchHeader: Equatable { text: String; dots: [WatchSeries.Dot]; showsStop: Bool }`, built from `WatchSeries.headerText`, `timeline(last: 30)`, `!isFinished`), which `BlockHeaderView` draws as the summary (dots as 6 pt circles in the block colours, then the text, then a Stop button when `showsStop`); `BlockAction.stopWatch`, `.watch(WatchPlan)` (menu: "Run Every 5 s", "Watch…" opening a small popover with interval, stop rule and condition fields — an `NSViewController` built on a `WatchPlanEditorModel` value type in Core with `title`/validation), `.runEvery(seconds)` in the ⋯ menu's "Request" group for HTTP blocks.
- Modify: `Sources/NyxApp/RequestEditor.swift` — the Run menu's "Run every…", "Run 10 times", "Run until 200" build a `WatchPlan` (interval from `config.httpWatchInterval`) and call `onWatch(plan, runLine)`; `Pane.presentRequestEditor` wires `onWatch` to `send` the line then `startWatch`.
- Modify: `Sources/NyxApp/TabController.swift` — `.stopWatch` → `focusedPane?.stopWatch(.stopped)` (beep when none); palette gets "Stop Watching" only while a series is active (`PaletteItem.isEnabled`).
- Modify: `docs/architecture.md` ("Where to add things": a lens, a watch rule), `docs/configuration.md` (already has the keys; add the ⋯ menu items), `docs/status.md`, `README.md`.
- Test: `WatchPlanEditorModelTests` (`validatesInterval`, `buildsPlanTitles`), `BlockHeaderTests` (`watchHeaderReplacesSummary`), snapshots `block-header-watch-{running,finished}-{dark,light}`, `watch-plan-editor-{dark,light}`.

- [ ] **Step 1: Core tests and changes.**
- [ ] **Step 2: Pane and sheet wiring.**
- [ ] **Step 3: Rung 6** — temporary `NYX_SMOKE_QA=watch` hook: start the fixture server from the request plan with an endpoint whose JSON changes every call (`/counter` → `{"n": k}`) and one that returns 503 twice then 200; run `curl -sS http://127.0.0.1:PORT/counter` with `WatchPlan(interval: 1, stop: .count(3))`; assert three blocks, the first two folded, the newest showing the diff lens with one `+`/`-` pair, the header text `3 runs · p50 …`; then `Run until 200` on the 503 endpoint → assert it stops at the third run and the two 503 blocks stay unfolded (status class changed) — note: per the fold rule, the 503→503 pair folds the first, the 503→200 change keeps the second; assert that exactly; then start a `.never` series and type a character → assert `phase == .finished(.userTyped)`. Remove the hook before the final commit.
- [ ] **Step 4: Ladder** — warnings 0, `swift test --no-parallel` count, `make bench`, every new PNG looked at.
- [ ] **Step 5: Commit** — "Watch, repeat, poll: the same request on a schedule, each run a block".
