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

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Clamped the same way the old hardcoded zoom was (6...72pt), independent of the config's own
    /// 4...144 clamp, which bounds the *configured* value rather than the zoomed one.
    private var effectiveFontSize: CGFloat { min(max(CGFloat(config.fontSize) + zoomOffset, 6), 72) }
    private var padding: CGFloat { CGFloat(config.padding) }

    /// `workingDirectory` is what a new pane inherits from the one it was split off; it is ignored
    /// when the config names a directory of its own, which is an explicit instruction rather than
    /// a default.
    init(_ frame: NSRect, config: Config, workingDirectory: String? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NyxError.noMetal }
        self.id = Pane.allocateID()
        self.config = config
        bindings = KeyBindingTable(user: config.keybinds)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        fonts = FontSet(family: config.fontFamily, pointSize: CGFloat(config.fontSize), scale: scale, lineHeight: CGFloat(config.lineHeight))
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
        session.withTerminal { $0.setDefaultCursorShape(config.cursorStyle); $0.modes.cursorBlink = config.cursorBlink }
        session.onUpdate = { [weak self] in self?.sessionDidUpdate() }
        session.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        session.onExit = { [weak self] code in DispatchQueue.main.async { self?.onExit?(code) } }
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
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        if scale != fonts.scale { rebuildFonts() }
        updateGrid()
    }

    private func rebuildFonts() {
        let scale = window?.backingScaleFactor ?? fonts.scale
        fonts = FontSet(family: config.fontFamily, pointSize: effectiveFontSize, scale: scale, lineHeight: CGFloat(config.lineHeight))
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
        resumeLink()
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
        let frame: RenderFrame = session.withTerminal { t in
            // Before anything reads the selection: a cleared scrollback, a reset or an
            // alternate-screen swap leaves it pointing at rows that now hold other content.
            selectionController.invalidateIfStale(t)
            let lines = (0..<t.rows).map { t.viewportRow($0) }
            let cursor: Cursor? = (t.modes.showCursor && t.viewportOffset == 0) ? t.screen.cursor : nil
            // Resolved here, inside the lock, so the highlighted columns belong to the same
            // viewport as the lines being drawn.
            let top = t.viewportTopRow
            let selected = (0..<t.rows).map { self.selection?.columnRange(onRow: top + $0, cols: t.cols) }
            let matches = SearchHighlights.visibleRanges(self.searchSession.matches, viewportTop: top,
                                                        rows: t.rows, cols: t.cols)
            let current = SearchHighlights.visibleRange(of: self.searchSession.current, viewportTop: top,
                                                       rows: t.rows, cols: t.cols)
            let hovered = SearchHighlights.visibleRange(onAbsoluteRow: self.hoveredLink?.row ?? 0,
                                                        columns: self.hoveredLink?.columns,
                                                        viewportTop: top, rows: t.rows, cols: t.cols)
            // A missing drawable is transient. On failure, re-setting dirty will repaint rows
            // already marked clean; once per-row partial redraw lands, fix both here and there.
            t.clearDirty()
            return RenderFrame(cols: t.cols, rows: t.rows, lines: lines, graphemes: t.graphemes, palette: t.palette,
                               cursor: cursor, cursorShape: t.cursorShape, focused: focused, preedit: preedit,
                               selection: selected, searchMatches: matches, currentSearchMatch: current,
                               hoveredLink: hovered)
        }
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
        case .cwdChanged, .notification: break
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

    private func send(_ bytes: [UInt8]) {
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
        return PointerMap.position(x: p.x, y: p.y, cellWidth: Double(cell.width), cellHeight: Double(cell.height),
                                   padding: Double(padding), viewportTop: t.viewportTopRow,
                                   cols: t.cols, totalRows: t.totalRows)
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
        if selectionController.end() { markDirty() }
        if config.copyOnSelect, selection != nil { copy(nil) }
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
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
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
            session.withTerminal { $0.scrollViewport(by: lines) }
            markDirty()
        }
    }

    // MARK: - Menu actions

    override func selectAll(_ sender: Any?) {
        session.withTerminal { if selectionController.selectAll(in: $0) { markDirty() } }
    }

    /// The right-click menu. Built from `TerminalAction` like the main menu, so an item here cannot
    /// do something different from the same item there, and both grey out by the same rule.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
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
    /// The same thing in view coordinates, for the pointing-hand cursor rect.
    private var hoveredRect: NSRect?

    private func updateHover(at point: NSPoint) {
        guard bounds.contains(point) else {
            clearHover()
            return
        }
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
    func openSearch() {
        if let bar = searchBar {
            bar.focusField()
            return
        }
        selectionBeforeSearch = selection
        let bar = SearchBarView(palette: Pane.resolvedPalette(for: config))
        bar.onQueryChange = { [weak self] text in self?.searchQueryChanged(text) }
        bar.onStep = { [weak self] forward in _ = self?.stepSearch(forward: forward) }
        bar.onClose = { [weak self] in self?.closeSearch() }
        addSubview(bar)
        searchBar = bar
        layoutSearchBar()
        bar.focusField()
        markDirty()
    }

    /// `⎋` or the close button: the highlights go, and so does the selection the search made --
    /// whatever was selected before it opened comes back.
    func closeSearch() {
        guard let bar = searchBar else { return }
        bar.removeFromSuperview()
        searchBar = nil
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
        window?.makeFirstResponder(self)
        markDirty()
    }

    private func searchQueryChanged(_ text: String) {
        session.withTerminal { t in
            searchSession.update(query: text, in: t, viewportTop: t.viewportTopRow)
        }
        revealCurrentMatch()
        searchBar?.setReadout(searchSession.readout)
        markDirty()
    }

    /// `⏎`/`⇧⏎` and ⌘G/⌘⇧G. Returns false when there is nothing to step through, so the caller can
    /// beep rather than doing nothing silently.
    @discardableResult
    func stepSearch(forward: Bool) -> Bool {
        guard searchBar != nil, !searchSession.isEmpty else { return false }
        searchSession.step(forward: forward)
        revealCurrentMatch()
        searchBar?.setReadout(searchSession.readout)
        markDirty()
        return true
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

    // MARK: - Shell integration

    /// Whether the shell in this pane emits OSC 133 marks at all. Without them the prompt-jumping
    /// actions have nothing to jump between, and the menu greys them out rather than beeping.
    var hasPromptMarks: Bool {
        session.withTerminal { !$0.promptRows.isEmpty }
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
        dirty.set()
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

    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let bracketed = session.withTerminal { $0.modes.bracketedPaste }
        var bytes: [UInt8] = []
        if bracketed { bytes += Array("\u{1B}[200~".utf8) }
        bytes += Array(text.utf8)
        if bracketed { bytes += Array("\u{1B}[201~".utf8) }
        send(bytes)
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
