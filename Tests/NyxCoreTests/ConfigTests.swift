import Testing
@testable import NyxCore

private func parse(_ s: String) -> (Config, [ConfigDiagnostic]) { ConfigParser.parse(s) }

@Test func anEmptyFileGivesTheDefaults() {
    let (c, d) = parse("")
    #expect(c == Config.defaults)
    #expect(d.isEmpty)
}

@Test func commentsAndBlankLinesAreIgnored() {
    let (c, d) = parse("# a comment\n\n   \n# another\n")
    #expect(c == Config.defaults)
    #expect(d.isEmpty)
}

@Test func parsesScalarSettings() {
    let (c, d) = parse("""
    font-family = JetBrains Mono
    font-size = 15
    line-height = 1.2
    padding = 12
    scrollback-lines = 50000
    background-opacity = 0.9
    """)
    #expect(d.isEmpty)
    #expect(c.fontFamily == "JetBrains Mono")
    #expect(c.fontSize == 15)
    #expect(c.lineHeight == 1.2)
    #expect(c.padding == 12)
    #expect(c.scrollbackLines == 50000)
    #expect(c.backgroundOpacity == 0.9)
}

@Test func whitespaceAroundKeysAndValuesIsTrimmed() {
    let (c, _) = parse("   font-size   =   20   ")
    #expect(c.fontSize == 20)
}

@Test func valuesMayContainEqualsSigns() {
    let (c, _) = parse("open-file-command = code -g {file}:{line}")
    #expect(c.openFileCommand == "code -g {file}:{line}")
}

@Test func parsesBooleans() {
    let (c, d) = parse("copy-on-select = true\nmiddle-click-paste = false\ncursor-blink = no\nwindow-decorations = yes")
    #expect(d.isEmpty)
    #expect(c.copyOnSelect)
    #expect(!c.middleClickPaste)
    #expect(!c.cursorBlink)
    #expect(c.windowDecorations)
}

@Test func parsesEnums() {
    let (c, d) = parse("cursor-style = bar\noption-as-meta = both\nbell = none\ntab-bar = always")
    #expect(d.isEmpty)
    #expect(c.cursorStyle == .bar)
    #expect(c.optionAsMeta == .both)
    #expect(c.bell == .none)
    #expect(c.tabBar == .always)
}

@Test func parsesAPlainThemeName() {
    let (c, _) = parse("theme = gruvbox-dark")
    #expect(c.themeName == "gruvbox-dark")
    #expect(c.darkThemeName == nil && c.lightThemeName == nil)
}

@Test func parsesADarkLightThemePair() {
    let (c, d) = parse("theme = dark:nyx-dark,light:nyx-light")
    #expect(d.isEmpty)
    #expect(c.darkThemeName == "nyx-dark")
    #expect(c.lightThemeName == "nyx-light")
}

@Test func parsesWordSeparators() {
    let (c, _) = parse("word-separators = ,;:")
    #expect(c.wordSeparators == Set(",;:"))
}

@Test func parsesPaletteOverrides() {
    let (c, d) = parse("palette = 0=#1a1b26\npalette = 15=#ffffff")
    #expect(d.isEmpty)
    #expect(c.paletteOverrides[0] == RGB(0x1a, 0x1b, 0x26))
    #expect(c.paletteOverrides[15] == RGB(255, 255, 255))
}

@Test func anUnknownKeyIsADiagnosticNotAFailure() {
    let (c, d) = parse("font-size = 15\nnot-a-setting = 3\npadding = 4")
    #expect(c.fontSize == 15)
    #expect(c.padding == 4)
    #expect(d.count == 1)
    #expect(d[0].line == 2)
    #expect(d[0].message.contains("not-a-setting"))
}

@Test func aBadValueKeepsTheDefaultAndReportsTheLine() {
    let (c, d) = parse("\nfont-size = enormous\n")
    #expect(c.fontSize == Config.defaults.fontSize)
    #expect(d.count == 1)
    #expect(d[0].line == 2)
}

@Test func aLineWithNoEqualsIsADiagnostic() {
    let (_, d) = parse("font-size 15")
    #expect(d.count == 1)
    #expect(d[0].line == 1)
}

@Test func outOfRangeNumbersAreClamped() {
    let (c, _) = parse("font-size = 0\nbackground-opacity = 5\nscrollback-lines = -3")
    #expect(c.fontSize >= 4)
    #expect(c.backgroundOpacity == 1.0)
    #expect(c.scrollbackLines == 0)
}

@Test func aLaterLineWinsOverAnEarlierOne() {
    let (c, _) = parse("font-size = 10\nfont-size = 20")
    #expect(c.fontSize == 20)
}
