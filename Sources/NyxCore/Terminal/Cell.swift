public struct CellAttrs: OptionSet, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold       = CellAttrs(rawValue: 1 << 0)
    public static let dim        = CellAttrs(rawValue: 1 << 1)
    public static let italic     = CellAttrs(rawValue: 1 << 2)
    public static let strike     = CellAttrs(rawValue: 1 << 3)
    public static let inverse    = CellAttrs(rawValue: 1 << 4)
    public static let blink      = CellAttrs(rawValue: 1 << 5)
    public static let hidden     = CellAttrs(rawValue: 1 << 6)
    public static let wide       = CellAttrs(rawValue: 1 << 7)   // first half of a 2-column glyph
    public static let wideSpacer = CellAttrs(rawValue: 1 << 8)   // second half; never drawn
    static let underlineMask     = CellAttrs(rawValue: 0b111 << 9)
}

public enum UnderlineStyle: UInt16 { case none = 0, single, double, curly, dotted, dashed }

/// One screen cell. 20 bytes.
public struct Cell: Equatable {
    /// 0 = empty. Otherwise a Unicode scalar value, or `graphemeFlag | index` into `Terminal.graphemes` for multi-scalar clusters.
    public var content: UInt32 = 0
    public var fg: Color = .default
    public var bg: Color = .default
    public var ul: Color = .default          // underline color (SGR 58)
    public var attrs: CellAttrs = []
    public var hyperlink: UInt16 = 0         // 0 = none, otherwise 1-based index into `Terminal.hyperlinks`

    public init() {}

    public static let graphemeFlag: UInt32 = 0x8000_0000

    public var underline: UnderlineStyle {
        get { UnderlineStyle(rawValue: (attrs.rawValue >> 9) & 0b111) ?? .none }
        set { attrs = CellAttrs(rawValue: (attrs.rawValue & ~CellAttrs.underlineMask.rawValue) | (newValue.rawValue << 9)) }
    }

    public var graphemeIndex: Int? {
        content & Cell.graphemeFlag != 0 ? Int(content & ~Cell.graphemeFlag) : nil
    }

    public var scalar: Unicode.Scalar? {
        content == 0 || content & Cell.graphemeFlag != 0 ? nil : Unicode.Scalar(content)
    }
}

/// Current SGR state applied to newly printed cells.
public struct Pen: Equatable {
    public var fg: Color = .default
    public var bg: Color = .default
    public var ul: Color = .default
    public var attrs: CellAttrs = []
    public var underline: UnderlineStyle = .none
    public var hyperlink: UInt16 = 0

    public init() {}

    public func makeCell() -> Cell {
        var c = Cell()
        c.fg = fg; c.bg = bg; c.ul = ul; c.attrs = attrs; c.underline = underline; c.hyperlink = hyperlink
        return c
    }
}
