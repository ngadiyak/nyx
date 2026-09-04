import Foundation

/// A row's text together with the column each character starts at.
///
/// The two travel together because they are useless apart. A wide glyph is one character in two
/// cells, so a character offset and a terminal column stop agreeing at the first CJK character or
/// emoji on the line -- and everything downstream, a link's hit area or a search match's highlight,
/// is drawn in columns.
public struct RowText: Equatable {
    public let text: String
    /// `columnOf[i]` is the column where the i-th character of `text` begins.
    public let columnOf: [Int]

    public init(text: String, columnOf: [Int]) {
        self.text = text
        self.columnOf = columnOf
    }

    public static let empty = RowText(text: "", columnOf: [])

    /// The column range a character range occupies, clamped to the row.
    public func columns(for characters: Range<Int>) -> Range<Int> {
        guard !columnOf.isEmpty else { return characters }
        let lower = characters.lowerBound < columnOf.count
            ? columnOf[characters.lowerBound] : columnOf[columnOf.count - 1] + 1
        let upper = characters.upperBound < columnOf.count
            ? columnOf[characters.upperBound] : columnOf[columnOf.count - 1] + 1
        return lower..<max(lower + 1, upper)
    }
}

public extension Terminal {
    /// The text of an absolute row, with its column mapping. Trailing blanks are kept as spaces so
    /// a column stays a column; callers that want them gone can trim the text themselves.
    func rowText(absoluteRow row: Int) -> RowText {
        guard let r = absoluteRow(row) else { return .empty }
        var text = ""
        var columnOf: [Int] = []
        for (column, cell) in r.cells.enumerated() {
            // The second cell of a wide glyph is not a character of its own.
            if cell.attrs.contains(.wideSpacer) { continue }
            let piece = cell.content == 0 ? " " : clusterText(of: cell)
            guard !piece.isEmpty else { continue }
            // A grapheme cluster is one character here, matching how the renderer draws it.
            columnOf.append(contentsOf: Array(repeating: column, count: piece.count))
            text += piece
        }
        return RowText(text: text, columnOf: columnOf)
    }

    /// Every structured token on an absolute row -- what is clickable there.
    func tokens(onAbsoluteRow row: Int) -> [TextToken] {
        let line = rowText(absoluteRow: row)
        return TextPatterns.tokens(in: line.text, columnOf: line.columnOf)
    }

    /// The token at a position, structured if there is one and the plain word otherwise. This is
    /// what a double-click selects and what a ⌘-click opens.
    func token(atAbsoluteRow row: Int, column: Int, separators: Set<Character>) -> TextToken? {
        let line = rowText(absoluteRow: row)
        return TextPatterns.selectionToken(at: column, in: line.text, separators: separators,
                                           columnOf: line.columnOf)
    }
}
