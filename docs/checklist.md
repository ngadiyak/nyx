# Manual checklist

Run before every release from `build/Nyx.app`.

## Phase 1
- [ ] Launch to prompt (measure: `printf '\e]0;%s\a' "$(date +%s%N)"` in .zshrc is not needed; use `time swift run -c release Nyx` visually) — window visible < 300 ms
- [ ] Typing Latin, Cyrillic, dead keys (⌥e then e → é), emoji picker (⌃⌘Space)
- [ ] `vim` / `nvim` / `fzf` / `claude` / `tmux` (and `htop` if installed) render and exit cleanly
- [ ] `vttest` screens 1 (cursor movements) and 2 (screen features) pass visibly
- [ ] `cat` 100 MB of text: UI stays responsive, ⌘Q immediate
- [ ] Resize: no artifacts, reflow of long lines, vim redraws correctly after resize
- [ ] Scrollback with wheel/trackpad; typing returns to bottom
- [ ] ⌘V plain and bracketed paste; multi-line paste
- [ ] ⌘+/⌘-/⌘0 zoom
- [ ] Bell (`printf '\a'`) beeps
- [ ] Title (`printf '\e]0;hello\a'`) changes window title
- [ ] `printf '\e[?25l'` hides cursor; `\e[?25h` shows; `\e[5 q` bar cursor
- [ ] Unfocused window shows hollow cursor
- [ ] Idle CPU 0% in Activity Monitor after 10 s idle
