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

public extension GutterMark {
    /// Whether the dot is drawn for a row carrying this mark.
    ///
    /// A finished command's dot is a record and is drawn whatever it printed -- `cd ..` succeeded
    /// and the gutter says so. `.running` is different: the prompt you are typing at carries a
    /// prompt mark and no status, so it reads as running, and a mark there would sit beside an idle
    /// cursor for the rest of the session. A command is only *visibly* running once it has begun
    /// printing, which is exactly `hasOutput`.
    func isDrawn(hasOutput: Bool) -> Bool { self == .running ? hasOutput : true }

    /// Whether pressing the dot can do anything. Pressing folds the command's output, and ⌥ selects
    /// it; a command that printed nothing has neither, and the click used to beep at the user after
    /// offering a pointing hand, a tooltip and an accessibility button.
    func isActionable(hasOutput: Bool) -> Bool { hasOutput }
}

/// What a gutter mark says to VoiceOver and in its tooltip.
///
/// The words used to promise the wrong thing twice over: every mark read "Select its output." while
/// pressing one folded the block (selecting is what ⌥-click does), and a command that printed
/// nothing offered both while doing neither. A control that names an action it does not perform is
/// worse than an unlabelled one, and there is no AppKit test target here, so the wording is decided
/// in Core and asserted.
public enum GutterMarkLabel {
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

    /// Whether the command whose prompt is on this absolute row printed anything -- which is what
    /// decides whether its gutter mark can be pressed at all.
    ///
    /// Answers exactly what `CommandRegion.outputRows.isEmpty` answers, without building the region:
    /// that walks to the next prompt three times over, and this is asked for every marked row on
    /// every frame. A command that printed nothing leaves its `C` on the row its successor's prompt
    /// lands on, so finding a prompt first means there was no output; the rows walked in between are
    /// the command's own wrapped line, of which there are one or two.
    func commandHasOutput(atAbsoluteRow row: Int) -> Bool {
        guard let line = absoluteRow(row),
              PromptMarks(rawValue: line.promptMark).contains(.promptStart) else { return false }
        var next = row + 1
        while next < totalRows {
            let marks = promptMarks(atAbsoluteRow: next)
            if marks.contains(.promptStart) { return false }
            if marks.contains(.outputStart) { return true }
            next += 1
        }
        return false
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
