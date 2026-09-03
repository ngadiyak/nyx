import NyxCore

enum Theme {
    /// Default dark theme (Tokyo Night colors, MIT).
    static let nyxDark = Palette(
        ansi: [0x1E2129, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xFF7A93, 0xB9F27C, 0xFF9E64, 0x7DA6FF, 0xBB9AF7, 0x0DB9D7, 0xC0CAF5].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xC0CAF5),
        background: RGB(hex: 0x1A1B26),
        cursor: RGB(hex: 0xC0CAF5)
    )
}
