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

/// `Stop` is drawn in the theme's failure colour, pushed toward `foreground` (via `RGB.readable`)
/// on the pill's own ground -- `blockHoverBackground` washed by exactly the alpha the fill state
/// draws (0.14 idle and hovered, 0.26 pressed -- D4 removed the 0.20 step) -- rather than
/// resolved once against plain
/// `background` and reused everywhere: gruvbox-dark's `Stop` read at 2.82:1 hovered when the two
/// disagreed. The hairline is `Palette.pillHairline`, which starts at the 0.30 wash the pill used
/// to draw unconditionally and widens further wherever a state's own fill has washed the ground too
/// close to `foreground` to leave a fixed 0.30 room (pressed, at 0.30 flat, measured under 1.6 in
/// every theme -- the *gap* a hairline has to work with shrinks as the fill's own alpha rises).
///
/// Six of seven themes clear 4.5:1 for `Stop` in every state; solarized-dark and one-dark's own red
/// cannot get there on some states even pushed all the way to `foreground` -- `RGB.readable`'s own
/// ceiling, `contrast(foreground, ground)`, which is what pure `foreground` would read at. Recorded
/// here at their measured ceilings rather than silently accepted: the general floor stays 4.5,
/// these two theme/state cells do not clear it and are not asked to.
@Test func theStripsUnlitPillsAreReadableInEveryTheme() {
    // (theme, state) -> the measured ceiling `RGB.readable` cannot get past on that ground: pure
    // `foreground` itself is not 4.5:1 there, so nothing pushed toward it can be either. Every
    // other cell (all seven themes idle; five of seven in every state) holds 4.5 outright.
    let knownCeilings: [String: [String: Double]] = [
        "solarized-dark": ["idle": 4.06, "hover": 3.70, "pressed": 3.32],
        "one-dark": ["hover": 4.05, "pressed": 3.62],
    ]
    for (name, palette) in Themes.builtin {
        // §2.3's two fills and no third: hover is the hairline's job now, so a hovered pill is
        // filled exactly as an idle one is and only a pressed one is darker (D4).
        for (state, alpha) in [("idle", 0.14), ("hover", 0.14), ("pressed", 0.26)] {
            let ground = RGB.blend(palette.blockHoverBackground, into: palette.foreground, amount: alpha)
            let ink = RGB.readable(SummaryTone.failure.color(in: palette), on: ground,
                                   towards: palette.foreground)
            let floor = knownCeilings[name]?[state] ?? 4.5
            #expect(RGB.contrast(ink, ground) >= floor, "\(name) \(state) Stop")
            // Every other unlit pill's ink is `foreground` outright, no push -- the same ceiling
            // `readable` converges to above, so it shares the same recorded exceptions.
            #expect(RGB.contrast(palette.foreground, ground) >= floor, "\(name) \(state) label")
            // D4: hover lives on the hairline, so an idle pill holds 1.6:1 and a hovered or
            // pressed one holds **3:1**. Measured after: idle 1.67-2.12, hovered 3.01-3.20,
            // pressed 3.04-3.18, against ceilings (pure `foreground` on the same ground) of
            // 3.32 (solarized-dark) to 5.40 (dracula) -- so every theme has the room, which the
            // *fill* did not: idle → hovered on the fill is 1.219:1 on nyx-dark and 1.088:1 on
            // nyx-light, and nyx-light's whole fill range spans 1.22:1 to about 4:1.
            let floorForState = state == "idle" ? 1.6 : 3.0
            let hairline = palette.pillHairline(on: ground, minimum: floorForState)
            #expect(RGB.contrast(hairline, ground) >= floorForState,
                    "\(name) \(state) hairline")
            // And the raise is real, not a relabelling: a hovered pill's hairline is further from
            // its ground than an idle one's is from *its* ground, in every theme.
            if state != "idle" {
                let idleGround = RGB.blend(palette.blockHoverBackground, into: palette.foreground,
                                           amount: 0.14)
                #expect(RGB.contrast(hairline, ground)
                    > RGB.contrast(palette.pillHairline(on: idleGround), idleGround) + 0.5,
                        "\(name) \(state) hairline is not a visible step")
            }
        }
    }
}

/// A tab group's name pill (`TabBarView.textColor(on:)`) is `textOn` on an arbitrary ANSI colour,
/// not just `accent` -- and picking the push direction from which neutral won, rather than from
/// that neutral's own luminance relative to the fill, walked nyx-light's `colors[3]` pill the wrong
/// way: `background` is the *lighter* of nyx-light's two neutrals, so pushing it toward black moved
/// it toward the fill instead of away, and a pill that read at 4.29:1 unpushed came out at 3.78:1
/// pushed -- a regression review round 1 found by measuring the built `Palette`, not the test.
@Test func textOnPushesTowardTheNeutralsOwnLighterOrDarkerSide() {
    guard let nyxLight = Themes.builtin["nyx-light"] else { Issue.record("nyx-light missing"); return }
    let fill = RGB(hex: 0x8F5E15)
    let ink = nyxLight.textOn(fill)
    #expect(RGB.contrast(ink, fill) >= 4.5)
}


/// The gutter's `.faded` mark -- a command that finished cleanly with nothing to fold -- is the
/// only cue there is that the command ran at all: it has no label, no chevron and no second
/// treatment beside it, so the Global Constraints' floor for it is **3:1**, not the 4.5 a line of
/// text needs.
///
/// §2.2 draws it as the solid mark at 40 %, and measured from the rendered pixels that came out at
/// **2.61:1 on nyx-dark and 1.78:1 on nyx-light** -- under the floor in the two themes that ship as
/// the defaults, and worse in the lighter of the two, where 40 % of a green over a near-white
/// ground is a pale grey. `Palette.fadedMark` keeps the 40 % wherever 40 % clears 3:1 and raises it
/// per theme until it does, capping at the solid mark's own colour, which by construction is the
/// most a mark can be.
///
/// Measured after the fix, success tone, every built-in (40 % -> raised, against `background`):
/// catppuccin-mocha 2.90 -> 3.33, dracula 2.86 -> 3.28, gruvbox-dark 1.88 -> 3.08,
/// nyx-dark 2.60 -> 3.33, nyx-light 1.79 -> 3.02, one-dark 2.32 -> 3.17,
/// solarized-dark 1.81 -> 3.24. All seven needed raising; none reaches its solid mark's own
/// contrast (4.69:1 to 11.03:1), so the mark still reads as the quieter of the two.
@Test func theFadedGutterMarkClearsThreeToOneInEveryTheme() {
    for (name, palette) in Themes.builtin {
        for (tone, colour) in [("success", SummaryTone.success), ("failure", .failure),
                               ("running", .running)] {
            let solid = colour.color(in: palette)
            let faded = palette.fadedMark(solid)
            // **Both grounds**, and the tint is the harder one. D6 moved the hover tint out to the
            // window's own edge so it now runs *under* the gutter mark, and `PromptGutterView`
            // paints no ground of its own -- so a `.faded` cap on a hovered block sits on
            // `blockHoverBackground`, where all 21 theme×tone cells measured 2.71:1 to 3.00:1
            // against a floor of 3 while every one of them cleared it against `background`
            // (3.02-3.33). `fadedMark`'s own comment claimed `background` was the harder of the
            // two; that was true before the tint reached the mark and false after (S1).
            let ratio = min(RGB.contrast(faded, palette.background),
                            RGB.contrast(faded, palette.blockHoverBackground))
            #expect(ratio >= 3, "\(name) \(tone): \(ratio)")
            // Never *more* than the solid mark: the faded treatment says "less", and a mark that
            // came back brighter than the pressable one would say the opposite.
            #expect(RGB.contrast(faded, palette.background)
                <= RGB.contrast(solid, palette.background) + 0.001, "\(name) \(tone) is not louder")
            #expect(RGB.contrast(faded, palette.blockHoverBackground)
                <= RGB.contrast(solid, palette.blockHoverBackground) + 0.001,
                    "\(name) \(tone) is not louder on the tint")
        }
    }
}

/// And it is still *faded* wherever it can afford to be: `fadedMark` is a floor, not a repaint, so
/// a mark whose 40 % already clears 3:1 comes back at exactly the 40 % §2.2 asks for. None of the
/// seven built-ins is in that position -- the closest is catppuccin-mocha at 2.90:1 -- so the
/// property is asserted where it can be, on a palette whose mark is white on black.
@Test func theFadedMarkKeepsFortyPercentWhenFortyPercentAlreadyReads() {
    var palette = Palette.xtermDefault()
    palette.background = RGB(0, 0, 0)
    let solid = RGB(255, 255, 255)
    let forty = RGB.blend(solid, into: palette.background, amount: 0.6)
    #expect(RGB.contrast(forty, palette.background) >= 3)
    #expect(palette.fadedMark(solid) == forty)
}

/// D1: every tone ink was made readable against `palette.background` and then drawn on the row's
/// **hover tint** -- the in-grid summary on a hovered block, the strip's own readout, and the fold
/// placeholder's `… 6 lines hidden`. Measured from the plan-1a composites: the neutral `8.8s`
/// reads 4.58:1 idle and **4.17:1** on the tint (`composite-strip-w3-folded-nyx-dark-dark`), and
/// `… 6 lines hidden` **4.13:1** on the same row -- so hovering a block made its own status *less*
/// legible, which is the shape of the defect §2.5 was written to remove.
///
/// The ground these three are resolved against is now the tint, unconditionally, rather than
/// whichever ground the block happens to be on this frame. Two reasons, and the second is the
/// stronger: the tint is the **harder** of the two grounds for every one of the 35 theme×tone pairs
/// (it moves `background` toward `accent`, i.e. toward these inks), so one resolution clears both;
/// and the placeholder is drawn as *cells* through the row cache, so an ink that changed with hover
/// would be a per-row input the renderer reads and `RowKey` does not carry -- a stale row, not a
/// colour bug.
@Test func everyToneInkIsReadableOnTheRowsHoverTintAndOnThePlainBackground() {
    for (name, palette) in Themes.builtin {
        let tint = palette.blockHoverBackground
        for (label, tone) in [("plain", SummaryTone.plain), ("running", .running),
                              ("success", .success), ("redirect", .redirect), ("failure", .failure)] {
            let ink = tone.color(in: palette, on: tint)
            #expect(RGB.contrast(ink, tint) >= 4.5, "\(name) \(label) on tint")
            // And still readable where the same ink is drawn on an unhovered row.
            #expect(RGB.contrast(ink, palette.background) >= 4.5, "\(name) \(label) on background")
        }
        // The placeholder's third state -- a clean block's `… 6 lines hidden` -- is the lens grey,
        // which had the same defect and takes the same ground.
        let dim = LensPalette.dimColour(in: palette)
        #expect(RGB.contrast(dim, tint) >= 4.5, "\(name) placeholder dim on tint")
        #expect(RGB.contrast(dim, palette.background) >= 4.5, "\(name) placeholder dim on background")
    }
}
