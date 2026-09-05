import Testing
@testable import NyxCore

@Test func identicalConfigsProduceAnEmptyDiff() {
    let diff = ConfigDiff(from: .defaults, to: .defaults)
    #expect(diff.isEmpty)
    #expect(diff.deferredNotes.isEmpty)
}

@Test func fontSettingsSetOnlyFontChanged() {
    for mutate: (inout Config) -> Void in [
        { $0.fontFamily = "Courier New" },
        { $0.fontSize = 18 },
        { $0.lineHeight = 1.4 },
        { $0.fontThicken = true },
    ] {
        var c = Config.defaults
        mutate(&c)
        let diff = ConfigDiff(from: .defaults, to: c)
        #expect(diff.fontChanged)
        #expect(!diff.geometryChanged)
        #expect(!diff.paletteChanged)
        #expect(!diff.cursorChanged)
    }
}

@Test func paddingSetsOnlyGeometryChanged() {
    var c = Config.defaults
    c.padding = 24
    let diff = ConfigDiff(from: .defaults, to: c)
    #expect(!diff.fontChanged)
    #expect(diff.geometryChanged)
    #expect(!diff.paletteChanged)
}

@Test func themeSettingsSetOnlyPaletteChanged() {
    for mutate: (inout Config) -> Void in [
        { $0.themeName = "dracula" },
        { $0.darkThemeName = "nyx-dark" },
        { $0.lightThemeName = "nyx-light" },
        { $0.paletteOverrides[0] = RGB(1, 2, 3) },
    ] {
        var c = Config.defaults
        mutate(&c)
        let diff = ConfigDiff(from: .defaults, to: c)
        #expect(diff.paletteChanged)
        #expect(!diff.fontChanged)
        #expect(!diff.geometryChanged)
        #expect(!diff.cursorChanged)
    }
}

@Test func cursorSettingsSetOnlyCursorChanged() {
    for mutate: (inout Config) -> Void in [
        { $0.cursorStyle = .bar },
        { $0.cursorBlink = false },
    ] {
        var c = Config.defaults
        mutate(&c)
        let diff = ConfigDiff(from: .defaults, to: c)
        #expect(diff.cursorChanged)
        #expect(!diff.fontChanged)
        #expect(!diff.paletteChanged)
    }
}

@Test func scrollbackLinesIsFlaggedAndNoted() {
    var c = Config.defaults
    c.scrollbackLines = 50_000
    let diff = ConfigDiff(from: .defaults, to: c)
    #expect(diff.scrollbackChanged)
    #expect(!diff.isEmpty)
    #expect(diff.deferredNotes.contains { $0.contains("scrollback-lines") })
}

@Test func windowDecorationsIsFlaggedAndNoted() {
    var c = Config.defaults
    c.windowDecorations = false
    let diff = ConfigDiff(from: .defaults, to: c)
    #expect(diff.windowDecorationsChanged)
    #expect(diff.deferredNotes.contains { $0.contains("window-decorations") })
}

@Test func backgroundSettingsSetOnlyWindowAppearanceChanged() {
    for mutate: (inout Config) -> Void in [
        { $0.backgroundOpacity = 0.5 },
        { $0.backgroundBlur = 10 },
    ] {
        var c = Config.defaults
        mutate(&c)
        let diff = ConfigDiff(from: .defaults, to: c)
        #expect(diff.windowAppearanceChanged)
        #expect(!diff.fontChanged)
        #expect(!diff.paletteChanged)
        #expect(diff.deferredNotes.isEmpty)
    }
}

@Test func settingsReadAtThePointOfUseProduceNoDiffAtAll() {
    for mutate: (inout Config) -> Void in [
        { $0.copyOnSelect = true },
        { $0.middleClickPaste = false },
        { $0.wordSeparators = Set(",;") },
        { $0.optionAsMeta = .both },
        { $0.mouseScrollAltScreen = false },
        { $0.clipboardRead = true },
        { $0.bell = .sound },
        { $0.shell = "/bin/bash" },
        { $0.workingDirectory = "/tmp" },
    ] {
        var c = Config.defaults
        mutate(&c)
        let diff = ConfigDiff(from: .defaults, to: c)
        #expect(diff.isEmpty, "expected no diff for \(c)")
    }
}

@Test func foldSettingsSetOnlyFoldingChanged() {
    var c = Config.defaults
    c.foldKeepLines = 5
    let diff = ConfigDiff(from: .defaults, to: c)
    #expect(diff.foldingChanged)
    #expect(!diff.fontChanged && !diff.geometryChanged && !diff.paletteChanged)
    #expect(!diff.isEmpty)
    #expect(diff.deferredNotes.isEmpty)
}
