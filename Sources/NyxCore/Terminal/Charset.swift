enum Charset: Equatable {
    case ascii
    case decSpecial

    /// DEC Special Graphics maps 0x60...0x7E to line-drawing glyphs.
    private static let decSpecialTable: [Unicode.Scalar] = Array("◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·".unicodeScalars)

    func map(_ s: Unicode.Scalar) -> Unicode.Scalar {
        guard self == .decSpecial, (0x60...0x7E).contains(s.value) else { return s }
        return Charset.decSpecialTable[Int(s.value - 0x60)]
    }
}
