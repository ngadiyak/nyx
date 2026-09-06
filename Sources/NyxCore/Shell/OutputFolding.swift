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
    /// id so clicking it can unfold the right block after the rows underneath have shifted, and its
    /// status -- the placeholder is drawn in the block's own colour, and the region is in hand here,
    /// where the entry is built, rather than on the render path.
    case fold(commandID: UInt32, hiddenRows: Int, status: BlockStatus)
    /// One line of a command's response, shown through a lens in place of the rows it was read
    /// from. Carries the command's id for the same reason `fold` does -- the rows underneath shift
    /// -- and the line's index into that command's `LensBuffer` rather than the line itself, so a
    /// display is a small value that does not copy a two-megabyte rendering per frame.
    case lens(commandID: UInt32, line: Int)
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
    ///
    /// `hasOutput` is `Terminal.commandHasOutput(atAbsoluteRow:)` -- the same rule the chevron, the
    /// gutter mark and ⌘⇧↑ use. `region.outputRows.count` alone is the row *span*, and a command
    /// that has started and printed nothing owns every blank row below it: at a 20-row threshold
    /// that made a fresh `sleep 10` in a tall pane "long output" and folded it into a placeholder
    /// standing for nothing.
    @discardableResult
    public mutating func autoFold(_ region: CommandRegion, longerThan threshold: Int, keep: Int,
                                  hasOutput: Bool) -> Bool {
        guard hasOutput, threshold > 0, region.id != 0, region.outputRows.count > threshold,
              !openedByHand.contains(region.id), folds[region.id] == nil else { return false }
        folds[region.id] = .tail(keep: keep)
        return true
    }

    /// "Tidy up the screen": every command with more than `threshold` rows of real output, folded.
    ///
    /// The `commandHasOutput` guard is the same one `autoFold` takes as a parameter, for the same
    /// reason: without it this folded a running command's blank screen into "… 38 lines hidden"
    /// while that command's own chevron was, correctly, not being drawn at all.
    public mutating func foldLongOutput(in terminal: Terminal, longerThan threshold: Int, keep: Int) {
        for promptRow in terminal.promptRows {
            guard let region = terminal.command(containingAbsoluteRow: promptRow),
                  region.id != 0, region.outputRows.count > threshold,
                  terminal.commandHasOutput(atAbsoluteRow: promptRow) else { continue }
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

    /// The lensed command whose *output* rows cover `row`, and the lines to show instead. A prompt
    /// row is never inside a lens: the command line stays on screen above its response.
    ///
    /// nil when the command has no lens, when its buffer has not been built yet (the rows show raw
    /// until it is), when that buffer has no lines -- taking the output off the screen and putting
    /// nothing in its place reads as a command that printed nothing -- or when the command has
    /// printed nothing for a lens to replace.
    func lensedCommand(containingOutputRow row: Int, lenses: LensChoices,
                       buffers: (UInt32) -> LensBuffer?) -> (region: CommandRegion, buffer: LensBuffer)? {
        guard !lenses.isEmpty, shellEmitsPromptMarks,
              let region = command(containingAbsoluteRow: row),
              lenses.lens(of: region.id) != nil,
              region.outputRows.contains(row),
              let buffer = buffers(region.id), buffer.lineCount > 0 else { return nil }
        return (region, buffer)
    }

    /// Exactly what a viewport `count` rows tall shows from `cursor`. With nothing folded and
    /// nothing lensed it is the plain range and no buffer walk, which is the path every ordinary
    /// frame takes.
    ///
    /// A lensed block's output rows are replaced by its buffer's lines: the prompt and the command
    /// line stay, then every line of the lens, then the row after the block. **A lens is not the
    /// same height as what it replaces**, which is why the viewport is addressed by `DisplayCursor`
    /// rather than by an absolute row -- see that type for what addressing it by row cost.
    ///
    /// One walk for every case, `displayEntry` per display line. The earlier version replaced a
    /// block's output only where the walk passed its *prompt* row, which left a hole one row wide:
    /// a viewport whose top was a wrapped continuation of the command line showed the whole block
    /// raw, fold and lens alike. Entering a block at any of its rows is the same question now, so
    /// the hole is gone by construction.
    func displayRows(from cursor: DisplayCursor, count: Int, folding: OutputFolding,
                     lenses: LensChoices = LensChoices(),
                     buffers: (UInt32) -> LensBuffer? = { _ in nil }) -> [DisplayRow] {
        guard count > 0 else { return [] }
        guard !folding.isEmpty || !lenses.isEmpty else {
            return (0..<count).map { .row(max(0, cursor.row) + $0) }
        }
        var out: [DisplayRow] = []
        var position = DisplayCursor(row: max(0, cursor.row), line: cursor.line)
        // The entry. A display cursor may sit anywhere inside a block -- halfway down a lens, on a
        // wrapped command line, inside a fold -- and only `displayEntry` answers from an arbitrary
        // position. It costs a scan back to the block's prompt each step, which inside the block is
        // the length of its command line and outside it is the length of the block, so the walk uses
        // it exactly until it is past the block it started in and then hands over to the loop below.
        if let region = command(containingAbsoluteRow: position.row),
           folding.shape(of: region.id) != nil || lenses.lens(of: region.id) != nil {
            while out.count < count, position.row <= region.endRow,
                  let (entry, next) = displayEntry(at: position, folding: folding, lenses: lenses,
                                                   buffers: buffers) {
                out.append(entry)
                position = next
            }
        }
        var row = position.row
        while out.count < count && row < totalRows {
            out.append(.row(row))
            // Two dictionary lookups before any region walk: `commandID` is stamped on prompt rows
            // only, so this is also what limits the walk to entering a block where it begins.
            guard let id = absoluteRow(row)?.commandID, id != 0 else { row += 1; continue }
            let shape = folding.shape(of: id)
            let lensed = lenses.lens(of: id) != nil
            guard shape != nil || lensed,
                  let region = command(containingAbsoluteRow: row), region.promptRow == row else {
                row += 1
                continue
            }
            // A folded block shows its fold, not its lens: both say "show me less", and the fold is
            // the one whose placeholder the reader can click to undo.
            if let shape {
                let hidden = OutputFolding.hiddenRange(of: region, shape: shape)
                guard !hidden.isEmpty else { row += 1; continue }
                // A wrapped command line lies between the prompt and its output; it belongs to the
                // command, not to what it printed, and stays on screen.
                var next = row + 1
                while next < hidden.lowerBound && out.count < count {
                    out.append(.row(next))
                    next += 1
                }
                if out.count < count {
                    out.append(.fold(commandID: id, hiddenRows: hidden.count, status: region.status))
                }
                row = hidden.upperBound
                continue
            }
            guard let buffer = buffers(id), buffer.lineCount > 0,
                  !region.outputRows.isEmpty else { row += 1; continue }
            var next = row + 1
            while next < region.outputRows.lowerBound && out.count < count {
                out.append(.row(next))
                next += 1
            }
            var index = 0
            while index < buffer.lineCount && out.count < count {
                out.append(.lens(commandID: id, line: index))
                index += 1
            }
            row = region.endRow + 1
        }
        return out
    }

    /// The same, from an absolute row: what everything that still scrolls to a *place* rather than
    /// by an amount asks for. A row inside a lens keeps its proportional position; see
    /// `displayCursor(atAbsoluteRow:)`.
    func displayRows(from top: Int, count: Int, folding: OutputFolding,
                     lenses: LensChoices = LensChoices(),
                     buffers: (UInt32) -> LensBuffer? = { _ in nil }) -> [DisplayRow] {
        guard count > 0 else { return [] }
        guard !folding.isEmpty || !lenses.isEmpty else { return (0..<count).map { .row(top + $0) } }
        let cursor = displayCursor(atAbsoluteRow: max(0, top), folding: folding, lenses: lenses,
                                   buffers: buffers)
        return displayRows(from: cursor, count: count, folding: folding, lenses: lenses,
                           buffers: buffers)
    }

    /// The rows to draw for a range of the buffer; used where a fixed count is not wanted.
    func displayRows(in range: Range<Int>, folding: OutputFolding,
                     lenses: LensChoices = LensChoices(),
                     buffers: (UInt32) -> LensBuffer? = { _ in nil }) -> [DisplayRow] {
        guard !folding.isEmpty || !lenses.isEmpty else { return range.map { .row($0) } }
        return displayRows(from: range.lowerBound, count: range.count, folding: folding,
                           lenses: lenses, buffers: buffers)
            .filter { if case .row(let r) = $0 { return range.contains(r) } else { return true } }
    }

    // `snapViewportOutOfFold` used to live here: after a scroll by rows it dragged a viewport top
    // that had landed inside a fold back out of it, so two thousand hidden rows were not two
    // thousand wheel clicks. `Terminal.advance(_:by:)` makes the whole idea unnecessary -- a fold is
    // one display line to step over and a lens is as many lines as it has -- and its lens branch was
    // actively wrong: it jumped the reader *past* a lensed block, which is precisely the content
    // they were trying to scroll through.

    /// The placeholder as a row of cells, so it is drawn through the ordinary row path and nothing
    /// in NyxRender learns what a fold is.
    ///
    /// Italic, and in the block's own status colour -- the same three the spine uses: red for a
    /// failure, amber while the command is still running (a folded build is a live tail, and grey
    /// beside an amber spine said two different things about one block), bright black otherwise.
    /// It used to be dim as well, and dimmed bright black read as a comment the shell had printed
    /// rather than as the one thing on that row you are meant to click.
    func foldPlaceholderRow(hiddenRows: Int, status: BlockStatus) -> Row {
        var row = Row(cols: cols)
        var cell = Cell()
        switch status {
        case .running: cell.fg = .indexed(3)
        case .failed: cell.fg = .indexed(1)
        case .succeeded: cell.fg = .indexed(8)
        }
        cell.attrs = [.italic]
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

    /// The slot showing `absoluteRow`, or nil when a fold hides that row.
    ///
    /// The cursor and the IME preedit are the only two things the renderer places by the *screen*
    /// row it is handed, while every line in the frame is a display slot; with a fold on screen
    /// those are different numbers, and the caret was drawn as many rows below the prompt as the
    /// fold had hidden above it. A hidden row has no slot at all, and no caret is a better answer
    /// than a caret on whichever row moved into that index.
    ///
    /// A walk rather than `indexByAbsoluteRow`: this is asked once per frame for one row, and
    /// building a dictionary of the whole viewport to answer it would cost more than it saves.
    public static func cursorSlot(absoluteRow: Int, in display: [DisplayRow]) -> Int? {
        for (slot, entry) in display.enumerated() {
            if case .row(absoluteRow) = entry { return slot }
        }
        return nil
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
            case .fold(let id, _, _), .lens(let id, _):
                // A lens line stands in for this block's output exactly as a fold placeholder
                // stands in for its hidden rows: both belong to the block, and its spine and its
                // hover have to cover them.
                guard id == commandID else { continue }
            }
            if first == nil { first = slot }
            last = slot
        }
        guard let first, let last else { return nil }
        return first..<(last + 1)
    }
}
