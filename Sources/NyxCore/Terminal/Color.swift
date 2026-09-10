import Foundation

/// A terminal color: default, one of 256 indexed colors, or 24-bit RGB. Packed in 32 bits.
public struct Color: Equatable, Hashable {
    public enum Kind: UInt8 { case `default` = 0, indexed = 1, rgb = 2 }

    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }
    public static let `default` = Color(raw: 0)
    public static func indexed(_ i: UInt8) -> Color { Color(raw: (1 << 24) | UInt32(i)) }
    public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
        Color(raw: (2 << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b))
    }

    public var kind: Kind { Kind(rawValue: UInt8(raw >> 24)) ?? .default }
    public var index: UInt8 { UInt8(raw & 0xFF) }
    public var r: UInt8 { UInt8((raw >> 16) & 0xFF) }
    public var g: UInt8 { UInt8((raw >> 8) & 0xFF) }
    public var b: UInt8 { UInt8(raw & 0xFF) }
}

public struct RGB: Equatable, Hashable {
    /// `amount` is how much of `other` shows through: 0 keeps `colour`, 1 gives `other`.
    public static func blend(_ colour: RGB, into other: RGB, amount: Double) -> RGB {
        let t = min(max(amount, 0), 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(a) * (1 - t) + Double(b) * t).rounded())))
        }
        return RGB(mix(colour.r, other.r), mix(colour.g, other.g), mix(colour.b, other.b))
    }

    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF); g = UInt8((hex >> 8) & 0xFF); b = UInt8(hex & 0xFF)
    }

    /// Parses "#rrggbb", "rgb:rr/gg/bb" and "rgb:rrrr/gggg/bbbb" (X11 forms used by OSC 4/10/11/12).
    public init?(spec: String) {
        if spec.hasPrefix("#"), spec.count == 7, let v = UInt32(spec.dropFirst(), radix: 16) {
            self.init(hex: v); return
        }
        if spec.hasPrefix("rgb:") {
            let parts = spec.dropFirst(4).split(separator: "/")
            guard parts.count == 3 else { return nil }
            var out = [UInt8]()
            for p in parts {
                guard let v = UInt32(p, radix: 16) else { return nil }
                switch p.count {
                case 1: out.append(UInt8(v * 17))
                case 2: out.append(UInt8(v))
                case 3: out.append(UInt8(v >> 4))
                case 4: out.append(UInt8(v >> 8))
                default: return nil
                }
            }
            self.init(out[0], out[1], out[2]); return
        }
        return nil
    }

    /// xterm response form, 16 bits per channel.
    public var xtermSpec: String { String(format: "rgb:%02x%02x/%02x%02x/%02x%02x", r, r, g, g, b, b) }

    public func scaled(_ f: Double) -> RGB {
        RGB(UInt8(Double(r) * f), UInt8(Double(g) * f), UInt8(Double(b) * f))
    }

    // MARK: - Measuring colours
    //
    // Three numbers, and every colour rule in the palette below is written in terms of them.
    // Without these the only way to answer "is this readable in gruvbox?" is to render it and
    // look, which is exactly how a control ends up invisible in one theme out of seven.

    /// WCAG relative luminance: how much light the colour puts out, 0 (black) to 1 (white).
    public var relativeLuminance: Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// A colour moved just far enough to be readable on a background, keeping as much of itself as
    /// it can.
    ///
    /// `colour` is blended towards `towards` in small steps until it clears `minimum` against
    /// `background`, and the first step that does is the answer -- so a colour that was already
    /// readable comes back untouched, and one that was not comes back as close to the original as
    /// the floor allows. The last resort is `towards` itself, which is the caller's guaranteed-
    /// readable colour (a label colour, a theme foreground).
    ///
    /// It exists because AppKit's system colours are chosen for a system background: `systemRed` on
    /// the pairing sheet's own grey measures about 3:1, which is below the 4.5 a line of text needs
    /// and exactly the sort of thing nobody notices until they read the render.
    public static func readable(_ colour: RGB, on background: RGB, towards: RGB,
                                minimum: Double = 4.5) -> RGB {
        guard contrast(colour, background) < minimum else { return colour }
        for step in 1...20 {
            let candidate = blend(colour, into: towards, amount: Double(step) / 20)
            if contrast(candidate, background) >= minimum { return candidate }
        }
        return towards
    }

    /// WCAG contrast ratio, 1 (identical) to 21 (black on white). Text needs about 4.5.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// CIE L*a*b*, the space where "how different do these look" is a distance rather than a guess.
    /// Contrast alone cannot tell red from green -- both can sit at the same luminance -- so the
    /// rules that ask whether two colours are *the same colour* ask in here.
    var lab: (l: Double, a: Double, b: Double) {
        func linear(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let x = (rl * 0.4124 + gl * 0.3576 + bl * 0.1805) / 0.95047
        let y = rl * 0.2126 + gl * 0.7152 + bl * 0.0722
        let z = (rl * 0.0193 + gl * 0.1192 + bl * 0.9505) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Perceptual distance (CIE76). Roughly: under 2 is invisible, under 8 is "the same colour in
    /// a slightly different light", over 20 is unmistakably a different colour.
    public static func distance(_ a: RGB, _ b: RGB) -> Double {
        let x = a.lab, y = b.lab
        let dl = x.l - y.l, da = x.a - y.a, db = x.b - y.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// How much colour there is, ignoring how light it is. A grey has none, and a grey is no use
    /// as an accent however bright it happens to be.
    public var chroma: Double {
        let c = lab
        return (c.a * c.a + c.b * c.b).squareRoot()
    }
}

public struct Palette: Equatable {
    public var colors: [RGB]
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    /// Background painted behind selected cells.
    public var selectionBackground: RGB
    /// Foreground for selected cells, or nil to keep each cell's own colour. Themes that pick a
    /// selection background close to the text colour set this; most do not need it.
    public var selectionForeground: RGB?

    /// `ansi` is the 16 base colors; the 6x6x6 cube and the 24-step gray ramp are always the xterm defaults.
    public init(ansi: [RGB], foreground: RGB, background: RGB, cursor: RGB,
                selectionBackground: RGB? = nil, selectionForeground: RGB? = nil) {
        precondition(ansi.count == 16)
        var c = ansi
        for i in 0..<216 {
            let r = i / 36, g = (i / 6) % 6, b = i % 6
            func v(_ x: Int) -> UInt8 { x == 0 ? 0 : UInt8(55 + 40 * x) }
            c.append(RGB(v(r), v(g), v(b)))
        }
        for i in 0..<24 { let v = UInt8(8 + 10 * i); c.append(RGB(v, v, v)) }
        colors = c
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selectionForeground = selectionForeground
        // `foreground.scaled(0.35)` -- the old default -- is a dark-theme rule wearing a general
        // name. On a light theme it turns the *dark* foreground into a near-black slab and paints
        // the equally dark text on top of it, so selecting a line in nyx-light made it unreadable.
        // A blend toward the background works in both directions: it is always a shade of the page
        // the selection is on, lifted toward the text colour by a fixed amount.
        self.selectionBackground = selectionBackground
            ?? Palette.pushed(foreground, toward: background,
                              until: foreground, reaches: Palette.target(foreground, background),
                              from: 0.0, to: 0.85)
    }

    public static let xtermAnsi16: [RGB] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ].map { RGB(hex: $0) }

    public static func xtermDefault() -> Palette {
        Palette(ansi: xtermAnsi16, foreground: RGB(hex: 0xE5E5E5), background: RGB(0, 0, 0), cursor: RGB(hex: 0xE5E5E5))
    }

    // MARK: - Colours derived from the theme
    //
    // Every colour Nyx invents for itself is computed here from the sixteen a theme already has,
    // so a user's theme file -- which sets exactly the keys the built-ins set -- gets the whole
    // interface for free. The rule each one follows is written as an inequality rather than a
    // fixed blend, because a fixed blend is only ever tuned against the theme its author had open,
    // and the others are where the control disappears.

    /// A theme is light when its page is brighter than its ink.
    public var isLight: Bool { background.relativeLuminance > foreground.relativeLuminance }

    /// The lighter of the theme's two neutrals. A colour lifted toward it gets brighter without
    /// leaving the theme, which is what `accentText` needs.
    var page: RGB { isLight ? background : foreground }

    /// How much contrast a derived colour has to keep. 4.5 where the theme can afford it; where it
    /// cannot -- Solarized Dark's foreground clears its own background by only 5.6 -- a highlight
    /// is allowed to cost at most about a sixth of the theme's own legibility, rather than being
    /// blended into invisibility chasing a number the theme never reaches anywhere.
    static func target(_ foreground: RGB, _ background: RGB) -> Double {
        min(4.5, RGB.contrast(foreground, background) * 0.85)
    }

    /// Walks `hue` toward `other` in twentieths until `against` reads on it, and stops there. The
    /// smallest change that satisfies the rule, so a theme that already satisfies it is untouched.
    static func pushed(_ hue: RGB, toward other: RGB, until against: RGB, reaches minimum: Double,
                       from low: Double, to high: Double) -> RGB {
        var t = low
        while t <= high {
            let candidate = RGB.blend(hue, into: other, amount: t)
            if RGB.contrast(against, candidate) >= minimum { return candidate }
            t += 0.05
        }
        return RGB.blend(hue, into: other, amount: high)
    }

    /// The theme's own attention colour: what a running toggle, an activity dot, a selected row in
    /// a panel and a group with no colour of its own are painted in.
    ///
    /// The cursor first, because a theme that bothered to pick a cursor colour has already said
    /// which colour means "here". Four of the seven built-ins do not -- their cursor *is* the
    /// foreground, which makes an accent that is not a colour at all and left gruvbox and Solarized
    /// with a grey slab where the highlight should be. The theme's blue is the fallback: every
    /// ANSI palette has one, and it is by construction chosen to read on that theme's background.
    public var accent: RGB {
        for candidate in [cursor, colors[12], colors[4], colors[6], colors[5]]
        where candidate.chroma >= 18
            && RGB.distance(candidate, foreground) >= 15
            && RGB.contrast(candidate, background) >= 2 {
            return candidate
        }
        return colors[12]
    }

    /// The accent used as *text* in a panel that also tints its selected row with the accent.
    ///
    /// The matched characters in the command palette sit on both the panel's background and, one
    /// row in twenty, on `panelSelectionBackground` -- which is the same hue. gruvbox's blue on a
    /// gruvbox-blue row is 1.6:1: the highlight that says why a row matched vanished on the one row
    /// the user was looking at. Lifted toward the light half of the theme until it clears the
    /// selected row, and left alone in the five themes that already do.
    public var accentText: RGB {
        Palette.pushed(accent, toward: page, until: panelSelectionBackground, reaches: 3,
                       from: 0, to: 0.70)
    }

    /// Text to put on a filled shape of `fill` -- a group's name on its pill, a toggle's name on
    /// its chip. Whichever of the theme's two neutrals reads on it; assuming the background always
    /// does gives dark-on-dark wherever the fill is a dark red. Neither neutral is guaranteed to
    /// clear 4.5:1 on its own -- gruvbox-dark's cream foreground on its own blue accent measured
    /// 3.48:1, one-dark's grey foreground on its own blue 4.33:1 -- so the winner is pushed further
    /// in the direction it already reads better, the same way `accentText` is pushed toward the
    /// page, until it does.
    ///
    /// The push direction is `base`'s own luminance relative to `fill`'s, not which neutral won:
    /// picking white whenever `background` was the winner sent nyx-light's `colors[3]` chip toward
    /// *black* -- `background` there is the lighter neutral, so pushing it dark walked it toward
    /// the fill instead of away, and a pill that read at 4.29:1 unpushed came out at 3.78:1 pushed.
    /// And a push that ends up worse than where it started is never used: `pushed` can only walk in
    /// twentieths, and the step that first clears (or fails to clear) `minimum` is not guaranteed
    /// to beat the colour it started from.
    public func textOn(_ fill: RGB) -> RGB {
        let base = RGB.contrast(background, fill) >= RGB.contrast(foreground, fill) ? background : foreground
        let extreme = base.relativeLuminance >= fill.relativeLuminance ? RGB(255, 255, 255) : RGB(0, 0, 0)
        let pushed = Palette.pushed(base, toward: extreme, until: fill, reaches: 4.5, from: 0, to: 1)
        return RGB.contrast(pushed, fill) >= RGB.contrast(base, fill) ? pushed : base
    }

    /// The hairline that outlines an unlit strip pill, on the ground the pill is actually filled
    /// with -- `foreground` composited at 0.30 first, the alpha the pill drew unconditionally
    /// before this, then further in the same twentieths `pushed` walks in until it clears 1.6:1.
    ///
    /// A fixed 0.30 is not enough on its own: `ground` already carries some of that same wash (the
    /// fill itself, 0.14 idle and hovered, 0.26 pressed), so the *gap* the hairline has left to
    /// work with shrinks as the fill's own alpha rises -- at 0.30 flat, every theme's pressed state
    /// measured under 1.6. Walking further towards `foreground` is always available: the ceiling is
    /// `contrast(foreground, ground)`, which is what a hairline of *pure* foreground would read at,
    /// and every theme's is comfortably above 1.6 in every state (worst: one-dark pressed, 3.63:1).
    ///
    /// `minimum` is where **hover** lives now. The fill alone cannot carry it: measured from the
    /// pictures, idle → hovered is 1.219:1 on nyx-dark and **1.088:1** on nyx-light, and in
    /// nyx-light the whole fill range from 0.14 to pure foreground spans about 1.22:1 → 4:1, so no
    /// alpha step buys much -- the hovered `Copy` could not be told from the unhovered `Fold` 6 pt
    /// away, and the lone `⋯` at W1, which has no neighbour to compare against, was indistinguishable
    /// from its own pressed art (D4/F7). The hairline has the headroom the fill does not, so a
    /// hovered pill asks it for **3:1** and an idle one keeps 1.6. One parameter, both palettes.
    public func pillHairline(on ground: RGB, minimum: Double = 1.6) -> RGB {
        Palette.pushed(ground, toward: foreground, until: ground, reaches: minimum,
                       from: 0.30, to: 1.0)
    }

    /// The gutter's faded mark: `solid` at 40 % over this palette's background, raised toward
    /// `solid` in twentieths until it clears **3:1** against that background, and capped at `solid`
    /// itself.
    ///
    /// 3 and not 4.5 because §2.2's mark is a *shape*, not text, and it is the only cue that a
    /// command ran and printed nothing -- no label, no chevron, nothing beside it. 40 % is the
    /// number §2.2 gives and it is kept wherever it reads; measured from the rendered pixels it did
    /// not, in either default theme (2.61:1 on nyx-dark, 1.78:1 on nyx-light), because 40 % of a
    /// green over a near-white ground is a pale grey.
    ///
    /// Walked from the **faintest** mark towards the solid one -- the loop's `amount` is how much
    /// *background* is blended in, so stepping it down strengthens the mark -- and it stops at the
    /// first step that reads. So the answer is the faintest mark that still clears the floor rather
    /// than the loudest one that does: the treatment means "less". (The first take of this comment
    /// said "walked *down* from 40 %", which reads as the mark getting fainter and is the opposite
    /// of what happens.)
    ///
    /// The floor is held against **both grounds** -- `background` and the hovered block's tint --
    /// because the mark lands on either. The comment here used to say `background` was the harder of
    /// the two and the only one worth holding: that was true while the tint began at column 0's ink,
    /// and D6 moved it out to the window's own edge so that it now runs *under* the gutter, where
    /// `PromptGutterView` paints no ground of its own. Measured after D6 and before this: all 21
    /// theme×tone cells were **2.71:1 to 3.00:1** on the tint against a floor of 3, while every one
    /// cleared it on `background` (3.02-3.33). The tint moves `background` toward `accent`, which is
    /// toward these marks, so it is the harder ground now and `min` is the honest test (S1).
    ///
    /// The steps are explicit rather than a `while amount > 0` countdown, whose last iteration
    /// landed on a floating-point residue of 0.60 - 12 × 0.05 and made the final `return solid` a
    /// path nothing could reach: the cap is real now, and it is what a theme whose own solid mark
    /// is under 3:1 gets.
    public func fadedMark(_ solid: RGB) -> RGB {
        let hover = blockHoverBackground
        for step in 0...11 {
            let amount = 0.60 - Double(step) * 0.05
            let candidate = RGB.blend(solid, into: background, amount: amount)
            if min(RGB.contrast(candidate, background),
                   RGB.contrast(candidate, hover)) >= 3 { return candidate }
        }
        return solid
    }

    /// One of the sixteen, picked for use as *text* or as a small filled shape: the normal variant
    /// of `index`, or the bright one where the normal is too dim to read and the bright is
    /// substantially better. gruvbox's red is 2.7:1 as a body colour and its bright red is 4.3:1; a
    /// failed command's summary should be the second one.
    ///
    /// "Substantially" matters. Solarized's red and bright red are 3.25:1 and 3.26:1, and taking
    /// the better of the two for a hundredth of a point swapped the red for an orange -- so the
    /// bright variant has to be worth the change of hue, not merely ahead of the normal one.
    public func readable(_ index: Int) -> RGB {
        let normal = colors[index & 7], bright = colors[(index & 7) + 8]
        let plain = RGB.contrast(normal, background)
        return plain < 4.5 && RGB.contrast(bright, background) >= plain * 1.15 ? bright : normal
    }

    /// Background behind a search hit that is not the one being stepped through.
    ///
    /// Derived from the theme's own yellow rather than stored, so every built-in theme -- and every
    /// user theme file, which sets the same keys the built-ins do -- gets a search colour that
    /// belongs to it without a new setting to fill in. Yellow is what editors have settled on for
    /// find, and a theme's yellow is by construction legible against its background.
    ///
    /// Blended toward the background rather than used at full strength. Every hit painted in full
    /// yellow makes a page of matches into a page of yellow, and -- worse -- makes the hit you are
    /// actually standing on indistinguishable from the forty you are not. Subdued here, full
    /// strength for the current one: the difference has to be visible at a glance, not on
    /// inspection. How far it is blended is not a constant: the text on these hits is the output's
    /// own, unchanged, so the tint may only go as strong as still lets the foreground read.
    ///
    /// Blended from `currentMatchBackground` rather than from the raw yellow, so the two are the
    /// same colour at two strengths by construction. Derived separately they collided on
    /// nyx-light -- one landed on 4.72:1 and the other on 4.55:1 of nearly the same gold, and the
    /// hit you were standing on was indistinguishable from the rest.
    public var searchMatchBackground: RGB {
        Palette.pushed(currentMatchBackground, toward: background, until: foreground,
                       reaches: Palette.target(foreground, background), from: 0.60, to: 0.92)
    }

    /// Background behind the current hit: the same hue at full strength, so the two are
    /// distinguishable at a glance without either becoming a different colour from "found text".
    ///
    /// Index 11 is the theme's bright yellow *where it is a yellow*. Solarized puts a grey there --
    /// its 8..15 row is a greyscale ramp -- and a grey slab is not a search highlight, so a palette
    /// whose bright yellow has no colour in it falls back to its ordinary one. Then the slab is
    /// lightened until the dark half of the theme reads on it, which is what makes this work on a
    /// light theme: there the raw yellow is dark enough to be body text, and a highlighter is not.
    /// The current hit and the text on it, decided together -- one cannot be chosen without the
    /// other, and deriving them separately is how they came to disagree.
    ///
    /// The slab is the theme's yellow at full strength; the text is whichever of the theme's two
    /// neutrals already reads on that yellow, and the slab moves only if neither does. Forcing the
    /// text to be the dark neutral instead -- the "black on a highlighter" idiom -- meant that on a
    /// light theme, whose yellow is dark enough to be body text, the slab had to be lightened to a
    /// khaki before the dark text cleared it, leaving no room between it and the tint the ordinary
    /// hits get. Letting the theme choose gives nyx-light a strong dark gold with the page colour
    /// on it, 46 units clear of the ordinary hits instead of 17.
    private var currentMatch: (background: RGB, foreground: RGB) {
        let raw = colors[11].chroma >= 18 ? colors[11] : colors[3]
        let text = RGB.contrast(background, raw) >= RGB.contrast(foreground, raw)
            ? background : foreground
        let away = text == background ? foreground : background
        return (Palette.pushed(raw, toward: away, until: text, reaches: 4.5, from: 0, to: 0.60), text)
    }

    public var currentMatchBackground: RGB { currentMatch.background }

    /// Text drawn on the *current* hit, which is painted at full strength.
    ///
    /// The other hits keep the ordinary foreground: their highlight is a tint behind unchanged
    /// text, which is what makes them read as marked rather than as selected.
    public var searchMatchForeground: RGB { currentMatch.foreground }

    /// The selected row in a panel Nyx draws itself -- the palette, a list.
    ///
    /// Deliberately not the terminal's `selectionBackground`, which is chosen to sit under the
    /// user's own text and, in several themes, is nearly the panel's background (invisible) or
    /// nearly its foreground (a dark slab under dark text). This is the accent, dropped toward the
    /// background just far enough that ordinary foreground text stays readable on it.
    public var panelSelectionBackground: RGB {
        // The ceiling matters as much as the floor here: chasing contrast all the way left the
        // row 6.8 units from Solarized's background, which is a selected row you cannot see. It
        // stops at four fifths, and a theme that cannot give 4.5:1 on a tinted row gives what it
        // has -- a list row is a surface, not a page of body text.
        Palette.pushed(accent, toward: background, until: foreground,
                       reaches: Palette.target(foreground, background), from: 0.40, to: 0.80)
    }

    /// Text for a note the terminal itself writes beside a row -- how long a command took. Blended
    /// toward the background: it has to be readable at a glance and must never compete with the
    /// output, which is the thing the user is actually reading. Backed off from the halfway point
    /// in themes that cannot afford it, so the note never falls under 3:1 unless the theme's own
    /// foreground is close to it.
    public var noteForeground: RGB {
        let floor = min(3.0, RGB.contrast(foreground, background) * 0.55)
        var amount = 0.45
        while amount > 0.05,
              RGB.contrast(RGB.blend(foreground, into: background, amount: amount), background) < floor {
            amount -= 0.05
        }
        return RGB.blend(foreground, into: background, amount: amount)
    }

    /// The tint behind every row of the block under the pointer: says "these rows are one thing"
    /// without competing with the selection colour, which is chosen to be seen. Background is the
    /// dominant colour, blended toward `accent` a little and pushed further only in themes where a
    /// little is invisible, too close to the selection, or too close to the foreground to read text
    /// on top of.
    ///
    /// Three mistakes this shape prevents:
    ///
    /// - `RGB.blend(a, into: b, amount:)` keeps mostly `a` at a small amount. `noteForeground`
    ///   above wants *text*, so it puts `foreground` first; a fill wants the opposite -- putting
    ///   `foreground` first here made the result read as foreground-on-foreground, 1.1:1, because
    ///   the "little" that bled in was the background, not the foreground.
    /// - Blending toward `foreground` (correctly, as the minority colour this time) still fails
    ///   one-dark: its selection is a step of grey on the very foreground/background axis this
    ///   blend walks, so every amount is either too close to the background or too close to the
    ///   selection -- there is no point on that line that clears both.
    /// - Blending toward `cursor` fixes one-dark (`cursor == foreground` in most built-ins, so no
    ///   behaviour change there; one-dark's cursor happens to carry its own hue, off the axis) but
    ///   is not *vetted* -- a user theme is free to set a saturated `cursor` at the foreground's own
    ///   luminance, which reads as black-on-black at 1:1 contrast for the loop's lower amounts. Only
    ///   `accent`, already load-bearing for `panelSelectionBackground`, has been screened for chroma,
    ///   distance from the foreground and contrast against the background, with a fallback to the
    ///   theme's own blue when the cursor does not clear those.
    ///
    /// The loop checks all three floors together first (background, selection, foreground contrast)
    /// and takes the first amount that clears every one. When no amount does, the selection floor is
    /// the one to give up -- a tint that is merely readable but happens to sit near the selection's
    /// colour is a smaller defect than a tint nobody can read text on. When even that combination
    /// fails for every amount tried, the smallest one is still what ships: some tint, however faint,
    /// beats none.
    public var blockHoverBackground: RGB {
        let amounts = Array(stride(from: 0.06, through: 0.20, by: 0.02))
        func candidate(_ amount: Double) -> RGB { RGB.blend(background, into: accent, amount: amount) }
        func clearsBackgroundAndContrast(_ c: RGB) -> Bool {
            RGB.distance(c, background) >= 4 && RGB.contrast(foreground, c) >= 4.5
        }
        if let amount = amounts.first(where: { a in
            let c = candidate(a)
            return clearsBackgroundAndContrast(c) && RGB.distance(c, selectionBackground) >= 8
        }) {
            return candidate(amount)
        }
        if let amount = amounts.first(where: { clearsBackgroundAndContrast(candidate($0)) }) {
            return candidate(amount)
        }
        return candidate(0.06)
    }

    public func resolve(_ c: Color, isForeground: Bool) -> RGB {
        switch c.kind {
        case .default: return isForeground ? foreground : background
        case .indexed: return colors[Int(c.index)]
        case .rgb: return RGB(c.r, c.g, c.b)
        }
    }
}
