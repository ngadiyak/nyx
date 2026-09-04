import Testing
import Metal
import NyxCore
@testable import NyxRender

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

private func renderSelection(_ selection: [Range<Int>?], cols: Int = 4, rows: Int = 2,
                             edit: (inout [Row]) -> Void = { _ in }) throws -> (FontSet, (Int, Int) -> Pixel) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    var lines = Array(repeating: Row(cols: cols), count: rows)
    edit(&lines)
    var palette = Palette.xtermDefault()
    palette.selectionBackground = RGB(0, 0, 255)
    let frame = RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: palette,
                            cursor: nil, cursorShape: .block, focused: true, preedit: nil,
                            selection: selection)
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

@Test func selectedCellsPaintTheSelectionBackground() throws {
    let (fonts, px) = try renderSelection([1..<3, nil])
    let w = fonts.metrics.width
    #expect(px(w / 2, 2) != Pixel(r: 0, g: 0, b: 255))          // column 0: not selected
    #expect(px(w + w / 2, 2) == Pixel(r: 0, g: 0, b: 255))      // column 1: selected
    #expect(px(2 * w + w / 2, 2) == Pixel(r: 0, g: 0, b: 255))  // column 2: selected
    #expect(px(3 * w + w / 2, 2) != Pixel(r: 0, g: 0, b: 255))  // column 3: not selected
}

@Test func unselectedRowsAreUntouched() throws {
    let (fonts, px) = try renderSelection([0..<4, nil])
    let m = fonts.metrics
    #expect(px(m.width / 2, 2) == Pixel(r: 0, g: 0, b: 255))
    #expect(px(m.width / 2, m.height + 2) != Pixel(r: 0, g: 0, b: 255))
}

@Test func anEmptySelectionArrayPaintsNothing() throws {
    let (fonts, px) = try renderSelection([])
    #expect(px(fonts.metrics.width / 2, 2) != Pixel(r: 0, g: 0, b: 255))
}

@Test func selectionOverridesTheCellBackground() throws {
    let (fonts, px) = try renderSelection([0..<1, nil]) { $0[0].cells[0].bg = .rgb(255, 0, 0) }
    #expect(px(fonts.metrics.width / 2, 2) == Pixel(r: 0, g: 0, b: 255))
}

@Test func selectionForegroundRecolorsTheGlyph() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    var lines = [Row(cols: 2)]
    lines[0].cells[0].content = 0x4D   // "M"
    var palette = Palette.xtermDefault()
    palette.selectionBackground = RGB(0, 0, 0)
    palette.selectionForeground = RGB(0, 255, 0)
    let frame = RenderFrame(cols: 2, rows: 1, lines: lines, graphemes: [], palette: palette,
                            cursor: nil, cursorShape: .block, focused: true, preedit: nil,
                            selection: [0..<1])
    let w = fonts.metrics.width * 2, h = fonts.metrics.height
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
    var greenest = 0
    for y in 0..<h {
        for x in 0..<fonts.metrics.width {
            let i = (y * w + x) * 4
            greenest = max(greenest, Int(bytes[i + 1]))
        }
    }
    #expect(greenest > 100)   // the glyph took the selection foreground, not the default grey
}
