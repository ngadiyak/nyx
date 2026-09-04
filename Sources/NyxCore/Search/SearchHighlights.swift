import Foundation

/// Turning absolute search matches into the per-visible-row column ranges a renderer paints.
///
/// The renderer knows nothing about scrollback: it is handed one array per frame, indexed by
/// visible row, exactly the way the selection reaches it. Keeping the conversion here rather than
/// in the view is what makes "a match two screens up is not drawn" and "a match clipped by the
/// right edge is clipped, not dropped" testable without a Metal device.
public enum SearchHighlights {
    /// Every match that falls inside the viewport, as column ranges per visible row.
    ///
    /// The result always has `rows` entries, so the renderer can index it by visible row without
    /// checking. Ranges are clamped to `0..<cols`; a match entirely off the grid is dropped.
    public static func visibleRanges(_ matches: [SearchMatch], viewportTop: Int, rows: Int,
                                     cols: Int) -> [[Range<Int>]] {
        var result = [[Range<Int>]](repeating: [], count: max(0, rows))
        guard rows > 0, cols > 0 else { return result }
        for match in matches {
            let row = match.row - viewportTop
            guard row >= 0, row < rows, let columns = clamp(match.columns, cols: cols) else { continue }
            result[row].append(columns)
        }
        return result
    }

    /// The current match on its own, so the renderer can paint it differently from the rest. One
    /// optional range per visible row, for the same indexing reason as `visibleRanges`.
    public static func visibleRange(of match: SearchMatch?, viewportTop: Int, rows: Int,
                                    cols: Int) -> [Range<Int>?] {
        guard let match else { return visibleRange(onAbsoluteRow: 0, columns: nil, viewportTop: viewportTop,
                                                   rows: rows, cols: cols) }
        return visibleRange(onAbsoluteRow: match.row, columns: match.columns, viewportTop: viewportTop,
                            rows: rows, cols: cols)
    }

    /// The same conversion for any single run on one absolute row -- the link under the pointer,
    /// which is a token rather than a match but is drawn by the same per-visible-row array.
    public static func visibleRange(onAbsoluteRow absoluteRow: Int, columns: Range<Int>?,
                                    viewportTop: Int, rows: Int, cols: Int) -> [Range<Int>?] {
        var result = [Range<Int>?](repeating: nil, count: max(0, rows))
        guard rows > 0, cols > 0, let columns else { return result }
        let row = absoluteRow - viewportTop
        guard row >= 0, row < rows, let clamped = clamp(columns, cols: cols) else { return result }
        result[row] = clamped
        return result
    }

    private static func clamp(_ columns: Range<Int>, cols: Int) -> Range<Int>? {
        let lower = max(0, columns.lowerBound)
        let upper = min(cols, columns.upperBound)
        return lower < upper ? lower..<upper : nil
    }
}
