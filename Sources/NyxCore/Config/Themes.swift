import Foundation

/// Built-in color themes and the `~/.config/nyx/themes/<name>` file parser (spec §6.5).
public enum Themes {
    /// Default dark theme (Tokyo Night colors, MIT), moved here from `NyxApp/Theme.swift`.
    private static let nyxDark = Palette(
        ansi: [0x1E2129, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xFF7A93, 0xB9F27C, 0xFF9E64, 0x7DA6FF, 0xBB9AF7, 0x0DB9D7, 0xC0CAF5].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xC0CAF5),
        background: RGB(hex: 0x1A1B26),
        cursor: RGB(hex: 0xC0CAF5)
    )

    /// Light counterpart with the same hues as `nyx-dark`, darkened just enough to read on a
    /// light background.
    private static let nyxLight = Palette(
        ansi: [0x343B58, 0x8C4351, 0x485E30, 0x8F5E15, 0x34548A, 0x5A4A78, 0x0F4B6E, 0x9699A3,
               0x4C505E, 0xC64343, 0x587539, 0xA1863D, 0x2959AA, 0x7847BD, 0x007197, 0x343B58].map { RGB(hex: $0) },
        foreground: RGB(hex: 0x343B58),
        background: RGB(hex: 0xE1E2E7),
        cursor: RGB(hex: 0x34548A)
    )

    /// Solarized Dark (Ethan Schoonover, MIT). https://ethanschoonover.com/solarized/
    private static let solarizedDark = Palette(
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3].map { RGB(hex: $0) },
        foreground: RGB(hex: 0x839496),
        background: RGB(hex: 0x002B36),
        cursor: RGB(hex: 0x839496),
        selectionBackground: RGB(hex: 0x073642)
    )

    /// Gruvbox Dark, medium contrast (morhetz/gruvbox, MIT).
    private static let gruvboxDark = Palette(
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xEBDBB2),
        background: RGB(hex: 0x282828),
        cursor: RGB(hex: 0xEBDBB2),
        selectionBackground: RGB(hex: 0x504945)
    )

    /// Dracula (draculatheme.com, MIT).
    private static let dracula = Palette(
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xF8F8F2),
        background: RGB(hex: 0x282A36),
        cursor: RGB(hex: 0xF8F8F2),
        selectionBackground: RGB(hex: 0x44475A)
    )

    /// Catppuccin Mocha (catppuccin.com, MIT).
    private static let catppuccinMocha = Palette(
        ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
               0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xCDD6F4),
        background: RGB(hex: 0x1E1E2E),
        cursor: RGB(hex: 0xF5E0DC),
        selectionBackground: RGB(hex: 0x45475A)
    )

    /// One Dark, as popularized by Atom's default syntax theme.
    private static let oneDark = Palette(
        ansi: [0x1E2127, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xABB2BF),
        background: RGB(hex: 0x282C34),
        cursor: RGB(hex: 0x528BFF),
        selectionBackground: RGB(hex: 0x3E4451)
    )

    /// Every built-in theme, by name.
    public static let builtin: [String: Palette] = [
        "nyx-dark": nyxDark,
        "nyx-light": nyxLight,
        "solarized-dark": solarizedDark,
        "gruvbox-dark": gruvboxDark,
        "dracula": dracula,
        "catppuccin-mocha": catppuccinMocha,
        "one-dark": oneDark,
    ]

    /// Looks up a theme, falling back to `nyx-dark` when the name is unknown.
    public static func palette(named name: String) -> Palette {
        builtin[name] ?? nyxDark
    }

    /// Parses a theme file: the same `key = value` grammar as the config, with keys `palette`,
    /// `foreground`, `background`, `cursor`, `selection`, `selection-foreground`. Returns nil when
    /// no colour key was recognized, which is what makes a stray file in the themes directory
    /// harmless rather than a theme that silently keeps every default.
    public static func parse(_ text: String) -> Palette? {
        var ansi = Palette.xtermAnsi16
        var extended: [Int: RGB] = [:]
        var foreground: RGB?
        var background: RGB?
        var cursor: RGB?
        var selectionBackground: RGB?
        var selectionForeground: RGB?
        var recognizedAny = false

        for rawLine in ConfigGrammar.lines(text) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "foreground":
                if let c = RGB(spec: value) { foreground = c; recognizedAny = true }
            case "background":
                if let c = RGB(spec: value) { background = c; recognizedAny = true }
            case "cursor":
                if let c = RGB(spec: value) { cursor = c; recognizedAny = true }
            case "selection":
                if let c = RGB(spec: value) { selectionBackground = c; recognizedAny = true }
            case "selection-foreground":
                if let c = RGB(spec: value) { selectionForeground = c; recognizedAny = true }
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2,
                   let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   let c = RGB(spec: parts[1].trimmingCharacters(in: .whitespaces)) {
                    if idx >= 0 && idx < 16 { ansi[idx] = c } else if idx >= 0 && idx < 256 { extended[idx] = c }
                    recognizedAny = true
                }
            default:
                break
            }
        }

        guard recognizedAny else { return nil }

        var palette = Palette(
            ansi: ansi,
            foreground: foreground ?? nyxDark.foreground,
            background: background ?? nyxDark.background,
            cursor: cursor ?? foreground ?? nyxDark.cursor,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground
        )
        for (idx, c) in extended { palette.colors[idx] = c }
        return palette
    }
}
