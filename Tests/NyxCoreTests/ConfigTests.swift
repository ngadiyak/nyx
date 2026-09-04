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

/// The scenario ConfigStore.reload() exists to protect against: a working `font-size = 18` gets
/// mistyped to `font-size = eighteen`. Reparsing with the previous config as `base` must leave
/// `fontSize` at 18 (what was in force), not reset it to `Config.defaults.fontSize` (13) -- losing a
/// working setting because of an unrelated typo on the same line is exactly the bug this guards.
@Test func aBadValueOnReloadKeepsThePreviousValueRatherThanTheCompiledDefault() {
    let (good, d0) = ConfigParser.parse("font-size = 18")
    #expect(d0.isEmpty)
    #expect(good.fontSize == 18)
    #expect(good.fontSize != Config.defaults.fontSize)

    let (reloaded, d1) = ConfigParser.parse("font-size = eighteen", base: good)
    #expect(d1.count == 1)
    #expect(reloaded.fontSize == 18)
}

/// A field the bad line doesn't touch keeps parsing normally: only the broken field falls back to
/// `base`, everything else in the same file still applies on top of it as usual.
@Test func otherSettingsInTheSameReloadStillApplyAlongsideABadLine() {
    let (good, _) = ConfigParser.parse("font-size = 18\npadding = 12")
    let (reloaded, d) = ConfigParser.parse("font-size = eighteen\npadding = 30", base: good)
    #expect(d.count == 1)
    #expect(reloaded.fontSize == 18)     // kept from base
    #expect(reloaded.padding == 30)      // the new, valid value
}

/// `base` exists to keep *scalar* settings alive across a reload that hits a typo. The additive
/// collections -- `keybinds` and `paletteOverrides` -- are a different case: the file is their only
/// source, so seeding them from `base` and then parsing the same file again appends every binding a
/// second time. Reloading an unchanged file must be idempotent, however many times the watcher fires.
@Test func reloadingAnUnchangedFileDoesNotAccumulateKeybinds() {
    let text = "keybind = cmd+t=new_tab\nkeybind = cmd+w=close_pane"
    var (config, d0) = ConfigParser.parse(text)
    #expect(d0.isEmpty)
    #expect(config.keybinds.count == 2)

    for _ in 0..<5 {
        (config, _) = ConfigParser.parse(text, base: config)
    }
    #expect(config.keybinds.count == 2)
}

/// Same idempotence requirement for the palette, and one step further: a reload must also *drop* an
/// override whose line the user deleted, rather than keeping it alive forever through `base`.
@Test func aRemovedPaletteLineIsForgottenOnReload() {
    let (first, _) = ConfigParser.parse("palette = 1=#ff0000\npalette = 2=#00ff00")
    #expect(first.paletteOverrides.count == 2)

    let (second, d) = ConfigParser.parse("palette = 1=#ff0000", base: first)
    #expect(d.isEmpty)
    #expect(second.paletteOverrides.count == 1)
    #expect(second.paletteOverrides[2] == nil)
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

/// Config keys whose default-file line is a plain scalar `# key = value`: uncommenting exactly that
/// one line reproduces `Config.defaults`, because the shown value *is* the compiled default.
/// `palette` and `keybind` are deliberately excluded -- both are additive (a file can list any
/// number of either), so their line is necessarily an *example*, not "the default": uncommenting it
/// always adds an entry, which can never equal `Config.defaults`'s empty collections. Those two are
/// covered separately, below, for "still parses" rather than "still equals the defaults".
private let scalarDefaultFileKeys = [
    "font-family", "font-size", "line-height", "font-thicken", "theme", "cursor-style", "cursor-blink",
    "scrollback-lines", "padding", "background-opacity", "background-blur", "window-decorations",
    "tab-bar", "shell", "working-directory", "copy-on-select", "middle-click-paste", "option-as-meta",
    "mouse-scroll-alt-screen", "bell", "confirm-close-process", "clipboard-read", "word-separators",
    "open-file-command",
]

@Test func theDefaultFileTextParsesBackToTheDefaults() {
    // Parsing the file exactly as shipped -- every line commented -- only proves the comments are
    // well-formed text: the parser skips every one of them without ever looking at the value that
    // follows, so it would return `Config.defaults` no matter what the comments said. Uncommenting
    // each scalar setting line first and parsing *that* is what actually catches a value that has
    // drifted from the real default.
    let lines = Config.defaultFileText.split(separator: "\n", omittingEmptySubsequences: false)
    let uncommented = lines.map { line -> Substring in
        for key in scalarDefaultFileKeys where line.hasPrefix("# \(key) =") {
            return line.dropFirst(2)
        }
        return line
    }.joined(separator: "\n")
    let (c, d) = ConfigParser.parse(uncommented)
    #expect(d.isEmpty, "default file has diagnostics once its scalar settings are uncommented: \(d)")
    #expect(c == Config.defaults)
}

@Test func thePaletteAndKeybindExampleLinesStillParseIfUncommented() {
    for prefix in ["# palette = ", "# keybind = "] {
        guard let line = Config.defaultFileText.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
            Issue.record("no example line found for \(prefix)")
            continue
        }
        let (_, d) = ConfigParser.parse(String(line.dropFirst(2)))
        #expect(d.isEmpty, "\(line) does not parse once uncommented: \(d)")
    }
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

// MARK: - Trailing comments

@Test func aCommentAfterAValueIsNotPartOfIt() {
    let (config, d) = ConfigParser.parse("font-size = 18  # bumped for the big monitor")
    #expect(d.isEmpty)
    #expect(config.fontSize == 18)
}

/// The qualifier that makes the rule safe. Colours are written `#rrggbb`, so a rule that stripped
/// from the first `#` on the line would turn every palette entry into an empty value.
@Test func aColourIsNotMistakenForAComment() {
    let (config, d) = ConfigParser.parse("palette = 1=#ff0000")
    #expect(d.isEmpty)
    #expect(config.paletteOverrides[1] == RGB(255, 0, 0))
}

@Test func aColourFollowedByACommentKeepsTheColour() {
    let (config, d) = ConfigParser.parse("palette = 2=#00ff00 # green")
    #expect(d.isEmpty)
    #expect(config.paletteOverrides[2] == RGB(0, 255, 0))
}

/// A value that is nothing but a comment is a value the user forgot to write, and has to be
/// reported rather than silently taken as an empty string.
@Test func aValueThatIsOnlyACommentIsADiagnostic() {
    let (config, d) = ConfigParser.parse("font-size = # what should this be?")
    #expect(d.count == 1)
    #expect(config.fontSize == Config.defaults.fontSize)
}
