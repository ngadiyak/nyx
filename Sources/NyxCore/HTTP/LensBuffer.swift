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
/// the terminal, so the same buffer can be built off the main thread, kept while a newer one is
/// built, and compared for staleness by `contentVersion` alone.
public struct LensBuffer: Equatable {
    public let commandID: UInt32
    public let lens: ResponseLens
    public let lines: [LensLine]
    /// The terminal's `contentVersion` when these lines were built. A buffer whose version differs
    /// from the terminal's is stale -- built before the last thing the command printed -- and is
    /// still drawn: a response one line out of date is a better frame than an empty one, and the
    /// pane replaces it as soon as the new one is ready.
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
    /// A Character that is more than one scalar (a combining accent, a flag, a ZWJ sequence) is
    /// drawn as its first scalar: the grapheme table those belong in is the *terminal's*, and this
    /// runs without one. It costs an accent in a string value and keeps every span offset -- which
    /// are Character offsets -- pointing at the cell the reader sees.
    public func row(_ index: Int, cols: Int, palette: LensPalette) -> Row {
        var row = Row(cols: cols)
        guard cols > 0, let line = line(index) else { return row }
        let characters = Array(line.text)
        let cut = characters.count > cols
        let drawn = cut ? cols - 1 : characters.count

        var spanIndex = 0
        var cell = Cell()
        for column in 0 ..< drawn {
            // The spans arrive in order and do not overlap, so one cursor over them is enough --
            // a search per column would make a wide pane quadratic in the line's span count.
            while spanIndex < line.spans.count, line.spans[spanIndex].range.upperBound <= column {
                spanIndex += 1
            }
            cell.fg = .default
            cell.attrs = []
            if spanIndex < line.spans.count, line.spans[spanIndex].range.contains(column) {
                let style = line.spans[spanIndex].style
                cell.fg = palette.colour(for: style) ?? .default
                cell.attrs = palette.attributes(for: style)
            }
            cell.content = characters[column].unicodeScalars.first?.value ?? 0
            row.cells[column] = cell
        }
        if cut {
            var ellipsis = Cell()
            ellipsis.fg = palette.dim
            ellipsis.content = 0x2026
            row.cells[cols - 1] = ellipsis
        }
        return row
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
