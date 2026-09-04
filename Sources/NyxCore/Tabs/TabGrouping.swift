import Foundation

/// A named, coloured run of tabs.
public struct TabGroup: Equatable {
    public let id: Int
    public var name: String
    /// An index into the theme's sixteen ANSI colours, so a group's colour belongs to whatever
    /// theme is in force rather than being a hex value frozen into a config file.
    public var colorIndex: Int
    /// A collapsed group takes one chip in the bar instead of one slot per tab.
    public var isCollapsed: Bool

    public init(id: Int, name: String, colorIndex: Int, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.isCollapsed = isCollapsed
    }
}

/// A tab that has to move, as an index in the strip before and after. The caller applies it to its
/// own tab array -- remove at `from`, insert at `to` -- and to nothing else; the grouping has
/// already applied it to itself.
public struct TabMove: Equatable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// Which tabs belong to which group.
///
/// The invariant that makes everything else possible: **a group's tabs are always contiguous**. A
/// group split in two by an ungrouped tab is not a state the bar should ever have to draw, so it is
/// not a state that can be reached -- adding a tab to a group moves it next to that group, and
/// taking one out of the middle of a run moves it clear. Every operation therefore reports the move
/// it needs, and the caller reorders its tabs to match.
public struct TabGrouping: Equatable {
    /// The group each tab belongs to, by index in the strip; nil where a tab is in no group.
    public private(set) var membership: [Int?]
    /// Every group, in no particular order -- their order in the bar follows their tabs.
    public private(set) var groups: [TabGroup]
    private var nextID: Int

    public init(tabCount: Int = 0) {
        membership = Array(repeating: nil, count: max(0, tabCount))
        groups = []
        nextID = 1
    }

    public var tabCount: Int { membership.count }

    /// The grouping a restored strip has, from what each tab says it belonged to.
    ///
    /// Runs, not names: a group is a *contiguous* run of tabs, so two separated runs claiming the
    /// same name come back as two groups rather than as one group with a hole in it -- which is a
    /// state the bar cannot draw and this type promises never to be in. A tab whose panes could not
    /// be recreated is simply not in the list, which shortens its group's run rather than splitting
    /// it.
    public static func restoring(_ tabs: [(name: String?, colorIndex: Int)]) -> TabGrouping {
        var grouping = TabGrouping(tabCount: tabs.count)
        var index = 0
        while index < tabs.count {
            guard let name = tabs[index].name, !name.isEmpty else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < tabs.count, tabs[end + 1].name == name { end += 1 }
            if let made = grouping.newGroup(named: name, colorIndex: tabs[index].colorIndex,
                                            fromTabAt: index) {
                // No tab has to move: the run is already contiguous, so every `add` lands the tab
                // exactly where it already is.
                for member in stride(from: index + 1, through: end, by: 1) {
                    grouping.add(tabAt: member, toGroup: made.id)
                }
            }
            index = end + 1
        }
        return grouping
    }

    // MARK: - Keeping up with the strip

    public mutating func tabInserted(at index: Int) {
        membership.insert(nil, at: min(max(0, index), membership.count))
    }

    public mutating func tabRemoved(at index: Int) {
        guard membership.indices.contains(index) else { return }
        membership.remove(at: index)
        pruneEmptyGroups()
    }

    /// Several tabs at once, as a batch close does. Removed high index first so the earlier ones
    /// keep meaning what the caller meant.
    public mutating func tabsRemoved(at indices: [Int]) {
        for index in indices.sorted(by: >) where membership.indices.contains(index) {
            membership.remove(at: index)
        }
        pruneEmptyGroups()
    }

    // MARK: - Asking

    public func group(withID id: Int) -> TabGroup? {
        groups.first { $0.id == id }
    }

    public func group(ofTabAt index: Int) -> TabGroup? {
        guard membership.indices.contains(index), let id = membership[index] else { return nil }
        return group(withID: id)
    }

    /// The contiguous run of tabs belonging to a group, or nil when it has none left.
    public func range(ofGroup id: Int) -> Range<Int>? {
        guard let first = membership.firstIndex(where: { $0 == id }),
              let last = membership.lastIndex(where: { $0 == id }) else { return nil }
        return first..<(last + 1)
    }

    /// True when every group's tabs sit together. Always true by construction; a test asserts it
    /// after every operation, which is what makes that claim worth anything.
    public var isContiguous: Bool {
        groups.allSatisfy { group in
            guard let range = range(ofGroup: group.id) else { return true }
            return range.allSatisfy { membership[$0] == group.id }
        }
    }

    // MARK: - Changing

    /// Puts a tab in a new group of its own, leaving whatever group it was in. Returns the group's
    /// id and the move, if it needed one to get clear of its old group.
    @discardableResult
    public mutating func newGroup(named name: String, colorIndex: Int,
                                  fromTabAt index: Int) -> (id: Int, move: TabMove?)? {
        guard membership.indices.contains(index) else { return nil }
        let move = removeFromGroup(tabAt: index)
        let landed = move?.to ?? index
        let id = nextID
        nextID += 1
        groups.append(TabGroup(id: id, name: name, colorIndex: colorIndex))
        membership[landed] = id
        return (id, move)
    }

    /// Adds a tab to an existing group, moving it to the end of that group's run. nil when it is
    /// already there, or when either index means nothing.
    @discardableResult
    public mutating func add(tabAt index: Int, toGroup id: Int) -> TabMove? {
        guard membership.indices.contains(index), group(withID: id) != nil,
              membership[index] != id, let range = range(ofGroup: id) else { return nil }
        // Taking the tab out closes the gap it leaves, so the group it came from stays contiguous
        // without a second move -- which is why one move is always enough.
        let destination = index < range.lowerBound ? range.upperBound - 1 : range.upperBound
        let move = TabMove(from: index, to: destination)
        apply(move)
        membership[destination] = id
        pruneEmptyGroups()
        return move.from == move.to ? nil : move
    }

    /// Takes a tab out of its group. A tab in the middle of a run has to move clear of it, or the
    /// group it left would be split around it; one at either end simply stops belonging.
    @discardableResult
    public mutating func removeFromGroup(tabAt index: Int) -> TabMove? {
        guard membership.indices.contains(index), let id = membership[index],
              let range = range(ofGroup: id) else { return nil }
        let isInside = index > range.lowerBound && index < range.upperBound - 1
        guard isInside else {
            membership[index] = nil
            pruneEmptyGroups()
            return nil
        }
        let move = TabMove(from: index, to: range.upperBound - 1)
        apply(move)
        membership[move.to] = nil
        pruneEmptyGroups()
        return move
    }

    public mutating func rename(group id: Int, to name: String) {
        guard let position = groups.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        groups[position].name = name
    }

    public mutating func setColor(_ colorIndex: Int, forGroup id: Int) {
        guard let position = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[position].colorIndex = colorIndex
    }

    public mutating func toggleCollapsed(group id: Int) {
        guard let position = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[position].isCollapsed.toggle()
    }

    public mutating func setCollapsed(_ collapsed: Bool, forGroup id: Int) {
        guard let position = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[position].isCollapsed = collapsed
    }

    // MARK: - Internals

    private mutating func apply(_ move: TabMove) {
        guard membership.indices.contains(move.from), move.from != move.to else { return }
        let value = membership.remove(at: move.from)
        membership.insert(value, at: min(move.to, membership.count))
    }

    /// A group whose last tab left is gone. Keeping an empty one would leave a header over nothing
    /// and a name in the "Add to Group" menu that adds to nowhere.
    private mutating func pruneEmptyGroups() {
        let live = Set(membership.compactMap { $0 })
        groups.removeAll { !live.contains($0.id) }
    }
}
