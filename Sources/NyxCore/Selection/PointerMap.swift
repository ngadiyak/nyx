/// Pointer-to-cell arithmetic, kept out of the view so it can be tested without AppKit.
///
/// Both entry points take a point measured in points from the **top-left** of the terminal view,
/// including its padding. A view whose own coordinate space has its origin at the bottom does the
/// flip before calling; nothing here knows about AppKit's conventions.
public enum PointerMap {
    /// The absolute cell a point falls on, for selection.
    ///
    /// The column clamp is inclusive of `cols`: dragging past the right edge has to be able to say
    /// "to the end of the line", and a column of `cols` is exactly that. `Selection.columnRange`
    /// clamps it back to the grid when the time comes to paint or copy.
    public static func position(x: Double, y: Double, cellWidth: Double, cellHeight: Double,
                                padding: Double, viewportTop: Int, cols: Int, totalRows: Int) -> AbsolutePosition {
        let col = clamp(floorDiv(x - padding, cellWidth), 0, cols)
        let row = floorDiv(y - padding, cellHeight)
        return AbsolutePosition(row: clamp(viewportTop + row, 0, max(0, totalRows - 1)), col: col)
    }

    /// The viewport-relative cell a point falls on, for mouse reporting. Clamped strictly inside the
    /// grid: the protocol has no way to say "past the last column", and an out-of-range coordinate
    /// would be worse than the nearest real one.
    public static func reportCell(x: Double, y: Double, cellWidth: Double, cellHeight: Double,
                                  padding: Double, cols: Int, rows: Int) -> (col: Int, row: Int) {
        (clamp(floorDiv(x - padding, cellWidth), 0, cols - 1),
         clamp(floorDiv(y - padding, cellHeight), 0, rows - 1))
    }

    /// Floors towards minus infinity, so a point in the padding above the first row lands on row -1
    /// rather than rounding up into row 0 and hiding a drag that left the top of the view.
    private static func floorDiv(_ a: Double, _ b: Double) -> Int {
        guard b > 0 else { return 0 }
        return Int((a / b).rounded(.down))
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
