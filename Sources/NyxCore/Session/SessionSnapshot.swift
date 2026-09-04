import Foundation

/// What one pane needs to come back.
///
/// The scrollback travels as an ANSI transcript rather than a grid of cells: restoring is then a
/// `feed` through the parser that already exists, the file is readable, and there is no second
/// representation of a cell to keep in step with the first. See `Transcript`.
public struct PaneSnapshot: Codable, Equatable {
    public let id: Int
    /// Where the shell was, so the restored pane opens in the same place.
    public let workingDirectory: String?
    /// The title the pane was showing, so a restored tab is recognisable before its shell starts.
    public let title: String?
    /// The buffer as ANSI, or nil when scrollback restoring is off.
    public let transcript: String?

    public init(id: Int, workingDirectory: String?, title: String?, transcript: String?) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.title = title
        self.transcript = transcript
    }
}

/// A tab: its pane layout and the panes themselves.
public struct TabSnapshot: Codable, Equatable {
    /// The split tree, flattened -- `PaneTree` is an indirect enum and encodes badly by itself.
    public let layout: PaneLayoutNode
    public let panes: [PaneSnapshot]
    public let focused: Int?
    /// A tab the user renamed keeps its name; nil means the title follows the shell again.
    public let customTitle: String?
    public let groupName: String?
    public let groupColorIndex: Int?

    public init(layout: PaneLayoutNode, panes: [PaneSnapshot], focused: Int?,
                customTitle: String? = nil, groupName: String? = nil, groupColorIndex: Int? = nil) {
        self.layout = layout
        self.panes = panes
        self.focused = focused
        self.customTitle = customTitle
        self.groupName = groupName
        self.groupColorIndex = groupColorIndex
    }
}

public struct WindowSnapshot: Codable, Equatable {
    public let tabs: [TabSnapshot]
    public let selectedTab: Int
    /// In screen points, so a window comes back where it was.
    public let frame: [Double]?

    public init(tabs: [TabSnapshot], selectedTab: Int, frame: [Double]? = nil) {
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.frame = frame
    }
}

/// Everything open, at the moment the application was last asked to remember it.
///
/// "Endless re-setting up of workspaces after a reboot" is the complaint people make about
/// terminals more than any other. This is what closes it.
public struct SessionSnapshot: Codable, Equatable {
    /// Bumped when the shape changes. A snapshot from a newer version is ignored rather than
    /// half-read: coming back to no windows is recoverable, coming back to a corrupted layout is
    /// confusing in a way that is hard to undo.
    public static let currentVersion = 1

    public let version: Int
    public let windows: [WindowSnapshot]
    /// When it was taken, so a very old snapshot can be discarded rather than restoring a workspace
    /// from last month.
    public let savedAt: Date

    public init(windows: [WindowSnapshot], savedAt: Date = Date()) {
        self.version = SessionSnapshot.currentVersion
        self.windows = windows
        self.savedAt = savedAt
    }

    public var isEmpty: Bool { windows.allSatisfy { $0.tabs.isEmpty } }

    /// Whether this snapshot should be restored at all.
    ///
    /// A snapshot from a future version cannot be read safely; one from long ago describes a day's
    /// work nobody remembers starting, and silently reopening twelve tabs from last month is worse
    /// than opening one fresh window.
    public func isUsable(now: Date = Date(), maximumAge: TimeInterval = 7 * 24 * 3600) -> Bool {
        guard version == SessionSnapshot.currentVersion, !isEmpty else { return false }
        let age = now.timeIntervalSince(savedAt)
        return age >= 0 && age <= maximumAge
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Seconds rather than ISO8601: that format has no sub-second field, so a date silently
        // lost its fraction and a snapshot did not compare equal to itself after a round trip.
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    /// Reads a snapshot back, or nil when the file is missing, truncated or from another version.
    /// A failure here must never stop the terminal starting.
    public static func decoded(from data: Data) -> SessionSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SessionSnapshot.self, from: data)
    }
}

/// `PaneTree` flattened into something `Codable` handles well.
///
/// The tree is an indirect enum with associated values; hand-writing its coding is more code than
/// this, and this shape is also what a person sees if they open the file.
public indirect enum PaneLayoutNode: Codable, Equatable {
    case leaf(Int)
    case split(vertical: Bool, ratio: Double, first: PaneLayoutNode, second: PaneLayoutNode)
}

public extension PaneLayoutNode {
    init(_ tree: PaneTree) {
        switch tree {
        case .leaf(let id):
            self = .leaf(id.value)
        case .split(let axis, let ratio, let first, let second):
            self = .split(vertical: axis == .vertical, ratio: ratio,
                          first: PaneLayoutNode(first), second: PaneLayoutNode(second))
        }
    }

    /// Back into a tree, remapping pane ids through `idFor` -- the restored panes are new objects
    /// with new ids, and a layout still pointing at the old ones would address nothing.
    func tree(idFor: (Int) -> PaneID?) -> PaneTree? {
        switch self {
        case .leaf(let id):
            return idFor(id).map { .leaf($0) }
        case .split(let vertical, let ratio, let first, let second):
            let left = first.tree(idFor: idFor)
            let right = second.tree(idFor: idFor)
            // A pane that could not be recreated collapses to its sibling, exactly as closing it
            // would -- better than refusing to restore the whole window because one shell is gone.
            switch (left, right) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?):
                return .split(axis: vertical ? .vertical : .horizontal,
                              ratio: PaneTree.clampRatio(ratio), first: a, second: b)
            }
        }
    }

    /// Every pane id the layout mentions, in order.
    var paneIDs: [Int] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second): return first.paneIDs + second.paneIDs
        }
    }
}
