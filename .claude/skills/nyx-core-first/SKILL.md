---
name: nyx-core-first
description: Use when deciding where a piece of Nyx logic belongs, when about to write an `if` or a computation inside an NSView/NSViewController handler, or when extracting a decision from Pane/TabController/TabBarView into something a test can call.
---

# Core first

**Every decision lives in `NyxCore` as a value type with tests. The AppKit layer converts events
in and draws results out.** This is not taste: the build machine denies Accessibility, so a
decision left in a view handler cannot be exercised by anything. The keypad regression lived in
`insertText` for a whole phase while seventeen encoder tests passed.

## Import rules

| Module | May import | Never |
|---|---|---|
| `NyxCore` | Foundation, CNyxPTY | AppKit, Metal, CoreText, QuartzCore |
| `NyxRender` | Metal, CoreText, QuartzCore, NyxCore | CNyxPTY |
| `Nyx` (NyxApp) | anything | — |

`NSPoint`, `NSEvent`, `CGFloat` geometry, `NSColor` do not cross into Core. Convert at the edge:
`(x: Double, y: Double)`, `KeyEvent`, `MouseEvent`, `RGB`.

## The test for "is this a decision"

Ask: *could this be wrong in a way a user would notice?* If yes, it is a decision and it goes in
Core. Examples already there, because they were once in views: which row a click lands on
(`PointerMap`), whether a tab's close button fits at this width (`TabBarGeometry`), whether the
dirty flags may be trusted this frame (`ViewportMapping`), whether a paste needs the editor
(`PasteGuard`), what the environment for the shell is (`ShellIntegration`), whether `⌘W` closes a
pane, a tab or the window (`TabClosing`).

What stays in the view: creating layers and views, `NSEvent` → Core types, calling the Core
function, drawing what it returned, posting to AppKit APIs.

## Extraction recipe

1. Name the decision's inputs as scalars and Core types. `ViewportMapping` is six integers.
2. Write the Core type in the directory that owns the concept (`docs/architecture.md` table).
   Value type, `Equatable`, `public`, doc comment on *why* the rule is what it is.
3. Write the tests first, one per way the answer can change. Use `makeTerminal().run(...)` for
   anything the model feeds. Hoist mutating calls out of `#expect` (see `CLAUDE.md`).
4. Replace the view code with a call. The view should shrink to conversion + call + draw.
5. The AppKit edge that remains (the event actually arrives, the selector is wired) gets a
   temporary env-var hook in the built app once (`docs/testing.md`, rung 6), then removed.

## Red flags

- "It's one `if`, it doesn't need a type." One `if` in a view is one untested branch.
- "I'll test it through the snapshot test." The snapshot test is opt-in and slow; it is not where
  a rule lives.
- "I'd need an AppKit test target." There is none, on purpose. Move the rule instead.
- A Core function whose only caller is its own test. Grep for callers before reporting done.
- A view that reads `session.withTerminal { $0 }` and keeps the reference. It must not escape.
