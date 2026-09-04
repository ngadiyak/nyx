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
/// which tab a shortcut means, how a title shortens -- is in `TabStrip`/`TabTitle` in `NyxCore`.
final class TabBarView: NSView {
    /// The bar's height, fixed by the brief.
    static let height: CGFloat = 28

    /// Sizes and the arithmetic over them live in `TabBarGeometry`, where they are tested; this
    /// view converts what it returns into `NSRect` and draws it.
    private static let metrics = TabBarMetrics.standard

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The system switched between light and dark; the controller decides whether the theme cares.
    var onAppearanceChange: (() -> Void)?

    private var items: [TabBarItem] = []
    private var selected = 0

    private var barBackground: NSColor = .clear
    private var selectedBackground: NSColor = .clear
    private var textColor: NSColor = .clear
    private var dimTextColor: NSColor = .clear
    private var separatorColor: NSColor = .clear
    private var accentColor: NSColor = .clear

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func setTabs(_ items: [TabBarItem], selected: Int) {
        self.items = items
        self.selected = selected
        needsDisplay = true
    }

    /// The bar is drawn in the terminal's own palette, so it belongs to the theme rather than to
    /// the system appearance.
    func setColors(palette: Palette) {
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

    private func rect(forTab index: Int) -> NSRect {
        ns(TabBarGeometry.tabRect(index: index, barWidth: bounds.width, barHeight: bounds.height,
                                  tabCount: items.count, metrics: TabBarView.metrics))
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

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch TabBarGeometry.hit(atX: point.x, y: point.y, barWidth: bounds.width,
                                  barHeight: bounds.height, tabCount: items.count,
                                  metrics: TabBarView.metrics) {
        case .close(let index): onClose?(index)
        case .select(let index): onSelect?(index)
        case nil: break
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        barBackground.setFill()
        dirtyRect.fill()
        for index in items.indices {
            let frame = rect(forTab: index)
            guard frame.intersects(dirtyRect) else { continue }
            draw(items[index], in: frame, isSelected: index == selected)
        }
        // The line under the whole bar, so the panes below it do not float.
        separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private func draw(_ item: TabBarItem, in frame: NSRect, isSelected: Bool) {
        if isSelected {
            selectedBackground.setFill()
            frame.fill()
        }
        separatorColor.setFill()
        NSRect(x: frame.maxX - 1, y: 4, width: 1, height: frame.height - 8).fill()

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
        guard rect.width > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .medium : .regular),
            .foregroundColor: isSelected ? textColor : dimTextColor,
        ]
        // The width of a string is a property of this font, which is why `TabTitle` is handed a
        // measuring function rather than a character count.
        let shortened = TabTitle.truncatedInMiddle(title, maxWidth: Double(rect.width)) {
            Double(($0 as NSString).size(withAttributes: attributes).width)
        }
        guard !shortened.isEmpty else { return }
        let string = NSAttributedString(string: shortened, attributes: attributes)
        let size = string.size()
        let origin = NSPoint(x: rect.minX + max(0, (rect.width - size.width) / 2),
                             y: rect.midY - size.height / 2)
        string.draw(at: origin)
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
