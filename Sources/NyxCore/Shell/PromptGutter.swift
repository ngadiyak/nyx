import Foundation

/// What the gutter draws beside a prompt row.
public enum GutterMark: Equatable {
    /// The command has not reported a status yet. Nothing is drawn: a mark that appeared the
    /// instant you pressed return and then changed colour would be a progress indicator, and the
    /// gutter is a record of what happened, not a spinner.
    case running
    case succeeded
    case failed
}

/// The geometry of the status gutter, and the marks to put in it.
///
/// The gutter lives inside the pane's own left padding, so it costs no terminal columns and never
/// overlaps a glyph. That makes its width a function of the padding setting, which is the sort of
/// rule that is quietly wrong in a view until someone sets `padding = 0` -- so it is here.
public enum PromptGutter {
    /// As wide as a mark needs and no wider; the rest of the padding stays padding.
    public static let maximumWidth: Double = 6
    /// Below this there is not enough room to draw a mark without it touching the text.
    public static let minimumPadding: Double = 4

    public static func width(padding: Double) -> Double {
        padding >= minimumPadding ? min(padding, maximumWidth) : 0
    }

    /// The visible row a point falls on, measured from the top of the pane including its padding.
    /// nil for a point in the padding above the first row or below the last.
    public static func row(atY y: Double, cellHeight: Double, padding: Double, rows: Int) -> Int? {
        guard cellHeight > 0, rows > 0 else { return nil }
        let row = Int(((y - padding) / cellHeight).rounded(.down))
        return row >= 0 && row < rows ? row : nil
    }
}

public extension Terminal {
    /// A mark per visible row: what happened to the command whose prompt is on that row, and
    /// nothing at all for a row that carries no prompt.
    ///
    /// One pass over the buffer starting at the top of the viewport, rather than
    /// `command(containingAbsoluteRow:)` per row, which would rescan the scrollback once for every
    /// line on screen. It reads past the bottom of the screen only far enough to find the status of
    /// a prompt sitting on the last visible row.
    func gutterMarks(rows visibleRows: Int) -> [GutterMark?] {
        var marks = [GutterMark?](repeating: nil, count: max(0, visibleRows))
        guard visibleRows > 0 else { return marks }
        let top = viewportTopRow
        let end = totalRows
        // The prompt whose status has not been seen yet: where it is, and where its mark goes.
        var pendingRow: Int?
        var pendingIndex: Int?
        var row = max(0, top)

        while row < end {
            let flags = promptMarks(atAbsoluteRow: row)
            // A `D` on our own prompt row closes whatever ran *before* it, which is why this is
            // strictly after the pending prompt -- the same ownership rule `command(containing:)`
            // follows, and the reason a fresh prompt does not inherit its predecessor's failure.
            if flags.contains(.commandDone), let index = pendingIndex, let pending = pendingRow, pending < row {
                marks[index] = (exitStatus(atAbsoluteRow: row) ?? 0) == 0 ? .succeeded : .failed
                pendingRow = nil
                pendingIndex = nil
            }
            if flags.contains(.promptStart) {
                let index = row - top
                guard index < visibleRows else { break }   // past the screen; nothing more to draw
                marks[index] = .running
                pendingRow = row
                pendingIndex = index
            }
            row += 1
            // Everything on screen is drawn and nothing is waiting on a status further down.
            if row >= top + visibleRows && pendingIndex == nil { break }
        }
        return marks
    }
}
