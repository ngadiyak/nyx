import Testing
@testable import NyxCore
@testable import NyxRender
import Metal

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

/// Primary colours, so a pixel names which rule painted it.
private func blockPalette() -> Palette {
    var colors = [RGB](repeating: RGB(0, 0, 0), count: 16)
    colors[1] = RGB(255, 0, 0)
    colors[2] = RGB(0, 255, 0)
    colors[3] = RGB(255, 255, 0)
    return Palette(ansi: colors, foreground: RGB(255, 255, 255), background: RGB(0, 0, 0),
                   cursor: RGB(0, 0, 255))
}

/// The chrome a command block draws, checked in pixels. The model has tests; these are about what
/// actually reaches the screen — which is where two of this feature's defects lived.
private func render(cols: Int = 8, rows: Int = 3, padding: Int,
                    spines: [(rows: Range<Int>, color: RGB)] = [],
                    summaries: [(row: Int, text: String, color: RGB)] = [],
                    notes: [String?] = [],
                    highlighted: Range<Int>? = nil,
                    selection: [Range<Int>?] = []) throws -> (FontSet, Int, (Int, Int) -> Pixel) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    let lines = Array(repeating: Row(cols: cols), count: rows)
    let frame = RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: blockPalette(),
                            cursor: nil, cursorShape: .block, focused: true, preedit: nil,
                            selection: selection,
                            rowNotes: notes, blockSpines: spines, blockSummaries: summaries,
                            highlightedRows: highlighted)
    let w = fonts.metrics.width * cols + padding * 2, h = fonts.metrics.height * rows + padding * 2
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                        mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    let tex = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(r.queue.makeCommandBuffer())
    r.render(frame, to: tex, commandBuffer: cb, padding: padding)
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (fonts, w, { x, y in
        let i = (y * w + x) * 4
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i])
    })
}

private let spineColor = RGB(0, 255, 0)

@Test func aSpineIsDrawnInThePaddingBesideItsRows() throws {
    let (fonts, _, px) = try render(padding: 8, spines: [(rows: 0..<2, color: spineColor)])
    // Beside the first two rows.
    #expect(px(6, 8 + fonts.metrics.height / 2) == Pixel(r: 0, g: 255, b: 0))
    // And not beside the third, which the block does not own.
    #expect(px(6, 8 + fonts.metrics.height * 2 + fonts.metrics.height / 2) != Pixel(r: 0, g: 255, b: 0))
}

/// The spine lives in the padding. With none there is nowhere to put it that is not the first
/// column of the user's output, and the settings window ships a Padding stepper that reaches zero.
@Test func noPaddingMeansNoSpine() throws {
    let (fonts, w, px) = try render(padding: 0, spines: [(rows: 0..<3, color: spineColor)])
    for x in 0..<min(4, w) {
        #expect(px(x, fonts.metrics.height / 2) != Pixel(r: 0, g: 255, b: 0), "column \(x)")
    }
}

/// The gutter's status pill sits at the far left of the padding. The spine must not be drawn on top
/// of it: two indicators sharing four points is one indicator drawn twice, in two systems, with the
/// AppKit one winning.
@Test func theSpineLeavesTheLeftmostPaddingToTheGutter() throws {
    let (fonts, _, px) = try render(padding: 8, spines: [(rows: 0..<1, color: spineColor)])
    let y = fonts.metrics.height / 2
    #expect(px(1, y) != Pixel(r: 0, g: 255, b: 0))
    #expect(px(2, y) != Pixel(r: 0, g: 255, b: 0))
}

/// The tint sits under the glyphs across the block's rows and nowhere else.
@Test func hoveredRowsAreTintedAndOthersAreNot() throws {
    let (fonts, w, px) = try render(padding: 0, highlighted: 0..<2)
    let mid = w / 2
    let tinted = px(mid, fonts.metrics.height / 2)
    let plain = px(mid, fonts.metrics.height * 2 + fonts.metrics.height / 2)
    #expect(tinted != Pixel(r: 0, g: 0, b: 0))
    #expect(plain == Pixel(r: 0, g: 0, b: 0))
}

/// A selection (or a search hit, or a coloured cell, or the block cursor) is a background instance
/// on top of the tint, not under it: it must stay visible on a hovered row, and only the cells with
/// nothing else painted on them show the tint through.
@Test func theTintNeverHidesWhatIsPaintedOnTopOfIt() throws {
    let (fonts, _, px) = try render(padding: 0, highlighted: 0..<1, selection: [0..<2])
    let y = fonts.metrics.height / 2
    let selectedX = fonts.metrics.width / 2
    let plainX = fonts.metrics.width * 4 + fonts.metrics.width / 2
    #expect(px(selectedX, y) == Pixel(r: blockPalette().selectionBackground.r,
                                      g: blockPalette().selectionBackground.g,
                                      b: blockPalette().selectionBackground.b))
    let tint = blockPalette().blockHoverBackground
    #expect(px(plainX, y) == Pixel(r: tint.r, g: tint.g, b: tint.b))
}

/// The chevron is a real glyph at the end of the summary, in the summary's colour.
@Test func theSummaryEndsInAChevron() throws {
    let (fonts, w, px) = try render(cols: 12, padding: 0,
                                    summaries: [(row: 0, text: "8.8s \u{25BE}", color: RGB(0, 255, 0))])
    let lastCell = (w - fonts.metrics.width)..<w
    var ink = 0
    for x in lastCell { for y in 0..<fonts.metrics.height where px(x, y).g > 100 { ink += 1 } }
    #expect(ink > 4)
}
