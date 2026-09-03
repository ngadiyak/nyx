import Testing
import Metal
import NyxCore
@testable import NyxRender

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

private func renderToPixels(_ frame: RenderFrame, padding: Int = 0) throws -> (Renderer, (Int, Int) -> Pixel) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    let w = fonts.metrics.width * frame.cols + padding * 2
    let h = fonts.metrics.height * frame.rows + padding * 2
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
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
    return (r, { x, y in
        let i = (y * w + x) * 4
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i])
    })
}

private func frame(cols: Int, rows: Int, _ edit: (inout [Row]) -> Void = { _ in }) -> RenderFrame {
    var lines = Array(repeating: Row(cols: cols), count: rows)
    edit(&lines)
    return RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: .xtermDefault(),
                       cursor: nil, cursorShape: .block, focused: true, preedit: nil)
}

@Test func paintsCellBackgrounds() throws {
    let f = frame(cols: 2, rows: 1) { $0[0].cells[0].bg = .rgb(255, 0, 0) }
    let (r, px) = try renderToPixels(f)
    let w = r.fonts.metrics.width
    #expect(px(2, 2) == Pixel(r: 255, g: 0, b: 0))
    #expect(px(w + 2, 2) == Pixel(r: 0, g: 0, b: 0))
}

@Test func paintsGlyphPixels() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].content = 0x4D }   // 'M'
    let (r, px) = try renderToPixels(f)
    let m = r.fonts.metrics
    var lit = 0
    for y in 0..<m.height { for x in 0..<m.width where px(x, y).r > 100 { lit += 1 } }
    #expect(lit > 10)
}

@Test func inverseSwapsColors() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].attrs.insert(.inverse) }
    let (_, px) = try renderToPixels(f)
    #expect(px(1, 1) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
}

@Test func blockCursorPaintsCursorColor() throws {
    var f = frame(cols: 2, rows: 1)
    f.cursor = Cursor(x: 1, y: 0)
    let (r, px) = try renderToPixels(f)
    #expect(px(r.fonts.metrics.width + 2, 2) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
}

@Test func unfocusedCursorIsHollow() throws {
    var f = frame(cols: 1, rows: 1)
    f.cursor = Cursor(x: 0, y: 0)
    f.focused = false
    let (r, px) = try renderToPixels(f)
    let m = r.fonts.metrics
    #expect(px(0, 0) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
    #expect(px(m.width / 2, m.height / 2) == Pixel(r: 0, g: 0, b: 0))
}

@Test func paddingOffsetsGrid() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].bg = .rgb(0, 255, 0) }
    let (_, px) = try renderToPixels(f, padding: 4)
    #expect(px(1, 1) == Pixel(r: 0, g: 0, b: 0))
    #expect(px(6, 6) == Pixel(r: 0, g: 255, b: 0))
}

@Test func underlineDrawsAtUnderlineY() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].underline = .single }
    let (r, px) = try renderToPixels(f)
    let m = r.fonts.metrics
    #expect(px(m.width / 2, m.underlineY) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
}

@Test func instanceLayoutMatchesShader() { #expect(MemoryLayout<Instance>.stride == 64) }
