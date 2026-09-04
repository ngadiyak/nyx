import AppKit
import Darwin
import NyxCore

/// The window's tabs: a `TabBarView` above a container that holds exactly one `PaneTreeView` -- the
/// selected tab's.
///
/// A tab owns its tree for its whole life. Switching tabs takes one tree out of the view hierarchy
/// and puts another in; nothing is rebuilt and no session is restarted. That is also what stops an
/// unselected tab from drawing: a `Pane` builds its display link in `viewDidMoveToWindow` and
/// invalidates it when it leaves the window, so a tree that is not on screen has no display link at
/// all. Its sessions keep running and keep reading their PTYs, and the frame they would have drawn
/// is simply never drawn until the tab comes back.
///
/// The decisions -- which tab a shortcut picks, what stays selected after a close, whether the bar
/// is worth its 28 points, how a title shortens, what an indicator means -- are `TabStrip`,
/// `TabTitle` and `TabIndicator` in `NyxCore`, where they are unit tested. What is left here is
/// events in and views out.
final class TabController: NSViewController, NSMenuItemValidation {
    var onAllTabsClosed: (() -> Void)?
    var onTitleChange: ((String) -> Void)?

    /// Why the last attempt to make a pane failed, for `TerminalWindowController` to report when
    /// the very first one does. A `() -> Pane?` factory cannot throw, so the error is left here.
    private(set) var paneCreationFailure: Error?

    /// One tab: its panes, the title they last reported, and what it has to tell the user about.
    private final class Tab {
        let panes: PaneTreeView
        /// What the program set with OSC 0/2; empty if it never has.
        var oscTitle = ""
        /// The program-and-directory title used when there is no OSC title. Recomputed rather than
        /// derived on demand because it costs two `proc_*` calls.
        var fallbackTitle = ""
        var indicator: TabIndicator = .none

        init(panes: PaneTreeView) { self.panes = panes }

        var title: String { oscTitle.isEmpty ? fallbackTitle : oscTitle }
    }

    private var config: Config
    private var tabs: [Tab] = []
    private var selected = 0

    private let tabBar = TabBarView(frame: .zero)
    private let paneContainer = NSView(frame: .zero)
    private var tabBarHeight: NSLayoutConstraint?

    /// Where the first pane of the tab being created should start. The factory a `PaneTreeView`
    /// calls takes no arguments and the new tree has nobody to inherit from, so the directory
    /// reaches it the same way `PaneTreeView.workingDirectoryForNewPane` reaches a split.
    private var workingDirectoryForNewTab: String?
    /// A fallback-title refresh is already queued; see `scheduleTitleRefresh`.
    private var titleRefreshScheduled = false

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
        newTab()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(paneContainer)
        let height = tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height)
        tabBarHeight = height
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            height,
            paneContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        tabBar.setColors(palette: Pane.resolvedPalette(for: config))
        view = root
        // The first tab exists before this view does, so the bar's state has to be caught up here
        // rather than only on the next change.
        refreshBar()
    }

    /// The selected tree fills the container. Auto Layout owns the container; the trees inside it
    /// are placed by frame, like the panes inside them.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard tabs.indices.contains(selected) else { return }
        tabs[selected].panes.frame = paneContainer.bounds
    }

    var focusedPane: Pane? {
        tabs.indices.contains(selected) ? tabs[selected].panes.focusedPane : nil
    }

    // MARK: - Opening and closing tabs

    /// Adds a tab at the end and selects it. Does nothing if its first pane cannot be created --
    /// the same answer `PaneTreeView.split` gives, and for the same reason.
    func newTab() {
        workingDirectoryForNewTab = tabs.indices.contains(selected)
            ? tabs[selected].panes.inheritableWorkingDirectory()
            : nil
        defer { workingDirectoryForNewTab = nil }
        let tree = makeTree()
        guard tree.focusedPane != nil else { return }
        let tab = Tab(panes: tree)
        tabs.append(tab)
        wire(tab)
        show(tabs.count - 1)
    }

    /// A tree whose panes are made with this window's config, inheriting a directory from whichever
    /// pane is being split -- or, for the first pane of a new tab, from the tab it was opened from.
    private func makeTree() -> PaneTreeView {
        // Weak, because the tree owns the closure that reads it. It is still nil during the tree's
        // own initialiser, which is exactly when `workingDirectoryForNewTab` is the right answer.
        weak var tree: PaneTreeView?
        let makePane: () -> Pane? = { [weak self] in
            guard let self else { return nil }
            let directory = tree?.workingDirectoryForNewPane ?? self.workingDirectoryForNewTab
            do {
                return try Pane(.zero, config: self.config, workingDirectory: directory)
            } catch {
                self.paneCreationFailure = error
                return nil
            }
        }
        let view = PaneTreeView(config: config, makePane: makePane)
        tree = view
        view.autoresizingMask = [.width, .height]
        return view
    }

    private func wire(_ tab: Tab) {
        let tree = tab.panes
        tree.onAllPanesClosed = { [weak self, weak tree] in
            guard let self, let tree, let index = self.index(of: tree) else { return }
            self.removeTab(at: index)
        }
        tree.onFocusedTitleChange = { [weak self, weak tree] title in
            guard let self, let tree, let index = self.index(of: tree) else { return }
            self.tabs[index].oscTitle = title
            self.refreshTitles()
        }
        tree.onAnyPaneOutput = { [weak self, weak tree] in
            guard let self, let tree, let index = self.index(of: tree) else { return }
            self.output(fromTabAt: index)
        }
        tree.onAnyPaneBell = { [weak self, weak tree] in
            guard let self, let tree, let index = self.index(of: tree) else { return }
            self.indicator(self.tabs[index].indicator.afterBell(isSelected: index == self.selected),
                           forTabAt: index)
        }
    }

    private func index(of tree: PaneTreeView) -> Int? {
        tabs.firstIndex { $0.panes === tree }
    }

    /// `⌘W`: closes the focused pane, asking first if something is running in it. The tab goes with
    /// its last pane and the window with the last tab, both by way of `PaneTreeView`'s own report.
    func closeCurrentPane() {
        guard tabs.indices.contains(selected), let pane = tabs[selected].panes.focusedPane else { return }
        let tab = tabs[selected]
        confirmClose(of: [pane], message: "Close this pane?") { [weak tab] in
            tab?.panes.closeFocusedPane()
        }
    }

    /// The close button on a tab: the whole tab goes, panes and all.
    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        confirmClose(of: tab.panes.allPanes, message: "Close this tab?") { [weak self, weak tab] in
            guard let self, let tab, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            tab.panes.terminate()
            self.removeTab(at: index)
        }
    }

    /// Takes a tab out of the strip. Its sessions are already over: either its last pane closed
    /// (which is what reported it) or `closeTab` terminated them.
    private func removeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        tab.panes.onAllPanesClosed = nil
        tab.panes.onFocusedTitleChange = nil
        tab.panes.onAnyPaneOutput = nil
        tab.panes.onAnyPaneBell = nil
        tab.panes.removeFromSuperview()
        let next = TabStrip.selectionAfterClosing(index, selected: selected, tabCount: tabs.count)
        tabs.remove(at: index)
        guard let next else {
            selected = 0
            refreshBar()
            onAllTabsClosed?()
            return
        }
        show(next)
    }

    /// Ends every session in every tab. The window controller calls this as its window closes.
    func terminateAll() {
        for tab in tabs { tab.panes.terminate() }
    }

    // MARK: - Selection

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        show(index)
    }

    func nextTab() { selectTab(at: TabStrip.next(after: selected, tabCount: tabs.count)) }
    func previousTab() { selectTab(at: TabStrip.previous(before: selected, tabCount: tabs.count)) }

    /// Puts a tab's tree on screen and takes the previous one off. Selecting the tab that is
    /// already selected still clears its indicators and reclaims focus, which is what makes this
    /// safe to call after a close.
    private func show(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if tab.panes.superview !== paneContainer {
            for other in tabs where other.panes.superview === paneContainer {
                other.panes.removeFromSuperview()
            }
            tab.panes.frame = paneContainer.bounds
            paneContainer.addSubview(tab.panes)
        }
        selected = index
        tab.indicator = tab.indicator.afterSelection()
        // The window forgot its first responder when the previous tree left the hierarchy.
        tab.panes.restoreFocus()
        refreshTitles()
        refreshBar()
    }

    // MARK: - Indicators

    private func output(fromTabAt index: Int) {
        indicator(tabs[index].indicator.afterOutput(isSelected: index == selected), forTabAt: index)
        scheduleTitleRefresh()
    }

    private func indicator(_ new: TabIndicator, forTabAt index: Int) {
        guard tabs.indices.contains(index), tabs[index].indicator != new else { return }
        tabs[index].indicator = new
        refreshBar()
    }

    // MARK: - Titles

    /// Recomputes the fallback title of every tab that has no OSC title, and reports the selected
    /// tab's title to the window.
    private func refreshTitles() {
        var changed = false
        for tab in tabs where tab.oscTitle.isEmpty {
            let fallback = tab.panes.focusedPane?.fallbackTitle ?? ""
            if fallback != tab.fallbackTitle {
                tab.fallbackTitle = fallback
                changed = true
            }
        }
        if changed { refreshBar() }
        onTitleChange?(tabs.indices.contains(selected) ? tabs[selected].title : "")
    }

    /// A fallback title is built from what the shell is running and where, neither of which can
    /// change without the program saying something first -- so output, not a timer, is what drives
    /// the refresh, and an idle window schedules nothing at all.
    ///
    /// The delay is what makes the answer right rather than merely fresh: pressing return echoes a
    /// newline *before* the shell has forked, so reading the foreground process in that instant
    /// still finds the shell. A third of a second later it finds the program.
    private func scheduleTitleRefresh() {
        guard !titleRefreshScheduled else { return }
        titleRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.titleRefreshScheduled = false
            self.refreshTitles()
        }
    }

    // MARK: - The bar

    private func refreshBar() {
        let visible = TabStrip.isBarVisible(config.tabBar, tabCount: tabs.count)
        tabBar.isHidden = !visible
        tabBarHeight?.constant = visible ? TabBarView.height : 0
        guard visible else { return }
        tabBar.setTabs(tabs.map { TabBarItem(title: $0.title, indicator: $0.indicator) }, selected: selected)
    }

    // MARK: - Closing something that is busy

    /// Asks before closing panes that have a program running in them. Nothing running,
    /// `confirm-close-process` off, or no window to hang a sheet on all mean "just close".
    ///
    /// The sheet is a sheet rather than a modal alert on purpose: `runModal()` would stop the run
    /// loop, and with it every other tab's session.
    private func confirmClose(of panes: [Pane], message: String, then close: @escaping () -> Void) {
        guard config.confirmCloseProcess, let window = view.window,
              panes.contains(where: TabController.hasLiveChildren) else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "A process is still running. Closing will end it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            close()
        }
    }

    /// Has this pane's shell got anything running under it?
    ///
    /// Best-effort by design: `proc_listchildpids` failing -- the shell is already gone, the call is
    /// refused -- reads as "nothing running", because a close that cannot be confirmed must still
    /// be a close. Only the shell's direct children are asked about, so the shell itself never
    /// counts as its own reason to confirm.
    private static func hasLiveChildren(_ pane: Pane) -> Bool {
        let pid = pane.processID
        guard pid > 0 else { return false }
        var children = [pid_t](repeating: 0, count: 64)
        let written = children.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return proc_listchildpids(pid, base, Int32(buffer.count))
        }
        return written > 0
    }

    // MARK: - Configuration

    func apply(_ newConfig: Config) {
        config = newConfig
        for tab in tabs { tab.panes.apply(newConfig) }
        tabBar.setColors(palette: Pane.resolvedPalette(for: newConfig))
        refreshBar()
    }

    /// The theme follows the system appearance whenever `dark:`/`light:` are set, the same as the
    /// panes and the dividers. The bar reports the change rather than this controller observing it:
    /// `viewDidChangeEffectiveAppearance` belongs to `NSView`, not to `NSViewController`.
    private func appearanceChanged() {
        guard config.darkThemeName != nil || config.lightThemeName != nil else { return }
        tabBar.setColors(palette: Pane.resolvedPalette(for: config))
    }

    // MARK: - Actions
    //
    // Reached through the responder chain: the focused `Pane` is the first responder, this
    // controller sits behind its own view, and a menu item with a nil target walks up to it.
    // `Pane.keyDown` finds the same object for a chord bound in the config file, so a menu item
    // and a key binding cannot disagree about what an action does.

    @objc func performTerminalAction(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let action = TerminalAction(rawValue: name) else { return }
        perform(action)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performTerminalAction(_:)) else { return true }
        guard let name = item.representedObject as? String,
              let action = TerminalAction(rawValue: name) else { return false }
        return canPerform(action)
    }
}

extension TabController: ActionTarget {
    private var panes: PaneTreeView? {
        tabs.indices.contains(selected) ? tabs[selected].panes : nil
    }

    /// Actions this controller cannot carry out itself belong to the application: they outlive any
    /// one window, so they go to the delegate rather than being duplicated per window.
    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    func perform(_ action: TerminalAction) {
        switch action {
        case .newWindow: appDelegate?.newWindow(nil)
        case .openConfig: appDelegate?.openConfig(nil)
        case .reloadConfig: appDelegate?.reloadConfig(nil)

        case .newTab: newTab()
        case .closePane: closeCurrentPane()
        case .nextTab: nextTab()
        case .previousTab: previousTab()
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            guard let number = TabStrip.commandNumber(for: action),
                  let index = TabStrip.index(forCommandNumber: number, tabCount: tabs.count) else { return }
            selectTab(at: index)

        case .splitRight: panes?.split(axis: .horizontal)
        case .splitDown: panes?.split(axis: .vertical)
        case .focusLeft: panes?.moveFocus(.left)
        case .focusRight: panes?.moveFocus(.right)
        case .focusUp: panes?.moveFocus(.up)
        case .focusDown: panes?.moveFocus(.down)
        case .growLeft: panes?.resizeFocused(.left)
        case .growRight: panes?.resizeFocused(.right)
        case .growUp: panes?.resizeFocused(.up)
        case .growDown: panes?.resizeFocused(.down)
        case .toggleZoom: panes?.toggleZoom()

        case .previousPrompt: if focusedPane?.jumpToPrompt(forward: false) != true { NSSound.beep() }
        case .nextPrompt: if focusedPane?.jumpToPrompt(forward: true) != true { NSSound.beep() }
        case .selectCommandOutput: if focusedPane?.selectCommandOutput() != true { NSSound.beep() }
        case .copyCommandOutput: if focusedPane?.copyLastCommandOutput() != true { NSSound.beep() }
        case .find, .findNext, .findPrevious, .commandPalette:
            // Wired up with the search bar and the palette overlay.
            NSSound.beep()

        case .copy: focusedPane?.copy(nil)
        case .paste: focusedPane?.paste(nil)
        case .clearScreen: focusedPane?.clearScreen()
        case .fontBigger: focusedPane?.zoomIn(nil)
        case .fontSmaller: focusedPane?.zoomOut(nil)
        case .fontReset: focusedPane?.zoomReset(nil)
        }
    }

    func canPerform(_ action: TerminalAction) -> Bool {
        switch action {
        case .newWindow, .openConfig, .reloadConfig, .newTab:
            return true
        case .nextTab, .previousTab:
            return tabs.count > 1
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            guard let number = TabStrip.commandNumber(for: action) else { return false }
            return TabStrip.index(forCommandNumber: number, tabCount: tabs.count) != nil
        case .copy:
            return focusedPane?.hasSelection ?? false
        case .previousPrompt, .nextPrompt, .selectCommandOutput, .copyCommandOutput:
            // A shell with no integration emits no marks, and these do nothing without them.
            return focusedPane?.hasPromptMarks ?? false
        case .focusLeft, .focusRight, .focusUp, .focusDown,
             .growLeft, .growRight, .growUp, .growDown, .toggleZoom:
            return (panes?.paneCount ?? 0) > 1
        default:
            return focusedPane != nil
        }
    }
}
