extension Terminal {
    /// Total number of absolute rows: every scrollback line plus the live screen.
    public var totalRows: Int { scrollback.count + rows }

    /// Row at an absolute index, or nil when out of range.
    public func absoluteRow(_ row: Int) -> Row? {
        guard row >= 0, row < totalRows else { return nil }
        return row < scrollback.count ? scrollback[row] : screen.rows[row - scrollback.count]
    }

    /// Absolute index of the top visible row. `viewportOffset` counts lines scrolled up from live.
    public var viewportTopRow: Int { scrollback.count - viewportOffset }

    /// Visible text of one row restricted to a column range, skipping the trailing halves of wide
    /// glyphs and rendering empty cells as spaces.
    private func rowText(_ row: Row, _ range: Range<Int>) -> String {
        var out = ""
        for x in range where x < row.cells.count {
            let c = row.cells[x]
            if c.attrs.contains(.wideSpacer) { continue }
            out += c.content == 0 ? " " : clusterText(of: c)
        }
        return out
    }

    /// The text a selection covers.
    ///
    /// Rows joined by a soft wrap produce no newline, so copying a wrapped command line gives back
    /// the command rather than the way it happened to be broken on screen. Block selections take
    /// their columns literally and always break lines, which is the whole point of the mode.
    public func text(in selection: Selection) -> String {
        guard !selection.isEmpty else { return "" }
        let first = max(selection.start.row, 0)
        let last = min(selection.end.row, totalRows - 1)
        guard first <= last else { return "" }

        var out = ""
        for absolute in first...last {
            guard let row = absoluteRow(absolute),
                  let range = selection.columnRange(onRow: absolute, cols: cols) else { continue }
            var piece = rowText(row, range)
            if selection.mode != .block {
                while piece.hasSuffix(" ") { piece.removeLast() }
            }
            out += piece
            guard absolute < last else { continue }
            // A soft wrap continues the same logical line; anything else ends it.
            let joins = selection.mode != .block && row.wrapped && range.upperBound >= cols
            if !joins { out += "\n" }
        }
        return out
    }

    /// Expands a position to the word around it. A position on a separator selects just that
    /// separator, which is what double-clicking a bracket should do; an empty cell selects nothing.
    public func wordRange(at position: AbsolutePosition, separators: Set<Character>) -> Range<Int>? {
        guard let row = absoluteRow(position.row), position.col >= 0, position.col < cols else { return nil }

        func text(_ x: Int) -> String {
            let c = row.cells[x]
            if c.attrs.contains(.wideSpacer), x > 0 { return clusterText(of: row.cells[x - 1]) }
            return c.content == 0 ? "" : clusterText(of: c)
        }
        func isSeparator(_ x: Int) -> Bool {
            guard let ch = text(x).first else { return true }
            return separators.contains(ch)
        }

        let here = text(position.col)
        guard !here.isEmpty else { return nil }
        if let ch = here.first, separators.contains(ch) { return position.col..<(position.col + 1) }

        var lo = position.col
        while lo > 0 && !isSeparator(lo - 1) { lo -= 1 }
        var hi = position.col + 1
        while hi < cols && !isSeparator(hi) { hi += 1 }
        return lo..<hi
    }
}
