import Testing
import Foundation
@testable import NyxCore

@Test func everySpecifiedThemeExists() {
    for name in ["nyx-dark", "nyx-light", "solarized-dark", "gruvbox-dark", "dracula", "catppuccin-mocha", "one-dark"] {
        #expect(Themes.builtin[name] != nil, "missing theme \(name)")
    }
}

@Test func everyThemeHasAFullPalette() {
    for (name, p) in Themes.builtin {
        #expect(p.colors.count == 256, "\(name) has \(p.colors.count) colours")
    }
}

@Test func everyThemeHasReadableContrast() {
    // A theme whose foreground and background are close is unusable. Compare relative luminance.
    func luminance(_ c: RGB) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }
    for (name, p) in Themes.builtin {
        let a = luminance(p.foreground), b = luminance(p.background)
        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        #expect(ratio > 4.5, "\(name) contrast ratio is \(ratio)")
    }
}

@Test func lightThemesAreActuallyLight() {
    let light = try! #require(Themes.builtin["nyx-light"])
    #expect(Int(light.background.r) + Int(light.background.g) + Int(light.background.b) > 600)
}

@Test func lookupFallsBackToTheDefault() {
    #expect(Themes.palette(named: "no-such-theme") == Themes.palette(named: "nyx-dark"))
}

@Test func parsesAThemeFile() {
    let p = Themes.parse("""
    # my theme
    background = #101010
    foreground = #e0e0e0
    cursor = #ff0000
    selection = #303060
    palette = 1=#ff5555
    palette = 2=#55ff55
    """)
    let theme = try! #require(p)
    #expect(theme.background == RGB(0x10, 0x10, 0x10))
    #expect(theme.foreground == RGB(0xe0, 0xe0, 0xe0))
    #expect(theme.cursor == RGB(255, 0, 0))
    #expect(theme.selectionBackground == RGB(0x30, 0x30, 0x60))
    #expect(theme.colors[1] == RGB(255, 0x55, 0x55))
    #expect(theme.colors[2] == RGB(0x55, 255, 0x55))
}

@Test func aThemeFileWithNoColoursIsRejected() {
    #expect(Themes.parse("# nothing here\n") == nil)
}
