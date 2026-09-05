import Foundation

/// How much of a command's output a fold hides.
public enum FoldShape: Equatable {
    /// Everything but the last `keep` rows. The tail is where the error and the summary line are,
    /// which is what a person folding a build actually wants to keep.
    case tail(keep: Int)
    case all
}

/// One row as the viewport should show it.
public enum DisplayRow: Equatable {
    case row(Int)
    /// A folded command's hidden output, standing in for `hiddenRows` rows. Carries the command's
    /// id so clicking it can unfold the right block after the rows underneath have shifted.
    case fold(commandID: UInt32, hiddenRows: Int)
}

/// Which commands' output is collapsed, and how.
///
/// Keyed by `Row.commandID` rather than by prompt row: once the scrollback ring is full every new
/// line shifts every absolute row, and a fold keyed by row would collapse whatever moved into its
/// index -- and vanish from the command it was on. The id stays with the command.
public struct OutputFolding: Equatable {
    private var folds: [UInt32: FoldShape] = [:]
    /// Commands the user unfolded by hand. Automatic folding leaves them alone: a block that
    /// re-collapses after you opened it is the terminal arguing with you.
    private var openedByHand: Set<UInt32> = []

    public init() {}

    public var isEmpty: Bool { folds.isEmpty }

    public func shape(of id: UInt32) -> FoldShape? { folds[id] }
    public func isFolded(_ id: UInt32) -> Bool { folds[id] != nil }

    public mutating func fold(_ id: UInt32, _ shape: FoldShape) {
        guard id != 0 else { return }
        folds[id] = shape
    }

    public mutating func unfold(_ id: UInt32) {
        folds[id] = nil
        openedByHand.insert(id)
    }

    public mutating func unfoldAll() {
        folds.removeAll()
    }

    /// Open ↔ tail. A block already folded fully opens too: the chevron means "show me".
    public mutating func toggle(_ id: UInt32, keep: Int) {
        if folds[id] != nil { unfold(id) } else { fold(id, .tail(keep: keep)) }
    }

    /// Open ↔ all. From a tail fold this tightens rather than opens: ⌥ means "more hidden".
    public mutating func toggleFull(_ id: UInt32) {
        if folds[id] == .all { unfold(id) } else { fold(id, .all) }
    }

    /// Drops folds for commands that have left the buffer, so the set cannot grow over a session.
    public mutating func prune(olderThan oldest: UInt32) {
        folds = folds.filter { $0.key >= oldest }
        openedByHand = openedByHand.filter { $0 >= oldest }
    }

    /// `fold-long-output`: folds `region` if its output is longer than `threshold` rows and the user
    /// has not opened it by hand. Returns whether it folded.
    @discardableResult
    public mutating func autoFold(_ region: CommandRegion, longerThan threshold: Int, keep: Int) -> Bool {
        guard threshold > 0, region.id != 0, region.outputRows.count > threshold,
              !openedByHand.contains(region.id), folds[region.id] == nil else { return false }
        folds[region.id] = .tail(keep: keep)
        return true
    }

    /// "Tidy up the screen": every finished command longer than `threshold` rows, folded.
    public mutating func foldLongOutput(in terminal: Terminal, longerThan threshold: Int, keep: Int) {
        for promptRow in terminal.promptRows {
            guard let region = terminal.command(containingAbsoluteRow: promptRow),
                  region.id != 0, region.outputRows.count > threshold else { continue }
            folds[region.id] = .tail(keep: keep)
        }
    }

    /// A tail that would hide one row behind a one-row placeholder has hidden nothing; below
    /// `keep + 1` rows the fold is a full one.
    public static func effectiveShape(_ shape: FoldShape, outputRows: Int) -> FoldShape {
        guard case .tail(let keep) = shape, keep > 0, outputRows > keep + 1 else { return .all }
        return shape
    }

    /// The absolute rows a fold hides for `region`, after the small-output rule.
    public static func hiddenRange(of region: CommandRegion, shape: FoldShape) -> Range<Int> {
        let output = region.outputRows
        guard !output.isEmpty else { return output.lowerBound..<output.lowerBound }
        switch effectiveShape(shape, outputRows: output.count) {
        case .all: return output
        case .tail(let keep): return output.lowerBound..<(output.upperBound - keep)
        }
    }

    /// What the placeholder row says: the same chevron the command row uses, so the two read as one
    /// control, then the count. Thousands are grouped by hand so the text does not depend on the
    /// machine's locale.
    public static func placeholder(hiddenRows: Int) -> String {
        "\u{25B8} \u{2026} \(grouped(hiddenRows)) \(hiddenRows == 1 ? "line" : "lines") hidden"
    }

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
    /// The folded command whose *hidden* rows cover `row`, and those rows. A prompt row and a kept
    /// tail row are never inside a fold.
    func foldedCommand(containingOutputRow row: Int, folding: OutputFolding)
        -> (region: CommandRegion, hidden: Range<Int>)? {
        guard !folding.isEmpty, shellEmitsPromptMarks,
              let region = command(containingAbsoluteRow: row),
              let shape = folding.shape(of: region.id) else { return nil }
        let hidden = OutputFolding.hiddenRange(of: region, shape: shape)
        return hidden.contains(row) ? (region, hidden) : nil
    }

    /// Exactly what a viewport `count` rows tall shows from absolute row `top`. With nothing folded
    /// it is the plain range and no buffer walk, which is the path every ordinary frame takes.
    func displayRows(from top: Int, count: Int, folding: OutputFolding) -> [DisplayRow] {
        guard count > 0 else { return [] }
        guard !folding.isEmpty else { return (0..<count).map { .row(top + $0) } }

        var out: [DisplayRow] = []
        var row = max(0, top)
        if let (region, hidden) = foldedCommand(containingOutputRow: row, folding: folding) {
            out.append(.fold(commandID: region.id, hiddenRows: hidden.count))
            row = hidden.upperBound
        }
        while out.count < count && row < totalRows {
            out.append(.row(row))
            let line = absoluteRow(row)
            guard let id = line?.commandID, id != 0, let shape = folding.shape(of: id),
                  let region = command(containingAbsoluteRow: row), region.promptRow == row else {
                row += 1
                continue
            }
            let hidden = OutputFolding.hiddenRange(of: region, shape: shape)
            guard !hidden.isEmpty else { row += 1; continue }
            // A wrapped command line lies between the prompt and its output; it belongs to the
            // command, not to what it printed, and stays on screen.
            var next = row + 1
            while next < hidden.lowerBound && out.count < count {
                out.append(.row(next))
                next += 1
            }
            if out.count < count { out.append(.fold(commandID: id, hiddenRows: hidden.count)) }
            row = hidden.upperBound
        }
        return out
    }

    /// The rows to draw for a range of the buffer; used where a fixed count is not wanted.
    func displayRows(in range: Range<Int>, folding: OutputFolding) -> [DisplayRow] {
        guard !folding.isEmpty else { return range.map { .row($0) } }
        return displayRows(from: range.lowerBound, count: range.count, folding: folding)
            .filter { if case .row(let r) = $0 { return range.contains(r) } else { return true } }
    }

    /// Moves the viewport off hidden rows in the direction the user was scrolling, so a fold of two
    /// thousand rows is not two thousand wheel clicks. Returns whether it moved.
    @discardableResult
    func snapViewportOutOfFold(movingUp: Bool, folding: OutputFolding) -> Bool {
        guard let (region, hidden) = foldedCommand(containingOutputRow: viewportTopRow, folding: folding)
        else { return false }
        return scrollToAbsoluteRow(movingUp ? region.promptRow : hidden.upperBound, margin: 0)
    }

    /// The placeholder as a row of cells, so it is drawn through the ordinary row path and nothing
    /// in NyxRender learns what a fold is. Dim and italic in the theme's own bright black: a note
    /// about the buffer, not something a program printed.
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
    /// Absolute row → screen row. Hidden rows are absent, so a highlight on hidden text is drawn
    /// nowhere rather than on whatever now sits at that index.
    public static func indexByAbsoluteRow(_ rows: [DisplayRow]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        map.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard case .row(let absolute) = row else { continue }
            map[absolute] = index
        }
        return map
    }

    /// The display slots that belong to one block: every `.row` slot whose absolute row, relative
    /// to `viewportTop`, falls in `visibleRows`, plus the block's own fold placeholder -- it stands
    /// for the block's hidden output, so hovering or spining it should cover that slot too. `nil`
    /// when none of the block survived onto the display.
    ///
    /// `visibleRows` can span everything a tail fold hides once the caller has widened its window
    /// to the block's own region (`Terminal.visibleBlocks(from:through:)` does this because a
    /// block's region spans hidden rows even though its drawn footprint does not). Looking up each
    /// of those rows individually against `display` -- a linear search per row -- turns a viewport
    /// walk into work proportional to the hidden row count. Walking `display` once instead, as this
    /// does, costs the viewport's height regardless of how much is folded underneath it. Both
    /// `BlockHover.placed` and the spine in `Pane` share this rather than each re-deriving it.
    public static func slots(coveredBy visibleRows: Range<Int>, commandID: UInt32, in display: [DisplayRow],
                              viewportTop: Int) -> Range<Int>? {
        var first: Int?
        var last: Int?
        for (slot, entry) in display.enumerated() {
            switch entry {
            case .row(let absolute):
                guard visibleRows.contains(absolute - viewportTop) else { continue }
            case .fold(let id, _):
                guard id == commandID else { continue }
            }
            if first == nil { first = slot }
            last = slot
        }
        guard let first, let last else { return nil }
        return first..<(last + 1)
    }
}
