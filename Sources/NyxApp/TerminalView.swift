import AppKit
import Metal
import QuartzCore
import NyxCore
import NyxRender

enum NyxError: Error, LocalizedError {
    case noMetal
    var errorDescription: String? { "Metal is not available on this Mac." }
}

final class TerminalView: NSView, NSTextInputClient {
    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// Left `false` deliberately: nothing writes it in phase 1, because the config file that will
    /// set it (`option-as-meta`) arrives in phase 2. Keeping it a constant makes the dead
    /// `insertText` branch visible instead of pretending there is a setting behind it.
    private let optionAsMeta = false

    private let session: TerminalSession
    private let renderer: Renderer
    private var fonts: FontSet
    private var fontSize: CGFloat = 13
    private let fontFamily = "Menlo"
    private let padding: CGFloat = 8
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
    /// Task 11 replaces these two with config values; the constants match the spec's defaults.
    private let copyOnSelect = false
    private let middleClickPaste = true

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(_ frame: NSRect) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NyxError.noMetal }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        fonts = FontSet(family: fontFamily, pointSize: fontSize, scale: scale)
        renderer = try Renderer(device: device, fonts: fonts)
        session = try TerminalSession(config: .loginShell(cols: 80, rows: 24, palette: Theme.nyxDark))
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        session.onUpdate = { [weak self] in self?.markDirty() }
        session.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        session.onExit = { [weak self] code in DispatchQueue.main.async { self?.onExit?(code) } }
        session.start()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var cellSizePoints: NSSize {
        NSSize(width: CGFloat(fonts.metrics.width) / fonts.scale, height: CGFloat(fonts.metrics.height) / fonts.scale)
    }

    func size(forCols c: Int, rows r: Int) -> NSSize {
        NSSize(width: cellSizePoints.width * CGFloat(c) + padding * 2, height: cellSizePoints.height * CGFloat(r) + padding * 2)
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
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        if scale != fonts.scale { rebuildFonts() }
        updateGrid()
    }

    private func rebuildFonts() {
        let scale = window?.backingScaleFactor ?? fonts.scale
        fonts = FontSet(family: fontFamily, pointSize: fontSize, scale: scale)
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
        let (frame, wantsMotion): (RenderFrame, Bool) = session.withTerminal { t in
            let lines = (0..<t.rows).map { t.viewportRow($0) }
            let cursor: Cursor? = (t.modes.showCursor && t.viewportOffset == 0) ? t.screen.cursor : nil
            // Resolved here, inside the lock, so the highlighted columns belong to the same
            // viewport as the lines being drawn.
            let top = t.viewportTopRow
            let selected = (0..<t.rows).map { self.selection?.columnRange(onRow: top + $0, cols: t.cols) }
            // A missing drawable is transient. On failure, re-setting dirty will repaint rows
            // already marked clean; once per-row partial redraw lands, fix both here and there.
            t.clearDirty()
            let f = RenderFrame(cols: t.cols, rows: t.rows, lines: lines, graphemes: t.graphemes, palette: t.palette,
                                cursor: cursor, cursorShape: t.cursorShape, focused: focused, preedit: preedit,
                                selection: selected)
            return (f, t.modes.mouse == .any)
        }
        // The tracking area for bare motion follows the mouse mode, which only an application can
        // change; this is the first place after such a change that runs on the main thread.
        if wantsMotion != (motionTracking != nil) { updateTrackingAreas() }
        // A missing drawable is transient; keep the frame stale so the next tick retries rather
        // than pausing the link on top of stale pixels.
        if !renderer.draw(frame, in: metalLayer, padding: Int(padding * metalLayer.contentsScale)) { dirty.set() }
    }

    // MARK: - Events from the terminal

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .titleChanged(let t): onTitleChange?(t)
        case .bell: NSSound.beep()
        case .clipboardWrite(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .colorsChanged: markDirty()
        case .cwdChanged, .notification: break
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        currentEvent = event
        defer { currentEvent = nil }
        if !(inputContext?.handleEvent(event) ?? false) { sendKey(event) }
    }

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

    private func sendKey(_ e: NSEvent) {
        guard let ke = keyEvent(from: e) else { return }
        let opts = session.withTerminal {
            KeyEncoderOptions(cursorKeysApp: $0.modes.cursorKeysApp, optionAsMeta: optionAsMeta)
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
        if let e = currentEvent, e.modifierFlags.contains(.control) || (optionAsMeta && e.modifierFlags.contains(.option)) {
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Bare motion is only worth delivering in `any` mode; every other mode would discard it.
        let wants = session.withTerminal { $0.modes.mouse == .any }
        if let area = motionTracking {
            guard !wants else { return }   // `.inVisibleRect` keeps the existing area in step
            removeTrackingArea(area)
            motionTracking = nil
            return
        }
        guard wants else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        motionTracking = area
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if report(event, .left, .press) { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        let point = topLeft(lastMousePoint!)
        let block = event.modifierFlags.contains(.option)
        let changed = session.withTerminal { t in
            selectionController.begin(at: position(point, in: t), clickCount: event.clickCount, block: block, in: t)
        }
        if changed { markDirty() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard selectionController.isDragging else { report(event, .left, .drag); return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        let point = topLeft(lastMousePoint!)
        let changed = session.withTerminal { t in selectionController.drag(to: position(point, in: t), in: t) }
        if changed { markDirty() }
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionController.isDragging else { report(event, .left, .release); return }
        lastMousePoint = nil
        if selectionController.end() { markDirty() }
        if copyOnSelect, selection != nil { copy(nil) }
    }

    override func mouseMoved(with event: NSEvent) {
        report(event, .left, .move)
    }

    override func rightMouseDown(with event: NSEvent) { report(event, .right, .press) }
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
        if middleClickPaste { paste(nil) }
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
            return selectionController.drag(to: position(head, in: t), in: t)
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

    @objc func copy(_ sender: Any?) {
        guard let s = selection, !s.isEmpty else { return }
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

    @objc func zoomIn(_ sender: Any?) { fontSize = min(fontSize + 1, 72); rebuildFonts() }
    @objc func zoomOut(_ sender: Any?) { fontSize = max(fontSize - 1, 6); rebuildFonts() }
    @objc func zoomReset(_ sender: Any?) { fontSize = 13; rebuildFonts() }
}
