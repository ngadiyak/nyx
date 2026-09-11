---
name: nyx-verifying-a-change
description: Use before saying any Nyx change is done, fixed, working, or mergeable — including when asked "готово?", "can I merge?", when writing a task report, a commit message with figures, or a PR description.
---

# Verifying a change

**"It compiles" and "the tests pass" are where this project's broken features came from.** A
change is verified when each rung below that applies has been run *now*, on *this* tree, and its
output is in the report. The machine denies Accessibility and screen recording: there is no
"launch it and press the key once". The rungs are the substitutes, and they are not optional.

## The rungs, with when each applies

| # | Applies when | Run | Evidence to report |
|---|---|---|---|
| 1 | always | `swift build 2>&1 \| grep -c warning:` | the count, which is `0` |
| 2 | always | `swift test --no-parallel` (if it hangs before any test runs: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test`, re-run in the foreground) | `N tests passed`, with N |
| 3 | `Sources/NyxCore/Parser`, `Terminal`, `Unicode`, or `NyxRender` changed | `make bench` ×3 | the three figures; floor 180 MB/s |
| 4 | anything drawn changed, **or** anything the chrome displays changed: an action, a binding (menus and the settings Keys page show chords), a theme, a config key (settings pages), a diagnostic (the banner) | `./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/shots ./build/Nyx.app/Contents/MacOS/Nyx`, then Read the PNGs that show the change | the PNG names and one line each on what they show |
| 5 | glyphs, fonts, atlas, or the grid renderer changed | `NYX_SNAPSHOT=1 swift test --filter Snapshot` and Read `build/snapshots/*.png` | as above |
| 6 | a path through AppKit changed or was added: a key, a menu item, a mouse gesture, a paste, a sheet, a reload | a temporary `NYX_SMOKE_QA=<name>` block in `AppDelegate.applicationDidFinishLaunching` that opens a window and drives the real entry point (`keyDown` with a synthesized `NSEvent`, the menu item's selector, `TabController.perform`), prints what happened, exits; run it from the bundle; **remove it** | the printed line, and `git status` clean of the hook |
| 7 | a promise was made in README, `docs/configuration.md`, a doc comment, or spec §11 | grep for the caller or the behaviour the promise names | file:line of the code that keeps it |
| 8 | always, before "done" | the `product-manager` agent | its verdict |

Rung 6 is where every "written, tested, not wired" defect was caught. A Core test of the encoder,
the parser or the layout is rung 2; it says nothing about whether the event reaches it.

## The report

In this order, so a reader who did not watch can trust it:

1. What changed, for a user, in two sentences.
2. The rung table above, reduced to the rungs that applied, each with its evidence line. A rung
   that applied and was not run is listed as **not run**, with the reason.
3. Docs touched: `docs/configuration.md` for a key/action/binding, README for a feature,
   `docs/status.md` for a capability, spec §11 for a promise.
4. What only a human with a screen can still check (`docs/checklist.md` items).
5. Files to commit, by name. `git add -A` has swept QA hooks into two commits already.

## Rationalizations, and what they cost last time

| "…" | What happened when someone thought that |
|---|---|
| "Tests pass, so it works" | Keypad: 17 encoder tests green, plain keypad-1 sent `1` in the app |
| "I'll just run the app and try it" | Cannot happen here. Write the hook or you have no evidence |
| "It's a Core-only change, no UI to look at" | A binding is shown in menus and the settings page; a diagnostic is shown in the banner |
| "The bench didn't change, I didn't touch the parser" | Fine, say so; that is a rung marked not applicable, not a rung skipped |
| "The README says it works" | Themes-from-files: README, spec and default config all said "recolours every window"; the grid did not recolour |
| "I'll report the figure from the last commit" | A figure not measured on this tree is a guess with a decimal point |
| "The PM review is a formality" | It has held the branch every round so far, for real defects |
