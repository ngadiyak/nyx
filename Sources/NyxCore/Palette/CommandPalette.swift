import Foundation

/// What choosing a palette row does.
public enum PaletteItemKind: Equatable {
    case action(TerminalAction)
    /// A theme name, written back into the config file.
    case theme(String)
    /// A tab, by its index in the window's strip.
    case tab(Int)
    /// A configured quick action, by its index in `config.quickActions`.
    case quickAction(Int)
    /// A session on a paired device: attach to it. `sessionID` is empty for the placeholder row an
    /// offline device shows, which nothing can attach to.
    case remoteSession(deviceID: String, sessionID: String)
}

/// One row of the command palette.
public struct PaletteItem: Equatable {
    /// The left-hand text, and the only part whose matched characters are highlighted.
    public let title: String
    /// The right-hand text: an action's chord, or what kind of thing this is.
    public let detail: String
    /// What the fuzzy matcher actually searches. It carries the category as well as the title, so
    /// typing `theme` finds `dracula` -- a palette where you have to already know the answer's name
    /// is a list, not a search.
    public let searchText: String
    public let kind: PaletteItemKind

    public init(title: String, detail: String, searchText: String? = nil, kind: PaletteItemKind) {
        self.title = title
        self.detail = detail
        self.searchText = searchText ?? title
        self.kind = kind
    }

    public static func action(_ action: TerminalAction, chord: String?) -> PaletteItem {
        PaletteItem(title: action.title, detail: chord ?? "",
                    searchText: "\(action.title) \(action.configName)", kind: .action(action))
    }

    public static func theme(_ name: String) -> PaletteItem {
        PaletteItem(title: name, detail: "Theme", searchText: "\(name) theme", kind: .theme(name))
    }

    /// A quick action. A `toggle` reads as what pressing it would *do* -- "Stop Caffeine" while it
    /// is running -- because a palette row is a verb, and one that says "Caffeine" leaves the user
    /// guessing which way it will go.
    public static func quickAction(_ action: QuickAction, index: Int, isRunning: Bool) -> PaletteItem {
        let title = action.kind == .toggle
            ? (isRunning ? "Stop \(action.name)" : "Start \(action.name)")
            : action.name
        return PaletteItem(title: title, detail: "Quick Action",
                           searchText: "\(title) \(action.name) quick action",
                           kind: .quickAction(index))
    }

    public static func tab(_ index: Int, title: String) -> PaletteItem {
        let shown = title.isEmpty ? "Tab \(index + 1)" : title
        return PaletteItem(title: shown, detail: "Tab", searchText: "\(shown) tab", kind: .tab(index))
    }

    /// One row of `RemoteCatalogue.paletteItems`. Built there (with `title`/`detail` already
    /// formatted) rather than from raw `RemoteSessionInfo` fields here, because the formatting --
    /// relative time, `~` shortening -- needs `now` and the local home directory, neither of which
    /// this module should have to thread through.
    public static func remoteSession(deviceID: String, sessionID: String, title: String, detail: String) -> PaletteItem {
        PaletteItem(title: title, detail: detail, searchText: "\(title) remote",
                    kind: .remoteSession(deviceID: deviceID, sessionID: sessionID))
    }
}

/// A matched row: the item, and the characters of its *title* the query hit.
public struct PaletteResult: Equatable {
    public let item: PaletteItem
    /// Character offsets into `item.title`. Offsets that fell in the category rather than the title
    /// are dropped, so nothing is highlighted outside the text the user can see.
    public let positions: [Int]

    public init(item: PaletteItem, positions: [Int]) {
        self.item = item
        self.positions = positions
    }
}

/// Everything the `⌘⇧P` panel does apart from drawing: what is in the list, how typing filters it,
/// and where ↑/↓ go.
public struct CommandPalette: Equatable {
    public private(set) var items: [PaletteItem]
    public private(set) var query = ""
    public private(set) var results: [PaletteResult] = []
    /// Index into `results`, never out of range: it is 0 for an empty list, so `selected` is the
    /// only thing a caller has to nil-check.
    public private(set) var selection = 0

    public init(items: [PaletteItem]) {
        self.items = items
        rank()
    }

    /// The row `⏎` runs, or nil when nothing matched.
    public var selected: PaletteItem? {
        results.indices.contains(selection) ? results[selection].item : nil
    }

    public mutating func setQuery(_ newQuery: String) {
        query = newQuery
        rank()
    }

    /// ↑/↓. Wraps at both ends, so holding ↓ walks the list round rather than sticking at the
    /// bottom, and ↑ from the first row reaches the last without scrolling through everything.
    public mutating func moveSelection(by delta: Int) {
        guard !results.isEmpty else {
            selection = 0
            return
        }
        let count = results.count
        selection = ((selection + delta) % count + count) % count
    }

    private mutating func rank() {
        let ranked = FuzzySearch.rank(query, items, by: \.searchText)
        results = ranked.map { item, match in
            PaletteResult(item: item, positions: match.positions.filter { $0 < item.title.count })
        }
        // Typing narrows the list under whatever was selected, so the selection goes back to the
        // best answer rather than to whichever row happens to now sit at the old index.
        selection = 0
    }
}

/// Building the palette's list out of what a window knows.
///
/// Here rather than in the app so the order -- actions, quick actions, themes, then tabs -- and the
/// way each kind is labelled are pinned by a test instead of by whoever last edited the view.
public enum PaletteSource {
    public static func items(actions: [TerminalAction], chord: (TerminalAction) -> String?,
                             quickActions: [(action: QuickAction, isRunning: Bool)] = [],
                             themes: [String], tabTitles: [String],
                             remote: [PaletteItem] = []) -> [PaletteItem] {
        actions.map { PaletteItem.action($0, chord: chord($0)) }
            + quickActions.enumerated().map {
                PaletteItem.quickAction($0.element.action, index: $0.offset,
                                        isRunning: $0.element.isRunning)
            }
            + themes.map(PaletteItem.theme)
            + tabTitles.enumerated().map { PaletteItem.tab($0.offset, title: $0.element) }
            + remote
    }
}
