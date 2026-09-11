---
name: nyx-ui-chrome
description: Use when adding or changing drawn interface in Nyx outside the terminal grid — tab bar, search bar, command palette, sheets, banners, gutter, sticky prompt, settings pages, context menus, buttons — or when a control's colours, states, labels or hit areas change.
---

# Chrome

Chrome is the AppKit-drawn part of the window. It has to look native, explain itself without a
manual, follow the theme, be reachable by VoiceOver, and be *looked at*, which on this machine
means rendered offscreen to PNG. The user's brief: "красиво и очевидно как работает".

## Checklist for a new or changed control

1. **State is a Core value type.** Geometry, truncation, which items fit, what the label says,
   what a click at (x, y) means: `TabBarGeometry`, `TabBarLabels`, `TabStrip`, `CommandPalette`,
   `SearchSession`, `StickyPromptLabel` are the models. Tests first, in `Tests/NyxCoreTests`.
   The view draws rectangles the model returned and reports hits back to it.
2. **Colours come from the palette.** `Pane.resolvedPalette(for: config)` and the derived
   interface colours; never a literal `NSColor`. Views drawn in *system* colours (banners) must
   be checked in both appearances, because they ignore the theme.
3. **Every control is an accessibility element.** For hand-drawn rectangles,
   `DrawnControlElement.make(label:role:frame:in:value:press:)` (`Accessibility.swift`), one per
   control, with the label the tooltip uses and the press it performs. Real `NSControl`s are
   labelled with `setAccessibilityLabel`.
4. **Every state has a `UISnapshot` case** in `Sources/NyxApp/UISnapshot.swift`: empty, typed,
   no matches, narrow, many, collapsed, running, failed, light, dark. Name the PNG after the
   state. The states nobody renders are the states nobody has looked at.
5. **Render and look.** `./scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/shots
   ./build/Nyx.app/Contents/MacOS/Nyx`, then Read the PNGs. Check contrast, clipping at 300 pt,
   alignment with neighbours, and that nothing else changed. The `design-reviewer` agent does a
   full pass when the change is more than a tweak.
6. **A control that can fail says so.** No shell integration, no marks, nothing to fold, no
   matches: the control shows its empty state or a note, or is disabled with a reason
   (`validateMenuItem`, `canPerform`). It never silently does nothing.
7. **Actions go through `TerminalAction`.** A new verb is a case in `TerminalAction`, a place in
   `ActionCatalog.sections` (which builds the menu), a default chord in `KeyBinding.defaults` if
   it deserves one, and a `case` in `TabController.perform`/`canPerform`. Then it is in the menu,
   the palette, the settings Keys page and the config file for free. `docs/configuration.md` gets
   a row.
8. **Drive the real path once.** A temporary `NYX_SMOKE_QA` hook that clicks the rectangle via the
   view's hit-test or invokes the menu selector, prints the outcome, and is removed
   (`docs/testing.md`, rung 6).

## Conventions already in the chrome

- Tab bar: groups are a tinted band with a name chip; a selected tab is not a stripe; the `+` for
  a new tab sits right of the tabs, the `+` for a new button right of the buttons. Buttons that
  do not fit at narrow widths drop in a defined order (`TabBarGeometry`); test that order.
- Sheets (`CommandEditor`, `QuickActionEditor`) are `NSViewController`s presented as window
  sheets with the terminal's palette for the editor area and system chrome elsewhere.
- Diagnostics go to `ConfigBanner` with a line number and stay until the file is fixed;
  deferred settings are named there too.
- Notes on rows (durations, block summaries) are drawn by the grid renderer, not by chrome;
  that is `nyx-rendering`.
- The gutter and the sticky prompt are views over the grid; their layout is re-measured on
  `padding` and font changes (`layoutGutter`, `layoutStickyStrip`).

## Common mistakes

- Hit-testing in the view with its own arithmetic instead of asking the Core geometry.
- A new state with no snapshot, or a snapshot added and never opened.
- A literal colour that is fine in `nyx-dark` and invisible in `nyx-light`.
- A menu item without `validateMenuItem`, enabled when the action cannot work.
- Forgetting the flipped-coordinate conversion for accessibility frames (the helper does it; do
  not hand-roll).
