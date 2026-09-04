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

@Test func crlfLineEndingsParseTheSameAsLF() {
    let lf = "font-size = 15\nfont-family = Menlo\npadding = 20\n"
    let crlf = "font-size = 15\r\nfont-family = Menlo\r\npadding = 20\r\n"
    let (cLF, dLF) = parse(lf)
    let (cCRLF, dCRLF) = parse(crlf)
    #expect(dCRLF.isEmpty)
    #expect(dCRLF == dLF)
    #expect(cCRLF == cLF)
}

@Test func loneCRLineEndingsParseTheSameAsLF() {
    let lf = "font-size = 15\nfont-family = Menlo\npadding = 20\n"
    let cr = "font-size = 15\rfont-family = Menlo\rpadding = 20\r"
    let (cLF, _) = parse(lf)
    let (cCR, dCR) = parse(cr)
    #expect(dCR.isEmpty)
    #expect(cCR == cLF)
}

@Test func paletteIndexOutOfRangeIsADiagnostic() {
    let (c, d) = parse("palette = 300=#ffffff\npalette = -1=#ffffff")
    #expect(c.paletteOverrides[300] == nil)
    #expect(c.paletteOverrides[-1] == nil)
    #expect(d.count == 2)
    #expect(d[0].line == 1)
    #expect(d[1].line == 2)
}

@Test func fontThickenDefaultsToFalseAndParses() {
    let (c0, _) = parse("")
    #expect(!c0.fontThicken)
    let (c, d) = parse("font-thicken = true")
    #expect(d.isEmpty)
    #expect(c.fontThicken)
}

@Test func theDefaultFileTextParsesBackToTheDefaults() {
    let (c, d) = ConfigParser.parse(Config.defaultFileText)
    #expect(d.isEmpty, "default file has diagnostics: \(d)")
    #expect(c == Config.defaults)
}

@Test func theDefaultFileTextIsFullyCommented() {
    // Every setting line is commented out, so the file documents without overriding. Uncommenting
    // any single line must still parse.
    for line in Config.defaultFileText.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { continue }
        #expect(t.hasPrefix("#"), "uncommented line in the default file: \(t)")
    }
}

@Test func everySettingAppearsInTheDefaultFile() {
    for key in ["font-family", "font-size", "line-height", "theme", "cursor-style", "cursor-blink",
                "scrollback-lines", "padding", "background-opacity", "background-blur", "shell",
                "working-directory", "copy-on-select", "middle-click-paste", "option-as-meta",
                "bell", "confirm-close-process", "clipboard-read", "tab-bar", "window-decorations",
                "word-separators", "open-file-command", "keybind", "palette"] {
        #expect(Config.defaultFileText.contains(key), "default file does not mention \(key)")
    }
}

@Test func configPathUsesNyxConfigEnvVarWhenSet() {
    let url = ConfigPath.resolve(environment: ["NYX_CONFIG": "/tmp/custom-config"], home: "/Users/nik")
    #expect(url.path == "/tmp/custom-config")
}

@Test func configPathFallsBackToDotConfigWhenUnset() {
    let url = ConfigPath.resolve(environment: [:], home: "/Users/nik")
    #expect(url.path == "/Users/nik/.config/nyx/config")
}

@Test func configPathIgnoresAnEmptyNyxConfigEnvVar() {
    let url = ConfigPath.resolve(environment: ["NYX_CONFIG": ""], home: "/Users/nik")
    #expect(url.path == "/Users/nik/.config/nyx/config")
}
