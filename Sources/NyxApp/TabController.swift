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
    /// What an "Add to Group" item carries: the tab by identity, the group by id. Both can go
    /// while the menu is open -- the tab's shell exits, the group empties -- and both are checked
    /// again when it is chosen.
    private final class TabAndGroup {
        let tab: Tab
        let group: Int
        init(tab: Tab, group: Int) {
            self.tab = tab
            self.group = group
        }
    }

    private final class Tab {
        let panes: PaneTreeView
        /// A name the user typed, which outranks whatever the shell goes on setting -- that being
        /// the entire point of renaming a tab. "Reset Title" puts it back to nil.
        var customTitle: String?
        /// What the program set with OSC 0/2; empty if it never has.
        var oscTitle = ""
        /// The program-and-directory title used when there is no OSC title. Recomputed rather than
        /// derived on demand because it costs two `proc_*` calls.
        var fallbackTitle = ""
        var indicator: TabIndicator = .none

        init(panes: PaneTreeView) { self.panes = panes }

        var title: String { TabTitle.resolve(custom: customTitle, osc: oscTitle, fallback: fallbackTitle) }
    }

    private var config: Config
    private var tabs: [Tab] = []
    private var selected = 0
    /// Which tabs belong to which group. Kept in step with `tabs` by hand -- every insertion and
    /// removal tells it -- because the invariant it guarantees (a group's tabs are contiguous) is
    /// only worth anything if it is never briefly untrue.
    private var grouping = TabGrouping()

    private let tabBar = TabBarView(frame: .zero)
    private let paneContainer = NSView(frame: .zero)
    private var tabBarHeight: NSLayoutConstraint?
    /// The strip that offers to show a project's actions. Never more than that until the user has
    /// read them and approved the directory.
    private let projectBar = ProjectActionsBar(frame: .zero)

    /// A fallback-title refresh is already queued; see `scheduleTitleRefresh`.
    private var titleRefreshScheduled = false

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
        newTab()
    }

    /// The tabs a saved session recorded. Falls back to one ordinary tab if not one of them could
    /// be rebuilt -- a window with no tabs in it is not a state this controller may be left in.
    init(config: Config, restoring window: WindowSnapshot) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
        restore(window)
        if tabs.isEmpty { newTab() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(projectBar)
        root.addSubview(paneContainer)
        let height = tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height)
        tabBarHeight = height
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            height,
            projectBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            projectBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            projectBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            paneContainer.topAnchor.constraint(equalTo: projectBar.bottomAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTabs(at: [index]) }
        tabBar.onContextMenu = { [weak self] index, event in self?.showTabMenu(for: index, event: event) }
        tabBar.onToggleGroup = { [weak self] id in self?.toggleGroup(id) }
        tabBar.onGroupContextMenu = { [weak self] id, event in self?.showGroupMenu(for: id, event: event) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        tabBar.onShowTabList = { [weak self] in self?.showTabList() }
        tabBar.onQuickAction = { [weak self] index in self?.performQuickAction(index) }
        tabBar.onAddQuickAction = { [weak self] in self?.editQuickAction(at: nil) }
        tabBar.onQuickActionContextMenu = { [weak self] index, event in
            self?.showQuickActionMenu(index, event)
        }
        tabBar.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        projectBar.onReview = { [weak self] in self?.reviewProjectActions() }
        projectBar.onIgnore = { [weak self] in self?.ignoreProjectActions() }
        tabBar.setColors(palette: Pane.resolvedPalette(for: config))
        tabBar.setQuickActions(quickActions)
        view = root
        // The first tab exists before this view does, so the bar's state has to be caught up here
        // rather than only on the next change.
        refreshBar()
    }

    /// The selected tree fills the container. Auto Layout owns the container; the trees inside it
    /// are placed by frame, like the panes inside them.
    override func viewDidLayout() {
        super.viewDidLayout()
        layoutCommandPalette()
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
        addTab(inheriting: tabs.indices.contains(selected)
            ? tabs[selected].panes.inheritableWorkingDirectory()
            : nil)
    }

    /// A new tab starting in a named directory. "Duplicate Tab" is this with the directory of the
    /// tab that was right-clicked, which is the only thing a duplicate can honestly copy: a shell's
    /// history and its running processes cannot be forked.
    private func addTab(inheriting directory: String?) {
        let tree = PaneTreeView(config: config, makePane: paneFactory(), startingIn: directory)
        tree.autoresizingMask = [.width, .height]
        guard tree.focusedPane != nil else { return }
        let tab = Tab(panes: tree)
        tabs.append(tab)
        grouping.tabInserted(at: tabs.count - 1)
        wire(tab)
        show(tabs.count - 1)
        sessionChanged()
    }

    /// Makes the panes of one tree, with this window's config. A seed carries whatever the new pane
    /// should start from -- the directory it inherits, and the transcript when a saved session is
    /// being rebuilt.
    private func paneFactory() -> (PaneSeed) -> Pane? {
        { [weak self] seed in
            guard let self else { return nil }
            do {
                return try Pane(.zero, config: self.config, workingDirectory: seed.workingDirectory,
                                restoringTranscript: seed.transcript)
            } catch {
                self.paneCreationFailure = error
                return nil
            }
        }
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
        tree.onFocusedDirectoryChange = { [weak self, weak tree] directory in
            guard let self, let tree, self.index(of: tree) == self.selected else { return }
            self.workingDirectoryChanged(directory)
        }
        tree.onLayoutChange = { [weak self] in self?.sessionChanged() }
    }

    // MARK: - Saving and restoring the session
    //
    // The shape of what is written, and every rule about whether it may be read back, is
    // `SessionSnapshot`/`SessionRestore` in NyxCore. What is here is turning live tabs into that
    // shape and back.

    /// Something about the tabs changed. The application owns the file and the debounce, because a
    /// session spans every window and no one window can write it.
    private func sessionChanged() {
        appDelegate?.sessionChanged()
    }

    /// This window's tabs as a saved session records them, or nil when there is nothing worth
    /// recording.
    func sessionSnapshot() -> (tabs: [TabSnapshot], selected: Int)? {
        let saved: [TabSnapshot] = tabs.enumerated().compactMap { index, tab in
            guard let panes = tab.panes.sessionSnapshot() else { return nil }
            let group = grouping.group(ofTabAt: index)
            return TabSnapshot(layout: panes.layout, panes: panes.panes, focused: panes.focused,
                               customTitle: tab.customTitle, groupName: group?.name,
                               groupColorIndex: group?.colorIndex)
        }
        guard !saved.isEmpty else { return nil }
        return (saved, min(max(0, selected), saved.count - 1))
    }

    /// Rebuilds the tabs a snapshot describes. A tab whose panes could not be recreated is skipped
    /// rather than inserted empty, so this can end with fewer tabs than the file had -- including
    /// none at all, which the initialiser answers with an ordinary new tab.
    private func restore(_ window: WindowSnapshot) {
        // The group each restored tab claimed, in the order they actually came back. A tab whose
        // panes could not be recreated leaves its group's run one shorter rather than leaving a
        // hole in it, which is what keeps `TabGrouping`'s contiguity invariant true.
        var memberships: [(name: String?, colorIndex: Int)] = []
        for snapshot in window.tabs {
            guard let tree = PaneTreeView(config: config, makePane: paneFactory(),
                                          restoring: snapshot) else { continue }
            tree.autoresizingMask = [.width, .height]
            let tab = Tab(panes: tree)
            tab.customTitle = snapshot.customTitle
            tabs.append(tab)
            memberships.append((snapshot.groupName, snapshot.groupColorIndex ?? 1))
            wire(tab)
        }
        guard !tabs.isEmpty else { return }
        grouping = TabGrouping.restoring(memberships)
        show(min(max(0, window.selectedTab), tabs.count - 1))
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

    /// The close button on a tab, and every "close" item on its context menu: whole tabs go, panes
    /// and all, after **one** confirmation covering the batch. Asking once per tab for a
    /// "Close Other Tabs" over eight tabs would be eight sheets.
    private func closeTabs(at indices: [Int]) {
        let doomed = indices.filter { tabs.indices.contains($0) }.map { tabs[$0] }
        guard !doomed.isEmpty else { return }
        let panes = doomed.flatMap(\.panes.allPanes)
        let message = doomed.count == 1 ? "Close this tab?" : "Close \(doomed.count) tabs?"
        confirmClose(of: panes, message: message) { [weak self] in
            guard let self else { return }
            // Resolved again on this side of the sheet: a pane may have exited while it was up,
            // which takes its tab out of the strip and shifts every index after it.
            let live = doomed.compactMap { tab in self.tabs.firstIndex(where: { $0 === tab }) }
            guard !live.isEmpty else { return }
            let next = TabClosing.selectionAfterClosing(live, selected: self.selected,
                                                        tabCount: self.tabs.count)
            for tab in doomed {
                guard let index = self.tabs.firstIndex(where: { $0 === tab }) else { continue }
                tab.panes.terminate()
                self.detach(tab)
                self.tabs.remove(at: index)
                self.grouping.tabRemoved(at: index)
            }
            self.sessionChanged()
            guard let next else {
                self.selected = 0
                self.refreshBar()
                self.onAllTabsClosed?()
                return
            }
            self.show(next)
        }
    }

    /// Takes a tab out of the strip. Its sessions are already over: either its last pane closed
    /// (which is what reported it) or `closeTabs` terminated them.
    private func removeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        detach(tabs[index])
        let next = TabStrip.selectionAfterClosing(index, selected: selected, tabCount: tabs.count)
        tabs.remove(at: index)
        grouping.tabRemoved(at: index)
        sessionChanged()
        guard let next else {
            selected = 0
            refreshBar()
            onAllTabsClosed?()
            return
        }
        show(next)
    }

    /// Unhooks a tab from this controller and takes its view out of the hierarchy. Separate from
    /// removing it from the array because a batch close does the two at different moments.
    private func detach(_ tab: Tab) {
        tab.panes.onAllPanesClosed = nil
        tab.panes.onFocusedTitleChange = nil
        tab.panes.onAnyPaneOutput = nil
        tab.panes.onAnyPaneBell = nil
        tab.panes.onFocusedDirectoryChange = nil
        tab.panes.removeFromSuperview()
    }

    /// Ends every session in every tab. The window controller calls this as its window closes.
    func terminateAll() {
        for tab in tabs { tab.panes.terminate() }
    }

    // MARK: - Selection

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        // A tab inside a collapsed group has no slot in the bar, so selecting one -- by ⌘2, by
        // cycling, or from the palette -- used to put its panes on screen while the bar highlighted
        // nothing. Asking for a tab is asking to see it, which includes seeing where it is.
        //
        // Deliberately here and not in `show`: collapsing a group deliberately leaves the selection
        // on its first tab, and `toggleGroup` reaches `show` directly, so putting this there would
        // re-expand a group the moment it was collapsed.
        if let group = grouping.group(ofTabAt: index), group.isCollapsed {
            grouping.setCollapsed(false, forGroup: group.id)
            groupsChanged()
        }
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
        sessionChanged()
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
        let visible = TabStrip.isBarVisible(config.tabBar, tabCount: tabs.count,
                                            quickActionCount: config.quickActions.count)
        tabBar.isHidden = !visible
        guard visible else {
            tabBarHeight?.constant = 0
            return
        }
        tabBar.setTabs(tabs.map { TabBarItem(title: $0.title, indicator: $0.indicator) },
                       selected: selected, grouping: grouping)
        // Set after the tabs, because the bar is taller whenever a group is expanded and only it
        // knows whether one is.
        tabBarHeight?.constant = tabBar.preferredHeight
    }

    // MARK: - The tab context menu
    //
    // Which tabs each item resolves to, and what is selected once they are gone, is `TabClosing` in
    // NyxCore. What is here is the menu and the sheets.

    private func showTabMenu(for index: Int, event: NSEvent) {
        guard tabs.indices.contains(index) else { return }
        let menu = NSMenu()
        // Items are enabled by hand: this controller's `validateMenuItem` answers for the
        // `TerminalAction` items, and would say yes to all of these.
        menu.autoenablesItems = false
        menu.addItem(tabMenuItem("Close Tab", #selector(menuCloseTab(_:)), index))
        menu.addItem(tabMenuItem("Close Other Tabs", #selector(menuCloseOtherTabs(_:)), index,
                                 enabled: tabs.count > 1))
        menu.addItem(tabMenuItem("Close Tabs to the Right", #selector(menuCloseTabsToTheRight(_:)), index,
                                 enabled: index < tabs.count - 1))
        menu.addItem(.separator())
        menu.addItem(tabMenuItem("Duplicate Tab", #selector(menuDuplicateTab(_:)), index))
        menu.addItem(.separator())
        addGroupItems(to: menu, forTabAt: index)
        menu.addItem(.separator())
        menu.addItem(tabMenuItem("Rename Tab…", #selector(menuRenameTab(_:)), index))
        menu.addItem(tabMenuItem("Reset Title", #selector(menuResetTabTitle(_:)), index,
                                 enabled: tabs[index].customTitle != nil))
        NSMenu.popUpContextMenu(menu, with: event, for: tabBar)
    }

    /// The group half of a tab's menu. "Add to Group" is only offered when there is a group other
    /// than this tab's own to add it to; an empty submenu is worse than no submenu.
    private func addGroupItems(to menu: NSMenu, forTabAt index: Int) {
        let current = grouping.group(ofTabAt: index)
        menu.addItem(tabMenuItem("New Group from Tab…", #selector(menuNewGroup(_:)), index))

        let others = grouping.groups.filter { $0.id != current?.id }
        if !others.isEmpty {
            let item = NSMenuItem(title: "Add to Group", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for group in others {
                let entry = NSMenuItem(title: group.name, action: #selector(menuAddToGroup(_:)),
                                       keyEquivalent: "")
                entry.target = self
                entry.representedObject = TabAndGroup(tab: tabs[index], group: group.id)
                submenu.addItem(entry)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        guard current != nil else { return }
        menu.addItem(tabMenuItem("Remove from Group", #selector(menuRemoveFromGroup(_:)), index))
    }

    private func showGroupMenu(for id: Int, event: NSEvent) {
        guard let group = grouping.group(withID: id) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(groupMenuItem(group.isCollapsed ? "Expand Group" : "Collapse Group",
                                   #selector(menuToggleGroup(_:)), id))
        menu.addItem(.separator())
        menu.addItem(groupMenuItem("Rename Group…", #selector(menuRenameGroup(_:)), id))

        let colors = NSMenuItem(title: "Group Colour", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (name, colorIndex) in TabController.groupColors {
            let entry = NSMenuItem(title: name, action: #selector(menuSetGroupColor(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [id, colorIndex]
            entry.state = group.colorIndex == colorIndex ? .on : .off
            submenu.addItem(entry)
        }
        colors.submenu = submenu
        menu.addItem(colors)
        NSMenu.popUpContextMenu(menu, with: event, for: tabBar)
    }

    /// The six ANSI colours a group can be, by name. Indices into the theme's own palette rather
    /// than hex values, so a group looks like it belongs to whatever theme is in force.
    private static let groupColors: [(String, Int)] = [
        ("Red", 1), ("Green", 2), ("Yellow", 3), ("Blue", 4), ("Magenta", 5), ("Cyan", 6),
    ]

    private func groupMenuItem(_ title: String, _ action: Selector, _ id: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.isEnabled = true
        return item
    }

    /// Applies the move a grouping change asked for, so the tabs themselves end up in the order the
    /// model already believes they are in. Nothing else may reorder `tabs`.
    private func apply(_ move: TabMove?) {
        guard let move, tabs.indices.contains(move.from) else { return }
        let tab = tabs.remove(at: move.from)
        tabs.insert(tab, at: min(move.to, tabs.count))
        // The selection is an index, so it moves with whatever it was pointing at.
        if selected == move.from {
            selected = min(move.to, tabs.count - 1)
        } else if move.from < selected && move.to >= selected {
            selected -= 1
        } else if move.from > selected && move.to <= selected {
            selected += 1
        }
    }

    private func groupsChanged() {
        refreshTitles()
        refreshBar()
        sessionChanged()
    }

    @objc private func menuNewGroup(_ sender: Any?) {
        guard let index = tabIndex(from: sender), let window = view.window else { return }
        let tab = tabs[index]
        askForName(title: "New Group", initial: tab.title, in: window) { [weak self, weak tab] name in
            guard let self, let tab, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            let free = TabController.groupColors.map(\.1)
            let used = Set(self.grouping.groups.map(\.colorIndex))
            let color = free.first { !used.contains($0) } ?? free[self.grouping.groups.count % free.count]
            let made = self.grouping.newGroup(named: name, colorIndex: color, fromTabAt: index)
            self.apply(made?.move)
            self.groupsChanged()
        }
    }

    @objc private func menuAddToGroup(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? TabAndGroup,
              let index = tabs.firstIndex(where: { $0 === pair.tab }),
              grouping.group(withID: pair.group) != nil else { return }
        apply(grouping.add(tabAt: index, toGroup: pair.group))
        groupsChanged()
    }

    @objc private func menuRemoveFromGroup(_ sender: Any?) {
        guard let index = tabIndex(from: sender) else { return }
        apply(grouping.removeFromGroup(tabAt: index))
        groupsChanged()
    }

    @objc private func menuToggleGroup(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        toggleGroup(id)
    }

    private func toggleGroup(_ id: Int) {
        grouping.toggleCollapsed(group: id)
        // A collapsed group hides its tabs, and the selected one may be among them: move the
        // selection to something the user can still see rather than leaving it on a hidden tab.
        if let group = grouping.group(withID: id), group.isCollapsed,
           let range = grouping.range(ofGroup: id), range.contains(selected) {
            show(range.lowerBound)
        }
        groupsChanged()
    }

    @objc private func menuSetGroupColor(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Int], pair.count == 2 else { return }
        grouping.setColor(pair[1], forGroup: pair[0])
        groupsChanged()
    }

    @objc private func menuRenameGroup(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? Int,
              let group = grouping.group(withID: id), let window = view.window else { return }
        askForName(title: "Rename Group", initial: group.name, in: window) { [weak self] name in
            self?.grouping.rename(group: id, to: name)
            self?.groupsChanged()
        }
    }

    /// One name-entry sheet, shared by "New Group", "Rename Group" and "Rename Tab". A sheet rather
    /// than a modal alert, for the reason `confirmClose` gives: `runModal()` stops the run loop and
    /// with it every session in every other tab.
    private func askForName(title: String, initial: String, in window: NSWindow,
                            then apply: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        // An alert's accessory view is named by nothing at all: the message text is the alert's,
        // not the field's.
        field.describeForAccessibility(title, role: .textField)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            apply(name)
        }
        alert.window.initialFirstResponder = field
    }

    private func tabMenuItem(_ title: String, _ action: Selector, _ index: Int,
                             enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        // The tab itself, not its index. A context menu stays open while the shells behind it keep
        // running, and a tab that exits in that moment takes its slot out of the strip and shifts
        // every index after it: "Close Tab" on the middle of three closed the one to its right.
        item.representedObject = tabs[index]
        item.isEnabled = enabled
        return item
    }

    private func tabIndex(from sender: Any?) -> Int? {
        // A menu item from the tab's own context menu names its tab. Anything else -- a menu bar
        // item, a key binding, the palette -- means the tab you are looking at.
        if let item = sender as? NSMenuItem, let tab = item.representedObject as? Tab {
            // Where that tab is *now*. Gone while the menu was open means nothing happens, which is
            // the only safe answer: acting on whatever took its place is the bug this replaced.
            return tabs.firstIndex { $0 === tab }
        }
        return tabs.indices.contains(selected) ? selected : nil
    }

    @objc private func menuCloseTab(_ sender: Any?) {
        guard let index = tabIndex(from: sender) else { return }
        closeTabs(at: [index])
    }

    @objc private func menuCloseOtherTabs(_ sender: Any?) {
        guard let index = tabIndex(from: sender) else { return }
        closeTabs(at: TabClosing.others(than: index, tabCount: tabs.count))
    }

    @objc private func menuCloseTabsToTheRight(_ sender: Any?) {
        guard let index = tabIndex(from: sender) else { return }
        closeTabs(at: TabClosing.toTheRight(of: index, tabCount: tabs.count))
    }

    @objc private func menuDuplicateTab(_ sender: Any?) {
        guard let index = tabIndex(from: sender) else { return }
        addTab(inheriting: tabs[index].panes.inheritableWorkingDirectory())
    }

    @objc private func menuResetTabTitle(_ sender: Any?) {
        guard let index = tabIndex(from: sender) else { return }
        tabs[index].customTitle = nil
        refreshTitles()
        refreshBar()
        sessionChanged()
    }

    /// A sheet rather than a modal alert, for the same reason `confirmClose` uses one: `runModal()`
    /// stops the run loop, and with it every session in every other tab.
    @objc private func menuRenameTab(_ sender: Any?) {
        guard let index = tabIndex(from: sender), let window = view.window else { return }
        let tab = tabs[index]
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "The name stays until you reset it, whatever the shell sets."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.customTitle ?? tab.title
        field.describeForAccessibility("Tab name", role: .textField)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak tab] response in
            guard response == .alertFirstButtonReturn, let self, let tab else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.customTitle = name.isEmpty ? nil : name
            self.refreshTitles()
            self.refreshBar()
            self.sessionChanged()
        }
        alert.window.initialFirstResponder = field
    }

    // MARK: - The command palette
    //
    // The panel belongs to the window rather than to a pane: two of its three sources -- the themes
    // and the open tabs -- are things a pane knows nothing about, and every action it runs goes
    // through this controller's `ActionTarget` conformance anyway.

    private var paletteOverlay: CommandPaletteView?

    /// The list button on the bar: the same panel, showing only the open tabs. A window with
    /// thirty tabs is exactly when the bar stops being a way to find one.
    func showTabList() {
        closeCommandPalette()
        openPalette(items: tabs.enumerated().map { PaletteItem.tab($0.offset, title: $0.element.title) })
    }

    /// `⌘⇧P`. Pressing it again while the panel is up closes it, the way every palette behaves.
    func toggleCommandPalette() {
        if paletteOverlay != nil {
            closeCommandPalette()
            return
        }
        let bindings = KeyBindingTable(user: config.keybinds)
        let items = PaletteSource.items(actions: ActionCatalog.allMenuActions,
                                        chord: { bindings.binding(for: $0)?.displayName },
                                        quickActions: quickActions.map {
                                            ($0, QuickActionRunner.shared.isRunning($0))
                                        },
                                        themes: Themes.builtin.keys.sorted(),
                                        tabTitles: tabs.map(\.title))
        openPalette(items: items)
    }

    private func openPalette(items: [PaletteItem]) {
        let overlay = CommandPaletteView(palette: Pane.resolvedPalette(for: config), items: items)
        overlay.onRun = { [weak self] item in self?.run(item) }
        overlay.onClose = { [weak self] in self?.closeCommandPalette() }
        overlay.onHeightChange = { [weak self] _ in self?.layoutCommandPalette() }
        view.addSubview(overlay)
        paletteOverlay = overlay
        layoutCommandPalette()
        overlay.focusField()
    }

    func closeCommandPalette() {
        guard let overlay = paletteOverlay else { return }
        overlay.removeFromSuperview()
        paletteOverlay = nil
        // The window lost its first responder with the panel's field; give it back to the terminal.
        if tabs.indices.contains(selected) { tabs[selected].panes.restoreFocus() }
    }

    /// Runs a row. The panel closes first in every case: an action that opens a sheet, or one that
    /// closes this very pane, must not run underneath a panel that is still on screen.
    private func run(_ item: PaletteItem) {
        closeCommandPalette()
        switch item.kind {
        case .action(let action):
            guard canPerform(action) else {
                NSSound.beep()
                return
            }
            perform(action)
        case .theme(let name):
            if appDelegate?.write(setting: "theme", value: name) != true { NSSound.beep() }
        case .tab(let index):
            selectTab(at: index)
        case .quickAction(let index):
            performQuickAction(index)
        }
    }

    /// The quick actions are the user's own buttons; the runner owns what they do, including which
    /// background ones are alive.
    private func performQuickAction(_ index: Int) {
        // Resolved against the combined list *now* rather than against a copy taken when the bar
        // was drawn: a project's actions leave the list the moment its directory stops being the
        // current one, and an index into a stale list would run the wrong command.
        let actions = quickActions
        guard actions.indices.contains(index) else { return }
        QuickActionRunner.shared.perform(actions[index], in: self, pane: focusedPane)
    }

    /// Centred horizontally over the panes and pinned near the top, which is where every command
    /// palette on this platform puts itself.
    private func layoutCommandPalette() {
        guard let overlay = paletteOverlay else { return }
        let area = paneContainer.frame
        let width = min(CommandPaletteView.width, max(280, area.width - 40))
        let height = min(overlay.preferredHeight, max(80, area.height - 80))
        overlay.frame = NSRect(x: area.midX - width / 2,
                               y: area.maxY - height - min(60, area.height / 8),
                               width: width, height: height)
        overlay.needsLayout = true
    }

    // MARK: - A project's own actions
    //
    // **The approval is the security boundary.** Nothing from a `.nyx` file may run, appear as a
    // button, or reach the palette before the user has been shown the commands and approved that
    // directory -- cloning a repository must not be enough. `ProjectActionsState.runnableActions`
    // in NyxCore is the one place that decides, and `projectActions` below is the only thing that
    // reaches the bar or the palette.

    /// The directory the selected tab's focused pane is in, as last reported.
    private var projectDirectory: String?
    /// What that directory's `.nyx` file is allowed to do. `.none` until one is found.
    private var projectState: ProjectActionsState = .none
    /// Directories the user pressed Ignore for. Session-scoped on purpose: Ignore is "not now", and
    /// recording it in the approvals file would make it indistinguishable from a decision.
    private var ignoredProjectDirectories: Set<String> = []

    /// Every button the bar shows: the user's own, then the current project's -- and the project's
    /// only while its directory is current and approved.
    private var quickActions: [QuickAction] { config.quickActions + projectState.runnableActions }

    /// A pane announced a new working directory. Reads that directory's `.nyx` file, if any, and
    /// asks NyxCore what it is allowed to do.
    private func workingDirectoryChanged(_ directory: String) {
        guard directory != projectDirectory else { return }
        projectDirectory = directory
        refreshProjectActions()
    }

    private func refreshProjectActions() {
        guard let directory = projectDirectory else {
            projectState = .none
            projectActionsChanged()
            return
        }
        let contents = ProjectApprovalsStore.shared.projectFile(in: directory)
        projectState = ProjectActionsGate.state(directory: directory, fileContents: contents,
                                                approvals: ProjectApprovalsStore.shared.load())
        projectActionsChanged()
    }

    private func projectActionsChanged() {
        tabBar.setQuickActions(quickActions)
        refreshBar()
        let directory = projectDirectory ?? ""
        guard projectState.needsApproval, !ignoredProjectDirectories.contains(directory),
              let message = ProjectActionsGate.barMessage(for: projectState, directory: directory)
        else {
            projectBar.hide()
            return
        }
        if case .changed = projectState {
            projectBar.show(message: message, changed: true)
        } else {
            projectBar.show(message: message, changed: false)
        }
    }

    /// Shows the commands themselves and offers to approve them.
    ///
    /// The commands, not the names: a button called "Test" that runs `curl … | sh` is exactly what
    /// approval exists to stop, and the name is chosen by the same file as the command.
    private func reviewProjectActions() {
        guard let window = view.window, let directory = projectDirectory,
              let digest = projectState.digest, projectState.needsApproval else { return }
        let actions = projectState.actionsToShow
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run these actions from \(ProjectActionsGate.displayName(of: directory))?"
        alert.informativeText = "Approving adds them as buttons in this terminal. They come from a "
            + "file in that directory, so anyone who can write there chooses what they do. "
            + "Approval covers exactly this content: an edit, or a pull that brings one in, asks "
            + "you again.\n\n\(directory)"
        alert.accessoryView = TabController.reviewView(for: actions)
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard ProjectApprovalsStore.shared.approve(directory: directory, digest: digest) else {
                self.projectBar.show(message: "Could not record the approval; check "
                    + ProjectApprovalsStore.path.path, changed: true)
                return
            }
            // Re-read rather than trusting what was on screen: the file may have changed while the
            // sheet was up, and approving what the user saw is only honest if it is still there.
            self.refreshProjectActions()
        }
    }

    /// A scrollable list of what would run. Selectable, because the first thing anyone does with a
    /// command they distrust is copy it somewhere to look at properly.
    private static func reviewView(for actions: [QuickAction]) -> NSView {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
        text.string = ProjectActionsGate.reviewText(actions)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.describeForAccessibility("The commands this folder would run", role: .textArea)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        return scroll
    }

    /// "Not now": the bar goes for this directory until the app is restarted. Deliberately not
    /// written to the approvals file -- a refusal recorded there would be indistinguishable from a
    /// decision, and there would be no way to change your mind.
    private func ignoreProjectActions() {
        if let directory = projectDirectory { ignoredProjectDirectories.insert(directory) }
        projectBar.hide()
    }

    // MARK: - Saving the scrollback
    //
    // What gets written is `Transcript` in NyxCore: ANSI by default, so a saved session restores
    // through the parser that is already there and `less -R` shows it as it looked, and plain text
    // when the name says `.txt`. Which of the two, what the file is called, and what the panel says
    // about it are all decided there. What is here is the panel and the write.

    private func saveScrollback() {
        guard let window = view.window, let pane = focusedPane else { return }
        let title = tabs.indices.contains(selected) ? tabs[selected].title : ""
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Transcript.defaultFileName(title: title, date: Date())
        panel.canCreateDirectories = true
        // Unrestricted on purpose: the extension is the whole interface for choosing the format,
        // and a panel that refuses `.txt` would take that choice away.
        panel.allowedContentTypes = []
        panel.message = "Save this pane\u{2019}s scrollback."
        panel.accessoryView = TabController.formatNote(for: panel.nameFieldStringValue)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let text = pane.scrollbackTranscript(options: Transcript.options(forFileNamed: url.lastPathComponent))
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.reportSaveFailure(error, in: window)
            }
        }
    }

    /// The panel says which of the two forms the name it is showing will produce, so the choice is
    /// visible before the file exists rather than discovered afterwards in `less`.
    private static func formatNote(for name: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: Transcript.formatDescription(forFileNamed: name))
        label.describeForAccessibility("File format", role: .staticText)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 44))
        label.frame = NSRect(x: 16, y: 6, width: 388, height: 32)
        container.addSubview(label)
        return container
    }

    /// A failed write is worth saying out loud: the user asked for a file and there is none.
    private func reportSaveFailure(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Could not save the scrollback."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
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
        // A new `quick` line gets its button here, without a restart.
        tabBar.setQuickActions(quickActions)
        refreshBar()
    }

    /// The theme follows the system appearance whenever `dark:`/`light:` are set, the same as the
    /// panes and the dividers. The bar reports the change rather than this controller observing it:
    /// `viewDidChangeEffectiveAppearance` belongs to `NSView`, not to `NSViewController`.
    private func appearanceChanged() {
        guard config.darkThemeName != nil || config.lightThemeName != nil else { return }
        tabBar.setColors(palette: Pane.resolvedPalette(for: config))
    }

    // MARK: - Editing the buttons

    /// The sheet for adding a button, or editing the one at `index`.
    private func editQuickAction(at index: Int?) {
        let existing = index.flatMap { config.quickActions.indices.contains($0) ? config.quickActions[$0] : nil }
        let editor = QuickActionEditor(editing: existing)
        editor.onFinish = { [weak self] action in
            self?.dismiss(editor)
            guard let self, let action else { return }
            var actions = self.config.quickActions
            if let index, actions.indices.contains(index) {
                actions[index] = action
            } else {
                actions.append(action)
            }
            (NSApp.delegate as? AppDelegate)?.setQuickActions(actions)
        }
        presentAsSheet(editor)
    }

    private func showQuickActionMenu(_ index: Int, _ event: NSEvent) {
        guard config.quickActions.indices.contains(index) else { return }
        let action = config.quickActions[index]
        let menu = NSMenu()
        // The command itself, greyed, so pressing a button is never a guess about what it runs.
        let header = NSMenuItem(title: action.command, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item("Edit…", #selector(menuEditQuickAction(_:)), index))
        menu.addItem(item("Duplicate", #selector(menuDuplicateQuickAction(_:)), index))
        if index > 0 { menu.addItem(item("Move Left", #selector(menuMoveQuickActionLeft(_:)), index)) }
        if index < config.quickActions.count - 1 {
            menu.addItem(item("Move Right", #selector(menuMoveQuickActionRight(_:)), index))
        }
        menu.addItem(.separator())
        menu.addItem(item("Remove", #selector(menuRemoveQuickAction(_:)), index))
        NSMenu.popUpContextMenu(menu, with: event, for: tabBar)
    }

    private func item(_ title: String, _ action: Selector, _ index: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = index
        return item
    }

    private func mutateQuickActions(_ change: (inout [QuickAction]) -> Void) {
        var actions = config.quickActions
        change(&actions)
        (NSApp.delegate as? AppDelegate)?.setQuickActions(actions)
    }

    @objc private func menuEditQuickAction(_ sender: NSMenuItem) { editQuickAction(at: sender.tag) }

    @objc private func menuDuplicateQuickAction(_ sender: NSMenuItem) {
        mutateQuickActions { actions in
            guard actions.indices.contains(sender.tag) else { return }
            let original = actions[sender.tag]
            actions.insert(QuickAction(name: original.name + " copy", kind: original.kind,
                                       command: original.command), at: sender.tag + 1)
        }
    }

    @objc private func menuRemoveQuickAction(_ sender: NSMenuItem) {
        mutateQuickActions { actions in
            guard actions.indices.contains(sender.tag) else { return }
            actions.remove(at: sender.tag)
        }
    }

    @objc private func menuMoveQuickActionLeft(_ sender: NSMenuItem) { moveQuickAction(sender.tag, by: -1) }
    @objc private func menuMoveQuickActionRight(_ sender: NSMenuItem) { moveQuickAction(sender.tag, by: 1) }

    private func moveQuickAction(_ index: Int, by offset: Int) {
        mutateQuickActions { actions in
            let target = index + offset
            guard actions.indices.contains(index), actions.indices.contains(target) else { return }
            actions.swapAt(index, target)
        }
    }

    // MARK: - Searching every tab

    /// Hits from the last search over every pane, and where we are in them.
    private var globalHits: [GlobalSearchHit] = []
    private var globalIndex = 0
    private var globalQuery = ""
    /// The pane whose search bar is on screen, so a cross-tab jump can take it along.
    private weak var searchingPane: Pane?

    /// Runs `query` over every pane in every tab and returns the readout for the search bar.
    ///
    /// A per-pane search cannot answer the question people actually have once more than one tab is
    /// open -- which of them had that error in it -- because answering it means visiting each tab
    /// and asking again.
    func runGlobalSearch(query: String) -> String {
        globalQuery = query
        globalIndex = 0
        guard !query.isEmpty else {
            globalHits = []
            return ""
        }
        let scopes = searchScopes()
        globalHits = GlobalSearch.run(query: query, scopes: scopes) { scope, work in
            self.pane(withID: scope.paneID)?.withTerminalForSearch(work) ?? []
        }
        guard !globalHits.isEmpty else { return "no matches" }
        let panes = GlobalSearch.paneCount(globalHits)
        let where_ = panes == 1 ? "1 pane" : "\(panes) panes"
        return "\(globalHits.count) in \(where_)"
    }

    /// Moves to the next or previous hit, switching tabs and focusing panes as it goes, and hands
    /// back the readout. nil when there is nothing to step through.
    func stepGlobalSearch(forward: Bool) -> String? {
        guard !globalHits.isEmpty else { return nil }
        // The bar belongs to the pane it was opened in, and switching tabs takes that pane off
        // screen -- so after one cross-tab jump the bar was gone, its pane was no longer in the
        // responder chain, and every further ⏎ did nothing. The bar moves to the pane the hit is
        // in, which is also where a person is now looking.
        defer { moveSearchBarToFocusedPane() }
        globalIndex = (globalIndex + (forward ? 1 : -1) + globalHits.count) % globalHits.count
        let hit = globalHits[globalIndex]

        if let tab = tabs.indices.first(where: { tabs[$0].panes.contains(paneID: hit.scope.paneID) }),
           tab != selected {
            selectTab(at: tab)
        }
        guard let pane = self.pane(withID: hit.scope.paneID) else { return nil }
        pane.focusFromSearch()
        pane.reveal(match: hit.match, query: globalQuery)
        return "\(globalIndex + 1) of \(globalHits.count) — \(hit.scope.title)"
    }

    /// Carries an open search bar to whichever pane now has focus, with its query and scope intact.
    private func moveSearchBarToFocusedPane() {
        guard let source = searchingPane, let destination = focusedPane, source !== destination else { return }
        let query = source.searchQuery
        source.closeSearchForHandover()
        destination.openSearch(query: query, allTabs: true)
        searchingPane = destination
    }

    /// Dropped when the search bar closes or its scope goes back to one pane, so a stale set of
    /// hits cannot send the next ⌘G to a tab nobody is searching any more.
    func endGlobalSearch() {
        searchingPane = nil
        globalHits = []
        globalQuery = ""
        globalIndex = 0
    }

    private func searchScopes() -> [SearchScope] {
        tabs.enumerated().flatMap { index, tab in
            tab.panes.allPanes.map { pane in
                SearchScope(paneID: pane.id.value, tabIndex: index, title: tab.title)
            }
        }
    }

    private func pane(withID id: Int) -> Pane? {
        for tab in tabs {
            if let pane = tab.panes.allPanes.first(where: { $0.id.value == id }) { return pane }
        }
        return nil
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
        case .editAndRunCommand: if focusedPane?.editAndRunLastCommand() != true { NSSound.beep() }
        case .pasteWithEditor: if focusedPane?.pasteWithEditor() != true { NSSound.beep() }

        // The group and rename commands existed only on a tab's context menu, which is a mouse and
        // nothing else. They are actions like everything else now, so they reach the menu bar, the
        // palette and `keybind =`.
        case .renameTab: menuRenameTab(nil)
        case .groupTab: menuNewGroup(nil)
        case .ungroupTab: menuRemoveFromGroup(nil)
        case .toggleTabGroup:
            guard let index = tabIndex(from: nil), let group = grouping.group(ofTabAt: index) else {
                NSSound.beep()
                return
            }
            toggleGroup(group.id)
        case .find:
            focusedPane?.openSearch()
            searchingPane = focusedPane
        case .findNext: if focusedPane?.stepSearch(forward: true) != true { NSSound.beep() }
        case .findPrevious: if focusedPane?.stepSearch(forward: false) != true { NSSound.beep() }
        case .commandPalette: toggleCommandPalette()
        case .foldCommand: if focusedPane?.toggleFoldOfCurrentCommand() != true { NSSound.beep() }
        case .foldAllLongOutput: if focusedPane?.foldAllLongOutput() != true { NSSound.beep() }
        case .saveScrollback: saveScrollback()

        case .copy: focusedPane?.copy(nil)
        case .paste:
            // An image or an empty clipboard has nothing to paste. The menu item is greyed out for
            // it, but a key binding reaches this directly, and silently doing nothing reads as a
            // broken ⌘V rather than as an empty clipboard.
            if TabController.clipboardHasText { focusedPane?.paste(nil) } else { NSSound.beep() }
        case .clearScreen: focusedPane?.clearScreen()
        case .fontBigger: focusedPane?.zoomIn(nil)
        case .fontSmaller: focusedPane?.zoomOut(nil)
        case .fontReset: focusedPane?.zoomReset(nil)
        }
    }

    /// Whether there is text to paste. Copying an image out of Preview leaves the pasteboard full
    /// and `string(forType:)` empty, which is the case that made Paste look broken.
    private static var clipboardHasText: Bool {
        NSPasteboard.general.string(forType: .string)?.isEmpty == false
    }

    func canPerform(_ action: TerminalAction) -> Bool {
        switch action {
        case .paste, .pasteWithEditor:
            return focusedPane != nil && TabController.clipboardHasText
        case .newWindow, .openConfig, .reloadConfig, .newTab:
            return true
        case .nextTab, .previousTab:
            return tabs.count > 1
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            guard let number = TabStrip.commandNumber(for: action) else { return false }
            return TabStrip.index(forCommandNumber: number, tabCount: tabs.count) != nil
        case .renameTab, .groupTab:
            return tabs.indices.contains(selected)
        case .ungroupTab, .toggleTabGroup:
            // Meaningless unless the tab you are on is in a group. Greyed out says that; beeping
            // when pressed does not, and silently doing nothing is worse than either.
            return tabs.indices.contains(selected) && grouping.group(ofTabAt: selected) != nil
        case .copy:
            return focusedPane?.hasSelection ?? false
        case .saveScrollback:
            return focusedPane?.hasScrollback ?? false
        case .findNext, .findPrevious:
            // Nothing to step through until ⌘F has been pressed and something typed.
            return focusedPane?.isSearching ?? false
        case .previousPrompt, .nextPrompt, .selectCommandOutput, .copyCommandOutput,
             .foldCommand, .foldAllLongOutput:
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
