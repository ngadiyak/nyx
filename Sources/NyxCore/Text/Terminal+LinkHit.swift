import Foundation

/// One row's share of something on screen: which absolute row, and which columns of it.
public struct RowSpan: Equatable {
    public let row: Int
    public let columns: Range<Int>

    public init(row: Int, columns: Range<Int>) {
        self.row = row
        self.columns = columns
    }
}

/// A link under the pointer: what it is, and every row it is drawn on.
///
/// `spans` rather than one column range, because a link is a property of a *logical* line and the
/// terminal draws a logical line over as many rows as it takes. Hover underlines each span and a
/// click on any of them opens the same thing -- which is the difference between reading a URL on
/// screen and opening the page it names.
public struct LinkHit: Equatable {
    public let text: String
    public let kind: TokenKind
    public let spans: [RowSpan]

    public init(text: String, kind: TokenKind, spans: [RowSpan]) {
        self.text = text
        self.kind = kind
        self.spans = spans
    }

    /// The hit as a `TextToken`, for `LinkResolver`. The columns are the first span's: a resolver
    /// asks what the text is and where it starts, and neither answer changes across a wrap.
    public var token: TextToken {
        TextToken(columns: spans.first?.columns ?? 0..<0, text: text, kind: kind)
    }
}

public extension Terminal {
    /// The link at a position, or nil when there is nothing openable there.
    ///
    /// Separate from `token(atAbsoluteRow:column:separators:)`, which a double-click uses: that one
    /// answers "what is the word here", in one row's coordinates, and a selection has to stay
    /// inside the row it was made on. This one answers "what would ⌘-click open", which is a
    /// question about the logical line and can be a run the program named rather than any text on
    /// screen at all.
    func linkHit(atAbsoluteRow row: Int, column: Int, separators: Set<Character>) -> LinkHit? {
        // OSC 8 first: the URI is what the program said the label means, and no pattern over the
        // label's text can recover it. `docs/status.md` has advertised this since the model half
        // was built; nothing on the click path read `Cell.hyperlink` until now.
        if let run = hyperlinkHit(atAbsoluteRow: row, column: column) { return run }

        let (rows, cappedAbove, cappedBelow) = logicalRows(containingAbsoluteRow: row)
        guard rows.contains(row) else { return nil }
        // One text and one column axis over all the rows of the logical line. The axis is the row
        // index times the width, which is monotonic because a wrapped row is full to its last
        // column by definition -- so a token's flat column range divides cleanly back into spans.
        var text = ""
        var columnOf: [Int] = []
        for r in rows {
            let line = rowText(absoluteRow: r)
            let base = (r - rows.lowerBound) * cols
            text += line.text
            columnOf.append(contentsOf: line.columnOf.map { $0 + base })
        }
        let flat = (row - rows.lowerBound) * cols + column
        guard let token = TextPatterns.selectionToken(at: flat, in: text, separators: separators,
                                                      columnOf: columnOf) else { return nil }
        // A join stopped by the cap rather than by the end of the line may have cut the link's
        // head or tail off, and half a URL is a valid URL for a different page -- the exact way
        // this failed before. No link is better than the wrong site.
        if cappedAbove, token.columns.lowerBound == 0 { return nil }
        if cappedBelow, token.columns.upperBound >= rows.count * cols { return nil }
        return LinkHit(text: token.text, kind: token.kind,
                       spans: spans(ofFlatColumns: token.columns, from: rows.lowerBound))
    }

    /// The rows one logical line occupies around a row, and whether either end was reached by the
    /// cap rather than by an unwrapped row.
    ///
    /// Bounded because hover runs this on every cell the pointer crosses, and a paragraph of soft
    /// wrapped prose is one logical line however long it is: joining thousands of rows to answer
    /// "is there a link here" would make moving the mouse cost the height of the buffer. Sixteen
    /// rows either way is over 2,500 characters at 80 columns, longer than any URL a person reads.
    func logicalRows(containingAbsoluteRow row: Int) -> (rows: Range<Int>, cappedAbove: Bool,
                                                         cappedBelow: Bool) {
        let cap = 16
        guard absoluteRow(row) != nil else { return (row..<row, false, false) }
        var first = row
        var cappedAbove = false
        while absoluteRow(first - 1)?.wrapped == true {
            if row - first >= cap { cappedAbove = true; break }
            first -= 1
        }
        var last = row
        var cappedBelow = false
        while absoluteRow(last)?.wrapped == true, absoluteRow(last + 1) != nil {
            if last - row >= cap { cappedBelow = true; break }
            last += 1
        }
        return (first..<(last + 1), cappedAbove, cappedBelow)
    }

    /// The OSC 8 run under a column, as the URI the program named.
    ///
    /// The run is every adjacent cell carrying the same interned index, across a soft wrap as well:
    /// a hyperlink's label wraps like any other text, and the URI does not depend on where it
    /// broke.
    private func hyperlinkHit(atAbsoluteRow row: Int, column: Int) -> LinkHit? {
        guard cols > 0, let cells = absoluteRow(row)?.cells,
              cells.indices.contains(column) else { return nil }
        let link = cells[column].hyperlink
        guard link != 0, Int(link) <= hyperlinks.count else { return nil }
        let (rows, _, _) = logicalRows(containingAbsoluteRow: row)
        // The same flat column axis the text path uses, so a run whose label wrapped joins the
        // same way. Only the run the pointer is *in*: two hyperlinks with the same URI separated
        // by plain text are two links, and underlining both would claim the text between them.
        func hyperlink(atFlat flat: Int) -> UInt16? {
            guard flat >= 0 else { return nil }
            let r = rows.lowerBound + flat / cols
            guard rows.contains(r), let cells = absoluteRow(r)?.cells,
                  cells.indices.contains(flat % cols) else { return nil }
            return cells[flat % cols].hyperlink
        }
        let start = (row - rows.lowerBound) * cols + column
        var lower = start
        while hyperlink(atFlat: lower - 1) == link { lower -= 1 }
        var upper = start + 1
        while hyperlink(atFlat: upper) == link { upper += 1 }
        return LinkHit(text: hyperlinks[Int(link) - 1], kind: .url,
                       spans: spans(ofFlatColumns: lower..<upper, from: rows.lowerBound))
    }

    /// A flat column range, back into one span per row.
    private func spans(ofFlatColumns flat: Range<Int>, from firstRow: Int) -> [RowSpan] {
        guard cols > 0 else { return [] }
        var result: [RowSpan] = []
        var index = flat.lowerBound / cols
        while index * cols < flat.upperBound {
            let lower = max(flat.lowerBound, index * cols) - index * cols
            let upper = min(flat.upperBound, (index + 1) * cols) - index * cols
            if lower < upper { result.append(RowSpan(row: firstRow + index, columns: lower..<upper)) }
            index += 1
        }
        return result
    }
}
