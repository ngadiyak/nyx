import Foundation

/// The colours a lens draws its tokens in, as terminal colours.
///
/// Indexed rather than RGB, so a lensed response is in the *theme's* green and the theme's red like
/// everything else on the screen -- and a value type rather than a constant, so a theme that wants
/// its own can hand one over without this file learning what a theme is.
///
/// `.match` has no colour on purpose: a search hit inverts, which is visible on top of whatever the
/// token underneath was already coloured. A colour for it would have to win against eight others.
public struct LensPalette: Equatable {
    public var key: Color
    public var string: Color
    public var number: Color
    public var literal: Color
    public var header: Color
    public var added: Color
    public var removed: Color
    public var dim: Color

    public init(key: Color, string: Color, number: Color, literal: Color, header: Color,
                added: Color, removed: Color, dim: Color) {
        self.key = key
        self.string = string
        self.number = number
        self.literal = literal
        self.header = header
        self.added = added
        self.removed = removed
        self.dim = dim
    }

    public static let standard = LensPalette(key: .indexed(4), string: .indexed(2),
                                             number: .indexed(3), literal: .indexed(5),
                                             header: .indexed(6), added: .indexed(2),
                                             removed: .indexed(1), dim: .indexed(8))

    /// `standard` with `dim` resolved against this theme instead of handed over as an index.
    ///
    /// `dim` is what the latency line, both fold placeholders, the `↪ 301 →` redirect line and the
    /// diff summary are drawn in -- four things a reader is meant to be able to read. As
    /// `.indexed(8)` it is the theme's bright black on the theme's background, which measured
    /// 1.91:1 in nyx-dark, 2.32 in one-dark, 2.46 in catppuccin-mocha, 2.79 in solarized-dark and
    /// 3.03 in dracula. Text at 1.9:1 is not dim, it is absent.
    ///
    /// The other seven stay indexed on purpose: they are the theme's own green, red and blue, and
    /// a lens should be in the colours the rest of the screen is in.
    ///
    /// Cheap, but not free -- twenty blend steps in the worst case -- so it is computed once per
    /// frame by the caller and never inside the per-row loop.
    public static func forTheme(_ palette: Palette) -> LensPalette {
        var lens = standard
        let dim = dimColour(in: palette)
        lens.dim = .rgb(dim.r, dim.g, dim.b)
        return lens
    }

    /// The dim colour for a theme: readable, and still visibly dimmer than the body text.
    ///
    /// A floor and a ceiling, because both mistakes are real. Below 4.5:1 the line cannot be read
    /// at all; at the foreground's own contrast it stops being a dim style and the fold placeholder
    /// reads as something the server printed. The ceiling is three quarters of the foreground's
    /// contrast, and the floor wins where a theme leaves no room between them -- an unreadable dim
    /// is the worse of the two failures.
    public static func dimColour(in palette: Palette) -> RGB {
        let background = palette.background
        let floor = 4.5
        let ceiling = max(floor, RGB.contrast(palette.foreground, background) * 0.75)
        let lifted = RGB.readable(palette.colors[8], on: background, towards: palette.foreground,
                                  minimum: floor)
        guard RGB.contrast(lifted, background) > ceiling else { return lifted }
        // Too strong: back towards the background, stopping at the first step under the ceiling
        // that is still over the floor.
        for step in 1...20 {
            let candidate = RGB.blend(lifted, into: background, amount: Double(step) / 20)
            let contrast = RGB.contrast(candidate, background)
            if contrast <= ceiling { return contrast >= floor ? candidate : lifted }
        }
        return lifted
    }

    /// nil for `.match`, which is an attribute rather than a colour.
    public func colour(for style: LensStyle) -> Color? {
        switch style {
        case .key: return key
        case .string: return string
        case .number: return number
        case .literal: return literal
        case .header: return header
        case .added: return added
        case .removed: return removed
        case .dim: return dim
        case .match: return nil
        }
    }

    /// Bright black is the dim colour, without the `.dim` *attribute*: dimmed bright black reads as
    /// something the shell printed and half meant, which is the mistake the fold placeholder made
    /// before it stopped dimming too.
    public func attributes(for style: LensStyle) -> CellAttrs {
        style == .match ? .inverse : []
    }
}

/// One command's response, rendered through one lens, ready to be drawn.
///
/// Built by whoever owns the pane and handed back to `Terminal.displayRows`; nothing in here reads
/// the terminal, so the same buffer can be built off the main thread and kept while a newer one is
/// built.
public struct LensBuffer: Equatable {
    public let commandID: UInt32
    public let lens: ResponseLens
    public let lines: [LensLine]
    /// The terminal's `contentVersion` when these lines were built, so a caller can tell how old
    /// this rendering is.
    ///
    /// **Nothing compares it today.** The pane stamps it in `rebuildLens` and never reads it back:
    /// a rebuild is asked for when the block finishes, when the lens changes and when a node is
    /// folded, and none of those needs a version to decide anything. It is here because a buffer
    /// that outlives the rows it was read from is a real possibility -- a command that keeps
    /// printing after its `D` mark -- and whatever notices that will need this number rather than a
    /// second parse of the grid. Read it as "when", not as "stale": no code path acts on it.
    public let contentVersion: UInt64

    public init(commandID: UInt32, lens: ResponseLens, lines: [LensLine], contentVersion: UInt64) {
        self.commandID = commandID
        self.lens = lens
        self.lines = lines
        self.contentVersion = contentVersion
    }

    public var lineCount: Int { lines.count }

    /// nil past the end. The buffer and the display are rebuilt at different moments, so a frame
    /// can ask for a line that has just stopped existing.
    public func line(_ index: Int) -> LensLine? {
        lines.indices.contains(index) ? lines[index] : nil
    }

    /// One line as a row of cells, so it is drawn through the ordinary row path and nothing in
    /// NyxRender learns what a lens is -- the same arrangement `foldPlaceholderRow` has.
    ///
    /// Nothing wraps. The terminal's own rows are wrapped because a program wrote them that way;
    /// these are Nyx's own text, and a pretty-printed body rewrapped at every pane width would lose
    /// the indentation that is the only thing holding its structure together. A line too long for
    /// the pane is cut with `…` in the last cell, which is visibly a cut rather than a shorter
    /// value than the one that arrived.
    ///
    /// Measured in **cells**, not Characters, exactly as the terminal measures: `日` is two columns
    /// wide, so the lead cell is marked `.wide` and the one after it `.wideSpacer` -- the pair the
    /// renderer already understands. Counting Characters instead put ten `日` in a ten-column pane:
    /// every glyph after the first drawn over its neighbour, the cut in the wrong place, and the
    /// row running past the edge. Two indices walk together for that reason: the spans step by
    /// Character, the cells by column.
    ///
    /// A Character that is more than one scalar (a combining accent, a flag, a ZWJ sequence) is
    /// drawn as its first scalar: the grapheme table those belong in is the *terminal's*, and this
    /// runs without one. It costs an accent in a string value and keeps every span pointing at the
    /// glyph it belongs to. A Character of zero width takes no cell at all.
    public func row(_ index: Int, cols: Int, palette: LensPalette) -> Row {
        var row = Row(cols: cols)
        guard cols > 0, let line = line(index) else { return row }

        var total = 0
        for character in line.text { total += LensBuffer.width(of: character) }
        let cut = total > cols
        // One column is the ellipsis'. A glyph that would straddle that boundary is dropped rather
        // than half drawn: half a `日` is a different character.
        let budget = cut ? cols - 1 : cols

        var column = 0
        var offset = 0
        var spanIndex = 0
        for character in line.text {
            // The spans arrive in order and do not overlap, so one cursor over them is enough --
            // a search per character would make a wide pane quadratic in the line's span count.
            while spanIndex < line.spans.count, line.spans[spanIndex].range.upperBound <= offset {
                spanIndex += 1
            }
            let style = spanIndex < line.spans.count && line.spans[spanIndex].range.contains(offset)
                ? line.spans[spanIndex].style
                : nil
            offset += 1

            let width = LensBuffer.width(of: character)
            guard width > 0 else { continue }
            guard column + width <= budget else { break }
            var cell = Cell()
            if let style {
                cell.fg = palette.colour(for: style) ?? .default
                cell.attrs = palette.attributes(for: style)
            }
            cell.content = character.unicodeScalars.first?.value ?? 0
            if width == 2 {
                cell.attrs.insert(.wide)
                row.cells[column] = cell
                // The follower carries the lead's colours for parity with the terminal's own
                // spacers, not because anything draws them: the renderer skips a `.wideSpacer`
                // outright and paints both columns from the lead cell's double-width rect. Code
                // that reads rows rather than drawing them -- selection, transcript, reflow --
                // sees the same shape it sees everywhere else.
                var spacer = cell
                spacer.content = 0
                spacer.attrs.remove(.wide)
                spacer.attrs.insert(.wideSpacer)
                row.cells[column + 1] = spacer
            } else {
                row.cells[column] = cell
            }
            column += width
        }
        if cut {
            var ellipsis = Cell()
            ellipsis.fg = palette.dim
            ellipsis.content = 0x2026
            row.cells[cols - 1] = ellipsis
        }
        return row
    }

    /// A Character's width in cells, through the same table the terminal uses. The single-scalar
    /// case -- which is nearly every character of nearly every line -- answers without building a
    /// `String`, because this runs per character per row per frame.
    private static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        if let only = scalars.first, scalars.index(after: scalars.startIndex) == scalars.endIndex {
            return CharWidth.width(only)
        }
        return CharWidth.width(of: String(character))
    }

    /// Which Character a click at `column` landed on, clamped: the second cell of a wide glyph is
    /// still that glyph, and anything past the end of the line is the end of the line. The mouse
    /// arrives in cells and the text is measured in Characters, so something has to convert.
    public func characterOffset(atColumn column: Int, line index: Int) -> Int {
        guard let text = line(index)?.text else { return 0 }
        guard column > 0 else { return 0 }
        var cells = 0
        for (offset, character) in text.enumerated() {
            let width = LensBuffer.width(of: character)
            if column < cells + max(width, 1) { return offset }
            cells += width
        }
        return text.count
    }

    /// Which column a foldable line's marker is drawn in, or nil when the line is not a fold point.
    ///
    /// §2.4 narrows a lens line's fold target from the whole row to the marker glyph, so that the
    /// text beside it can be dragged across and selected. That needs the marker's column, and the
    /// spec's "column 0" is only true of the headers line and the root bracket: `JSONDocument`
    /// writes the indent and the key first, so `"results": ▸ […] 40 items,` carries its triangle at
    /// column 13. A 20 pt box at column 0 on that row would be a pointing hand over blank indent
    /// and a fold nothing could reach with a mouse.
    ///
    /// A folded container shows a `▸`; an open one shows no triangle at all, and its marker is the
    /// bracket it ends in (`{`, `"users": [`). Hence: the first triangle if there is one, else the
    /// last glyph that is not a space. (A *key* containing a `▸` would win the search over the real
    /// marker. It costs a misplaced 20 pt box on that one line and nothing else, which is cheaper
    /// than a rule that has to parse the line.)
    public func foldMarkerColumn(line index: Int) -> Int? {
        guard let line = line(index), line.node != nil else { return nil }
        let text = line.text
        let marker = text.firstIndex(where: { $0 == "\u{25B8}" || $0 == "\u{25BE}" })
            ?? text.lastIndex(where: { $0 != " " })
        guard let marker else { return nil }
        let offset = text.distance(from: text.startIndex, to: marker)
        return columnRange(ofCharacters: offset ..< (offset + 1), line: index).lowerBound
    }

    /// The cells a run of Characters occupies, for drawing a selection over them.
    public func columnRange(ofCharacters characters: Range<Int>, line index: Int) -> Range<Int> {
        guard let text = line(index)?.text else { return 0 ..< 0 }
        var start = 0
        var width = 0
        for (offset, character) in text.enumerated() {
            let cells = LensBuffer.width(of: character)
            if offset < characters.lowerBound {
                start += cells
            } else if offset < characters.upperBound {
                width += cells
            } else {
                break
            }
        }
        return start ..< (start + width)
    }

    /// The text of a range of lines, for copying. Clamped rather than trapped: a selection outlives
    /// the buffer it was made on, and a re-render between the drag and the ⌘C is ordinary.
    public func text(lines range: Range<Int>) -> String {
        // Both ends clamped and then ordered: a range entirely past the end would otherwise be
        // `5..<3`, which is not an empty range in Swift, it is a trap.
        let lower = min(max(0, range.lowerBound), lines.count)
        let upper = min(max(lower, range.upperBound), lines.count)
        guard lower < upper else { return "" }
        return lines[lower ..< upper].map(\.text).joined(separator: "\n")
    }
}
