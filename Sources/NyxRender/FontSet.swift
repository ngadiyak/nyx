import CoreText
import CoreGraphics
import Foundation

/// Cell geometry in device pixels, derived from the regular font.
public struct CellMetrics: Equatable {
    public var width: Int
    public var height: Int
    public var baseline: Int      // from cell top
    public var underlineY: Int    // from cell top
    public var thickness: Int
    public var strikeY: Int       // from cell top
}

public final class FontSet {
    public let regular: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont
    public let pointSize: CGFloat
    public let scale: CGFloat
    public let metrics: CellMetrics

    /// `baseFont` overrides the family lookup entirely.
    ///
    /// It exists for one font: macOS's own monospaced UI face, SF Mono, which Apple exposes only
    /// through `NSFont.monospacedSystemFont` -- CoreText's `userFixedPitch` returns Menlo, and
    /// asking for it by any of its internal names quietly returns Helvetica. `NyxRender` cannot
    /// import AppKit, so the app layer resolves that one font and hands the `CTFont` down; every
    /// other family still arrives as a name.
    public init(family: String, pointSize: CGFloat, scale: CGFloat, lineHeight: CGFloat = 1.0,
                baseFont: CTFont? = nil) {
        self.pointSize = pointSize
        self.scale = scale
        let px = pointSize * scale
        let base = baseFont.map { CTFontCreateCopyWithAttributes($0, px, nil, nil) }
            ?? FontSet.resolveFont(named: family, size: px)
        regular = base
        bold = CTFontCreateCopyWithSymbolicTraits(base, px, nil, .boldTrait, .boldTrait) ?? base
        italic = CTFontCreateCopyWithSymbolicTraits(base, px, nil, .italicTrait, .italicTrait) ?? base
        boldItalic = CTFontCreateCopyWithSymbolicTraits(base, px, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? base

        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        var glyph: CGGlyph = 0
        var ch: UniChar = 0x4D   // 'M'
        CTFontGetGlyphsForCharacters(base, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let width = max(1, Int(ceil(advance.width)))
        let natural = ascent + descent + leading
        let height = max(1, Int(ceil(natural * lineHeight)))
        let extra = CGFloat(height) - natural
        let baseline = Int(round(ascent + extra / 2))
        let thickness = max(1, Int(round(CTFontGetUnderlineThickness(base))))
        let ulOffset = Int(round(-CTFontGetUnderlinePosition(base)))
        let underlineY = min(height - thickness, baseline + max(1, ulOffset))
        let strikeY = max(1, baseline - Int(round(CTFontGetXHeight(base) / 2)))
        metrics = CellMetrics(width: width, height: height, baseline: baseline,
                              underlineY: underlineY, thickness: thickness, strikeY: strikeY)
    }

    public func font(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (false, false): return regular
        case (true, false): return self.bold
        case (false, true): return self.italic
        case (true, true): return boldItalic
        }
    }

    private static func resolveFont(named name: String, size px: CGFloat) -> CTFont {
        for key in [kCTFontFamilyNameAttribute, kCTFontNameAttribute, kCTFontDisplayNameAttribute] {
            let desc = CTFontDescriptorCreateWithAttributes([key: name] as CFDictionary)
            if let matched = CTFontDescriptorCreateMatchingFontDescriptor(desc, nil) {
                return CTFontCreateWithFontDescriptor(matched, px, nil)
            }
        }
        return CTFontCreateWithName("Menlo" as CFString, px, nil)
    }
}
