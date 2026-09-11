# Verifying Nyx

The machine Nyx is developed on denies Accessibility and screen recording. Nothing can be clicked,
typed into, or screen-captured. Every feature that shipped broken in this project shipped because
"it compiles" or "the tests pass" was accepted as evidence that a person could reach it. This page
is the list of what *is* evidence, from cheapest to most complete.

## The ladder

| Rung | Command | Proves |
|---|---|---|
| 1 | `swift build 2>&1 \| grep -c warning:` → `0` | Warning-free. CI fails on any warning, debug or release |
| 2 | `swift test --no-parallel` | Every decision in `NyxCore` and every pixel rule in `NyxRender`. ~1000 tests |
| 3 | `make bench` ≥ 180 MB/s (run it three times; it varies by ±3) | Parser + model throughput did not regress |
| 4 | `NYX_UI_SNAPSHOT=/tmp/shots ./build/Nyx.app/Contents/MacOS/Nyx` then **look at the PNGs** | The chrome looks right in every state, every theme, both appearances |
| 5 | `NYX_SNAPSHOT=1 swift test --filter Snapshot` | A real zsh through PTY → parser → model → Metal → pixels; PNGs in `build/snapshots/` |
| 6 | A temporary env-var hook in `AppDelegate` that drives the real path and prints what happened | The feature works *the way a user reaches it*: through `keyDown`, the input context, the menu, the mouse |
| 7 | `docs/checklist.md` on a machine with a screen | The things only a human can see: latency feel, IME, vttest, idle CPU |

A change is not done until every rung it can reach is green, and rung 6 is reached far more often
than it feels like it should be. The keypad regression passed seventeen unit tests of the encoder
while plain keypad-1 sent `1` in the built app: `insertText` never called the encoder.

## Rung 2: swift-testing

`import Testing`, `@Test`, `#expect`, `#require`. XCTest is not available.

**The runner hangs at launch intermittently.** It is `swiftpm-testing-helper`, not a test. Kill it
and re-run in the foreground; never wait on a background test run:

```
pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test
swift test --no-parallel
```

**Mutating calls inside `#expect`/`#require` do not compile.** The macro captures the receiver
immutably, and the error points at the macro expansion. Hoist the call:

```swift
let created = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)   // not inside #require
let group = try #require(created).id
```

**Driving the model.** `Tests/NyxCoreTests/TerminalTestHelpers.swift`:

```swift
let t = makeTerminal(cols: 10, rows: 3).run("\u{1B}[2J\u{1B}[H" + "hi")
#expect(t.line(0) == "hi")
#expect(t.cur == (2, 0))
#expect(t.cell(0, 0).attrs.contains(.bold) == false)
#expect(t.responseText == "\u{1B}[?1;2c")      // what the terminal answered
```

`t.events` holds `TerminalEvent`s (title, bell, cwd, clipboard, notification), `t.scrollbackLine(i)`
reads the ring. Every test that feeds bytes should also assert what the *user sees*, not just what
the cursor did.

**Rendering pixels.** `Tests/NyxRenderTests/RendererTests.swift` has `renderToPixels(frame)`: a
`Renderer` on the default Metal device drawing into a managed texture, read back as `(x, y) → RGB`.
`PartialRedrawTests` compares a cache-using renderer against one told nothing, frame by frame; add
a scenario there whenever a new input reaches `RenderFrame`.

**Filter to what you touched** while iterating, then run everything before claiming done:

```
swift test --no-parallel --filter PromptMarks
```

## Rung 4: the interface as pictures

`UISnapshot` draws each view with `cacheDisplay(in:to:)`, which needs no permission, and
`GridSnapshot` composites that chrome over a grid drawn by the real Metal renderer. One run writes
about 420 PNGs.

### Naming

`<case>-<palette>-<appearance>` wherever the pane's own theme decides how a control is painted;
`<case>-<appearance>` for the sheets and the settings window, which are AppKit surfaces the theme
never touches. `<palette>` is a theme name (`nyx-dark`, `nyx-light`, `solarized-dark`),
`<appearance>` is `light` or `dark`.

Both appearances are rendered for every themed case even though most pairs come out
**byte-identical** — and that is the point: `BlockHeaderView`, `LensFieldView`, `PromptGutterView`
and `StickyPromptView` pin their own appearance to the palette, so a pair that stops being identical
is the Light-Mode bug coming back (a disabled Copy measured 1.13:1 over a dark theme under Light
Mode). `cmp` the pair before you read it; read one of each identical pair and every pair that
differs.

### What is rendered

- the tab bar at 1, 4, 6, 12, 20 tabs; at 420 and 300 pt wide; with groups, collapsed groups, two
  groups, no quick actions, a running toggle, a remote badge;
- the search bar empty, typed, with no results, and in all-tabs scope;
- the command palette empty, filtered, with no matches, and with the Remote and Requests sections;
- the config banner in all three kinds (config error, note, failure) and the project bar, in both
  appearances;
- every sheet in both appearances: quick-action editor, command editor, the request editor on each
  of its five tabs plus its masked-credential, pipeline-note and per-tab not-editable states, the
  `Save as Button` and `Run every…` prompts, the watch popover valid and invalid;
- the pairing sheet in every `PairingFlow.State`, on **both** sides (host and client), plus the
  invalid-code state, in both appearances;
- every settings page, with the Remote page switched on and off;
- the hover strip in all 26 of its states × both themes × both appearances — every command state,
  every HTTP tone, the `{ }` control on/off/`.body`/too-large/not-JSON, the two narrow control sets,
  and the watch timeline at 11, 30 and 48 runs;
- the gutter's four marks, the lens field's five states, the sticky prompt's four, the workbench
  pill and the long-command fallback strip — all × both themes × both appearances;
- the remote strip in all eleven states × both themes × both appearances;
- every theme: a swatch strip, the tab bar, groups, the palette, the search bar, and a
  `theme-<name>-lens-watch` sheet with the lens and watch chrome on one page.

### The composites: chrome over a real grid

`GridSnapshot` (`Sources/NyxApp/GridSnapshot.swift`) is the only place the two halves meet. It feeds
a fixture `Terminal` — OSC 133 marks, a folded 1,200-row build, wrapped rows, CJK and emoji, a
lensed `curl` — through `Terminal.displayRows` into a `RenderFrame`, draws it with the offscreen
`Renderer`, and then composites the AppKit chrome over that image at the placement the pane's own
NyxCore rules choose (`CommandBlockChrome.overlayPlacement` and `summaryPlacement`,
`PromptGutter.width`, the `bounds.height - padding - (row + 1) * cell` arithmetic of
`Pane.overlayOrigin`). `composite-*.png`: the hover strip at each control set, on a lensed block and
on a watched one; the sticky strip over scrolled output; the gutter beside its rows; the lens field
over a lens; `.body`, a filter that matched nothing and `.pretty` on an HTML body; the search bar
over its highlights; and each banner above the grid.

It lives in NyxApp, not in `NyxRenderTests`, so that `NyxRender` never learns what a hover strip is.

Chrome is drawn through `ChromeGround`: the view's **layer** ground first (fill, corner radius,
border, and the chrome's own gradient sublayers), then `cacheDisplay` for the content.
`cacheDisplay` alone renders the view and never the layer, so any ground that is a
`layer.backgroundColor` was missing from every picture — invisible on `UISnapshot`'s flat fill,
and not invisible at all over a grid, where the search bar came out with the terminal reading
through it. Both snapshot paths use it.

### Menus and alerts

`MenuSnapshot` covers what `cacheDisplay` cannot reach.

An `NSMenu` has no view. `popUp` on a windowless view throws `View is not in any window`; an
offscreen window would then run a modal tracking loop that never returns; and capturing the menu's
own window needs screen recording, which `CGPreflightScreenCaptureAccess()` answers **false** to on
this machine. So `menu-*.png` are **reconstructions at AppKit's own metrics**: the width is
`NSMenu.size.width`, the pitch is the measured `10 + 24 × items + 11 × separators`, and every title,
tick, separator, submenu arrow and key equivalent is read off a real `NSMenu`'s `items` rather than
retyped. `MenuSheetView` checks its own height against `NSMenu.size` and prints to stderr if they
disagree. What is *not* real in them: the panel material, the corner radius and the highlight art.

`NSAlert` needs none of that — it owns a real window, `layout()` fills it in, and its `contentView`
renders like any other view. Every `alert-*.png` is built by the product's own builder
(`Pane.watchRefusedAlert`, `TabController.closeConfirmationAlert`,
`TabController.projectReviewAlert`, `RequestEditor.intervalPrompt`), so the wording in the picture
is the wording in the app.

### Hover and pressed

`StateSnapshot` renders `tabbar-hovered-*`, `gutter-marks-hovered-*` and `block-header-pressed-*`.
The tab bar's hover targets are **found**, not written down: the pointer is swept across the bar
through the real `mouseMoved` until the tooltip is the one being looked for, and the x it stopped at
is printed. `NSButton.highlight(true)` gives the pressed art; the *hovered* art of an `.inline`
bezel is AppKit's own tracking and is not reachable without a window, so there is no hovered strip
picture.

A hovered picture that is byte-identical to its idle one is a finding, not a bug in the tool — it
means the control has no hover drawing. `cmp` them.

### Reproducibility

`NYX_CONFIG` is pointed at a fixture file for the whole run, so the settings pages no longer render
from the developer's own `~/.config/nyx`. (`$HOME` cannot be used: AppKit has read
`NSHomeDirectory()` long before the snapshot runs.) The Mac's own host name still reaches the
Remote page's `Device name` placeholder and cannot be fixtured this way.

Read the PNGs with the Read tool. What you are checking: contrast (nothing invisible), alignment,
truncation at narrow widths, that a new state you added actually appears, and that a state you did
not touch did not change. **A new piece of chrome gets a snapshot case in the same commit**, one
per state; the states nobody renders are the states nobody has looked at.

The run is deterministic — two runs of one build differ in nothing but
`request-editor-options-*.png`, whose field group is placed by an ambiguous constraint in
`RequestEditor.optionsPage`. `cmp -r` two runs before you trust a diff. One run writes about 530
PNGs.

Metal content that no chrome sits over is rung 5.

## Rung 6: exercising the real path

The pattern that has caught every "tests pass, feature does nothing" defect so far:

1. Add a block to `AppDelegate.applicationDidFinishLaunching` gated on an env var
   (`NYX_SMOKE_QA=keypad`). Open a window, get its `Pane`, and drive the real entry point: post an
   `NSEvent` to `keyDown`, call the menu's selector, call `TabController.perform(.find)`, feed bytes
   through the session and read back what the PTY received.
2. Print what happened (`print("SMOKE keypad1 -> \(bytes)")`) and `exit(0)`.
3. `./scripts/bundle.sh && NYX_SMOKE_QA=keypad ./build/Nyx.app/Contents/MacOS/Nyx`.
4. **Remove the hook before committing.** `git diff --stat` must not show it. Two commits have
   already had to be amended because `git add -A` swept a hook in.

Read-only accessors added to views for this purpose are also removed; if the probe needed state the
view hides, that is a hint the decision belongs in `NyxCore` where a test can ask for it.

## Rung 3: the benchmark

`make bench` builds release and feeds a synthetic stream through `Terminal.feed`; `make bench
FILE=path` uses a recorded file. The number depends on the machine and on what else is running.
Compare against `main` on the same machine in the same minute, not against a number in a commit
message. `NYX_RENDER_STATS=1` in the app prints the row-cache counters per pane, which is how a
renderer change is shown to be an improvement rather than described as one.

## CI

`.github/workflows/ci.yml` runs rungs 1–4 on every push: build, fail on warnings, tests, release
build, bench floor 120, bundle, launch and stay up for 8 s, render ≥10 UI snapshots and upload them
as an artifact. If the renderer starts crashing, CI goes red; there is no `|| true`.

## Reporting

A report of verification says which rungs ran and what they printed, including the test count and
the bench figure. "Tests pass" without a number, or a bench figure copied from the previous commit,
is the shape of every report that later turned out to be wrong.
