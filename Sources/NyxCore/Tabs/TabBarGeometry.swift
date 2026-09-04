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

    public init(maxTabWidth: Double = 220, closeButtonSize: Double = 14,
                indicatorSize: Double = 9, horizontalInset: Double = 7, gap: Double = 4) {
        self.maxTabWidth = maxTabWidth
        self.closeButtonSize = closeButtonSize
        self.indicatorSize = indicatorSize
        self.horizontalInset = horizontalInset
        self.gap = gap
    }

    public static let standard = TabBarMetrics()

    /// Below this a tab has no room for its close button, and shows none.
    var minimumWidthForCloseButton: Double { closeButtonSize + horizontalInset * 2 }
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
        let width = tabWidth(barWidth: barWidth, tabCount: tabCount, metrics: metrics)
        return PaneRect(x: Double(index) * width, y: 0, width: width, height: barHeight)
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

    /// What a click means: the close button of a tab, the tab itself, or nothing.
    public enum Hit: Equatable {
        case select(Int)
        case close(Int)
    }

    public static func hit(atX x: Double, y: Double, barWidth: Double, barHeight: Double,
                           tabCount: Int, metrics: TabBarMetrics = .standard) -> Hit? {
        guard tabCount > 0, x >= 0, x < barWidth, y >= 0, y <= barHeight else { return nil }
        let width = tabWidth(barWidth: barWidth, tabCount: tabCount, metrics: metrics)
        guard width > 0 else { return nil }
        let index = Int(x / width)
        guard index < tabCount else { return nil }
        let tab = tabRect(index: index, barWidth: barWidth, barHeight: barHeight,
                          tabCount: tabCount, metrics: metrics)
        if let close = closeRect(in: tab, metrics: metrics), close.contains(x: x, y: y) {
            return .close(index)
        }
        return .select(index)
    }
}

public extension PaneRect {
    func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x <= self.x + width && y >= self.y && y <= self.y + height
    }
}
