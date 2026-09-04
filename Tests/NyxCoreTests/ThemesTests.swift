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

@Test func crlfThemeFileParsesToTheSamePalette() {
    let lf = "background = #101010\nforeground = #e0e0e0\ncursor = #ff0000\n"
    let crlf = "background = #101010\r\nforeground = #e0e0e0\r\ncursor = #ff0000\r\n"
    let pLF = Themes.parse(lf)
    let pCRLF = Themes.parse(crlf)
    #expect(pCRLF != nil)
    #expect(pCRLF == pLF)
}

@Test func loneCRThemeFileParsesToTheSamePalette() {
    let lf = "background = #101010\nforeground = #e0e0e0\ncursor = #ff0000\n"
    let cr = "background = #101010\rforeground = #e0e0e0\rcursor = #ff0000\r"
    let pLF = Themes.parse(lf)
    let pCR = Themes.parse(cr)
    #expect(pCR != nil)
    #expect(pCR == pLF)
}

@Test func outOfRangePaletteIndexIsNotRecognised() {
    #expect(Themes.parse("palette = 300=#ffffff\n") == nil)
    #expect(Themes.parse("palette = -1=#ffffff\n") == nil)
}

// MARK: - What makes a theme usable
//
// The rules below are the ones a theme has to satisfy for the interface built on top of it to be
// visible. They exist because the previous round of this file checked one thing -- foreground
// against background -- and every theme passed it while Solarized's bright black was pixel-identical
// to its background, nyx-light's black was pixel-identical to its bright white, nyx-dark's bright
// cyan was *darker* than its cyan, and selecting a line in nyx-light painted near-black under
// near-black text. A rule that only looks at two of a theme's twenty colours is a rule that passes
// things it should not.
//
// Every threshold here is a floor the seven built-ins clear, not an aspiration: a test that fails on
// the code as shipped teaches nobody anything.

/// Index 0 is exempt everywhere: black sitting on the background is what black is for, and five of
/// the seven built-ins ship it within a point or two of the page. Index 8 is exempt from the
/// contrast floor for the same reason -- "bright black" is the comment colour -- but has to be
/// *visibly* off the background, which is the rule Solarized Dark used to fail by 0.00.
@Test func noAnsiColourIsInvisibleOnItsOwnBackground() {
    for (name, p) in Themes.builtin {
        // Bright black is the third grey: not black, not the page, and not the body text either.
        #expect(RGB.distance(p.colors[8], p.background) >= 12,
                "\(name): bright black is \(RGB.distance(p.colors[8], p.background)) from the background")
        #expect(RGB.distance(p.colors[8], p.foreground) >= 12,
                "\(name): bright black is \(RGB.distance(p.colors[8], p.foreground)) from the foreground")
        for index in Array(1...7) + Array(9...15) {
            let ratio = RGB.contrast(p.colors[index], p.background)
            #expect(ratio >= 2.5, "\(name): colour \(index) is \(ratio):1 against the background")
        }
    }
}

/// A colour indistinguishable from ordinary text carries no information: the escape sequence runs,
/// the text changes colour, and nothing on screen changes. nyx-dark's bright blue was 11.4 from its
/// foreground and nyx-light's cyan 13.2 -- both close enough that a line printed in them read as an
/// ordinary line.
///
/// Ten slots, not sixteen. The four neutrals -- black, white, bright black, bright white -- *are*
/// the theme's greyscale ramp, and every theme in this set but one draws its foreground straight
/// out of that ramp: dracula's and one-dark's foreground is their white, gruvbox's, catppuccin's
/// and nyx-light's is their bright white. `\u{1B}[37m` rendering in the default text colour is what
/// "white" means on those themes, not a defect, and a rule that condemned it would be a rule
/// demanding four upstream palettes be rewritten to no purpose. What must not happen is a *colour*
/// disappearing into the text, and that is what this checks.
@Test func noChromaticColourIsIndistinguishableFromOrdinaryText() {
    for (name, p) in Themes.builtin {
        for index in Array(1...6) + Array(9...14) {
            let distance = RGB.distance(p.colors[index], p.foreground)
            #expect(distance >= 15,
                    "\(name): colour \(index) is \(distance) from the foreground")
        }
    }
}

/// Black and bright white are the two ends of the ramp; a theme that makes them the same colour
/// renders `\u{1B}[30;107m` as nothing at all. nyx-light did, because its light palette had been
/// built by darkening every slot including the one that was already the darkest.
@Test func blackAndBrightWhiteAreDifferentColours() {
    for (name, p) in Themes.builtin {
        #expect(RGB.distance(p.colors[0], p.colors[15]) >= 20,
                "\(name): black and bright white are \(RGB.distance(p.colors[0], p.colors[15])) apart")
    }
}

/// "Bright" means emphasis, and emphasis is contrast against the page -- not luminance.
///
/// Stated as luminance this rule is dark-theme-only, because on a light theme a brighter colour is
/// a *less* legible one; stated as contrast it is appearance-independent, and holds for all seven.
/// That distinction is not academic. The first version of this test said luminance and was guarded
/// by `where !p.isLight`, so it skipped nyx-light -- the one theme where every bright variant was
/// still less legible than its normal, which is the identical defect the same commit had just
/// fixed in nyx-dark. A rule written to describe a repair notices nothing; a rule written as a rule
/// would have failed on the theme that was never repaired.
///
/// Slots 9...15. Slot 8 is exempt and has its own rule above: "bright black" is the only slot where
/// bright does not mean stronger. It is the comment grey -- the tone between the ink and the page --
/// and which side of black that falls on depends on which of them the page is. Every other bright
/// is its normal with more emphasis, in either polarity.
@Test func brightVariantsAreNotWeakerThanTheirNormals() {
    for (name, p) in Themes.builtin {
        for index in 9...15 {
            let bright = RGB.contrast(p.colors[index], p.background)
            let normal = RGB.contrast(p.colors[index - 8], p.background)
            #expect(bright >= normal - 0.15,
                    "\(name): colour \(index) is \(bright):1 where colour \(index - 8) is \(normal):1")
        }
    }
}

@Test func theCursorCanBeFound() {
    for (name, p) in Themes.builtin {
        #expect(RGB.contrast(p.cursor, p.background) >= 3,
                "\(name): the cursor is \(RGB.contrast(p.cursor, p.background)):1 against the background")
    }
}

/// The accent is what the chrome paints a running toggle, an activity dot and a panel's selected
/// row in. Four of the seven themes make their cursor the foreground colour, so taking the cursor
/// as the accent gave four themes an accent that was not a colour.
@Test func everyThemeHasAnAccentThatIsAColour() {
    for (name, p) in Themes.builtin {
        #expect(p.accent.chroma >= 18, "\(name): the accent has chroma \(p.accent.chroma)")
        #expect(RGB.distance(p.accent, p.foreground) >= 15,
                "\(name): the accent is \(RGB.distance(p.accent, p.foreground)) from the foreground")
        #expect(RGB.contrast(p.accent, p.background) >= 2.5,
                "\(name): the accent is \(RGB.contrast(p.accent, p.background)):1 on the background")
    }
}

/// Every band the interface paints under text, checked against the text that lands on it. The
/// `target` allowance is what keeps this honest for a deliberately low-contrast theme: Solarized's
/// own foreground only clears its background by 5.6:1, and a highlight there may cost a sixth of
/// that rather than being blended away chasing 4.5.
@Test func textReadsOnEveryBandDrawnUnderIt() {
    for (name, p) in Themes.builtin {
        let allowed = min(4.5, RGB.contrast(p.foreground, p.background) * 0.85) - 0.01
        let selectionText = p.selectionForeground ?? p.foreground
        #expect(RGB.contrast(selectionText, p.selectionBackground) >= 3,
                "\(name): selected text is \(RGB.contrast(selectionText, p.selectionBackground)):1")
        #expect(RGB.contrast(p.foreground, p.searchMatchBackground) >= allowed,
                "\(name): text on a search hit is \(RGB.contrast(p.foreground, p.searchMatchBackground)):1")
        #expect(RGB.contrast(p.searchMatchForeground, p.currentMatchBackground) >= 4.5,
                "\(name): text on the current hit is \(RGB.contrast(p.searchMatchForeground, p.currentMatchBackground)):1")
        // 3.5 rather than `allowed`: the selected row is a surface behind list rows, and it also
        // has to stay visibly off the panel's own background, which in Solarized is a fight the
        // contrast rule would otherwise win by making the row invisible.
        #expect(RGB.contrast(p.foreground, p.panelSelectionBackground) >= 3.5,
                "\(name): text on the selected row is \(RGB.contrast(p.foreground, p.panelSelectionBackground)):1")
        #expect(RGB.contrast(p.noteForeground, p.background) >= 2.8,
                "\(name): a duration note is \(RGB.contrast(p.noteForeground, p.background)):1")
    }
}

/// A band you cannot see is not a band. Each one has to be visibly off the background it is drawn
/// on -- Solarized shipped a selection 5 units from its own background -- and the current search
/// hit has to be visibly different from the forty others, which is the whole reason there are two
/// of them.
@Test func everyBandIsVisiblyOffTheSurfaceUnderIt() {
    for (name, p) in Themes.builtin {
        #expect(RGB.distance(p.selectionBackground, p.background) >= 10,
                "\(name): the selection is \(RGB.distance(p.selectionBackground, p.background)) from the background")
        #expect(RGB.distance(p.searchMatchBackground, p.background) >= 10,
                "\(name): a search hit is \(RGB.distance(p.searchMatchBackground, p.background)) from the background")
        #expect(RGB.distance(p.panelSelectionBackground, p.background) >= 10,
                "\(name): the selected row is \(RGB.distance(p.panelSelectionBackground, p.background)) from the background")
        #expect(RGB.distance(p.currentMatchBackground, p.searchMatchBackground) >= 20,
                "\(name): the current hit is \(RGB.distance(p.currentMatchBackground, p.searchMatchBackground)) from the others")
    }
}

/// The command palette tints its selected row with the accent *and* draws the characters a query
/// matched in the accent. In gruvbox those were 1.6:1 apart, so on the one row the user was looking
/// at, the highlight that says why the row matched disappeared.
@Test func theMatchHighlightSurvivesTheSelectedRow() {
    for (name, p) in Themes.builtin {
        #expect(RGB.contrast(p.accentText, p.panelSelectionBackground) >= 3,
                "\(name): matched characters are \(RGB.contrast(p.accentText, p.panelSelectionBackground)):1 on the selected row")
        #expect(RGB.contrast(p.accentText, p.background) >= 3,
                "\(name): matched characters are \(RGB.contrast(p.accentText, p.background)):1 on the panel")
        // And still a different colour from the text around them, which is the other half of the
        // job: lifting the accent until it clears the selected row must not lift it into the
        // foreground. gruvbox is the tight one at 23.7 -- its blue is low-chroma to begin with.
        #expect(RGB.distance(p.accentText, p.foreground) >= 18,
                "\(name): matched characters are \(RGB.distance(p.accentText, p.foreground)) from ordinary text")
    }
}

/// A group's name sits on a pill filled with the group's own colour, and a running toggle's name
/// sits on the accent. Both used to be drawn in the background colour on the assumption that the
/// background contrasts with everything, which put dark text on gruvbox's dark red.
@Test func labelsOnColouredFillsAreReadable() {
    for (name, p) in Themes.builtin {
        for index in 1...6 {
            let fill = p.readable(index)
            // 3:1 is the floor for a short bold label on a fill rather than a page of body text;
            // the built-ins clear 3.2.
            #expect(RGB.contrast(p.textOn(fill), fill) >= 3,
                    "\(name): a group label on colour \(index) is \(RGB.contrast(p.textOn(fill), fill)):1")
        }
        #expect(RGB.contrast(p.textOn(p.accent), p.accent) >= 3,
                "\(name): a running toggle's label is \(RGB.contrast(p.textOn(p.accent), p.accent)):1")
    }
}

/// The block chrome paints failures, successes and running commands in the theme's red, green and
/// yellow. gruvbox's red is 2.7:1 as a line of text; its bright red is 4.3:1.
@Test func theBlockChromeUsesColoursYouCanRead() {
    for (name, p) in Themes.builtin {
        for index in [1, 2, 3] {
            #expect(RGB.contrast(p.readable(index), p.background) >= 3,
                    "\(name): a spine of colour \(index) is \(RGB.contrast(p.readable(index), p.background)):1")
        }
    }
}

/// A user theme file gets every derived colour the built-ins get, so the rules have to survive a
/// palette nobody vetted. The xterm defaults are the harshest realistic case: a pure-black
/// background with saturated primaries, and a "bright yellow" of #FFFF00.
@Test func derivedColoursHoldUpOnAnUnvettedPalette() {
    let p = Palette.xtermDefault()
    #expect(RGB.contrast(p.searchMatchForeground, p.currentMatchBackground) >= 4.5)
    #expect(RGB.contrast(p.foreground, p.panelSelectionBackground) >= 4)
    #expect(RGB.distance(p.selectionBackground, p.background) >= 10)
    #expect(RGB.distance(p.currentMatchBackground, p.searchMatchBackground) >= 20)
    #expect(p.accent.chroma >= 18)
}

/// A light theme's selection used to be `foreground.scaled(0.35)`, a rule that only makes sense
/// when the foreground is the light half of the theme. On nyx-light it produced a near-black slab
/// under near-black text.
@Test func aLightThemeGetsALightSelection() {
    let light = Themes.palette(named: "nyx-light")
    #expect(light.isLight)
    #expect(light.selectionBackground.relativeLuminance > 0.25,
            "the selection is \(light.selectionBackground.relativeLuminance) on a light theme")
    #expect(RGB.contrast(light.foreground, light.selectionBackground) >= 4)
}
