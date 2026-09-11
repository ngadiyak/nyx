import AppKit
import NyxCore

/// One tab, as much of it as the bar needs to draw.
struct TabBarItem {
    var title: String
    var indicator: TabIndicator
    /// A chip after the title: "observer"/"writer" on a tab attached to another Mac's session. nil
    /// on every ordinary tab, which is all of them until one is opened from the palette's Remote
    /// section. Drawn like a group's name chip, because it means the same kind of thing -- what
    /// sort of tab this is, as opposed to which one.
    var label: String?

    init(title: String, indicator: TabIndicator, label: String? = nil) {
        self.title = title
        self.indicator = indicator
        self.label = label
    }
}

/// The strip of tabs above the panes: a single view that draws every tab itself.
///
/// There are no subviews and no tracking areas. A tab is a rectangle, its close button is a smaller
/// rectangle inside it, and a click is answered by working out which one it landed in -- the same
/// arrangement `PaneTreeView` uses for dividers, and for the same reason: a handful of rects is
/// less machinery than a view per tab, and the bar redraws only when something about a tab changes.
///
/// Everything that has to be *decided* rather than drawn -- whether the bar is on screen at all,
/// which tab a shortcut means, how a title shortens, where a group's header sits and what a click
/// at a point means -- is in `TabStrip`/`TabTitle`/`TabBarGeometry` in `NyxCore`.
final class TabBarView: NSView {
    /// The bar's height with no groups in it. A bar with an expanded group is taller by a header
    /// row; `preferredHeight` is the one to ask.
    static let height: CGFloat = 28

    /// Sizes and the arithmetic over them live in `TabBarGeometry`, where they are tested; this
    /// view converts what it returns into `NSRect` and draws it.
    private static let metrics = TabBarMetrics.standard

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// A right-click landed on a tab. The controller builds the menu, because every item on it is
    /// something only the controller can do.
    var onContextMenu: ((Int, NSEvent) -> Void)?
    /// A click on a collapsed group's chip, or on an expanded group's header.
    var onToggleGroup: ((Int) -> Void)?
    /// A right-click on either of those.
    var onGroupContextMenu: ((Int, NSEvent) -> Void)?
    /// The `+` at the far left.
    var onNewTab: (() -> Void)?
    /// The list button beside it: the command palette, showing only the open tabs.
    var onShowTabList: (() -> Void)?
    /// One of the configured quick actions, by its index in `config.quickActions`.
    var onQuickAction: ((Int) -> Void)?
    /// The trailing `+`.
    var onAddQuickAction: (() -> Void)?
    /// Right-click on a quick-action chip: its index and the event, for a menu.
    var onQuickActionContextMenu: ((Int, NSEvent) -> Void)?
    /// A right-click on the bar itself -- the `≡` at the leading edge, the `+` after the last tab,
    /// or the empty stretch between them. All three used to do nothing at all, which is the wrong
    /// answer three times: the tab bar is where a person looks for the kinds of new tab there are.
    var onBarContextMenu: ((NSEvent) -> Void)?
    /// The system switched between light and dark; the controller decides whether the theme cares.
    var onAppearanceChange: (() -> Void)?

    private var items: [TabBarItem] = []
    private var selected = 0
    private var grouping = TabGrouping()
    private var slots: [TabBarGeometry.Slot] = []
    private var quickActions: [QuickAction] = []
    /// What each leading button does, in the order they are laid out. Parallel to the widths handed
    /// to `TabBarGeometry`, so a `.leadingButton(i)` hit indexes straight into it.
    private var leadingButtons: [LeadingButton] = []
    private var leadingWidths: [Double] = []
    private var runningObserver: NSObjectProtocol?

    private var palette = Palette.xtermDefault()
    private var barBackground: NSColor = .clear
    private var selectedBackground: NSColor = .clear
    private var textColor: NSColor = .clear
    private var dimTextColor: NSColor = .clear
    private var separatorColor: NSColor = .clear
    private var accentColor: NSColor = .clear

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// How tall the bar needs to be for what it is showing: its base, plus a row for group names
    /// whenever a group is expanded. A collapsed group names itself on its chip.
    var preferredHeight: CGFloat {
        CGFloat(TabBarGeometry.barHeight(base: Double(TabBarView.height), grouping: grouping,
                                         metrics: TabBarView.metrics))
    }

    /// Nothing when no group is expanded, so an ungrouped window keeps the bar it always had.
    private var headerHeight: CGFloat {
        preferredHeight - TabBarView.height
    }

    func setTabs(_ items: [TabBarItem], selected: Int, grouping: TabGrouping) {
        self.items = items
        self.selected = selected
        self.grouping = grouping
        self.slots = TabBarGeometry.slots(tabCount: items.count, grouping: grouping)
        needsDisplay = true
    }

    /// The quick actions from the config. A new `quick` line therefore adds its button on the next
    /// reload, with no restart -- `TabController.apply` calls this.
    func setQuickActions(_ actions: [QuickAction]) {
        quickActions = actions
        rebuildLeadingButtons()
        needsDisplay = true
    }

    /// What each leading button is. The order is fixed: the two built-ins first, so a user's muscle
    /// memory for `+` does not move when they add a quick action.
    private enum LeadingButton: Equatable {
        case newTab
        case tabList
        case quick(Int)
        /// Adds a quick action. Always present, including when there are none: with no buttons and
        /// no `+`, the feature has no entry point at all and can only be found by reading the
        /// config file, which is exactly the problem it exists to solve.
        case addQuickAction
        /// The buttons this bar is too narrow to show. Appears only when there are some, and is
        /// pinned beside the `+`: a configured button that is simply not there, with nothing
        /// saying so, reads as a button that stopped working.
        case overflow
    }

    private static let builtInButtonWidth: Double = 26
    private static let quickActionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private func rebuildLeadingButtons() {
        leadingButtons = [.tabList] + quickActions.indices.map { .quick($0) } + [.addQuickAction]
        leadingWidths = leadingButtons.map { button in
            switch button {
            case .newTab, .tabList, .addQuickAction, .overflow:
                return TabBarView.builtInButtonWidth
            case .quick(let index):
                let name = quickActions[index].name as NSString
                let text = Double(name.size(withAttributes: [.font: TabBarView.quickActionFont]).width)
                // Room either side, plus a dot for a toggle that is running.
                return min(140, text + 20)
            }
        }
    }

    /// The bar as it is actually laid out: which buttons, how wide, and how many of them are
    /// pinned. Everything that draws, hit-tests or measures the leading buttons goes through this,
    /// so a click always lands on the button that was drawn there.
    ///
    /// Two passes, because whether the overflow chip is needed depends on the layout and the
    /// layout depends on the chip. The first pass pins the `+`; if it dropped anything, the second
    /// makes room for a chip beside it and pins both.
    private var resolvedLeading: (buttons: [LeadingButton], widths: [Double], pinnedTail: Int) {
        let first = layout(widths: leadingWidths, pinnedTail: 1)
        guard first.count < leadingButtons.count else {
            return (leadingButtons, leadingWidths, 1)
        }
        var buttons = leadingButtons
        var widths = leadingWidths
        buttons.insert(.overflow, at: buttons.count - 1)
        widths.insert(TabBarView.builtInButtonWidth, at: widths.count - 1)
        return (buttons, widths, 2)
    }

    private func layout(widths: [Double], pinnedTail: Int) -> [(index: Int, rect: PaneRect)] {
        TabBarGeometry.leadingLayout(buttonWidths: widths, barWidth: Double(bounds.width),
                                     barHeight: Double(bounds.height), slotCount: slots.count,
                                     headerHeight: Double(headerHeight), pinnedTail: pinnedTail,
                                     metrics: TabBarView.metrics)
    }

    /// The buttons that actually fit, each with the button it belongs to. `TabBarGeometry` drops
    /// the overflow rather than squeezing the tabs, so this is shorter than `leadingButtons` on a
    /// narrow bar with many tabs -- and the tail is pinned, so what gets dropped is a quick action,
    /// never the control that adds one nor the chip that reaches the dropped ones.
    private var fittedLeading: [(button: LeadingButton, rect: NSRect)] {
        let resolved = resolvedLeading
        return layout(widths: resolved.widths, pinnedTail: resolved.pinnedTail)
            .compactMap { laid in
                guard resolved.buttons.indices.contains(laid.index) else { return nil }
                return (resolved.buttons[laid.index], ns(laid.rect))
            }
    }

    /// The quick actions the bar could not show, by their index in the configured list.
    private var hiddenQuickActions: [Int] {
        var shown: Set<Int> = []
        for (button, _) in fittedLeading {
            if case .quick(let index) = button { shown.insert(index) }
        }
        return quickActions.indices.filter { !shown.contains($0) }
    }

    /// The `+` sits after the last tab, where every browser and every other tabbed application
    /// puts it, and where the eye already is once a tab has just been opened.
    private var trailingRect: NSRect? {
        TabBarGeometry.trailingRect(buttonWidth: TabBarView.builtInButtonWidth,
                                    barWidth: Double(bounds.width), barHeight: Double(bounds.height),
                                    slotCount: slots.count, leading: leadingWidth,
                                    headerHeight: Double(headerHeight), metrics: TabBarView.metrics)
            .map(ns)
    }

    private var leadingWidth: Double {
        let resolved = resolvedLeading
        return TabBarGeometry.leadingWidth(buttonWidths: resolved.widths, barWidth: Double(bounds.width),
                                           barHeight: Double(bounds.height), slotCount: slots.count,
                                           headerHeight: Double(headerHeight),
                                           pinnedTail: resolved.pinnedTail,
                                           metrics: TabBarView.metrics)
    }

    /// The bar is drawn in the terminal's own palette, so it belongs to the theme rather than to
    /// the system appearance.
    func setColors(palette: Palette) {
        self.palette = palette
        barBackground = nsColor(mix(palette.background, palette.foreground, 0.10), alpha: 1)
        selectedBackground = nsColor(palette.background, alpha: 1)
        textColor = nsColor(palette.foreground, alpha: 0.95)
        // 0.68, not 0.55. At 0.55 an unselected tab title was 2.46:1 against the bar in Solarized
        // and 2.64:1 in nyx-light -- a title you have to lean in to read, on the control whose
        // whole job is to be scanned. At 0.68 no theme falls under 3:1 and the selected tab, at
        // full strength and a heavier weight, still reads as the selected one.
        dimTextColor = nsColor(palette.foreground, alpha: 0.68)
        separatorColor = nsColor(palette.foreground, alpha: 0.15)
        // `palette.accent`, not `palette.cursor`. Four of the seven built-in themes make their
        // cursor the foreground colour, which turned every accent in the bar -- the activity dot,
        // the bell, a running toggle's fill -- into a shade of grey.
        accentColor = nsColor(palette.accent, alpha: 0.9)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard runningObserver == nil else { return }
        // A toggle can stop on its own -- the process exits, or fails to start -- and the runner
        // says so here. Without this the button would keep claiming it is on.
        runningObserver = NotificationCenter.default.addObserver(
            forName: QuickActionRunner.stateChanged, object: nil, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
    }

    deinit {
        if let runningObserver { NotificationCenter.default.removeObserver(runningObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    // MARK: - Geometry

    private func ns(_ r: PaneRect) -> NSRect {
        NSRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    private func rect(forSlot index: Int) -> NSRect {
        ns(TabBarGeometry.slotRect(index: index, slotCount: slots.count, barWidth: bounds.width,
                                   barHeight: bounds.height, headerHeight: Double(headerHeight),
                                   leading: leadingWidth, trailing: TabBarView.builtInButtonWidth,
                                   metrics: TabBarView.metrics))
    }

    /// nil when the tab is too narrow to carry a close button, in which case none is drawn.
    private func closeRect(in tab: NSRect) -> NSRect? {
        TabBarGeometry.closeRect(in: pane(tab), metrics: TabBarView.metrics).map(ns)
    }

    private func indicatorRect(in tab: NSRect) -> NSRect {
        ns(TabBarGeometry.indicatorRect(in: pane(tab), metrics: TabBarView.metrics))
    }

    private func titleRect(in tab: NSRect, hasIndicator: Bool, badge: NSRect? = nil) -> NSRect {
        ns(TabBarGeometry.titleRect(in: pane(tab), hasIndicator: hasIndicator,
                                    badge: badge.map(pane), metrics: TabBarView.metrics))
    }

    private func pane(_ r: NSRect) -> PaneRect {
        PaneRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    private func hit(at point: NSPoint) -> TabBarGeometry.Hit? {
        let resolved = resolvedLeading
        return TabBarGeometry.hit(atX: Double(point.x), y: Double(point.y), slots: slots,
                                  barWidth: Double(bounds.width), barHeight: Double(bounds.height),
                                  headerHeight: Double(headerHeight),
                                  trailingWidth: TabBarView.builtInButtonWidth,
                                  leadingWidths: resolved.widths,
                                  pinnedLeadingTail: resolved.pinnedTail,
                                  metrics: TabBarView.metrics)
    }

    /// A group's colour, as the palette holds it. The bright variant where that reads better on the
    /// bar -- gruvbox's red is 2.7:1 against its own background and its bright red is 4.3:1, and a
    /// group band is a thin tint of this colour before anything else happens to it.
    private func rgb(ofGroup id: Int) -> RGB {
        guard let group = grouping.group(withID: id),
              (0..<16).contains(group.colorIndex) else { return palette.accent }
        return palette.readable(group.colorIndex)
    }

    private func color(ofGroup id: Int) -> NSColor {
        nsColor(rgb(ofGroup: id), alpha: 1)
    }

    // MARK: - Clicks

    /// Names for the bar's controls, which were bare glyphs with nothing to say for themselves.
    ///
    /// With no quick actions configured the bar was two unlabelled symbols, one of which is the
    /// only way into the quick-action feature at all. A glyph nobody can name is a glyph nobody
    /// presses.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        toolTip = label(at: point)
        if label(at: point) != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        toolTip = nil
        NSCursor.arrow.set()
    }

    /// What the thing under the pointer is called, or nil where there is nothing to name. The
    /// words themselves are `TabBarLabels` in NyxCore, shared with the accessibility labels below
    /// -- a control that says one thing to a pointer and another to a screen reader is a control
    /// with two different names.
    private func label(at point: NSPoint) -> String? {
        switch hit(at: point) {
        case .newTab:
            return TabBarLabels.newTab
        case .close(let index):
            return TabBarLabels.close(tabTitled: items.indices.contains(index) ? items[index].title : nil)
        case .select(let index):
            return items.indices.contains(index) ? items[index].title : nil
        case .expandGroup(let id), .groupHeader(let id):
            guard let group = grouping.group(withID: id) else { return nil }
            return TabBarLabels.group(named: group.name, isCollapsed: group.isCollapsed)
        case .leadingButton(let index):
            let buttons = resolvedLeading.buttons
            guard buttons.indices.contains(index) else { return nil }
            switch buttons[index] {
            case .tabList: return TabBarLabels.tabList
            case .addQuickAction: return TabBarLabels.addQuickAction
            case .quick(let action):
                guard quickActions.indices.contains(action) else { return nil }
                return quickActionLabel(action, forAccessibility: false)
            case .overflow: return TabBarLabels.moreQuickActions(count: hiddenQuickActions.count)
            case .newTab: return TabBarLabels.newTab
            }
        case nil:
            return nil
        }
    }

    private func quickActionLabel(_ index: Int, forAccessibility: Bool) -> String {
        let quick = quickActions[index]
        let running = quick.kind == .toggle && QuickActionRunner.shared.isRunning(quick)
        return forAccessibility
            ? TabBarLabels.quickActionState(named: quick.name, kind: quick.kind,
                                            command: quick.command, isRunning: running)
            : TabBarLabels.quickAction(named: quick.name, kind: quick.kind,
                                       command: quick.command, isRunning: running)
    }

    // MARK: - Accessibility
    //
    // The bar has no subviews, so there is nothing for AppKit to describe on its own: without this
    // VoiceOver found one unlabelled group and could not reach a single tab, close button or quick
    // action. Every rectangle the bar draws and hit-tests becomes an element that carries the same
    // name the tooltip does and performs the same press a click does.
    //
    // Built on demand rather than cached: the elements are frames over state that changes with
    // every tab opened, every group collapsed and every resize, and a stale frame points VoiceOver
    // at a control that is no longer there.

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }

    override func accessibilityLabel() -> String? { TabBarLabels.bar }

    override func accessibilityChildren() -> [Any]? {
        var children: [NSAccessibilityElement] = []

        for (button, frame) in fittedLeading {
            switch button {
            case .newTab:
                children.append(element(TabBarLabels.newTab, .button, frame) { [weak self] in
                    self?.onNewTab?()
                })
            case .tabList:
                children.append(element(TabBarLabels.tabList, .button, frame) { [weak self] in
                    self?.onShowTabList?()
                })
            case .addQuickAction:
                children.append(element(TabBarLabels.addQuickAction, .button, frame) { [weak self] in
                    self?.onAddQuickAction?()
                })
            case .overflow:
                let label = TabBarLabels.moreQuickActions(count: hiddenQuickActions.count)
                children.append(element(label, .button, frame) { [weak self] in
                    self?.showOverflowMenu()
                })
            case .quick(let action):
                guard quickActions.indices.contains(action) else { continue }
                children.append(element(quickActionLabel(action, forAccessibility: true), .button,
                                        frame) { [weak self] in self?.onQuickAction?(action) })
            }
        }

        for (position, slot) in slots.enumerated() {
            let frame = rect(forSlot: position)
            switch slot {
            case .tab(let index, _):
                guard items.indices.contains(index) else { continue }
                let item = items[index]
                // A radio button, which is what a tab is: one of a set, exactly one of which is
                // on. The value is what carries "this is the one you are looking at".
                children.append(element(TabBarLabels.tab(titled: item.title, position: index + 1,
                                                         of: items.count, indicator: item.indicator,
                                                         badge: item.label),
                                        .radioButton, frame, value: index == selected ? 1 : 0) {
                    [weak self] in self?.onSelect?(index)
                })
                if let close = closeRect(in: frame) {
                    children.append(element(TabBarLabels.close(tabTitled: item.title), .button,
                                            close) { [weak self] in self?.onClose?(index) })
                }
            case .collapsedGroup(let id, let count):
                guard let group = grouping.group(withID: id) else { continue }
                children.append(element(TabBarLabels.collapsedGroup(named: group.name, tabCount: count),
                                        .button, frame) { [weak self] in self?.onToggleGroup?(id) })
            case .groupLabel(let id):
                guard let group = grouping.group(withID: id) else { continue }
                children.append(element(TabBarLabels.expandedGroup(named: group.name), .button,
                                        frame) { [weak self] in self?.onToggleGroup?(id) })
            }
        }

        if let trailing = trailingRect {
            children.append(element(TabBarLabels.newTab, .button, trailing) { [weak self] in
                self?.onNewTab?()
            })
        }
        return children
    }

    private func element(_ label: String, _ role: NSAccessibility.Role, _ frame: NSRect,
                         value: Any? = nil, press: @escaping () -> Void) -> NSAccessibilityElement {
        DrawnControlElement.make(label: label, role: role, frame: frame, in: self, value: value,
                                 press: press)
    }

    override func mouseDown(with event: NSEvent) {
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .close(let index): onClose?(index)
        case .select(let index): onSelect?(index)
        case .expandGroup(let id), .groupHeader(let id): onToggleGroup?(id)
        case .leadingButton(let index): pressLeadingButton(index)
        case .newTab: onNewTab?()
        case nil: break
        }
    }

    private func pressLeadingButton(_ index: Int) {
        let buttons = resolvedLeading.buttons
        guard buttons.indices.contains(index) else { return }
        switch buttons[index] {
        case .newTab: onNewTab?()
        case .tabList: onShowTabList?()
        case .quick(let action): onQuickAction?(action)
        case .addQuickAction: onAddQuickAction?()
        case .overflow: showOverflowMenu()
        }
    }

    /// The buttons that did not fit, as a menu. Same commands, same right-click menu on each entry
    /// as the chips have; the bar being narrow changes where they are, not what they do.
    private func showOverflowMenu() {
        let hidden = hiddenQuickActions
        guard !hidden.isEmpty, let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        for index in hidden {
            let action = quickActions[index]
            let item = NSMenuItem(title: action.name, action: #selector(pressHiddenQuickAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.toolTip = action.command
            item.tag = index
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func pressHiddenQuickAction(_ sender: NSMenuItem) {
        onQuickAction?(sender.tag)
    }

    /// A right-click anywhere on a tab -- its close button included, where a context menu is more
    /// useful than a second way to close it.
    override func rightMouseDown(with event: NSEvent) {
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .close(let index), .select(let index): onContextMenu?(index, event)
        case .expandGroup(let id), .groupHeader(let id): onGroupContextMenu?(id, event)
        case .leadingButton(let index):
            let buttons = resolvedLeading.buttons
            switch buttons.indices.contains(index) ? buttons[index] : nil {
            case .quick(let action)?:
                onQuickActionContextMenu?(action, event)
            // The `≡`, which is the bar's own control rather than any tab's: a right-click on it is
            // a right-click on the bar. `.addQuickAction` -- the dashed `+` drawn beside it -- and
            // `.overflow` keep their silence: the first has a sheet of its own and the second is
            // already a menu, and neither is about opening a tab. `.newTab` is listed for
            // completeness only; `rebuildLeadingButtons` never lays one out, and the `+` a user
            // right-clicks is the one after the last tab, which arrives as `Hit.newTab` below.
            case .newTab?, .tabList?:
                onBarContextMenu?(event)
            default:
                break
            }
        case .newTab, nil:
            onBarContextMenu?(event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        barBackground.setFill()
        dirtyRect.fill()
        // The bands go down first, behind everything: a group is a place its tabs sit in.
        drawGroupBands(dirtyRect)
        for (position, slot) in slots.enumerated() {
            let frame = rect(forSlot: position)
            guard frame.intersects(dirtyRect) else { continue }
            switch slot {
            case .tab(let index, _):
                guard items.indices.contains(index) else { continue }
                draw(items[index], in: frame, isSelected: index == selected)
            case .collapsedGroup(let id, let count):
                drawChip(groupID: id, tabCount: count, in: frame)
            case .groupLabel(let id):
                drawGroupLabel(id, in: frame)
            }
        }
        drawLeadingButtons(dirtyRect)
        // The line under the whole bar, so the panes below it do not float.
        separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// The `+`, the tab-list button, and one per quick action. Only the ones that fit are drawn --
    /// `TabBarGeometry` has already dropped the rest.
    private func drawLeadingButtons(_ dirtyRect: NSRect) {
        for (button, frame) in fittedLeading {
            guard frame.intersects(dirtyRect) else { continue }
            switch button {
            case .newTab: drawSymbol("plus", fallback: "+", in: frame)
            case .tabList: drawSymbol("list.bullet", fallback: "\u{2261}", in: frame)
            case .quick(let action): drawQuickActionButton(action, in: frame)
            case .addQuickAction: drawAddQuickActionButton(in: frame)
            case .overflow: drawOverflowButton(in: frame)
            }
        }
        if let trailing = trailingRect { drawPlus(in: trailing) }
        guard let last = fittedLeading.last?.rect else { return }
        separatorColor.setFill()
        NSRect(x: last.maxX - 1, y: last.minY + 4, width: 1, height: last.height - 8).fill()
    }

    private func drawSymbol(_ name: String, fallback: String, in frame: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: dimTextColor))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(configuration) else {
            drawLabel(fallback, in: frame, color: dimTextColor,
                      font: .systemFont(ofSize: 13, weight: .medium), centred: true)
            return
        }
        let size = image.size
        image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    /// Text drawn on top of a fill taken from the palette -- a running toggle's chip, a group's
    /// name pill. Whichever of the theme's two neutrals reads on that particular fill: assuming the
    /// background always does put dark text on gruvbox's dark red at 2.7:1.
    private func textColor(on fill: RGB) -> NSColor {
        nsColor(palette.textOn(fill), alpha: 1)
    }

    /// Drawn as an empty chip with a `+` in it, not as another plain plus.
    ///
    /// There is already a `+` at the far left for a new tab; a second identical one a few pixels
    /// away is a coin toss. Shaped like the buttons it makes, it reads as "add one of these".
    /// The chip that stands for the buttons there was no room for. A count rather than an
    /// ellipsis: "2" says how much is missing, which is the question a missing button raises.
    private func drawOverflowButton(in frame: NSRect) {
        let hidden = hiddenQuickActions.count
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 5), xRadius: 5, yRadius: 5)
        dimTextColor.withAlphaComponent(0.35).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        drawLabel(hidden > 9 ? "9+" : "\(hidden)", in: frame, color: dimTextColor,
                  font: TabBarView.quickActionFont, centred: true)
    }

    private func drawAddQuickActionButton(in frame: NSRect) {
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 5), xRadius: 5, yRadius: 5)
        dimTextColor.withAlphaComponent(0.35).setStroke()
        pill.lineWidth = 1
        pill.setLineDash([3, 2.5], count: 2, phase: 0)
        pill.stroke()
        drawLabel("+", in: frame, color: dimTextColor,
                  font: .systemFont(ofSize: 12, weight: .medium), centred: true)
    }

    private func drawQuickActionButton(_ index: Int, in frame: NSRect) {
        guard quickActions.indices.contains(index) else { return }
        let action = quickActions[index]
        let running = action.kind == .toggle && QuickActionRunner.shared.isRunning(action)
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 5), xRadius: 5, yRadius: 5)

        // A button drawn as bare text is indistinguishable from a tab title, and these sit right
        // next to tab titles. Every one gets a chip; a running toggle fills its chip with the
        // accent colour so "on" is a colour and not a shade of grey.
        if running {
            accentColor.withAlphaComponent(1).setFill()
            pill.fill()
        } else {
            dimTextColor.withAlphaComponent(0.12).setFill()
            pill.fill()
            dimTextColor.withAlphaComponent(0.25).setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }
        drawLabel(action.name, in: frame.insetBy(dx: 8, dy: 0),
                  color: running ? textColor(on: palette.accent) : textColor,
                  font: TabBarView.quickActionFont, centred: true)
    }

    /// One coloured strip per expanded group, spanning its tabs, with its name shown once.
    /// Two strokes, not a glyph and not a symbol.
    ///
    /// `NSImage(systemSymbolName: "plus")` did not resolve here and came out as an asterisk, which
    /// is a confusing thing to put beside the tabs; a text `+` depends on whatever face is in use.
    /// Drawn, it is a plus at every size and in every theme.
    private func drawPlus(in frame: NSRect) {
        let arm: CGFloat = 5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: frame.midX - arm, y: frame.midY))
        path.line(to: NSPoint(x: frame.midX + arm, y: frame.midY))
        path.move(to: NSPoint(x: frame.midX, y: frame.midY - arm))
        path.line(to: NSPoint(x: frame.midX, y: frame.midY + arm))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        dimTextColor.setStroke()
        path.stroke()
    }

    /// A tinted band behind a group's label and its tabs.
    ///
    /// This is the whole of the group's presence in the bar: the tabs sit *in* something, which is
    /// what makes them look like a set. It replaces a coloured strip in a row of its own, which
    /// cost every tab vertical space and still managed to look unrelated to the tabs it named.
    private func drawGroupBands(_ dirtyRect: NSRect) {
        for header in TabBarGeometry.groupHeaders(slots: slots) {
            let frame = ns(TabBarGeometry.groupBandRect(fromSlot: header.first, toSlot: header.last,
                                                        slotCount: slots.count,
                                                        barWidth: Double(bounds.width),
                                                        barHeight: Double(bounds.height),
                                                        leading: leadingWidth,
                                                        trailing: TabBarView.builtInButtonWidth,
                                                        metrics: TabBarView.metrics))
            guard frame.intersects(dirtyRect) else { continue }
            let color = self.color(ofGroup: header.id)
            let band = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6)
            color.withAlphaComponent(0.16).setFill()
            band.fill()
            color.withAlphaComponent(0.55).setStroke()
            band.lineWidth = 1
            band.stroke()
        }
    }

    /// The group's name, in its own colour, in front of its tabs. Clicking it collapses the group,
    /// which is why it looks like a control rather than like a caption.
    private func drawGroupLabel(_ id: Int, in frame: NSRect) {
        guard let group = grouping.group(withID: id) else { return }
        let fill = rgb(ofGroup: id)
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 4, dy: 6), xRadius: 5, yRadius: 5)
        nsColor(fill, alpha: 1).setFill()
        pill.fill()
        drawLabel(group.name, in: frame.insetBy(dx: 8, dy: 0), color: textColor(on: fill),
                  font: .systemFont(ofSize: 10, weight: .semibold), centred: true)
    }

    /// A collapsed group: one chip carrying its name and how many tabs it is standing in for.
    private func drawChip(groupID: Int, tabCount: Int, in frame: NSRect) {
        guard let group = grouping.group(withID: groupID) else { return }
        let color = self.color(ofGroup: groupID)
        color.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 4), xRadius: 4, yRadius: 4).fill()
        separatorColor.setFill()
        NSRect(x: frame.maxX - 1, y: 4, width: 1, height: frame.height - 8).fill()
        drawLabel("\(group.name) \(tabCount)", in: frame.insetBy(dx: 8, dy: 0), color: textColor,
                  font: .systemFont(ofSize: 11, weight: .medium), centred: true)
    }

    /// The font the badge chip is set in. Small and medium: it is a category, not a name, and it
    /// must not compete with the title beside it.
    private static let badgeFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    /// How wide a badge's pill is for the text in it, or 0 when there is none. Measured here
    /// because a string's width is a property of the font; `TabBarGeometry` is handed the number.
    private func badgeWidth(_ label: String?) -> Double {
        guard let label, !label.isEmpty else { return 0 }
        let size = (label as NSString).size(withAttributes: [.font: TabBarView.badgeFont])
        return Double(ceil(size.width)) + 10   // 5pt of pill on each side of the text
    }

    private func badgeRect(in tab: NSRect, label: String?) -> NSRect? {
        TabBarGeometry.badgeRect(in: pane(tab), width: badgeWidth(label),
                                 metrics: TabBarView.metrics).map(ns)
    }

    private func draw(_ item: TabBarItem, in frame: NSRect, isSelected: Bool) {
        if isSelected {
            selectedBackground.setFill()
            frame.fill()
            // A bar in the accent along the selected tab's bottom edge, over the line that runs
            // under the whole bar. Without it the only things saying which tab is selected are a
            // background one step off the bar's own and a slightly heavier weight -- true at a
            // glance in nyx-dark, and much less so in Solarized, where those two colours are four
            // units apart. This is the cue every tabbed application uses, and it is the one place
            // in the bar where the theme's accent says something rather than decorating.
            accentColor.setFill()
            NSRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2).fill()
        }
        separatorColor.setFill()
        NSRect(x: frame.maxX - 1, y: frame.minY + 4, width: 1, height: frame.height - 8).fill()

        let hasIndicator = item.indicator != .none
        if hasIndicator { drawIndicator(item.indicator, in: indicatorRect(in: frame)) }
        let badge = badgeRect(in: frame, label: item.label)
        if let badge, let label = item.label { drawBadge(label, in: badge) }
        drawTitle(item.title, in: titleRect(in: frame, hasIndicator: hasIndicator, badge: badge),
                  isSelected: isSelected)
        if let close = closeRect(in: frame) { drawCloseButton(in: close, isSelected: isSelected) }
    }

    /// The observer/writer chip: a filled pill in the theme's accent with text picked to read on
    /// it, exactly like a group's name chip -- the bar already has one vocabulary for "what kind of
    /// tab is this", and a second one would be a second thing to learn.
    private func drawBadge(_ label: String, in frame: NSRect) {
        let fill = palette.accent
        nsColor(fill, alpha: 1).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
        drawLabel(label, in: frame.insetBy(dx: 5, dy: 0), color: textColor(on: fill),
                  font: TabBarView.badgeFont, centred: true)
    }

    private func drawIndicator(_ indicator: TabIndicator, in rect: NSRect) {
        accentColor.setFill()
        switch indicator {
        case .none:
            break
        case .activity:
            let dot = rect.insetBy(dx: rect.width / 2 - 3, dy: rect.height / 2 - 3)
            NSBezierPath(ovalIn: dot).fill()
        case .bell:
            // SF Symbols carries a bell; a filled ring is the fallback if it ever does not.
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: accentColor))
            if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "bell")?
                .withSymbolConfiguration(configuration) {
                let size = bell.size
                bell.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                     width: size.width, height: size.height))
            } else {
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
        }
    }

    private func drawTitle(_ title: String, in rect: NSRect, isSelected: Bool) {
        // Left-aligned, not centred. A centred title drifts away from its own activity dot, which
        // sits at the tab's left edge -- so on a wide tab the dot ends up nearer the *previous*
        // tab's title than its own, and reads as belonging to it.
        drawLabel(title, in: rect, color: isSelected ? textColor : dimTextColor,
                  font: .systemFont(ofSize: 11, weight: isSelected ? .medium : .regular), centred: false)
    }

    /// Draws text shortened to fit. The width of a string is a property of the font, which is why
    /// `TabTitle` is handed a measuring function rather than a character count.
    private func drawLabel(_ text: String, in rect: NSRect, color: NSColor, font: NSFont, centred: Bool) {
        guard rect.width > 0, !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let shortened = TabTitle.truncatedInMiddle(text, maxWidth: Double(rect.width)) {
            Double(($0 as NSString).size(withAttributes: attributes).width)
        }
        guard !shortened.isEmpty else { return }
        let string = NSAttributedString(string: shortened, attributes: attributes)
        let size = string.size()
        let x = centred ? rect.minX + max(0, (rect.width - size.width) / 2) : rect.minX
        string.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2))
    }

    private func drawCloseButton(in rect: NSRect, isSelected: Bool) {
        let cross = rect.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cross.minX, y: cross.minY))
        path.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
        path.move(to: NSPoint(x: cross.maxX, y: cross.minY))
        path.line(to: NSPoint(x: cross.minX, y: cross.maxY))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        (isSelected ? textColor : dimTextColor).setStroke()
        path.stroke()
    }
}

/// Two theme colours mixed, for the shades of the bar that are not in the palette itself.
private func mix(_ a: RGB, _ b: RGB, _ fraction: Double) -> RGB {
    func blend(_ x: UInt8, _ y: UInt8) -> UInt8 {
        UInt8(max(0, min(255, (Double(x) * (1 - fraction) + Double(y) * fraction).rounded())))
    }
    return RGB(blend(a.r, b.r), blend(a.g, b.g), blend(a.b, b.b))
}
