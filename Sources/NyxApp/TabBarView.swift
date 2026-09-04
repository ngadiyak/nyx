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
    /// The system switched between light and dark; the controller decides whether the theme cares.
    var onAppearanceChange: (() -> Void)?

    private var items: [TabBarItem] = []
    private var selected = 0
    private var grouping = TabGrouping()
    private var slots: [TabBarGeometry.Slot] = []

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
                           headerHeight: Double(headerHeight), metrics: TabBarView.metrics)
    }

    private func color(ofGroup id: Int) -> NSColor {
        guard let group = grouping.group(withID: id),
              palette.colors.indices.contains(group.colorIndex) else { return accentColor }
        return nsColor(palette.colors[group.colorIndex], alpha: 1)
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .close(let index): onClose?(index)
        case .select(let index): onSelect?(index)
        case .expandGroup(let id), .groupHeader(let id): onToggleGroup?(id)
        case nil: break
        }
    }

    /// A right-click anywhere on a tab -- its close button included, where a context menu is more
    /// useful than a second way to close it.
    override func rightMouseDown(with event: NSEvent) {
        switch hit(at: convert(event.locationInWindow, from: nil)) {
        case .close(let index), .select(let index): onContextMenu?(index, event)
        case .expandGroup(let id), .groupHeader(let id): onGroupContextMenu?(id, event)
        case nil: break
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        barBackground.setFill()
        dirtyRect.fill()
        for (position, slot) in slots.enumerated() {
            let frame = rect(forSlot: position)
            guard frame.intersects(dirtyRect) else { continue }
            switch slot {
            case .tab(let index, _):
                guard items.indices.contains(index) else { continue }
                draw(items[index], in: frame, isSelected: index == selected)
            case .collapsedGroup(let id, let count):
                drawChip(groupID: id, tabCount: count, in: frame)
            }
        }
        drawGroupHeaders(dirtyRect)
        // The line under the whole bar, so the panes below it do not float.
        separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// One coloured strip per expanded group, spanning its tabs, with its name shown once.
    private func drawGroupHeaders(_ dirtyRect: NSRect) {
        guard headerHeight > 0 else { return }
        for header in TabBarGeometry.groupHeaders(slots: slots) {
            let frame = ns(TabBarGeometry.groupHeaderRect(fromSlot: header.first, toSlot: header.last,
                                                          slotCount: slots.count, barWidth: Double(bounds.width),
                                                          headerHeight: Double(headerHeight),
                                                          metrics: TabBarView.metrics))
            guard frame.intersects(dirtyRect), let group = grouping.group(withID: header.id) else { continue }
            let color = self.color(ofGroup: header.id)
            color.withAlphaComponent(0.30).setFill()
            frame.fill()
            color.setFill()
            NSRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2).fill()
            drawLabel(group.name, in: frame.insetBy(dx: 6, dy: 0), color: textColor,
                      font: .systemFont(ofSize: 9, weight: .semibold), centred: false)
        }
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
        drawLabel(title, in: rect, color: isSelected ? textColor : dimTextColor,
                  font: .systemFont(ofSize: 11, weight: isSelected ? .medium : .regular), centred: true)
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
