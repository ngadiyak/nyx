---
name: nyx-config-keys
description: Use when adding or changing a Nyx config key, a theme file property, a `TerminalAction`, a default key binding, a quick-action kind, or anything the settings window edits — including when a setting "does nothing" after a reload.
---

# Config keys, actions and bindings

The config is one flat `key = value` file, parsed by `ConfigParser` into `Config`, diffed by
`ConfigDiff`, applied by `Pane.apply` and `TabController.apply`, edited in place by
`ConfigWriter` (settings window, quick-action editor), and documented in `docs/configuration.md`.
A key that is missing from any one of those is a defect the tests partly catch and the user fully
notices.

## Adding a key: every place, in order

| # | Where | What |
|---|---|---|
| 1 | `Config` (`Config.swift`) | the field, its default, a doc comment on *why this default* |
| 2 | `ConfigParser.parse` | the `case "key-name":` with a typed parse; on a bad value emit `ConfigDiagnostic` with the line, keep the previous value. Values that legitimately contain `#` (commands, templates) must be exempted from comment stripping like `quick` and `open-file-command` |
| 3 | `Config.defaultFileText` | a commented `# key-name = default` line under the right heading. `ConfigTests.theDefaultFileTextParsesBackToTheDefaults` fails until this is there, on purpose |
| 4 | `ConfigDiff` | if the key changes what is on screen, a flag (or fold into an existing one); if it takes effect only for a new session or window, add it to `deferredNotes` so the banner says so instead of silence |
| 5 | `Pane.apply` / `TabController.apply` / `TerminalWindowController` | act on the diff flag. Palette-like things ask the *resolved* value, not the field (`applyPaletteIfChanged`), because files can change the result without any field moving |
| 6 | `SettingsWindowController` | a row on the right page, writing through `ConfigWriter`. Popups list live values (`Pane.themes.names` at open time), never a list frozen at init |
| 7 | `docs/configuration.md` | the row: key, default, values, meaning |
| 8 | README | only if it is a feature a user chooses Nyx for |
| 9 | Tests | `ConfigTests`: parses, rejects with a line number, round-trips through `ConfigWriter`; `ConfigDiffTests` for the flag |

Then `nyx-verifying-a-change`, and rung 4 applies: the settings page shows the key.

## Adding an action

`TerminalAction` case (its raw value is the config spelling) → `ActionCatalog.sections` (this
*is* the menu; a case not listed there is not in the menu or the palette) → `KeyBinding.defaults`
if it earns a chord (check collisions against the table in `docs/configuration.md`) →
`TabController.perform` and `canPerform` (disabled with a reason when it cannot work) →
`docs/configuration.md` bindings table → `ActionCatalogTests`/`KeyBindingTests`. The menu is
rebuilt on config change, so a `keybind` line shows up in it; the settings Keys page lists every
action with its chord.

## Bindings

`keybind = mods+key=action`; split at the *last* `=`; lowercase single characters; `shift`
explicit; named keys listed in `docs/configuration.md`. User beats default; later line beats
earlier. A new named key goes in `KeyBinding.parseKeyToken`, `Key`, and the docs.

## Themes and palettes

Theme files share `ConfigGrammar` with the config and are parsed by `Themes.parse`; a new theme
property is a `case` there, a field on `Palette`, a derived interface colour if the chrome uses it,
a `UISnapshot` `theme-*` render, and a row in `docs/configuration.md`. Built-ins must pass
`ThemesTests`' contrast floor; user files must not be held to it. A name the config asks for and
nothing provides is reported as `no theme named "…"`.

## Common mistakes

- A field with no `defaultFileText` line: the round-trip test tells you.
- A flag added to `ConfigDiff` and read by nobody: the setting reloads and nothing changes.
- A value validated on parse but not on write: the settings window can write a value the parser
  then rejects on reload.
- Reading a setting at init and caching it; settings change at runtime and the app must follow.
- Stripping comments from a value that contains `#`.
- Documenting the key in the code comment and nowhere a user reads.
