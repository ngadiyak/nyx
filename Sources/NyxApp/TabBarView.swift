import AppKit
import NyxCore

/// One tab, as much of it as the bar needs to draw.
struct TabBarItem {
    var title: String
    var indicator: TabIndicator
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
    }

    private static let builtInButtonWidth: Double = 26
    private static let quickActionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private func rebuildLeadingButtons() {
        leadingButtons = [.tabList] + quickActions.indices.map { .quick($0) } + [.addQuickAction]
        leadingWidths = leadingButtons.map { button in
            switch button {
            case .newTab, .tabList, .addQuickAction:
                return TabBarView.builtInButtonWidth
            case .quick(let index):
                let name = quickActions[index].name as NSString
                let text = Double(name.size(withAttributes: [.font: TabBarView.quickActionFont]).width)
                // Room either side, plus a dot for a toggle that is running.
                return min(140, text + 20)
            }
        }
    }

    /// The buttons that actually fit. `TabBarGeometry` drops the overflow rather than squeezing the
    /// tabs, so this is shorter than `leadingButtons` on a narrow bar with many tabs.
    private var fittedLeadingRects: [NSRect] {
        TabBarGeometry.leadingRects(buttonWidths: leadingWidths, barWidth: Double(bounds.width),
                                    barHeight: Double(bounds.height), slotCount: slots.count,
                                    headerHeight: Double(headerHeight), metrics: TabBarView.metrics)
            .map(ns)
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
        TabBarGeometry.leadingWidth(buttonWidths: leadingWidths, barWidth: Double(bounds.width),
                                    barHeight: Double(bounds.height), slotCount: slots.count,
                                    headerHeight: Double(headerHeight), metrics: TabBarView.metrics)
    }

    /// The bar is drawn in the terminal's own palette, so it belongs to the theme rather than to
    /// the system appearance.
    func setColors(palette: Palette) {
        self.palette = palette
        barBackground = nsColor(mix(palette.background, palette.foreground, 0.10), alpha: 1)
        selectedBackground = nsColor(palette.background, alpha: 1)
        textColor = nsColor(palette.foreground, alpha: 0.95)
        dimTextColor = nsColor(palette.foreground, alpha: 0.55)
        separatorColor = nsColor(palette.foreground, alpha: 0.15)
        accentColor = nsColor(palette.cursor, alpha: 0.9)
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

    private func titleRect(in tab: NSRect, hasIndicator: Bool) -> NSRect {
        ns(TabBarGeometry.titleRect(in: pane(tab), hasIndicator: hasIndicator, metrics: TabBarView.metrics))
    }

    private func pane(_ r: NSRect) -> PaneRect {
        PaneRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    private func hit(at point: NSPoint) -> TabBarGeometry.Hit? {
        TabBarGeometry.hit(atX: Double(point.x), y: Double(point.y), slots: slots,
                           barWidth: Double(bounds.width), barHeight: Double(bounds.height),
                           headerHeight: Double(headerHeight),
                           trailingWidth: TabBarView.builtInButtonWidth,
                           leadingWidths: leadingWidths, metrics: TabBarView.metrics)
    }

    private func color(ofGroup id: Int) -> NSColor {
        guard let group = grouping.group(withID: id),
              palette.colors.indices.contains(group.colorIndex) else { return accentColor }
        return nsColor(palette.colors[group.colorIndex], alpha: 1)
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

    /// What the thing under the pointer is called, or nil where there is nothing to name.
    private func label(at point: NSPoint) -> String? {
        switch hit(at: point) {
        case .newTab:
            return "New tab (⌘T)"
        case .close(let index):
            return items.indices.contains(index) ? "Close \(items[index].title) (⌘W)" : "Close tab"
        case .select(let index):
            return items.indices.contains(index) ? items[index].title : nil
        case .expandGroup(let id), .groupHeader(let id):
            guard let group = grouping.group(withID: id) else { return nil }
            return group.isCollapsed ? "Expand “\(group.name)”" : "Collapse “\(group.name)”"
        case .leadingButton(let index):
            guard leadingButtons.indices.contains(index) else { return nil }
            switch leadingButtons[index] {
            case .tabList: return "All tabs (⌘⇧P)"
            case .addQuickAction: return "Add a button for a command you run often"
            case .quick(let action):
                guard quickActions.indices.contains(action) else { return nil }
                let quick = quickActions[action]
                let what: String
                switch quick.kind {
                case .send: what = "types"
                case .run: what = "opens a tab and runs"
                case .toggle:
                    what = QuickActionRunner.shared.isRunning(quick) ? "stops" : "runs in the background"
                }
                return "\(quick.name) — \(what): \(quick.command)"
            case .newTab: return "New tab (⌘T)"
            }
        case nil:
            return nil
        }
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
        guard leadingButtons.indices.contains(index) else { return }
        switch leadingButtons[index] {
        case .newTab: onNewTab?()
        case .tabList: onShowTabList?()
        case .quick(let action): onQuickAction?(action)
        case .addQuickAction: onAddQuickAction?()
        }
    }

    /// A right-click anywhere on a tab -- its close button included, where a context menu is more
    /// useful than a second way to close it.
    override func rightMouseDown(with event: NSEvent) {
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .close(let index), .select(let index): onContextMenu?(index, event)
        case .expandGroup(let id), .groupHeader(let id): onGroupContextMenu?(id, event)
        case .leadingButton(let index):
            if case .quick(let action)? = leadingButtons.indices.contains(index) ? leadingButtons[index] : nil {
                onQuickActionContextMenu?(action, event)
            }
        case .newTab: break
        case nil: break
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
        for (index, frame) in fittedLeadingRects.enumerated() {
            guard frame.intersects(dirtyRect), leadingButtons.indices.contains(index) else { continue }
            switch leadingButtons[index] {
            case .newTab: drawSymbol("plus", fallback: "+", in: frame)
            case .tabList: drawSymbol("list.bullet", fallback: "\u{2261}", in: frame)
            case .quick(let action): drawQuickActionButton(action, in: frame)
            case .addQuickAction: drawAddQuickActionButton(in: frame)
            }
        }
        if let trailing = trailingRect { drawPlus(in: trailing) }
        guard let last = fittedLeadingRects.last else { return }
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

    /// A quick action's button. A `toggle` that is running says so with a filled dot, because a
    /// button that goes on claiming `caffeinate` is alive after it died is worse than no button.
    /// Text drawn on top of the accent fill. Using the foreground colour there gives light-on-light
    /// or dark-on-dark depending on the theme; the background always contrasts with the accent,
    /// because that is what the accent was chosen against.
    private var backgroundColorForAccentText: NSColor { barBackground }

    /// Drawn as an empty chip with a `+` in it, not as another plain plus.
    ///
    /// There is already a `+` at the far left for a new tab; a second identical one a few pixels
    /// away is a coin toss. Shaped like the buttons it makes, it reads as "add one of these".
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
            accentColor.withAlphaComponent(0.85).setFill()
            pill.fill()
        } else {
            dimTextColor.withAlphaComponent(0.12).setFill()
            pill.fill()
            dimTextColor.withAlphaComponent(0.25).setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }
        drawLabel(action.name, in: frame.insetBy(dx: 8, dy: 0),
                  color: running ? backgroundColorForAccentText : textColor,
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
        let color = self.color(ofGroup: id)
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 4, dy: 6), xRadius: 5, yRadius: 5)
        color.withAlphaComponent(0.9).setFill()
        pill.fill()
        drawLabel(group.name, in: frame.insetBy(dx: 8, dy: 0), color: barBackground,
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

    private func draw(_ item: TabBarItem, in frame: NSRect, isSelected: Bool) {
        if isSelected {
            selectedBackground.setFill()
            frame.fill()
        }
        separatorColor.setFill()
        NSRect(x: frame.maxX - 1, y: frame.minY + 4, width: 1, height: frame.height - 8).fill()

        let hasIndicator = item.indicator != .none
        if hasIndicator { drawIndicator(item.indicator, in: indicatorRect(in: frame)) }
        drawTitle(item.title, in: titleRect(in: frame, hasIndicator: hasIndicator), isSelected: isSelected)
        if let close = closeRect(in: frame) { drawCloseButton(in: close, isSelected: isSelected) }
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
