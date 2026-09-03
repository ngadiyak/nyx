/// Display width of a Unicode scalar in terminal cells: 0 (combining/control/zero-width), 1, or 2 (East Asian wide, emoji presentation).
public enum CharWidth {
    public static func width(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        if v < 0x300 { return 1 }          // Latin, Latin-1, nothing wide or combining below U+0300
        if contains(WidthTable.zero, v) { return 0 }
        if contains(WidthTable.wide, v) { return 2 }
        return 1
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
