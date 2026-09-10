import Foundation

/// The character a menu item carries for a key that is not a character, read in both directions.
///
/// A menu item's shortcut is a `keyEquivalent` string plus a modifier mask, and for ↑ ⇞ ⌦ F5 that
/// string is one of AppKit's function-key scalars -- `NSUpArrowFunctionKey` and friends, Unicode
/// private-use code points from 0xF700 up, fixed since NeXT and documented as such. Two directions
/// are needed: the menu bar and the block menu hand them *out* (`MenuShortcut.keyEquivalent`), and
/// `MenuSnapshot` reads them *back* so `Key.displayName` can say how to draw the chord -- the
/// system font has no glyph for a private-use scalar, and a picture of a menu drew a missing-glyph
/// box where ⌘⇧↑ belongs.
///
/// One list, so a key cannot go out as one character and come back as another. It lives in
/// **NyxCore** rather than beside the menu builders because NyxApp has no test target: a table
/// read two ways with no test on the round trip is exactly the copy that goes stale, which is what
/// happened to the third copy `MenuSnapshot` used to carry.
///
/// The numbers are written out because NyxCore may not import AppKit. `NYX_SMOKE_QA` checked them
/// against the framework's own constants in the built app when this landed; the values are pinned
/// by a test here, so a typo cannot reach a menu quietly.
public extension Key {
    /// The scalar to put in a menu item's `keyEquivalent`, or nil for a `.char` -- AppKit takes an
    /// ordinary character as itself, and the menu builders switch on that case first.
    var menuKeyEquivalent: Unicode.Scalar? {
        // `NSF1FunctionKey` upwards is arithmetic rather than a list: 35 rows of it would be a
        // table nobody reads, and the range is what AppKit itself documents.
        if case .f(let n) = self {
            guard n >= 1, n <= Key.functionKeyCount else { return nil }
            return Unicode.Scalar(Key.f1Scalar + UInt32(n - 1))
        }
        return Key.menuKeyEquivalents.first { $0.key == self }?.scalar
    }

    /// The key a menu item's `keyEquivalent` names, or nil when the character names none -- which
    /// is every ordinary letter, and is the answer for `.char`'s own case.
    init?(menuKeyEquivalent scalar: Unicode.Scalar) {
        if let named = Key.menuKeyEquivalents.first(where: { $0.scalar == scalar })?.key {
            self = named
            return
        }
        let value = scalar.value
        guard value >= Key.f1Scalar, value < Key.f1Scalar + UInt32(Key.functionKeyCount) else {
            return nil
        }
        self = .f(Int(value - Key.f1Scalar) + 1)
    }

    /// `NSF1FunctionKey`, and the 35 keys AppKit reserves from there (`NSF35FunctionKey` is
    /// 0xF726). Everything above that range is another key's scalar, so the bound is not a guess.
    private static var f1Scalar: UInt32 { 0xF704 }
    private static var functionKeyCount: Int { 35 }

    /// Every non-character key AppKit has a scalar for, `.f` excepted. The four control characters
    /// at the end are not private-use scalars at all: a menu item for ⌘⌫ carries a real backspace,
    /// which is what AppKit's own menus use and what `NSMenuItem` compares against.
    private static var menuKeyEquivalents: [(key: Key, scalar: Unicode.Scalar)] {
        [(.up, "\u{F700}"), (.down, "\u{F701}"), (.left, "\u{F702}"), (.right, "\u{F703}"),
         (.insert, "\u{F727}"), (.delete, "\u{F728}"), (.home, "\u{F729}"), (.end, "\u{F72B}"),
         (.pageUp, "\u{F72C}"), (.pageDown, "\u{F72D}"),
         (.backspace, "\u{8}"), (.tab, "\u{9}"), (.enter, "\u{d}"), (.escape, "\u{1b}")]
    }
}
