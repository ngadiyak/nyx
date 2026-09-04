import Foundation

/// A terminal color: default, one of 256 indexed colors, or 24-bit RGB. Packed in 32 bits.
public struct Color: Equatable, Hashable {
    public enum Kind: UInt8 { case `default` = 0, indexed = 1, rgb = 2 }

    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }
    public static let `default` = Color(raw: 0)
    public static func indexed(_ i: UInt8) -> Color { Color(raw: (1 << 24) | UInt32(i)) }
    public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
        Color(raw: (2 << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b))
    }

    public var kind: Kind { Kind(rawValue: UInt8(raw >> 24)) ?? .default }
    public var index: UInt8 { UInt8(raw & 0xFF) }
    public var r: UInt8 { UInt8((raw >> 16) & 0xFF) }
    public var g: UInt8 { UInt8((raw >> 8) & 0xFF) }
    public var b: UInt8 { UInt8(raw & 0xFF) }
}

public struct RGB: Equatable, Hashable {
    /// `amount` is how much of `other` shows through: 0 keeps `colour`, 1 gives `other`.
    public static func blend(_ colour: RGB, into other: RGB, amount: Double) -> RGB {
        let t = min(max(amount, 0), 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(a) * (1 - t) + Double(b) * t).rounded())))
        }
        return RGB(mix(colour.r, other.r), mix(colour.g, other.g), mix(colour.b, other.b))
    }

    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF); g = UInt8((hex >> 8) & 0xFF); b = UInt8(hex & 0xFF)
    }

    /// Parses "#rrggbb", "rgb:rr/gg/bb" and "rgb:rrrr/gggg/bbbb" (X11 forms used by OSC 4/10/11/12).
    public init?(spec: String) {
        if spec.hasPrefix("#"), spec.count == 7, let v = UInt32(spec.dropFirst(), radix: 16) {
            self.init(hex: v); return
        }
        if spec.hasPrefix("rgb:") {
            let parts = spec.dropFirst(4).split(separator: "/")
            guard parts.count == 3 else { return nil }
            var out = [UInt8]()
            for p in parts {
                guard let v = UInt32(p, radix: 16) else { return nil }
                switch p.count {
                case 1: out.append(UInt8(v * 17))
                case 2: out.append(UInt8(v))
                case 3: out.append(UInt8(v >> 4))
                case 4: out.append(UInt8(v >> 8))
                default: return nil
                }
            }
            self.init(out[0], out[1], out[2]); return
        }
        return nil
    }

    /// xterm response form, 16 bits per channel.
    public var xtermSpec: String { String(format: "rgb:%02x%02x/%02x%02x/%02x%02x", r, r, g, g, b, b) }

    public func scaled(_ f: Double) -> RGB {
        RGB(UInt8(Double(r) * f), UInt8(Double(g) * f), UInt8(Double(b) * f))
    }
}

public struct Palette: Equatable {
    public var colors: [RGB]
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    /// Background painted behind selected cells.
    public var selectionBackground: RGB
    /// Foreground for selected cells, or nil to keep each cell's own colour. Themes that pick a
    /// selection background close to the text colour set this; most do not need it.
    public var selectionForeground: RGB?

    /// `ansi` is the 16 base colors; the 6x6x6 cube and the 24-step gray ramp are always the xterm defaults.
    public init(ansi: [RGB], foreground: RGB, background: RGB, cursor: RGB,
                selectionBackground: RGB? = nil, selectionForeground: RGB? = nil) {
        precondition(ansi.count == 16)
        var c = ansi
        for i in 0..<216 {
            let r = i / 36, g = (i / 6) % 6, b = i % 6
            func v(_ x: Int) -> UInt8 { x == 0 ? 0 : UInt8(55 + 40 * x) }
            c.append(RGB(v(r), v(g), v(b)))
        }
        for i in 0..<24 { let v = UInt8(8 + 10 * i); c.append(RGB(v, v, v)) }
        colors = c
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selectionBackground = selectionBackground ?? foreground.scaled(0.35)
        self.selectionForeground = selectionForeground
    }

    public static let xtermAnsi16: [RGB] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ].map { RGB(hex: $0) }

    public static func xtermDefault() -> Palette {
        Palette(ansi: xtermAnsi16, foreground: RGB(hex: 0xE5E5E5), background: RGB(0, 0, 0), cursor: RGB(hex: 0xE5E5E5))
    }

    /// Background behind a search hit that is not the one being stepped through.
    ///
    /// Derived from the theme's own yellow rather than stored, so every built-in theme -- and every
    /// user theme file, which sets the same keys the built-ins do -- gets a search colour that
    /// belongs to it without a new setting to fill in. Yellow is what editors have settled on for
    /// find, and a theme's yellow is by construction legible against its background.
    /// Blended well toward the background rather than used at full strength. Every hit painted in
    /// full yellow makes a page of matches into a page of yellow, and -- worse -- makes the hit you
    /// are actually standing on indistinguishable from the forty you are not. Subdued here, full
    /// strength for the current one: the difference has to be visible at a glance, not on
    /// inspection.
    public var searchMatchBackground: RGB { RGB.blend(colors[3], into: background, amount: 0.55) }

    /// Background behind the current hit: the same hue, brighter, so the two are distinguishable
    /// at a glance without either becoming a different colour from "found text".
    public var currentMatchBackground: RGB { colors[11] }

    /// Text drawn on the *current* hit, which is painted at full strength. The background colour is
    /// the one thing a theme guarantees contrasts with its own yellow.
    ///
    /// The other hits keep the ordinary foreground: their highlight is a tint behind unchanged
    /// text, which is what makes them read as marked rather than as selected.
    public var searchMatchForeground: RGB { background }

    /// Mixes `colour` into `background`. `amount` is how much of the background wins, so 0 is the
    /// colour untouched and 1 is the background.
    static func blendedTowardBackground(_ colour: RGB, _ background: RGB, _ amount: Double) -> RGB {
        RGB.blend(colour, into: background, amount: amount)
    }

    public func resolve(_ c: Color, isForeground: Bool) -> RGB {
        switch c.kind {
        case .default: return isForeground ? foreground : background
        case .indexed: return colors[Int(c.index)]
        case .rgb: return RGB(c.r, c.g, c.b)
        }
    }
}
