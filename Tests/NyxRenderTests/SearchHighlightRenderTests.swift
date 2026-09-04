import Testing
import Metal
import NyxCore
@testable import NyxRender

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

/// The palette used by every test here: search colours pinned to primaries so a pixel identifies
/// which of the three backgrounds -- match, current match, selection -- painted it.
private func testPalette() -> Palette {
    var ansi = Palette.xtermAnsi16
    ansi[3] = RGB(0, 255, 0)     // every match
    ansi[11] = RGB(255, 0, 255)  // the current match
    var palette = Palette(ansi: ansi, foreground: RGB(hex: 0xE5E5E5), background: RGB(0, 0, 0),
                          cursor: RGB(255, 0, 0))
    palette.selectionBackground = RGB(0, 0, 255)
    return palette
}

private func renderFrame(cols: Int = 4, rows: Int = 2,
                         selection: [Range<Int>?] = [],
                         matches: [[Range<Int>]] = [],
                         current: [Range<Int>?] = [],
                         hovered: [Range<Int>?] = [],
                         cursor: Cursor? = nil,
                         edit: (inout [Row]) -> Void = { _ in }) throws -> (FontSet, (Int, Int) -> Pixel) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    var lines = Array(repeating: Row(cols: cols), count: rows)
    edit(&lines)
    let frame = RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: testPalette(),
                            cursor: cursor, cursorShape: .block, focused: true, preedit: nil,
                            selection: selection, searchMatches: matches, currentSearchMatch: current,
                            hoveredLink: hovered)
    let w = fonts.metrics.width * cols, h = fonts.metrics.height * rows
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    let tex = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(r.queue.makeCommandBuffer())
    r.render(frame, to: tex, commandBuffer: cb, padding: 0)
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (fonts, { x, y in
        let i = (y * w + x) * 4
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i])
    })
}

/// The theme's match colour as it is actually painted: blended toward the background, so an
/// ordinary hit is a tint rather than a slab of green. The current hit stays full strength, and the
/// two being different is the property that matters.
private let matchColor = Pixel(r: 0, g: 115, b: 0)
private let rawMatchColor = Pixel(r: 0, g: 255, b: 0)
private let currentColor = Pixel(r: 255, g: 0, b: 255)
private let selectionColor = Pixel(r: 0, g: 0, b: 255)

@Test func matchedColumnsPaintTheMatchBackground() throws {
    let (fonts, px) = try renderFrame(matches: [[1..<3], []])
    let w = fonts.metrics.width
    #expect(px(w / 2, 2) != matchColor)
    #expect(px(w + w / 2, 2) == matchColor)
    #expect(px(2 * w + w / 2, 2) == matchColor)
    #expect(px(3 * w + w / 2, 2) != matchColor)
    // Subdued, not the raw theme colour: forty hits painted at full strength is a page of colour
    // in which the one you are standing on cannot be picked out.
    #expect(px(w + w / 2, 2) != rawMatchColor)
}

@Test func severalMatchesOnARowAreAllPainted() throws {
    let (fonts, px) = try renderFrame(matches: [[0..<1, 3..<4], []])
    let w = fonts.metrics.width
    #expect(px(w / 2, 2) == matchColor)
    #expect(px(3 * w + w / 2, 2) == matchColor)
    #expect(px(w + w / 2, 2) != matchColor)
}

/// The whole point of the second colour: stepping has to be visible without counting highlights.
@Test func theCurrentMatchIsPaintedInItsOwnColour() throws {
    let (fonts, px) = try renderFrame(matches: [[0..<1, 2..<3], []], current: [2..<3, nil])
    let w = fonts.metrics.width
    #expect(px(w / 2, 2) == matchColor)
    #expect(px(2 * w + w / 2, 2) == currentColor)
}

@Test func aMatchSitsOverTheCellsOwnBackground() throws {
    let (fonts, px) = try renderFrame(matches: [[0..<1], []]) { $0[0].cells[0].bg = .rgb(255, 0, 0) }
    #expect(px(fonts.metrics.width / 2, 2) == matchColor)
}

/// The selection is what ⌘C acts on, so it has to stay recognisable even where a hit is under it.
@Test func theSelectionWinsOverAMatch() throws {
    let (fonts, px) = try renderFrame(selection: [0..<1, nil], matches: [[0..<1], []])
    #expect(px(fonts.metrics.width / 2, 2) == selectionColor)
}

@Test func theBlockCursorWinsOverAMatch() throws {
    let (fonts, px) = try renderFrame(matches: [[0..<1], []], current: [0..<1, nil],
                                      cursor: Cursor(x: 0, y: 0))
    #expect(px(fonts.metrics.width / 2, 2) == Pixel(r: 255, g: 0, b: 0))
}

@Test func rowsWithNoMatchesAreUntouched() throws {
    let (fonts, px) = try renderFrame(matches: [[0..<4], []])
    let m = fonts.metrics
    #expect(px(m.width / 2, 2) == matchColor)
    #expect(px(m.width / 2, m.height + 2) != matchColor)
}

@Test func noHighlightArraysPaintNothing() throws {
    let (fonts, px) = try renderFrame()
    #expect(px(fonts.metrics.width / 2, 2) == Pixel(r: 0, g: 0, b: 0))
}

/// The hover underline is a decoration, not a background: the cell keeps its own colours and gains
/// a line on the underline baseline.
@Test func aHoveredLinkIsUnderlined() throws {
    let (fonts, px) = try renderFrame(hovered: [0..<2, nil])
    let m = fonts.metrics
    let underlineRow = m.underlineY + max(0, m.thickness / 2)
    #expect(px(m.width / 2, underlineRow) != Pixel(r: 0, g: 0, b: 0))
    #expect(px(2 * m.width + m.width / 2, underlineRow) == Pixel(r: 0, g: 0, b: 0))
}

@Test func nothingIsUnderlinedWithoutAHover() throws {
    let (fonts, px) = try renderFrame()
    let m = fonts.metrics
    #expect(px(m.width / 2, m.underlineY + max(0, m.thickness / 2)) == Pixel(r: 0, g: 0, b: 0))
}
