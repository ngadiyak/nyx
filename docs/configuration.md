# Configuration reference

The file is `~/.config/nyx/config` (override with `NYX_CONFIG=/path/to/config`). Flat
`key = value`, one per line, `#` comments (a `#` starts a comment only after whitespace, so
`palette = 1=#ff0000` is a colour, not a comment). The file is watched and reloaded on save. A bad
line is reported in the banner at the top of the window with its line number, and every other
setting stays in force. `⌘,` opens the settings window, which edits this file in place;
`⌘⇧,` reloads it by hand.

`Config.defaultFileText` in `Sources/NyxCore/Config/Config.swift` is the commented template Nyx
writes when the file is missing. `ConfigTests` checks that parsing it yields exactly the defaults,
so that template and this page are the two places a new key must be added.

## Keys

| Key | Default | Values / meaning |
|---|---|---|
| `font-family` | `system` | A family name, or `system` for SF Mono (Apple exposes it only through `NSFont.monospacedSystemFont`, so it cannot be named). Glyphs missing from the family come from Core Text fallback |
| `font-size` | `13` | Points |
| `line-height` | `1.0` | Multiplier over the font's natural line height |
| `font-thicken` | `false` | Heavier rasterisation, the "font smoothing" effect |
| `theme` | `nyx-dark` | A theme name, or `dark:<name>,light:<name>` to follow the system appearance |
| `palette` | — | `<0-255>=<#rrggbb>`, one per line, additive. Overrides slots of the active theme. Slots 0–15 also drive Nyx's own interface colours |
| `cursor-style` | `block` | `block`, `underline`, `bar`. A program's DECSCUSR wins while it runs |
| `cursor-blink` | `true` | |
| `scrollback-lines` | `10000` | Per pane. Takes effect for new sessions; the banner says so |
| `padding` | `8` | Points between the window edge and the grid |
| `background-opacity` | `1.0` | 0–1 |
| `background-blur` | `0` | Blur radius behind a translucent window. A value above 0 implies opacity 0.9 unless `background-opacity` says otherwise |
| `window-decorations` | `true` | |
| `tab-bar` | `auto` | `auto` (hidden with one tab and no buttons), `always`, `never` |
| `shell` | `$SHELL`, else `/bin/zsh` | Path to the shell, launched as a login shell |
| `working-directory` | `inherit` | `inherit` (from the current pane, via OSC 7), `home`, or an absolute path |
| `copy-on-select` | `false` | |
| `middle-click-paste` | `true` | |
| `option-as-meta` | `none` | `none`, `left`, `right`, `both`: which ⌥ sends ESC-prefixed bytes instead of composing characters |
| `mouse-scroll-alt-screen` | `true` | On the alternate screen, the wheel sends arrow keys |
| `bell` | `visual` | `visual`, `sound`, `none` |
| `confirm-close-process` | `true` | Ask before closing a pane whose shell has a running child |
| `restore-session` | `true` | Bring back windows, tabs, splits, cwd and scrollback at launch. `no` also deletes the saved session |
| `clipboard-read` | `false` | Allow OSC 52 to *read* the clipboard. Writing is always allowed |
| `word-separators` | `` ()[]{}'"`,;:|<> `` plus space | Characters that end a double-click word |
| `open-file-command` | — | Template run for a clicked path, with `{file}` and `{line}` placeholders. Empty means `NSWorkspace.open`. Not comment-stripped, so `#` is allowed |
| `shell-integration` | `auto` | `auto` injects the OSC 133 hooks for zsh; `off` never touches the shell |
| `multiline-paste` | `edit` | What a paste with newlines does: `edit` opens the editor, `confirm` shows a preview with an Edit button, `direct` sends it straight through |
| `fold-keep-lines` | `3` | Rows of output a folded command keeps visible at its end. `0` hides all of it |
| `fold-long-output` | `0` | Fold a command's output automatically once the next command starts, when it is longer than this many rows. `0` turns it off. A block you unfolded by hand is never re-folded |
| `quick` | — | A button on the tab bar; see below. Additive |
| `keybind` | — | A binding; see below. Additive |

Booleans accept `true`/`false`, `yes`/`no`, `1`/`0`.

## Themes

Built in: `nyx-dark` (default), `nyx-light`, `solarized-dark`, `gruvbox-dark`, `dracula`,
`catppuccin-mocha`, `one-dark`. Every built-in passes the floor in `ThemesTests`: nothing invisible
against the background, no colour indistinguishable from the foreground, every bright variant more
legible than its normal. Three ports deviate from upstream to clear that floor; each deviation is
documented on the palette in `Themes.swift`.

**Your own theme** is a file in `~/.config/nyx/themes/` (beside the config, so it moves with
`NYX_CONFIG`). The theme's name is the filename without its extension; a name matching a built-in
replaces it. Keys:

```
foreground           = #c0caf5
background           = #1a1b26
cursor               = #c0caf5
selection            = #33467c
selection-foreground = #c0caf5
palette              = 0=#15161e
palette              = 1=#f7768e
...
```

Rules that follow from the code:

- The directory is watched. Saving a file recolours the grid and the chrome of every window.
- Symlinks are followed. Hidden files are skipped.
- A file with no colours in it is reported in the banner rather than becoming a theme.
- A theme name the config asks for that no file or built-in provides is reported as
  `no theme named "…"` and `nyx-dark` is used.
- Colours you leave out come from `nyx-dark`, not from the built-in you are replacing. Nyx does not
  hold your file to the contrast floor.
- Interface colours (selection, search highlight, accent, tab tints) are derived from the sixteen
  ANSI slots, so a palette restyles the whole window.

## Key bindings

```
keybind = <modifier>+<modifier>+<key>=<action>
```

Modifiers: `cmd`, `ctrl` (or `control`), `alt` (or `opt`, `option`), `shift`. Keys: a single
character (lowercase; add `shift` explicitly), or one of `enter`/`return`, `tab`, `escape`/`esc`,
`space`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, `up`, `down`,
`left`, `right`, `f1`…`f12`. The chord is split at the *last* `=`, so `cmd+,=open_config` works.
A user binding beats a default for the same chord; the last line in the file wins.

| Action | Default | What it does |
|---|---|---|
| `new_window` | ⌘N | |
| `new_tab` | ⌘T | Inherits the working directory |
| `close_pane` | ⌘W | Closes the pane; the last pane closes the tab; the last tab closes the window |
| `next_tab` / `previous_tab` | ⌘⇧] / ⌘⇧[ | |
| `tab_1` … `tab_9` | ⌘1 … ⌘9 | |
| `split_right` / `split_down` | ⌘D / ⌘⇧D | |
| `focus_left` / `focus_right` / `focus_up` / `focus_down` | ⌘⌥ arrows | |
| `grow_left` / `grow_right` / `grow_up` / `grow_down` | ⌘⌃ arrows | Resize the focused pane |
| `toggle_zoom` | ⌘⇧⏎ | Focused pane fills the tab, and back |
| `copy` / `paste` | ⌘C / ⌘V | Paste is bracketed when the program asked for it |
| `paste_with_editor` | ⌘⇧V | Open the clipboard in the editor first |
| `clear_screen` | ⌘K | Clears screen and scrollback (`ED 3`) |
| `font_bigger` / `font_smaller` / `font_reset` | ⌘+ (⌘=) / ⌘- / ⌘0 | |
| `open_config` / `reload_config` | ⌘, / ⌘⇧, | ⌘, opens the settings window |
| `previous_prompt` / `next_prompt` | ⌘↑ / ⌘↓ | Needs shell integration |
| `select_command_output` / `copy_command_output` | — | The output of the command under the cursor / the last command |
| `find` / `find_next` / `find_previous` | ⌘F / ⌘G / ⌘⇧G | The bar has an "All tabs" scope toggle |
| `command_palette` | ⌘⇧P | Actions, themes, tabs, quick actions |
| `edit_and_run_command` | ⌘E | Opens the command under the cursor in the editor |
| `rename_tab` | ⌘⇧R | |
| `group_tab` / `ungroup_tab` / `toggle_tab_group` | ⌘⌃G / — / — | |
| `fold_command` / `fold_all_long_output` | ⌘⇧↑ / — | Fold the current command's output, keeping its last lines / fold every long one |
| `copy_block_markdown` | — | The last command and its output as a fenced Markdown block |
| `save_command_output` | — | Writes the last command's output to a file the user chooses |
| `notify_when_done` | — | Arm a notification for the command running now, however short it turns out |
| `save_scrollback` | — | Writes the transcript to a file the user chooses |

The menu is generated from `ActionCatalog.sections`, so every action is discoverable there with
its current chord, and the settings window's Keys page lists them all.

## Quick actions

```
quick = <name> | <kind> | <command>
quick = <name> | <command>              # kind defaults to send
```

| Kind | Behaviour |
|---|---|
| `send` | Types the command into the focused pane and runs it, as if you typed it (it lands in history) |
| `run` | Opens a new tab and runs it there |
| `toggle` | Starts it in the background; pressing again stops it. Made for `caffeinate -d` |

Buttons appear on the tab bar in file order, and in the command palette. The `+` on the bar and
the button's context menu add, edit, duplicate, reorder and remove them; those edits are written
back to the config file as ordinary `quick =` lines.

**Project actions.** A file named `.nyx` at a directory's root may contain `quick =` lines and
nothing else (other keys are ignored). When a pane's working directory enters that project, Nyx
shows a bar offering to review the file; approval is recorded against the file's digest, so an
edit, or a `git pull` that brings one in, revokes it until you look again. A cloned repository can
never put a command behind a button on its own.

## Environment variables

| Variable | Read by | Effect |
|---|---|---|
| `NYX_CONFIG` | app, tests | Path of the config file; the themes directory and `session.json` sit beside it |
| `NYX_SESSION` | app | Path of the session file, overriding the one beside the config |
| `NYX_UI_SNAPSHOT=<dir>` | app | Render every piece of chrome to PNGs in `<dir>` and exit. See `docs/testing.md` |
| `NYX_RENDER_STATS=1` | app | Print row-cache statistics per pane |
| `NYX_SNAPSHOT=1` | tests | Enable the end-to-end pixel snapshot test |
| `NYX_SIGN_IDENTITY`, `NYX_NOTARY_PROFILE` | `scripts/release.sh` | Developer ID identity and notarytool keychain profile |
| `NYX_SHELL_INTEGRATION_DIR`, `NYX_ZDOTDIR` | the shell shim | Set by Nyx for the zsh shim; tell an rc file that it is running inside Nyx and where the user's own `ZDOTDIR` was |

Nyx also sets `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Nyx` and
`TERM_PROGRAM_VERSION` in every session.
