import Testing
import Metal
@testable import NyxRender

private func makeAtlas() throws -> GlyphAtlas {
    let device = try #require(MTLCreateSystemDefaultDevice())
    return GlyphAtlas(device: device, fonts: FontSet(family: "Menlo", pointSize: 13, scale: 2))
}

@Test func rasterizesLatinGlyph() throws {
    let atlas = try makeAtlas()
    let g = try #require(atlas.glyph(for: GlyphKey(text: .scalar(0x41), bold: false, italic: false)))
    #expect(g.width > 0 && g.height > 0)
    #expect(!g.isColor)
    #expect(g.top >= 0 && g.top < atlas.fonts.metrics.baseline)
    #expect(g.left > -3)
}

@Test func spaceHasNoGlyph() throws {
    let atlas = try makeAtlas()
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x20), bold: false, italic: false)) == nil)
}

@Test func cachesGlyphs() throws {
    let atlas = try makeAtlas()
    let k = GlyphKey(text: .scalar(0x42), bold: true, italic: false)
    let a = atlas.glyph(for: k), b = atlas.glyph(for: k)
    #expect(a == b)
}

@Test func emojiIsColorAndWide() throws {
    let atlas = try makeAtlas()
    let g = try #require(atlas.glyph(for: GlyphKey(text: .scalar(0x1F600), bold: false, italic: false)))
    #expect(g.isColor)
    #expect(g.width > atlas.fonts.metrics.width)
}

@Test func cyrillicAndClusterFallback() throws {
    let atlas = try makeAtlas()
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x44F), bold: false, italic: false)) != nil)   // я
    #expect(atlas.glyph(for: GlyphKey(text: .cluster("e\u{0301}"), bold: false, italic: false)) != nil)
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x2500), bold: false, italic: false)) != nil)  // ─
}

@Test func overflowResetsAtlas() throws {
    let atlas = try makeAtlas()
    let g0 = atlas.generation
    for cp in 0x4E00..<0x4E00 + 12000 {     // CJK: far more than one 2048² page holds at this size
        _ = atlas.glyph(for: GlyphKey(text: .scalar(UInt32(cp)), bold: false, italic: false))
    }
    #expect(atlas.generation > g0)
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x41), bold: false, italic: false)) != nil)
}

@Test func glyphBitmapIsUploadedTopDown() throws {
    let atlas = try makeAtlas()
    let g = try #require(atlas.glyph(for: GlyphKey(text: .scalar(0x2580), bold: false, italic: false)))
    var bytes = [UInt8](repeating: 0, count: g.width * g.height * 4)
    atlas.texture.getBytes(&bytes, bytesPerRow: g.width * 4, from: MTLRegionMake2D(g.x, g.y, g.width, g.height), mipmapLevel: 0)
    func alpha(row: Int) -> Int { (0..<g.width).map { Int(bytes[(row * g.width + $0) * 4 + 3]) }.reduce(0, +) }
    #expect(alpha(row: 2) > 0)                 // just inside the top padding: filled
    #expect(alpha(row: g.height - 2) == 0)     // just inside the bottom padding: empty
    #expect(g.top >= 0)
}
