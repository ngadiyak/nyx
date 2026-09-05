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
    private var palette = Palette.xtermDefault()
    private var cellHeight: CGFloat = 1
    private var topPadding: CGFloat = 0

    override var isFlipped: Bool { true }

    /// The gutter is decoration over the terminal; a click that misses a mark belongs to the pane
    /// underneath, so this view claims only the marks themselves.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local),
              let row = PromptGutter.row(atY: Double(local.y), cellHeight: Double(cellHeight),
                                         padding: Double(topPadding), rows: marks.count),
              mark(at: row) != nil
        else { return nil }
        return self
    }

    func update(marks: [GutterMark?], folded: [Bool], palette: Palette,
                cellHeight: CGFloat, topPadding: CGFloat) {
        let changed = marks != self.marks || folded != self.folded || palette != self.palette
            || cellHeight != self.cellHeight || topPadding != self.topPadding
        guard changed else { return }
        self.marks = marks
        self.folded = folded
        self.palette = palette
        self.cellHeight = cellHeight
        self.topPadding = topPadding
        needsDisplay = true
        // A tooltip per mark, saying the same sentence VoiceOver reads. Rebuilt rather than edited:
        // the rows shift under the marks on every scroll, so a tooltip left where it was would soon
        // describe a different command.
        removeAllToolTips()
        for row in marks.indices {
            guard let mark = mark(at: row) else { continue }
            let y = topPadding + CGFloat(row) * cellHeight
            addToolTip(NSRect(x: 0, y: y, width: max(1, bounds.width), height: cellHeight),
                       owner: label(for: mark, row: row) as NSString, userData: nil)
        }
    }

    /// The words a mark says, in the tooltip and to VoiceOver. Decided in `GutterMarkLabel`, so a
    /// control that folds cannot go on claiming it selects.
    private func label(for mark: GutterMark, row: Int) -> String {
        GutterMarkLabel.text(mark: mark, folded: folded.indices.contains(row) && folded[row],
                             line: row + 1)
    }

    /// Nothing is drawn for a command still running: a mark that appeared the instant you pressed
    /// return and then changed colour would be a progress indicator, and this is a record.
    private func mark(at row: Int) -> GutterMark? {
        guard marks.indices.contains(row) else { return nil }
        switch marks[row] {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .running, .none: return nil
        }
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
        for row in marks.indices {
            guard let mark = mark(at: row) else { continue }
            let y = topPadding + CGFloat(row) * cellHeight
            let rect = NSRect(x: inset, y: y + 1, width: width, height: max(1, cellHeight - 2))
            guard rect.intersects(dirtyRect) else { continue }
            (mark == .failed ? failedColor : succeededColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = PromptGutter.row(atY: Double(point.y), cellHeight: Double(cellHeight),
                                         padding: Double(topPadding), rows: marks.count),
              mark(at: row) != nil
        else { return }
        onSelectRow?(row, event.modifierFlags.contains(.option))
    }

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
            return DrawnControlElement.make(
                label: label(for: mark, row: row),
                role: .button,
                frame: NSRect(x: 0, y: y, width: max(1, bounds.width), height: cellHeight),
                in: self,
                press: { [weak self] in self?.onSelectRow?(row, false) })
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard cellHeight > 0 else { return }
        for row in marks.indices where mark(at: row) != nil {
            let y = topPadding + CGFloat(row) * cellHeight
            addCursorRect(NSRect(x: 0, y: y, width: bounds.width, height: cellHeight), cursor: .pointingHand)
        }
    }
}
