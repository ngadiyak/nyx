import Foundation

/// What changed between two `Config`s, computed as a pure value so the decision of what to rebuild
/// -- the font atlas, the grid, the palette, nothing -- can be unit-tested without AppKit. The app
/// (`TerminalView.apply`, `TerminalWindowController`) reads these flags to do the minimum amount of
/// work on a reload.
public struct ConfigDiff: Equatable {
    /// `font-family`, `font-size`, `line-height`, `font-thicken`: rebuild the `FontSet`.
    public var fontChanged: Bool
    /// `padding`: recompute the grid even when the font itself didn't change.
    public var geometryChanged: Bool
    /// `theme`, the dark/light theme pair, `palette` overrides.
    public var paletteChanged: Bool
    /// `cursor-style`, `cursor-blink`.
    public var cursorChanged: Bool
    /// `scrollback-lines`: only takes effect for a new session.
    public var scrollbackChanged: Bool
    /// `background-opacity`, `background-blur`.
    public var windowAppearanceChanged: Bool
    /// `window-decorations`: only takes effect for a new window.
    public var windowDecorationsChanged: Bool

    public init(from old: Config, to new: Config) {
        fontChanged = old.fontFamily != new.fontFamily || old.fontSize != new.fontSize
            || old.lineHeight != new.lineHeight || old.fontThicken != new.fontThicken
        geometryChanged = old.padding != new.padding
        paletteChanged = old.themeName != new.themeName
            || old.darkThemeName != new.darkThemeName
            || old.lightThemeName != new.lightThemeName
            || old.paletteOverrides != new.paletteOverrides
        cursorChanged = old.cursorStyle != new.cursorStyle || old.cursorBlink != new.cursorBlink
        scrollbackChanged = old.scrollbackLines != new.scrollbackLines
        windowAppearanceChanged = old.backgroundOpacity != new.backgroundOpacity || old.backgroundBlur != new.backgroundBlur
        windowDecorationsChanged = old.windowDecorations != new.windowDecorations
    }

    /// True when nothing that `apply` acts on changed at all (e.g. only `shell` or `bell` changed,
    /// which are read at the point of use and need no rebuild).
    public var isEmpty: Bool {
        !(fontChanged || geometryChanged || paletteChanged || cursorChanged || scrollbackChanged
            || windowAppearanceChanged || windowDecorationsChanged)
    }

    /// Settings that changed but only take effect for a new session or window, so silently doing
    /// nothing would look like a bug. The banner names them instead.
    public var deferredNotes: [String] {
        var notes: [String] = []
        if scrollbackChanged { notes.append("scrollback-lines applies to new sessions only") }
        if windowDecorationsChanged { notes.append("window-decorations requires a new window") }
        return notes
    }
}
