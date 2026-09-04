import Foundation

/// One row as the viewport should show it.
public enum DisplayRow: Equatable {
    /// An ordinary row of the buffer, by absolute index.
    case row(Int)
    /// A folded command's output, standing in for `hiddenRows` rows. Carries the command's own
    /// prompt row so the placeholder can name what was folded, and so clicking it can unfold.
    case fold(promptRow: Int, hiddenRows: Int)
}

/// Which commands' output is collapsed.
///
/// One `cat` of a large file pushes everything useful out of the scrollback and leaves you
/// scrolling through thousands of lines you did not want. Folding it to a single line keeps the
/// history readable and makes the buffer limit go further, without losing anything -- unfolding
/// puts it back, because nothing was thrown away.
///
/// Folds are keyed by the command's prompt row, which is stable in absolute coordinates for as long
/// as the row lives; when it scrolls out of the buffer the fold goes with it.
public struct OutputFolding: Equatable {
    private var folded: Set<Int>

    public init(_ folded: Set<Int> = []) {
        self.folded = folded
    }

    public var isEmpty: Bool { folded.isEmpty }

    public func isFolded(promptRow: Int) -> Bool { folded.contains(promptRow) }

    public mutating func fold(promptRow: Int) { folded.insert(promptRow) }
    public mutating func unfold(promptRow: Int) { folded.remove(promptRow) }
    public mutating func unfoldAll() { folded.removeAll() }

    public mutating func toggle(promptRow: Int) {
        if folded.contains(promptRow) { folded.remove(promptRow) } else { folded.insert(promptRow) }
    }

    /// Folds every command that produced more than `threshold` rows of output.
    ///
    /// This is "tidy up the screen": after a long session most of what is on screen is output you
    /// have already read, and one action to collapse it is worth more than folding each by hand.
    public mutating func foldLongOutput(in terminal: Terminal, longerThan threshold: Int) {
        for promptRow in terminal.promptRows {
            guard let region = terminal.command(containingAbsoluteRow: promptRow) else { continue }
            if region.outputRows.count > threshold { folded.insert(promptRow) }
        }
    }

    /// Drops folds for commands that have scrolled out of the buffer, so the set cannot grow
    /// without bound over a long session.
    public mutating func prune(below firstRow: Int) {
        folded = folded.filter { $0 >= firstRow }
    }

    /// Drops folds whose prompt row is no longer a prompt row.
    ///
    /// A fold is an absolute row index, and absolute indices are only stable while the buffer is
    /// only ever appended to. Once the scrollback ring is full every eviction shifts them all down
    /// by one, so a fold would follow the index rather than the command -- and collapse whatever
    /// text moved into its place. Checking that the row still carries a prompt mark is the cheap
    /// version of noticing: a shifted fold almost never lands on another prompt, and the one that
    /// does is a fold on a neighbouring command rather than on the middle of somebody's output.
    ///
    /// Costs one row read per fold, and is not called at all when there are none.
    public mutating func prune(in terminal: Terminal) {
        folded = folded.filter { terminal.promptMarks(atAbsoluteRow: $0).contains(.promptStart) }
    }
}

public extension Terminal {
    /// The rows to draw for a range of the buffer, with folded output replaced by a placeholder.
    ///
    /// Returns absolute rows when nothing is folded, so the renderer's ordinary path is unchanged
    /// and costs nothing extra for the overwhelmingly common case.
    func displayRows(in range: Range<Int>, folding: OutputFolding) -> [DisplayRow] {
        guard !folding.isEmpty else { return range.map { .row($0) } }

        var out: [DisplayRow] = []
        var row = range.lowerBound
        while row < range.upperBound {
            // A fold is anchored on its prompt row: the prompt itself stays visible -- the point is
            // to hide the output, not the command that produced it.
            guard folding.isFolded(promptRow: row),
                  let region = command(containingAbsoluteRow: row),
                  region.promptRow == row,
                  !region.outputRows.isEmpty else {
                out.append(.row(row))
                row += 1
                continue
            }
            out.append(.row(row))
            let hidden = region.outputRows.clamped(to: row..<range.upperBound)
            if !hidden.isEmpty {
                out.append(.fold(promptRow: row, hiddenRows: region.outputRows.count))
            }
            // Skip the output, and any rows of the command between the prompt and its output --
            // a wrapped command line, for instance.
            row = max(row + 1, region.outputRows.upperBound)
        }
        return out
    }

    /// How many rows a range collapses to, for deciding how much of the buffer the viewport covers.
    func displayRowCount(in range: Range<Int>, folding: OutputFolding) -> Int {
        folding.isEmpty ? range.count : displayRows(in: range, folding: folding).count
    }
}

public extension OutputFolding {
    /// What the placeholder row says. Written here so the wording, the grouping and the plural are
    /// one testable rule rather than three guesses in a view.
    static func placeholder(hiddenRows: Int) -> String {
        "\u{2026} \(grouped(hiddenRows)) \(hiddenRows == 1 ? "line" : "lines") hidden"
    }

    /// Thousands separated, without asking `NumberFormatter` -- which would make the text depend on
    /// the user's locale and the test on the machine it runs on. A row count is not a currency.
    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var out = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return number < 0 ? "-" + out : out
    }
}

public extension Terminal {
    /// The folded command whose *output* covers `row`, or nil. A prompt row is never inside its own
    /// fold: folding hides what a command printed, not the command.
    func foldedCommand(containingOutputRow row: Int, folding: OutputFolding) -> CommandRegion? {
        guard !folding.isEmpty, shellEmitsPromptMarks,
              let region = command(containingAbsoluteRow: row),
              folding.isFolded(promptRow: region.promptRow),
              region.outputRows.contains(row) else { return nil }
        return region
    }

    /// Exactly what a viewport `count` rows tall shows, starting at absolute row `top`.
    ///
    /// The renderer needs a fixed number of rows, which `displayRows(in:folding:)` cannot give it:
    /// collapsing a range returns fewer rows than it was asked about, and the viewport would come
    /// up short by however much was folded. This walks forward until it has filled the screen.
    ///
    /// With nothing folded it is `(top..<top+count).map(DisplayRow.row)` and no buffer walk at all,
    /// which is the path every frame of every ordinary session takes.
    func displayRows(from top: Int, count: Int, folding: OutputFolding) -> [DisplayRow] {
        guard count > 0 else { return [] }
        guard !folding.isEmpty else { return (0..<count).map { .row(top + $0) } }

        var out: [DisplayRow] = []
        var row = max(0, top)

        // A viewport that starts in the middle of folded output starts on the placeholder instead:
        // those rows are precisely the ones the fold stands in for.
        if let region = foldedCommand(containingOutputRow: row, folding: folding) {
            out.append(.fold(promptRow: region.promptRow, hiddenRows: region.outputRows.count))
            row = region.outputRows.upperBound
        }

        while out.count < count && row < totalRows {
            out.append(.row(row))
            guard folding.isFolded(promptRow: row),
                  let region = command(containingAbsoluteRow: row),
                  region.promptRow == row,
                  !region.outputRows.isEmpty else {
                row += 1
                continue
            }
            if out.count < count {
                out.append(.fold(promptRow: row, hiddenRows: region.outputRows.count))
            }
            // Past the output, and past any row between the prompt and it -- a wrapped command
            // line belongs to the command, not to what it printed.
            row = max(row + 1, region.outputRows.upperBound)
        }
        return out
    }

    /// Moves the viewport off the middle of a folded command's output, in the direction the user
    /// was already scrolling.
    ///
    /// Without this, scrolling into a fold of two thousand rows means two thousand more wheel
    /// clicks to get out of it: the viewport top is an absolute row, and every one of those rows is
    /// hidden, so the screen would not change. Returns whether it moved.
    @discardableResult
    func snapViewportOutOfFold(movingUp: Bool, folding: OutputFolding) -> Bool {
        guard !folding.isEmpty,
              let region = foldedCommand(containingOutputRow: viewportTopRow, folding: folding)
        else { return false }
        // Up lands on the command that produced the output; down lands past it.
        return scrollToAbsoluteRow(movingUp ? region.promptRow : region.outputRows.upperBound,
                                   margin: 0)
    }
}

public extension Terminal {
    /// The placeholder as a row of cells, so the renderer draws it through exactly the same path as
    /// every other row and nothing in `NyxRender` has to learn what a fold is.
    ///
    /// Dim and italic in the theme's own bright black: it has to read as a note about the buffer
    /// rather than as something a program printed, and it must do that in any theme -- which rules
    /// out naming a colour.
    func foldPlaceholderRow(hiddenRows: Int) -> Row {
        var row = Row(cols: cols)
        var cell = Cell()
        cell.fg = .indexed(8)
        cell.attrs = [.dim, .italic]
        for (column, scalar) in OutputFolding.placeholder(hiddenRows: hiddenRows).unicodeScalars.enumerated() {
            guard column < cols else { break }
            cell.content = scalar.value
            row.cells[column] = cell
        }
        return row
    }
}

/// Where the rows of a folded viewport ended up.
public enum DisplayRows {
    /// Absolute row to the screen row it is drawn on. Rows hidden inside a fold are absent, which
    /// is what makes a highlight on folded text disappear with the text rather than being painted
    /// onto whatever row happens to sit at that index now.
    public static func indexByAbsoluteRow(_ rows: [DisplayRow]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        map.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard case .row(let absolute) = row else { continue }
            map[absolute] = index
        }
        return map
    }
}
