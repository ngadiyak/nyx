---
name: nyx-rendering
description: Use when touching `RenderFrame`, `Renderer`, `GlyphAtlas`, `FontSet`, `Shaders.swift`, `SyncOutputGate`, dirty-row tracking, or anything drawn per cell or per row in the terminal grid — colours, underlines, cursor, selection, search highlights, notes, spines.
---

# Rendering the grid

`Renderer` sees a `RenderFrame` and nothing else: rows, graphemes, palette, cursor, focus, preedit,
and per-row arrays (selection, search matches, current match, hovered link, notes, spines,
summaries, dirty flags). The pane builds it under the session lock. Three instanced draw calls:
backgrounds, glyphs, decorations. The whole design is in `docs/architecture.md` §NyxRender.

## The one rule that bites

The renderer keeps the instances it built for each visible row and rebuilds a row only when its
key changed. **Anything `buildRow` reads must be part of `RowKey` (per row) or `FrameKey` (whole
frame), or be drawn in `buildChrome` outside the cache.** Otherwise the screen shows last frame's
row for that input, and no unit test of the drawing catches it: the symptom is "sometimes the
terminal is wrong".

So, for a new `RenderFrame` input:

1. Add the field with a doc comment saying what it is indexed by (visible row, like `selection`).
2. Decide: per row → `RowKey`; every row → `FrameKey`; drawn over everything and cheap → chrome.
3. Add a scenario to `Tests/NyxRenderTests/PartialRedrawTests.swift` that changes only that input
   between two frames and asserts the cache-using renderer matches a full rebuild pixel for pixel.
4. Fill it in `Pane.render()` from Core (`SearchHighlights.visibleRanges` is the pattern for
   absolute → viewport arithmetic; do the arithmetic in Core, not in the pane).

## Pixel tests

`Tests/NyxRenderTests/RendererTests.swift` has `renderToPixels(frame)`: a real `Renderer` on the
default Metal device into a managed texture, read back as `(x, y) → RGB`. One test per visual
rule, asserting a pixel, not a call:

```swift
@Test func curlyUnderlineUsesTheUnderlineColour() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].content = 0x5F; $0[0].cells[0].underline = .curly
                                      $0[0].cells[0].ul = .rgb(255, 0, 0) }
    let (r, px) = try renderToPixels(f)
    let m = r.fonts.metrics
    #expect((0..<m.width).contains { px($0, m.height - 2).r > 200 })
}
```

Tests need a Metal device; CI has one. Menlo at 12 pt, scale 1, is the fixture font.

## Dirty flags and presentation

- `Row.dirty` is set by the model, cleared by `Terminal.clearDirty(ifContentVersionIs:)`, which the
  pane calls only after `draw` returned `.presented` and only if no `feed` happened meanwhile.
- `ViewportMapping.mayTrustDirtyFlags` (Core, tested) decides whether slot *y* still holds the row
  it held last frame. When it does not, the frame sends `dirtyRows: []`, meaning "rebuild all".
  Scrolling back, a fold opening, `ED 3`, ring trimming, resize and alt-screen all move the mapping.
- `.held` means a synchronised update (DECSET 2026) is in progress: keep the frame stale. The gate
  expires after 150 ms; `syncOutputTimeout` is settable for tests.
- `.noDrawable` is transient; retry next tick; nothing was cleared.

## Atlas and fonts

- `GlyphAtlas.generation` bumps on reset and on `setFonts`; it is in `FrameKey`, so a font change
  or a repack empties the row cache. Count resets when adding fallback-heavy content (emoji, Nerd
  icons): a reset per frame is a cliff.
- Colour glyphs take a separate shader path (`kind` on `Instance`); the atlas is RGBA so both live
  in one texture.
- `Instance` is 64 bytes and must match `struct Instance` in `Shaders.swift` field for field; the
  shader is compiled from that string at runtime, and a mismatch is garbage on screen with no
  compiler error.

## Measure, do not describe

`NYX_RENDER_STATS=1` prints `RenderStats` per pane (rows seen, rebuilt, full invalidations). A
spinner should rebuild ~2 % of rows; a full repaint 100 %. `make bench` ×3 for anything on the
`feed` side. The `render-performance` agent does the before/after when the claim is "faster".

## Common mistakes

- Reading `frame.cursor` in a row build without putting the cursor column in `RowKey`.
- Computing absolute → viewport ranges in the pane instead of a Core helper with tests.
- Clearing dirty flags after *building* the frame rather than after it was presented.
- Marking only the moved rows dirty on a scroll; the whole region moved.
- A new decoration drawn in the glyph pass (wrong draw order; the cursor must be above text).
