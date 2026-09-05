import Testing
@testable import NyxCore

/// Themes the user wrote themselves, which is the half of the theming feature that existed only in
/// the documentation: `Themes.parse` was written, tested, and called by nothing at all.
@Suite("The theme catalogue")
struct ThemeCatalogTests {

    private let solarizedish = """
        # my own
        background = #002b36
        foreground = #839496
        cursor = #93a1a1
        palette = 1=#dc322f
        palette = 9=#ff6e67
        """

    @Test func aFileBecomesAThemeYouCanChoose() {
        let (catalog, problems) = ThemeCatalog.make(files: [ThemeFile(name: "mine", text: solarizedish)])
        #expect(problems.isEmpty)
        #expect(catalog.names.contains("mine"))
        #expect(catalog.contains("mine"))
        #expect(catalog.palette(named: "mine").background == RGB(0x00, 0x2b, 0x36))
        #expect(catalog.palette(named: "mine").colors[1] == RGB(0xdc, 0x32, 0x2f))
    }

    /// A user's file outranks the built-in of the same name. Someone who writes their own
    /// `gruvbox-dark` means theirs; preferring ours would be indistinguishable from ignoring the
    /// file, which is the failure mode a person cannot debug.
    @Test func aUserThemeOutranksTheBuiltInOfTheSameName() {
        let mine = "background = #101010\nforeground = #f0f0f0"
        let (catalog, _) = ThemeCatalog.make(files: [ThemeFile(name: "gruvbox-dark", text: mine)])
        #expect(catalog.palette(named: "gruvbox-dark").background == RGB(0x10, 0x10, 0x10))
        #expect(Themes.palette(named: "gruvbox-dark").background != RGB(0x10, 0x10, 0x10))
        // ...and it appears once in the list, not twice.
        #expect(catalog.names.filter { $0 == "gruvbox-dark" }.count == 1)
    }

    /// A file with nothing recognisable in it is reported, not registered. Registering it would put
    /// a theme in the picker that silently keeps every default -- picking it would look exactly
    /// like the terminal ignoring your choice.
    @Test func aFileWithNoColoursIsReportedRatherThanRegistered() {
        let (catalog, problems) = ThemeCatalog.make(files: [
            ThemeFile(name: "junk", text: "this is not a theme\n{}\n"),
            ThemeFile(name: "good", text: "background = #001122"),
        ])
        #expect(catalog.names.contains("good"))
        #expect(!catalog.names.contains("junk"))
        #expect(problems.map(\.name) == ["junk"])
        #expect(problems.first?.message.contains("junk") == true)
    }

    /// Two files can claim one theme name -- `mine` and `mine.bak` are the same name once the
    /// extension is dropped, and the second is exactly what a person makes before editing the
    /// first. The first in the caller's order wins (the caller sorts, so it is the same one on
    /// every launch) and the collision is named, because a theme resolving to whichever file the
    /// filesystem happened to return first is a thing nobody can debug.
    @Test func collidingNamesResolveTheSameWayTwiceAndSaySo() {
        let files = [ThemeFile(name: "mine", text: "background = #010101"),
                     ThemeFile(name: "mine", text: "background = #020202")]
        let (catalog, problems) = ThemeCatalog.make(files: files)
        #expect(catalog.palette(named: "mine").background == RGB(0x01, 0x01, 0x01))
        #expect(problems.count == 1)
        #expect(problems.first?.message.contains("two files") == true)

        let (again, _) = ThemeCatalog.make(files: files)
        #expect(again.palette(named: "mine").background == catalog.palette(named: "mine").background)
    }

    /// An unknown name still draws something. A typo in `theme =` must not leave a person with a
    /// terminal that refuses to paint.
    @Test func anUnknownNameFallsBackRatherThanFailing() {
        let (catalog, _) = ThemeCatalog.make(files: [])
        #expect(catalog.palette(named: "no-such-theme") == Themes.palette(named: "nyx-dark"))
        #expect(!catalog.contains("no-such-theme"))
    }

    /// The built-ins are all still there once files are in play -- a themes directory is an
    /// addition, not a replacement.
    @Test func everyBuiltInSurvivesTheArrivalOfUserThemes() {
        let (catalog, _) = ThemeCatalog.make(files: [ThemeFile(name: "mine", text: "background = #000000")])
        for name in Themes.builtin.keys {
            #expect(catalog.contains(name), "lost \(name)")
        }
        #expect(catalog.names.contains("mine"))
    }

    /// The palette a user file does not mention comes from the ANSI defaults rather than from
    /// whatever theme happened to be in force, so a file listing four colours is a complete theme
    /// and not a patch on an arbitrary one.
    @Test func aPartialFileIsAWholeThemeNotAPatch() {
        let (catalog, _) = ThemeCatalog.make(files: [ThemeFile(name: "sparse", text: "background = #000000")])
        let sparse = catalog.palette(named: "sparse")
        #expect(Array(sparse.colors.prefix(16)) == Palette.xtermAnsi16)
    }
}
