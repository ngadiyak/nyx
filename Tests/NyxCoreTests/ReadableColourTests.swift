import Testing
@testable import NyxCore

private let systemRedLight = RGB(255, 59, 48)      // AppKit's systemRed in the aqua appearance
private let sheetGreyLight = RGB(236, 236, 236)    // windowBackgroundColor, light
private let sheetGreyDark = RGB(50, 50, 50)        // windowBackgroundColor, dark

/// The bug: AppKit's system colours are chosen against a system background in the abstract, and
/// `systemRed` on the pairing sheet's own grey measures about 3:1 -- below the 4.5 a line of text
/// needs, and the sort of thing that is only visible in a render.
@Test func aColourTooFaintForItsBackgroundIsDarkenedUntilItReads() {
    #expect(RGB.contrast(systemRedLight, sheetGreyLight) < 4.5)
    let fixed = RGB.readable(systemRedLight, on: sheetGreyLight, towards: RGB(0, 0, 0))
    #expect(RGB.contrast(fixed, sheetGreyLight) >= 4.5)
}

/// A colour that already reads is left exactly as it was: this must not repaint every red in the
/// application on the way past.
@Test func aColourThatAlreadyReadsIsUntouched() {
    let brightRed = RGB(255, 130, 120)
    #expect(RGB.contrast(brightRed, sheetGreyDark) >= 4.5)
    #expect(RGB.readable(brightRed, on: sheetGreyDark, towards: RGB(255, 255, 255)) == brightRed)
}

/// Both appearances needed it, which is why this is computed against the background actually in
/// force rather than a fixed blend: `systemRed` is 3.0:1 on the light sheet and 3.6:1 on the dark.
@Test func systemRedFailsOnBothOfTheSheetsBackgrounds() {
    #expect(RGB.contrast(systemRedLight, sheetGreyLight) < 4.5)
    #expect(RGB.contrast(systemRedLight, sheetGreyDark) < 4.5)
    #expect(RGB.contrast(RGB.readable(systemRedLight, on: sheetGreyDark, towards: RGB(255, 255, 255)),
                         sheetGreyDark) >= 4.5)
}

/// As much of the original as the floor allows: the answer is nearer the colour asked for than the
/// colour it was blended towards.
@Test func itKeepsAsMuchOfTheColourAsItCan() {
    let target = RGB(0, 0, 0)
    let fixed = RGB.readable(systemRedLight, on: sheetGreyLight, towards: target)
    #expect(fixed != target)
    #expect(fixed.r > fixed.g && fixed.r > fixed.b)   // still recognisably red
}

/// The impossible case ends at the colour it was aiming for rather than looping or returning
/// something unreadable.
@Test func aColourThatCannotBeMadeToReadEndsAtTheTarget() {
    let white = RGB(255, 255, 255)
    #expect(RGB.readable(white, on: white, towards: white, minimum: 4.5) == white)
}

/// The lens chip's on-state is `accent` filled with `textOn(accent)` ink. That ink is the only
/// thing on a filled chip, so it is text and holds to 4.5:1 -- in all seven built-in themes, which
/// is where the old lit `{ }` failed at 2.82:1.
@Test func theLensChipsInkIsReadableOnItsOwnFillInEveryTheme() {
    for (name, palette) in Themes.builtin {
        let ratio = RGB.contrast(palette.textOn(palette.accent), palette.accent)
        #expect(ratio >= 4.5, "\(name): \(ratio)")
    }
}

/// `Stop` is drawn in the theme's failure colour on the pill's own ground. `Stop`'s colour is
/// calibrated to clear 4.5:1 on `palette.background` and nothing further (one-dark measures
/// 4.503:1, no headroom to spare) -- so a wash of the row's hover tint under it, as the pill used
/// to draw, ate that headroom and gruvbox-dark's `Stop` read at 2.82:1. The idle pill's ground is
/// therefore opaque `background`, not a tint of the hovered row, and the hairline that outlines it
/// is a 0.30 wash rather than 0.22 -- the smallest alpha that clears 1.6:1 against that ground in
/// every theme (0.22 tops out at 1.29:1, in every theme, however the row's tint is chosen: it is
/// not a tuning problem, `RGB.blend`'s straight line from any ground to `foreground` cannot clear
/// 1.6 at a 0.08 step). Measured in all seven built-ins, because "readable in nyx-dark" is how
/// gruvbox's lit `{ }` shipped at 2.82:1 in the first place.
@Test func theStripsUnlitPillsAreReadableInEveryTheme() {
    for (name, palette) in Themes.builtin {
        let ground = palette.background
        #expect(RGB.contrast(SummaryTone.failure.color(in: palette), ground) >= 4.5, "\(name) Stop")
        #expect(RGB.contrast(palette.foreground, ground) >= 4.5, "\(name) label")
        let hairline = RGB.blend(palette.background, into: palette.foreground, amount: 0.30)
        #expect(RGB.contrast(hairline, ground) >= 1.6, "\(name) hairline")
    }
}
