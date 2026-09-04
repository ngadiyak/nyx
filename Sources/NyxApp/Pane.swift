import AppKit
import Darwin
import Metal
import QuartzCore
import NyxCore
import NyxRender

enum NyxError: Error, LocalizedError {
    case noMetal
    var errorDescription: String? { "Metal is not available on this Mac." }
}

final class Pane: NSView, NSTextInputClient, NSMenuItemValidation {
    /// Identifies this pane in the `PaneTree` its `PaneTreeView` lays out. Allocated here rather
    /// than passed in so a `() -> Pane?` factory needs no knowledge of the tree's numbering.
    let id: PaneID

    var onTitleChange: ((String) -> Void)?
    /// Already delivered on the main queue: see the `session.onExit` wiring in `init`.
    var onExit: ((Int32) -> Void)?
    /// The user clicked in this pane. `PaneTreeView` turns it into a focus change; the pane itself
    /// only ever knows that it was clicked.
    var onFocusRequested: (() -> Void)?
    /// The session produced output, delivered on the main queue. The tab bar turns this into an
    /// activity dot for a tab that is not on screen; a pane the user is looking at just draws it.
    var onOutput: (() -> Void)?
    /// The program rang the bell, delivered on the main queue and independently of what
    /// `config.bell` does about it here.
    var onBell: (() -> Void)?
    /// The pane's working directory changed, on the main queue. Reported from the shell's own
    /// `OSC 7` where there is one, and from the process otherwise -- a `cd` in a shell with no
    /// integration is still a `cd`.
    var onWorkingDirectoryChange: ((String) -> Void)?

    /// Only ever touched on the main thread, where every pane is created.
    private static var nextID = 0

    private static func allocateID() -> PaneID {
        nextID += 1
        return PaneID(nextID)
    }

    private let session: TerminalSession
    private let renderer: Renderer
    private var fonts: FontSet
    /// The full configuration currently in force. Kept apart from the actual font size in use
    /// (`effectiveFontSize`) so ⌘+/⌘−/⌘0 can zoom independently of it: reloading the config after a
    /// zoom must not snap the size back to whatever the file says.
    private var config: Config
    /// Net zoom applied on top of `config.fontSize` by `zoomIn`/`zoomOut`; reset by `zoomReset`.
    private var zoomOffset: CGFloat = 0
    private var displayLink: CADisplayLink?
    private let dirty = AtomicFlag()
    /// The window is hidden behind another one or minimised: stop drawing entirely.
    private var isOccluded = false
    private var markedText = ""
    private var currentEvent: NSEvent?
    private var scrollAccumulator: CGFloat = 0
    private var cols = 80, rows = 24
    private var observers: [NSObjectProtocol] = []
    /// All the selection state; the view only feeds it cells. In absolute rows, so a selection
    /// survives scrolling and new output.
    private var selectionController = SelectionController()
    var selection: Selection? { selectionController.selection }
    /// The last mouse point of the drag, in view coordinates. Kept outside the bounds when the drag
    /// leaves the view so the display link can autoscroll towards it.
    private var lastMousePoint: NSPoint?
    private var motionTracking: NSTrackingArea?
    /// All the search state; every decision in it belongs to `NyxCore`. nil bar means ⌘F has not
    /// been pressed, and then the session is empty and nothing is highlighted.
    private var searchSession = SearchSession()
    private var searchBar: SearchBarView?
    /// What was selected when the bar opened, restored when `⎋` closes it.
    private var selectionBeforeSearch: Selection?
    /// A re-run of the open search against new output is already queued; see `scheduleSearchRefresh`.
    private var searchRefreshScheduled = false
    /// The status gutter down the left of the pane, inside its padding.
    private let gutter = PromptGutterView(frame: .zero)
    /// The command line pinned over the top row while its output fills the viewport.
    private let stickyStrip = StickyPromptView(frame: .zero)
    /// The prompt row the strip currently names, for its click.
    private var stickyPromptRow: Int?
    /// Which commands' output is collapsed. Empty for almost every pane that ever exists, which is
    /// what keeps the render path unchanged: every fold-aware branch is behind `isEmpty`.
    private var folding = OutputFolding()
    /// The buffer the folds belong to; a `clear` makes every absolute row mean something else.
    private var foldingGeneration: UInt64 = 0
    /// The last frame's display rows, so a click can tell which visible row is a fold placeholder
    /// and which command it stands for. Empty whenever nothing is folded.
    private var foldRowsOnScreen: [DisplayRow] = []
    /// Notices that a command ended, from nothing but the prompt marks; see `CommandWatcher`.
    private var commandWatcher = CommandWatcher()
    private var commandCheckScheduled = false

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Clamped the same way the old hardcoded zoom was (6...72pt), independent of the config's own
    /// 4...144 clamp, which bounds the *configured* value rather than the zoomed one.
    private var effectiveFontSize: CGFloat { min(max(CGFloat(config.fontSize) + zoomOffset, 6), 72) }
    private var padding: CGFloat { CGFloat(config.padding) }

    /// `workingDirectory` is what a new pane inherits from the one it was split off; it is ignored
    /// when the config names a directory of its own, which is an explicit instruction rather than
    /// a default.
    ///
    /// `restoringTranscript` is the ANSI a saved session left behind. It is fed **before**
    /// `session.start()`, which is the only moment at which nothing else can be writing to the
    /// terminal: feeding it afterwards would race the shell's first prompt and could interleave
    /// the two.
    init(_ frame: NSRect, config: Config, workingDirectory: String? = nil,
         restoringTranscript: String? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NyxError.noMetal }
        self.id = Pane.allocateID()
        self.config = config
        bindings = KeyBindingTable(user: config.keybinds)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        fonts = FontSet(family: config.fontFamily, pointSize: CGFloat(config.fontSize), scale: scale,
                        lineHeight: CGFloat(config.lineHeight),
                        baseFont: Pane.systemMonospacedFont(for: config.fontFamily))
        renderer = try Renderer(device: device, fonts: fonts)
        let palette = Pane.resolvedPalette(for: config)
        session = try TerminalSession(config: Pane.sessionConfig(for: config, cols: 80, rows: 24, palette: palette,
                                                                 inheriting: workingDirectory))
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        applyBackgroundAppearance()
        gutter.onSelectRow = { [weak self] row, alternate in
            self?.gutterClicked(atVisibleRow: row, alternate: alternate)
        }
        addSubview(gutter)
        stickyStrip.onClick = { [weak self] in self?.scrollToStickyPrompt() }
        addSubview(stickyStrip)
        session.withTerminal { $0.setDefaultCursorShape(config.cursorStyle); $0.modes.cursorBlink = config.cursorBlink }
        session.onUpdate = { [weak self] in self?.sessionDidUpdate() }
        session.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        session.onExit = { [weak self] code in DispatchQueue.main.async { self?.onExit?(code) } }
        if let restoringTranscript, !restoringTranscript.isEmpty {
            // The shell's own prompt then lands on a line of its own rather than on the end of
            // whatever the buffer was showing when it was saved.
            session.withTerminal { $0.feed(restoringTranscript); $0.feed("\r\n") }
        }
        session.start()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The user's login shell, or `config.shell`/`config.workingDirectory` when set. Only used at
    /// session creation: like `scrollback-lines`, a later change to either only takes effect for a
    /// new window (`ConfigDiff.deferredNotes` doesn't call this out today because the whole session
    /// -- not just these two settings -- would need recreating).
    private static func sessionConfig(for config: Config, cols: Int, rows: Int, palette: Palette,
                                      inheriting inherited: String?) -> SessionConfig {
        var cwd: String? = inherited
        if config.workingDirectory != "inherit", !config.workingDirectory.isEmpty {
            cwd = (config.workingDirectory as NSString).expandingTildeInPath
        }
        var sc = SessionConfig.loginShell(cols: cols, rows: rows, palette: palette, cwd: cwd,
                                          shellIntegration: config.shellIntegration)
        if let shell = config.shell, !shell.isEmpty {
            sc.shellPath = shell
            sc.argv = ["-" + (shell as NSString).lastPathComponent]
        }
        sc.scrollbackLimit = config.scrollbackLines
        return sc
    }

    /// Resolves `theme`/`dark:.../light:...` against the current system appearance, then applies
    /// `palette` overrides on top. Not private: `PaneTreeView` draws its dividers and focus border
    /// in theme colours and resolves them the same way.
    static func resolvedPalette(for config: Config) -> Palette {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name: String
        switch (config.darkThemeName, config.lightThemeName) {
        case let (dark?, light?): name = isDark ? dark : light
        case let (dark?, nil): name = isDark ? dark : config.themeName
        case let (nil, light?): name = isDark ? config.themeName : light
        case (nil, nil): name = config.themeName
        }
        var palette = Themes.palette(named: name)
        for (idx, rgb) in config.paletteOverrides where idx >= 0 && idx < palette.colors.count {
            palette.colors[idx] = rgb
        }
        return palette
    }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Accessibility
    //
    // A pane is a Metal layer: there is no text in the view hierarchy at all, so without this it
    // reaches VoiceOver as an unlabelled rectangle -- the terminal itself, the one thing in the
    // application anybody is actually here to read, silent.

    override func isAccessibilityElement() -> Bool { true }

    /// A text area rather than a group: what is in it is text, and the role is what decides whether
    /// a screen reader will read the value at all.
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityRoleDescription() -> String? { "terminal" }

    override func accessibilityLabel() -> String? {
        let title = fallbackTitle
        return title.isEmpty ? "Terminal" : "Terminal, \(title)"
    }

    /// What is on screen now, as plain text. Read on demand and never cached: it is the buffer, and
    /// the buffer changes on every keystroke.
    override func accessibilityValue() -> Any? {
        session.withTerminal { terminal in
            let top = terminal.viewportTopRow
            return terminal.transcript(rows: top..<(top + terminal.rows), options: .plainText)
        }
    }

    override func isAccessibilityEnabled() -> Bool { true }
    override var isOpaque: Bool { config.backgroundOpacity >= 1 && config.backgroundBlur <= 0 }

    var cellSizePoints: NSSize {
        NSSize(width: CGFloat(fonts.metrics.width) / fonts.scale, height: CGFloat(fonts.metrics.height) / fonts.scale)
    }

    /// Where a pane split off this one should start: the directory the shell last announced with
    /// OSC 7, else the working directory of whatever process is in the foreground, else the shell's
    /// own. Every step is best-effort and nil is a perfectly good answer -- the caller falls back
    /// to `$HOME` rather than refusing to split.
    var workingDirectory: String? {
        if let cwd = session.withTerminal({ $0.cwd }), !cwd.isEmpty { return cwd }
        if let pgid = session.foregroundProcessGroup, let path = Pane.processWorkingDirectory(pgid) { return path }
        return Pane.processWorkingDirectory(session.pid)
    }

    /// The shell this pane started, for `proc_listchildpids`.
    var processID: pid_t { session.pid }

    /// The name of the program the user is actually looking at -- the shell unless it is running
    /// something -- for the tab title. nil if it cannot be read.
    var foregroundProcessName: String? {
        guard let pgid = session.foregroundProcessGroup else { return nil }
        return Pane.processName(pgid)
    }

    /// The tab title to fall back on when nothing has set one with OSC 0/2.
    var fallbackTitle: String {
        TabTitle.fallback(processName: foregroundProcessName, directory: workingDirectory,
                          home: NSHomeDirectory())
    }

    /// The short name of a running process, e.g. `zsh` or `vim`.
    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let read = proc_name(pid, &buffer, UInt32(buffer.count))
        guard read > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    /// The current directory of a running process, or nil if it cannot be read (it is gone, or it
    /// belongs to another user -- neither is worth reporting).
    private static func processWorkingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, UnsafeMutableRawPointer($0), size)
        }
        guard read == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    func size(forCols c: Int, rows r: Int) -> NSSize {
        NSSize(width: cellSizePoints.width * CGFloat(c) + padding * 2, height: cellSizePoints.height * CGFloat(r) + padding * 2)
    }

    /// Rebuilds whatever changed and leaves the session running; called by `TerminalWindowController`
    /// after every `ConfigStore` reload. The view keeps its own `config` and diffs against the new
    /// one so an unrelated change -- e.g. `bell`, read only at the point of use -- never rebuilds the
    /// font atlas or touches the palette.
    func apply(_ newConfig: Config) {
        let diff = ConfigDiff(from: config, to: newConfig)
        config = newConfig
        // Rebuilt unconditionally: `ConfigDiff` tracks what has to be *redrawn*, and a changed
        // binding changes nothing on screen, so there is no diff flag to hang this on.
        bindings = KeyBindingTable(user: newConfig.keybinds)

        if diff.cursorChanged {
            session.withTerminal { t in
                t.setDefaultCursorShape(config.cursorStyle)
                t.modes.cursorBlink = config.cursorBlink
            }
            markDirty()
        }
        // `fontChanged` needs a new `FontSet` (glyph atlas and all); `geometryChanged` alone --
        // `padding` -- only moves where the existing grid sits, so it's cheaper to recompute just
        // the grid than to rebuild the atlas for a setting that never touched a glyph. `rebuildFonts`
        // already ends by recomputing the grid, so a change to both still does the atlas work once.
        if diff.fontChanged {
            rebuildFonts()
        } else if diff.geometryChanged {
            updateGrid()
        }
        if diff.paletteChanged {
            applyPalette()
            let palette = Pane.resolvedPalette(for: config)
            searchBar?.apply(palette: palette)
        }
        if diff.windowAppearanceChanged {
            applyBackgroundAppearance()
            markDirty()
        }
        // `padding` decides how much room the gutter has, so it is re-measured after any change.
        layoutGutter()
    }

    private func applyPalette() {
        let palette = Pane.resolvedPalette(for: config)
        session.withTerminal { $0.palette = palette }
        markDirty()
    }

    /// The blur behind the window (`TerminalWindowController`'s `NSVisualEffectView`) only shows
    /// through wherever this layer itself draws at less than full opacity -- a `background-blur`
    /// setting with `background-opacity` left at its default of 1 would otherwise be invisible, an
    /// opaque layer fully covering it. So `background-blur > 0` implies at least a default amount of
    /// translucency; an explicit `background-opacity` below that still wins.
    private static let defaultTranslucencyWithBlur = 0.9

    private func applyBackgroundAppearance() {
        let opacity = config.backgroundBlur > 0
            ? min(config.backgroundOpacity, Pane.defaultTranslucencyWithBlur)
            : config.backgroundOpacity
        metalLayer.isOpaque = opacity >= 1
        metalLayer.opacity = Float(opacity)
    }

    /// Draws (or clears) the focus ring `PaneTreeView` puts around the focused pane. It is a layer
    /// border rather than something drawn by the parent view, because the pane's own Metal layer
    /// covers every point of its frame -- anything the parent drew there would be hidden. The
    /// border lands inside the terminal's padding, so it never covers a cell.
    func setFocusBorder(_ color: NSColor?) {
        metalLayer.borderWidth = color == nil ? 0 : 1
        metalLayer.borderColor = color?.cgColor
    }

    /// The theme follows the system appearance whenever `dark:`/`light:` are both set.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard config.darkThemeName != nil || config.lightThemeName != nil else { return }
        applyPalette()
    }

    func terminate() {
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        session.terminate()
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard let window else { return }
        // Sync the occlusion state from the new window; stale occlusion from a previous window
        // breaks resumeLink() when a pane moves between windows until AppKit posts a notification.
        isOccluded = !(window.occlusionState.contains(.visible))
        updateScale()
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.focusChanged(true) })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.focusChanged(false) })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.occlusionChanged() })
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func layout() {
        super.layout()
        updateGrid()
        layoutSearchBar()
        layoutGutter()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        if scale != fonts.scale { rebuildFonts() }
        updateGrid()
    }

    private func rebuildFonts() {
        let scale = window?.backingScaleFactor ?? fonts.scale
        fonts = FontSet(family: config.fontFamily, pointSize: effectiveFontSize, scale: scale,
                        lineHeight: CGFloat(config.lineHeight),
                        baseFont: Pane.systemMonospacedFont(for: config.fontFamily))
        renderer.setFonts(fonts)
        window?.contentResizeIncrements = cellSizePoints
        updateGrid()
    }

    private func updateGrid() {
        let scale = metalLayer.contentsScale
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return }
        metalLayer.drawableSize = CGSize(width: w, height: h)
        let pad = Int(padding * scale)
        let c = max(2, (w - pad * 2) / fonts.metrics.width)
        let r = max(1, (h - pad * 2) / fonts.metrics.height)
        if c != cols || r != rows {
            cols = c
            rows = r
            session.resize(cols: c, rows: r)
        }
        session.withTerminal { $0.pixelSize = (c * fonts.metrics.width, r * fonts.metrics.height) }
        // The strip is one terminal row tall, so it moves with the grid rather than with the view:
        // a font change resizes it without the bounds changing at all.
        layoutStickyStrip()
        markDirty()
    }

    private func focusChanged(_ focused: Bool) {
        let wants = session.withTerminal { $0.modes.focusEvents }
        if wants { session.send(Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)) }
        markDirty()
    }

    // MARK: - Rendering
    //
    // The display link is only allowed to run while there is something to draw. A tick that finds
    // the dirty flag clear pauses it, and every producer of new content calls `markDirty()`, which
    // sets the flag and then unpauses on the main thread. Both halves of that handshake run on the
    // main thread, so a wake-up can never be lost: the pause and the unpause are serialised by the
    // main queue, and whichever runs second leaves the link running with the flag still set.

    /// The session read something from the PTY, on the reader thread. Same handshake as
    /// `markDirty()`, plus the `onOutput` report -- which is deliberately *not* in `markDirty()`,
    /// where a relayout or a config reload would look like the program had said something.
    private func sessionDidUpdate() {
        dirty.set()
        if Thread.isMainThread {
            outputArrived()
        } else {
            DispatchQueue.main.async { [weak self] in self?.outputArrived() }
        }
    }

    private func outputArrived() {
        onOutput?()
        scheduleSearchRefresh()
        scheduleCommandCheck()
        resumeLink()
    }

    /// The directory last reported, so an unchanged one costs nothing and a project file is not
    /// re-read on every prompt.
    private var lastReportedDirectory: String?

    private func reportWorkingDirectory(_ path: String) {
        guard !path.isEmpty, path != lastReportedDirectory else { return }
        lastReportedDirectory = path
        onWorkingDirectoryChange?(path)
    }

    /// Re-reads the directory from the process when the shell does not announce one. Called from
    /// the same coalesced check that notices a command finished -- which is exactly when a `cd`
    /// has just happened -- rather than on a timer of its own.
    private func checkWorkingDirectory() {
        guard let directory = workingDirectory else { return }
        reportWorkingDirectory(directory)
    }

    /// Marks the frame stale from any thread and wakes the display link.
    private func markDirty() {
        dirty.set()
        if Thread.isMainThread {
            resumeLink()
        } else {
            DispatchQueue.main.async { [weak self] in self?.resumeLink() }
        }
    }

    private func resumeLink() {
        guard !isOccluded else { return }
        displayLink?.isPaused = false
    }

    private func occlusionChanged() {
        isOccluded = !(window?.occlusionState.contains(.visible) ?? true)
        if isOccluded {
            displayLink?.isPaused = true
        } else {
            markDirty()   // the flag may have accumulated changes while we were hidden
        }
    }

    @objc private func tick() {
        autoscroll()
        if dirty.takeAndClear() { render() } else { displayLink?.isPaused = true }
    }

    private func render() {
        let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
        let preedit = markedText.isEmpty ? nil : markedText
        var gutterMarks: [GutterMark?] = []
        var notes: [String?] = []
        var spines: [(rows: Range<Int>, color: RGB)] = []
        var summaries: [(row: Int, text: String, color: RGB)] = []
        var sticky: (text: String, failed: Bool, row: Int)?
        let frame: RenderFrame = session.withTerminal { t in
            // Before anything reads the selection: a cleared scrollback, a reset or an
            // alternate-screen swap leaves it pointing at rows that now hold other content.
            selectionController.invalidateIfStale(t)
            // The selection is not the only thing addressed in absolute rows. Search matches
            // survived a `clear`, so the highlights painted over unrelated text, the readout went
            // on claiming a count, and stepping selected -- then copied -- text nobody searched
            // for. A hovered link had the same shape. Both cost one comparison when nothing moved.
            searchSession.invalidateIfStale(in: t, viewportTop: t.viewportTopRow)
            if hoveredLinkGeneration != t.scrollbackGeneration {
                hoveredLinkGeneration = t.scrollbackGeneration
                hoveredLink = nil
            }
            // A fold is an absolute row, and a `clear` makes every absolute row mean something
            // else; keeping them would collapse whatever landed on those indices.
            if self.foldingGeneration != t.scrollbackGeneration {
                self.foldingGeneration = t.scrollbackGeneration
                self.folding.unfoldAll()
            }
            // Folds whose prompt has gone -- evicted from the ring, or overwritten -- are dropped
            // here rather than accumulating over a session. Costs one row read per fold, and
            // nothing at all when there are none.
            if !self.folding.isEmpty { self.folding.prune(in: t) }
            let cursor: Cursor? = (t.modes.showCursor && t.viewportOffset == 0) ? t.screen.cursor : nil
            // Resolved here, inside the lock, so the highlighted columns belong to the same
            // viewport as the lines being drawn.
            let top = t.viewportTopRow
            let lines: [Row]
            let selected: [Range<Int>?]
            let matches: [[Range<Int>]]
            let current: [Range<Int>?]
            let hovered: [Range<Int>?]
            if self.folding.isEmpty {
                // Untouched: no fold means no buffer walk, no mapping and no allocation beyond the
                // rows themselves. This is the path every frame of an ordinary session takes.
                self.foldRowsOnScreen = []
                lines = (0..<t.rows).map { t.viewportRow($0) }
                selected = (0..<t.rows).map { self.selection?.columnRange(onRow: top + $0, cols: t.cols) }
                matches = SearchHighlights.visibleRanges(self.searchSession.matches, viewportTop: top,
                                                        rows: t.rows, cols: t.cols)
                current = SearchHighlights.visibleRange(of: self.searchSession.current, viewportTop: top,
                                                        rows: t.rows, cols: t.cols)
                hovered = SearchHighlights.visibleRange(onAbsoluteRow: self.hoveredLink?.row ?? 0,
                                                        columns: self.hoveredLink?.columns,
                                                        viewportTop: top, rows: t.rows, cols: t.cols)
            } else {
                // A folded viewport is not a contiguous run of absolute rows, so everything indexed
                // by visible row has to be placed through the display rows rather than by
                // subtracting the viewport top -- otherwise a highlight lands on whichever row the
                // fold pulled up into that slot.
                let display = t.displayRows(from: top, count: t.rows, folding: self.folding)
                self.foldRowsOnScreen = display
                lines = display.map { row in
                    switch row {
                    case .row(let absolute): return t.absoluteRow(absolute) ?? Row(cols: t.cols)
                    case .fold(_, let hidden): return t.foldPlaceholderRow(hiddenRows: hidden)
                    }
                } + Array(repeating: Row(cols: t.cols), count: max(0, t.rows - display.count))
                selected = display.map { row in
                    guard case .row(let absolute) = row else { return nil }
                    return self.selection?.columnRange(onRow: absolute, cols: t.cols)
                } + Array(repeating: nil, count: max(0, t.rows - display.count))
                matches = SearchHighlights.visibleRanges(self.searchSession.matches,
                                                        displayRows: display, cols: t.cols)
                    + Array(repeating: [], count: max(0, t.rows - display.count))
                current = SearchHighlights.visibleRange(onAbsoluteRow: self.searchSession.current?.row ?? 0,
                                                        columns: self.searchSession.current?.columns,
                                                        displayRows: display, cols: t.cols)
                    + Array(repeating: nil, count: max(0, t.rows - display.count))
                hovered = SearchHighlights.visibleRange(onAbsoluteRow: self.hoveredLink?.row ?? 0,
                                                        columns: self.hoveredLink?.columns,
                                                        displayRows: display, cols: t.cols)
                    + Array(repeating: nil, count: max(0, t.rows - display.count))
            }
            // Read here rather than on a timer: one cheap pass over the visible rows, and it is
            // guaranteed to describe the same viewport as the frame being drawn.
            // Everything below is indexed by *screen* row. With a fold on screen the viewport is
            // not a contiguous run of absolute rows, so each has to be placed through the display
            // map -- the same one the text goes through. Getting this wrong puts a status mark, a
            // duration or a spine beside whichever row the fold happened to pull into that slot,
            // and clicking a spine *creates* a fold, so the feature would misplace its own chrome
            // the first time anyone used it.
            let screenRow: (Int) -> Int? = { [foldRowsOnScreen] absolute in
                guard !foldRowsOnScreen.isEmpty else {
                    let index = absolute - max(0, t.viewportTopRow)
                    return (0..<t.rows).contains(index) ? index : nil
                }
                return foldRowsOnScreen.firstIndex { if case .row(absolute) = $0 { return true } else { return false } }
            }

            gutterMarks = Pane.place(t.gutterMarks(rows: t.rows), from: max(0, t.viewportTopRow),
                                     rows: t.rows, screenRow: screenRow)
            notes = Pane.place(t.durationNotes(rows: t.rows), from: max(0, t.viewportTopRow),
                               rows: t.rows, screenRow: screenRow)
            // Blocks are chrome over an unmodified grid, so they step aside entirely when a
            // full-screen program owns the display or the mouse. This is the rule that keeps vim,
            // htop and tmux behaving exactly as they did.
            let blocks = CommandBlockChrome.isAllowed(altScreen: t.modes.altScreen,
                                                  mouseReporting: t.modes.mouse != .none,
                                                  hasMarks: t.shellEmitsPromptMarks)
                ? t.visibleBlocks(rows: t.rows) : []
            // The three block colours, once per frame. `readable` picks between a colour and its
            // bright variant by contrast against the background -- a handful of Lab conversions --
            // and evaluating it per block, per frame, put that on the render path for nothing: the
            // palette cannot change between two blocks of the same frame.
            let failedColor = t.palette.readable(1)
            let runningColor = t.palette.readable(3)
            let doneColor = t.palette.readable(2)
            spines = blocks.compactMap { block -> (rows: Range<Int>, color: RGB)? in
                // The prompt you are typing at has not run anything; the gutter already decided a
                // running command draws nothing, and a spine that says "in progress" beside an idle
                // prompt would sit there amber forever.
                guard block.region.outputStart != nil else { return nil }
                let placed = block.visibleRows.compactMap { screenRow($0 + max(0, t.viewportTopRow)) }
                guard let first = placed.min(), let last = placed.max() else { return nil }
                return (rows: first..<(last + 1),
                        color: block.failed ? failedColor : (block.isRunning ? runningColor : doneColor))
            }
            // A summary only where the command it describes is on screen, and only when it has
            // something to say -- `exit 0` on a command that took no time is not news.
            summaries = blocks.compactMap { block -> (row: Int, text: String, color: RGB)? in
                guard block.showsHeader, let row = screenRow(block.region.promptRow) else { return nil }
                let text = block.summary()
                guard !text.isEmpty else { return nil }
                return (row: row, text: text,
                        color: block.failed ? failedColor : t.palette.noteForeground)
            }
            // The summary already carries the duration, and both draw right-aligned on the command's
            // row: left alone they paint the same glyphs twice in two colours, on the failure case
            // this feature exists to make obvious.
            for summary in summaries where notes.indices.contains(summary.row) {
                notes[summary.row] = nil
            }
            // Same pass, same lock, same viewport: the strip names the command whose output is on
            // screen *in this frame*, and reading it anywhere else would let the two disagree.
            // Costs one flag test for a shell with no integration, which is the whole reason
            // `shellEmitsPromptMarks` exists.
            if let pinned = t.stickyPrompt(), let region = t.command(containingAbsoluteRow: pinned.row) {
                sticky = (StickyPromptLabel.text(command: t.commandText(of: region),
                                                 exitStatus: pinned.exitStatus, columns: t.cols),
                          pinned.failed, pinned.row)
            }
            // A missing drawable is transient. On failure, re-setting dirty will repaint rows
            // already marked clean; once per-row partial redraw lands, fix both here and there.
            t.clearDirty()
            return RenderFrame(cols: t.cols, rows: t.rows, lines: lines, graphemes: t.graphemes, palette: t.palette,
                               cursor: cursor, cursorShape: t.cursorShape, focused: focused, preedit: preedit,
                               selection: selected, searchMatches: matches, currentSearchMatch: current,
                               hoveredLink: hovered, rowNotes: notes, blockSpines: spines,
                               blockSummaries: summaries)
        }
        gutter.update(marks: gutterMarks, palette: frame.palette,
                      cellHeight: cellSizePoints.height, topPadding: padding)
        stickyPromptRow = sticky?.row
        let wasHidden = stickyStrip.isHidden
        stickyStrip.update(text: sticky?.text, failed: sticky?.failed ?? false, palette: frame.palette,
                           font: .monospacedSystemFont(ofSize: effectiveFontSize, weight: .regular))
        // The strip claims the pointer only while it is up, so appearing or disappearing changes
        // which view the cursor over the top row belongs to.
        if wasHidden != stickyStrip.isHidden { window?.invalidateCursorRects(for: stickyStrip) }
        // A missing drawable is transient; keep the frame stale so the next tick retries rather
        // than pausing the link on top of stale pixels.
        if !renderer.draw(frame, in: metalLayer, padding: Int(padding * metalLayer.contentsScale)) { dirty.set() }
    }

    // MARK: - Events from the terminal

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .titleChanged(let t): onTitleChange?(t)
        case .bell:
            onBell?()
            switch config.bell {
            case .visual: flashBell()
            case .sound: NSSound.beep()
            case .none: break
            }
        case .clipboardWrite(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .colorsChanged: markDirty()
        case .cwdChanged(let path): reportWorkingDirectory(path)
        case .notification: break
        }
    }

    /// A brief white flash over the terminal content, removed once the animation finishes.
    private func flashBell() {
        let flash = CALayer()
        flash.frame = metalLayer.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0.25
        metalLayer.addSublayer(flash)
        CATransaction.begin()
        CATransaction.setCompletionBlock { flash.removeFromSuperlayer() }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.25
        anim.toValue = 0
        anim.duration = 0.15
        flash.opacity = 0
        flash.add(anim, forKey: "flash")
        CATransaction.commit()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // A chord bound to an action never reaches the shell. Most bindings are also menu key
        // equivalents, which AppKit consumes before `keyDown` is ever called; this path is what
        // makes a binding work when the config names a chord the menu cannot express.
        if let ke = keyEvent(from: event),
           let action = bindings.action(for: ke.key, modifiers: ke.modifiers),
           let target = actionTarget, target.canPerform(action) {
            target.perform(action)
            return
        }
        currentEvent = event
        defer { currentEvent = nil }
        if !(inputContext?.handleEvent(event) ?? false) { sendKey(event) }
    }

    /// Rebuilt from the config on every reload, so a new `keybind` line takes effect without a
    /// restart. Defaults are included, with the user's lines layered on top.
    private var bindings: KeyBindingTable

    private func keyEvent(from e: NSEvent) -> KeyEvent? {
        var mods: KeyModifiers = []
        let f = e.modifierFlags
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.control) { mods.insert(.ctrl) }
        if f.contains(.option) { mods.insert(.alt) }
        if f.contains(.command) { mods.insert(.cmd) }
        let key: Key
        switch e.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 115: key = .home
        case 119: key = .end
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 117: key = .delete
        case 114: key = .insert
        case 51: key = .backspace
        case 48: key = .tab
        case 36, 76: key = .enter
        case 53: key = .escape
        case 122: key = .f(1)
        case 120: key = .f(2)
        case 99: key = .f(3)
        case 118: key = .f(4)
        case 96: key = .f(5)
        case 97: key = .f(6)
        case 98: key = .f(7)
        case 100: key = .f(8)
        case 101: key = .f(9)
        case 109: key = .f(10)
        case 103: key = .f(11)
        case 111: key = .f(12)
        default:
            guard let chars = e.charactersIgnoringModifiers, let s = chars.unicodeScalars.first else { return nil }
            key = .char(s)
        }
        return KeyEvent(key: key, modifiers: mods, text: e.characters)
    }

    /// `KeyEncoderOptions.optionAsMeta` is a plain bool -- it doesn't distinguish which side of the
    /// keyboard was held -- so `.left` and `.right` both act like `.both` here rather than silently
    /// doing nothing; only `.none` turns it off.
    private var optionActsAsMeta: Bool { config.optionAsMeta != .none }

    private func sendKey(_ e: NSEvent) {
        guard let ke = keyEvent(from: e) else { return }
        let opts = session.withTerminal {
            KeyEncoderOptions(cursorKeysApp: $0.modes.cursorKeysApp, optionAsMeta: optionActsAsMeta)
        }
        if let bytes = KeyEncoder.encode(ke, options: opts) { send(bytes) }
    }

    /// Writes bytes to the shell as though the user had typed them. Not private because a quick
    /// action is exactly "type this for me".
    func send(_ bytes: [UInt8]) {
        // Typing both jumps the viewport back to the live screen and drops the selection: the text
        // it pointed at is about to move, and every terminal drops it here.
        clearSelection()
        session.withTerminal { $0.scrollViewportToBottom() }
        session.send(bytes)
        markDirty()
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        if let e = currentEvent, e.modifierFlags.contains(.control) || (optionActsAsMeta && e.modifierFlags.contains(.option)) {
            sendKey(e)
            markDirty()
            return
        }
        send(Array(text.utf8))
    }

    override func doCommand(by selector: Selector) {
        if let e = currentEvent { sendKey(e) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markDirty()
    }

    func unmarkText() {
        markedText = ""
        markDirty()
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cursor = session.withTerminal { $0.screen.cursor }
        let cell = cellSizePoints
        let rect = NSRect(x: padding + CGFloat(cursor.x) * cell.width,
                          y: bounds.height - padding - CGFloat(cursor.y + 1) * cell.height,
                          width: cell.width, height: cell.height)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Hit testing

    /// A view point re-measured from the top-left of the view, which is what `PointerMap` wants;
    /// this view is not flipped, so its own origin is at the bottom.
    private func topLeft(_ p: NSPoint) -> (x: Double, y: Double) {
        (Double(p.x), Double(bounds.height - p.y))
    }

    private func position(_ p: (x: Double, y: Double), in t: Terminal) -> AbsolutePosition {
        let cell = cellSizePoints
        let hit = PointerMap.position(x: p.x, y: p.y, cellWidth: Double(cell.width), cellHeight: Double(cell.height),
                                      padding: Double(padding), viewportTop: t.viewportTopRow,
                                      cols: t.cols, totalRows: t.totalRows)
        // `PointerMap` counts rows down from the viewport top, which stops being the same thing as
        // counting absolute rows the moment something is folded: the rows under the pointer are
        // whatever the folds left on screen.
        guard !folding.isEmpty,
              let absolute = absoluteRow(forVisibleRow: hit.row - t.viewportTopRow, in: t)
        else { return hit }
        return AbsolutePosition(row: absolute, col: hit.col)
    }

    private func mouseModifiers(_ e: NSEvent) -> KeyModifiers {
        var mods: KeyModifiers = []
        if e.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if e.modifierFlags.contains(.control) { mods.insert(.ctrl) }
        if e.modifierFlags.contains(.option) { mods.insert(.alt) }
        return mods
    }

    // MARK: - Mouse reporting
    //
    // Option held is the standard override: it hands the event back to the terminal so text can be
    // selected inside a full-screen program that has taken the mouse.

    /// Reports the event to the application. Returns true when the application has the mouse, which
    /// it does whether or not this particular event produced bytes: a `normal`-mode program that
    /// ignores drags must still not have those drags turn into a selection behind its back.
    @discardableResult
    private func report(_ event: NSEvent, _ button: MouseButton, _ action: MouseAction) -> Bool {
        guard !event.modifierFlags.contains(.option) else { return false }
        let (mode, sgr) = session.withTerminal { ($0.modes.mouse, $0.modes.mouseSGR) }
        guard mode != .none else { return false }
        let cell = reportCell(event)
        let e = MouseEvent(button: button, action: action, col: cell.col, row: cell.row,
                           modifiers: mouseModifiers(event))
        if let bytes = MouseEncoder.encode(e, mode: mode, sgr: sgr) { session.send(bytes) }
        return true
    }

    private func reportCell(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = topLeft(convert(event.locationInWindow, from: nil)), cell = cellSizePoints
        return PointerMap.reportCell(x: p.x, y: p.y, cellWidth: Double(cell.width), cellHeight: Double(cell.height),
                                     padding: Double(padding), cols: cols, rows: rows)
    }

    /// One tracking area, always on. It used to follow the mouse mode, because bare motion is only
    /// worth *reporting* in `any` mode; hovering a link needs the same events whatever the program
    /// is doing, and `mouseMoved` decides which of the two a given event is for.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard motionTracking == nil else { return }   // `.inVisibleRect` keeps the existing area in step
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        motionTracking = area
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocusRequested?()
        // ⌘-click opens whatever is under the pointer, before the click can become a selection or
        // be handed to a program that has taken the mouse.
        if event.modifierFlags.contains(.command), openLink(at: event) { return }
        // A fold placeholder is a button, not text: clicking it puts the output back. Checked
        // before mouse reporting, because a fold only exists while the user is reading scrollback.
        if unfoldPlaceholder(at: convert(event.locationInWindow, from: nil)) { return }
        if report(event, .left, .press) { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        let point = topLeft(lastMousePoint!)
        let block = event.modifierFlags.contains(.option)
        let changed = session.withTerminal { t in
            selectionController.begin(at: position(point, in: t), clickCount: event.clickCount, block: block, in: t,
                                      separators: config.wordSeparators)
        }
        if changed { markDirty() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard selectionController.isDragging else { report(event, .left, .drag); return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        let point = topLeft(lastMousePoint!)
        let changed = session.withTerminal { t in
            selectionController.drag(to: position(point, in: t), in: t, separators: config.wordSeparators)
        }
        if changed { markDirty() }
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionController.isDragging else { report(event, .left, .release); return }
        lastMousePoint = nil
        let wasEmpty = selection == nil || selection?.isEmpty == true
        if selectionController.end() { markDirty() }
        if config.copyOnSelect, selection != nil { copy(nil) }
        // The spine is a target: clicking it folds the block, which is what a bar drawn beside a
        // command's rows is inviting. Checked before the caret move, since the spine is in the
        // padding and no caret can live there.
        if wasEmpty, event.clickCount == 1, foldBlock(atPointInPadding: convert(event.locationInWindow, from: nil)) {
            return
        }
        // A click that selected nothing is a click, not a drag. On the command line that means
        // "put the caret here" -- which is how anyone expects to fix one value in the middle of a
        // pasted `curl`, rather than holding an arrow key.
        if wasEmpty, event.clickCount == 1 {
            moveShellCaret(to: convert(event.locationInWindow, from: nil))
        }
    }

    /// Folds or unfolds the block whose spine was clicked. Returns whether the click was on one.
    ///
    /// Only in the left padding: inside the text a click means the caret or a selection, and a
    /// gesture that means two things depending on a few pixels is a gesture people stop trusting.
    private func foldBlock(atPointInPadding point: NSPoint) -> Bool {
        guard point.x < CGFloat(padding) else { return false }
        let promptRow: Int? = session.withTerminal { t in
            guard CommandBlockChrome.isAllowed(altScreen: t.modes.altScreen,
                                               mouseReporting: t.modes.mouse != .none,
                                               hasMarks: t.shellEmitsPromptMarks) else { return nil }
            let position = self.position(topLeft(point), in: t)
            return t.block(atAbsoluteRow: position.row, rows: t.rows)?.region.promptRow
        }
        guard let promptRow else { return false }
        folding.toggle(promptRow: promptRow)
        markDirty()
        return true
    }

    /// Moves the shell's caret to a clicked cell by sending the arrow keys that get it there.
    ///
    /// A terminal cannot place another program's cursor; all it can do is press the keys the user
    /// would have pressed. With shell integration the distance is exactly known -- the offset of
    /// the click within the command line, minus the offset the caret is at -- so this is precise
    /// rather than a guess, and it works through a line that has wrapped.
    ///
    /// Does nothing without marks, while a command is running, or on a click that is not on the
    /// command line: in all of those there is no caret to move and arrows would do something else.
    private func moveShellCaret(to point: NSPoint) {
        let steps: Int? = session.withTerminal { terminal in
            guard terminal.modes.mouse == .none else { return nil }   // a TUI owns its own clicks
            let position = self.position(topLeft(point), in: terminal)
            guard let target = terminal.inputOffset(atAbsoluteRow: position.row, column: position.col),
                  let caret = terminal.currentInputCursorOffset else { return nil }
            return target - caret
        }
        guard let steps, steps != 0 else { return }
        let arrow: [UInt8] = steps > 0 ? [0x1B, 0x5B, 0x43] : [0x1B, 0x5B, 0x44]   // CSI C / CSI D
        var bytes: [UInt8] = []
        bytes.reserveCapacity(abs(steps) * 3)
        for _ in 0..<abs(steps) { bytes += arrow }
        send(bytes)
    }

    override func mouseMoved(with event: NSEvent) {
        // Only `any` mode wants bare motion; every other mode would discard it, and the tracking
        // area is on regardless now because hovering a link needs the same events.
        if session.withTerminal({ $0.modes.mouse == .any }) { report(event, .left, .move) }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    /// A TUI that turned mouse reporting on gets the right button, as it does the left. Only when
    /// nothing is listening does the click become a context menu -- otherwise right-click would
    /// stop working inside vim and htop the moment we added one.
    override func rightMouseDown(with event: NSEvent) {
        if report(event, .right, .press) { return }
        NSMenu.popUpContextMenu(contextMenu(at: convert(event.locationInWindow, from: nil)),
                                with: event, for: self)
    }
    override func rightMouseDragged(with event: NSEvent) { report(event, .right, .drag) }
    override func rightMouseUp(with event: NSEvent) { report(event, .right, .release) }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        report(event, .middle, .press)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        report(event, .middle, .drag)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        if report(event, .middle, .release) { return }
        if config.middleClickPaste { paste(nil) }
    }

    private func clearSelection() {
        if selectionController.clear() { markDirty() }
        lastMousePoint = nil
    }

    /// While a drag is held outside the view, scroll one line per frame and keep extending. Driven
    /// from the display link rather than a timer because AppKit stops sending drags once the mouse
    /// stops moving, and because it puts the scroll on the same clock as the redraw it causes.
    private func autoscroll() {
        guard selectionController.isDragging, let point = lastMousePoint else { return }
        let lines = point.y > bounds.maxY ? 1 : (point.y < bounds.minY ? -1 : 0)
        guard lines != 0 else { return }
        let head = topLeft(point)
        let changed = session.withTerminal { t -> Bool in
            let before = t.viewportOffset
            t.scrollViewport(by: lines)
            guard t.viewportOffset != before else { return false }
            return selectionController.drag(to: position(head, in: t), in: t, separators: config.wordSeparators)
        }
        if changed { markDirty() }
    }

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        let cellHeight = cellSizePoints.height
        var lines: Int
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            lines = Int(scrollAccumulator / cellHeight)
            scrollAccumulator -= CGFloat(lines) * cellHeight
        } else {
            lines = Int(event.scrollingDeltaY.rounded(.awayFromZero)) * 3
        }
        guard lines != 0 else { return }
        let (alt, app, mouse, sgr) = session.withTerminal {
            ($0.modes.altScreen, $0.modes.cursorKeysApp, $0.modes.mouse, $0.modes.mouseSGR)
        }
        // On the alternate screen there is no scrollback to move through, so the wheel belongs to
        // the application: as button presses when it asked for the mouse, as arrow keys otherwise.
        if mouse != .none, alt, !event.modifierFlags.contains(.option) {
            let button: MouseButton = lines > 0 ? .wheelUp : .wheelDown
            let cell = reportCell(event)
            let e = MouseEvent(button: button, action: .press, col: cell.col, row: cell.row,
                               modifiers: mouseModifiers(event))
            guard let bytes = MouseEncoder.encode(e, mode: mouse, sgr: sgr) else { return }
            var all: [UInt8] = []
            for _ in 0..<abs(lines) { all += bytes }
            session.send(all)
        } else if alt {
            guard config.mouseScrollAltScreen else { return }
            let key: Key = lines > 0 ? .up : .down
            let opts = KeyEncoderOptions(cursorKeysApp: app, optionAsMeta: false)
            guard let bytes = KeyEncoder.encode(KeyEvent(key: key, modifiers: [], text: nil), options: opts) else { return }
            var all: [UInt8] = []
            for _ in 0..<abs(lines) { all += bytes }
            session.send(all)
        } else {
            session.withTerminal { t in
                t.scrollViewport(by: lines)
                // A fold hides every row it covers, so a viewport top inside one does not move on
                // screen however far it is scrolled -- two thousand hidden rows would be two
                // thousand wheel clicks. Step over the fold in the direction of travel instead.
                t.snapViewportOutOfFold(movingUp: lines > 0, folding: folding)
            }
            markDirty()
        }
    }

    // MARK: - Menu actions

    override func selectAll(_ sender: Any?) {
        session.withTerminal { if selectionController.selectAll(in: $0) { markDirty() } }
    }

    /// The right-click menu. Built from `TerminalAction` like the main menu, so an item here cannot
    /// do something different from the same item there, and both grey out by the same rule.
    private func contextMenu(at point: NSPoint? = nil) -> NSMenu {
        let menu = NSMenu()
        // The command under the pointer, when there is one. This is the entry that turns the
        // scrollback into something you can act on rather than only read: the prompt marks say
        // where each command began, so "that one, with a change" is answerable.
        if let point, let row = commandRow(under: point) {
            let rerun = NSMenuItem(title: "Edit and Run This Command…",
                                   action: #selector(editAndRunFromMenu(_:)), keyEquivalent: "")
            rerun.target = self
            rerun.tag = row
            menu.addItem(rerun)
            let again = NSMenuItem(title: "Run This Command Again",
                                   action: #selector(rerunFromMenu(_:)), keyEquivalent: "")
            again.target = self
            again.tag = row
            menu.addItem(again)
            menu.addItem(.separator())
        }
        let groups: [[TerminalAction]] = [
            [.copy, .paste],
            [.splitRight, .splitDown, .toggleZoom],
            [.newTab, .closePane],
            [.clearScreen, .openConfig],
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if index == 0 {
                menu.addItem(actionItem(.copy))
                menu.addItem(actionItem(.paste))
                let all = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
                all.target = self
                menu.addItem(all)
                continue
            }
            for action in group { menu.addItem(actionItem(action)) }
        }
        return menu
    }

    private func actionItem(_ action: TerminalAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title,
                              action: #selector(TabController.performTerminalAction(_:)),
                              keyEquivalent: "")
        item.representedObject = action.rawValue
        if let binding = bindings.binding(for: action),
           let (key, mask) = MenuShortcut.keyEquivalent(for: binding) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return hasSelection }
        if item.action == #selector(selectAll(_:)) { return session.withTerminal { $0.totalRows > 0 } }
        return true
    }

    // MARK: - Links
    //
    // Hovering rescans exactly one row -- the one under the pointer -- so moving the mouse across a
    // 10,000-line buffer costs the same as moving it across an empty one. Whether a token is a link
    // at all, and what opening it means, is `LinkResolver` in NyxCore.

    /// The link under the pointer, in absolute coordinates so it stays on its text while the buffer
    /// scrolls underneath. nil when the pointer is over ordinary text.
    private var hoveredLink: (row: Int, columns: Range<Int>)?
    /// The buffer the hovered link was found in; a `clear` moves its row out from under it.
    private var hoveredLinkGeneration: UInt64 = 0
    /// The cell the pointer was last over, so a mouse-move inside one cell does no work at all --
    /// hit-testing tokenizes a row through five regular expressions and may `stat` a path.
    private var lastHoverCell: (row: Int, col: Int)?
    /// The same thing in view coordinates, for the pointing-hand cursor rect.
    private var hoveredRect: NSRect?

    private func updateHover(at point: NSPoint) {
        guard bounds.contains(point) else {
            clearHover()
            return
        }
        // A mouse-move that stays inside one cell cannot change what is under the pointer, and
        // hit-testing is not cheap: it tokenizes the row through five regular expressions and may
        // `stat` a path. Mouse-move events arrive far faster than cells change.
        let cell: (row: Int, col: Int) = session.withTerminal { t in
            let p = self.position(topLeft(point), in: t)
            return (p.row, p.col)
        }
        guard lastHoverCell == nil || lastHoverCell! != cell else { return }
        lastHoverCell = cell

        let hit = token(under: point)
        // Resolved *outside* the session lock: a path needs the pane's working directory, and
        // finding that takes the same lock, which is not recursive.
        var found: (row: Int, columns: Range<Int>)?
        if let hit, linkTarget(for: hit.token) != nil { found = (hit.row, hit.token.columns) }
        guard found?.row != hoveredLink?.row || found?.columns != hoveredLink?.columns else { return }
        hoveredLink = found
        updateHoverCursor()
        markDirty()
    }

    private func clearHover() {
        lastHoverCell = nil
        guard hoveredLink != nil else { return }
        hoveredLink = nil
        updateHoverCursor()
        markDirty()
    }

    /// The pointing hand is a cursor rect rather than a `NSCursor.set()`, so AppKit restores the
    /// arrow on its own when the pointer leaves the link -- and when it leaves the window entirely.
    private func updateHoverCursor() {
        hoveredRect = hoveredLink.flatMap { link in
            let top = session.withTerminal { $0.viewportTopRow }
            let cell = cellSizePoints
            let row = link.row - top
            guard row >= 0 else { return nil }
            let width = CGFloat(link.columns.count) * cell.width
            return NSRect(x: padding + CGFloat(link.columns.lowerBound) * cell.width,
                          y: bounds.height - padding - CGFloat(row + 1) * cell.height,
                          width: width, height: cell.height)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let hoveredRect else { return }
        addCursorRect(hoveredRect, cursor: .pointingHand)
    }

    /// The token under a view point, if any. One row is read, and the lock is released before the
    /// answer is looked at.
    private func token(under point: NSPoint) -> (row: Int, token: TextToken)? {
        session.withTerminal { t in
            let position = self.position(topLeft(point), in: t)
            guard let token = t.token(atAbsoluteRow: position.row, column: position.col,
                                      separators: config.wordSeparators) else { return nil }
            return (position.row, token)
        }
    }

    private func linkTarget(for token: TextToken) -> LinkTarget? {
        LinkResolver.target(for: token, home: NSHomeDirectory(),
                            // Read lazily: only a path needs it, and finding it costs two syscalls.
                            workingDirectory: { self.workingDirectory },
                            fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// ⌘-click. Returns false when there was nothing to open, so the click can go on to mean what
    /// it usually means.
    private func openLink(at event: NSEvent) -> Bool {
        guard let hit = token(under: convert(event.locationInWindow, from: nil)) else { return false }
        switch linkTarget(for: hit.token) {
        case .none:
            return false
        case .url(let text):
            guard let url = URL(string: text) else { return false }
            return NSWorkspace.shared.open(url)
        case .file(let path, let line, let column):
            if let template = config.openFileCommand, !template.isEmpty,
               let argv = OpenFileCommand.arguments(template: template, path: path, line: line, column: column) {
                return runOpenFileCommand(argv)
            }
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Runs `open-file-command` through `env`, so the user's template can name a command on their
    /// `PATH` rather than an absolute path to it. A failure to launch is reported by returning
    /// false; the caller beeps rather than opening the wrong thing instead.
    private func runOpenFileCommand(_ argv: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let directory = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Search
    //
    // The bar is a subview over the Metal layer; every decision it needs -- which hit becomes
    // current, where stepping goes, what the readout says, which columns are highlighted -- is
    // `SearchSession` and `SearchHighlights` in NyxCore. What is here is placement, focus and the
    // one thing a view must own: the selection to put back when the bar closes.

    var isSearching: Bool { searchBar != nil }

    /// `⌘F`. Opening while already open just re-focuses the field and selects what is in it, which
    /// is what every editor does with a second ⌘F.
    /// The query the bar is showing, so a search that jumps to another tab can take it along.
    var searchQuery: String { searchBar?.query ?? "" }

    /// Closes the bar without touching the hits a search over every tab is stepping through -- it
    /// is being handed to another pane, not abandoned.
    func closeSearchForHandover() {
        guard let bar = searchBar else { return }
        bar.removeFromSuperview()
        searchBar = nil
        // The highlights and the selection go with the bar. Leaving them behind stranded a pane in
        // another tab painted with matches and holding a selection the user never made, with no
        // way to clear either: ⎋ reaches the bar, and the bar is somewhere else now.
        clearSearchState()
        markDirty()
    }

    /// Drops search highlights and puts the selection back, without touching the bar. What
    /// `closeSearch` does to the buffer, for the paths that close the bar some other way.
    func clearSearchState() {
        searchSession.clear()
        let restored = selectionBeforeSearch
        selectionBeforeSearch = nil
        session.withTerminal { t in
            if let restored {
                _ = selectionController.replace(with: restored, in: t)
            } else {
                _ = selectionController.clear()
            }
        }
    }

    /// Clears what a cross-tab search left on a pane that no longer has the bar: the highlights,
    /// and the selection it made around the hit it jumped to.
    func clearSearchResidue() {
        guard searchBar == nil, !searchSession.isEmpty || selection != nil else { return }
        clearSearchState()
        markDirty()
    }

    /// Puts the readout on this pane's bar, for a cross-tab jump whose position was computed
    /// before the bar arrived here.
    func setSearchReadout(_ text: String) {
        searchBar?.setReadout(text)
    }

    /// `capturingSelection` is false when the bar is being *moved* here from another pane rather
    /// than opened by the user. What it captures is "the selection to put back when the search
    /// ends" -- and on a handover the only selection there is is the one the search itself just
    /// made, so capturing it made closing the search restore the highlight it was clearing.
    func openSearch(query: String = "", allTabs: Bool = false, capturingSelection: Bool = true) {
        if let bar = searchBar {
            bar.focusField()
            return
        }
        selectionBeforeSearch = capturingSelection ? selection : nil
        let bar = SearchBarView(palette: Pane.resolvedPalette(for: config))
        bar.onQueryChange = { [weak self] text in self?.searchQueryChanged(text) }
        bar.onStep = { [weak self] forward in _ = self?.stepSearch(forward: forward) }
        bar.onClose = { [weak self] in self?.closeSearch() }
        bar.onScopeChange = { [weak self] all in self?.searchScopeChanged(toAllTabs: all) }
        addSubview(bar)
        searchBar = bar
        layoutSearchBar()
        if !query.isEmpty || allTabs { bar.restore(query: query, allTabs: allTabs) }
        bar.focusField()
        markDirty()
    }

    /// `⎋` or the close button: the highlights go, and so does the selection the search made --
    /// whatever was selected before it opened comes back.
    func closeSearch() {
        guard let bar = searchBar else { return }
        bar.removeFromSuperview()
        searchBar = nil
        clearSearchState()
        // Closing the bar ends the cross-tab search too, and clears whatever it left on the panes
        // it visited. Without this the hit list outlived the bar, and the next ⌘G sent the user to
        // a tab nobody was searching.
        globalSearchOwner?.endGlobalSearch()
        window?.makeFirstResponder(self)
        markDirty()
    }

    private func searchQueryChanged(_ text: String) {
        if searchBar?.searchesAllTabs == true {
            searchBar?.setReadout(globalSearchOwner?.runGlobalSearch(query: text) ?? "")
            return
        }
        session.withTerminal { t in
            searchSession.update(query: text, in: t, viewportTop: t.viewportTopRow)
        }
        revealCurrentMatch()
        searchBar?.setReadout(searchSession.readout)
        markDirty()
    }

    /// Switching scope re-runs the query, so the readout and the highlights describe what is
    /// actually being searched rather than what was searched before the toggle.
    private func searchScopeChanged(toAllTabs all: Bool) {
        if !all { globalSearchOwner?.endGlobalSearch() }
        searchQueryChanged(searchBar?.query ?? "")
    }

    /// The object that can see every tab. A pane knows only its own buffer, which is the whole
    /// reason a per-pane search cannot answer "which tab was that in".
    private var globalSearchOwner: TabController? { actionTarget as? TabController }

    /// `⏎`/`⇧⏎` and ⌘G/⌘⇧G. Returns false when there is nothing to step through, so the caller can
    /// beep rather than doing nothing silently.
    @discardableResult
    func stepSearch(forward: Bool) -> Bool {
        if searchBar?.searchesAllTabs == true {
            guard let owner = globalSearchOwner, let readout = owner.stepGlobalSearch(forward: forward)
            else { return false }
            searchBar?.setReadout(readout)
            return true
        }
        guard searchBar != nil, !searchSession.isEmpty else { return false }
        searchSession.step(forward: forward)
        revealCurrentMatch()
        searchBar?.setReadout(searchSession.readout)
        markDirty()
        return true
    }

    /// Shows a hit that a search over every tab found in this pane: scroll to it, select it, and
    /// highlight it the way a local search would, so stepping across tabs looks like one search
    /// rather than several.
    func reveal(match: SearchMatch, query: String) {
        session.withTerminal { t in
            searchSession.update(query: query, in: t, viewportTop: match.row)
            _ = t.scrollToAbsoluteRow(match.row, margin: max(1, t.rows / 3))
            _ = selectionController.replace(with: match.selection, in: t)
        }
        markDirty()
    }

    /// Brings the current hit on screen and selects it, so `⎋` can be followed by ⌘C.
    private func revealCurrentMatch() {
        guard let match = searchSession.current else { return }
        session.withTerminal { t in
            // A third of the screen down, so the hit lands where the eye already is rather than
            // flush against the top edge.
            _ = t.revealAbsoluteRow(match.row, margin: max(1, t.rows / 3))
            _ = selectionController.replace(with: match.selection, in: t)
        }
    }

    /// Output while the bar is open moves the text the highlights point at, so the search is re-run
    /// -- coalesced, because a build scrolling past would otherwise rescan the buffer per read.
    private func scheduleSearchRefresh() {
        guard searchBar != nil, !searchSession.query.isEmpty, !searchRefreshScheduled else { return }
        searchRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.searchRefreshScheduled = false
            guard self.searchBar != nil else { return }
            self.session.withTerminal { t in
                self.searchSession.refresh(in: t, viewportTop: t.viewportTopRow)
            }
            self.searchBar?.setReadout(self.searchSession.readout)
            self.markDirty()
        }
    }

    private func layoutSearchBar() {
        guard let bar = searchBar else { return }
        let width = min(SearchBarView.preferredWidth, max(200, bounds.width - 16))
        bar.frame = NSRect(x: bounds.width - width - 8, y: bounds.height - SearchBarView.height - 8,
                           width: width, height: SearchBarView.height)
        bar.needsLayout = true
    }

    /// Runs `body` against this pane's terminal while holding its lock.
    ///
    /// This used to hand the terminal *out* of the lock, with a comment claiming the opposite.
    /// Searching every open buffer then read them with no lock at all while their PTY threads were
    /// writing, and took the whole application down -- every shell in every window -- whenever
    /// anything was producing output as you typed.
    func withTerminalForSearch<T>(_ body: (Terminal) -> T) -> T { session.withTerminal(body) }

    /// Takes focus because a search landed here, without the side effects of a click.
    func focusFromSearch() {
        onFocusRequested?()
        window?.makeFirstResponder(self)
    }

    // MARK: - Shell integration

    /// Whether the shell in this pane emits OSC 133 marks at all. Without them the prompt-jumping
    /// actions have nothing to jump between, and the menu greys them out rather than beeping.
    var hasPromptMarks: Bool {
        // A stored flag on the terminal, set when the first `OSC 133` arrives. Menu validation asks
        // this several times per keystroke, and the honest answer used to mean scanning every row
        // of the buffer to find out that a shell without integration still has no marks.
        session.withTerminal { $0.shellEmitsPromptMarks }
    }


    /// Moves the viewport to the prompt above or below what is on screen, and returns whether it
    /// moved -- the caller beeps when there is nowhere to go rather than doing nothing silently.
    @discardableResult
    func jumpToPrompt(forward: Bool) -> Bool {
        let moved: Bool = session.withTerminal { t in
            let from = t.viewportTopRow
            guard let row = forward ? t.nextPrompt(after: from) : t.previousPrompt(before: from)
            else { return false }
            _ = t.scrollToAbsoluteRow(row)
            return true
        }
        if moved { markDirty() }
        return moved
    }

    /// The gutter takes as much of the pane's left padding as a mark needs, and nothing when there
    /// is not enough padding for one -- a gutter over the first column of text would be worse than
    /// no gutter at all.
    private func layoutGutter() {
        let width = CGFloat(PromptGutter.width(padding: Double(padding)))
        gutter.isHidden = width <= 0
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        gutter.needsDisplay = true
    }

    /// Exactly one terminal row tall and exactly over the first one, inside the padding and clear
    /// of the gutter -- so the strip covers a row of text and never the marks beside it.
    private func layoutStickyStrip() {
        let cell = cellSizePoints
        let left = max(padding, CGFloat(PromptGutter.width(padding: Double(padding))))
        stickyStrip.frame = NSRect(x: left, y: bounds.height - padding - cell.height,
                                   width: max(0, bounds.width - left - padding), height: cell.height)
    }

    /// Clicking the strip goes to the command it names: the point of pinning it is to be able to
    /// get back to where the output started.
    private func scrollToStickyPrompt() {
        guard let row = stickyPromptRow else { return }
        session.withTerminal { t in _ = t.scrollToAbsoluteRow(row) }
        onFocusRequested?()
        markDirty()
    }

    // MARK: - Folding
    //
    // What a fold hides, which rows the viewport shows once some are hidden, and where a highlight
    // lands afterwards are all `OutputFolding` and `Terminal.displayRows` in NyxCore. What is here
    // is a click, a menu action, and the arithmetic that turns a point into a visible row.

    /// The visible row a point falls on, or nil for a point in the padding.
    private func visibleRow(at point: NSPoint) -> Int? {
        let cell = cellSizePoints
        guard cell.height > 0 else { return nil }
        let y = Double(bounds.height - point.y)
        let row = Int(((y - Double(padding)) / Double(cell.height)).rounded(.down))
        return row >= 0 && row < rows ? row : nil
    }

    /// A click on a fold placeholder puts the output back. Returns false when the click was on
    /// ordinary text, so it can go on to mean what it usually means.
    private func unfoldPlaceholder(at point: NSPoint) -> Bool {
        guard !folding.isEmpty, let visible = visibleRow(at: point),
              foldRowsOnScreen.indices.contains(visible),
              case .fold(let promptRow, _) = foldRowsOnScreen[visible] else { return false }
        folding.unfold(promptRow: promptRow)
        markDirty()
        return true
    }

    /// A click on a gutter mark folds that command's output, and folds it back open. Holding ⌥
    /// selects the output instead, which is what a plain click used to do.
    private func gutterClicked(atVisibleRow row: Int, alternate: Bool) {
        guard !alternate else {
            selectCommand(atVisibleRow: row)
            return
        }
        let absolute: Int? = session.withTerminal { t in
            guard let entry = self.absoluteRow(forVisibleRow: row, in: t),
                  let region = t.command(containingAbsoluteRow: entry),
                  !region.outputRows.isEmpty else { return nil }
            return region.promptRow
        }
        guard let promptRow = absolute else {
            NSSound.beep()
            return
        }
        folding.toggle(promptRow: promptRow)
        onFocusRequested?()
        markDirty()
    }

    /// Which absolute row a visible row is showing, through whatever folds are in force. nil for a
    /// row that is showing a fold placeholder rather than a row of the buffer.
    private func absoluteRow(forVisibleRow row: Int, in t: Terminal) -> Int? {
        guard !folding.isEmpty else { return t.viewportTopRow + row }
        guard foldRowsOnScreen.indices.contains(row) else { return nil }
        guard case .row(let absolute) = foldRowsOnScreen[row] else { return nil }
        return absolute
    }

    /// `fold_command`: collapses the command the viewport is showing, and expands it again.
    @discardableResult
    func toggleFoldOfCurrentCommand() -> Bool {
        let promptRow: Int? = session.withTerminal { t in
            guard let region = t.command(containingAbsoluteRow: t.viewportTopRow) ?? t.lastFinishedCommand,
                  !region.outputRows.isEmpty else { return nil }
            return region.promptRow
        }
        guard let promptRow else { return false }
        folding.toggle(promptRow: promptRow)
        markDirty()
        return true
    }

    /// `fold_all_long_output`: tidies the screen in one action, and puts it back on a second press
    /// -- after a long session most of what is in the buffer is output you have already read.
    @discardableResult
    func foldAllLongOutput() -> Bool {
        guard session.withTerminal({ $0.shellEmitsPromptMarks }) else { return false }
        guard folding.isEmpty else {
            folding.unfoldAll()
            markDirty()
            return true
        }
        session.withTerminal { t in
            folding.foldLongOutput(in: t, longerThan: Pane.longOutputThreshold)
        }
        guard !folding.isEmpty else { return false }
        markDirty()
        return true
    }

    /// Output longer than a screenful is what "long" means here: anything shorter was readable
    /// where it stood, and folding it would hide as many rows as the placeholder costs.
    private static let longOutputThreshold = 20

    /// A click on a mark selects that command's output.
    private func selectCommand(atVisibleRow row: Int) {
        let selection: Selection? = session.withTerminal { t in
            guard let absolute = self.absoluteRow(forVisibleRow: row, in: t),
                  let region = t.command(containingAbsoluteRow: absolute) else { return nil }
            return t.selectionForOutput(of: region)
        }
        guard let selection else {
            NSSound.beep()
            return
        }
        session.withTerminal { t in _ = selectionController.replace(with: selection, in: t) }
        onFocusRequested?()
        markDirty()
    }

    // MARK: - Telling the user a long command finished
    //
    // Coalesced rather than run per read: finding the bottom-most prompt walks back through the
    // buffer, and a build scrolling past would otherwise pay for that thousands of times a second.
    // Half a second late is not late for a notification about something that took ten seconds.

    private func scheduleCommandCheck() {
        guard !commandCheckScheduled else { return }
        commandCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.commandCheckScheduled = false
            self.checkWorkingDirectory()
            self.checkForFinishedCommand()
        }
    }

    private func checkForFinishedCommand() {
        let now = Date.timeIntervalSinceReferenceDate
        let bottom: (row: Int?, started: Bool) = session.withTerminal { t in
            guard t.totalRows > 0, let region = t.command(containingAbsoluteRow: t.totalRows - 1)
            else { return (nil, false) }
            return (region.promptRow, region.outputStart != nil)
        }
        guard let finished = commandWatcher.observe(bottomPromptRow: bottom.row,
                                                    outputStarted: bottom.started, now: now)
        else { return }
        // A command that finished while the user was watching it needs no notification.
        guard window?.isKeyWindow != true else { return }
        let described: (text: String, status: Int32?) = session.withTerminal { t in
            guard let region = t.command(containingAbsoluteRow: finished.promptRow) else { return ("", nil) }
            return (t.commandText(of: region), region.exitStatus)
        }
        CommandNotifier.shared.post(title: CommandNotification.title(failed: (described.status ?? 0) != 0),
                                    body: CommandNotification.body(command: described.text,
                                                                   exitStatus: described.status))
    }

    /// Selects the output of the command the viewport is showing.
    @discardableResult
    func selectCommandOutput() -> Bool {
        let selection: Selection? = session.withTerminal { t in
            guard let region = t.command(containingAbsoluteRow: t.viewportTopRow) ?? t.lastFinishedCommand
            else { return nil }
            return t.selectionForOutput(of: region)
        }
        guard let selection else { return false }
        session.withTerminal { t in _ = selectionController.replace(with: selection, in: t) }
        markDirty()
        return true
    }

    /// Copies the output of the last command that finished, without disturbing the selection --
    /// the point is to grab it and paste it somewhere, not to change what is highlighted.
    @discardableResult
    func copyLastCommandOutput() -> Bool {
        let text: String = session.withTerminal { t in
            guard let region = t.lastFinishedCommand,
                  let selection = t.selectionForOutput(of: region) else { return "" }
            return t.text(in: selection)
        }
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// The whole buffer -- scrollback and screen -- as text. `Transcript` decides what "as text"
    /// means; the pane only holds the lock while it is written out.
    func scrollbackTranscript(options: Transcript.Options) -> String {
        session.withTerminal { $0.transcript(options: options) }
    }

    /// Whether there is any buffer to save at all, so the menu item can grey out rather than
    /// putting up a panel that would write an empty file.
    var hasScrollback: Bool { session.withTerminal { $0.totalRows > 0 } }

    /// This pane as a saved session records it: where its shell is, what it was called, and the
    /// last few thousand rows of what it was showing.
    ///
    /// Capped by `SessionCapture` rather than written whole. Ten tabs of a full 10,000-line
    /// scrollback is megabytes of ANSI to build and write on the way out of the application, and
    /// nobody scrolls back through last week's build output anyway.
    func sessionSnapshot(title: String?) -> PaneSnapshot {
        // Reuses the last transcript when nothing has been written to this buffer since.
        //
        // Selecting a tab, renaming one, or moving it between groups all ask for a fresh snapshot
        // and change nothing a transcript can see -- and rebuilding one is thousands of rows of
        // string assembly under the session lock, on the most frequent action in a terminal. The
        // version counter makes that case free without making the answer stale: any byte the shell
        // writes bumps it.
        let transcript: String = session.withTerminal { terminal -> String in
            let version = terminal.contentVersion
            let generation = terminal.scrollbackGeneration
            if let cached = cachedTranscript, cached.version == version, cached.generation == generation {
                return cached.text
            }
            let rows = SessionCapture.rowRange(totalRows: terminal.totalRows)
            let text = rows.isEmpty ? "" : terminal.transcript(rows: rows, options: .forRestoring)
            cachedTranscript = (version: version, generation: generation, text: text)
            return text
        }
        return PaneSnapshot(id: id.value, workingDirectory: workingDirectory, title: title,
                            transcript: transcript.isEmpty ? nil : transcript)
    }

    /// The last transcript built for a session snapshot, and the buffer state it described.
    private var cachedTranscript: (version: UInt64, generation: UInt64, text: String)?

    /// Re-indexes anything produced per absolute row onto the screen rows actually being drawn.
    private static func place<T>(_ values: [T?], from top: Int, rows: Int,
                                 screenRow: (Int) -> Int?) -> [T?] {
        var out = [T?](repeating: nil, count: max(0, rows))
        for (offset, value) in values.enumerated() {
            guard let value, let row = screenRow(top + offset), out.indices.contains(row) else { continue }
            out[row] = value
        }
        return out
    }

    /// The `font-family = system` case: macOS's own monospaced face, SF Mono.
    ///
    /// It cannot be asked for by name -- CoreText hands back Menlo for `userFixedPitch` and
    /// Helvetica for every internal name it has -- so it is resolved here, where AppKit is
    /// available, and passed down as a font rather than a family. Any other value is a family name
    /// and takes the ordinary path.
    static func systemMonospacedFont(for family: String) -> CTFont? {
        guard family.lowercased() == "system" else { return nil }
        return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
    }

    /// Whether ⌘C has anything to copy, so the menu item can grey out.
    var hasSelection: Bool {
        guard let selection else { return false }
        return !session.withTerminal { $0.text(in: selection) }.isEmpty
    }

    /// `clear_screen`: what ⌘K does in most terminals -- wipe the screen and the scrollback, as if
    /// the user had run `clear -x`, without sending anything to the shell (which may be busy).
    func clearScreen() {
        // Cursor home, erase the screen, erase the scrollback -- fed to our own parser rather than
        // written to the PTY, so it works while the shell is busy running something.
        session.withTerminal { $0.feed("\u{1b}[H\u{1b}[2J\u{1b}[3J") }
        // `markDirty`, not `dirty.set()`. On an idle pane the display link is parked -- that is how
        // this terminal holds 0% CPU doing nothing -- and setting the flag without waking it means
        // the screen is cleared in the model and unchanged on screen until something else happens
        // to draw. ⌘K on an idle prompt did nothing visible at all.
        markDirty()
    }

    @objc func copy(_ sender: Any?) {
        guard let s = selection else { return }
        // `text(in:)` already yields "" for an empty selection, so this covers that too — and a
        // selection of nothing but blanks, which should leave the pasteboard alone rather than
        // wiping it.
        let text = session.withTerminal { $0.text(in: s) }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘V, the middle button, and the `paste` action.
    ///
    /// `PasteGuard` decides whether what is on the pasteboard is worth stopping for, given the
    /// terminal's *own* bracketed-paste mode -- which is the whole protection, and is read from the
    /// terminal rather than assumed. Nothing worth stopping for means the paste happens exactly as
    /// it did before: one mode read and one write, no view work at all.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let bracketed = session.withTerminal { $0.modes.bracketedPaste }

        // Several lines go to the editor by default, and this is why: once a multi-line command is
        // on the shell's line editor it is very hard to change. Clicking cannot help either -- with
        // real newlines in the buffer the shell re-wraps it on its own terms, so the distance in
        // cells on screen stops matching the number of arrow presses, and there is no honest
        // arithmetic left. Editing it before it lands is the reliable answer, not a nicer dialog.
        if PasteGuard.lineCount(text) > 1 {
            switch config.multilinePaste {
            case .edit:
                let shown = presentCommandEditor(text: text, heading: "Edit before pasting",
                                                 runTitle: "Paste") { [weak self] edited in
                    self?.performPaste(edited, bracketed: bracketed)
                }
                // If the editor could not be shown, paste anyway. A feature that intercepts a core
                // action has to degrade to that action, never to nothing at all.
                if !shown { performPaste(text, bracketed: bracketed) }
                return
            case .direct:
                performPaste(text, bracketed: bracketed)
                return
            case .confirm:
                break
            }
        }

        guard let warning = PasteGuard.warning(for: text, bracketedPaste: bracketed) else {
            performPaste(text, bracketed: bracketed)
            return
        }
        confirmPaste(text, bracketed: bracketed, warning: warning)
    }

    private func performPaste(_ text: String, bracketed: Bool) {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        var bytes: [UInt8] = []
        if bracketed { bytes += Array("\u{1B}[200~".utf8) }
        bytes += Array(normalised.utf8)
        if bracketed { bytes += Array("\u{1B}[201~".utf8) }
        send(bytes)
    }

    /// A sheet, never a modal alert: `runModal()` stops the run loop and with it every session in
    /// every other tab and window -- the same rule `TabController.confirmClose` follows. A pane
    /// with no window has nobody to ask, and an unanswerable question is answered "no".
    private func confirmPaste(_ text: String, bracketed: Bool, warning: PasteWarning) {
        guard let window else {
            NSSound.beep()
            return
        }
        let confirmation = PasteGuard.confirmation(for: warning, text: text)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.detail
        alert.accessoryView = Pane.pastePreview(confirmation)
        // "Paste" is first, so it is the default -- but the sheet itself is the interruption, and a
        // user who reads the preview and presses ⏎ has still read it.
        alert.addButton(withTitle: "Paste")
        // The third choice is the useful one for the case this dialog is most often shown for: a
        // long command pasted from somewhere that needs one value changed before it runs. Refusing
        // or accepting a wall of text are both worse answers than being able to look at it.
        alert.addButton(withTitle: "Edit…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.performPaste(text, bracketed: bracketed)
            case .alertSecondButtonReturn:
                // Presented after this sheet has finished dismissing; two sheets on one window at
                // the same time is undefined and in practice loses the second.
                DispatchQueue.main.async { self.editThenPaste(text, bracketed: bracketed) }
            default:
                break
            }
        }
    }

    /// The absolute row of the command whose region covers a point, or nil where there is none --
    /// above the first prompt, or with a shell that emits no marks.
    private func commandRow(under point: NSPoint) -> Int? {
        session.withTerminal { terminal in
            guard terminal.shellEmitsPromptMarks else { return nil }
            let position = self.position(topLeft(point), in: terminal)
            return terminal.command(containingAbsoluteRow: position.row)?.promptRow
        }
    }

    @objc private func editAndRunFromMenu(_ sender: NSMenuItem) {
        if !editAndRunCommand(atAbsoluteRow: sender.tag) { NSSound.beep() }
    }

    /// No editor, no confirmation: the command exactly as it ran.
    @objc private func rerunFromMenu(_ sender: NSMenuItem) {
        let command: String = session.withTerminal { terminal in
            guard let region = terminal.command(containingAbsoluteRow: sender.tag) else { return "" }
            return terminal.commandText(of: region)
        }
        guard !command.isEmpty else {
            NSSound.beep()
            return
        }
        send(Array((command + "\r").utf8))
    }

    /// `⌘E`: the last command that ran, in the editor. From the keyboard there is no pointer to
    /// say which command was meant, and the last one is what "run that again, but…" means.
    @discardableResult
    func editAndRunLastCommand() -> Bool {
        // What is on the command line right now comes first. Pasting a long `curl` and then
        // needing to change something in its body is the case this is for, and at that moment the
        // command has not run yet -- looking only at history would offer the wrong thing.
        if let typed: String = session.withTerminal({ $0.currentInput }) {
            editCurrentInput(typed)
            return true
        }
        let row: Int? = session.withTerminal { $0.lastFinishedCommand?.promptRow }
        guard let row else { return false }
        return editAndRunCommand(atAbsoluteRow: row)
    }

    /// Edits the text already on the command line, then replaces it with the result.
    private func editCurrentInput(_ text: String) {
        presentCommandEditor(text: text, heading: "Edit the command line", runTitle: "Run") {
            [weak self] edited in
            guard let self else { return }
            // Clear what is there before writing the replacement. `^E` then `^U` covers both of the
            // common line editors: zsh's `^U` kills the whole line, bash's kills back from the
            // cursor, so moving to the end first makes them agree.
            self.send([0x05, 0x15])
            let bracketed = self.session.withTerminal { $0.modes.bracketedPaste }
            self.performPaste(edited, bracketed: bracketed)
        }
    }

    /// `⌘⇧V`: paste, but look at it first. The plain paste path deliberately does not interrupt a
    /// multi-line paste when bracketed paste is on -- the shell shows it rather than running it --
    /// which is right for safety and wrong for the one case where you *want* the editor. This is
    /// that case, asked for on purpose.
    @discardableResult
    func pasteWithEditor() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return false
        }
        let bracketed = session.withTerminal { $0.modes.bracketedPaste }
        presentCommandEditor(text: text, heading: "Edit before pasting", runTitle: "Paste") {
            [weak self] edited in
            self?.performPaste(edited, bracketed: bracketed)
        }
        return true
    }

    /// Opens the paste in the command editor, and pastes whatever comes back.
    private func editThenPaste(_ text: String, bracketed: Bool) {
        presentCommandEditor(text: text, heading: "Edit before pasting", runTitle: "Paste") {
            [weak self] edited in
            self?.performPaste(edited, bracketed: bracketed)
        }
    }

    /// `Edit and Run` on a command in the scrollback: the command comes back in the editor, and
    /// what the user leaves there is typed at the shell as though they had entered it.
    ///
    /// Possible only because the prompt marks say where each command began and ended -- without
    /// them the terminal has a screen of text and no idea which part of it was a command.
    func editAndRunCommand(atAbsoluteRow row: Int) -> Bool {
        let command: String = session.withTerminal { terminal in
            guard let region = terminal.command(containingAbsoluteRow: row) else { return "" }
            return terminal.commandText(of: region)
        }
        guard !command.isEmpty else { return false }
        presentCommandEditor(text: command, heading: "Edit and run", runTitle: "Run") {
            [weak self] edited in
            guard let self else { return }
            // Sent as a paste so a multi-line edit arrives as one command rather than as several
            // lines the shell starts running one at a time.
            let bracketed = self.session.withTerminal { $0.modes.bracketedPaste }
            self.performPaste(edited, bracketed: bracketed)
        }
        return true
    }

    @discardableResult
    private func presentCommandEditor(text: String, heading: String, runTitle: String,
                                      then run: @escaping (String) -> Void) -> Bool {
        guard let window else { return false }
        let editor = CommandEditor(text: text, heading: heading, runTitle: runTitle,
                                   palette: Pane.resolvedPalette(for: config))
        // Presented as a sheet window rather than through `presentAsSheet`, which needs a
        // presenting view controller -- and this window has none, because its content is a view.
        // Relying on one meant the editor silently never appeared, and with it the paste it was
        // supposed to be editing. Whatever else changes here, a paste must never end in nothing.
        let size = editor.view.frame.size == .zero ? NSSize(width: 620, height: 380) : editor.view.frame.size
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .fullSizeContentView, .resizable],
                             backing: .buffered, defer: false)
        // `contentViewController`, not `contentView`. A window retains its content *view* but not
        // the controller behind it, so the editor was deallocated the moment this function
        // returned: every button's target went nil, `⎋` did nothing, and the sheet became a
        // picture of an editor that could not be closed. Exactly what a user reported.
        sheet.contentViewController = editor
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false

        editor.onFinish = { [weak window] edited in
            window?.endSheet(sheet)
            guard let edited else { return }
            run(edited)
        }
        window.beginSheet(sheet) { _ in }
        return true
    }

    /// The first line in a fixed-width font, with the line count under it. Selectable, because the
    /// first thing anyone does with a paste they distrust is copy it somewhere to look at properly.
    private static func pastePreview(_ confirmation: PasteConfirmation) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: confirmation.summary.isEmpty ? 40 : 58))
        let field = NSTextField(wrappingLabelWithString: confirmation.preview)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: container.bounds.height - 40, width: 320, height: 40)
        container.addSubview(field)
        guard !confirmation.summary.isEmpty else { return container }
        let summary = NSTextField(labelWithString: confirmation.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.frame = NSRect(x: 0, y: 0, width: 320, height: 16)
        container.addSubview(summary)
        return container
    }

    /// `setZoom` recomputes `zoomOffset` from the clamped target rather than just incrementing it,
    /// so repeated presses at the 6...72pt cap don't let the offset drift past what's visible --
    /// which would otherwise take several presses the other way to undo.
    private func setZoom(_ desiredEffectiveSize: CGFloat) {
        zoomOffset = min(max(desiredEffectiveSize, 6), 72) - CGFloat(config.fontSize)
        rebuildFonts()
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(effectiveFontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(effectiveFontSize - 1) }
    @objc func zoomReset(_ sender: Any?) { zoomOffset = 0; rebuildFonts() }
}
