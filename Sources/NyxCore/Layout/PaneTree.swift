import Foundation

/// The axis along which a split divides its bounds. `.horizontal` means the two children sit
/// side by side (dividing width); `.vertical` means they stack (dividing height).
public enum SplitAxis: Equatable {
    case horizontal
    case vertical
}

/// The four directions focus can move between panes.
public enum FocusDirection: Equatable {
    case left, right, up, down
}

/// Opaque identifier for a pane. The tree model knows nothing about what a pane actually
/// displays; the view layer maps `PaneID`s to its own objects.
public struct PaneID: Hashable, Equatable {
    public let value: Int
    public init(_ value: Int) {
        self.value = value
    }
}

/// A plain rectangle, independent of AppKit/CoreGraphics so `NyxCore` stays free of those
/// imports. The view layer converts this to `NSRect` when it needs one.
public struct PaneRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A binary tree of panes. Leaves carry an opaque identifier so the view layer can map them to
/// its own objects; the model itself knows nothing about views.
///
/// Ratios are clamped to `0.05...0.95` everywhere a split is created or resized, so a divider
/// drag (or a long run of resize deltas) can never collapse a pane to zero or negative size.
public indirect enum PaneTree: Equatable {
    case leaf(PaneID)
    case split(axis: SplitAxis, ratio: Double, first: PaneTree, second: PaneTree)

    /// The bounds every clamped ratio is kept within.
    static let ratioBounds = 0.05...0.95

    static func clampRatio(_ ratio: Double) -> Double {
        min(max(ratio, ratioBounds.lowerBound), ratioBounds.upperBound)
    }
}

public extension PaneTree {
    /// Every pane in left-to-right, top-to-bottom order (i.e. a pre-order walk: `first` before
    /// `second`).
    var panes: [PaneID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.panes + second.panes
        }
    }

    /// Replaces `target` with a split of itself and `new`, along `axis`, `new` second. If
    /// `target` is not present, the tree is returned unchanged.
    func splitting(_ target: PaneID, axis: SplitAxis, with new: PaneID, ratio: Double) -> PaneTree {
        switch self {
        case .leaf(let id):
            if id == target {
                return .split(axis: axis, ratio: PaneTree.clampRatio(ratio), first: self, second: .leaf(new))
            }
            return self
        case .split(let a, let r, let first, let second):
            return .split(
                axis: a,
                ratio: r,
                first: first.splitting(target, axis: axis, with: new, ratio: ratio),
                second: second.splitting(target, axis: axis, with: new, ratio: ratio)
            )
        }
    }

    /// Removes `target`; the sibling subtree takes the place of the split that contained it,
    /// keeping the grandparent's axis and ratio. Returns nil only when `target` was the last
    /// leaf in the tree. Returns the tree unchanged if `target` is not present.
    func removing(_ target: PaneID) -> PaneTree? {
        var found = false
        return removing(target, found: &found)
    }

    /// Implementation detail of `removing(_:)`: also reports (via `found`) whether `target` was
    /// present, so an unchanged sibling can be distinguished from "not found" without relying on
    /// structural equality (two distinct subtrees could otherwise look alike).
    private func removing(_ target: PaneID, found: inout Bool) -> PaneTree? {
        switch self {
        case .leaf(let id):
            if id == target {
                found = true
                return nil
            }
            return self
        case .split(let axis, let ratio, let first, let second):
            var foundInFirst = false
            let removedFirst = first.removing(target, found: &foundInFirst)
            if foundInFirst {
                found = true
                guard let removedFirst else { return second }
                return .split(axis: axis, ratio: ratio, first: removedFirst, second: second)
            }
            var foundInSecond = false
            let removedSecond = second.removing(target, found: &foundInSecond)
            if foundInSecond {
                found = true
                guard let removedSecond else { return first }
                return .split(axis: axis, ratio: ratio, first: first, second: removedSecond)
            }
            return self
        }
    }

    /// Frames for every pane inside `bounds`, given a divider thickness. The divider's thickness
    /// is subtracted from the axis being divided *before* the ratio is applied, so two panes at
    /// ratio 0.5 get equal-sized halves rather than the divider eating unevenly into one side.
    /// Extents are clamped at zero rather than going negative when bounds are smaller than the
    /// dividers require.
    func layout(in bounds: PaneRect, dividerThickness: Double) -> [PaneID: PaneRect] {
        var result: [PaneID: PaneRect] = [:]
        layout(in: bounds, dividerThickness: dividerThickness, into: &result)
        return result
    }

    private func layout(in bounds: PaneRect, dividerThickness: Double, into result: inout [PaneID: PaneRect]) {
        switch self {
        case .leaf(let id):
            result[id] = bounds
        case .split(let axis, let ratio, let first, let second):
            let (firstBounds, secondBounds) = PaneTree.splitBounds(bounds, axis: axis, ratio: ratio, dividerThickness: dividerThickness)
            first.layout(in: firstBounds, dividerThickness: dividerThickness, into: &result)
            second.layout(in: secondBounds, dividerThickness: dividerThickness, into: &result)
        }
    }

    /// The bounds `layout` gives the two children of a split. Internal rather than private because
    /// `PaneDividers` places each divider in the gap this leaves between the two children: the
    /// rounding here and the divider's position have to be the same arithmetic, or they drift apart
    /// by a pixel at some ratios. `theDividerAlwaysSitsExactlyBetweenTheTwoPanes` pins that.
    static func splitBounds(_ bounds: PaneRect, axis: SplitAxis, ratio: Double, dividerThickness: Double) -> (PaneRect, PaneRect) {
        switch axis {
        case .horizontal:
            let available = max(0, bounds.width - dividerThickness)
            let firstWidth = (available * ratio).rounded()
            let secondWidth = max(0, available - firstWidth)
            let first = PaneRect(x: bounds.x, y: bounds.y, width: firstWidth, height: bounds.height)
            let second = PaneRect(
                x: min(bounds.x + firstWidth + dividerThickness, bounds.x + bounds.width),
                y: bounds.y,
                width: secondWidth,
                height: bounds.height
            )
            return (first, second)
        case .vertical:
            let available = max(0, bounds.height - dividerThickness)
            let firstHeight = (available * ratio).rounded()
            let secondHeight = max(0, available - firstHeight)
            let first = PaneRect(x: bounds.x, y: bounds.y, width: bounds.width, height: firstHeight)
            let second = PaneRect(
                x: bounds.x,
                y: min(bounds.y + firstHeight + dividerThickness, bounds.y + bounds.height),
                width: bounds.width,
                height: secondHeight
            )
            return (first, second)
        }
    }

    /// The pane to focus when moving `direction` from `from`, or nil at the edge. This is
    /// geometric, not structural: the whole tree is laid out, then the candidate whose frame
    /// lies on the correct side of `from`'s frame -- and whose perpendicular span overlaps
    /// `from`'s the most -- wins. That handles a sibling subtree with several leaves correctly,
    /// unlike a purely structural tree walk.
    func neighbour(of from: PaneID, direction: FocusDirection, in bounds: PaneRect, dividerThickness: Double) -> PaneID? {
        let frames = layout(in: bounds, dividerThickness: dividerThickness)
        guard let sourceFrame = frames[from] else { return nil }

        var best: (id: PaneID, distance: Double, overlap: Double)?
        for (candidateID, candidateFrame) in frames where candidateID != from {
            guard let distance = signedDistance(from: sourceFrame, to: candidateFrame, direction: direction) else { continue }
            let overlap = perpendicularOverlap(sourceFrame, candidateFrame, direction: direction)
            guard overlap > 0 else { continue }
            if let current = best {
                if distance < current.distance || (distance == current.distance && overlap > current.overlap) {
                    best = (candidateID, distance, overlap)
                }
            } else {
                best = (candidateID, distance, overlap)
            }
        }
        return best?.id
    }

    /// Distance from `source` to `candidate` along `direction`, measured edge-to-edge; nil if
    /// `candidate` is not on the correct side of `source`.
    private func signedDistance(from source: PaneRect, to candidate: PaneRect, direction: FocusDirection) -> Double? {
        switch direction {
        case .right:
            let d = candidate.x - (source.x + source.width)
            return candidate.x >= source.x + source.width ? d : nil
        case .left:
            let d = source.x - (candidate.x + candidate.width)
            return candidate.x + candidate.width <= source.x ? d : nil
        case .down:
            let d = candidate.y - (source.y + source.height)
            return candidate.y >= source.y + source.height ? d : nil
        case .up:
            let d = source.y - (candidate.y + candidate.height)
            return candidate.y + candidate.height <= source.y ? d : nil
        }
    }

    /// How much `source` and `candidate` overlap along the axis perpendicular to `direction`.
    private func perpendicularOverlap(_ source: PaneRect, _ candidate: PaneRect, direction: FocusDirection) -> Double {
        switch direction {
        case .left, .right:
            let lo = max(source.y, candidate.y)
            let hi = min(source.y + source.height, candidate.y + candidate.height)
            return max(0, hi - lo)
        case .up, .down:
            let lo = max(source.x, candidate.x)
            let hi = min(source.x + source.width, candidate.x + candidate.width)
            return max(0, hi - lo)
        }
    }

    /// Adjusts the ratio of the split that separates `pane` from its neighbour in `direction`.
    /// Walks down to find the nearest ancestor split whose axis matches `direction` and whose
    /// subtree containing `pane` sits on the appropriate side, then nudges its ratio by `delta`
    /// (positive delta grows the side `pane` is on), clamped to `0.05...0.95`.
    func resizing(_ pane: PaneID, direction: FocusDirection, by delta: Double) -> PaneTree {
        guard let axis = matchingAxis(for: direction) else { return self }
        let (result, _) = applyResize(pane: pane, axis: axis, direction: direction, delta: delta)
        return result.tree
    }

    private func matchingAxis(for direction: FocusDirection) -> SplitAxis? {
        switch direction {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// The outcome of walking one subtree looking for `pane`.
    ///
    /// `handled` is what keeps a resize local. A pane's neighbour in `direction` is separated from
    /// it by exactly one split, and only that split's ratio may move. Once some level has moved it,
    /// every ancestor must rebuild itself unchanged -- otherwise a chain like `A | B | C` moves the
    /// outer divider too and shrinks `C`, which is not `A`'s neighbour at all.
    private struct ResizeOutcome {
        var tree: PaneTree
        var handled: Bool
    }

    /// Returns the outcome of resizing within this subtree, and whether `pane` was found in it.
    private func applyResize(
        pane: PaneID, axis: SplitAxis, direction: FocusDirection, delta: Double
    ) -> (ResizeOutcome, Bool) {
        switch self {
        case .leaf(let id):
            return (ResizeOutcome(tree: self, handled: false), id == pane)

        case .split(let splitAxis, let ratio, let first, let second):
            let (firstOutcome, foundInFirst) = first.applyResize(
                pane: pane, axis: axis, direction: direction, delta: delta)
            if foundInFirst {
                // `pane` sits in `first`, so `second` lies to its right (horizontal) or below it
                // (vertical). This split therefore separates `pane` from a neighbour only when the
                // resize points that way; a `.left`/`.up` resize belongs to some ancestor where
                // this whole subtree is the *second* child, so pass it up untouched.
                let separates = splitAxis == axis && (direction == .right || direction == .down)
                if firstOutcome.handled || !separates {
                    let rebuilt = PaneTree.split(axis: splitAxis, ratio: ratio,
                                                 first: firstOutcome.tree, second: second)
                    return (ResizeOutcome(tree: rebuilt, handled: firstOutcome.handled), true)
                }
                // Growing `first` towards `second` means a larger ratio.
                let moved = PaneTree.split(axis: splitAxis, ratio: PaneTree.clampRatio(ratio + delta),
                                           first: firstOutcome.tree, second: second)
                return (ResizeOutcome(tree: moved, handled: true), true)
            }

            let (secondOutcome, foundInSecond) = second.applyResize(
                pane: pane, axis: axis, direction: direction, delta: delta)
            if foundInSecond {
                // Mirror image: `first` lies to the left of / above `pane`, so this split separates
                // `pane` from a neighbour only for a `.left`/`.up` resize.
                let separates = splitAxis == axis && (direction == .left || direction == .up)
                if secondOutcome.handled || !separates {
                    let rebuilt = PaneTree.split(axis: splitAxis, ratio: ratio,
                                                 first: first, second: secondOutcome.tree)
                    return (ResizeOutcome(tree: rebuilt, handled: secondOutcome.handled), true)
                }
                // Growing `second` towards `first` means a smaller ratio.
                let moved = PaneTree.split(axis: splitAxis, ratio: PaneTree.clampRatio(ratio - delta),
                                           first: first, second: secondOutcome.tree)
                return (ResizeOutcome(tree: moved, handled: true), true)
            }

            return (ResizeOutcome(tree: self, handled: false), false)
        }
    }

}
