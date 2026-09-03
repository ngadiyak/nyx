/// Display width of a Unicode scalar in terminal cells: 0 (combining/control/zero-width), 1, or 2 (East Asian wide, emoji presentation).
public enum CharWidth {
    public static func width(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        if v < 0x300 { return 1 }          // Latin, Latin-1, nothing wide or combining below U+0300
        if v < 0x10000 {
            // Two bit tests instead of two binary searches over the range tables. Cyrillic, Greek
            // and CJK all land here, and they are most of the non-ASCII traffic in real output.
            let word = Int(v >> 6), bit = UInt64(1) << UInt64(v & 63)
            if bmpZero[word] & bit != 0 { return 0 }
            if bmpWide[word] & bit != 0 { return 2 }
            return 1
        }
        if contains(WidthTable.zero, v) { return 0 }
        if contains(WidthTable.wide, v) { return 2 }
        return 1
    }

    /// Bitmaps of the BMP portion of the range tables, one bit per scalar (8 KB each), built once.
    private static let bmpZero: [UInt64] = bitmap(of: WidthTable.zero)
    private static let bmpWide: [UInt64] = bitmap(of: WidthTable.wide)

    private static func bitmap(of table: [UInt32]) -> [UInt64] {
        var bits = [UInt64](repeating: 0, count: 0x10000 / 64)
        var i = 0
        while i + 1 < table.count {
            let lo = table[i]
            if lo < 0x10000 {
                var v = lo
                let hi = min(table[i + 1], 0xFFFF)
                while v <= hi {
                    bits[Int(v >> 6)] |= UInt64(1) << UInt64(v & 63)
                    v += 1
                }
            }
            i += 2
        }
        return bits
    }

    /// Width of a grapheme cluster: width of its first non-zero scalar, promoted to 2 by VS16 (U+FE0F).
    public static func width(of cluster: String) -> Int {
        var result = 0
        for s in cluster.unicodeScalars {
            if result == 0 { result = width(s) }
            if s.value == 0xFE0F { result = 2 }
        }
        return result
    }

    @inline(__always)
    static func contains(_ table: [UInt32], _ v: UInt32) -> Bool {
        var lo = 0
        var hi = table.count / 2 - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let a = table[mid * 2], b = table[mid * 2 + 1]
            if v < a { hi = mid - 1 } else if v > b { lo = mid + 1 } else { return true }
        }
        return false
    }
}
