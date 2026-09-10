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

/// What a gutter mark says to VoiceOver and in its tooltip.
///
/// The words used to promise the wrong thing twice over: every mark read "Select its output." while
/// pressing one folded the block (selecting is what ⌥-click does), and a command that printed
/// nothing offered both while doing neither. A control that names an action it does not perform is
/// worse than an unlabelled one, and there is no AppKit test target here, so the wording is decided
/// in Core and asserted.
public enum GutterMarkLabel {
    /// The four facts a mark's sentence is made of, as a value.
    ///
    /// `Pane.render` builds one of these per mark inside `withTerminal`, sixty times a second; the
    /// gutter view turns them into strings only when the set actually changed. Formatting them
    /// under the PTY lock instead meant four string interpolations per command on screen per frame,
    /// holding the lock the parser wants, to produce sentences that are identical to last frame's
    /// unless a command started, finished or was folded.
    public struct Key: Equatable {
        public let mark: GutterMark
        public let folded: Bool
        public let hasOutput: Bool
        public let line: Int

        public init(mark: GutterMark, folded: Bool, hasOutput: Bool, line: Int) {
            self.mark = mark
            self.folded = folded
            self.hasOutput = hasOutput
            self.line = line
        }
    }

    public static func text(_ key: Key) -> String {
        text(mark: key.mark, folded: key.folded, hasOutput: key.hasOutput, line: key.line)
    }

    public static func text(mark: GutterMark, folded: Bool, hasOutput: Bool, line: Int) -> String {
        let outcome: String
        switch mark {
        case .failed: outcome = "failed"
        case .succeeded: outcome = "succeeded"
        case .running: outcome = "is still running"
        }
        let state = "Command on line \(line) \(outcome)."
        // Nothing to fold and nothing to select: the mark is a record, and says only what happened.
        guard hasOutput else { return state }
        return "\(state) \(folded ? "Unfold" : "Fold") its output. Option-click selects its output."
    }
}

/// The geometry of the status gutter, and the marks to put in it.
///
/// Only the *hit* geometry: what the gutter draws is `CommandBlockChrome.GutterCap` at
/// `CommandBlockChrome.spineLeadingInset` × `.spineWidth`, which is where the Metal spine is drawn
/// too. The target and the picture were one number for a long time, and the result was that making
/// the dots easier to click also made them fatter.
public enum PromptGutter {
    /// The **hit area**: 20 points, the same target the fold triangles of §2.4 get, independent of
    /// `padding` and allowed to overlap the first text column. `PromptGutterView.hitTest` hands
    /// back every point that is not on a mark, so the columns of text under it keep their clicks;
    /// what changes is that a pointer reaching for a mark no longer has to find 8 points of padding
    /// at the window's own resize margin.
    ///
    /// The *drawn* mark is `CommandBlockChrome.spineWidth` wide at `spineLeadingInset`, which is
    /// where the Metal spine is: one shape, one fact.
    public static let hitWidth: Double = 20

    /// The marked row a point falls on, or nil for a point that belongs to the pane.
    ///
    /// Each marked row's target is `hitHeight` tall, centred on the row -- `hitRowHeight` clamps it
    /// to 16 pt, so at `line-height 0.8` it overhangs the rows above and below. Those are usually
    /// output rows with no mark of their own; where two marks' rects genuinely overlap (two prompts
    /// with nothing between them) the nearer centre wins, and an exact tie goes to the upper row so
    /// the answer never depends on the order `markedRows` arrives in.
    public static func markedRow(atY y: Double, cellHeight: Double, padding: Double,
                                 hitHeight: Double, markedRows: [Int]) -> Int? {
        // The gutter cap and the in-grid fold triangles are the same target at the same height, so
        // they resolve a point the same way -- one implementation, in `CommandBlockChrome`.
        CommandBlockChrome.hitRow(atY: y, cellHeight: cellHeight, padding: padding,
                                  hitHeight: hitHeight, rows: markedRows)
    }

    /// The visible row a point falls on, measured from the top of the pane including its padding.
    /// nil for a point in the padding above the first row or below the last.
    ///
    /// The *text* rule, and `Pane.visibleRow(at:)` is its caller: rows are one cell tall and do not
    /// overlap, so a point belongs to exactly one of them. A *target* on a row is the other rule --
    /// `CommandBlockChrome.hitRow`, with `hitRowHeight`'s floor under it and overlapping bands to
    /// resolve. Everything that turns a click into a control goes through that one; everything that
    /// turns a click into a caret or a selection comes here.
    public static func row(atY y: Double, cellHeight: Double, padding: Double, rows: Int) -> Int? {
        guard cellHeight > 0, rows > 0 else { return nil }
        let row = Int(((y - padding) / cellHeight).rounded(.down))
        return row >= 0 && row < rows ? row : nil
    }
}

public extension Terminal {
    /// The mark for one absolute row: what happened to the command whose prompt is on it, and
    /// nothing at all for a row that carries no prompt.
    ///
    /// The status of each command was written onto its own prompt row when its `D` arrived, so
    /// there is nothing to search for here -- searching forward used to walk to the end of the
    /// buffer on every frame whenever a command was still running, under the session lock, which is
    /// the one place that cost is worst.
    func gutterMark(atAbsoluteRow row: Int) -> GutterMark? {
        guard let line = absoluteRow(row),
              PromptMarks(rawValue: line.promptMark).contains(.promptStart) else { return nil }
        guard let status = line.commandStatus else { return .running }
        return status == 0 ? .succeeded : .failed
    }

    /// A mark per visible row, for a viewport with nothing folded: the rows on screen are exactly
    /// `viewportTop ..< viewportTop + rows`.
    func gutterMarks(rows visibleRows: Int) -> [GutterMark?] {
        guard visibleRows > 0 else { return [] }
        let top = max(0, viewportTopRow)
        return (0..<visibleRows).map { gutterMark(atAbsoluteRow: top + $0) }
    }

    /// A mark per display slot, for a viewport with a fold in it.
    ///
    /// Driven by the slots rather than by a window of absolute rows on purpose. With a fold on
    /// screen the last row displayed can be ten thousand rows below the first, and asking for a
    /// mark per row of *that* window is a scan of the whole fold on every frame: measured at
    /// 3.276 ms per frame over a 10,000-row fold, against 0.019 ms for the rows actually drawn.
    /// A fold placeholder has no prompt of its own, so it gets no mark.
    func gutterMarks(onDisplayRows display: [DisplayRow]) -> [GutterMark?] {
        display.map { entry in
            guard case .row(let absolute) = entry else { return nil }
            return gutterMark(atAbsoluteRow: absolute)
        }
    }

    /// Whether the command whose prompt is on this absolute row is folded. `false` for a row with
    /// no prompt: the gutter draws nothing there, so nothing asks.
    ///
    /// Beside the marks because it is read for the same rows at the same moment, and because the
    /// gutter's own label depends on it: pressing a mark folds, and the words have to say which way.
    func isCommandFolded(atAbsoluteRow row: Int, folding: OutputFolding) -> Bool {
        guard let line = absoluteRow(row),
              PromptMarks(rawValue: line.promptMark).contains(.promptStart),
              line.commandID != 0 else { return false }
        return folding.isFolded(line.commandID)
    }

    /// One flag per visible row, beside `gutterMarks(rows:)`.
    func foldStates(rows visibleRows: Int, folding: OutputFolding) -> [Bool] {
        guard visibleRows > 0 else { return [] }
        let top = max(0, viewportTopRow)
        return (0..<visibleRows).map { isCommandFolded(atAbsoluteRow: top + $0, folding: folding) }
    }

    /// One flag per display slot, beside `gutterMarks(onDisplayRows:)`.
    func foldStates(onDisplayRows display: [DisplayRow], folding: OutputFolding) -> [Bool] {
        display.map { entry in
            guard case .row(let absolute) = entry else { return false }
            return isCommandFolded(atAbsoluteRow: absolute, folding: folding)
        }
    }

    /// How many rows of a command's output are looked at before assuming the rest has something in
    /// it. Eight is one glance: a command whose first eight lines are blank and whose ninth is not
    /// is rare enough that scanning ten thousand rows to catch it would be the wrong trade.
    static var outputScanLimit: Int { 8 }

    /// Whether the command whose prompt is on this absolute row has output worth folding -- which is
    /// what decides whether its gutter mark can be pressed, whether its header shows a chevron, and
    /// whether `toggleFold` does anything.
    ///
    /// Two things it is *not*. It is not `CommandRegion.outputRows.isEmpty`: that walks to the next
    /// prompt three times over, and this is asked for every marked row on every frame. And it is not
    /// "the shell said output started" either -- `OSC 133;C` arrives when the command *begins*, so a
    /// `sleep 10` one second in has an output region made of the blank rows below it, and folding it
    /// collapsed five empty lines into "… 5 lines hidden".
    ///
    /// So: find where the output begins, then look for one row with something on it. A command that
    /// printed nothing leaves its `C` on the row its successor's prompt lands on, so meeting a
    /// prompt first means there was no output at all; the rows walked in between are the command's
    /// own wrapped line, of which there are one or two. The search for content stops at the next
    /// prompt, at the last row anything has been written to (rows below the cursor on the live
    /// screen are not output, they are the rest of the screen), or after `outputScanLimit` rows.
    func commandHasOutput(atAbsoluteRow row: Int) -> Bool {
        guard let start = outputStartRow(ofCommandAt: row) else { return false }
        return hasContent(fromOutputRow: start)
    }

    /// Whether anything has been written on the output rows beginning at `start`.
    private func hasContent(fromOutputRow start: Int) -> Bool {
        // Nothing below the cursor has been written yet; for a command still running that is most of
        // the screen, and counting it as output is what made a fresh `sleep 10` look foldable.
        let lastWritten = min(totalRows - 1, scrollback.count + screen.cursor.y)
        var scanned = 0
        var here = start
        while here <= lastWritten, scanned < Terminal.outputScanLimit {
            if here > start, promptMarks(atAbsoluteRow: here).contains(.promptStart) { return false }
            if let row = absoluteRow(here), !row.isBlank { return true }
            here += 1
            scanned += 1
        }
        // Eight blank rows and the output still going: take the rest on trust rather than scan it.
        return scanned >= Terminal.outputScanLimit
    }

    /// Where the output of the command whose prompt is on `row` begins, or nil when it never did.
    ///
    /// A command that printed nothing leaves its `C` on the row its successor's prompt lands on, so
    /// meeting a prompt first means the command produced no output region at all; the rows walked in
    /// between are the command's own wrapped line, of which there are one or two.
    func outputStartRow(ofCommandAt row: Int) -> Int? {
        guard let line = absoluteRow(row),
              PromptMarks(rawValue: line.promptMark).contains(.promptStart) else { return nil }
        var next = row + 1
        while next < totalRows {
            let marks = promptMarks(atAbsoluteRow: next)
            if marks.contains(.promptStart) { return nil }
            if marks.contains(.outputStart) { return next }
            next += 1
        }
        return nil
    }

    /// Whether the shell has said this command started running -- its `C` mark arrived. True the
    /// instant `sleep 10` begins and false for the prompt you are typing at, which is the one bit
    /// that decides whether the gutter draws a running ring.
    func commandDidStart(atAbsoluteRow row: Int) -> Bool {
        outputStartRow(ofCommandAt: row) != nil
    }

    /// Both flags for one row in a single walk. The gutter needs them together on every frame, and
    /// asking separately walks to the output start twice.
    func commandStates(atAbsoluteRow row: Int) -> (started: Bool, hasOutput: Bool) {
        guard let start = outputStartRow(ofCommandAt: row) else { return (false, false) }
        return (true, hasContent(fromOutputRow: start))
    }

    /// Both flags per visible row, in one pass.
    func commandStates(rows visibleRows: Int) -> (started: [Bool], hasOutput: [Bool]) {
        guard visibleRows > 0 else { return ([], []) }
        let top = max(0, viewportTopRow)
        var started = [Bool](); started.reserveCapacity(visibleRows)
        var output = [Bool](); output.reserveCapacity(visibleRows)
        for row in 0..<visibleRows {
            let state = commandStates(atAbsoluteRow: top + row)
            started.append(state.started)
            output.append(state.hasOutput)
        }
        return (started, output)
    }

    /// Both flags per display slot, in one pass.
    func commandStates(onDisplayRows display: [DisplayRow]) -> (started: [Bool], hasOutput: [Bool]) {
        var started = [Bool](); started.reserveCapacity(display.count)
        var output = [Bool](); output.reserveCapacity(display.count)
        for entry in display {
            guard case .row(let absolute) = entry else {
                started.append(false); output.append(false)
                continue
            }
            let state = commandStates(atAbsoluteRow: absolute)
            started.append(state.started)
            output.append(state.hasOutput)
        }
        return (started, output)
    }

    /// One flag per visible row, beside `gutterMarks(rows:)`.
    func startStates(rows visibleRows: Int) -> [Bool] {
        guard visibleRows > 0 else { return [] }
        let top = max(0, viewportTopRow)
        return (0..<visibleRows).map { commandDidStart(atAbsoluteRow: top + $0) }
    }

    /// One flag per display slot, beside `gutterMarks(onDisplayRows:)`.
    func startStates(onDisplayRows display: [DisplayRow]) -> [Bool] {
        display.map { entry in
            guard case .row(let absolute) = entry else { return false }
            return commandDidStart(atAbsoluteRow: absolute)
        }
    }

    /// One flag per visible row, beside `gutterMarks(rows:)`.
    func outputStates(rows visibleRows: Int) -> [Bool] {
        guard visibleRows > 0 else { return [] }
        let top = max(0, viewportTopRow)
        return (0..<visibleRows).map { commandHasOutput(atAbsoluteRow: top + $0) }
    }

    /// One flag per display slot, beside `gutterMarks(onDisplayRows:)`.
    func outputStates(onDisplayRows display: [DisplayRow]) -> [Bool] {
        display.map { entry in
            guard case .row(let absolute) = entry else { return false }
            return commandHasOutput(atAbsoluteRow: absolute)
        }
    }
}

public extension Terminal {
    /// How long the command whose prompt is on this absolute row took, ready to draw at the right
    /// edge of that row -- and nothing for a row with no prompt, or a command too quick to be worth
    /// a number: `3ms` beside every `cd` is noise that hides the one figure anybody cares about.
    func durationNote(atAbsoluteRow row: Int, threshold: Double = 0.5) -> String? {
        guard let line = absoluteRow(row),
              PromptMarks(rawValue: line.promptMark).contains(.promptStart),
              let seconds = line.commandDuration,
              DurationText.isWorthShowing(seconds, threshold: threshold) else { return nil }
        return DurationText.short(seconds)
    }

    /// One per visible row, for a viewport with nothing folded.
    func durationNotes(rows visibleRows: Int, threshold: Double = 0.5) -> [String?] {
        guard visibleRows > 0 else { return [] }
        let top = max(0, viewportTopRow)
        return (0..<visibleRows).map { durationNote(atAbsoluteRow: top + $0, threshold: threshold) }
    }

    /// One per display slot, for a viewport with a fold in it. See `gutterMarks(onDisplayRows:)`
    /// for why this is driven by the slots and not by a window of absolute rows.
    func durationNotes(onDisplayRows display: [DisplayRow], threshold: Double = 0.5) -> [String?] {
        display.map { entry in
            guard case .row(let absolute) = entry else { return nil }
            return durationNote(atAbsoluteRow: absolute, threshold: threshold)
        }
    }
}
