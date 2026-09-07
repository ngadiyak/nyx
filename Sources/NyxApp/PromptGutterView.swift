import AppKit
import NyxCore

/// The narrow column down the left of a pane carrying one mark per command: the head of that
/// command's spine, in the block's own colour, in a shape that says what happened.
///
/// The mark is drawn at `CommandBlockChrome.spineLeadingInset` and is `CommandBlockChrome.spineWidth`
/// wide -- the two numbers the Metal spine reads for the same block -- so the cap and the spine are
/// one continuous shape rather than a 4.5 pt capsule beside a 1 pt line, which is what the design
/// review read as "a green line with beads on it".
///
/// The view's own frame is `PromptGutter.hitWidth`, which is wider than the mark and independent of
/// the pane's padding: it may overlap the first text column, and `hitTest` gives every point that is
/// not on a mark back to the pane, so the text under it keeps its clicks.
///
/// `otherMouseUp` is deliberately *not* overridden. Middle-click paste happens in the pane's
/// `otherMouseUp`, which this view reaches through the responder chain; an override here -- even one
/// that forwarded -- would put the release on a different path from the press and break it. Only
/// `otherMouseDown` is forwarded, because this view claims the point and would otherwise swallow it.
final class PromptGutterView: NSView {
    /// A click on a mark, as a visible row index, and whether ⌥ was held.
    var onSelectRow: ((Int, Bool) -> Void)?

    /// The cap per marked display slot. Every decision about shape, colour and pressability was
    /// made by `CommandBlockChrome.gutterCap` in the pane; nothing here re-derives one.
    private var caps: [Int: CommandBlockChrome.GutterCap] = [:]
    /// What each mark says in its tooltip and to VoiceOver, from `GutterMarkLabel.text` -- built in
    /// the pane, where the header is.
    private var labels: [Int: String] = [:]
    private var palette = Palette.xtermDefault()
    private var cellHeight: CGFloat = 1
    private var panePadding: CGFloat = 8
    private var topPadding: CGFloat = 0

    override var isFlipped: Bool { true }

    /// The one-row hit floor: 16 pt even when `line-height 0.8` makes a row 13 (§8.4). The *drawn*
    /// mark stays exactly `cellHeight` tall, so widening the target cannot fatten the picture.
    private var hitHeight: CGFloat {
        CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cellHeight)))
    }

    /// Where the mark is drawn -- the same x the renderer puts the spine at.
    private var markX: CGFloat {
        CGFloat(CommandBlockChrome.spineLeadingInset(padding: Double(panePadding)))
    }

    /// The gutter is decoration over the terminal; a point that misses a mark belongs to the pane
    /// underneath, so this view claims only the marks themselves -- every *drawn* mark, not only the
    /// pressable ones. That matters more now that the column is 20 pt wide and overlaps the first
    /// text column at the shipping padding: everything but the marks is the pane's.
    ///
    /// Drawn rather than pressable because AppKit resolves a tooltip's owner by hit-testing, and a
    /// view that disowns a point cannot be asked about it. A `cd ..` mark has a tooltip saying a
    /// command ran and succeeded, and claiming the point is the only way to be sure it is offered.
    /// What the click means is unchanged -- `mouseDown` hands a press on a mark with nothing to fold
    /// straight back to the pane.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local),
              PromptGutter.markedRow(atY: Double(local.y), cellHeight: Double(cellHeight),
                                     padding: Double(topPadding), hitHeight: Double(hitHeight),
                                     markedRows: Array(caps.keys)) != nil
        else { return nil }
        return self
    }

    /// Returns whether anything that decides where a *cursor rect* goes changed, so the pane can
    /// ask AppKit to rebuild them. Nothing else does: `resetCursorRects` is called when a view is
    /// added, resized or explicitly invalidated, and this view is none of those between frames --
    /// so after `ls` finished, its new mark had no pointing hand until the next resize, and after a
    /// resize a hand could sit over a `cd ..` mark that no longer had one.
    ///
    /// A rect is a row index *and* a geometry, so the cell height, the top padding and the pane's
    /// padding count too: after ⌘+ with the same commands on the same rows, the hands stayed the
    /// old size.
    @discardableResult
    func update(caps: [Int: CommandBlockChrome.GutterCap], labels: [Int: String],
                palette: Palette, cellHeight: CGFloat, padding: CGFloat, topPadding: CGFloat) -> Bool {
        let changed = caps != self.caps || labels != self.labels || palette != self.palette
            || cellHeight != self.cellHeight || padding != self.panePadding
            || topPadding != self.topPadding
        guard changed else { return false }
        let previous = pressableRows()
        let geometryMoved = cellHeight != self.cellHeight || topPadding != self.topPadding
            || padding != self.panePadding
        self.caps = caps
        self.labels = labels
        self.palette = palette
        self.cellHeight = cellHeight
        self.panePadding = padding
        self.topPadding = topPadding
        needsDisplay = true
        // A tooltip per mark, saying the same sentence VoiceOver reads. Rebuilt rather than edited:
        // the rows shift under the marks on every scroll, so a tooltip left where it was would soon
        // describe a different command.
        removeAllToolTips()
        for (row, _) in caps {
            addToolTip(rect(of: row), owner: (labels[row] ?? "") as NSString, userData: nil)
        }
        return pressableRows() != previous || geometryMoved
    }

    /// The target: 20 pt wide, `hitRowHeight` tall, centred on the row. The rect the *tooltip*, the
    /// *cursor rect* and the *accessibility element* all use, so the three cannot disagree about
    /// where a mark is.
    private func rect(of row: Int) -> NSRect {
        let centre = topPadding + (CGFloat(row) + 0.5) * cellHeight
        return NSRect(x: 0, y: centre - hitHeight / 2, width: CGFloat(PromptGutter.hitWidth),
                      height: hitHeight)
    }

    /// The rows a pointing hand belongs on. Compared between frames rather than recomputed by
    /// AppKit, which has no way of knowing the gutter changed.
    private func pressableRows() -> [Int] { caps.filter { $0.value.isPressable }.keys.sorted() }

    /// The marked row a point is on, through the one rule in Core: overlapping targets on a short
    /// row go to the nearer centre rather than to whichever happened to be tested first.
    private func markedRow(at point: NSPoint) -> Int? {
        PromptGutter.markedRow(atY: Double(point.y), cellHeight: Double(cellHeight),
                               padding: Double(topPadding), hitHeight: Double(hitHeight),
                               markedRows: Array(caps.keys))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cellHeight > 0 else { return }
        let width = CGFloat(CommandBlockChrome.spineWidth)
        for (row, cap) in caps {
            let y = topPadding + CGFloat(row) * cellHeight
            let colour = nsColor(cap.tone.color(in: palette), alpha: cap.shape == .faded ? 0.4 : 1)
            switch cap.shape {
            case .solid, .faded:
                // Inset top and bottom, so a cap reads as one command's mark and a run of them
                // reads as several -- the bar below is the shape that joins up.
                let box = NSRect(x: markX, y: y + 2, width: width, height: max(1, cellHeight - 4))
                colour.setFill()
                NSBezierPath(roundedRect: box, xRadius: width / 2, yRadius: width / 2).fill()
            case .bar:
                // The full row: a failure carries more ink than a success, because a failure is
                // what has to be findable while scrolling (design §3.2, over a11y 6.2's half mark).
                colour.setFill()
                NSBezierPath(rect: NSRect(x: markX, y: y, width: width, height: cellHeight)).fill()
            case .hollow:
                let box = NSRect(x: markX, y: y + 2, width: width, height: max(1, cellHeight - 4))
                colour.setStroke()
                let ring = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: width / 2, yRadius: width / 2)
                ring.lineWidth = 1
                ring.stroke()
            case .chevronDown, .chevronRight:
                // The only new mark this wave draws, and only under the pointer: an 8 pt path, in
                // the block's own colour, in place of the cap. Nothing is added at idle.
                colour.setFill()
                chevron(pointingDown: cap.shape == .chevronDown,
                        in: NSRect(x: markX, y: y + (cellHeight - 8) / 2, width: 8, height: 8)).fill()
            }
        }
    }

    /// A filled triangle, drawn as a path rather than set as a glyph: the 5 pt `▾` in a 20 pt pill
    /// is exactly what the design review measured as "weak because of size".
    ///
    /// The view is flipped, so `maxY` is the *bottom* of the box: a chevron pointing down has its
    /// apex there and its base along `minY`.
    private func chevron(pointingDown: Bool, in box: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        if pointingDown {
            path.move(to: NSPoint(x: box.minX, y: box.minY))
            path.line(to: NSPoint(x: box.maxX, y: box.minY))
            path.line(to: NSPoint(x: box.midX, y: box.maxY))
        } else {
            path.move(to: NSPoint(x: box.minX, y: box.minY))
            path.line(to: NSPoint(x: box.minX, y: box.maxY))
            path.line(to: NSPoint(x: box.maxX, y: box.midY))
        }
        path.close()
        return path
    }

    /// Set while a click that landed on a mark with nothing to fold is being handed to the pane.
    /// The drag and the release have to follow the same way: the pane starts a selection on the
    /// press and extends it from `mouseDragged`, so forwarding only the press would leave a
    /// selection nothing could grow or finish.
    private var forwardingToPane = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = markedRow(at: point), caps[row]?.isPressable == true else {
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
    // The gutter says whether a command worked in a colour and a shape. Every mark becomes an
    // element that says it in words and performs the same fold a click does.

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Command results" }

    override func accessibilityChildren() -> [Any]? {
        guard cellHeight > 0 else { return [] }
        return caps.keys.sorted().compactMap { row -> NSAccessibilityElement? in
            guard let cap = caps[row] else { return nil }
            // A mark with nothing to fold is still an element, because a command ran there and
            // VoiceOver has no other way to learn that -- but it is text rather than a button, and
            // `press: nil` is what makes it report as not enabled.
            return DrawnControlElement.make(
                label: labels[row] ?? "",
                role: cap.isPressable ? .button : .staticText,
                frame: rect(of: row),
                in: self,
                press: cap.isPressable ? { [weak self] in self?.onSelectRow?(row, false) } : nil)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard cellHeight > 0 else { return }
        for row in pressableRows() {
            addCursorRect(rect(of: row), cursor: .pointingHand)
        }
    }
}
