import Foundation

/// Built-in color themes and the `~/.config/nyx/themes/<name>` file parser (spec §6.5).
public enum Themes {
    /// Default dark theme, on Tokyo Night's hues (MIT), with its bright row repaired.
    ///
    /// Tokyo Night's own 8..15 is three duplicates of the normal colour (red, blue, magenta), an
    /// orange sitting in the bright-yellow slot, and a bright cyan *darker* than the plain one --
    /// so bold text was sometimes the same colour, sometimes a different hue, and once dimmer than
    /// what it was emphasising. This is our theme rather than a port, so every bright here is the
    /// normal colour with more light in it and nothing else changed. The one real loss is the
    /// orange, which was the prettiest colour in the theme and the wrong colour to reach for when
    /// something asks for bright yellow -- the search highlight, which is built from that slot,
    /// came out orange in this theme and yellow in every other.
    private static let nyxDark = Palette(
        ansi: [0x1E2129, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xFF9EAE, 0xB9F27C, 0xFFC777, 0xA9C1FF, 0xD2B4FF, 0xB4E7FF, 0xD5DCFF].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xC0CAF5),
        background: RGB(hex: 0x1A1B26),
        cursor: RGB(hex: 0xC0CAF5)
    )

    /// Light counterpart with the same hues as `nyx-dark`, darkened just enough to read on a
    /// light background.
    ///
    /// Black was the same colour as bright white here -- both the foreground -- so anything
    /// printing black on bright white printed nothing at all; black is now the darkest colour in
    /// the theme and bright white stays the foreground. White and bright yellow were 2.2:1 and
    /// 2.7:1 against the page, which is a colour you can see is there and cannot read; both are
    /// darkened to clear 3.
    private static let nyxLight = Palette(
        ansi: [0x101119, 0x8C4351, 0x485E30, 0x8F5E15, 0x34548A, 0x5A4A78, 0x0F4B6E, 0x767B8B,
               0x545A6E, 0xC64343, 0x587539, 0x97731F, 0x2959AA, 0x7847BD, 0x007197, 0x343B58].map { RGB(hex: $0) },
        foreground: RGB(hex: 0x343B58),
        background: RGB(hex: 0xE1E2E7),
        cursor: RGB(hex: 0x34548A)
    )

    /// Solarized Dark (Ethan Schoonover, MIT), with its bright row repaired.
    /// https://ethanschoonover.com/solarized/
    ///
    /// The canonical xterm mapping puts Solarized's greyscale ramp -- base03..base1, the tones the
    /// palette designs *backgrounds and body text* from -- into slots 8, 10, 11, 12 and 14. Taken
    /// literally that gives a bright black identical to the background (invisible: 1.00:1), a
    /// bright yellow that is a grey, and a bright blue that is the foreground. Those five slots are
    /// now brighter mixes of Solarized's own accent hues; the accents themselves, the two greys
    /// that read (base02 as black, base01 as bright black) and base2/base3 as the whites are
    /// untouched. The foreground moves from base0 to base1, Solarized's own emphasised text, for
    /// 5.6:1 rather than 4.8:1 -- the theme is meant to be quiet, not unreadable, and every colour
    /// Nyx derives is bounded by how much contrast the foreground has to give away.
    private static let solarizedDark = Palette(
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x586E75, 0xCB4B16, 0x9EB300, 0xD3A400, 0x4FA6E8, 0x8A8FDC, 0x3FBFB4, 0xFDF6E3].map { RGB(hex: $0) },
        foreground: RGB(hex: 0x93A1A1),
        background: RGB(hex: 0x002B36),
        cursor: RGB(hex: 0x93A1A1),
        // base02 is 5 units from base03 in Lab: a selection you cannot see is not a selection.
        selectionBackground: RGB(hex: 0x0E4A57)
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
    ///
    /// Upstream deliberately repeats each hue in the bright row, which is a defensible way to run a
    /// sixteen-colour palette on eight hues and is left alone. Bright white is the one slot that is
    /// wrong rather than repeated: upstream puts Subtext0 there and Subtext1 in plain white, so
    /// bright white came out *dimmer* than white. It is Text here, the colour the theme calls its
    /// brightest.
    private static let catppuccinMocha = Palette(
        ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
               0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xCDD6F4].map { RGB(hex: $0) },
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
                // Only mark the line recognised when the index actually landed somewhere -- an
                // out-of-range index (matching ConfigGrammar.paletteEntry's 0..<256 bound) stores
                // nothing, so it must not count towards "this file has colours".
                if let (idx, c) = ConfigGrammar.paletteEntry(value) {
                    if idx < 16 { ansi[idx] = c } else { extended[idx] = c }
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
