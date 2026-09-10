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
    /// Whether this pane is the only one in its tab, from the tree that holds it. nil for a pane
    /// that is not in a tree yet, which is treated as "alone" -- the state a remote tab starts in.
    var isSolePaneInTab: (() -> Bool)?
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
    /// A remote pane's attachment changed phase or role, on the main queue. The tab takes its title
    /// and its observer/writer badge from it; nil for every local pane.
    var onRemoteStateChange: ((AttachState) -> Void)?

    /// Only ever touched on the main thread, where every pane is created.
    private static var nextID = 0

    private static func allocateID() -> PaneID {
        nextID += 1
        return PaneID(nextID)
    }

    /// What this pane is a view of. `any PaneSession` rather than `TerminalSession` so a session
    /// running on another Mac can stand in for a local shell without a second copy of this class;
    /// see `PaneSession` for what a remote conformer answers for `pid` and
    /// `foregroundProcessGroup`.
    let session: any PaneSession
    /// The same object as `session` when this pane shows another Mac's session, nil when it shows a
    /// local shell. It is what the few things that genuinely differ ask -- the strip, the tab's
    /// badge, whether a key closes a dead tab, whether this pane is worth saving in the session
    /// file, whether it is published to paired Macs -- and nothing else in the pane branches on it.
    let remote: RemoteSession?
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
    /// A remote pane's "Attaching…" / "Observing — Take control" / "Session ended" row, over the
    /// same top row. Present only on a remote pane; when it is up, the sticky strip moves down a
    /// row rather than the two of them sharing one.
    private let remoteStrip = RemoteStripView(frame: .zero)
    /// The hovered block's strip of labelled pills -- `Fold`, `Copy`, `Actions ▾` -- drawn over its
    /// command row the same way. What it carries at a given width is `CommandBlockChrome.stripPlan`.
    private let blockHeader = BlockHeaderView(frame: .zero)
    /// `⌘E Workbench`, at the end of a `curl` that has just been pasted. See `WorkbenchHint`.
    private let workbenchHint = WorkbenchHintView(frame: .zero)
    /// The prompt row the strip currently names, for its click.
    private var stickyPromptRow: Int?
    /// Which display slot the last frame blanked for the pinned band, so the frame that stops
    /// blanking it can tell the renderer's row cache that the row it has is no longer the row.
    private var blankedStickyRow: Int?
    /// Which commands' output is collapsed. Empty for almost every pane that ever exists, which is
    /// what keeps the render path unchanged: every fold-aware branch is behind `isEmpty`.
    private var folding = OutputFolding()
    /// The buffer the folds belong to; a `clear` makes every absolute row mean something else.
    private var foldingGeneration: UInt64 = 0
    /// The last frame's display rows, so a click can tell which visible row is a fold placeholder
    /// and which command it stands for. Empty whenever nothing is folded.
    private var foldRowsOnScreen: [DisplayRow] = []
    /// A row inside each block the last frame drew, by command id.
    ///
    /// A fold placeholder and a lens line are not rows of the buffer, and the pointer has to be
    /// answered with *something*: without this, a click on one fell back to `viewportTop + slot`,
    /// which names whatever block happens to occupy that row -- so a right-click two thirds of the
    /// way down a hundred-line lens offered the next command's actions, Re-run included. Built here,
    /// from the blocks the frame already walked, because asking the buffer for a prompt row whose
    /// command line is scrolled off the top means scanning the whole scrollback.
    private var displayBlockRows: [UInt32: Int] = [:]
    /// What the buffer had evicted the last time folds and armed notifications were pruned. Nothing
    /// else can retire a command id, so an unchanged pair means the walk to find the oldest one
    /// would answer exactly what it answered last frame.
    /// -1 so the first prune always runs.
    private var lastPruneEvictedRows = -1
    /// `Terminal.evictedRows` the last time the viewport anchor was moved to keep up with it. Its
    /// own counter rather than `lastPruneEvictedRows`, which is only updated on the frames that
    /// have something to prune: the anchor has to follow the rows on every frame that loses one.
    private var lastAnchorEvictedRows = -1
    private var lastPruneGeneration: UInt64 = 0
    /// The block under the pointer, re-resolved by `BlockHover` in every frame against that frame's
    /// own blocks and display rows -- so it follows the rows when they scroll and disappears when a
    /// TUI takes the screen.
    private(set) var hoveredBlock: BlockHover?
    /// The headers built for the last frame, by visible row, so a click on a summary can be resolved
    /// and the overlay can be fed without another walk.
    private var headersOnScreen: [Int: BlockHeader] = [:]
    /// The cell range of each summary on its row, for the chevron click target.
    /// What each finished block on screen turned out to be: a request and what it said, or not a
    /// request at all. One reading per block, ever -- see `RequestSummaryCache`, which owns that
    /// rule and is tested on its own.
    private var requestCache = RequestSummaryCache()
    /// Only visible finished blocks are ever read, so this grows by the handful; the cap is for a
    /// session that scrolls through thousands of requests without ever clearing.
    private static let requestCacheLimit = 512
    /// Which responses are being read through which lens, and what is folded inside them. Empty in
    /// every pane nobody has run a `curl` in, which is what keeps the render path unchanged: the
    /// lens-aware branch is behind the same `isEmpty` the folds are.
    private var lenses = LensChoices()
    /// The lines each lensed block is showing, by command id. Built off the main thread and stored
    /// here; the frame reads it and nothing else writes it.
    private var lensBuffers: [UInt32: LensBuffer] = [:]
    /// Rendering a response is a JSON parse and a pretty-print of a body that can be megabytes.
    /// Serial, so two rebuilds of the same block cannot land out of order, and `.userInitiated`
    /// because someone is waiting for it -- they just chose the lens.
    private let lensQueue = DispatchQueue(label: "nyx.lens", qos: .userInitiated)
    /// Blocks whose lines are being built right now, and blocks whose input changed while that was
    /// happening.
    ///
    /// A rendering is a JSON parse and a pretty-print of the whole body; a burst of fold clicks --
    /// which is how anyone reads a large response -- would otherwise queue one per click and make
    /// the reader wait for four answers they no longer want. One in flight, one remembered, and the
    /// remembered one runs from the state as it is when the first lands.
    private var lensRebuilds: Set<UInt32> = []
    private var lensRebuildsAgain: Set<UInt32> = []
    /// The display position this pane last scrolled to, and the terminal viewport top it was chosen
    /// against.
    ///
    /// Two numbers because the two can differ: a lens on the *live screen* can be longer than the
    /// rows it replaced, and reading its tail means a display top below the last row the terminal
    /// can be scrolled to (`viewportOffset` bottoms out at 0). The terminal clamps, this does not,
    /// and the recorded top is how a viewport the terminal moved on its own -- new output, a resize,
    /// a jump to a search match -- is told apart from one this pane chose. See `viewportCursor(in:)`.
    private var viewportAnchor: DisplayCursor?
    private var viewportAnchorTop = -1
    /// Whether the anchor is what "go to the live screen" recorded rather than a place the reader
    /// scrolled to. `send` does that on every keystroke, and such an anchor must not outlive the
    /// bottom moving -- see `Terminal.viewportCursor`.
    private var viewportAnchorIsDisplayBottom = false

    /// For a display that is about to be a different height -- a lens opened or closed, a watch run
    /// lensed, a fold moved. Only the live-bottom anchor goes; a reader's own place is kept, and
    /// `canonicalised` clamps it against the buffers as they are. The rule is
    /// `DisplayCursor.survivesDisplayChange`, in Core where it is tested.
    private func forgetViewportAnchorIfItIsOnlyTheLiveBottom() {
        guard !DisplayCursor.survivesDisplayChange(anchor: viewportAnchor,
                                                   isDisplayBottom: viewportAnchorIsDisplayBottom)
        else { return }
        forgetViewportAnchor()
    }

    /// Forgets where in the display the viewport was, so the next frame takes the terminal's own
    /// row and line 0.
    ///
    /// The staleness check in `viewportCursor(in:)` compares a *row*, and rows are reused: a session
    /// that has not overflowed its window has `viewportTopRow == 0` from beginning to end, so an
    /// anchor left over from a lens read earlier would be re-homed by `canonicalised` onto whatever
    /// block now occupies that row. `⌘K`, a new `curl`, and the fresh response opened sixty lines
    /// down. Anything that makes an absolute row mean something else calls this.
    private func forgetViewportAnchor() {
        viewportAnchor = nil
        viewportAnchorTop = -1
        viewportAnchorIsDisplayBottom = false
    }

    /// A drag over a lensed block's own lines. Not `Selection`: those are absolute rows and cells
    /// of the grid, and these lines exist nowhere in the buffer.
    private var lensSelection: LensSelection?
    /// The `Filter…` / `Find in Body…` field, while one is open, and the block it belongs to.
    private var lensField: LensFieldView?
    private var lensFieldBlock: UInt32?
    /// Requests read this frame that should open in the configured lens. Applied by `render` once
    /// the session lock is gone -- the same arrangement the request history has, and for the same
    /// reason: nothing that dispatches may run with the lock held.
    private var pendingDefaultLens: [UInt32] = []
    /// The hover strip this frame: which pills, how much of the sentence, and the column it begins
    /// at. Decided in `render()` by `CommandBlockChrome.stripPlacement`; applied after the lock,
    /// where AppKit lives. nil is no strip at all -- no row had room for one.
    private var hoverStripPlan: CommandBlockChrome.StripPlan?
    /// A finished request read this frame that has not been written to the history yet. Set under
    /// the session lock by `requestSummary` and drained by `render` once the lock is gone: the
    /// store writes a file, and a file write must never happen with the session lock held.
    private var recordAfterFrame: String?
    /// The `curl` a paste has just put on the command line, and the clock reading at which its pill
    /// stops being offered. Nil for every pane that has never had one pasted into it, which is the
    /// state that costs nothing per frame.
    private var hintCommand: String?
    private var hintExpiry: Double = 0
    /// Fires once, when the pill's welcome runs out: nothing else would ask for the redraw that
    /// takes it off an otherwise idle screen.
    private var hintTimer: Timer?
    /// Ticks once a second while a running command's row is on screen, so its elapsed time moves.
    private var runningTimer: Timer?
    /// The watch this pane is running, or nil -- which is every pane nobody has asked for one in.
    /// Kept after it finishes so the newest run's header can go on showing the statistics.
    private var watch: WatchSeries?
    /// The Watch popover while one is up, so Start can close it -- see `presentWatchPlanEditor`.
    private var watchPopover: NSPopover?
    /// Alive only while the series is waiting for its next run to fall due. A watch that is
    /// *running* one has nothing to poll for: the finish arrives with the frame that reads the
    /// block. See `updateWatchTimer`.
    private var watchTimer: Timer?
    /// When a run was typed at the shell and has not been seen to start.
    ///
    /// Without it the 250 ms tick would type the command again on every tick until the shell got
    /// round to echoing an `OSC 133 C` -- four curls a second at a busy prompt. Cleared when the
    /// run starts, when it finishes (a local request can begin and end between two ticks), and
    /// after `watchStartTimeout` for the line that never ran at all.
    private var watchSentAt: Double?
    /// The newest command in the pane that had already run when the outstanding line was typed.
    /// The floor `WatchSeries.owns` needs to tell the run it is waiting for from a stale block
    /// that finished before the watch existed -- see that function.
    private var watchSentAfterCommandID: UInt32 = 0
    /// True for exactly as long as the watch is writing its own run to the shell, so the rule that
    /// stops a series when the user types does not stop it on the series' own bytes.
    private var isSendingWatchRun = false
    /// Runs whose blocks the exchange cache learned this frame. Filled under the session lock by
    /// `requestSummary` and drained by `render` once the lock is gone: acting on one folds blocks,
    /// sets a lens and dispatches, none of which may happen with the lock held.
    private var pendingWatchFinishes: [WatchFinish] = []

    /// One finished run, as the frame that read its block saw it.
    private struct WatchFinish {
        let id: UInt32
        let status: Int?
        let exitStatus: Int32
        let timeTotal: Double?
        /// For `WatchPlan.Condition.bodyContains`/`bodyLacks`.
        let body: String
        let at: Double
    }

    /// How long a typed run may go unstarted before the series tries again. Generous on purpose:
    /// a shell that is busy, slow to draw, or paused under a `less` has not lost the line, and
    /// typing a second copy of a request into it would be worse than waiting.
    private static let watchStartTimeout: Double = 30
    /// Whether a command was running at the last check, to notice the moment a new one starts.
    private var commandWasRunning = false
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
    convenience init(_ frame: NSRect, config: Config, workingDirectory: String? = nil,
                     restoringTranscript: String? = nil) throws {
        let palette = Pane.resolvedPalette(for: config)
        let session = try TerminalSession(config: Pane.sessionConfig(for: config, cols: 80, rows: 24,
                                                                     palette: palette,
                                                                     inheriting: workingDirectory))
        try self.init(frame, config: config, session: session, remote: nil,
                      restoringTranscript: restoringTranscript)
    }

    /// A pane showing a session on a paired Mac.
    ///
    /// `state` is the attachment's state as it stands right now, so the strip is drawn before the
    /// first frame rather than a moment after it: an attach that is still in "Attaching…" must not
    /// spend its first redraw looking like an ordinary, silent terminal.
    ///
    /// There is no `workingDirectory` and no `restoringTranscript`: the host decides where its own
    /// shell is, and what fills the buffer is its snapshot.
    convenience init(_ frame: NSRect, config: Config, remote: RemoteSession, state: AttachState) throws {
        try self.init(frame, config: config, session: remote, remote: remote, restoringTranscript: nil)
        showRemote(state)
    }

    private init(_ frame: NSRect, config: Config, session: any PaneSession, remote: RemoteSession?,
                 restoringTranscript: String?) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NyxError.noMetal }
        self.id = Pane.allocateID()
        self.config = config
        bindings = KeyBindingTable(user: config.keybinds)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        fonts = FontSet(family: config.fontFamily, pointSize: CGFloat(config.fontSize), scale: scale,
                        lineHeight: CGFloat(config.lineHeight),
                        baseFont: Pane.systemMonospacedFont(for: config.fontFamily))
        renderer = try Renderer(device: device, fonts: fonts)
        self.session = session
        self.remote = remote
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
        blockHeader.onAction = { [weak self] action, id in self?.perform(action, on: id) }
        blockHeader.onToggleFold = { [weak self] id, full in self?.toggleFold(ofCommand: id, full: full) }
        blockHeader.onNeedsPreviousRun = { [weak self] id in self?.previousRun(of: id) != nil }
        addSubview(blockHeader)
        workbenchHint.onPress = { [weak self] in self?.openWorkbenchFromHint() }
        addSubview(workbenchHint)
        if let remote {
            remoteStrip.onButton = { [weak self] in self?.remoteStripButtonPressed() }
            addSubview(remoteStrip)
            // Wired before `start()`, like every other callback here: the attachment may already be
            // past `attaching` by the time this pane exists.
            remote.onStateChange = { [weak self] state in self?.showRemote(state) }
        }
        session.withTerminal { $0.setDefaultCursorShape(config.cursorStyle); $0.modes.cursorBlink = config.cursorBlink }
        session.onUpdate = { [weak self] in self?.sessionDidUpdate() }
        session.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        session.onExit = { [weak self] code in DispatchQueue.main.async { self?.onExit?(code) } }
        // After the callbacks and before `start()`: `register` publishes the catalogue immediately,
        // and a session announced before it can answer an attach would be a palette row that beeps.
        if let local = session as? TerminalSession { startPublishing(local) }
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
    /// Every theme this installation has, kept up to date by `AppDelegate` on each config reload.
    ///
    /// Process-wide because that is what it describes: one themes directory, shared by every window
    /// and read by the settings window and the palette as well. It starts as the built-ins, so a
    /// pane created before the first reload draws in a real theme rather than in nothing.
    static var themes: ThemeCatalog = .builtinOnly

    static func resolvedPalette(for config: Config) -> Palette {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name: String
        switch (config.darkThemeName, config.lightThemeName) {
        case let (dark?, light?): name = isDark ? dark : light
        case let (dark?, nil): name = isDark ? dark : config.themeName
        case let (nil, light?): name = isDark ? config.themeName : light
        case (nil, nil): name = config.themeName
        }
        var palette = themes.palette(named: name)
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

    /// The subviews (gutter, sticky strip, block header overlay) plus one element per fold
    /// placeholder, which is drawn in Metal as a row of cells and has nothing else in the view
    /// hierarchy to report it. Without this a folded block could be opened with a mouse and by no
    /// other means.
    ///
    /// The in-grid summary has no element here any more. It used to have one because its chevron
    /// was a fold control; the chevron is gone and the sentence is a readout (§2.4), and the fold
    /// control VoiceOver reaches on a command row is the gutter cap's, which `PromptGutterView`
    /// publishes with a real label at every width -- including the narrow ones where the strip has
    /// no `Fold` pill.
    override func accessibilityChildren() -> [Any]? {
        var children = subviews.filter { !$0.isHidden } as [Any]
        for row in foldPlaceholderRowsOnScreen {
            guard case .fold(let id, let hidden, _) = foldRowsOnScreen[row] else { continue }
            // The same box the pointer gets and the same box a click is tested against: one row of
            // cells is 13 pt at `line-height 0.8`, below the floor for a target VoiceOver rings
            // (§8.4), so all three read it from `foldPlaceholderRect`.
            let frame = foldPlaceholderRect(onVisibleRow: row)
            children.append(DrawnControlElement.make(
                label: "Unfold the \(hidden) hidden lines of the command on line \(row + 1)",
                role: .button, frame: frame, in: self,
                press: { [weak self] in
                    self?.folding.unfold(id)
                    self?.markDirty()
                }))
        }
        return children
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
        // A remote session has no local child (`PaneSession` documents it as 0), and asking the
        // kernel about process 0 is a syscall whose only possible answer is "no". The host's own
        // OSC 7 above is where a remote pane's directory comes from.
        guard session.pid > 0 else { return nil }
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
        // Asked of the *resolved* palette rather than of the config fields that usually move it.
        // A theme now also comes from a file, and editing that file changes no field at all: the
        // tab bar and the split dividers recoloured (they rebuild unconditionally) while the grid
        // stayed on the old colours, which is a worse look than not reloading at all.
        if applyPaletteIfChanged() {
            searchBar?.apply(palette: Pane.resolvedPalette(for: config))
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
        appliedPalette = palette
        session.withTerminal { $0.palette = palette }
        markDirty()
    }

    /// The palette this pane is currently drawing in, so a reload can ask whether anything actually
    /// moved rather than trusting a list of the fields that might have.
    private var appliedPalette: Palette?

    /// Repaints when the resolved palette is not the one in force. Returns whether it did.
    @discardableResult
    private func applyPaletteIfChanged() -> Bool {
        let palette = Pane.resolvedPalette(for: config)
        guard palette != appliedPalette else { return false }
        applyPalette()
        return true
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
        runningTimer?.invalidate()
        runningTimer = nil
        // A series whose pane has gone has nowhere to type; the timer would also keep this whole
        // terminal alive for as long as it ticked.
        stopWatch(.paneClosed)
        watchTimer?.invalidate()
        watchTimer = nil
        watchPopover?.performClose(nil)
        watchPopover = nil
        // The pill's expiry timer retains this pane until it fires; a tab closed inside its eight
        // seconds would otherwise keep a whole terminal alive waiting to hide a label.
        hintTimer?.invalidate()
        hintTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // Before the session goes: everyone attached is told the session ended, and the palette row
        // on the other Mac disappears rather than staying there pointing at nothing.
        publication?.end()
        publication = nil
        session.terminate()
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        runningTimer?.invalidate()
        runningTimer = nil
        // The pill's expiry timer retains this pane until it fires; a tab closed inside its eight
        // seconds would otherwise keep a whole terminal alive waiting to hide a label.
        hintTimer?.invalidate()
        hintTimer = nil
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
        // The floor is in cells, so it moves with the font -- set once at creation it was a floor
        // in points, and raising the font size to 24 left a "minimum" three lines tall.
        window?.contentMinSize = size(forCols: 24, rows: 6)
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
        // The geometry note is the one thing on the strip that changes when *this* window does, so
        // it is re-decided here as well as on every state change.
        if let remote { showRemote(remote.state) }
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
        lastActivityAt = Date()
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
            // Nothing occluded is worth a tick a second for; render() starts it again once a
            // running block is next actually drawn, which markDirty() below brings about.
            runningTimer?.invalidate()
            runningTimer = nil
        } else {
            markDirty()   // the flag may have accumulated changes while we were hidden
        }
    }

    @objc private func tick() {
        autoscroll()
        if dirty.takeAndClear() { render() } else { displayLink?.isPaused = true }
    }

    /// The viewport mapping of the frame before this one. See `dirtyRows(of:top:)`.
    private var lastMapping: ViewportMapping?

    /// Which visible rows changed since the last presented frame, or `[]` meaning "all of them".
    ///
    /// The decision itself is `ViewportMapping` in NyxCore, where it can be tested: its failure
    /// mode is a stale row on screen, which no test of the drawing catches and no user reports as
    /// anything but "sometimes the terminal is wrong".
    private func dirtyRows(of t: Terminal, top: Int) -> [Bool] {
        let mapping = ViewportMapping(of: t, top: top, folded: !folding.isEmpty || !lenses.isEmpty)
        let trusted = mapping.trustsDirtyFlags(after: lastMapping)
        lastMapping = mapping
        guard trusted else { return [] }
        return (0..<t.rows).map { t.screen.rows[$0].dirty }
    }

    /// `NYX_RENDER_STATS=1` reports how much of each frame the renderer actually rebuilds. The
    /// per-row cache is invisible by construction -- the picture is identical either way -- so
    /// without a counter there is no way to tell a working cache from a broken one in the real app.
    private static let renderStatsEnabled = ProcessInfo.processInfo.environment["NYX_RENDER_STATS"] != nil
    private func reportRenderStats() {
        let s = renderer.stats
        guard s.frames >= 120 else { return }
        let share = s.rowsSeen == 0 ? 0 : (s.rowsRebuilt * 100) / s.rowsSeen
        let line = "nyx render: \(s.frames) frames, \(s.rowsRebuilt)/\(s.rowsSeen) rows rebuilt (\(share)%), "
            + "\(s.fullInvalidations) full invalidations\n"
        FileHandle.standardError.write(Data(line.utf8))
        renderer.resetStats()
    }

    // MARK: - Lenses
    //
    // A lens replaces a finished request's output rows with lines Nyx made up: pretty JSON, the
    // headers, a filter, a search, a diff against the last run. Everything that decides what those
    // lines *are* is `LensRendering` in NyxCore; what is here is when to build them, where to put
    // them, and how a click reaches one.

    /// Opens the configured lens on requests read this frame. Called from `render` after the lock.
    private func applyPendingLenses() {
        guard !pendingDefaultLens.isEmpty else { return }
        let ids = pendingDefaultLens
        pendingDefaultLens.removeAll()
        var armed = false
        for id in ids where lenses.lens(of: id) == nil {
            lenses.set(.pretty, for: id)
            rebuildLens(for: id)
            armed = true
        }
        // The display just became a different height under a viewport nobody moved. In a window the
        // session has never scrolled, `viewportTopRow` is 0 from the first keystroke to the last, so
        // the anchor `send` stored while the command was being typed -- row 0, back when there were
        // no lenses at all -- is still "valid" and would be used: the frame draws from the prompt
        // down, the response fills the window, and the shell's own prompt is a hundred display lines
        // below the last row. No caret, no echo, until the reader scrolls by hand. Forgetting it
        // here is what sends the next frame to `displayBottomCursor`.
        if armed { forgetViewportAnchorIfItIsOnlyTheLiveBottom() }
    }

    /// Whether anything in this pane could be shown through a lens: a finished request that has
    /// been read. What `⌘⇧J`'s menu item and palette row are enabled by.
    var hasResponseToLens: Bool { lensTargetBlock() != nil }

    /// The lens a block is being read through, for its header and its menu.
    func lens(of id: UInt32) -> ResponseLens? { lenses.lens(of: id) }

    /// Whether this block's response body is JSON -- the one thing the `{ }` control can do
    /// something with. From the cache, never a re-parse: this is asked once per block per frame.
    func bodyIsJSON(_ id: UInt32) -> Bool {
        guard case .request(let exchange)? = requestCache.entry(for: id), let exchange else {
            return false
        }
        return exchange.bodyKind == .json
    }

    /// Whether this block's body is past what a lens will re-lay-out, which is what the ⋯ menu says
    /// instead of offering seven rows that would each do nothing.
    func lensIsTooLarge(_ id: UInt32) -> Bool {
        guard case .request(let exchange)? = requestCache.entry(for: id), let exchange else {
            return false
        }
        return LensRendering.isTooLarge(exchange)
    }

    /// The nearest earlier block that ran the same request, or nil. Both the menu's `Diff with
    /// Previous Run` and the diff itself go through this, so the row cannot be enabled for a run
    /// the lens would then fail to find.
    func previousRun(of id: UInt32) -> UInt32? {
        guard let line = requestCache.commandLine(of: id),
              let command = CurlCommand.parse(line) else { return nil }
        return requestCache.previousRun(before: id, matching: command)
    }

    /// Chooses a lens for a block. `nil` and `.raw` are the same instruction -- put the rows back.
    func setLens(_ lens: ResponseLens?, on id: UInt32) {
        let chosen: ResponseLens? = (lens == nil || lens == .raw) ? nil : lens
        lenses.set(chosen, for: id)
        if chosen == nil { lensBuffers[id] = nil }
        if lensSelection?.commandID == id { lensSelection = nil }
        // The display under the viewport is about to be a different height. A line offset chosen
        // against the old one would put the reader somewhere they did not ask to be -- but only if
        // it was chosen against *this* block, and `canonicalised` clamps it either way. What has to
        // go is the live-bottom anchor, which was never a place anyone chose.
        forgetViewportAnchorIfItIsOnlyTheLiveBottom()
        rebuildLens(for: id)
        markDirty()
    }

    /// `⌘⇧J` and the `{ }` control: pretty ↔ raw, on the block under the pointer or the last
    /// request in the pane. Returns false when there is no request to toggle, so the caller can
    /// beep rather than pretending.
    @discardableResult
    func toggleLensOfCurrentBlock() -> Bool {
        guard let id = lensTargetBlock() else { return false }
        guard !lensIsTooLarge(id) else { return false }
        setLens(lenses.lens(of: id) == nil ? .pretty : nil, on: id)
        return true
    }

    /// The block a lens command applies to: the one under the pointer when it is a request, else
    /// the last request in the pane. A keyboard shortcut with no pointer involved still has to have
    /// an answer, and "the response you were just looking at" is the one people mean.
    private func lensTargetBlock() -> UInt32? {
        if let point = lastPointerPoint, let id = commandID(under: point),
           requestCache.isRequest(id: id) {
            return id
        }
        if let hovered = hoveredBlock?.id, requestCache.isRequest(id: hovered) { return hovered }
        return session.withTerminal { t -> UInt32? in
            t.promptRows.reversed().compactMap { row -> UInt32? in
                guard let region = t.command(containingAbsoluteRow: row), region.id != 0,
                      self.requestCache.isRequest(id: region.id) else { return nil }
                return region.id
            }.first
        }
    }

    /// Builds a block's lens lines off the main thread and stores them when they are ready.
    ///
    /// The frame builder never waits on this: it draws whatever buffer is there, which is the
    /// previous rendering while a new one is in flight and the raw rows when there is none at all.
    /// A response of two megabytes is a JSON parse and a pretty-print, and doing that between two
    /// frames is how a terminal gets a reputation for stuttering.
    private func rebuildLens(for id: UInt32) {
        guard let lens = lenses.lens(of: id) else {
            lensBuffers[id] = nil
            markDirty()
            return
        }
        guard case .request(let exchange)? = requestCache.entry(for: id), let exchange else {
            lenses.set(nil, for: id)
            lensBuffers[id] = nil
            markDirty()
            return
        }
        var previous: HTTPExchange?
        if case .diff(let previousID) = lens,
           case .request(let earlier)? = requestCache.entry(for: previousID) {
            previous = earlier
        }
        // One at a time per block. The follow-up is not queued with this input, it is re-derived
        // when this one lands, so five folds in a second cost two renderings and the second one is
        // of the folds as they finally stand.
        guard !lensRebuilds.contains(id) else {
            lensRebuildsAgain.insert(id)
            return
        }
        let input = LensInput(exchange: exchange, previous: previous, folded: lenses.folded(in: id))
        let version = session.withTerminal { $0.contentVersion }
        lensRebuilds.insert(id)
        lensQueue.async { [weak self] in
            let lines = LensRendering.lines(for: lens, input: input)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lensRebuilds.remove(id)
                // Before the guard below, and in a `defer`, because the commonest reason a rebuild
                // was asked for mid-flight is that the *lens itself* changed -- and that is exactly
                // the case the guard returns on. Draining afterwards would leave the new lens with
                // nothing ever built for it.
                let again = self.lensRebuildsAgain.remove(id) != nil
                defer { if again { self.rebuildLens(for: id) } }
                // The lens may have changed while this was in flight -- a fold, another lens, back
                // to raw. The newest choice wins; this rendering is of a question nobody is asking.
                guard self.lenses.lens(of: id) == lens else { return }
                if let lines, !lines.isEmpty {
                    self.lensBuffers[id] = LensBuffer(commandID: id, lens: lens, lines: lines,
                                                      contentVersion: version)
                } else {
                    // nil is `LensRendering` saying "show the raw transcript": a body too large, a
                    // filter with no JSON under it, a diff with nothing to compare against. The
                    // block goes back to its rows rather than showing an empty pane.
                    self.lensBuffers[id] = nil
                    self.lenses.set(nil, for: id)
                }
                self.markDirty()
            }
        }
    }

    /// Opens the one-line field a filter or a search is typed into, over the block's command row.
    ///
    /// The field applies on every keystroke, because the lens is a pure function of the exchange
    /// and the text: there is nothing to submit, and a response that only re-filters when you press
    /// return is one you cannot explore.
    private func presentLensField(for lens: ResponseLens, on id: UInt32) {
        dismissLensField()
        let isFilter: Bool
        if case .filter = lens { isFilter = true } else { isFilter = false }
        let view = LensFieldView(frame: .zero)
        let palette = session.withTerminal { $0.palette }
        addSubview(view)
        view.frame = lensFieldFrame(for: id, height: view.intrinsicContentSize.height)
        view.show(caption: isFilter ? "Filter" : "Find", text: "", palette: palette)
        view.onChange = { [weak self] text in
            guard let self else { return }
            guard !text.isEmpty else {
                self.setLens(nil, on: id)
                self.lensField?.setMessage(nil, offersJq: false)
                return
            }
            if isFilter {
                let body = self.lensBody(of: id)
                if let problem = LensRendering.filterError(text, body: body) {
                    // A path this box does not understand, or a body that is not JSON. The lens is
                    // left alone -- the response stays on screen -- and the sentence says which.
                    self.lensField?.setMessage(problem, offersJq: problem == JSONPath.unsupportedMessage)
                    return
                }
                self.lensField?.setMessage(nil, offersJq: false)
                self.setLens(.filter(text), on: id)
            } else {
                self.setLens(.grep(text), on: id)
            }
        }
        view.onRunWithJq = { [weak self] text in
            guard let self, let line = self.requestCache.commandLine(of: id) else { return }
            self.dismissLensField()
            // The block's own command line, piped: what a person would have typed if they had
            // known at the start that they would want jq. Bracketed, because a `\`-continued curl
            // read off the grid has real newlines in it.
            let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
            let bracketed = self.session.withTerminal { $0.modes.bracketedPaste }
            self.performPaste("\(line) | jq '\(escaped)'", bracketed: bracketed)
            self.send([0x0D])
        }
        view.onClose = { [weak self] in self?.dismissLensField() }
        lensField = view
        lensFieldBlock = id
        view.focus()
        onFocusRequested?()
    }

    /// Over the block's command row when that row is on screen, and at the top of the pane when it
    /// is not: the field belongs to a response, and a response scrolled off the top is still the
    /// one being filtered.
    ///
    /// The slot comes from the display the last frame built, not from `promptRow - viewportTop`: a
    /// lens or a fold on screen means those are different numbers, and the field would sit over
    /// somebody else's command.
    private func lensFieldFrame(for id: UInt32, height: CGFloat) -> NSRect {
        let width: CGFloat = 360
        let cell = cellSizePoints
        var row = 0
        if let promptRow = session.withTerminal({ $0.promptRow(ofCommand: id) }) {
            let top = session.withTerminal { max(0, $0.viewportTopRow) }
            row = max(0, min(rows - 1, displaySlot(ofAbsoluteRow: promptRow, viewportTop: top) ?? 0))
        }
        let y = bounds.height - padding - CGFloat(row + 1) * cell.height - height
        return NSRect(x: max(padding, bounds.width - padding - width),
                      y: max(padding, y), width: width, height: height)
    }

    /// Which visible slot an absolute row is drawn in, through whatever folds and lenses the last
    /// frame applied. nil when that row is not on screen at all.
    private func displaySlot(ofAbsoluteRow absolute: Int, viewportTop top: Int) -> Int? {
        guard !foldRowsOnScreen.isEmpty else {
            let index = absolute - top
            return (0..<rows).contains(index) ? index : nil
        }
        return foldRowsOnScreen.firstIndex {
            if case .row(absolute) = $0 { return true } else { return false }
        }
    }

    /// Keeps the field over the command row it belongs to as the view scrolls under it.
    ///
    /// It used to be placed once, when it opened, and never again: three wheel clicks left a filter
    /// box floating over an unrelated command, still filtering the block it could no longer point
    /// at. **On scroll it follows, and when its block leaves the top of the screen it pins to the
    /// first row** rather than being dismissed -- a response scrolled past is still the one being
    /// filtered, and taking the box away mid-word would lose what was typed.
    private func repositionLensField() {
        guard let view = lensField, let id = lensFieldBlock else { return }
        let frame = lensFieldFrame(for: id, height: view.intrinsicContentSize.height)
        if view.frame != frame { view.frame = frame }
    }

    /// The response body as a JSON document, for the field's own error message.
    private func lensBody(of id: UInt32) -> JSONValue? {
        guard case .request(let exchange)? = requestCache.entry(for: id),
              let exchange else { return nil }
        return LensRendering.bodyValue(exchange)
    }

    func dismissLensField() {
        lensField?.removeFromSuperview()
        lensField = nil
        lensFieldBlock = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Watching
    //
    // The pane owns a timer, a shell and a screen; `WatchSeries` owns every decision -- when the
    // next run is due, whether it may be sent, which runs fold, what the header says. Nothing here
    // re-derives any of that: the rules are tested without a terminal, and this is the wiring.

    /// Begins watching `command` in this pane. One series per pane: a second is what the user just
    /// asked for, so the first is stopped rather than left ticking invisibly behind it.
    ///
    /// `firstRunSent` is for the sheet's Repeat menu, which types the request itself so the user
    /// sees it go. A series starts *due*, so without this the first tick would type a second copy
    /// of the same request a quarter of a second later.
    @discardableResult
    func startWatch(plan: WatchPlan, command: String, firstRunSent: Bool = false) -> Bool {
        guard !command.isEmpty else { NSSound.beep(); return false }
        // A series only ever sends at a prompt, and a shell that emits no marks can never say it
        // is at one -- so a watch here would sit on a 250 ms timer until the pane closed and never
        // send a thing. Refused rather than started; callers that have something to undo first ask
        // `canWatch` instead, so the refusal happens before anything has been run.
        guard canWatch else {
            reportWatchRefused()
            return false
        }
        stopWatch(.stopped)
        let now = watchClock
        watch = WatchSeries(plan: plan, command: Pane.watchLine(command), startedAt: now)
        watchSentAt = firstRunSent ? now : nil
        // The sheet types its first run and then calls this, so the terminal has not seen the new
        // command yet: what it calls the last finished command is still the block *before* it.
        watchSentAfterCommandID = firstRunSent ? newestRunCommandID : 0
        updateWatchTimer()
        markDirty()
        return true
    }

    /// Whether a watch could run in this pane at all: the shell has to mark its prompts, because
    /// "is the shell free?" is the one question a series asks before every send.
    var canWatch: Bool { session.withTerminal { $0.shellEmitsPromptMarks } }

    /// The refusal itself, built apart from being shown so `UISnapshot` can picture it: an alert
    /// nobody has looked at is a sentence nobody has read, and this one is three lines long.
    static func watchRefusedAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot watch a request in this pane"
        alert.informativeText = "A watch sends its next run only when the shell is back at a "
            + "prompt, and this shell does not tell Nyx where its prompts are. Set "
            + "shell-integration = auto and open a new tab, or run the request from a pane that "
            + "has it."
        return alert
    }

    /// Says why a watch cannot start here.
    ///
    /// On the *window*, never on a sheet attached to it. `reportProjectWrite` puts its alert on
    /// `window.attachedSheet` because the sheet that asked stays up; this refusal's one caller is
    /// the request sheet's Repeat menu, which closes itself in the very next statement -- and an
    /// alert hosted by a sheet that is then ended is created, never shown, and its completion
    /// never runs. The user saw nothing at all. So: the window, and after the sheet has gone --
    /// see `presentRequestEditor`, which holds the refusal until `beginSheet`'s completion.
    private func reportWatchRefused() {
        let alert = Pane.watchRefusedAlert()
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            NSSound.beep()
        }
    }

    /// The line a series actually types: the request with Nyx's own measurement flags on it.
    ///
    /// A watch exists to say what each run answered and how long it took, and a bare `curl URL`
    /// can say neither -- it prints a body and nothing else, so every run comes back with no
    /// status and no `time_total`. Measured against the real fixture, a `Run until 200` on a
    /// hand-typed line never stopped (twenty-one runs and counting) because no run ever had a
    /// status to compare, and the header read "stopped after 3 runs" where it should have read
    /// "3 runs · p50 8 ms".
    ///
    /// These are the same additions the workbench's own Run makes (`RequestRun.commandLine`), and
    /// the same ones stripped back out of everything a user copies, exports or saves as a button
    /// -- so a watch of a block that was already run through the workbench re-types exactly the
    /// line that is on screen. A command that is not a `curl`, or one with a pipeline, is left
    /// exactly as it stands.
    static func watchLine(_ command: String) -> String {
        guard let parsed = CurlCommand.parse(command) else { return command }
        return RequestRun.commandLine(for: parsed)
    }

    /// Ends the series, if there is one still going. False when there was none, so a caller with a
    /// menu item or a chord can say so instead of pretending it did something.
    @discardableResult
    func stopWatch(_ reason: WatchSeries.Finish) -> Bool {
        guard var series = watch, !series.isFinished else { return false }
        series.stop(reason)
        watch = series
        watchSentAt = nil
        updateWatchTimer()
        markDirty()
        return true
    }

    /// Whether `⌘.` has a series to stop here.
    ///
    /// Only while the series' own newest run is the last request in the pane. `⌘.` is a chord
    /// people press for lots of reasons, and one that silently killed a watch three screens up --
    /// after they had gone on to run something else -- would be a stop they could not see.
    /// A series that has not run anything yet passes: nothing can be later than nothing.
    var canStopWatch: Bool {
        guard let series = watch, !series.isFinished else { return false }
        guard let newest = series.runs.last?.id else { return true }
        return latestRequestBlock() == newest
    }

    /// The last block in the pane whose command was a request. Also the fallback `lensTargetBlock`
    /// uses when there is no pointer, and the same answer for the same reason: "the response you
    /// were just looking at".
    private func latestRequestBlock() -> UInt32? {
        session.withTerminal { t -> UInt32? in
            t.promptRows.reversed().compactMap { row -> UInt32? in
                guard let region = t.command(containingAbsoluteRow: row), region.id != 0,
                      self.requestCache.isRequest(id: region.id) else { return nil }
                return region.id
            }.first
        }
    }

    /// The header for a block that is a series' newest run, or nil for every other block.
    ///
    /// Only the newest: the older runs are ordinary finished requests with their own summaries,
    /// and a timeline drawn beside each of them would be the same dots twenty times down a screen.
    private func watchHeader(forBlock id: UInt32) -> WatchHeader? {
        guard let series = watch, series.runs.last?.id == id else { return nil }
        return series.header()
    }

    /// The clock every reading the series is given comes from, so `at` values, deadlines and the
    /// terminal's own command timings are on one timeline.
    private var watchClock: Double { session.withTerminal { $0.now() } }

    /// The timer exists only while the series is waiting. No series, or one running or finished,
    /// and there is nothing to poll for -- the idle cost of a pane must stay at zero.
    private func updateWatchTimer() {
        let waiting: Bool = {
            guard let series = watch, !series.isFinished else { return false }
            if case .waiting = series.phase { return true }
            return false
        }()
        if waiting, watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.watchTick()
            }
        } else if !waiting, let timer = watchTimer {
            timer.invalidate()
            watchTimer = nil
        }
    }

    /// Four times a second while a run is due: is the shell free, and has the interval elapsed?
    ///
    /// Both questions are the series'. The one thing decided here is what "at a prompt" means for
    /// a real shell: no command running, and marks to know it by -- a session with no shell
    /// integration can never answer it, so a watch there simply never sends.
    private func watchTick() {
        guard let series = watch, !series.isFinished else {
            updateWatchTimer()
            return
        }
        let now = watchClock
        if let sentAt = watchSentAt {
            // Typed and not yet seen to start. Ask the buffer directly before giving up: a local
            // request can begin and end between two ticks, and on a pane with no frames the tick
            // is the only thing looking.
            pollWatch()
            if watch?.isFinished == true || watchSentAt == nil { return }
            if now - sentAt > Pane.watchStartTimeout { watchSentAt = nil }
            return
        }
        let atPrompt: Bool = session.withTerminal { t in
            t.shellEmitsPromptMarks && t.runningCommand == nil
        }
        guard series.shouldSend(now: now, shellAtPrompt: atPrompt) else { return }
        sendWatchRun(series.command, at: now)
    }

    /// The newest command in the pane that has actually run -- not the prompt the user (or the
    /// watch) is about to type at, which has an id already but has produced nothing. Read at the
    /// moment a run is typed, so that the run itself, whose id is the prompt's, is above it.
    private var newestRunCommandID: UInt32 {
        session.withTerminal { $0.lastFinishedCommand?.id ?? 0 }
    }

    /// Types one run at the shell.
    ///
    /// Bracketed like every other command Nyx types for the user, because a `\`-continued `curl`
    /// read back off the grid has real newlines in it and sent raw the shell would start running
    /// it a fragment at a time. Not through `performPaste`: that arms the `⌘E Workbench` pill for
    /// any pasted curl, and a pill flashing over the prompt every five seconds for a request the
    /// user is already watching is chrome arguing with itself.
    private func sendWatchRun(_ command: String, at now: Double) {
        let bracketed = session.withTerminal { $0.modes.bracketedPaste }
        let line = command.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        var bytes: [UInt8] = []
        if bracketed { bytes += Array("\u{1B}[200~".utf8) }
        bytes += Array(line.utf8)
        if bracketed { bytes += Array("\u{1B}[201~".utf8) }
        bytes += [0x0D]
        watchSentAt = now
        watchSentAfterCommandID = newestRunCommandID
        isSendingWatchRun = true
        send(bytes)
        isSendingWatchRun = false
    }

    /// The user has taken the shell back. Called from the two keyboard entry points rather than
    /// from `send`, because `send` is also how a quick action, a paste and the watch itself write
    /// to the shell, and none of those is somebody typing.
    private func stopWatchIfUserTyped() {
        guard !isSendingWatchRun, let series = watch, !series.isFinished else { return }
        stopWatch(.userTyped)
    }

    /// Moves the series on **without a frame**, from the coalesced check that already notices a
    /// command starting and finishing from the prompt marks alone.
    ///
    /// This is what makes a watch survive not being looked at. `render()` does not run for a pane
    /// whose tab is not selected (its view is out of the hierarchy), whose window is occluded, or
    /// whose window is minimised -- the display link is paused or invalidated -- and the frame
    /// builder is also the only thing that reads a block into the exchange cache. Driven from
    /// there alone, switching tabs mid-watch left the series `.waiting` on a deadline that had
    /// passed with a run it never saw start: every thirty seconds `watchStartTimeout` cleared the
    /// outstanding flag and the next tick typed the request again, for ever, ignoring the
    /// interval, never counting towards `.count(n)` and never testing an `until` condition.
    ///
    /// So the block is found by *id* rather than by being on screen, read through the same
    /// `requestSummary` the frame uses (one parse per block, cached, so a frame that later draws
    /// it does no work), and the series moved on. `render` goes on draining whatever it sees; the
    /// two cannot double-count, because `RequestSummaryCache.shouldParse` answers once per block.
    private func pollWatch() {
        guard let series = watch, !series.isFinished else { return }
        var runningID: UInt32?
        session.withTerminal { t in
            if self.watchSentAt != nil { runningID = t.runningCommand?.id }
            guard let region = self.watchCandidateBlock(of: series, in: t) else { return }
            // `requestSummary` is the finish signal: it reads the transcript, caches the exchange
            // and enqueues the run. It refuses a block that has not finished, which is the guard
            // that keeps a run in flight out of the series' statistics.
            _ = self.requestSummary(for: CommandBlock(region: region, visibleRows: 0..<0,
                                                      showsHeader: true), in: t)
        }
        drainPendingRecord()
        advanceWatch(runningCommandID: runningID)
        applyPendingLenses()
    }

    /// The block a waiting or running series is expecting an answer from, wherever it is on screen.
    ///
    /// While a run is `.running` that is its own block, by id. While one has been typed and not
    /// seen to start it is the last command in the buffer that has actually run -- the bottom
    /// region when it has output of its own, else the one before the prompt being typed at.
    private func watchCandidateBlock(of series: WatchSeries, in t: Terminal) -> CommandRegion? {
        if case .running(let id) = series.phase {
            return t.promptRow(ofCommand: id).flatMap { t.command(containingAbsoluteRow: $0) }
        }
        guard watchSentAt != nil, t.totalRows > 0,
              let bottom = t.command(containingAbsoluteRow: t.totalRows - 1) else { return nil }
        return bottom.outputStart == nil ? t.previousCommand(of: bottom) : bottom
    }

    /// Moves the series on by whatever this frame saw: a run that started, and runs whose blocks
    /// the cache finished reading. Called from `render` after the session lock.
    private func advanceWatch(runningCommandID: UInt32?) {
        guard watch != nil else {
            pendingWatchFinishes.removeAll()
            return
        }
        if watchSentAt != nil, let id = runningCommandID, var series = watch {
            series.runStarted(id: id, at: watchClock)
            watch = series
            if case .running = series.phase {
                watchSentAt = nil
                updateWatchTimer()
                markDirty()
            }
        }
        guard !pendingWatchFinishes.isEmpty else { return }
        let finishes = pendingWatchFinishes
        pendingWatchFinishes.removeAll()
        for finish in finishes { recordWatchRun(finish) }
    }

    /// One finished run: told to the series, then shown -- the older runs folded, the newest one
    /// lensed against the run before it.
    private func recordWatchRun(_ finish: WatchFinish) {
        guard var series = watch, !series.isFinished else { return }
        series.runFinished(id: finish.id, status: finish.status, exitStatus: finish.exitStatus,
                           timeTotal: finish.timeTotal, body: finish.body, at: finish.at)
        // The series drops a finish that is not its own; if it did, nothing here should happen
        // either -- least of all folding somebody else's block.
        guard series.runs.contains(where: { $0.id == finish.id }) else { return }
        watch = series
        watchSentAt = nil
        var moved = false
        for (index, run) in series.runs.enumerated() where series.shouldFold(runAt: index) {
            if folding.foldUnlessOpened(run.id, .all) { moved = true }
        }
        // The newest run's lens: what changed since the last one, when both are JSON and there is
        // a last one. Otherwise the configured default, which `requestSummary` has already armed.
        if series.runs.last?.id == finish.id, isJSONResponse(finish.id),
           let previous = previousRun(of: finish.id) {
            pendingDefaultLens.removeAll { $0 == finish.id }
            setLens(.diff(previousCommandID: previous), on: finish.id)
        }
        updateWatchTimer()
        if moved { forgetViewportAnchorIfItIsOnlyTheLiveBottom() }
        markDirty()
    }

    /// The `Watch…` popover, over the block's own command row.
    ///
    /// A popover anchored to the row rather than a sheet: what is being watched is *this* block,
    /// and a window-wide sheet loses that. It is `NSPopover`'s job to keep it there while the view
    /// scrolls, and to take it down on a click outside.
    private func presentWatchPlanEditor(seed: WatchPlan, command: String, on id: UInt32) {
        let editor = WatchPlanEditor(seed: seed)
        editor.onStart = { [weak self] plan in
            // Closed from here, not by the controller: `dismiss(nil)` only ends a *presented*
            // controller, and this one was handed to an `NSPopover` rather than presented -- so
            // pressing Start left the popover on screen over the watch it had just begun.
            self?.watchPopover?.performClose(nil)
            self?.watchPopover = nil
            self?.startWatch(plan: plan, command: command)
        }
        watchPopover?.performClose(nil)
        let popover = NSPopover()
        popover.contentViewController = editor
        popover.behavior = .transient
        watchPopover = popover
        // The command row if it is on screen, and the top of the pane if it is not -- the same
        // rule the filter field follows, and for the same reason: a response scrolled past is
        // still the one being asked about.
        var slot = 0
        if let promptRow = session.withTerminal({ $0.promptRow(ofCommand: id) }) {
            let top = session.withTerminal { max(0, $0.viewportTopRow) }
            slot = max(0, min(rows - 1, displaySlot(ofAbsoluteRow: promptRow, viewportTop: top) ?? 0))
        }
        let cell = cellSizePoints
        let y = bounds.height - padding - CGFloat(slot + 1) * cell.height
        popover.show(relativeTo: NSRect(x: padding, y: y, width: max(1, bounds.width - padding * 2),
                                        height: cell.height),
                     of: self, preferredEdge: .maxY)
    }

    /// Whether a block's response is JSON a lens can re-lay-out -- the precondition for diffing it
    /// against the run before.
    private func isJSONResponse(_ id: UInt32) -> Bool {
        guard case .request(let exchange)? = requestCache.entry(for: id), let exchange else {
            return false
        }
        return exchange.bodyKind == .json && !LensRendering.isTooLarge(exchange)
    }

    /// Writes the request read this frame to the history, outside the session lock. Called from
    /// `render` and from the context menu, which is the other place a block can be read.
    private func drainPendingRecord() {
        guard let line = recordAfterFrame else { return }
        recordAfterFrame = nil
        (NSApp.delegate as? AppDelegate)?.requests?.record(line)
    }

    /// What a finished block's request said, for its header -- nil for every block that is not a
    /// curl, which is almost all of them.
    ///
    /// A block is read the first frame it is on screen and finished, and never again: after that
    /// this is one dictionary lookup per visible block. `blocks` is empty for a shell with no
    /// prompt marks, so a session without integration never reaches here at all.
    ///
    /// Only *finished* blocks: a half-written transcript would parse to a head with no body and put
    /// a status on the row that the response has not actually finished delivering.
    private func requestSummary(for block: CommandBlock, in t: Terminal) -> HTTPSummary? {
        let id = block.region.id
        guard id != 0, !block.isRunning, block.region.outputStart != nil else { return nil }

        if requestCache.shouldParse(id: id) {
            let line = t.commandLine(of: block.region)
            guard CurlDetection.isCurl(line) else {
                requestCache.remember(.notARequest, for: id)
                return nil
            }
            // The one moment a request is known to have been *run*: this block is finished, it is a
            // curl, and no block this new has been recorded. Recorded here rather than when the
            // command is typed, because what the user re-runs from the palette must be a line that
            // ran, and recorded for a failed connection too -- "the deploy call that could not
            // reach the host" is exactly the one somebody wants back.
            //
            // `shouldRecord` and not `shouldParse`: reading happens again whenever the cache has
            // been trimmed and the block comes back on screen, and recording it again would stamp
            // last Tuesday's request with the time you scrolled past it.
            //
            // Recorded *after* the lock, in `render`: the store writes a file on its own queue and
            // takes its own lock, and doing that with the session's held puts a file write between
            // the PTY reader and every other pane in the window.
            if requestCache.shouldRecord(id: id) { recordAfterFrame = line }
            // A response big enough to fill the scrollback is not one whose body kind is worth
            // joining into a single string under the session lock. The head and the sentinel are
            // in the first and last rows of it, but reading only those would still walk the whole
            // region, so a run this large simply gets the ordinary summary.
            let exchange = block.region.outputRows.count > Pane.requestOutputRowLimit
                ? nil
                // The *logical* lines, not the rows: a JSON body is one line however wide the pane
                // is, and reading it as rows puts a newline inside a string literal, which no JSON
                // parser accepts. See `Terminal.outputLines(of:)`.
                : HTTPExchange.parse(lines: t.outputLines(of: block.region))
            requestCache.remember(.request(exchange), line: line, for: id)
            requestCache.trim(to: Pane.requestCacheLimit)
            // The one moment a response exists and nobody has looked at it yet, which is where the
            // default lens belongs. Not applied here: this runs under the session lock, and
            // building a lens means dispatching. `render` drains it the way it drains the history.
            if let exchange, config.httpLens == .pretty, exchange.bodyKind == .json,
               !LensRendering.isTooLarge(exchange) {
                pendingDefaultLens.append(id)
            }
            // And the one moment a watched run is known to have *finished*: reading the block is
            // what turns a transcript into a status and a timing, so this is where the series
            // hears about it. Whether it is the series' own run at all is `WatchSeries.owns`,
            // which is tested without a terminal -- an id comparison cannot tell a stranger's
            // curl from a later run of the watch.
            if let series = watch, series.owns(finishedBlock: id, outstanding: watchSentAt != nil,
                                               typedAfter: watchSentAfterCommandID) {
                pendingWatchFinishes.append(WatchFinish(id: id, status: exchange?.status,
                                                        exitStatus: block.region.exitStatus ?? 0,
                                                        timeTotal: exchange?.timing?.total,
                                                        body: exchange?.bodyLines.joined(separator: "\n") ?? "",
                                                        at: t.now()))
            }
        }
        // `.request(nil)` still produces a summary: a curl that could not connect prints no head
        // and no sentinel, and "exit 7 · connection refused" is the entire point of it.
        guard case .request(let exchange) = requestCache.entry(for: id) else { return nil }
        return HTTPSummary.make(exchange: exchange, exitStatus: block.region.exitStatus,
                                duration: block.region.duration)
    }

    /// Above this many output rows a block keeps its ordinary summary. 20,000 rows is twice the
    /// default scrollback: a response that long is a download, not something anyone reads a status
    /// line for.
    private static let requestOutputRowLimit = 20_000

    /// Where the `⌘E Workbench` pill goes this frame and what it says, or nil for no pill.
    ///
    /// Three questions, in the order that makes the common case free: is one armed at all (nothing
    /// is, in every pane nobody has pasted a `curl` into), is the line still worth offering it for,
    /// and is there anywhere to put it. The middle one asks `WorkbenchHint` about what is on the
    /// command line *now* rather than about the text that armed it, so backspacing the `curl` away
    /// takes the pill with it.
    ///
    /// Placed against the rows of the command line rather than of a block, and walked from the
    /// last row up the way the hover strip is: the first row from the bottom with room for the
    /// whole pill. A `curl` worth a workbench usually fills every row it touches, and then there
    /// is no pill -- covering four cells of a command somebody is still typing, to advertise a
    /// feature they did not ask for, is not a trade anyone agreed to.
    private func workbenchHintPlacement(in t: Terminal, lines: [Row], cellWidth: Double,
                                        screenRow: (Int) -> Int?) -> (slot: Int, text: String)? {
        guard let armed = hintCommand, Date.timeIntervalSinceReferenceDate < hintExpiry,
              cellWidth > 0 else { return nil }
        // With shell integration the line itself is the authority, and `currentInput` going nil --
        // the command was run, or the line was cleared -- takes the pill with it. Without it there
        // is nothing to read back, and the text that was pasted a moment ago is the best thing
        // known about the line.
        let line = t.shellEmitsPromptMarks ? t.currentInput : armed
        guard let line, WorkbenchHint.shouldShow(commandLine: line, hintEnabled: config.httpHint,
                                                 altScreen: t.modes.altScreen) else { return nil }
        let cursorRow = t.scrollback.count + t.screen.cursor.y
        let firstRow = min(t.currentInputStart?.row ?? cursorRow, cursorRow)
        var candidates: [(absoluteRow: Int, lastUsedColumn: Int)] = []
        var slotOf: [Int: Int] = [:]
        for absolute in firstRow...cursorRow {
            guard let slot = screenRow(absolute), slot < lines.count else { continue }
            slotOf[absolute] = slot
            candidates.append((absoluteRow: absolute,
                               lastUsedColumn: CommandBlockChrome.lastUsedColumn(of: lines[slot])))
        }
        // The chord as the palette writes it, from the table this pane matches keys against: `⌘E`
        // is a default, and a config that has moved it must not be told to press it.
        let text = WorkbenchHint.text(chord: bindings.binding(for: .editAndRunCommand)?.displayName ?? "")
        let columns = Int((workbenchHint.width(for: text) / cellWidth).rounded(.up))
        // The pill shows itself, with no pointer near it, so a command line with no room simply
        // gets no pill -- the hover strip is the only chrome that may cover text, and only because
        // a pointer is deliberately on it. Walked from the last row up, the way every other piece
        // of block chrome is placed against a wrapped command.
        for row in candidates.reversed() {
            let free = CommandBlockChrome.freeColumns(cols: t.cols, lastUsedColumn: row.lastUsedColumn)
            guard columns <= free, let slot = slotOf[row.absoluteRow] else { continue }
            return (slot: slot, text: text)
        }
        return nil
    }

    /// Offers the workbench for a `curl` that has just been pasted, for `WorkbenchHint.seconds`.
    ///
    /// Armed from the paste rather than from the shell's echo: the paste is the moment we know a
    /// request arrived, and waiting to recognise it in the grid would mean recognising every line
    /// the user types by hand as well -- a pill that appears while you are still typing a command
    /// is chrome nobody asked for.
    private func armWorkbenchHint(for text: String) {
        guard config.httpHint, !text.isEmpty, CurlDetection.isCurl(text) else { return }
        guard !session.withTerminal({ $0.modes.altScreen }) else { return }
        hintCommand = text
        hintExpiry = Date.timeIntervalSinceReferenceDate + WorkbenchHint.seconds
        hintTimer?.invalidate()
        // Half a second past the deadline, so the frame this asks for is one where the pill has
        // certainly expired rather than one racing it.
        hintTimer = Timer.scheduledTimer(withTimeInterval: WorkbenchHint.seconds + 0.5, repeats: false) {
            [weak self] _ in self?.dismissWorkbenchHint()
        }
        markDirty()
    }

    /// Takes the pill away: a key press, the deadline, or the workbench having been opened.
    private func dismissWorkbenchHint() {
        guard hintCommand != nil else { return }
        hintCommand = nil
        hintTimer?.invalidate()
        hintTimer = nil
        markDirty()
    }

    /// The pill was clicked: the line it is sitting on, in the workbench.
    ///
    /// The line as the shell has it, falling back to the text that armed the pill -- without shell
    /// integration there is no `currentInput` to read, and the pasted text is what is on the line.
    private func openWorkbenchFromHint() {
        let typed: String? = session.withTerminal { $0.currentInput }
        let line = typed ?? hintCommand
        dismissWorkbenchHint()
        guard let line, !line.isEmpty else { return }
        editCurrentInput(line)
    }

    private func render() {
        // Asked before the frame is built, not after: while an application is inside a synchronised
        // update (DECSET 2026) the frame would be thrown away, and building one walks the grid, the
        // blocks and the prompt marks under the session lock the PTY reader is waiting for.
        let syncOutput = session.withTerminal { $0.modes.syncOutput }
        guard renderer.canPresent(syncOutput: syncOutput) else {
            // Still stale, and the link stays awake: the hold has to end on the mode being cleared
            // or on the gate's timeout, and both are noticed by ticking.
            dirty.set()
            return
        }
        let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
        let preedit = markedText.isEmpty ? nil : markedText
        // The mark at the head of each block's spine, per display slot: shape, colour and whether
        // it can be pressed, all decided by `CommandBlockChrome.gutterCap`. Built from the very
        // blocks and headers this frame draws, so the cap, the spine and the summary cannot
        // disagree about what a command did -- and so the gutter steps aside with the rest of the
        // chrome when a full-screen program owns the display.
        var gutterCaps: [Int: CommandBlockChrome.GutterCap] = [:]
        // What each mark *would* say in its tooltip and to VoiceOver, as the four facts the
        // sentence is made of rather than the sentence: this loop runs under the PTY lock on every
        // frame, and `GutterMarkLabel.Key` is four stored properties where the string it produces
        // was four interpolations per command on screen. The gutter view formats them when the set
        // changes, which is when a command started, finished, or was folded.
        var gutterLabels: [Int: GutterMarkLabel.Key] = [:]
        var notes: [String?] = []
        var spines: [(rows: Range<Int>, color: RGB)] = []
        var summaries: [(row: Int, text: String, color: RGB)] = []
        var sticky: (text: String, row: Int, summary: String, tone: SummaryTone)?
        var anyRunningOnScreen = false
        // Where the workbench pill goes this frame and what it says, or nil for no pill. Decided
        // under the lock with the rest of the chrome, applied after it.
        var hint: (slot: Int, text: String)?
        // Set under the lock, acted on after it: the overlay and the cursor rects are AppKit calls.
        var hoverChanged = false
        /// The block the filter field belongs to has been cleared away or evicted; see below.
        var dismissField = false
        /// The buffer this series' runs lived in has gone; see below.
        var abandonWatch = false
        // What the buffer looked like when the frame was built. The dirty flags are cleared against
        // it once the frame is on screen, so a write that lands in between keeps its flags.
        var builtAtContentVersion: UInt64 = 0
        /// Which command the shell says is running, read only while a watch is waiting to see its
        /// own run start. Acted on after the lock, with everything else the frame noticed.
        var runningCommandID: UInt32?
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
                // A block hover is a range of rows in the same absolute space; a `clear` moves
                // every one of them out from under it. Re-resolved below from the pointer's own
                // position, so the very next frame puts it back if there is still a block there.
                self.hoveredBlock = nil
            }
            // A fold is an absolute row, and a `clear` makes every absolute row mean something
            // else; keeping them would collapse whatever landed on those indices.
            if self.foldingGeneration != t.scrollbackGeneration {
                self.foldingGeneration = t.scrollbackGeneration
                self.folding.unfoldAll()
                // A lens replaces a block's rows; with every absolute row meaning something else
                // there is no block left to replace, and the buffers are readings of text that has
                // gone.
                self.lenses = LensChoices()
                self.lensBuffers.removeAll()
                self.lensSelection = nil
                // And the field, which is a filter on a response that no longer exists. Flagged
                // rather than done: this runs under the session lock and dismissing touches AppKit.
                if self.lensFieldBlock != nil { dismissField = true }
                self.forgetViewportAnchor()
                // Every block the series made is gone, and its ids now name other rows: kept, its
                // header would sit on a stranger's command and its folds would collapse one. A
                // watch cleared out from under itself is stopped and forgotten rather than left
                // pointing at rows that no longer exist.
                if self.watch != nil { abandonWatch = true }
            }
            // Rows have gone from under the numbering, so the row the anchor names is not the row
            // it was chosen on -- it is that many rows further up. Moved rather than forgotten:
            // forgetting it sent `viewportCursor` back to the terminal's own row, which inside a
            // lens means the block's row *offset* and not the line the reader was on, so a reader
            // seventy lines into a response was put back to line thirteen of it once per evicted
            // row for as long as anything else was printing. See `DisplayCursor.shifted`.
            //
            // Before the pruning below and outside its guard: the anchor has to follow the rows on
            // every frame that loses one, not only on the frames that have a fold or a lens to
            // prune.
            if t.evictedRows != self.lastAnchorEvictedRows {
                let previous = self.lastAnchorEvictedRows
                self.lastAnchorEvictedRows = t.evictedRows
                if previous >= 0 {
                    if let moved = DisplayCursor.shifted(anchor: self.viewportAnchor,
                                                         anchorTop: self.viewportAnchorTop,
                                                         evictedBefore: previous,
                                                         evictedAfter: t.evictedRows,
                                                         viewportTopRow: t.viewportTopRow) {
                        self.viewportAnchor = moved.anchor
                        self.viewportAnchorTop = moved.anchorTop
                    } else {
                        self.forgetViewportAnchor()
                    }
                }
            }
            // Folds whose prompt has gone -- evicted from the ring, or overwritten -- are dropped
            // here rather than accumulating over a session, and with them any notification armed
            // for an id that can never finish now.
            //
            // Only when the buffer actually lost rows. `oldestCommandID` walks forward from the
            // start of the ring looking for the first prompt, and doing that on every frame of a
            // session that has one fold open -- under the session lock, on the render path -- was
            // paying for a scan whose answer cannot have changed. Nothing else moves the oldest id:
            // it changes when rows are evicted, or when the whole buffer is replaced.
            let bufferMoved = t.evictedRows != self.lastPruneEvictedRows
                || t.scrollbackGeneration != self.lastPruneGeneration
            if bufferMoved, !(self.folding.isEmpty && self.armedNotifications.isEmpty
                                && self.requestCache.isEmpty && self.lenses.isEmpty) {
                self.lastPruneEvictedRows = t.evictedRows
                self.lastPruneGeneration = t.scrollbackGeneration
                let oldest = t.oldestCommandID
                if !self.folding.isEmpty { self.folding.prune(olderThan: oldest) }
                if !self.armedNotifications.isEmpty {
                    self.armedNotifications = self.armedNotifications.filter { $0 >= oldest }
                }
                // A reading outlives the rows it was made from by exactly nothing: once the block
                // is evicted its id can never come back, and the entry is a leak.
                self.requestCache.prune(olderThan: oldest)
                if !self.lenses.isEmpty {
                    self.lenses.prune(olderThan: oldest)
                    self.lensBuffers = self.lensBuffers.filter { $0.key >= oldest }
                }
                if let field = self.lensFieldBlock, field < oldest { dismissField = true }
            }
            // Screen coordinates: `cursor.y` counts from the top of the live screen. The renderer
            // takes it as an index into the lines it is handed, which are display slots, so with a
            // fold on screen it is remapped below -- and the IME preedit with it, since that is
            // drawn from the same coordinate.
            var cursor: Cursor? = (t.modes.showCursor && t.viewportOffset == 0) ? t.screen.cursor : nil
            // Resolved here, inside the lock, so the highlighted columns belong to the same
            // viewport as the lines being drawn.
            let top = t.viewportTopRow
            // A `var` for one assignment: the row the sticky band covers is blanked below, which is
            // one row of an array this pass already owns.
            var lines: [Row]
            let selected: [Range<Int>?]
            let matches: [[Range<Int>]]
            let current: [Range<Int>?]
            let hovered: [Range<Int>?]
            if self.folding.isEmpty && self.lenses.isEmpty {
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
                // From the display cursor, not from `top`: a lens is taller or shorter than the rows
                // it replaces, so which of its lines is at the top of the screen is the pane's own
                // state and cannot be recovered from an absolute row. See `DisplayCursor`.
                // One memo for the whole frame: finding the cursor and drawing from it both walk
                // the same blocks, and the terminal is locked between them, so nothing can have
                // moved the rows it remembers. See `CommandRegionMemo`.
                let memo = CommandRegionMemo()
                // Once per frame, never per row: resolving the theme's dim colour walks a blend
                // ladder, and there are as many rows as the window is tall.
                let lensPalette = LensPalette.forTheme(t.palette)
                let placeholderDim = LensPalette.dimColour(in: t.palette)
                let display = t.displayRows(from: self.viewportCursor(in: t, memo: memo),
                                            count: t.rows,
                                            folding: self.folding, lenses: self.lenses,
                                            buffers: { self.lensBuffers[$0] }, memo: memo)
                self.foldRowsOnScreen = display
                // The caret goes through the same map as the text under it. Without this it was
                // drawn at `cursor.y` -- as many rows below the prompt as the folds above had
                // hidden -- which with two folds on screen put it nine rows down an empty screen.
                // A caret whose row is inside a fold is not drawn at all: it has no slot.
                if let c = cursor {
                    let absolute = t.scrollback.count + c.y
                    cursor = DisplayRows.cursorSlot(absoluteRow: absolute, in: display)
                        .map { Cursor(x: c.x, y: $0) }
                }
                lines = display.map { row in
                    switch row {
                    case .row(let absolute): return t.absoluteRow(absolute) ?? Row(cols: t.cols)
                    case .fold(_, let hidden, let status):
                        return t.foldPlaceholderRow(hiddenRows: hidden, status: status,
                                                    dim: placeholderDim)
                    case .lens(let id, let index):
                        // A blank row rather than nothing at all when the buffer has just been
                        // replaced under the display: the next frame has the right lines, and one
                        // empty row is better than a slot count that does not match the display.
                        return self.lensBuffers[id]?.row(index, cols: t.cols,
                                                         palette: lensPalette)
                            ?? Row(cols: t.cols)
                    }
                } + Array(repeating: Row(cols: t.cols), count: max(0, t.rows - display.count))
                selected = display.map { row in
                    switch row {
                    case .row(let absolute):
                        return self.selection?.columnRange(onRow: absolute, cols: t.cols)
                    case .lens(let id, let index):
                        // The lens has its own selection, in its own coordinates, drawn through the
                        // same channel: the renderer is handed cell ranges either way.
                        guard let selection = self.lensSelection, selection.commandID == id,
                              let buffer = self.lensBuffers[id] else { return nil }
                        return selection.columns(onLine: index, in: buffer)
                    case .fold:
                        return nil
                    }
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

            // The window of absolute rows this frame actually shows. Without a fold it is
            // `top ..< top + rows`; with one, hiding a thousand rows pulls rows from far below into
            // the same slots, and a chrome window of `rows` absolute rows stopped above every block
            // under the placeholder -- they lost their spine, their summary and their gutter mark.
            let windowTop = max(0, t.viewportTopRow)
            let lastRowOnScreen: Int = {
                let plain = windowTop + t.rows - 1
                guard !self.foldRowsOnScreen.isEmpty else { return plain }
                let displayed = self.foldRowsOnScreen.compactMap { entry -> Int? in
                    if case .row(let absolute) = entry { return absolute } else { return nil }
                }
                return displayed.max() ?? plain
            }()

            // Per display slot when a fold is on screen, per visible row otherwise. Not through a
            // window of absolute rows reaching `lastRowOnScreen`: that window spans everything the
            // fold hides, and a note per row of it costs 3.3 ms a frame at a 10,000-row fold
            // against 0.019 ms for the rows actually drawn. `visibleBlocks` below does take the
            // window, because a block's own region spans the hidden rows and it walks commands
            // rather than rows.
            if self.foldRowsOnScreen.isEmpty {
                notes = t.durationNotes(rows: t.rows)
            } else {
                let pad = max(0, t.rows - self.foldRowsOnScreen.count)
                notes = t.durationNotes(onDisplayRows: self.foldRowsOnScreen)
                    + Array(repeating: nil, count: pad)
            }
            // Blocks are chrome over an unmodified grid, so they step aside entirely when a
            // full-screen program owns the display or the mouse. This is the rule that keeps vim,
            // htop and tmux behaving exactly as they did.
            let chromeAllowed = CommandBlockChrome.isAllowed(altScreen: t.modes.altScreen,
                                                             mouseReporting: t.modes.mouse != .none,
                                                             hasMarks: t.shellEmitsPromptMarks)
            let blocks = chromeAllowed ? t.visibleBlocks(from: windowTop, through: lastRowOnScreen) : []
            self.displayBlockRows = Dictionary(blocks.map { ($0.region.id, $0.region.promptRow) },
                                               uniquingKeysWith: { first, _ in first })
            // Which block the pointer is on, decided here rather than in `mouseMoved`, against the
            // very blocks and display rows this frame is about to draw.
            //
            // Recomputing it only on a pointer move meant the tint outlived what it was describing:
            // it stayed on screen when a TUI took the display (nothing gated `highlightedRows` on
            // `chromeAllowed`), and after a scroll it sat on whatever rows had moved into those
            // slots. Doing it per frame makes the hover follow the rows the way the hovered link
            // does (spec 4.2), and no scroll, fold, search reveal or autoscroll needs to remember
            // to invalidate it.
            let previousHover = self.hoveredBlock
            self.hoveredBlock = self.resolveBlockHover(in: t, blocks: blocks, allowed: chromeAllowed,
                                                       viewportTop: windowTop)
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
                // `block.visibleRows` spans everything a tail fold hides once `visibleBlocks`
                // widened the window to the block's own region, so calling `screenRow` -- itself a
                // linear search of the display slots -- once per row here was quadratic in the
                // hidden row count. `DisplayRows.slots` walks the display once instead; with no
                // folds on screen `screenRow` is already O(1) per row and stays as it was.
                let placedRange: Range<Int>?
                if self.foldRowsOnScreen.isEmpty {
                    let placed = block.visibleRows.compactMap { screenRow($0 + windowTop) }
                    if let first = placed.min(), let last = placed.max() {
                        placedRange = first..<(last + 1)
                    } else {
                        placedRange = nil
                    }
                } else {
                    placedRange = DisplayRows.slots(coveredBy: block.visibleRows, commandID: block.region.id,
                                                    in: self.foldRowsOnScreen, viewportTop: windowTop)
                }
                // Below the cap's own row, never over it: `CommandBlockChrome.spineRows` says why,
                // and the gutter's hollow ring and 40 % cap are what a spine over the prompt row
                // used to paint out.
                guard let placedRange,
                      let spineRange = CommandBlockChrome.spineRows(placed: placedRange,
                                                                    headOnScreen: block.showsHeader)
                else { return nil }
                return (rows: spineRange,
                        color: block.failed ? failedColor : (block.isRunning ? runningColor : doneColor))
            }
            // A summary only where the command it describes is on screen, and only when it has
            // something to say -- `exit 0` on a command that took no time is not news.
            let now = t.now()
            var headers: [Int: BlockHeader] = [:]
            // Which display slot the hover strip goes on. Only the hovered block ever sets it, so
            // "no room for a strip anywhere on this command" comes out as no overlay at all.
            var stripSlots: [UInt32: Int] = [:]
            // Every slot whose duration note the summary now speaks for, including the prompt row
            // when the summary moved off it onto a wrapped continuation.
            var notesSpokenFor: Set<Int> = []
            let overlayFont = NSFont.monospacedSystemFont(ofSize: effectiveFontSize, weight: .regular)
            let cellWidth = self.cellSizePoints.width
            // Only the hovered block ever sets it, and only when a row had room: "no strip anywhere
            // on this command" has to come out as no strip rather than as last frame's.
            self.hoverStripPlan = nil
            summaries = blocks.compactMap { block -> (row: Int, text: String, color: RGB)? in
                guard block.showsHeader, let promptSlot = screenRow(block.region.promptRow) else { return nil }
                // In this order: reading the block is what puts "was this a request" in the cache,
                // and `isRequest` is that cached answer rather than a second parse of the grid.
                let httpSummary = self.requestSummary(for: block, in: t)
                let header = block.header(now: now, folding: self.folding,
                                          notifyArmed: self.armedNotifications.contains(block.region.id),
                                          anyFolds: !self.folding.isEmpty,
                                          hasOutput: t.commandHasOutput(atAbsoluteRow: block.region.promptRow),
                                          httpSummary: httpSummary,
                                          isHTTP: self.requestCache.isRequest(id: block.region.id),
                                          lens: self.lenses.lens(of: block.region.id),
                                          lensTooLarge: self.lensIsTooLarge(block.region.id),
                                          bodyIsJSON: self.bodyIsJSON(block.region.id),
                                          // Only the ⋯ menu needs it, and finding it parses command
                                          // lines: not a question for sixty frames a second.
                                          hasPreviousRun: false,
                                          watch: self.watchHeader(forBlock: block.region.id),
                                          watchInterval: self.config.httpWatchInterval)
                // The head of this block's spine, before any of the ladders below can `return nil`:
                // a command whose summary does not fit anywhere still has a mark, and that mark is
                // the one route to folding it with the mouse.
                if let cap = CommandBlockChrome.gutterCap(
                        header,
                        hasStarted: t.commandDidStart(atAbsoluteRow: block.region.promptRow),
                        hovered: self.hoveredBlock?.id == block.region.id) {
                    gutterCaps[promptSlot] = cap
                    gutterLabels[promptSlot] = GutterMarkLabel.Key(
                        mark: block.failed ? .failed : (block.isRunning ? .running : .succeeded),
                        folded: header.folded, hasOutput: header.hasOutput, line: promptSlot + 1)
                }
                // The sentence only. The chevron that used to follow it was a control, and the
                // gutter cap is the control now: what stays here is a readout (§2.4).
                let text = header.summary
                // Every row of the command line is a candidate, not just the prompt row: a pasted
                // `curl` wraps, and the row that has room is usually the last one.
                let lastCommandRow = block.region.outputStart.map { $0 - 1 } ?? block.region.promptRow
                var candidates: [(absoluteRow: Int, lastUsedColumn: Int)] = []
                var slotOf: [Int: Int] = [:]
                if lastCommandRow >= block.region.promptRow {
                    for absolute in block.region.promptRow...lastCommandRow {
                        guard let slot = screenRow(absolute), slot < lines.count else { continue }
                        slotOf[absolute] = slot
                        candidates.append((absoluteRow: absolute,
                                           lastUsedColumn: CommandBlockChrome.lastUsedColumn(of: lines[slot])))
                    }
                }
                // Where the summary would go if there were no strip at all, asked first so the
                // suppression rule can compare what the two of them say. A row with no room for the
                // whole sentence carries none of it, so whatever is placed is the whole fact.
                let summaryHere = text.isEmpty ? nil : CommandBlockChrome.summaryPlacement(
                    commandRows: candidates, textCount: text.count, cols: t.cols)
                let placedSummary: CommandBlockChrome.PlacedSummary? = summaryHere.map {
                    (row: $0.row, text: text)
                }
                // The hovered block's strip is placed by the same ladder against the same rows,
                // from the view's own measured width. Measured here, under the lock, because the
                // answer decides what the Metal pass draws on those rows and the frame is built
                // here; the widths are cached per content and font, so in steady state this is one
                // dictionary lookup and no layout pass.
                if self.hoveredBlock?.id == block.region.id, self.hoveredBlock?.headerRow != nil,
                   cellWidth > 0,
                   let placement = CommandBlockChrome.stripPlacement(
                        header, commandRows: candidates, cols: t.cols, summary: placedSummary,
                        measure: { Int((self.blockHeader.width(of: $0, font: overlayFont) / cellWidth).rounded(.up)) }),
                   let slot = slotOf[placement.row] {
                    headers[slot] = header
                    stripSlots[block.region.id] = slot
                    self.hoverStripPlan = placement.plan
                    notesSpokenFor.insert(slot)
                    notesSpokenFor.insert(promptSlot)
                    // §2.5: the summary gives way only to a strip **on its own row that repeats
                    // it word for word**. A wrapped watched command whose last row is full places
                    // its lone `Stop` there and keeps its sentence on the row above; at W0, and on
                    // a row that had no room at all, there is no strip and the summary stays.
                    if CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                            summary: placedSummary) {
                        return nil
                    }
                }
                // Nothing to say and nothing to fold: a quick success with no output. No summary,
                // and no click target either.
                guard !text.isEmpty else {
                    headers[promptSlot] = header
                    return nil
                }
                // The same rule the renderer uses to decide what it draws and where, so the click
                // target and the pixels can never disagree.
                guard let placement = summaryHere, let slot = slotOf[placement.row] else { return nil }
                headers[slot] = header
                notesSpokenFor.insert(slot)
                notesSpokenFor.insert(promptSlot)
                // A running block used to differ from a finished one only by the digit in the
                // elapsed time -- the same grey `12s` a finished command's `12s` shows. The
                // theme's running colour is the one the spine already uses for the same state,
                // so a glance down the screen says which command is still going. `tone` is the same
                // ladder the hover strip and the sticky strip use, so a 404 is red in all three.
                // Resolved against the row's own hover **tint**, not `palette.background`: the
                // summary is drawn on the tint the moment the pointer arrives, where the neutral
                // `8.8s` measured 4.17:1 (design D1). The tint is the harder ground, so one
                // resolution reads on both and the colour does not change under the pointer.
                return (row: slot, text: text,
                        color: header.tone.color(in: t.palette, on: t.palette.blockHoverBackground))
            }
            // The overlay goes where it fits, which is not always the prompt row: a strip placed
            // from the prompt row alone and sized only from its own content painted over the end of
            // the command it describes, and in a narrow split hid a word of it. No placement means
            // no overlay: the tint, the gutter cap, the in-grid summary and the context menu remain.
            if let hover = self.hoveredBlock, hover.headerRow != nil,
               stripSlots[hover.id] != hover.headerRow {
                self.hoveredBlock = hover.attachingHeader(to: stripSlots[hover.id])
            }
            hoverChanged = self.hoveredBlock != previousHover
            self.headersOnScreen = headers
            anyRunningOnScreen = blocks.contains { $0.isRunning && $0.showsHeader }
            // The summary already carries the duration, and both draw right-aligned on a row of the
            // command: left alone they paint the same glyphs twice in two colours, on the failure
            // case this feature exists to make obvious.
            //
            // Keyed off where a summary was actually *placed*, not off the list of summaries asked
            // for: a command line that leaves room for nothing at all means the renderer draws
            // nothing there, and erasing the duration note as well left that row with neither. The
            // command's prompt row goes with it, because a summary that moved onto a wrapped
            // continuation row would otherwise say the duration one row below the note.
            for row in notesSpokenFor where notes.indices.contains(row) {
                notes[row] = nil
            }
            // The pill over the command line the user is typing at. Not gated on `chromeAllowed`:
            // it belongs to the line rather than to a block, so it appears in a shell with no
            // integration at all -- where there are no blocks and never will be -- and its own rule
            // (`WorkbenchHint.shouldShow`) keeps it off the alternate screen.
            hint = self.workbenchHintPlacement(in: t, lines: lines, cellWidth: cellWidth,
                                               screenRow: screenRow)
            // Same pass, same lock, same viewport: the strip names the command whose output is on
            // screen *in this frame*, and reading it anywhere else would let the two disagree.
            // Costs one flag test for a shell with no integration, which is the whole reason
            // `shellEmitsPromptMarks` exists.
            if let pinned = t.stickyPrompt(), let region = t.command(containingAbsoluteRow: pinned.row) {
                // Same fields the hover overlay would show for this command, so the strip and the
                // overlay never disagree about what a command's duration, exit status or HTTP
                // response was. The block is the pinned one, which is on screen by definition of
                // there being a strip, so its exchange is the one already parsed for the header.
                let block = CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true)
                let header = block.header(now: t.now(), folding: self.folding, notifyArmed: false,
                                          anyFolds: !self.folding.isEmpty,
                                          hasOutput: t.commandHasOutput(atAbsoluteRow: region.promptRow),
                                          httpSummary: self.requestSummary(for: block, in: t),
                                          watch: self.watchHeader(forBlock: region.id))
                // No `failed` flag beside the tone: a curl that returned 404 exited 0, so the
                // command did not fail and the response did, and `BlockHeader.tone` is the one
                // place that distinction is made.
                // `summary:` so the status is said once: the note on the right of the band already
                // reads `exit 2 · 8.8s`, and the text appended `  exit 2` to the command as well.
                sticky = (StickyPromptLabel.text(command: t.commandText(of: region),
                                                 exitStatus: pinned.exitStatus, columns: t.cols,
                                                 summary: header.summary),
                          pinned.row, header.summary, header.tone)
            }
            if self.watchSentAt != nil { runningCommandID = t.runningCommand?.id }
            builtAtContentVersion = t.contentVersion
            var dirty = self.dirtyRows(of: t, top: top)
            // `stickyPromptRow` has been computed since the strip existed and read only by the
            // click handler. The row the band covers is blanked in the frame, so the pinned command
            // and the output beneath it cannot print on top of each other -- which the opaque ground
            // alone does not fix: the band is one row tall over a grid whose glyphs overhang their
            // own cells at `line-height` below 1, so the descenders of the covered row came out
            // above and below it.
            //
            // The blanked slot is the one `layoutStickyStrip` puts the band on: the top row, or the
            // one below it while the remote strip has the top.
            // Keyed on the text, not on `sticky != nil`: an empty text hides the band
            // (`StickyPromptView.update`), and blanking a row with nothing drawn over it is one row
            // of somebody's output silently gone.
            let blankRow = self.stickyStripRow
            let pinned = !(sticky?.text.isEmpty ?? true)
            if pinned, blankRow < lines.count {
                lines[blankRow] = Row(cols: t.cols)
            }
            // The renderer caches shaped rows and rebuilds a row only when the terminal says it
            // changed or its `RowKey` moved, and neither hears about this: blanking is done to the
            // frame after the buffer has spoken. Without saying so, the band's first frame drew the
            // old glyphs under it, and the frame that unpinned it left the row blank with nothing
            // over it -- one row of somebody's output missing until it was next written to. An
            // empty `dirty` already means "everything changed".
            let blanked = pinned ? blankRow : nil
            if blanked != self.blankedStickyRow, !dirty.isEmpty {
                for row in [blanked, self.blankedStickyRow].compactMap({ $0 })
                where dirty.indices.contains(row) {
                    dirty[row] = true
                }
            }
            self.blankedStickyRow = blanked
            return RenderFrame(cols: t.cols, rows: t.rows, lines: lines, graphemes: t.graphemes, palette: t.palette,
                               cursor: cursor, cursorShape: t.cursorShape, focused: focused, preedit: preedit,
                               selection: selected, searchMatches: matches, currentSearchMatch: current,
                               hoveredLink: hovered, rowNotes: notes, blockSpines: spines,
                               blockSummaries: summaries, highlightedRows: self.hoveredBlock?.rows,
                               dirtyRows: dirty)
        }
        drainPendingRecord()
        if abandonWatch {
            stopWatch(.stopped)
            watch = nil
            pendingWatchFinishes.removeAll()
            watchSentAt = nil
            updateWatchTimer()
        }
        // Before `applyPendingLenses`: a watched run that is going to open in `diff` takes itself
        // off the default-lens list, and the default would otherwise win the race and open it in
        // `pretty` for one frame.
        advanceWatch(runningCommandID: runningCommandID)
        applyPendingLenses()
        // A running command's elapsed time only moves if something asks for a redraw; nothing else
        // on this row changes while it runs. One timer per pane, alive only while it would do
        // anything -- the idle-CPU cost of a terminal sitting at a prompt must stay at zero.
        if anyRunningOnScreen, runningTimer == nil {
            runningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.markDirty() }
        } else if !anyRunningOnScreen, let timer = runningTimer {
            timer.invalidate()
            runningTimer = nil
        }
        // The pointing hand over a gutter mark is a cursor rect, and nothing rebuilds those on its
        // own between frames: after a command finished, its new mark had no hand until the window
        // was resized. Only when the set of pressable marks actually moved -- `resetCursorRects` is
        // not free to ask for per frame.
        if gutter.update(caps: gutterCaps, labels: gutterLabels, palette: frame.palette,
                         cellHeight: cellSizePoints.height, padding: padding, topPadding: padding) {
            window?.invalidateCursorRects(for: gutter)
        }
        stickyPromptRow = sticky?.row
        let wasHidden = stickyStrip.isHidden
        // The pane's own face, not `.monospacedSystemFont`: the band's text is a copy of a row of
        // this grid and is kerned onto this grid's columns, and at any `font-family` but `system`
        // those were two different faces.
        stickyStrip.update(text: sticky?.text, summary: sticky?.summary ?? "", tone: sticky?.tone ?? .plain,
                           palette: frame.palette,
                           font: Pane.terminalFont(family: config.fontFamily, fonts: fonts,
                                                   size: effectiveFontSize),
                           padding: padding, cellWidth: cellSizePoints.width,
                           cellHeight: cellSizePoints.height)
        // The strip claims the pointer only while it is up, so appearing or disappearing changes
        // which view the cursor over the top row belongs to.
        if wasHidden != stickyStrip.isHidden { window?.invalidateCursorRects(for: stickyStrip) }
        // After the sticky strip so a running command's timer and a fold toggle -- both of which
        // can change the header without a matching pointer move -- refresh the overlay's text too;
        // `update` compares before it applies, so redrawing here every frame is cheap. `frame.palette`
        // was already read under the lock this frame; passing it on saves a second lock take.
        blockHeaderChanged(palette: frame.palette)
        if dismissField { dismissLensField() } else { repositionLensField() }
        workbenchHint.update(text: hint?.text, palette: frame.palette)
        if let hint {
            let size = workbenchHint.intrinsicContentSize
            let origin = overlayOrigin(forHeaderRow: hint.slot)
            // The pill is a control on a row, and a row is 13 pt at `line-height 0.8` (§8.4): the
            // last one-row target in a pane that was still exactly one cell tall. It takes the same
            // floor every other one does and is centred on its row, so it overhangs by up to 1.5 pt
            // rather than being a 13 pt button.
            let height = CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cellSizePoints.height)))
            // Right-aligned on the row the placement chose. Nothing to invalidate when it appears
            // or goes: the pill is a subview, so AppKit resolves both the click and the cursor
            // through it while it is up (`hitTest` returns nil when it is hidden) -- the pane's own
            // cursor rects, which are the pointing hands over links, are unaffected either way.
            workbenchHint.frame = NSRect(x: origin.x - size.width,
                                         y: origin.y + (cellSizePoints.height - height) / 2,
                                         width: size.width, height: height)
        }
        // Only when the block under the pointer actually changed: rebuilding cursor rects asks
        // AppKit to re-run `resetCursorRects` for the view, which is not free per frame.
        if hoverChanged { updateHoverCursor() }
        switch renderer.draw(frame, in: metalLayer, padding: Int(padding * metalLayer.contentsScale),
                             syncOutput: syncOutput) {
        case .presented:
            // Only now, and only if nothing was written in between: the flags say "this row has not
            // been drawn since it changed", and the renderer skips the rows they do not name.
            // Clearing them for a frame that was never presented is how a row goes stale forever.
            session.withTerminal { _ = $0.clearDirty(ifContentVersionIs: builtAtContentVersion) }
        case .noDrawable, .held:
            // Nothing reached the screen. Keep the frame stale so the next tick retries rather than
            // pausing the link on top of stale pixels, and leave every dirty flag standing.
            dirty.set()
        }
        if Pane.renderStatsEnabled { reportRenderStats() }
    }

    // MARK: - Events from the terminal

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .titleChanged(let t):
            lastOSCTitle = t
            onTitleChange?(t)
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
        // Any key at all takes the workbench pill away, including the ⌘E it is advertising: the
        // offer has been read, and chrome that outstays an answer is worse than chrome that was
        // never shown. Before the action dispatch below, so the pill is gone whichever way the key
        // is dealt with.
        dismissWorkbenchHint()
        // A tab whose session ended on the host, or whose attach never happened, will never show
        // another byte. The first key closes it -- what "press any key to continue" has always
        // meant -- and the key is swallowed rather than handed on to whatever tab comes next.
        // A chord bound to an action never reaches the shell. Most bindings are also menu key
        // equivalents, which AppKit consumes before `keyDown` is ever called; this path is what
        // makes a binding work when the config names a chord the menu cannot express.
        if let ke = keyEvent(from: event),
           let action = bindings.action(for: ke.key, modifiers: ke.modifiers),
           let target = actionTarget, target.canPerform(action) {
            target.perform(action)
            return
        }
        // A remote pane that is not the writer -- observing, still attaching, reconnecting, or
        // holding the transcript of a session that has ended -- has nowhere to send this. It beeps
        // rather than swallowing it: a key that does nothing and says nothing is how a tab that has
        // quietly stopped moving looks exactly like one that is working. Bound actions were already
        // handled above, so ⌘W, ⌘F, ⌘C and the scroll keys all still work on the kept transcript.
        if remote != nil, !acceptsInput {
            NSSound.beep()
            return
        }
        // The numeric keypad in application mode goes straight to the encoder. Everything else
        // reaches the input context first, and for a plain keypad key that ends in `insertText`,
        // which sends the digit -- so `ESC O q` was produced by `KeyEncoder` and never sent by the
        // application. Every keypad test passed because the tests called the encoder directly, and
        // so did the smoke check that was supposed to prove the wiring. No input method wants the
        // keypad, so nothing is taken away from one by deciding this here.
        if MacKeyCodes.isKeypad(event.keyCode), session.withTerminal({ $0.modes.keypadApp }) {
            sendKey(event)
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
        // `isKeypad` comes from the key code, not from `NSEvent.numericPad`: macOS sets that flag
        // on the arrow keys too, so trusting it would send SS3 for arrows in application-keypad
        // mode and break every full-screen program the moment one turned the mode on.
        return KeyEvent(key: key, modifiers: mods, text: e.characters,
                        isKeypad: MacKeyCodes.isKeypad(e.keyCode))
    }

    /// `KeyEncoderOptions.optionAsMeta` is a plain bool -- it doesn't distinguish which side of the
    /// keyboard was held -- so `.left` and `.right` both act like `.both` here rather than silently
    /// doing nothing; only `.none` turns it off.
    private var optionActsAsMeta: Bool { config.optionAsMeta != .none }

    private func sendKey(_ e: NSEvent) {
        guard let ke = keyEvent(from: e) else { return }
        stopWatchIfUserTyped()
        // Every mode the encoder needs, read under the one lock: `cursorKeysApp` and `keypadApp`
        // are what DECCKM/DECKPAM asked for, and `modifyOtherKeys` is what an application turned on
        // to be able to tell ctrl+Enter from Enter at all.
        let opts = session.withTerminal {
            KeyEncoderOptions(cursorKeysApp: $0.modes.cursorKeysApp, optionAsMeta: optionActsAsMeta,
                              keypadApp: $0.modes.keypadApp,
                              modifyOtherKeys: $0.modes.modifyOtherKeys)
        }
        if let bytes = KeyEncoder.encode(ke, options: opts) { send(bytes) }
    }

    /// Whether anything this pane sends can reach a shell at all.
    ///
    /// True for every local pane. On a remote one it is `AttachState.acceptsInput`: observing, or
    /// attaching, or reconnecting, and there is no path from a keystroke to the host. The gate is
    /// here as well as inside `Attachment.send` because the *side effects* are the visible part --
    /// without it, typing while observing still dropped the selection and threw the viewport back
    /// to the bottom, and ⌘⇧V still opened the paste editor for a paste that went nowhere.
    var acceptsInput: Bool { remote?.state.acceptsInput ?? true }

    /// Writes bytes to the shell as though the user had typed them. Not private because a quick
    /// action is exactly "type this for me".
    func send(_ bytes: [UInt8]) {
        guard acceptsInput else {
            // The strip is the explanation -- it is on screen saying "Observing", with the button
            // that fixes it. The beep is only the acknowledgement that the key was seen.
            NSSound.beep()
            return
        }
        // Typing both jumps the viewport back to the live screen and drops the selection: the text
        // it pointed at is about to move, and every terminal drops it here.
        //
        // Not for the watch's own runs. `send` is also how a series types its request, and doing
        // this there yanked the reader to the live screen every interval -- the loudest half of
        // "a watch throws you out of the run you are reading", and the half the forget rule does
        // not touch. `isSendingWatchRun` is the distinction the file already draws for the rule
        // that stops a series when the user types; the user's own keystrokes still come through
        // here with it false.
        if !isSendingWatchRun {
            clearSelection()
            scrollDisplayToBottom()
        }
        session.send(bytes)
        markDirty()
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        // Someone is typing at the prompt; a series that went on sending would splice a `curl`
        // into the middle of their sentence.
        stopWatchIfUserTyped()
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

    /// The cell under a point, or nil when there is no cell there.
    ///
    /// The character-level twin of `position(_:in:)`: a fold placeholder and a lens line are not
    /// rows of the buffer, so a question about the *character* under the pointer has no answer on
    /// one. Answering it with the block's own row instead -- which `position` does, correctly, for
    /// questions about the block -- read the command line's characters from a hundred lines away:
    /// a pointer at column 15 of any lens line landed inside the URL of `$ curl -s https://…`, drew
    /// a stray underline on the command row, and made ⌘-click on the body of a response open the
    /// request.
    private func characterPosition(_ p: (x: Double, y: Double), in t: Terminal) -> AbsolutePosition? {
        let cell = cellSizePoints
        let hit = PointerMap.position(x: p.x, y: p.y, cellWidth: Double(cell.width), cellHeight: Double(cell.height),
                                      padding: Double(padding), viewportTop: t.viewportTopRow,
                                      cols: t.cols, totalRows: t.totalRows)
        guard !foldRowsOnScreen.isEmpty else { return hit }
        guard let absolute = absoluteRow(forVisibleRow: hit.row - t.viewportTopRow, in: t) else {
            return nil
        }
        return AbsolutePosition(row: absolute, col: hit.col)
    }

    private func position(_ p: (x: Double, y: Double), in t: Terminal) -> AbsolutePosition {
        let cell = cellSizePoints
        let hit = PointerMap.position(x: p.x, y: p.y, cellWidth: Double(cell.width), cellHeight: Double(cell.height),
                                      padding: Double(padding), viewportTop: t.viewportTopRow,
                                      cols: t.cols, totalRows: t.totalRows)
        // `PointerMap` counts rows down from the viewport top, which stops being the same thing as
        // counting absolute rows the moment anything is folded *or lensed*: the rows under the
        // pointer are whatever the display left on screen. Gated on `folding` alone, a pane with
        // only a lens open answered with the rows the lens replaced, so a drag selected text nobody
        // could see, a link hit-test read the wrong row, and a right-click two thirds of the way
        // down a long lens offered the *next* command's actions -- Re-run included.
        guard let absolute = pointerRow(forVisibleRow: hit.row - t.viewportTopRow, in: t)
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
        // Any click that reaches the pane is a click *outside* the filter field -- AppKit routes the
        // ones inside it to the field itself -- and this handler takes first responder away from it
        // on the next line, which would otherwise leave a live-looking box that nothing types into.
        if lensField != nil { dismissLensField() }
        window?.makeFirstResponder(self)
        onFocusRequested?()
        // ⌘-click opens whatever is under the pointer, before the click can become a selection or
        // be handed to a program that has taken the mouse.
        if event.modifierFlags.contains(.command), openLink(at: event) { return }
        // A fold placeholder is a button, not text: clicking it puts the output back. Checked
        // before mouse reporting, because a fold only exists while the user is reading scrollback.
        if unfoldPlaceholder(at: convert(event.locationInWindow, from: nil)) { return }
        // A lens line's fold point is a button too, and it is checked before mouse reporting for
        // the same reason: a lens only exists on a finished block being read.
        if event.clickCount == 1, toggleLensFold(at: convert(event.locationInWindow, from: nil)) {
            return
        }
        if report(event, .left, .press) { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        // A drag that starts on a lens line selects the lens's own text. A drag that starts on the
        // transcript clears any lens selection: two visible selections is one too many, and only
        // one of them can be what ⌘C means.
        if let hit = lensLine(at: lastMousePoint!) {
            // The terminal's own highlight goes now, not when the lens drag ends: two selections
            // drawn at once, with ⌘C silently preferring the lens one, is the pane telling the user
            // two different things about what they are about to copy.
            _ = selectionController.clear()
            lensSelection = LensSelection(commandID: hit.id,
                                          anchor: .init(line: hit.line, character: hit.character),
                                          head: .init(line: hit.line, character: hit.character))
            markDirty()
            return
        }
        if lensSelection != nil {
            lensSelection = nil
            markDirty()
        }
        let point = topLeft(lastMousePoint!)
        let block = event.modifierFlags.contains(.option)
        let changed = session.withTerminal { t in
            selectionController.begin(at: position(point, in: t), clickCount: event.clickCount, block: block, in: t,
                                      separators: config.wordSeparators)
        }
        if changed { markDirty() }
    }

    override func mouseDragged(with event: NSEvent) {
        if lensSelection != nil {
            lastMousePoint = convert(event.locationInWindow, from: nil)
            if let hit = lensLine(at: lastMousePoint!), hit.id == lensSelection?.commandID {
                lensSelection?.head = .init(line: hit.line, character: hit.character)
                markDirty()
            }
            return
        }
        guard selectionController.isDragging else { report(event, .left, .drag); return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        let point = topLeft(lastMousePoint!)
        let changed = session.withTerminal { t in
            selectionController.drag(to: position(point, in: t), in: t, separators: config.wordSeparators)
        }
        if changed { markDirty() }
    }

    override func mouseUp(with event: NSEvent) {
        if let selection = lensSelection {
            lastMousePoint = nil
            if selection.isEmpty { lensSelection = nil; markDirty() }
            else if config.copyOnSelect { copy(nil) }
            return
        }
        guard selectionController.isDragging else { report(event, .left, .release); return }
        lastMousePoint = nil
        let wasEmpty = selection == nil || selection?.isEmpty == true
        if selectionController.end() { markDirty() }
        if config.copyOnSelect, selection != nil { copy(nil) }
        // A click that selected nothing is a click, not a drag. On the command line that means
        // "put the caret here" -- which is how anyone expects to fix one value in the middle of a
        // pasted `curl`, rather than holding an arrow key.
        if wasEmpty, event.clickCount == 1 {
            moveShellCaret(to: convert(event.locationInWindow, from: nil))
        }
    }

    /// The one place a fold is toggled from a control, so every route agrees on the shape.
    func toggleFold(ofCommand id: UInt32, full: Bool) {
        if full { folding.toggleFull(id) } else { folding.toggle(id, keep: config.foldKeepLines) }
        onFocusRequested?()
        // Folding reshuffles the display slots under the pointer without a matching mouse-move. The
        // next frame re-resolves the hover against the new slots, so nothing to do here but ask
        // for one.
        markDirty()
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
        // Through the display, like the wheel: a drag off the top of a lensed block would otherwise
        // scroll by rows the lens has replaced and extend the selection over rows nobody can see.
        guard scrollDisplay(by: -lines) else { return }
        let changed = session.withTerminal { t -> Bool in
            selectionController.drag(to: position(head, in: t), in: t, separators: config.wordSeparators)
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
            scrollDisplay(by: -lines)
            markDirty()
        }
    }

    /// Moves the viewport `lines` **display lines** towards newer content (negative: older), which
    /// is what a wheel click means. Returns whether anything moved.
    ///
    /// Not `scrollViewport(by:)`: a fold is one display line covering a thousand rows and a lens is
    /// as many lines as it has, so a scroll measured in rows either sticks or skips. `advance` walks
    /// the display sequence itself; the row it lands on goes to the terminal, and the line within
    /// that row's lens stays here, because a lens is the pane's own state and the terminal knows
    /// nothing about it.
    @discardableResult
    private func scrollDisplay(by lines: Int) -> Bool {
        session.withTerminal { t in
            let from = self.viewportCursor(in: t)
            let to = t.advance(from, by: lines, folding: self.folding, lenses: self.lenses,
                               buffers: { self.lensBuffers[$0] })
            guard to != from else { return false }
            _ = t.scrollToAbsoluteRow(to.row, margin: 0)
            self.viewportAnchor = to
            self.viewportAnchorTop = t.viewportTopRow
            // By what the position *is*, not by who moved to it. Wheeling down to the live edge
            // lands on the display bottom through `advance`'s own clamp, and an anchor tagged
            // "a place the reader chose" there froze the pane the moment the ring filled -- with
            // no lens and no fold anywhere. One walk per wheel click, which a wheel click can
            // afford; the frame path only reads the flag.
            self.viewportAnchorIsDisplayBottom = t.isDisplayBottom(to, folding: self.folding,
                                                                   lenses: self.lenses,
                                                                   viewportRows: t.rows,
                                                                   buffers: { self.lensBuffers[$0] })
            return true
        }
    }

    /// Puts the last display line on the last row of the window. What "the viewport goes back to the
    /// live screen" means now that the display is not the rows -- see `Terminal.displayBottomCursor`
    /// for why the prompt wins over the top of a long response.
    private func scrollDisplayToBottom() {
        session.withTerminal { t in
            t.scrollViewportToBottom()
            self.viewportAnchor = t.displayBottomCursor(folding: self.folding, lenses: self.lenses,
                                                        viewportRows: t.rows,
                                                        buffers: { self.lensBuffers[$0] })
            self.viewportAnchorTop = t.viewportTopRow
            // Not a place anybody chose. Flagged so the next frame recomputes the bottom instead of
            // trusting this value: the bottom moves whenever anything prints, and with the ring at
            // capacity nothing the staleness check compares moves with it. See
            // `Terminal.viewportCursor`.
            self.viewportAnchorIsDisplayBottom = true
        }
    }

    /// Where the top of the viewport is in the display sequence. The rule is
    /// `Terminal.viewportCursor(anchor:anchorTop:…)` in NyxCore, where it can be tested; this hands
    /// it the two numbers only the pane knows.
    private func viewportCursor(in t: Terminal, memo: CommandRegionMemo? = nil) -> DisplayCursor {
        t.viewportCursor(anchor: viewportAnchor, anchorTop: viewportAnchorTop,
                         anchorIsDisplayBottom: viewportAnchorIsDisplayBottom, folding: folding,
                         lenses: lenses, viewportRows: t.rows,
                         buffers: { self.lensBuffers[$0] }, memo: memo)
    }

    // MARK: - Menu actions

    override func selectAll(_ sender: Any?) {
        session.withTerminal { if selectionController.selectAll(in: $0) { markDirty() } }
    }

    /// The right-click menu, in two halves.
    ///
    /// The block group at the top comes from `BlockHeader.actions`, the same list the hover
    /// overlay's ⋯ menu builds from, so the mouse route and the menu route cannot offer different
    /// things or grey out differently. Everything below it is built from `TerminalAction` like the
    /// main menu, so an item here cannot do something different from the same item there.
    ///
    /// Auto-enabling stays on: `validateMenuItem` greys out Copy, Paste and Select All, and passes
    /// the block group's own `isEnabled` back through unchanged.
    private func contextMenu(at point: NSPoint? = nil) -> NSMenu {
        let menu = NSMenu()
        // The command under the pointer, when there is one. This is the entry that turns the
        // scrollback into something you can act on rather than only read: the prompt marks say
        // where each command began, so the whole block's actions -- not just rerun and edit -- are
        // answerable from a right-click.
        if let point, let id = commandID(under: point) {
            // Asked before the lock: finding the previous run of this request parses command lines
            // out of the cache, and this is a menu press rather than a frame.
            let previousRun = self.previousRun(of: id)
            let header: BlockHeader? = session.withTerminal { t in
                guard let row = t.promptRow(ofCommand: id),
                      let region = t.command(containingAbsoluteRow: row) else { return nil }
                let block = CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true)
                // Read here as well as in `render`, because a right-click reaches blocks the frame
                // never built a header for: one whose prompt row is scrolled off the top still has
                // every output row under the pointer, and its Request group has to be there.
                let httpSummary = self.requestSummary(for: block, in: t)
                return block.header(now: t.now(), folding: self.folding,
                                    notifyArmed: self.armedNotifications.contains(id),
                                    anyFolds: !self.folding.isEmpty,
                                    hasOutput: t.commandHasOutput(atAbsoluteRow: region.promptRow),
                                    httpSummary: httpSummary,
                                    isHTTP: self.requestCache.isRequest(id: id),
                                    lens: self.lenses.lens(of: id),
                                    lensTooLarge: self.lensIsTooLarge(id),
                                    bodyIsJSON: self.bodyIsJSON(id),
                                    hasPreviousRun: previousRun != nil,
                                    // Right-clicking a watched run has to offer Stop, not a second
                                    // "Run Every 5 s": this menu is built apart from the frame's,
                                    // and a header without the series is a menu that disagrees
                                    // with the strip over the same block.
                                    watch: self.watchHeader(forBlock: id),
                                    watchInterval: self.config.httpWatchInterval)
            }
            drainPendingRecord()
            if let header {
                for (index, entry) in header.actions.enumerated() {
                    if index > 0 && entry.action.startsGroup { menu.addItem(.separator()) }
                    let item = NSMenuItem(title: header.title(for: entry.action),
                                          action: #selector(blockActionFromMenu(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = BlockMenuEntry(action: entry.action, id: id)
                    item.isEnabled = entry.enabled
                    // The lens rows are a radio group and the notification row is a switch; both
                    // are one question to the header, so a third state cannot be invented here.
                    item.state = header.isChecked(entry.action) ? .on : .off
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
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
        // The block group sets its own `isEnabled` per action (`.copyOutput` needs output,
        // `.editAndRun` needs the command to have finished). This menu leaves auto-enabling on, so
        // AppKit asks here as well; handing back what the item already decided is what keeps the
        // two from contradicting each other. Turning auto-enabling off for the whole menu instead
        // silenced Copy, Paste, Select All and Toggle Zoom, which have no such case here.
        if item.action == #selector(blockActionFromMenu(_:)) { return item.isEnabled }
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
    /// The same thing in view coordinates, for the pointing-hand cursor rect. A list rather than
    /// one rect: a link and a block's summary can both want the pointing hand at once.
    private var hoveredRect: [NSRect] = []

    /// Where the pointer last was, in view coordinates, or nil when it is outside the pane.
    ///
    /// Kept rather than acted on: which block it is over is answered in `render()`, against the
    /// blocks and display rows of the frame being drawn. See `resolveBlockHover`.
    private var lastPointerPoint: NSPoint?

    /// Which block the pointer sits on -- for the tint and the overlay -- against one frame's
    /// blocks. `resolve` answers in viewport-relative absolute space; `placed` re-expresses that in
    /// the display slots actually on screen, which differ from absolute space only when a fold is
    /// showing. Called under the session lock from `render()`.
    private func resolveBlockHover(in t: Terminal, blocks: [CommandBlock], allowed: Bool,
                                   viewportTop: Int) -> BlockHover? {
        guard allowed, let point = lastPointerPoint, bounds.contains(point) else { return nil }
        let visible = visibleRow(at: point)
        let pointerRow: Int?
        let standIn: UInt32? = visible.flatMap { slot in
            guard foldRowsOnScreen.indices.contains(slot) else { return nil }
            switch foldRowsOnScreen[slot] {
            // Neither a fold placeholder nor a lens line has an absolute row of its own: each stands
            // for the block whose output it replaced, so hover that block directly. Without the lens
            // half of this, reading a pretty-printed response with its command row scrolled off the
            // top produced no tint and no hover strip -- no `{ }`, no Copy, no Lens menu -- which is
            // every control the response has.
            case .fold(let commandID, _, _): return commandID
            case .lens(let commandID, _): return commandID
            case .row: return nil
            }
        }
        if let standIn {
            pointerRow = blocks.first { $0.region.id == standIn }?.visibleRows.lowerBound
        } else {
            let absolute = visible.flatMap { self.absoluteRow(forVisibleRow: $0, in: t) }
            pointerRow = absolute.map { $0 - viewportTop }
        }
        let resolved = BlockHover.resolve(pointerRow: pointerRow, blocks: blocks, allowed: allowed)
        guard !foldRowsOnScreen.isEmpty else { return resolved }
        return resolved?.placed(onDisplayRows: foldRowsOnScreen, viewportTop: viewportTop)
    }

    private func updateHover(at point: NSPoint) {
        guard bounds.contains(point) else {
            clearHover()
            return
        }
        // The block hover is not computed here: the pointer's position is all this knows, and which
        // block is under it depends on the frame. Recorded on every move, including a move inside
        // one cell -- the cheap comparison below is about the link hit test, and the block hover
        // costs nothing until the next frame asks for it.
        lastPointerPoint = point
        // A mouse-move that stays inside one cell cannot change what is under the pointer, and
        // hit-testing is not cheap: it tokenizes the row through five regular expressions and may
        // `stat` a path. Mouse-move events arrive far faster than cells change.
        // The *character* under the pointer, so a slot with no character in it -- a lens line, a
        // fold placeholder -- is its own key rather than the block's prompt row shared by all of
        // them, which deduped every lens line in a column down to one hit test.
        let cell: (row: Int, col: Int) = session.withTerminal { t in
            guard let p = self.characterPosition(topLeft(point), in: t) else {
                return (Int.min, self.visibleRow(at: point) ?? -1)
            }
            return (p.row, p.col)
        }
        guard lastHoverCell == nil || lastHoverCell! != cell else { return }
        lastHoverCell = cell
        // The pointer moved to another cell, so the block under it may have changed even if nothing
        // else did; the next frame is where that is decided.
        markDirty()

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
        // The pointer has left the pane; with no point to resolve against, the next frame finds no
        // block and takes the overlay and the tint down with it.
        lastPointerPoint = nil
        let hadBlock = hoveredBlock != nil
        let hadLink = hoveredLink != nil
        hoveredLink = nil
        guard hadBlock || hadLink else { return }
        updateHoverCursor()
        markDirty()
    }

    /// The box of one in-grid fold triangle: 20 pt by `hitRowHeight`, centred on its row and on the
    /// column the marker is actually drawn in. One rule, because the pointing hand and the click
    /// have to agree about where the control is -- they disagreed about the old summary chevron for
    /// two releases (§2.4).
    private func foldTriangleRect(onVisibleRow visible: Int, markerColumn column: Int) -> NSRect {
        let cell = cellSizePoints
        let box = CommandBlockChrome.foldTriangleHit(cellHeight: Double(cell.height))
        let centre = bounds.height - padding - (CGFloat(visible) + 0.5) * cell.height
        return NSRect(x: padding + CGFloat(column) * cell.width,
                      y: centre - CGFloat(box.height) / 2,
                      width: CGFloat(box.width), height: CGFloat(box.height))
    }

    /// The fold placeholder's box: the whole row, at the same height floor. It is a control end to
    /// end -- there is no content on it to select past.
    private func foldPlaceholderRect(onVisibleRow visible: Int) -> NSRect {
        let cell = cellSizePoints
        let box = CommandBlockChrome.foldTriangleHit(cellHeight: Double(cell.height))
        let centre = bounds.height - padding - (CGFloat(visible) + 0.5) * cell.height
        return NSRect(x: padding, y: centre - CGFloat(box.height) / 2,
                      width: max(0, bounds.width - padding * 2), height: CGFloat(box.height))
    }

    /// The pointing hand is a cursor rect rather than a `NSCursor.set()`, so AppKit restores the
    /// arrow on its own when the pointer leaves the link -- and when it leaves the window entirely.
    ///
    /// Everything it is placed on is a control: a link, a lens line's fold triangle, a fold
    /// placeholder. The in-grid summary is not one of them any more, which is what makes the hand
    /// truthful -- it used to be offered on a chevron that was the only clickable thing on a row of
    /// unclickable text beside it (§2.4).
    private func updateHoverCursor() {
        let cell = cellSizePoints
        var rects: [NSRect] = []
        if let link = hoveredLink {
            // Through the display, not `row - viewportTop`: with a fold or a lens on screen those
            // are different numbers, and the hand would have been placed on whichever slot the
            // replacement pulled into that index.
            let top = session.withTerminal { max(0, $0.viewportTopRow) }
            if let row = displaySlot(ofAbsoluteRow: link.row, viewportTop: top) {
                let width = CGFloat(link.columns.count) * cell.width
                rects.append(NSRect(x: padding + CGFloat(link.columns.lowerBound) * cell.width,
                                    y: bounds.height - padding - CGFloat(row + 1) * cell.height,
                                    width: width, height: cell.height))
            }
        }
        // A lens container line's marker is the control; the rest of the line is text, and a reader
        // dragging across it is selecting. The box is the gutter's own 20 pt by `hitRowHeight`
        // (§2.4) -- one cell is about 8 pt and one row 13 pt at `line-height 0.8`, neither a target.
        if !lenses.isEmpty {
            for visible in lensMarkerRowsOnScreen {
                guard case .lens(let id, let line) = foldRowsOnScreen[visible],
                      let column = lensBuffers[id]?.foldMarkerColumn(line: line) else { continue }
                rects.append(foldTriangleRect(onVisibleRow: visible, markerColumn: column))
            }
        }
        // The placeholder row is a control end to end: it has no content worth selecting, and it is
        // the one affordance the PM's read found already legible. It had no pointing hand (a11y
        // 6.13), which is the one thing that said so.
        if !folding.isEmpty {
            for visible in foldPlaceholderRowsOnScreen {
                rects.append(foldPlaceholderRect(onVisibleRow: visible))
            }
        }
        hoveredRect = rects
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in hoveredRect { addCursorRect(rect, cursor: .pointingHand) }
    }

    /// Places the overlay over the hovered block's command row, or hides it. `palette` is the one
    /// `render()` already read under the lock this frame; every other caller (a hover change, a
    /// fold toggle) has no such value in hand and passes nil, which reads it here instead.
    private func blockHeaderChanged(palette suppliedPalette: Palette? = nil) {
        let palette = suppliedPalette ?? session.withTerminal { $0.palette }
        let font = NSFont.monospacedSystemFont(ofSize: effectiveFontSize, weight: .regular)
        guard let row = hoveredBlock?.headerRow, let header = headersOnScreen[row],
              let plan = hoverStripPlan else {
            blockHeader.update(header: nil, plan: nil, palette: palette, font: font, groundHeight: 0)
            return
        }
        let cell = cellSizePoints
        // The frame is as tall as the pills and never below the hit floor, centred on the row:
        // `hitTest` rejects a point outside the view's frame, so a frame one row tall around 20 pt
        // pills left a dead sliver along the top and bottom of every one of them. What the strip
        // *paints* is one row, so an opaque band cannot cover the rows above and below. Both
        // numbers come from `CommandBlockChrome` rather than from `fittingSize`, which had no floor
        // at all at `line-height = 0.8`.
        let height = CGFloat(CommandBlockChrome.stripFrameHeight(cellHeight: Double(cell.height)))
        let top = bounds.height - padding - CGFloat(row + 1) * cell.height
        blockHeader.update(header: header, plan: plan, palette: palette, font: font,
                           groundHeight: CGFloat(CommandBlockChrome.stripGroundHeight(cellHeight: Double(cell.height))))
        // The strip occupies exactly the columns Core chose. Usually that is "after the command's
        // last glyph, out to the pane's right edge", so what is right-aligned inside it lands on the
        // last column; a pills-only strip ends at the in-grid summary's first column instead, which
        // is `trailingColumn`, because that rung exists to keep the sentence it would otherwise be
        // drawn on top of.
        let trailing = plan.trailingColumn < 0 ? cols : plan.trailingColumn
        blockHeader.frame = NSRect(x: padding + CGFloat(plan.firstColumn) * cell.width,
                                   y: top - (height - cell.height) / 2,
                                   width: CGFloat(trailing - plan.firstColumn) * cell.width,
                                   height: height)
        window?.invalidateCursorRects(for: self)
    }

    /// The token under a view point, if any. One row is read, and the lock is released before the
    /// answer is looked at.
    private func token(under point: NSPoint) -> (row: Int, token: TextToken)? {
        session.withTerminal { t in
            guard let position = self.characterPosition(topLeft(point), in: t) else { return nil }
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
        // Closing the bar ends the cross-tab search too, and clears whatever it left on the *other*
        // panes it visited. Without this the hit list outlived the bar, and the next ⌘G sent the
        // user to a tab nobody was searching; without the exclusion, the cleanup ran over this
        // pane as well and threw away the selection `clearSearchState` had just put back.
        globalSearchOwner?.endGlobalSearch(excluding: self)
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

    /// A fixed 20 pt column, whatever the padding is, and never hidden. It is the *target*, not the
    /// picture: the mark inside it is 3 pt wide at `spineLeadingInset`, and `hitTest` gives every
    /// point that is not on a mark back to the pane -- so the first text column under it keeps its
    /// clicks even at `padding = 0`, where the gutter used to disappear entirely.
    private func layoutGutter() {
        gutter.frame = NSRect(x: 0, y: 0, width: CGFloat(PromptGutter.hitWidth), height: bounds.height)
        gutter.needsDisplay = true
    }

    /// Exactly one terminal row tall and exactly over the first one, inside the padding and clear
    /// of the gutter -- so the strip covers a row of text and never the marks beside it.
    // MARK: - Publishing this pane to paired Macs

    /// This pane's entry in every paired Mac's palette, for as long as it lives. nil on a remote
    /// pane (spec §11: only local PTY sessions are published, so attachments cannot chain) and when
    /// there is no coordinator at all.
    private var publication: RemotePublication?
    /// The last repo lookup and the directory it was made for. `SessionSummary.repo` walks up to the
    /// filesystem root reading `.git/HEAD`, and this runs twice a second on a busy pane -- but the
    /// answer only changes when the directory does.
    private var cachedRepo: (cwd: String, repo: (name: String, branch: String)?)?
    /// What the program last set with OSC 0/2, for the summary. The tab keeps its own copy for the
    /// bar; this pane needs one because the summary is built here.
    private var lastOSCTitle = ""
    /// When this pane last printed anything -- what a palette row on another Mac turns into
    /// "2 min ago". Wall-clock rather than anything from the prompt marks, because a shell with no
    /// integration has no marks and still has activity worth reporting.
    private var lastActivityAt: Date?

    /// Publishes this pane, if it is a local one and the application has remote sessions at all.
    private func startPublishing(_ local: TerminalSession) {
        guard let coordinator = (NSApp.delegate as? AppDelegate)?.remote else { return }
        publication = coordinator.publish(local)
        updatePublishedSummary()
    }

    /// Rebuilds what paired Macs see of this pane: its title, where it is, what it is running, what
    /// it last ran, and the grid an attach would take. Called from the same coalesced half-second
    /// check that notices a `cd` and a finished command, so a pane printing at full speed costs one
    /// of these twice a second rather than one per chunk.
    ///
    /// Everything here is read on the main thread and handed over as a value. The host's queue
    /// reads only that value.
    private func updatePublishedSummary() {
        guard let publication else { return }
        let cwd = workingDirectory
        let (lastCommand, cols, rows) = session.withTerminal { t -> (String?, Int, Int) in
            (SessionSummary.lastCommand(in: t), t.cols, t.rows)
        }
        let title = lastOSCTitle.isEmpty ? fallbackTitle : lastOSCTitle
        publication.update(SessionSummary.make(sessionID: RemoteID.base64url(publication.sessionID),
                                               title: title, cwd: cwd,
                                               processName: foregroundProcessName,
                                               lastCommand: lastCommand, lastActivity: lastActivityAt,
                                               cols: cols, rows: rows, repo: repo(at: cwd)))
    }

    /// The repository a directory is in, cached by directory: the walk reads a file per level, and
    /// nothing about it can change while the pane stays where it is.
    private func repo(at cwd: String?) -> (name: String, branch: String)? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if let cachedRepo, cachedRepo.cwd == cwd { return cachedRepo.repo }
        let found = SessionSummary.repo(atPath: cwd) { try? String(contentsOfFile: $0, encoding: .utf8) }
        cachedRepo = (cwd, found)
        return found
    }

    /// Which display slot the pinned band sits on: the top row, or the one below it while the
    /// remote strip has the top -- two strips over one row would leave whichever was added last
    /// covering the other, and both are sentences somebody has to read.
    ///
    /// One property rather than the same expression in two places: `render` blanks this row and
    /// `layoutStickyStrip` puts the band on it, and a band over one row with another one blanked is
    /// two rows of nonsense.
    private var stickyStripRow: Int { remote != nil && !remoteStrip.isHidden ? 1 : 0 }

    private func layoutStickyStrip() {
        let cell = cellSizePoints
        let left = max(padding, CGFloat(PromptGutter.hitWidth))
        let width = max(0, bounds.width - left - padding)
        let top = bounds.height - padding - cell.height
        remoteStrip.frame = NSRect(x: left, y: top, width: width, height: cell.height)
        // `hitRowHeight`, centred on the row it covers, so the band is never 13 pt tall at
        // `line-height = 0.8` -- the same floor every other one-row target in a pane obeys (§8.4).
        // It overhangs the rows above and below by up to 1.5 pt, which is a band the mouse can hit
        // rather than a row of output taken away: the covered row is the only one blanked.
        let height = CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cell.height)))
        let centre = top + cell.height / 2 - CGFloat(stickyStripRow) * cell.height
        stickyStrip.frame = NSRect(x: left, y: centre - height / 2, width: width, height: height)
    }

    // MARK: - The remote strip

    /// Draws one `AttachState` and tells the tab about it. The only place a remote pane's chrome
    /// changes; everything it decides -- the words, whether there is a button, whether input is
    /// accepted at all -- is `AttachState` in NyxCore.
    private func showRemote(_ state: AttachState) {
        var shown = state
        // Added here rather than by the client: how much of the host's screen fits, and how many
        // panes share this tab, are facts about this window -- which `RemoteClient` neither knows
        // nor should.
        shown.geometryNote = remoteGeometryNote()
        shown.closesWholeTab = isSolePaneInTab?() ?? true
        shown.today = AttachState.startOfDay(Date(), in: shown.timeZone)
        let wasHidden = remoteStrip.isHidden
        // Unconditionally, and *before* the guard below. Which of the strip's two labels fits
        // depends on the pane's width and its font, and neither of those is in `AttachState`: a
        // window dragged narrower and a ⌘+ both leave the state byte-identical, so a guard in front
        // of this left the label truncating mid-word at the old width, in the old font.
        // `RemoteStripView.update` has its own guard keyed on exactly those two.
        remoteStrip.update(state: shown, palette: Pane.resolvedPalette(for: config),
                           font: .monospacedSystemFont(ofSize: effectiveFontSize, weight: .regular))
        if wasHidden != remoteStrip.isHidden { layoutStickyStrip() }
        // The *report* is what must not repeat: `updateGrid` calls this on every layout pass, and a
        // tab bar that rebuilt its badge and title on each one would be doing that for nothing.
        guard shown != shownRemoteState else { return }
        shownRemoteState = shown
        onRemoteStateChange?(shown)
        markDirty()
    }

    /// The last state actually drawn, so an unchanged one is not redrawn or re-reported.
    private var shownRemoteState: AttachState?

    /// The geometry note for this pane, or nil on a local pane and before `attached` has said how
    /// big the host is.
    private func remoteGeometryNote() -> String? {
        guard let remote else { return nil }
        let host = GridSize(cols: remote.attachment.cols, rows: remote.attachment.rows)
        guard host.cols > 0, host.rows > 0 else { return nil }
        return AttachState.geometryNote(host: host, pane: GridSize(cols: cols, rows: rows))
    }

    /// The strip's one button. Which of the two it is, is `AttachState.stripAction` -- the view
    /// dispatches on the decision, never on the words it happens to have drawn.
    private func remoteStripButtonPressed() {
        switch remote?.state.stripAction {
        case .takeControl: takeControl()
        case .close:
            // This pane, not whichever one happens to have focus. The button is on a strip inside
            // one pane, and `closePane` acts on the focused one -- so clicking Close on a dead
            // remote pane beside a live local one used to close the *local* one.
            onFocusRequested?()
            actionTarget?.perform(.closePane)
        case nil: break
        }
    }

    /// The strip's button and the `remote_take_control` action. Returns whether there was anything
    /// to take: a local pane, or one that is already writing, answers no and the caller beeps.
    @discardableResult
    func takeControl() -> Bool {
        guard let remote, remote.state.stripAction == .takeControl else { return false }
        remote.attachment.takeControl()
        return true
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
    ///
    /// `PromptGutter.row` rather than the same division written out here: this is the *text* rule --
    /// one row is one cell tall and the rows do not overlap -- and `hitRow` is the *target* rule,
    /// with a floor under it. Keeping both in Core is what makes the difference between them
    /// something a test can state (`aFoldTargetIsHitThroughoutItsSixteenPointBand`) rather than a
    /// discrepancy between a view handler and a Core function.
    private func visibleRow(at point: NSPoint) -> Int? {
        PromptGutter.row(atY: Double(bounds.height - point.y),
                         cellHeight: Double(cellSizePoints.height),
                         padding: Double(padding), rows: rows)
    }

    /// Which lens line a view point is on, and where along it, or nil when the point is on
    /// ordinary terminal text. The column is a Character offset, which is what a selection and a
    /// fold both work in.
    private func lensLine(at point: NSPoint) -> (id: UInt32, line: Int, character: Int)? {
        guard !lenses.isEmpty, let visible = visibleRow(at: point),
              visible < foldRowsOnScreen.count,
              case .lens(let id, let line) = foldRowsOnScreen[visible],
              let buffer = lensBuffers[id] else { return nil }
        let cell = cellSizePoints
        guard cell.width > 0 else { return nil }
        let column = Int(((Double(point.x) - Double(padding)) / Double(cell.width)).rounded(.down))
        return (id, line, buffer.characterOffset(atColumn: max(0, column), line: line))
    }

    /// A click on the fold marker of a foldable node in a lens folds or unfolds it.
    ///
    /// The *marker* and not the whole line, which is what it used to be: the rest of a lens line is
    /// text a reader drags across to select, and a control that swallows the whole row is a control
    /// that cannot be selected past (§2.4). The box is that marker's cell widened to the same 20 pt
    /// the gutter cap gets. `foldMarkerColumn` is what says which cell -- a pretty-printed body
    /// writes its indent and its key before the triangle, so it is not column 0.
    private func toggleLensFold(at point: NSPoint) -> Bool {
        guard !lenses.isEmpty,
              let visible = foldHitRow(at: point, among: lensMarkerRowsOnScreen),
              case .lens(let id, let line) = foldRowsOnScreen[visible],
              let buffer = lensBuffers[id], let node = buffer.line(line)?.node,
              let column = buffer.foldMarkerColumn(line: line) else { return false }
        // The very rect `updateHoverCursor` drew the hand on, tested whole: what looks pressable is.
        guard foldTriangleRect(onVisibleRow: visible, markerColumn: column).contains(point) else {
            return false
        }
        lenses.toggleFold(node, in: id)
        rebuildLens(for: id)
        return true
    }

    /// The visible rows carrying a lens fold marker. A candidate list rather than a lookup by row,
    /// because a 16 pt target on a 13 pt row overhangs its neighbours and two of them can claim the
    /// same point (§8.4); `hitRow` settles it by the nearer centre.
    private var lensMarkerRowsOnScreen: [Int] {
        foldRowsOnScreen.enumerated().compactMap { visible, entry in
            guard case .lens(let id, let line) = entry,
                  lensBuffers[id]?.foldMarkerColumn(line: line) != nil else { return nil }
            return visible
        }
    }

    /// The visible rows carrying a fold placeholder.
    private var foldPlaceholderRowsOnScreen: [Int] {
        foldRowsOnScreen.enumerated().compactMap { visible, entry in
            guard case .fold(let id, _, _) = entry, id != 0 else { return nil }
            return visible
        }
    }

    /// Which of `rows` a point lands on, through the same `hitRowHeight` band the hand is drawn at.
    /// Not `visibleRow(at:)`: that divides by the cell height, which is right for text and wrong for
    /// a target with a floor under it -- the two disagreed by 1.5 pt at each end of every row.
    private func foldHitRow(at point: NSPoint, among rows: [Int]) -> Int? {
        let cell = Double(cellSizePoints.height)
        guard cell > 0, !rows.isEmpty else { return nil }
        return CommandBlockChrome.hitRow(atY: Double(bounds.height - point.y), cellHeight: cell,
                                         padding: Double(padding),
                                         hitHeight: CommandBlockChrome.hitRowHeight(cellHeight: cell),
                                         rows: rows)
    }

    /// A click on a fold placeholder puts the output back. Returns false when the click was on
    /// ordinary text, so it can go on to mean what it usually means.
    private func unfoldPlaceholder(at point: NSPoint) -> Bool {
        guard !folding.isEmpty,
              let visible = foldHitRow(at: point, among: foldPlaceholderRowsOnScreen),
              case .fold(let id, _, _) = foldRowsOnScreen[visible],
              foldPlaceholderRect(onVisibleRow: visible).contains(point) else { return false }
        folding.unfold(id)
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
        let commandID: UInt32? = session.withTerminal { t in
            guard let entry = self.absoluteRow(forVisibleRow: row, in: t),
                  let region = t.command(containingAbsoluteRow: entry),
                  t.commandHasOutput(atAbsoluteRow: region.promptRow) else { return nil }
            return region.id
        }
        // No beep: `PromptGutterView` does not claim a click on a mark whose command printed
        // nothing, so this is reached only if the buffer changed between the frame that drew the
        // mark and the click -- a race, not a mistake the user made, and a beep would be blaming
        // them for it.
        guard let id = commandID, id != 0 else { return }
        toggleFold(ofCommand: id, full: false)
    }

    /// The absolute row a *pointer* on this slot should be taken to mean.
    ///
    /// The same as `absoluteRow(forVisibleRow:)` for a slot that is a row, and the block's own
    /// prompt row for one that is not: a fold placeholder and a lens line stand for a block, and the
    /// questions asked through this one -- which command was right-clicked, which block a drag
    /// started in -- want the block they stand for rather than the row that would have been there
    /// without them.
    ///
    /// **Not for anything that reads characters.** A hit test wants the text under the pointer, and
    /// on a replaced slot there is none; `characterPosition(_:in:)` is that question and answers nil.
    private func pointerRow(forVisibleRow row: Int, in t: Terminal) -> Int? {
        guard !foldRowsOnScreen.isEmpty else { return t.viewportTopRow + row }
        guard foldRowsOnScreen.indices.contains(row) else { return nil }
        switch foldRowsOnScreen[row] {
        case .row(let absolute): return absolute
        case .fold(let id, _, _): return displayBlockRows[id]
        case .lens(let id, _): return displayBlockRows[id]
        }
    }

    /// Which absolute row a visible row is showing, through whatever the display put on screen. nil
    /// for a slot showing a fold placeholder or a lens line -- neither is a row of the buffer.
    private func absoluteRow(forVisibleRow row: Int, in t: Terminal) -> Int? {
        // Keyed off the display the last frame actually built, not off `folding`: a pane with a lens
        // open and nothing folded also draws through the display map, and subtracting the viewport
        // top there answers with a row the lens replaced.
        guard !foldRowsOnScreen.isEmpty else { return t.viewportTopRow + row }
        guard foldRowsOnScreen.indices.contains(row) else { return nil }
        guard case .row(let absolute) = foldRowsOnScreen[row] else { return nil }
        return absolute
    }

    /// `fold_command`: collapses the last command's output -- or, scrolled back, the one at the top
    /// of the screen -- and expands it again. `Terminal.commandToFold` is the rule.
    @discardableResult
    func toggleFoldOfCurrentCommand() -> Bool {
        let commandID: UInt32? = session.withTerminal { t in
            // The same rule the chevron and the gutter mark use, so ⌘⇧↑ cannot fold a screenful
            // of blank rows a command has not filled in yet.
            guard let region = t.commandToFold(),
                  t.commandHasOutput(atAbsoluteRow: region.promptRow) else { return nil }
            return region.id
        }
        guard let id = commandID, id != 0 else { return false }
        toggleFold(ofCommand: id, full: NSEvent.modifierFlags.contains(.option))
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
            folding.foldLongOutput(in: t, longerThan: Pane.longOutputThreshold, keep: config.foldKeepLines)
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
            // Here rather than on its own timer: what a paired Mac sees of this pane -- its title,
            // its directory, what it is running, what it last ran -- can only have moved when one
            // of the two checks above could have, and this is already the coalesced half second
            // after output arrived.
            self.updatePublishedSummary()
        }
    }

    private func checkForFinishedCommand() {
        let now = Date.timeIntervalSinceReferenceDate
        let bottom: (row: Int?, started: Bool, runningID: UInt32, previous: CommandRegion?) = session.withTerminal { t in
            guard t.totalRows > 0, let region = t.command(containingAbsoluteRow: t.totalRows - 1)
            else { return (nil, false, 0, nil) }
            return (region.promptRow, region.outputStart != nil, t.runningCommand?.id ?? 0,
                    region.outputStart != nil ? t.previousCommand(of: region) : nil)
        }
        // The moment a new command starts running is when the one before it is "done with", and
        // the only moment automatic folding is allowed to touch it.
        if bottom.started, !commandWasRunning, config.foldLongOutput > 0, let previous = bottom.previous {
            // The same predicate the chevron and the gutter use, so automatic folding cannot fold
            // something the user is not allowed to fold by hand.
            let hasOutput = session.withTerminal { $0.commandHasOutput(atAbsoluteRow: previous.promptRow) }
            if folding.autoFold(previous, longerThan: config.foldLongOutput,
                                keep: config.foldKeepLines, hasOutput: hasOutput) {
                markDirty()
            }
        }
        commandWasRunning = bottom.started
        // Before the notification rule, and unconditionally: this is the one path that runs for a
        // pane with no frames -- a background tab, an occluded or minimised window -- and it is
        // what keeps a watch advancing there. See `pollWatch`.
        pollWatch()
        guard let finished = commandWatcher.observe(bottomPromptRow: bottom.row, outputStarted: bottom.started,
                                                    runningID: bottom.runningID, now: now) else { return }
        let armed = armedNotifications
        armedNotifications.remove(finished.id)
        guard CommandNotificationRule.shouldNotify(finished, armed: armed,
                                                   windowFocused: window?.isKeyWindow == true,
                                                   minimumDuration: commandWatcher.minimumDuration) else { return }
        let described: (text: String, status: Int32?) = session.withTerminal { t in
            guard let region = t.command(containingAbsoluteRow: finished.promptRow) else { return ("", nil) }
            return (t.commandText(of: region), region.exitStatus)
        }
        CommandNotifier.shared.post(title: CommandNotification.title(failed: (described.status ?? 0) != 0),
                                    body: CommandNotification.body(command: described.text,
                                                                   exitStatus: described.status))
    }

    /// Selects the output of the last command -- or, scrolled back, the one at the top of the
    /// screen. The same rule ⌘⇧↑ folds by, so the two gestures cannot name different commands.
    @discardableResult
    func selectCommandOutput() -> Bool {
        let selection: Selection? = session.withTerminal { t in
            guard let region = t.commandToFold() else { return nil }
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

    /// `copy_block_markdown`: the last finished command and its output, fenced, for a chat or a ticket.
    @discardableResult
    func copyLastCommandAsMarkdown() -> Bool {
        let markdown: String? = session.withTerminal { t in
            guard let region = t.lastFinishedCommand else { return nil }
            return BlockExport.markdown(command: t.commandLine(of: region), output: t.outputText(of: region))
        }
        guard let markdown else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        return true
    }

    /// `save_command_output`: the last finished command's output to a file the user names.
    @discardableResult
    func saveLastCommandOutput() -> Bool {
        let id: UInt32? = session.withTerminal { $0.lastFinishedCommand?.id }
        guard let id else { return false }
        saveOutput(ofCommand: id)
        return true
    }

    /// The output of one block, through a save panel. Shared by the action and the ⋯ menu.
    func saveOutput(ofCommand id: UInt32) {
        guard let window else { return }
        let text: String = session.withTerminal { t in
            guard let row = t.promptRow(ofCommand: id), let region = t.command(containingAbsoluteRow: row)
            else { return "" }
            return t.outputText(of: region)
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "output.txt"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = []
        panel.message = "Save this command\u{2019}s output."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // The user asked for a file and there is none. A `try?` here meant a full disk or a
                // read-only folder looked exactly like a successful save.
                self?.onSaveFailed?(error)
            }
        }
    }

    /// Told when writing a block's output failed, so the window that owns this pane can say so.
    /// Set by `TabController`, which already has the alert for a failed scrollback save.
    var onSaveFailed: ((Error) -> Void)?

    /// Commands whose end the user asked to be told about, by id. See `CommandNotificationRule`.
    private var armedNotifications: Set<UInt32> = []

    var hasRunningCommand: Bool { session.withTerminal { $0.runningCommand != nil } }

    /// `notify_when_done`: arm a notification for the command running now. Returns false at a prompt.
    @discardableResult
    func armNotificationForRunningCommand() -> Bool {
        guard let id: UInt32 = session.withTerminal({ $0.runningCommand?.id }) else { return false }
        setNotification(armed: !armedNotifications.contains(id), forCommand: id)
        return true
    }

    func setNotification(armed: Bool, forCommand id: UInt32) {
        if armed { armedNotifications.insert(id) } else { armedNotifications.remove(id) }
        markDirty()
    }

    /// Every block action, from the ⋯ menu and the context menu, by command id.
    func perform(_ action: BlockAction, on id: UInt32) {
        let region: CommandRegion? = session.withTerminal { t in
            t.promptRow(ofCommand: id).flatMap { t.command(containingAbsoluteRow: $0) }
        }
        guard let region else { NSSound.beep(); return }
        switch action {
        case .copyCommand:
            // `commandLine`, not `commandText`: what belongs on the pasteboard is the command, not
            // the machine's `PS1` in front of it.
            let text = session.withTerminal { $0.commandLine(of: region) }
            copyToPasteboard(text)
        case .copyOutput:
            // What is on the screen, when that is a lens: someone copying a response they are
            // reading pretty-printed means the pretty-printed one, not the single line it arrived
            // as. Without a lens this is the transcript, exactly as it always was.
            if let buffer = lensBuffers[id] {
                copyToPasteboard(buffer.text(lines: 0 ..< buffer.lineCount))
            } else {
                copyToPasteboard(session.withTerminal { $0.outputText(of: region) })
            }
        case .copyMarkdown:
            let md = session.withTerminal { BlockExport.markdown(command: $0.commandLine(of: region),
                                                                 output: $0.outputText(of: region)) }
            copyToPasteboard(md)
        case .saveOutput: saveOutput(ofCommand: id)
        case .runAgain:
            // This one is typed at the shell. With the prompt still attached it ran
            // `nik@host ~ % make test`, which is not a command.
            let command = session.withTerminal { $0.commandLine(of: region) }
            guard !command.isEmpty else { NSSound.beep(); return }
            // As a bracketed paste and then a return, not as raw bytes: a `\`-continued command
            // read back off the grid has real newlines in it, and sent raw the shell would start
            // running it a fragment at a time. Inside the brackets it is one command.
            let bracketed = session.withTerminal { $0.modes.bracketedPaste }
            performPaste(command, bracketed: bracketed)
            send([0x0D])
        case .editAndRun:
            if !editAndRunCommand(atAbsoluteRow: region.promptRow) { NSSound.beep() }
        case .openInWorkbench:
            guard let command = requestCommand(of: region) else { NSSound.beep(); return }
            if !presentRequestEditor(command: command, then: { [weak self] line in
                self?.runFromWorkbench(line)
            }) { NSSound.beep() }
        case .copyAs(let format):
            guard let command = requestCommand(of: region) else { NSSound.beep(); return }
            copyToPasteboard(RequestExport.render(command, as: format))
        case .saveAsButton:
            guard let command = requestCommand(of: region) else { NSSound.beep(); return }
            // The same path the workbench's own `Save as Button…` takes: the sheet names it, and
            // the list goes back through the config file so the button appears in every window.
            if !presentQuickActionEditor(for: command, then: { action in
                let delegate = NSApp.delegate as? AppDelegate
                delegate?.setQuickActions((delegate?.quickActions ?? []) + [action])
            }) { NSSound.beep() }
        case .saveToProject:
            guard let command = requestCommand(of: region) else { NSSound.beep(); return }
            if !presentQuickActionEditor(for: command, then: { [weak self] action in
                self?.appendToProjectFile("quick = " + action.configValue)
            }) { NSSound.beep() }
        case .toggleFold: toggleFold(ofCommand: id, full: NSEvent.modifierFlags.contains(.option))
        case .toggleFoldAll: _ = foldAllLongOutput()
        case .notifyWhenDone(let armed): setNotification(armed: !armed, forCommand: id)
        case .setLens(let lens):
            switch lens {
            // The two that need a word from the user open the field over the block's command row
            // rather than switching to a lens with nothing in it.
            case .filter, .grep: presentLensField(for: lens, on: id)
            case .diff:
                // The row carries "diff"; which run to diff against is the cache's answer, and the
                // menu only enables the row when there is one.
                guard let previous = previousRun(of: id) else { NSSound.beep(); return }
                setLens(.diff(previousCommandID: previous), on: id)
            default: setLens(lens, on: id)
            }
        case .toggleLens:
            if !toggleLensOfCurrentBlock() { NSSound.beep() }
        case .copyBody:
            guard let text = responseText(of: id, headersOnly: false) else { NSSound.beep(); return }
            copyToPasteboard(text)
        case .copyHeaders:
            guard let text = responseText(of: id, headersOnly: true) else { NSSound.beep(); return }
            copyToPasteboard(text)
        case .runEvery(let seconds):
            // The block's own command line, not a rebuilt one: the twentieth run has to be the
            // same request as the first, or the numbers in the header compare two things.
            startWatch(plan: WatchPlan(interval: seconds, stop: .never),
                       command: session.withTerminal { $0.commandLine(of: region) })
        case .watch(let seed):
            let command = session.withTerminal { $0.commandLine(of: region) }
            guard !command.isEmpty else { NSSound.beep(); return }
            presentWatchPlanEditor(seed: seed, command: command, on: id)
        // The Stop button and the menu row always stop, wherever the block is: unlike `⌘.`, the
        // press names the series it belongs to.
        case .stopWatch:
            if !stopWatch(.stopped) { NSSound.beep() }
        // The body is past what a lens will re-lay-out. The row says so and still does the thing
        // that works on a response that size.
        case .lensUnavailable: saveOutput(ofCommand: id)
        }
    }

    /// The response's body or its headers as text, for the two Copy rows. Built from the parsed
    /// exchange rather than from the grid, so `Copy Headers` gives the headers and not the blank
    /// line and the body under them.
    private func responseText(of id: UInt32, headersOnly: Bool) -> String? {
        guard case .request(let exchange)? = requestCache.entry(for: id),
              let exchange else { return nil }
        if headersOnly {
            guard let head = exchange.final else { return nil }
            var status = "HTTP/\(head.version) \(head.status)"
            if !head.reason.isEmpty { status += " \(head.reason)" }
            return ([status] + head.headers.map { "\($0.name): \($0.value)" })
                .joined(separator: "\n")
        }
        return exchange.bodyLines.isEmpty ? nil : exchange.bodyLines.joined(separator: "\n")
    }

    /// The request a block ran, parsed, or nil when its command line is not one.
    ///
    /// Re-parsed here rather than kept in the cache beside the exchange: this runs on a menu press,
    /// not per frame, and holding a whole `CurlCommand` per block on screen to save one parse on a
    /// click nobody may ever make is the wrong trade. Nil only when the grid no longer holds the
    /// command the menu was built from -- a `clear` between opening the menu and choosing from it.
    private func requestCommand(of region: CommandRegion) -> CurlCommand? {
        CurlCommand.parse(session.withTerminal { $0.commandLine(of: region) })
            .map(RequestRun.stripAdditions(from:))
    }

    /// The button sheet, prefilled from a request, on this pane's window.
    ///
    /// A sheet window rather than `presentAsSheet` for the reason `presentCommandEditor` sets out:
    /// a pane is a view, so there is no presenting controller, and a window retains a content view
    /// controller but not the controller behind a bare content view.
    @discardableResult
    private func presentQuickActionEditor(for command: CurlCommand,
                                          then keep: @escaping (QuickAction) -> Void) -> Bool {
        guard let window else { return false }
        let editor = QuickActionEditor(editing: RequestEditorModel(command: command).quickActionDraft,
                                       heading: "New Button", verb: "Save")
        let size = editor.view.frame.size == .zero ? NSSize(width: 420, height: 260) : editor.view.frame.size
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.contentViewController = editor
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        editor.onFinish = { [weak window, weak sheet] action in
            if let sheet { window?.endSheet(sheet) }
            guard let action else { return }
            keep(action)
        }
        window.beginSheet(sheet) { _ in }
        return true
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var headerForHoveredBlock: BlockHeader? {
        guard let row = hoveredBlock?.headerRow else { return nil }
        return headersOnScreen[row]
    }

    /// Top-right corner of a visible row, in view coordinates, for placing the overlay.
    func overlayOrigin(forHeaderRow row: Int) -> NSPoint {
        let cell = cellSizePoints
        return NSPoint(x: bounds.width - padding, y: bounds.height - padding - CGFloat(row + 1) * cell.height)
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
    /// nil for a remote pane. What a saved session can honestly restore is a shell on *this* Mac in
    /// a directory; restoring a remote tab would mean re-attaching at launch to a machine that may
    /// be asleep, unpaired or gone -- and its transcript is somebody else's screen, not this Mac's.
    func sessionSnapshot(title: String?) -> PaneSnapshot? {
        guard remote == nil else { return nil }
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

    /// The pane's own terminal face, as an `NSFont` at point size, for the chrome that has to sit on
    /// the grid's columns -- which is the pinned band's label and nothing else.
    ///
    /// Taken from the `FontSet` the renderer is drawing with rather than resolved a second time from
    /// the family name: the band is kerned by the difference between its advance and the cell's
    /// width, and that is only the `ceil` in `FontSet` (which builds its font at `pointSize × scale`
    /// and rounds the advance up to whole device pixels) if the two are the same face. Asking
    /// `.monospacedSystemFont` for it is why `↑ $ swift build` was drawn in SF Mono over a Menlo
    /// grid, with a kern of `(Menlo cell) − (SF Mono advance)` -- a different number, of a different
    /// sign, from the rounding it claimed to be.
    ///
    /// The `system` family goes through `NSFont` for the same reason `systemMonospacedFont` exists:
    /// SF Mono is reachable only through that call, and its descriptor does not resolve by name.
    static func terminalFont(family: String, fonts: FontSet, size: CGFloat) -> NSFont {
        guard family.lowercased() != "system" else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let descriptor = CTFontCopyFontDescriptor(fonts.regular) as NSFontDescriptor
        return NSFont(descriptor: descriptor, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Whether ⌘C has anything to copy, so the menu item can grey out.
    ///
    /// A lens selection counts. Both Copy validators -- the Edit menu's and `TabController`'s
    /// `canPerform` -- gate on this, and a disabled menu item means AppKit never dispatches the ⌘C
    /// key equivalent either: a drag over a pretty-printed response could be made, was drawn, and
    /// then could not be copied by any route at all.
    var hasSelection: Bool {
        if let lensSelection, let buffer = lensBuffers[lensSelection.commandID],
           !lensSelection.text(from: buffer).isEmpty {
            return true
        }
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
        // A lens selection wins when there is one: it is the visible one, and the terminal's own
        // selection was cleared the moment a drag started on a lens line.
        if let lensSelection, let buffer = lensBuffers[lensSelection.commandID] {
            let text = lensSelection.text(from: buffer)
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
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
        // Checked here, before the editor or the confirmation sheet: a paste into a session that
        // will not take it must not put up a sheet and then do nothing when it is dismissed.
        guard acceptsInput else {
            NSSound.beep()
            return
        }
        let bracketed = session.withTerminal { $0.modes.bracketedPaste }

        // Several lines go to the editor by default, and this is why: once a multi-line command is
        // on the shell's line editor it is very hard to change. Clicking cannot help either -- with
        // real newlines in the buffer the shell re-wraps it on its own terms, so the distance in
        // cells on screen stops matching the number of arrow presses, and there is no honest
        // arithmetic left. Editing it before it lands is the reliable answer, not a nicer dialog.
        if PasteGuard.lineCount(text) > 1 {
            switch config.multilinePaste {
            case .edit:
                let shown = presentEditorForPaste(text, bracketed: bracketed)
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
        // Every paste passes through here -- ⌘V, the middle button, the confirmation sheet, the
        // command editor and the workbench itself -- so this is the one place that can notice a
        // request arriving on the command line.
        armWorkbenchHint(for: text)
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

    /// One entry of the context menu's block group: which action, on which command.
    private final class BlockMenuEntry: NSObject {
        let action: BlockAction
        let id: UInt32
        init(action: BlockAction, id: UInt32) { self.action = action; self.id = id }
    }

    /// The id of the command whose region covers a point, or nil where there is none -- above the
    /// first prompt, or with a shell that emits no marks.
    private func commandID(under point: NSPoint) -> UInt32? {
        session.withTerminal { t in
            guard t.shellEmitsPromptMarks else { return nil }
            let position = self.position(topLeft(point), in: t)
            let id = t.command(containingAbsoluteRow: position.row)?.id ?? 0
            return id == 0 ? nil : id
        }
    }

    @objc private func blockActionFromMenu(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? BlockMenuEntry else { return }
        perform(entry.action, on: entry.id)
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
    ///
    /// A `curl` gets the workbench and everything else gets the plain editor. That is the whole
    /// routing rule, and it is the same one `pasteWithEditor` and `editAndRun` follow: one chord,
    /// two sheets, chosen by what the line actually is rather than by which menu item was used.
    private func editCurrentInput(_ text: String) {
        dismissWorkbenchHint()
        if let command = CurlCommand.parse(text),
           presentRequestEditor(command: command, then: { [weak self] line in
               self?.abandonCurrentLine()
               self?.runFromWorkbench(line)
           }) {
            return
        }
        presentCommandEditor(text: text, heading: "Edit the command line", runTitle: "Run") {
            [weak self] edited in
            guard let self else { return }
            self.abandonCurrentLine()
            let bracketed = self.session.withTerminal { $0.modes.bracketedPaste }
            self.performPaste(edited, bracketed: bracketed)
        }
    }

    /// Throws away whatever is on the shell's line editor, so an edited command replaces it rather
    /// than being appended to it.
    ///
    /// `^C`, not `^E^U`. `^U` kills a *line*, and the buffer this feature exists for is a
    /// multi-line one: a five-line `curl` pasted from a browser left four of its lines behind, and
    /// the edited command was appended to them -- the shell then ran
    /// `--compressed curl --compressed …`, which reported `Could not resolve host: curl`. Every
    /// common shell abandons the whole buffer on `^C` and draws a fresh prompt, which is exactly
    /// what "replace what is on the line" means. It costs a visible `^C` in the scrollback, which
    /// is honest: something *was* discarded.
    private func abandonCurrentLine() {
        send([0x03])
    }

    /// Runs what the workbench finished with, and remembers it.
    ///
    /// A bracketed paste and then a separate `\r`, rather than a line ending in one: a request line
    /// is long and often has quoted newlines in its body, and inside the brackets the shell takes
    /// the whole thing as text instead of running it a fragment at a time. The `\r` outside them is
    /// what submits it.
    ///
    /// Recorded here as well as when the block finishes, because these are different guarantees: a
    /// pane with no shell integration has no blocks and would otherwise never write a request to
    /// the history at all. `RequestHistory.record` dedups on the parsed request, so a run that is
    /// recorded twice is one row either way.
    private func runFromWorkbench(_ line: String) {
        guard !line.isEmpty else { return }
        let bracketed = session.withTerminal { $0.modes.bracketedPaste }
        performPaste(line, bracketed: bracketed)
        send([0x0D])
        // `performPaste` arms the pill for any pasted curl; this one is already running, and a pill
        // offering to edit a line that has left the prompt would point at nothing.
        dismissWorkbenchHint()
        (NSApp.delegate as? AppDelegate)?.requests?.record(line)
    }

    /// `⌘⇧V`: paste, but look at it first. The plain paste path deliberately does not interrupt a
    /// multi-line paste when bracketed paste is on -- the shell shows it rather than running it --
    /// which is right for safety and wrong for the one case where you *want* the editor. This is
    /// that case, asked for on purpose.
    @discardableResult
    func pasteWithEditor() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty,
              acceptsInput else {
            return false
        }
        dismissWorkbenchHint()
        // A `curl` on the pasteboard is a request, and a request has a better editor than a text
        // box. Everything else pastes through the plain one exactly as it always did.
        if let command = CurlCommand.parse(text),
           presentRequestEditor(command: command, then: { [weak self] line in
               self?.runFromWorkbench(line)
           }) {
            return true
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
        _ = presentEditorForPaste(text, bracketed: bracketed)
    }

    /// The sheet a paste is shown in before it lands: the workbench when the text is a request,
    /// the plain editor otherwise.
    ///
    /// `multiline-paste = edit` exists because a multi-line command is very hard to change once the
    /// shell's line editor has it -- and a `curl` copied out of a browser is the multi-line paste
    /// people actually make. Sending it to a text box when there is a form for it is the feature
    /// not being where it is needed most.
    @discardableResult
    private func presentEditorForPaste(_ text: String, bracketed: Bool) -> Bool {
        if let command = CurlCommand.parse(text).map(RequestRun.stripAdditions(from:)),
           presentRequestEditor(command: command, then: { [weak self] line in
               self?.runFromWorkbench(line)
           }) {
            return true
        }
        return presentCommandEditor(text: text, heading: "Edit before pasting", runTitle: "Paste") {
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
            // The editor is prefilled with something the user is about to run, so it gets the
            // command line without the prompt -- the same text `Run Again` sends.
            return terminal.commandLine(of: region)
        }
        guard !command.isEmpty else { return false }
        // A block the workbench ran holds `curl -sSi -w '<sentinel>' …` in the grid. Editing it
        // again must show what was asked for, not what Nyx measured it with -- otherwise `-i` and
        // a nine-variable write-out format appear in the form the second time round, and stay in
        // the line if the user runs it from there.
        if let request = CurlCommand.parse(command) {
            let stripped = RequestRun.stripAdditions(from: request)
            return editAndRun(command: stripped.shellLine(masking: .none, layout: .oneLine))
        }
        return editAndRun(command: command)
    }

    /// The same editor, on a line that did not come from this pane's scrollback -- a row of the
    /// palette's Requests section, which may well have been run in another tab.
    ///
    /// A request goes to the workbench, which is what makes a palette row of a `curl` open as a
    /// form: every row of that section is one by construction, since nothing else is ever recorded.
    @discardableResult
    func editAndRun(command: String) -> Bool {
        guard !command.isEmpty else { return false }
        dismissWorkbenchHint()
        // Stripped here as well as in the history: this is also the palette's only path, and a row
        // read from a file an older build wrote -- or one recorded by a build without the strip --
        // would otherwise open a form full of `-i` and a write-out format nobody typed.
        if let parsed = CurlCommand.parse(command).map(RequestRun.stripAdditions(from:)),
           presentRequestEditor(command: parsed, then: { [weak self] line in
               self?.runFromWorkbench(line)
           }) {
            return true
        }
        return presentCommandEditor(text: command, heading: "Edit and run", runTitle: "Run") {
            [weak self] edited in
            guard let self else { return }
            // Sent as a paste so a multi-line edit arrives as one command rather than as several
            // lines the shell starts running one at a time.
            let bracketed = self.session.withTerminal { $0.modes.bracketedPaste }
            self.performPaste(edited, bracketed: bracketed)
        }
    }

    /// `new_request`: the workbench on a blank request -- `curl https://`, with the form waiting
    /// for a URL, headers and a body.
    @discardableResult
    func newRequest() -> Bool {
        dismissWorkbenchHint()
        return presentRequestEditor(command: RequestEditorModel.newRequest().command) {
            [weak self] line in self?.runFromWorkbench(line)
        }
    }

    /// Opens the request workbench on a parsed `curl`, and hands whatever the sheet finishes with
    /// to `run` -- the same contract `presentCommandEditor` has.
    ///
    /// The fallback is the point of the return value: a request that cannot be shown as a form is
    /// still shown as a command line, because a user who asked to edit a request must never be
    /// answered with nothing at all.
    ///
    /// Reached from the paste pill, `⌘E`, `⌘⇧V`, the block menu's "Open in Workbench", the
    /// palette's request rows and the New Request action.
    @discardableResult
    func presentRequestEditor(command: CurlCommand, then run: @escaping (String) -> Void) -> Bool {
        let text = command.shellLine(masking: .none, layout: .multiline)
        guard let window else {
            return presentCommandEditor(text: text, heading: "Edit and run", runTitle: "Run",
                                        then: run)
        }
        let editor = RequestEditor(command: command, palette: Pane.resolvedPalette(for: config),
                                   watchInterval: config.httpWatchInterval)
        editor.onSaveToProject = { [weak self] _, line in self?.appendToProjectFile(line) }
        // Set by `onWatch` when the pane cannot watch, and acted on once the sheet has ended: see
        // `reportWatchRefused` for why the alert cannot go up while the sheet is still there.
        var refusedWatch = false
        editor.onWatch = { [weak self, weak editor] request in
            guard let self, let line = editor?.runLine else { return }
            // Asked *before* the request is run. "Run 10 times" that cannot watch and runs the
            // request once anyway is a menu item doing a tenth of what it says and then going
            // quiet -- a refusal means zero runs, and the sentence that follows says why.
            guard self.canWatch else {
                refusedWatch = true
                return
            }
            // Typed first, so the user sees the request go the moment the sheet closes, and the
            // history records it the way every other run is recorded. The series is then told the
            // first run is already out: it starts *due*, and without this it would type a second
            // copy of the same request a quarter of a second later.
            run(line)
            self.startWatch(plan: Pane.plan(for: request, interval: self.config.httpWatchInterval),
                            command: line, firstRunSent: true)
        }

        // The same sheet-window mechanics as `presentCommandEditor`, for the same reasons: this
        // window's content is a view, so there is no presenting controller, and the window retains
        // `contentViewController` but not a bare `contentView`'s controller.
        let size = editor.view.frame.size == .zero ? NSSize(width: 720, height: 480) : editor.view.frame.size
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .fullSizeContentView, .resizable],
                             backing: .buffered, defer: false)
        sheet.contentViewController = editor
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false

        // Both captures weak: the window retains the sheet while it is attached and the sheet
        // retains the editor, so a strong `sheet` here would be the editor holding its own window
        // through the closure it stores -- a cycle that outlives the sheet it was made for.
        editor.onFinish = { [weak window, weak sheet] line in
            if let sheet { window?.endSheet(sheet) }
            guard let line else { return }
            run(line)
        }
        // The completion runs when the sheet has ended, which is the earliest moment an alert can
        // be put on this window and actually be seen.
        window.beginSheet(sheet) { [weak self] _ in
            guard refusedWatch else { return }
            self?.reportWatchRefused()
        }
        return true
    }

    /// What the sheet's Repeat menu asked for, as a plan the pane can run.
    ///
    /// The sheet knows nothing about series, and the interval belongs to the configuration, so the
    /// conversion lives here rather than in either -- and `Run 10 times` carries the interval too,
    /// because ten runs still have to be spaced.
    static func plan(for request: WatchPlanRequest, interval: Double) -> WatchPlan {
        switch request {
        case .every(let seconds): return WatchPlan(interval: seconds, stop: .never)
        case .times(let count): return WatchPlan(interval: interval, stop: .count(count))
        case .untilStatus(let code): return WatchPlan(interval: interval, stop: .until(.status(code)))
        }
    }

    /// Appends one `quick = …` line to the project's `.nyx` file, creating it when there is none.
    ///
    /// Written through the same file the approval gate reads, so the digest changes and the gate
    /// asks again before the button is offered -- including when Nyx is the one that wrote it.
    /// Nothing here is silent: no directory, or a file that will not take the line, says so.
    private func appendToProjectFile(_ line: String) {
        guard let directory = workingDirectory else {
            reportProjectWrite("This pane does not know which directory it is in, so there is no "
                + "project to save to. Shell integration reports the directory.")
            return
        }
        var text = ProjectApprovalsStore.shared.projectFile(in: directory) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        let url = URL(fileURLWithPath: directory).appendingPathComponent(ProjectActionsFile.name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            reportProjectWrite("\(url.path) could not be written: \(error.localizedDescription)")
        }
    }

    private func reportProjectWrite(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not save to the project"
        alert.informativeText = message
        // On the sheet that asked, when there is one: an alert on the window behind it would be
        // queued until that sheet closed, which reads as nothing having happened.
        if let host = window?.attachedSheet ?? window {
            alert.beginSheetModal(for: host) { _ in }
        } else {
            NSSound.beep()
        }
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
