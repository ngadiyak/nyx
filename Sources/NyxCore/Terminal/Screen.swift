public struct Cursor: Equatable {
    public var x = 0
    public var y = 0
    public init(x: Int = 0, y: Int = 0) { self.x = x; self.y = y }
}

/// A grid of rows with a cursor, scroll margins and tab stops. The terminal owns two: primary and alternate.
public struct Screen {
    public var rows: [Row]
    public var cursor = Cursor()
    /// Set after printing in the last column; the next printable character wraps first (DECAWM).
    public var pendingWrap = false
    public var scrollTop = 0
    public var scrollBottom: Int
    public var tabStops: [Bool]

    public init(cols: Int, rows count: Int) {
        rows = Array(repeating: Row(cols: cols), count: count)
        scrollBottom = count - 1
        tabStops = Screen.defaultTabStops(cols: cols)
    }

    public static func defaultTabStops(cols: Int) -> [Bool] {
        (0..<cols).map { $0 % 8 == 0 }
    }
}
