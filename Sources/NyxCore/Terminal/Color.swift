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

    /// `ansi` is the 16 base colors; the 6x6x6 cube and the 24-step gray ramp are always the xterm defaults.
    public init(ansi: [RGB], foreground: RGB, background: RGB, cursor: RGB) {
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
    }

    public static let xtermAnsi16: [RGB] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ].map { RGB(hex: $0) }

    public static func xtermDefault() -> Palette {
        Palette(ansi: xtermAnsi16, foreground: RGB(hex: 0xE5E5E5), background: RGB(0, 0, 0), cursor: RGB(hex: 0xE5E5E5))
    }

    public func resolve(_ c: Color, isForeground: Bool) -> RGB {
        switch c.kind {
        case .default: return isForeground ? foreground : background
        case .indexed: return colors[Int(c.index)]
        case .rgb: return RGB(c.r, c.g, c.b)
        }
    }
}
