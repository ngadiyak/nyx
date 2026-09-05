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
