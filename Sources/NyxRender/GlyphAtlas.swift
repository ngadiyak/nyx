import CoreText
import CoreGraphics
import Metal
import Foundation

public enum GlyphText: Hashable {
    case scalar(UInt32)
    case cluster(String)
}

public struct GlyphKey: Hashable {
    public var text: GlyphText
    public var bold: Bool
    public var italic: Bool
    public init(text: GlyphText, bold: Bool, italic: Bool) { self.text = text; self.bold = bold; self.italic = italic }
}

public struct Glyph: Equatable {
    public var x: Int, y: Int, width: Int, height: Int   // rect in the atlas, pixels
    public var left: Int, top: Int                        // draw offset from the cell's top-left, pixels
    public var isColor: Bool
}

/// Rasterises glyphs with Core Text into one RGBA8 texture using shelf packing. When full, it resets and bumps `generation`.
public final class GlyphAtlas {
    public static let size = 2048
    public let texture: MTLTexture
    public private(set) var fonts: FontSet
    public private(set) var generation = 0

    private var cache: [GlyphKey: Glyph?] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    public init(device: MTLDevice, fonts: FontSet) {
        self.fonts = fonts
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: GlyphAtlas.size, height: GlyphAtlas.size, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        texture = device.makeTexture(descriptor: desc)!
    }

    public func setFonts(_ f: FontSet) {
        fonts = f
        reset()
    }

    public func reset() {
        cache.removeAll(keepingCapacity: true)
        shelfX = 0; shelfY = 0; shelfHeight = 0
        generation += 1
    }

    public func glyph(for key: GlyphKey) -> Glyph? {
        if let cached = cache[key] { return cached }
        let g = rasterize(key)
        cache[key] = g
        return g
    }

    private func rasterize(_ key: GlyphKey) -> Glyph? {
        let text: String
        switch key.text {
        case .scalar(let v):
            guard let s = Unicode.Scalar(v) else { return nil }
            text = String(s)
        case .cluster(let s):
            text = s
        }
        if text.isEmpty || text == " " { return nil }

        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        let font = CTFontCreateForString(fonts.font(bold: key.bold, italic: key.italic), cfText, range)
        let isColor = CTFontGetSymbolicTraits(font).contains(.colorGlyphsTrait)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: white]
        guard let attributed = CFAttributedStringCreate(nil, cfText, attrs as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        if bounds.width <= 0 || bounds.height <= 0 { bounds = CTLineGetBoundsWithOptions(line, []) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let pad = 1
        let minX = Int(floor(bounds.minX)), maxX = Int(ceil(bounds.maxX))
        let minY = Int(floor(bounds.minY)), maxY = Int(ceil(bounds.maxY))
        let w = maxX - minX + 2 * pad
        let h = maxY - minY + 2 * pad
        guard w <= GlyphAtlas.size, h <= GlyphAtlas.size,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldAntialias(true)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(true)
        ctx.textPosition = CGPoint(x: CGFloat(pad - minX), y: CGFloat(pad - minY))
        CTLineDraw(line, ctx)

        guard let (ax, ay) = allocate(w: w, h: h), let data = ctx.data else { return nil }
        let src = data.assumingMemoryBound(to: UInt8.self)
        var flipped = [UInt8](repeating: 0, count: w * h * 4)
        flipped.withUnsafeMutableBytes { dst in
            for row in 0..<h {
                memcpy(dst.baseAddress! + row * w * 4, src + (h - 1 - row) * w * 4, w * 4)
            }
        }
        texture.replace(region: MTLRegionMake2D(ax, ay, w, h), mipmapLevel: 0, withBytes: flipped, bytesPerRow: w * 4)
        return Glyph(x: ax, y: ay, width: w, height: h,
                     left: minX - pad, top: fonts.metrics.baseline - maxY - pad, isColor: isColor)
    }

    private func allocate(w: Int, h: Int) -> (Int, Int)? {
        if shelfX + w > GlyphAtlas.size {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        if shelfY + h > GlyphAtlas.size {
            reset()
            if h > GlyphAtlas.size { return nil }
        }
        let pos = (shelfX, shelfY)
        shelfX += w
        shelfHeight = max(shelfHeight, h)
        return pos
    }
}
