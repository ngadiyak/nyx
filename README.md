# Nyx

A fast, light, native terminal for macOS. Swift + Metal, no dependencies, no Xcode required.

    make run        # build & launch from SwiftPM
    make test       # unit tests (swift-testing)
    make app        # build/Nyx.app
    make install    # copy to /Applications
    make bench      # parser throughput

Design: docs/superpowers/specs/2026-09-03-nyx-terminal-design.md

## Snapshot test

`Tests/NyxRenderTests/SnapshotTests.swift` is an opt-in end-to-end regression test: it drives a
real `zsh` through `TerminalSession` into the `Renderer` and reads pixels back from the rendered
Metal texture. It exercises the full pipeline (PTY → parser → `Terminal` → `Renderer` → texture)
with real programs — a shell prompt with SGR attributes, Cyrillic/CJK/emoji, an alt-screen editor
session (`vim`), a resize, and a scrollback scroll — which is what caught a glyph-orientation bug
that every unit test missed. It asserts, from the rendered pixels, that the frame isn't blank and
that a capital "L" has more ink in its lower half than its upper half (the orientation check unit
tests missed), then writes PNGs to `build/snapshots/` for human inspection.

It's skipped by default so `make test` stays fast and deterministic. Run it with:

    NYX_SNAPSHOT=1 swift test --filter Snapshot
