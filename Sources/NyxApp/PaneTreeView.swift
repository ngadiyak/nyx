import AppKit
import NyxCore

/// The window's terminal area: a `PaneTree` of live `Pane`s, laid out with dividers between them.
///
/// All the geometry -- where the panes go, where the dividers are, which one a point is over, what
/// a drag does to a ratio, which pane a click lands in, where focus moves to -- belongs to
/// `PaneTree` in `NyxCore`, where it is unit tested. This view converts events into those queries
/// and the answers into frames; it holds no geometry of its own beyond the last layout's dividers.
///
/// The view is flipped so its coordinates match the model's, whose y grows downwards (a `.vertical`
/// split puts `first` on top). Nothing else here has to think about the difference.
/// What a pane about to be created should start from.
///
/// A directory for the ordinary case -- a split inherits from the pane it came out of -- and, when
/// a saved session is being rebuilt, the ANSI transcript that pane was showing. Both travel
/// together because both are only ever known at the moment the pane is made.
struct PaneSeed {
    var workingDirectory: String?
    var transcript: String?

    init(workingDirectory: String? = nil, transcript: String? = nil) {
        self.workingDirectory = workingDirectory
        self.transcript = transcript
    }
}

final class PaneTreeView: NSView {
    /// The dividing line between two panes, and the width of the band around it the mouse can grab.
    private static let dividerThickness: Double = 1
    private static let dividerHitSlop: Double = 6
    /// How much one press of ⌘⌃arrow moves a divider, as a fraction of the containing split.
    private static let keyboardResizeStep: Double = 0.02

    var onAllPanesClosed: (() -> Void)?
    var onFocusedTitleChange: ((String) -> Void)?
    /// Any pane in this tree produced output, on the main queue. Forwarded straight from the panes
    /// so the tab holding this tree can show an activity dot while it is off screen.
    var onAnyPaneOutput: (() -> Void)?
    /// Any pane in this tree rang the bell, on the main queue.
    var onAnyPaneBell: (() -> Void)?
    /// The focused pane's working directory, whenever it changes and whenever focus moves to a
    /// pane with a different one. A project's actions belong to the pane you are looking at.
    var onFocusedDirectoryChange: ((String) -> Void)?
    /// A pane was added or removed. The session file follows the layout, so it has to be told.
    var onLayoutChange: (() -> Void)?

    private(set) var focused: PaneID?

    private let makePane: (PaneSeed) -> Pane?
    private var config: Config
    /// nil once the last pane has closed, at which point this view is on its way out.
    private var tree: PaneTree?
    private var panes: [PaneID: Pane] = [:]
    /// Last title reported by each pane, so re-focusing one restores the window title without
    /// waiting for the program to set it again.
    private var titles: [PaneID: String] = [:]
    /// The dividers from the last layout, in view coordinates. Only ever produced by `PaneTree`.
    private var dividers: [PaneDivider] = []
    /// The pane filling the whole view, if any. The tree is left untouched while zoomed: unzooming
    /// is just laying it out again.
    private var zoomed: PaneID?
    private var dividerColor: NSColor = .clear
    private var focusBorderColor: NSColor = .clear

    private init(config: Config, makePane: @escaping (PaneSeed) -> Pane?) {
        self.config = config
        self.makePane = makePane
        super.init(frame: .zero)
        updateThemeColors()
    }

    /// A tree of one pane, starting in `directory`.
    convenience init(config: Config, makePane: @escaping (PaneSeed) -> Pane?,
                     startingIn directory: String? = nil) {
        self.init(config: config, makePane: makePane)
        if let pane = makePane(PaneSeed(workingDirectory: directory)) {
            adopt(pane)
            tree = .leaf(pane.id)
            setFocus(pane.id)
        }
    }

    /// The panes a saved session recorded, in the layout it recorded them in. nil when not one of
    /// them could be created, which is the caller's cue to open an ordinary tab instead: a restore
    /// that fails must cost the user their layout, never their terminal.
    convenience init?(config: Config, makePane: @escaping (PaneSeed) -> Pane?,
                      restoring tab: TabSnapshot) {
        self.init(config: config, makePane: makePane)
        guard restore(tab) else { return nil }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Recreates a tab's panes and puts them back in their split layout.
    ///
    /// Panes are created against the ids the layout mentions, not against the pane list, so a
    /// snapshot whose two halves disagree cannot produce a pane sitting outside the tree with a
    /// live shell in it and no frame. A shell that will not start costs its own pane and nothing
    /// more -- `PaneLayoutNode.tree(idFor:)` collapses it into its sibling, exactly as closing it
    /// would.
    private func restore(_ tab: TabSnapshot) -> Bool {
        let saved = Dictionary(tab.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var remapped: [Int: PaneID] = [:]
        for id in tab.layout.paneIDs {
            let snapshot = saved[id]
            guard let pane = makePane(PaneSeed(workingDirectory: snapshot?.workingDirectory,
                                               transcript: snapshot?.transcript)) else { continue }
            adopt(pane)
            remapped[id] = pane.id
            if let title = snapshot?.title, !title.isEmpty { titles[pane.id] = title }
        }
        guard let restored = tab.layout.tree(idFor: { remapped[$0] }) else {
            // Nothing came back. Whatever did start is shut down again rather than left running
            // with no way to see it.
            for pane in panes.values {
                pane.onExit = nil
                pane.terminate()
                pane.removeFromSuperview()
            }
            panes.removeAll()
            titles.removeAll()
            return false
        }
        tree = restored
        setFocus(tab.focused.flatMap { remapped[$0] } ?? restored.panes.first)
        return true
    }

    /// This tab's panes as a saved session records them. nil once the last pane has gone: an empty
    /// tree is not worth a tab in the file.
    func sessionSnapshot() -> (layout: PaneLayoutNode, panes: [PaneSnapshot], focused: Int?)? {
        guard let tree else { return nil }
        let layout = PaneLayoutNode(tree)
        let saved = layout.paneIDs.compactMap { id -> PaneSnapshot? in
            panes[PaneID(id)]?.sessionSnapshot(title: titles[PaneID(id)])
        }
        guard !saved.isEmpty else { return nil }
        return (layout, saved, focused?.value)
    }

    override var isFlipped: Bool { true }

    /// The panes themselves are the first responders; this view only ever holds them.
    override var acceptsFirstResponder: Bool { false }

    var focusedPane: Pane? { focused.flatMap { panes[$0] } }

    /// Used by menu validation: the pane-relative actions mean nothing with a single pane.
    var paneCount: Int { panes.count }

    /// Every live pane, in no particular order. For a caller that has to ask something of all of
    /// them at once -- closing a whole tab asks each whether it is busy.
    var allPanes: [Pane] { Array(panes.values) }

    func contains(paneID: Int) -> Bool { panes.values.contains { $0.id.value == paneID } }

    // MARK: - Layout

    private var modelBounds: PaneRect {
        PaneRect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
    }

    override func layout() {
        super.layout()
        relayout()
    }

    /// Assigns every pane its frame from the model. Setting a frame is what eventually resizes that
    /// pane's PTY: `Pane.layout()` recomputes its grid and calls `TerminalSession.resize`.
    private func relayout() {
        guard let tree else {
            dividers = []
            return
        }
        if let zoomed, let pane = panes[zoomed] {
            for (id, p) in panes { p.isHidden = id != zoomed }
            pane.frame = bounds
            dividers = []
        } else {
            let frames = tree.layout(in: modelBounds, dividerThickness: PaneTreeView.dividerThickness)
            for (id, pane) in panes {
                guard let f = frames[id] else { continue }
                pane.isHidden = false
                pane.frame = NSRect(x: f.x, y: f.y, width: f.width, height: f.height)
            }
            dividers = tree.dividers(in: modelBounds, dividerThickness: PaneTreeView.dividerThickness)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Panes

    private func adopt(_ pane: Pane) {
        pane.onTitleChange = { [weak self, id = pane.id] title in self?.titleChanged(id, title) }
        // `Pane` already hops to the main queue before calling this, so closing here is safe
        // whether or not the pane that exited was the focused one.
        pane.onExit = { [weak self, id = pane.id] _ in self?.close(id) }
        pane.onFocusRequested = { [weak self, id = pane.id] in self?.setFocus(id) }
        // The remote strip offers "⌘W to close", which closes the whole tab -- true only while this
        // pane is the tab's only one. Read through a closure rather than cached: a split can happen
        // under a remote pane at any moment.
        pane.isSolePaneInTab = { [weak self] in (self?.paneCount ?? 1) <= 1 }
        pane.onOutput = { [weak self] in self?.onAnyPaneOutput?() }
        pane.onBell = { [weak self] in self?.onAnyPaneBell?() }
        pane.onWorkingDirectoryChange = { [weak self, id = pane.id] directory in
            guard let self, self.focused == id else { return }
            self.onFocusedDirectoryChange?(directory)
        }
        panes[pane.id] = pane
        addSubview(pane)
    }

    /// Splits the focused pane, putting the new pane to its right (`.horizontal`) or below it
    /// (`.vertical`). Does nothing if the new pane cannot be created.
    func split(axis: SplitAxis) {
        guard let tree, let focused else { return }
        guard let pane = makePane(PaneSeed(workingDirectory: inheritableWorkingDirectory())) else { return }
        adopt(pane)
        self.tree = tree.splitting(focused, axis: axis, with: pane.id, ratio: 0.5)
        // A split has to be visible to be useful, so it ends any zoom.
        zoomed = nil
        setFocus(pane.id)
        relayout()
        onLayoutChange?()
    }

    func closeFocusedPane() {
        guard let focused else { return }
        close(focused)
    }

    /// Ends a pane's session and takes it out of the tree; the sibling subtree takes its space.
    /// Closing the last pane leaves the view empty and reports it.
    private func close(_ id: PaneID) {
        guard let pane = panes[id], let tree else { return }
        let successor = successor(after: id)
        pane.onTitleChange = nil
        pane.onExit = nil
        pane.onFocusRequested = nil
        pane.onOutput = nil
        pane.onBell = nil
        pane.terminate()
        pane.removeFromSuperview()
        panes[id] = nil
        titles[id] = nil
        if zoomed == id { zoomed = nil }
        // A drag in progress holds a `SplitPath`, and a path only means what it meant while the
        // tree keeps its shape: removing a pane collapses its parent split, so the captured path
        // can come to name a *different* split -- which the next drag event would then yank to the
        // pointer. Dropping the drag is the only safe answer; the mouse is still down, but the
        // divider it was holding may no longer exist.
        drag = nil
        guard let remaining = tree.removing(id) else {
            self.tree = nil
            focused = nil
            dividers = []
            onAllPanesClosed?()
            return
        }
        self.tree = remaining
        setFocus(successor ?? remaining.panes.first)
        relayout()
        onLayoutChange?()
    }

    /// Where focus goes when `id` closes: the nearest neighbour in any direction, preferring the
    /// one to the right. Closing an unfocused pane leaves focus where it is.
    private func successor(after id: PaneID) -> PaneID? {
        guard focused == id, let tree else { return focused }
        for direction: FocusDirection in [.right, .left, .down, .up] {
            if let n = tree.neighbour(of: id, direction: direction, in: modelBounds,
                                      dividerThickness: PaneTreeView.dividerThickness) {
                return n
            }
        }
        return nil
    }

    // MARK: - Focus

    func moveFocus(_ direction: FocusDirection) {
        guard let tree, let focused else { return }
        guard let next = tree.neighbour(of: focused, direction: direction, in: modelBounds,
                                        dividerThickness: PaneTreeView.dividerThickness) else { return }
        // Focus can only move to a pane the user can see, so leaving the zoomed pane unzooms.
        if zoomed != nil {
            zoomed = nil
            relayout()
        }
        setFocus(next)
    }

    /// Puts the keyboard back where it was. A tree taken out of the window while its tab is
    /// unselected loses the window's first responder along with it, so the tab that comes back has
    /// to claim it again -- and it claims it for the pane that had it, not for a fresh one.
    func restoreFocus() { setFocus(focused) }

    private func setFocus(_ id: PaneID?) {
        focused = id
        refreshFocusBorders()
        if let id, let pane = panes[id], window?.firstResponder !== pane {
            window?.makeFirstResponder(pane)
        }
        onFocusedTitleChange?(id.flatMap { titles[$0] } ?? "")
        // Focus moving between panes moves between directories too, and the project bar belongs to
        // the pane the user is looking at.
        if let directory = id.flatMap({ panes[$0]?.workingDirectory }) {
            onFocusedDirectoryChange?(directory)
        }
    }

    /// The focus border says *which* pane has focus, so it is worth nothing when there is only one
    /// pane to choose from -- a permanent cursor-coloured ring around the whole terminal is noise,
    /// not information. It appears with the first split and goes away again with the last close.
    private func refreshFocusBorders() {
        let wanted = panes.count > 1
        for (id, pane) in panes {
            pane.setFocusBorder(wanted && id == focused ? focusBorderColor : nil)
        }
    }

    private func titleChanged(_ id: PaneID, _ title: String) {
        titles[id] = title
        if id == focused { onFocusedTitleChange?(title) }
    }

    // MARK: - Resizing and zoom

    /// Moves the divider between the focused pane and its neighbour in `direction` by one step.
    func resizeFocused(_ direction: FocusDirection) {
        guard let tree, let focused else { return }
        self.tree = tree.resizing(focused, direction: direction, by: PaneTreeView.keyboardResizeStep)
        relayout()
    }

    /// Makes the focused pane fill the view, or restores the layout. The tree is never mutated:
    /// zoom only changes what gets laid out.
    func toggleZoom() {
        guard let focused, panes.count > 1 else { return }
        zoomed = zoomed == nil ? focused : nil
        relayout()
    }

    // MARK: - Configuration

    func apply(_ newConfig: Config) {
        config = newConfig
        for pane in panes.values { pane.apply(newConfig) }
        updateThemeColors()
    }

    private func updateThemeColors() {
        let palette = Pane.resolvedPalette(for: config)
        dividerColor = nsColor(palette.foreground, alpha: 0.2)
        focusBorderColor = nsColor(palette.cursor, alpha: 1)
        refreshFocusBorders()
        needsDisplay = true
    }

    /// The theme follows the system appearance whenever `dark:`/`light:` are set; `Pane` does the
    /// same for its own palette.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard config.darkThemeName != nil || config.lightThemeName != nil else { return }
        updateThemeColors()
    }

    /// Ends every session. The window controller calls this as its window closes.
    func terminate() {
        for pane in panes.values {
            pane.onExit = nil
            pane.terminate()
        }
    }

    // MARK: - Working directory

    /// What a new pane should inherit: the focused pane's OSC 7 directory, else the directory of
    /// the process running in it, else `$HOME`. Every step is best-effort -- a split must never
    /// fail because a directory could not be worked out.
    ///
    /// Not private: a new *tab* inherits by the same rule, and `TabController` asks the tree it is
    /// leaving for the answer rather than keeping a second copy of the rule.
    func inheritableWorkingDirectory() -> String {
        focusedPane?.workingDirectory ?? NSHomeDirectory()
    }

    // MARK: - Dividers
    //
    // A divider is not a view: it is the gap the layout leaves between two panes. This view claims
    // the mouse over that gap (and the few points either side of it that make it grabbable) in
    // `hitTest`, so the panes underneath never see those events.

    /// The divider being dragged and how far its centre was from the mouse when the drag began, so
    /// grabbing one slightly off-centre does not make it jump.
    private var drag: (divider: PaneDivider, grabOffset: Double)?

    private func divider(at point: NSPoint) -> PaneDivider? {
        guard zoomed == nil, let tree, bounds.contains(point) else { return nil }
        return tree.divider(atX: Double(point.x), y: Double(point.y), in: modelBounds,
                            dividerThickness: PaneTreeView.dividerThickness,
                            hitSlop: PaneTreeView.dividerHitSlop)
    }

    /// The band around a divider that the mouse can grab it by.
    private func hitRect(for divider: PaneDivider) -> NSRect {
        let r = NSRect(x: divider.rect.x, y: divider.rect.y, width: divider.rect.width, height: divider.rect.height)
        let slop = CGFloat(PaneTreeView.dividerHitSlop)
        switch divider.axis {
        case .horizontal: return NSRect(x: r.midX - slop / 2, y: r.minY, width: slop, height: r.height)
        case .vertical: return NSRect(x: r.minX, y: r.midY - slop / 2, width: r.width, height: slop)
        }
    }

    /// `point` arrives in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if divider(at: convert(point, from: superview)) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let divider = divider(at: p) {
            drag = (divider, dividerPosition(of: divider) - position(of: p, along: divider.axis))
            return
        }
        // A click can only reach this view where no pane is: focus whichever pane owns the point,
        // if any (a gap between two panes belongs to neither).
        if let tree, let id = tree.pane(atX: Double(p.x), y: Double(p.y), in: modelBounds,
                                        dividerThickness: PaneTreeView.dividerThickness) {
            setFocus(id)
        }
    }

    /// The ratio follows the mouse for the whole drag, so both panes -- and both shells -- resize
    /// live rather than on mouse-up.
    override func mouseDragged(with event: NSEvent) {
        guard let drag, let tree else { return }
        let p = convert(event.locationInWindow, from: nil)
        let centre = position(of: p, along: drag.divider.axis) + drag.grabOffset
        let ratio = PaneTree.ratio(forDividerCentre: centre, of: drag.divider,
                                   dividerThickness: PaneTreeView.dividerThickness)
        // The split's own bounds do not move while only its ratio changes, so the divider captured
        // at mouse-down stays valid for the whole drag.
        let updated = tree.settingRatio(ratio, at: drag.divider.path)
        guard updated != tree else { return }
        self.tree = updated
        relayout()
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    private func position(of point: NSPoint, along axis: SplitAxis) -> Double {
        axis == .horizontal ? Double(point.x) : Double(point.y)
    }

    private func dividerPosition(of divider: PaneDivider) -> Double {
        switch divider.axis {
        case .horizontal: return divider.rect.x + divider.rect.width / 2
        case .vertical: return divider.rect.y + divider.rect.height / 2
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for divider in dividers {
            addCursorRect(hitRect(for: divider), cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    // MARK: - Menu actions
    //
    // Reached through the responder chain: the focused `Pane` is the first responder and this view
    // is its superview, so a menu item with a nil target finds these.

    @objc func splitRight(_ sender: Any?) { split(axis: .horizontal) }
    @objc func splitDown(_ sender: Any?) { split(axis: .vertical) }
    @objc func focusLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func focusRight(_ sender: Any?) { moveFocus(.right) }
    @objc func focusUp(_ sender: Any?) { moveFocus(.up) }
    @objc func focusDown(_ sender: Any?) { moveFocus(.down) }
    @objc func growLeft(_ sender: Any?) { resizeFocused(.left) }
    @objc func growRight(_ sender: Any?) { resizeFocused(.right) }
    @objc func growUp(_ sender: Any?) { resizeFocused(.up) }
    @objc func growDown(_ sender: Any?) { resizeFocused(.down) }
    @objc func togglePaneZoom(_ sender: Any?) { toggleZoom() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        dividerColor.setFill()
        for divider in dividers {
            let r = NSRect(x: divider.rect.x, y: divider.rect.y, width: divider.rect.width, height: divider.rect.height)
            guard r.intersects(dirtyRect) else { continue }
            r.fill()
        }
    }
}

/// A theme colour as AppKit wants it. Shared with `TabBarView`, which draws in the same palette.
func nsColor(_ rgb: RGB, alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: alpha)
}

/// An AppKit colour as `NyxCore`'s contrast arithmetic wants it, resolved in whatever appearance is
/// current. Dynamic system colours have no components until they are resolved, so a caller has to
/// be inside `performAsCurrentDrawingAppearance` (or on screen) for this to mean anything.
func rgb(of color: NSColor) -> RGB {
    guard let resolved = color.usingColorSpace(.sRGB) else { return RGB(0, 0, 0) }
    return RGB(UInt8(max(0, min(255, resolved.redComponent * 255))),
               UInt8(max(0, min(255, resolved.greenComponent * 255))),
               UInt8(max(0, min(255, resolved.blueComponent * 255))))
}
