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
