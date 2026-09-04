/// A position in the terminal's absolute coordinate space: row 0 is the oldest scrollback line and
/// row `scrollback.count` is the top of the live screen. Using absolute rows rather than viewport
/// rows means a selection survives scrolling and new output without any fix-up.
public struct AbsolutePosition: Equatable, Comparable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public static func < (a: AbsolutePosition, b: AbsolutePosition) -> Bool {
        a.row != b.row ? a.row < b.row : a.col < b.col
    }
}

public enum SelectionMode: Equatable { case character, word, line, block }

/// A selection in progress or completed. `anchor` is where the drag started and `head` where it is
/// now; a backwards drag simply has `head < anchor`, and every query goes through `start`/`end`.
public struct Selection: Equatable {
    public var anchor: AbsolutePosition
    public var head: AbsolutePosition
    public var mode: SelectionMode

    public init(anchor: AbsolutePosition, head: AbsolutePosition, mode: SelectionMode) {
        self.anchor = anchor
        self.head = head
        self.mode = mode
    }

    public var start: AbsolutePosition { min(anchor, head) }
    public var end: AbsolutePosition { max(anchor, head) }

    public var isEmpty: Bool {
        switch mode {
        case .block: return start.row > end.row || min(anchor.col, head.col) >= max(anchor.col, head.col)
        case .line: return false
        case .character, .word: return start == end
        }
    }

    /// Half-open column range selected on absolute row `row`, or nil when the row is outside the
    /// selection. Character and word selections run to the end of every row but the last; block
    /// selections use the same column span on every row; line selections take whole rows.
    public func columnRange(onRow row: Int, cols: Int) -> Range<Int>? {
        guard !isEmpty, row >= start.row, row <= end.row, cols > 0 else { return nil }
        switch mode {
        case .block:
            let lo = min(min(anchor.col, head.col), cols)
            let hi = min(max(anchor.col, head.col), cols)
            return lo < hi ? lo..<hi : nil
        case .line:
            return 0..<cols
        case .character, .word:
            let lo = row == start.row ? min(start.col, cols) : 0
            let hi = row == end.row ? min(end.col, cols) : cols
            return lo < hi ? lo..<hi : nil
        }
    }
}
