import Foundation

/// A path from the root of a `PaneTree` down to one split node: `.first` descends into the first
/// child, `.second` into the second. An empty path is the root itself.
///
/// Dividers are identified by path rather than by index into `dividers(in:dividerThickness:)`,
/// because a divider drag has to survive the tree changing underneath it (a pane closing while the
/// mouse is down) without silently grabbing a different split.
public struct SplitPath: Hashable {
    public enum Step: Hashable { case first, second }

    public var steps: [Step]

    public init(_ steps: [Step] = []) { self.steps = steps }

    public func appending(_ step: Step) -> SplitPath { SplitPath(steps + [step]) }
}

/// One divider: the gap between the two children of a split.
public struct PaneDivider: Equatable {
    /// The axis of the split. `.horizontal` divides width, so the divider is a vertical line the
    /// user drags left and right; `.vertical` divides height and is dragged up and down.
    public var axis: SplitAxis
    /// The divider itself -- `dividerThickness` wide (or tall), spanning the split's other axis.
    public var rect: PaneRect
    /// The bounds the split node occupies. A drag position only means something relative to these,
    /// so it is carried alongside rather than recomputed.
    public var bounds: PaneRect
    /// Which split in the tree this divider belongs to.
    public var path: SplitPath

    public init(axis: SplitAxis, rect: PaneRect, bounds: PaneRect, path: SplitPath) {
        self.axis = axis
        self.rect = rect
        self.bounds = bounds
        self.path = path
    }
}

public extension PaneTree {
    /// Every divider in the tree, in pre-order. The rects are in the same space as `bounds` and
    /// exactly fill the gaps `layout(in:dividerThickness:)` leaves between panes.
    func dividers(in bounds: PaneRect, dividerThickness: Double) -> [PaneDivider] {
        var result: [PaneDivider] = []
        collectDividers(in: bounds, dividerThickness: dividerThickness, path: SplitPath(), into: &result)
        return result
    }

    private func collectDividers(in bounds: PaneRect, dividerThickness: Double, path: SplitPath,
                                 into result: inout [PaneDivider]) {
        guard case .split(let axis, let ratio, let first, let second) = self else { return }
        let (firstBounds, secondBounds) = PaneTree.splitBounds(bounds, axis: axis, ratio: ratio, dividerThickness: dividerThickness)
        // The gap the layout actually left between the two children, so the drawn line and the
        // laid-out panes can never disagree about where the boundary is.
        let rect: PaneRect
        switch axis {
        case .horizontal:
            let x = firstBounds.x + firstBounds.width
            rect = PaneRect(x: x, y: bounds.y, width: max(0, secondBounds.x - x), height: bounds.height)
        case .vertical:
            let y = firstBounds.y + firstBounds.height
            rect = PaneRect(x: bounds.x, y: y, width: bounds.width, height: max(0, secondBounds.y - y))
        }
        result.append(PaneDivider(axis: axis, rect: rect, bounds: bounds, path: path))
        first.collectDividers(in: firstBounds, dividerThickness: dividerThickness, path: path.appending(.first), into: &result)
        second.collectDividers(in: secondBounds, dividerThickness: dividerThickness, path: path.appending(.second), into: &result)
    }

    /// The divider whose hit area contains the point, or nil. `hitSlop` is the full width of that
    /// hit area, centred on the divider, so a 1pt line with a 6pt slop is grabbable from 3pt away
    /// on either side. Overlapping hit areas resolve to the nearest divider.
    func divider(atX x: Double, y: Double, in bounds: PaneRect, dividerThickness: Double, hitSlop: Double) -> PaneDivider? {
        var best: (divider: PaneDivider, distance: Double)?
        for divider in dividers(in: bounds, dividerThickness: dividerThickness) {
            let (position, centre, span): (Double, Double, ClosedRange<Double>)
            switch divider.axis {
            case .horizontal:
                position = x
                centre = divider.rect.x + divider.rect.width / 2
                span = divider.rect.y...(divider.rect.y + divider.rect.height)
                guard span.contains(y) else { continue }
            case .vertical:
                position = y
                centre = divider.rect.y + divider.rect.height / 2
                span = divider.rect.x...(divider.rect.x + divider.rect.width)
                guard span.contains(x) else { continue }
            }
            let distance = abs(position - centre)
            guard distance <= max(hitSlop, dividerThickness) / 2 else { continue }
            if best == nil || distance < best!.distance { best = (divider, distance) }
        }
        return best?.divider
    }

    /// The pane whose frame contains the point, or nil when the point is in a divider gap or
    /// outside `bounds`. Frames are half-open on their far edges, so no point belongs to two panes.
    func pane(atX x: Double, y: Double, in bounds: PaneRect, dividerThickness: Double) -> PaneID? {
        let frames = layout(in: bounds, dividerThickness: dividerThickness)
        // `panes` order, not the dictionary's, so the answer never depends on hash ordering.
        for id in panes {
            guard let f = frames[id] else { continue }
            if x >= f.x, x < f.x + f.width, y >= f.y, y < f.y + f.height { return id }
        }
        return nil
    }

    /// The ratio of the split at `path`, or nil when the path does not name a split.
    func ratio(at path: SplitPath) -> Double? {
        node(at: path).flatMap { node in
            guard case .split(_, let ratio, _, _) = node else { return nil }
            return ratio
        }
    }

    /// A copy of the tree with the ratio of the split at `path` replaced (clamped to the same
    /// `0.05...0.95` bounds every other ratio is). A path that does not name a split is a no-op.
    func settingRatio(_ ratio: Double, at path: SplitPath) -> PaneTree {
        guard case .split(let axis, let existing, let first, let second) = self else { return self }
        guard let step = path.steps.first else {
            return .split(axis: axis, ratio: PaneTree.clampRatio(ratio), first: first, second: second)
        }
        let rest = SplitPath(Array(path.steps.dropFirst()))
        switch step {
        case .first:
            return .split(axis: axis, ratio: existing, first: first.settingRatio(ratio, at: rest), second: second)
        case .second:
            return .split(axis: axis, ratio: existing, first: first, second: second.settingRatio(ratio, at: rest))
        }
    }

    /// The ratio that puts `divider`'s centre at `position` -- the x of a horizontal split's
    /// divider, the y of a vertical one's -- measured in the same space as the layout bounds.
    /// Clamped like every other ratio, so a drag past either end stops rather than collapsing a
    /// pane.
    static func ratio(forDividerCentre position: Double, of divider: PaneDivider, dividerThickness: Double) -> Double {
        let (origin, extent): (Double, Double)
        switch divider.axis {
        case .horizontal: (origin, extent) = (divider.bounds.x, divider.bounds.width)
        case .vertical: (origin, extent) = (divider.bounds.y, divider.bounds.height)
        }
        let available = max(0, extent - dividerThickness)
        guard available > 0 else { return clampRatio(0.5) }
        return clampRatio((position - origin - dividerThickness / 2) / available)
    }

    /// The subtree at `path`, or nil when the path runs off a leaf.
    internal func node(at path: SplitPath) -> PaneTree? {
        guard let step = path.steps.first else { return self }
        guard case .split(_, _, let first, let second) = self else { return nil }
        let rest = SplitPath(Array(path.steps.dropFirst()))
        return step == .first ? first.node(at: rest) : second.node(at: rest)
    }

}
