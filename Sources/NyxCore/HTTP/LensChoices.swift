import Foundation

/// Which command's response is being shown through which lens, and what is folded inside it.
///
/// Keyed by `Row.commandID`, for the reason `OutputFolding` is: once the scrollback ring is full
/// every new line shifts every absolute row, and a lens keyed by row would attach itself to
/// whatever moved into that index -- and come off the response it was chosen for. The id stays with
/// the command.
///
/// A sibling of `OutputFolding` rather than part of it: a fold hides rows the terminal already has,
/// while a lens *replaces* them with text Nyx made up. The two can be set on one block, and when
/// they are, the fold wins -- see `Terminal.displayRows`.
public struct LensChoices: Equatable {
    private var lenses: [UInt32: ResponseLens] = [:]
    /// Kept separately from `lenses` so that going back to raw and returning does not lose what the
    /// reader had folded, and so that a fold made on a raw view is still theirs when they choose a
    /// lens.
    private var folds: [UInt32: Set<NodePath>] = [:]

    public init() {}

    /// True when no command has a lens. `displayRows` takes its fast path on this, so it must mean
    /// "nothing to look up" and not "nothing remembered": a leftover fold set is not a lens.
    public var isEmpty: Bool { lenses.isEmpty }

    public var lensedIDs: Set<UInt32> { Set(lenses.keys) }

    /// nil means raw -- the rows as the terminal has them.
    public func lens(of id: UInt32) -> ResponseLens? { lenses[id] }

    /// Choosing a lens for a command that has never had one folds its headers, because what a
    /// person wants from a response is the body. It happens here rather than in `LensRendering`
    /// (which is pure, and would have to be told twice) and rather than at each call site, which is
    /// how one surface ends up opening headers the other closes.
    ///
    /// Only on the *first* choice: a header the reader unfolded stays unfolded through a change of
    /// lens, and through going back to raw and returning. A terminal that re-folds what you opened
    /// is arguing with you.
    public mutating func set(_ lens: ResponseLens?, for id: UInt32) {
        guard id != 0 else { return }
        if let lens {
            if folds[id] == nil { folds[id] = [ResponseLens.headersNode] }
            lenses[id] = lens
        } else {
            lenses[id] = nil
        }
    }

    public func folded(in id: UInt32) -> Set<NodePath> { folds[id] ?? [] }

    public mutating func toggleFold(_ node: NodePath, in id: UInt32) {
        guard id != 0 else { return }
        var set = folds[id] ?? []
        if set.contains(node) { set.remove(node) } else { set.insert(node) }
        folds[id] = set
    }

    /// Drops choices for commands that have left the buffer, so neither map can grow over a
    /// session. The same rule as `OutputFolding.prune`, and called from the same place.
    public mutating func prune(olderThan oldest: UInt32) {
        lenses = lenses.filter { $0.key >= oldest }
        folds = folds.filter { $0.key >= oldest }
    }
}
