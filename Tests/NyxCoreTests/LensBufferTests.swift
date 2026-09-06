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
