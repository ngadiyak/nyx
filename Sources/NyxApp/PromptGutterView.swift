import AppKit
import NyxCore

/// The narrow column down the left of a pane carrying one mark per command: green where it
/// succeeded, red where it failed, nothing while it is still running.
///
/// It lives inside the pane's own left padding, so it costs no terminal columns and never overlaps
/// a glyph -- `PromptGutter.width` decides how much of the padding it may take, and a pane with too
/// little padding gets no gutter rather than one over its text.
final class PromptGutterView: NSView {
    /// A click on a mark, as a visible row index, and whether ⌥ was held.
    var onSelectRow: ((Int, Bool) -> Void)?

    private var marks: [GutterMark?] = []
    /// Whether each row's command is folded, so a mark says which way pressing it goes.
    private var folded: [Bool] = []
    /// Whether the shell said each row's command started -- what decides whether a running ring is
    /// drawn at all, as opposed to whether it can be pressed.
    private var hasStarted: [Bool] = []
    /// Whether each row's command has anything on its output rows. A mark without it is a record
    /// and nothing more: no pointing hand and no button, because pressing it can do nothing -- it
    /// used to offer a hand, a tooltip and a button, and then beep.
    private var hasOutput: [Bool] = []
    private var palette = Palette.xtermDefault()
    private var cellHeight: CGFloat = 1
    private var topPadding: CGFloat = 0

    override var isFlipped: Bool { true }

    /// The gutter is decoration over the terminal; a point that misses a mark belongs to the pane
    /// underneath, so this view claims only the marks themselves -- every *drawn* mark, not only the
    /// pressable ones.
    ///
    /// Drawn rather than pressable because AppKit resolves a tooltip's owner by hit-testing, and a
    /// view that disowns a point cannot be asked about it. A `cd ..` mark has a tooltip saying a
    /// command ran and succeeded, and claiming the point is the only way to be sure it is offered.
    /// Whether AppKit would have found it anyway could not be shown either way here: a probe with a
    /// real cursor warp saw no tooltip window even for a control view that *does* own its point, so
    /// the deterministic route is the one with evidence behind it. What the click means is unchanged
    /// -- `mouseDown` hands a press on a mark with nothing to fold straight back to the pane.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local),
              let row = PromptGutter.row(atY: Double(local.y), cellHeight: Double(cellHeight),
                                         padding: Double(topPadding), rows: marks.count),
              mark(at: row) != nil
        else { return nil }
        return self
    }

    /// Returns whether anything that decides where a *cursor rect* goes changed, so the pane can
    /// ask AppKit to rebuild them. Nothing else does: `resetCursorRects` is called when a view is
    /// added, resized or explicitly invalidated, and this view is none of those between frames --
    /// so after `ls` finished, its new green dot had no pointing hand until the next resize, and
    /// after a resize a hand could sit over a `cd ..` mark that no longer had one.
    ///
    /// A rect is a row index *and* a geometry, so the cell height and the top padding count too:
    /// after ⌘+ with the same commands on the same rows, the hands stayed the old size.
    @discardableResult
    func update(marks: [GutterMark?], folded: [Bool], hasStarted: [Bool], hasOutput: [Bool],
                palette: Palette, cellHeight: CGFloat, topPadding: CGFloat) -> Bool {
        let changed = marks != self.marks || folded != self.folded
            || hasStarted != self.hasStarted || hasOutput != self.hasOutput
            || palette != self.palette
            || cellHeight != self.cellHeight || topPadding != self.topPadding
        guard changed else { return false }
        let previousRects = actionableRows()
        let geometryMoved = cellHeight != self.cellHeight || topPadding != self.topPadding
        self.marks = marks
        self.folded = folded
        self.hasStarted = hasStarted
        self.hasOutput = hasOutput
        self.palette = palette
        self.cellHeight = cellHeight
        self.topPadding = topPadding
        needsDisplay = true
        // A tooltip per mark, saying the same sentence VoiceOver reads. Rebuilt rather than edited:
        // the rows shift under the marks on every scroll, so a tooltip left where it was would soon
        // describe a different command.
        removeAllToolTips()
        for row in marks.indices {
            // Every drawn mark, pressable or not: a `cd ..` mark still says "Command on line 3
            // succeeded.", which is the whole reason the gutter exists -- it is a record.
            guard let mark = mark(at: row) else { continue }
            let y = topPadding + CGFloat(row) * cellHeight
            addToolTip(NSRect(x: 0, y: y, width: max(1, bounds.width), height: cellHeight),
                       owner: label(for: mark, row: row) as NSString, userData: nil)
        }
        return actionableRows() != previousRects || geometryMoved
    }

    /// The rows a pointing hand belongs on. Compared between frames rather than recomputed by
    /// AppKit, which has no way of knowing the gutter changed.
    private func actionableRows() -> [Int] {
        marks.indices.filter { isActionable($0) }
    }

    /// The words a mark says, in the tooltip and to VoiceOver. Decided in `GutterMarkLabel`, so a
    /// control that folds cannot go on claiming it selects -- or promise anything at all on a
    /// command that printed nothing to fold.
    private func label(for mark: GutterMark, row: Int) -> String {
        GutterMarkLabel.text(mark: mark, folded: folded.indices.contains(row) && folded[row],
                             hasOutput: output(at: row), line: row + 1)
    }

    private func output(at row: Int) -> Bool {
        hasOutput.indices.contains(row) && hasOutput[row]
    }

    private func started(at row: Int) -> Bool {
        hasStarted.indices.contains(row) && hasStarted[row]
    }

    /// The mark to draw on a row, or nil for a row with nothing to say. Both rules are Core's:
    /// a finished command's dot is a record whatever it printed, and a running one appears only
    /// once it has actually begun printing -- otherwise the prompt you are typing at, which has a
    /// prompt mark and no status, would wear a ring forever.
    private func mark(at row: Int) -> GutterMark? {
        guard marks.indices.contains(row), let mark = marks[row],
              mark.isDrawn(hasStarted: started(at: row)) else { return nil }
        return mark
    }

    /// Whether a press on this row can do anything, which is what the pointing hand, the tooltip
    /// and the accessibility element are for.
    private func isActionable(_ row: Int) -> Bool {
        guard let mark = mark(at: row) else { return false }
        return mark.isActionable(hasOutput: output(at: row))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cellHeight > 0, bounds.width > 0 else { return }
        let inset: CGFloat = 1
        let width = max(1, bounds.width - inset * 2)
        // The theme's own green and red, so the gutter matches whatever the shell prints, in
        // whichever of the normal and bright variants reads on this background. Both resolved
        // before the loop: `readable` compares two contrast ratios, which is not much, and is not
        // worth doing once per visible row per frame.
        let failedColor = nsColor(palette.readable(1), alpha: 0.9)
        let succeededColor = nsColor(palette.readable(2), alpha: 0.9)
        // The amber the spine and a folded running command's placeholder already use, so one glance
        // down the gutter says which command is still going.
        let runningColor = nsColor(palette.readable(3), alpha: 0.9)
        for row in marks.indices {
            guard let mark = mark(at: row) else { continue }
            let y = topPadding + CGFloat(row) * cellHeight
            let rect = NSRect(x: inset, y: y + 1, width: width, height: max(1, cellHeight - 2))
            guard rect.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: mark == .running ? rect.insetBy(dx: 0.5, dy: 0.5) : rect,
                                    xRadius: width / 2, yRadius: width / 2)
            switch mark {
            // Hollow, so a command in progress is legible as unfinished at a glance rather than
            // only by its colour -- the one thing a colour can never say on its own.
            case .running:
                runningColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            case .failed:
                failedColor.setFill()
                path.fill()
            case .succeeded:
                succeededColor.setFill()
                path.fill()
            }
        }
    }

    /// Set while a click that landed on a mark with nothing to fold is being handed to the pane.
    /// The drag and the release have to follow the same way: the pane starts a selection on the
    /// press and extends it from `mouseDragged`, so forwarding only the press would leave a
    /// selection nothing could grow or finish.
    private var forwardingToPane = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = PromptGutter.row(atY: Double(point.y), cellHeight: Double(cellHeight),
                                         padding: Double(topPadding), rows: marks.count),
              isActionable(row)
        else {
            // A mark with nothing to fold is a record, not a button. The click means what it would
            // have meant on the padding beside it: the start of a selection.
            forwardingToPane = true
            superview?.mouseDown(with: event)
            return
        }
        forwardingToPane = false
        onSelectRow?(row, event.modifierFlags.contains(.option))
    }

    override func mouseDragged(with event: NSEvent) {
        guard forwardingToPane else { return }
        superview?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard forwardingToPane else { return }
        forwardingToPane = false
        superview?.mouseUp(with: event)
    }

    // The gutter answers to a left click and nothing else. Now that it claims every drawn mark --
    // including ones it does nothing with -- a right or middle click landing on one would otherwise
    // stop here, taking away the block context menu and the middle-click paste over those few
    // points. Both go straight back to the pane.
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { superview?.otherMouseDown(with: event) }

    // MARK: - Accessibility
    //
    // The gutter says whether a command worked entirely in colour -- green or red -- which is the
    // one thing a colour can never say on its own. Every mark becomes an element that says it in
    // words and performs the same jump a click does.

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Command results" }

    override func accessibilityChildren() -> [Any]? {
        guard cellHeight > 0 else { return [] }
        return marks.indices.compactMap { row -> NSAccessibilityElement? in
            guard let mark = mark(at: row) else { return nil }
            let y = topPadding + CGFloat(row) * cellHeight
            // A mark with nothing to fold is still an element, because a command ran there and
            // VoiceOver has no other way to learn that -- but it is text rather than a button, and
            // `press: nil` is what makes it report as not enabled.
            let actionable = isActionable(row)
            return DrawnControlElement.make(
                label: label(for: mark, row: row),
                role: actionable ? .button : .staticText,
                frame: NSRect(x: 0, y: y, width: max(1, bounds.width), height: cellHeight),
                in: self,
                press: actionable ? { [weak self] in self?.onSelectRow?(row, false) } : nil)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard cellHeight > 0 else { return }
        for row in marks.indices where isActionable(row) {
            let y = topPadding + CGFloat(row) * cellHeight
            addCursorRect(NSRect(x: 0, y: y, width: bounds.width, height: cellHeight), cursor: .pointingHand)
        }
    }
}
