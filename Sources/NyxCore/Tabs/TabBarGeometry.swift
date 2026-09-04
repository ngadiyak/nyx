import Foundation

/// The fixed sizes the tab bar is laid out from. Kept as a value rather than constants so a test
/// can lay out a bar at sizes that would be tedious to reach through the real metrics.
public struct TabBarMetrics: Equatable {
    public let maxTabWidth: Double
    public let closeButtonSize: Double
    public let indicatorSize: Double
    public let horizontalInset: Double
    /// The gap between the indicator and the title, and between the title and the close button.
    public let gap: Double

    /// The strip above an expanded group's tabs carrying its colour and its name, shown once.
    public let groupHeaderHeight: Double

    public init(maxTabWidth: Double = 220, closeButtonSize: Double = 14,
                indicatorSize: Double = 9, horizontalInset: Double = 7, gap: Double = 4,
                groupHeaderHeight: Double = 14) {
        self.maxTabWidth = maxTabWidth
        self.closeButtonSize = closeButtonSize
        self.indicatorSize = indicatorSize
        self.horizontalInset = horizontalInset
        self.gap = gap
        self.groupHeaderHeight = groupHeaderHeight
    }

    public static let standard = TabBarMetrics()

    /// Below this a tab has no room for its close button, and shows none.
    ///
    /// It is deliberately generous. A close button costs the title the width it needs to say
    /// anything, and twenty tabs reading `×` twenty times is a bar you cannot navigate: the tab is
    /// there to be identified first and closed second. ⌘W still closes; nothing is lost but a
    /// target that had crowded out the only thing distinguishing one tab from another.
    var minimumWidthForCloseButton: Double { closeButtonSize + horizontalInset * 2 + 46 }

    /// The narrowest a tab may be squeezed to make room for the bar's leading buttons. The tabs are
    /// what the bar is *for*, so a button that would push them below this is not shown at all.
    public var minimumSlotWidth: Double { 40 }
}

/// Where each part of each tab sits, and what a click at a point means.
///
/// This is arithmetic that is wrong by one until it is tested, so it lives here rather than in the
/// view -- the same reasoning as `PaneDividers` for split geometry and `TabStrip` for the selection
/// rules. `TabBarView` converts these to `NSRect` and draws them.
public enum TabBarGeometry {
    /// Tabs share the bar equally, never wider than `maxTabWidth`.
    ///
    /// There is deliberately no minimum. A minimum would make tabs overflow the bar once enough of
    /// them are open, and a tab past the right-hand edge cannot be clicked at all -- it can only be
    /// reached by ⌘1…⌘9 or by cycling. Shrinking past legibility is recoverable by closing a tab;
    /// a tab you cannot see or click is not.
    public static func tabWidth(barWidth: Double, tabCount: Int,
                                metrics: TabBarMetrics = .standard) -> Double {
        guard tabCount > 0, barWidth > 0 else { return 0 }
        return min(metrics.maxTabWidth, barWidth / Double(tabCount))
    }

    public static func tabRect(index: Int, barWidth: Double, barHeight: Double, tabCount: Int,
                               metrics: TabBarMetrics = .standard) -> PaneRect {
        slotRect(index: index, slotCount: tabCount, barWidth: barWidth, barHeight: barHeight,
                 headerHeight: 0, metrics: metrics)
    }

    /// The close button, or nil when the tab is too narrow to carry one.
    public static func closeRect(in tab: PaneRect, metrics: TabBarMetrics = .standard) -> PaneRect? {
        guard tab.width >= metrics.minimumWidthForCloseButton else { return nil }
        let size = metrics.closeButtonSize
        return PaneRect(x: tab.x + tab.width - size - metrics.horizontalInset,
                        y: tab.y + (tab.height - size) / 2,
                        width: size, height: size)
    }

    public static func indicatorRect(in tab: PaneRect, metrics: TabBarMetrics = .standard) -> PaneRect {
        let size = metrics.indicatorSize
        return PaneRect(x: tab.x + metrics.horizontalInset,
                        y: tab.y + (tab.height - size) / 2,
                        width: size, height: size)
    }

    /// What is left for the title once the indicator and the close button have taken their corners.
    /// Never negative, and empty when there is no room at all.
    public static func titleRect(in tab: PaneRect, hasIndicator: Bool,
                                 metrics: TabBarMetrics = .standard) -> PaneRect {
        let left = tab.x + metrics.horizontalInset
            + (hasIndicator ? metrics.indicatorSize + metrics.gap : 0)
        let right = closeRect(in: tab, metrics: metrics).map { $0.x - metrics.gap }
            ?? (tab.x + tab.width - metrics.horizontalInset)
        return PaneRect(x: left, y: tab.y, width: max(0, right - left), height: tab.height)
    }

    /// What a click means: the close button of a tab, the tab itself, a collapsed group's chip, a
    /// group's header, or nothing.
    public enum Hit: Equatable {
        case select(Int)
        case close(Int)
        /// The chip a collapsed group shows instead of its tabs; clicking it expands the group.
        case expandGroup(Int)
        /// The coloured strip above an expanded group's tabs.
        case groupHeader(Int)
        /// One of the buttons on the left of the bar, by its index in the list that fitted.
        case leadingButton(Int)
        /// The `+` after the last tab.
        case newTab
    }

    public static func hit(atX x: Double, y: Double, barWidth: Double, barHeight: Double,
                           tabCount: Int, metrics: TabBarMetrics = .standard) -> Hit? {
        hit(atX: x, y: y, slots: (0..<max(0, tabCount)).map { .tab(index: $0, group: nil) },
            barWidth: barWidth, barHeight: barHeight, headerHeight: 0, metrics: metrics)
    }

    // MARK: - Groups
    //
    // With groups the bar stops being "one box per tab". It is a row of *slots*: an ungrouped tab
    // is one slot, an expanded group is one slot per member with a header above them, and a
    // collapsed group is a single chip however many tabs it holds. Everything below is written in
    // slots, and the ungrouped case is just the one where every slot is a tab.

    public enum Slot: Equatable {
        /// The name of an expanded group, standing before its tabs. A slot of its own rather than a
        /// row above them: a whole extra row of bar for a two-tab group costs every tab vertical
        /// space to label a couple of them, and a strip floating above the tabs reads as unrelated
        /// to the tabs it is describing.
        case groupLabel(id: Int)
        /// A tab, and the expanded group it belongs to. A tab in a *collapsed* group gets no slot
        /// of its own -- its group's chip stands in for it -- so a slot's group is always expanded.
        case tab(index: Int, group: Int?)
        /// A collapsed group and how many tabs it is standing in for.
        case collapsedGroup(id: Int, tabCount: Int)
    }

    /// The bar's slots, left to right, from the tabs and how they are grouped.
    public static func slots(tabCount: Int, grouping: TabGrouping) -> [Slot] {
        var result: [Slot] = []
        var index = 0
        while index < tabCount {
            let group = grouping.group(ofTabAt: index)
            guard let group else {
                result.append(.tab(index: index, group: nil))
                index += 1
                continue
            }
            guard let range = grouping.range(ofGroup: group.id) else {
                result.append(.tab(index: index, group: nil))
                index += 1
                continue
            }
            if group.isCollapsed {
                result.append(.collapsedGroup(id: group.id, tabCount: range.count))
                index = range.upperBound
                continue
            }
            // An expanded group announces itself once, in front of its own tabs.
            if index == range.lowerBound { result.append(.groupLabel(id: group.id)) }
            result.append(.tab(index: index, group: group.id))
            index += 1
        }
        return result
    }

    /// The height the bar needs: its base, plus a row for group names when any group is expanded.
    /// A collapsed group names itself on its chip and needs no header.
    /// The bar is one height, always.
    ///
    /// It used to grow a row whenever any group was expanded, which spent vertical space across the
    /// whole window to label two tabs, and put the label somewhere it did not look attached to
    /// them. A group now names itself in a slot in front of its own tabs.
    public static func barHeight(base: Double, grouping: TabGrouping,
                                 metrics: TabBarMetrics = .standard) -> Double {
        base
    }

    /// `leading` is the room taken by the bar's leading buttons; the slots share what is left.
    public static func slotWidth(barWidth: Double, slotCount: Int, leading: Double = 0,
                                 trailing: Double = 0, metrics: TabBarMetrics = .standard) -> Double {
        let available = barWidth - leading - trailing
        guard slotCount > 0, available > 0 else { return 0 }
        return min(metrics.maxTabWidth, available / Double(slotCount))
    }

    /// A slot's box. The header row, when there is one, is taken off the top: slots sit below it,
    /// so a group's name never overlaps the tab it names.
    public static func slotRect(index: Int, slotCount: Int, barWidth: Double, barHeight: Double,
                                headerHeight: Double, leading: Double = 0, trailing: Double = 0,
                                metrics: TabBarMetrics = .standard) -> PaneRect {
        let width = slotWidth(barWidth: barWidth, slotCount: slotCount, leading: leading,
                              trailing: trailing, metrics: metrics)
        return PaneRect(x: leading + Double(index) * width, y: headerHeight,
                        width: width, height: max(0, barHeight - headerHeight))
    }

    /// The coloured strip over an expanded group, spanning the slots its tabs occupy.
    public static func groupHeaderRect(fromSlot first: Int, toSlot last: Int, slotCount: Int,
                                       barWidth: Double, headerHeight: Double, leading: Double = 0,
                                       trailing: Double = 0,
                                       metrics: TabBarMetrics = .standard) -> PaneRect {
        let width = slotWidth(barWidth: barWidth, slotCount: slotCount, leading: leading,
                              trailing: trailing, metrics: metrics)
        return PaneRect(x: leading + Double(first) * width, y: 0,
                        width: Double(last - first + 1) * width, height: headerHeight)
    }

    /// The box for the button pinned to the right of the last tab.
    ///
    /// `+` belongs after the tabs, where every browser and every other tabbed application puts it,
    /// and where the eye already is once a tab has just been opened. On the left it sat among the
    /// quick-action buttons, which are a different kind of thing entirely.
    ///
    /// Returns nil when the tabs need every pixel: at that point one more tab is not what the bar
    /// should be spending its last 26 points on.
    public static func trailingRect(buttonWidth: Double, barWidth: Double, barHeight: Double,
                                    slotCount: Int, leading: Double, headerHeight: Double,
                                    metrics: TabBarMetrics = .standard) -> PaneRect? {
        guard buttonWidth > 0, barWidth > buttonWidth else { return nil }
        // Deliberately not dropped when the tabs are tight. At twenty tabs the bar lost its `+`
        // exactly when it was hardest to reach one any other way, and a row of tabs you cannot add
        // to is not a saving -- the tabs give up a point each instead.
        return PaneRect(x: barWidth - buttonWidth, y: headerHeight,
                        width: buttonWidth, height: max(0, barHeight - headerHeight))
    }

    // MARK: - The buttons on the left of the bar
    //
    // A `+`, a tab-list button, and one per configured quick action. They sit left of the first tab
    // and must never overlap it, which is what makes them a layout question rather than a drawing
    // one: at forty open tabs there is no room, and the answer is to show fewer buttons rather than
    // to squeeze the tabs to nothing. The tabs are what the bar is for.

    /// The buttons that fit, in order, with their boxes. Anything past the budget is dropped.
    public static func leadingRects(buttonWidths: [Double], barWidth: Double, barHeight: Double,
                                    slotCount: Int, headerHeight: Double,
                                    metrics: TabBarMetrics = .standard) -> [PaneRect] {
        let needed = Double(max(0, slotCount)) * metrics.minimumSlotWidth
        let budget = max(0, barWidth - needed)
        var rects: [PaneRect] = []
        var x: Double = 0
        for width in buttonWidths {
            guard width > 0, x + width <= budget else { break }
            rects.append(PaneRect(x: x, y: headerHeight, width: width,
                                  height: max(0, barHeight - headerHeight)))
            x += width
        }
        return rects
    }

    /// How much of the bar the buttons that fit have taken.
    public static func leadingWidth(buttonWidths: [Double], barWidth: Double, barHeight: Double,
                                    slotCount: Int, headerHeight: Double,
                                    metrics: TabBarMetrics = .standard) -> Double {
        leadingRects(buttonWidths: buttonWidths, barWidth: barWidth, barHeight: barHeight,
                     slotCount: slotCount, headerHeight: headerHeight, metrics: metrics)
            .last.map { $0.x + $0.width } ?? 0
    }

    /// The box covering a group's label and its tabs, for the tinted band drawn behind them.
    public static func groupBandRect(fromSlot first: Int, toSlot last: Int, slotCount: Int,
                                     barWidth: Double, barHeight: Double, leading: Double = 0,
                                     trailing: Double = 0,
                                     metrics: TabBarMetrics = .standard) -> PaneRect {
        let width = slotWidth(barWidth: barWidth, slotCount: slotCount, leading: leading,
                              trailing: trailing, metrics: metrics)
        return PaneRect(x: leading + Double(first) * width, y: 0,
                        width: Double(last - first + 1) * width, height: barHeight)
    }

    /// The slot runs each expanded group covers, as `(group id, first slot, last slot)`.
    public static func groupHeaders(slots: [Slot]) -> [(id: Int, first: Int, last: Int)] {
        var headers: [(id: Int, first: Int, last: Int)] = []
        for (position, slot) in slots.enumerated() {
            var group: Int?
            if case .tab(_, let g) = slot { group = g }
            if case .groupLabel(let id) = slot { group = id }
            guard let id = group else { continue }
            if let previous = headers.last, previous.id == id, previous.last == position - 1 {
                headers[headers.count - 1] = (id: id, first: previous.first, last: position)
            } else {
                headers.append((id: id, first: position, last: position))
            }
        }
        return headers
    }

    public static func hit(atX x: Double, y: Double, slots: [Slot], barWidth: Double,
                           barHeight: Double, headerHeight: Double, trailingWidth: Double = 0,
                           leadingWidths: [Double] = [],
                           metrics: TabBarMetrics = .standard) -> Hit? {
        guard x >= 0, x < barWidth, y >= 0, y <= barHeight else { return nil }
        if let trailing = trailingRect(buttonWidth: trailingWidth, barWidth: barWidth,
                                       barHeight: barHeight, slotCount: slots.count,
                                       leading: leadingWidth(buttonWidths: leadingWidths, barWidth: barWidth,
                                                             barHeight: barHeight, slotCount: slots.count,
                                                             headerHeight: headerHeight, metrics: metrics),
                                       headerHeight: headerHeight, metrics: metrics),
           trailing.contains(x: x, y: y) {
            return .newTab
        }
        let buttons = leadingRects(buttonWidths: leadingWidths, barWidth: barWidth, barHeight: barHeight,
                                   slotCount: slots.count, headerHeight: headerHeight, metrics: metrics)
        if let button = buttons.firstIndex(where: { $0.contains(x: x, y: y) }) {
            return .leadingButton(button)
        }
        let leading = buttons.last.map { $0.x + $0.width } ?? 0
        guard !slots.isEmpty, x >= leading else { return nil }
        let width = slotWidth(barWidth: barWidth, slotCount: slots.count, leading: leading,
                              trailing: trailingWidth, metrics: metrics)
        guard width > 0 else { return nil }
        let position = Int((x - leading) / width)
        guard position < slots.count else { return nil }

        switch slots[position] {
        case .collapsedGroup(let id, _):
            return .expandGroup(id)
        case .groupLabel(let id):
            // The name is the collapse control: it is the one part of a group that is obviously
            // about the group rather than about one of its tabs.
            return .groupHeader(id)
        case .tab(let index, _):
            let slot = slotRect(index: position, slotCount: slots.count, barWidth: barWidth,
                                barHeight: barHeight, headerHeight: headerHeight, leading: leading,
                                trailing: trailingWidth, metrics: metrics)
            if let close = closeRect(in: slot, metrics: metrics), close.contains(x: x, y: y) {
                return .close(index)
            }
            return .select(index)
        }
    }
}

public extension PaneRect {
    func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x <= self.x + width && y >= self.y && y <= self.y + height
    }
}
