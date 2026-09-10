import Foundation
import Testing
@testable import NyxCore

private func buffer(_ lines: [LensLine], id: UInt32 = 2, version: UInt64 = 1) -> LensBuffer {
    LensBuffer(commandID: id, lens: .pretty, lines: lines, contentVersion: version)
}

private func text(_ row: Row) -> String {
    String(row.cells.map { $0.content == 0 ? " " : Character(UnicodeScalar($0.content)!) })
        .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
}

// MARK: - Rows

/// A lens line is not reflowed. The terminal's own rows wrap because a program wrote them that
/// way; these are Nyx's own text, and a pretty-printed body that rewrapped at every pane width
/// would have its indentation -- the only thing holding the structure together -- destroyed by a
/// narrow window. It is cut, and the cut is visible.
@Test func rowCutsWithEllipsis() {
    let line = LensLine("0123456789abcdef")
    let row = buffer([line]).row(0, cols: 10, palette: .standard)
    #expect(text(row) == "012345678\u{2026}")
    #expect(row.cells.count == 10)

    // Exactly the width fits, with nothing cut.
    #expect(text(buffer([LensLine("0123456789")]).row(0, cols: 10, palette: .standard))
            == "0123456789")
    // Shorter is padded with empty cells, as any terminal row is.
    let short = buffer([LensLine("ab")]).row(0, cols: 10, palette: .standard)
    #expect(short.cells[2].content == 0)
    #expect(short.cells.count == 10)
}

@Test func stylesBecomeColours() {
    let line = LensLine("\"a\": 1",
                        spans: [.init(range: 0 ..< 3, style: .key),
                                .init(range: 5 ..< 6, style: .number)])
    let row = buffer([line]).row(0, cols: 20, palette: .standard)
    #expect(row.cells[0].fg == .indexed(4))          // the key, quotes included
    #expect(row.cells[2].fg == .indexed(4))
    #expect(row.cells[3].fg == .default)             // the colon between them is not a token
    #expect(row.cells[5].fg == .indexed(3))
    #expect(row.cells[5].attrs.isEmpty)
}

/// A search hit inverts rather than taking a colour, so it is visible on top of whatever the token
/// under it was already coloured.
@Test func aMatchInvertsInsteadOfRecolouring() {
    let line = LensLine("2: needle", spans: [.init(range: 3 ..< 9, style: .match)])
    let row = buffer([line]).row(0, cols: 20, palette: .standard)
    #expect(row.cells[3].attrs.contains(.inverse))
    #expect(row.cells[3].fg == .default)
    #expect(!row.cells[0].attrs.contains(.inverse))
}

@Test func everyStyleHasAColour() {
    let palette = LensPalette.standard
    #expect(palette.colour(for: .key) == .indexed(4))
    #expect(palette.colour(for: .string) == .indexed(2))
    #expect(palette.colour(for: .number) == .indexed(3))
    #expect(palette.colour(for: .literal) == .indexed(5))
    #expect(palette.colour(for: .header) == .indexed(6))
    #expect(palette.colour(for: .added) == .indexed(2))
    #expect(palette.colour(for: .removed) == .indexed(1))
    #expect(palette.colour(for: .dim) == .indexed(8))
    // `.match` is an attribute, not a colour.
    #expect(palette.colour(for: .match) == nil)
    #expect(palette.attributes(for: .match) == .inverse)
    #expect(palette.attributes(for: .key).isEmpty)
}

/// The palette is a value, so a theme can hand the renderer its own without this type knowing what
/// a theme is.
@Test func aPaletteCanBeOverridden() {
    var palette = LensPalette.standard
    palette.key = .rgb(1, 2, 3)
    let line = LensLine("\"a\"", spans: [.init(range: 0 ..< 3, style: .key)])
    #expect(buffer([line]).row(0, cols: 10, palette: palette).cells[0].fg == .rgb(1, 2, 3))
}

/// A row asked for beyond the end is empty rather than a crash: the buffer and the display are
/// rebuilt at different moments, and a frame in between must draw *something*.
@Test func aRowPastTheEndIsBlank() {
    let empty = buffer([LensLine("a")]).row(5, cols: 4, palette: .standard)
    #expect(empty.cells.allSatisfy { $0.content == 0 })
    #expect(buffer([LensLine("a")]).line(5) == nil)
    #expect(buffer([]).lineCount == 0)
}

// MARK: - Copying

@Test func textOfRange() {
    let lines = [LensLine("{"), LensLine("  \"a\": 1"), LensLine("}")]
    #expect(buffer(lines).text(lines: 0..<3) == "{\n  \"a\": 1\n}")
    #expect(buffer(lines).text(lines: 1..<2) == "  \"a\": 1")
    // Out of range is clamped rather than trapped: a selection outlives the buffer it was made on.
    #expect(buffer(lines).text(lines: 1..<99) == "  \"a\": 1\n}")
    #expect(buffer(lines).text(lines: 5..<9).isEmpty)
}

/// The buffer says which version of the terminal's content it was built from, so a pane can tell a
/// stale rendering from a current one without comparing every line.
@Test func staleIsAVersionComparison() {
    let terminal = makeTerminal(cols: 20, rows: 4)
    terminal.feed("hello\r\n")
    let built = LensBuffer(commandID: 2, lens: .pretty, lines: [], contentVersion: terminal.contentVersion)
    #expect(built.contentVersion == terminal.contentVersion)
    terminal.feed("more\r\n")
    #expect(built.contentVersion != terminal.contentVersion)
}

/// The fold point on a line survives into the buffer: Task 4 hangs a click on it, and a placeholder
/// nobody can click is a fold nobody can open.
@Test func aLineKeepsItsFoldPoint() {
    let node = NodePath([.key("items")])
    let line = LensLine("  \"items\": \u{25B8} […] 2 items", node: node, depth: 1)
    #expect(buffer([line]).line(0)?.node == node)
    #expect(buffer([line]).line(0)?.depth == 1)
}

// MARK: - Cells, not characters

/// The terminal measures in cells and so must this: `日` is two columns wide, so ten of them fill a
/// twenty-column pane. Measured in Characters they filled ten, and every glyph after the first
/// would have been drawn over its neighbour and the row run past the edge of the pane.
@Test func aWideGlyphTakesTwoCells() {
    let row = buffer([LensLine("日本語")]).row(0, cols: 10, palette: .standard)
    #expect(row.cells[0].content == "日".unicodeScalars.first!.value)
    #expect(row.cells[0].attrs.contains(.wide))
    #expect(row.cells[1].content == 0)
    #expect(row.cells[1].attrs.contains(.wideSpacer))
    #expect(row.cells[2].content == "本".unicodeScalars.first!.value)
    #expect(row.cells[2].attrs.contains(.wide))
    #expect(row.cells[4].content == "語".unicodeScalars.first!.value)
    // Six columns used by three characters, and the rest of the row is empty.
    #expect(row.cells[6].content == 0)
    #expect(!row.cells[6].attrs.contains(.wideSpacer))
}

/// The cut is in columns too, and a wide glyph that would straddle it is dropped rather than half
/// drawn: half of a `日` is a different character.
@Test func theCutCountsColumns() {
    let row = buffer([LensLine("日本語")]).row(0, cols: 4, palette: .standard)
    #expect(row.cells[0].content == "日".unicodeScalars.first!.value)
    #expect(row.cells[1].attrs.contains(.wideSpacer))
    #expect(row.cells[2].content == 0, "本 would straddle the ellipsis, so it is not drawn at all")
    #expect(row.cells[3].content == 0x2026)
    #expect(row.cells.count == 4)
}

/// A line whose display width is exactly the pane's is not cut.
@Test func aLineThatExactlyFillsIsNotCut() {
    let row = buffer([LensLine("日本語")]).row(0, cols: 6, palette: .standard)
    #expect(row.cells[4].content == "語".unicodeScalars.first!.value)
    #expect(row.cells[5].attrs.contains(.wideSpacer))
    #expect(!row.cells.contains { $0.content == 0x2026 })
}

/// Spans are Character offsets and cells are columns: the two walk together, so a colour still
/// lands on the glyph it belongs to when a wide one has moved everything after it along.
@Test func aSpanOverAWideGlyphColoursTheRightCells() {
    let line = LensLine("\"🚀\": 1",
                        spans: [.init(range: 0 ..< 3, style: .key),
                                .init(range: 5 ..< 6, style: .number)])
    let row = buffer([line]).row(0, cols: 20, palette: .standard)
    #expect(row.cells[0].fg == .indexed(4))          // the opening quote
    #expect(row.cells[1].fg == .indexed(4))          // the emoji, two cells wide
    #expect(row.cells[1].attrs.contains(.wide))
    #expect(row.cells[2].attrs.contains(.wideSpacer))
    #expect(row.cells[2].fg == .indexed(4), "the spacer carries the lead cell's colour")
    #expect(row.cells[3].fg == .indexed(4))          // the closing quote
    #expect(row.cells[4].fg == .default)             // the colon
    #expect(row.cells[6].fg == .indexed(3))          // `1`, one column later than its Character
    #expect(row.cells[6].content == UInt32(UInt8(ascii: "1")))
}

/// And the ordinary case is untouched: an ASCII line is one cell per character, as it always was.
@Test func anASCIILineIsUnchanged() {
    let line = LensLine("  \"a\": 1", spans: [.init(range: 2 ..< 5, style: .key)])
    let row = buffer([line]).row(0, cols: 12, palette: .standard)
    #expect(text(row) == "  \"a\": 1")
    #expect(row.cells[2].fg == .indexed(4))
    #expect(row.cells[7].content == UInt32(UInt8(ascii: "1")))
    #expect(!row.cells.contains { $0.attrs.contains(.wide) || $0.attrs.contains(.wideSpacer) })
}

/// The lens' `dim` -- the latency line, both fold placeholders, the `↪ 301 →` line and the diff
/// summary -- has to be readable in the theme it is drawn in.
///
/// `.indexed(8)` handed to the renderer raw is the theme's bright black against the theme's
/// background: 1.91:1 in nyx-dark, 2.32 in one-dark, 2.46 in catppuccin-mocha, 2.79 in
/// solarized-dark, 3.03 in dracula. Text at 1.9:1 is not dim, it is absent.
@Test func dimIsReadableInEveryBuiltInTheme() {
    for (name, palette) in Themes.builtin {
        let dim = LensPalette.dimColour(in: palette)
        let contrast = RGB.contrast(dim, palette.background)
        #expect(contrast >= 4.5, "\(name): \(contrast)")
        // …and never stronger than the body text, or it is not a dim style at all. Where the
        // theme leaves room between the floor and three quarters of the foreground's contrast, it
        // stays under that too; where it does not, the floor wins -- an unreadable dim is the
        // worse of the two failures.
        let foreground = RGB.contrast(palette.foreground, palette.background)
        #expect(contrast <= foreground, "\(name): \(contrast) vs fg \(foreground)")
        if foreground * 0.75 >= 4.5 {
            #expect(contrast <= foreground * 0.75 + 0.001, "\(name): \(contrast) vs fg \(foreground)")
        }
    }
}

/// The theme's own colours, so a lens is in the theme's green and the theme's red like everything
/// else on the screen -- and `dim` resolved rather than passed through as an index.
@Test func theThemePaletteResolvesOnlyDim() {
    let palette = Themes.builtin["nyx-dark"] ?? Palette.xtermDefault()
    let lens = LensPalette.forTheme(palette)
    #expect(lens.key == LensPalette.standard.key)
    #expect(lens.string == LensPalette.standard.string)
    #expect(lens.dim != LensPalette.standard.dim)
    #expect(lens.dim.kind == .rgb)
}

// MARK: - Where a lens line's fold control actually is

/// §2.4 narrows a lens line's fold target from the whole row to the marker, so a reader can drag
/// across the text beside it. The spec says that marker is at column 0; in a pretty-printed body it
/// is not, because `JSONDocument` writes the indent and the key before it. This is the column it
/// really occupies, so the pointing hand and the click land on the glyph the eye picked.
@Test func aLensLineKnowsWhichColumnItsFoldMarkerIsIn() {
    let lines = [
        LensLine("\u{25B8} 5 headers \u{b7} content-type: application/json",
                 node: ResponseLens.headersNode),          // the headers line: column 0
        LensLine("{", node: NodePath([])),                  // an open root: the bracket, column 0
        LensLine("  \"results\": \u{25B8} [\u{2026}] 40 items,",
                 node: NodePath([.key("results")])),        // folded, indented, after the key
        LensLine("  \"users\": [", node: NodePath([.key("users")])),  // open: its bracket
        LensLine("    \"id\": 1,"),                          // not a fold point at all
    ]
    let b = buffer(lines)
    #expect(b.foldMarkerColumn(line: 0) == 0)
    #expect(b.foldMarkerColumn(line: 1) == 0)
    #expect(b.foldMarkerColumn(line: 2) == 13)
    #expect(b.foldMarkerColumn(line: 3) == 11)
    #expect(b.foldMarkerColumn(line: 4) == nil)
    #expect(b.foldMarkerColumn(line: 99) == nil)
}

/// Measured in cells, like everything else a lens hands the grid: a wide glyph in a key is two
/// columns, and a marker column counted in Characters would put the target one cell left of the
/// triangle for every such line.
@Test func theFoldMarkerColumnIsCountedInCellsNotCharacters() {
    let b = buffer([LensLine("  \"\u{65E5}\u{672C}\": \u{25B8} [\u{2026}] 2 items",
                             node: NodePath([.key("\u{65E5}\u{672C}")]))])
    // 2 spaces + `"` + 日本 (4 cells) + `"` + `:` + space = 10
    #expect(b.foldMarkerColumn(line: 0) == 10)
}
