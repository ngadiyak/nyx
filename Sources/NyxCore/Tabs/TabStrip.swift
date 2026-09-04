import Foundation

/// What an unselected tab has to tell the user about: output it produced (a dot) or a bell it rang
/// (a bell glyph). A bell outranks output -- once a tab has rung, the dot has nothing left to say.
public enum TabIndicator: Equatable {
    case none, activity, bell
}

public extension TabIndicator {
    /// The tab produced output. Only an unselected tab can accumulate anything: the user is
    /// already looking at the selected one.
    func afterOutput(isSelected: Bool) -> TabIndicator {
        guard !isSelected else { return .none }
        return self == .bell ? .bell : .activity
    }

    /// The tab rang the bell. The selected tab flashes instead, so it keeps no indicator.
    func afterBell(isSelected: Bool) -> TabIndicator {
        isSelected ? .none : .bell
    }

    /// The user selected the tab, which is what clears both indicators.
    func afterSelection() -> TabIndicator { .none }
}

/// The rules the tab strip runs on, kept apart from the view that draws it: which tab a shortcut
/// picks, which one survives a close, and whether the bar is on screen at all.
///
/// None of this needs AppKit, and all of it is the sort of thing that is wrong by one until it is
/// tested, so it lives here rather than in `TabController`. `PaneDividers` is the same idea for
/// split geometry.
public enum TabStrip {
    /// `auto` is worth the vertical space only once there is a choice to make.
    public static func isBarVisible(_ visibility: TabBarVisibility, tabCount: Int) -> Bool {
        switch visibility {
        case .always: return true
        case .never: return false
        case .auto: return tabCount > 1
        }
    }

    /// The number behind each of the nine tab-selection actions. Keeping the mapping next to
    /// `index(forCommandNumber:tabCount:)` gives the "⌘9 is the last tab" rule exactly one home,
    /// rather than the action list and the index rule each knowing half of it.
    public static func commandNumber(for action: TerminalAction) -> Int? {
        switch action {
        case .tab1: return 1
        case .tab2: return 2
        case .tab3: return 3
        case .tab4: return 4
        case .tab5: return 5
        case .tab6: return 6
        case .tab7: return 7
        case .tab8: return 8
        case .tab9: return 9
        default: return nil
        }
    }

    /// The tab ⌘1…⌘9 selects. ⌘9 is the *last* tab however many there are -- which is the same
    /// thing as the ninth only when there are exactly nine -- and a number past the end selects
    /// nothing rather than the nearest tab.
    public static func index(forCommandNumber number: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, (1...9).contains(number) else { return nil }
        if number == 9 { return tabCount - 1 }
        let index = number - 1
        return index < tabCount ? index : nil
    }

    /// ⌘⇧] : the next tab, wrapping round to the first.
    public static func next(after selected: Int, tabCount: Int) -> Int {
        guard tabCount > 0 else { return 0 }
        return (normalise(selected, tabCount) + 1) % tabCount
    }

    /// ⌘⇧[ : the previous tab, wrapping round to the last.
    public static func previous(before selected: Int, tabCount: Int) -> Int {
        guard tabCount > 0 else { return 0 }
        return (normalise(selected, tabCount) + tabCount - 1) % tabCount
    }

    /// Which tab is selected once the tab at `closed` goes, given `tabCount` tabs *before* the
    /// close. Closing the selected tab moves the selection to whichever tab takes its place, or to
    /// the new last tab when it had none to its right. nil means nothing is left.
    public static func selectionAfterClosing(_ closed: Int, selected: Int, tabCount: Int) -> Int? {
        guard tabCount > 1 else { return nil }
        if closed < selected { return selected - 1 }
        if closed > selected { return selected }
        return min(closed, tabCount - 2)
    }

    private static func normalise(_ index: Int, _ count: Int) -> Int {
        ((index % count) + count) % count
    }
}

/// How a tab names itself.
public enum TabTitle {
    public static let ellipsis = "\u{2026}"

    /// The title for a tab whose program has never set one with OSC 0/2: the program in the
    /// foreground and where it is running, e.g. `vim — nyx`. Every part is best-effort, so any
    /// piece may be missing and the whole thing may come back empty.
    ///
    /// `home` is passed in rather than read from the environment so this stays a pure function.
    public static func fallback(processName: String?, directory: String?, home: String) -> String {
        let process = processName.map(trimmed) ?? ""
        let place = directory.map { shortDirectory($0, home: home) } ?? ""
        switch (process.isEmpty, place.isEmpty) {
        case (false, false): return "\(process) — \(place)"
        case (false, true): return process
        case (true, false): return place
        case (true, true): return ""
        }
    }

    /// The last component of a path, with the home directory itself shown as `~`. The root is its
    /// own last component.
    private static func shortDirectory(_ path: String, home: String) -> String {
        let trimmedPath = trimmed(path)
        guard !trimmedPath.isEmpty else { return "" }
        if trimmedPath == home || trimmedPath == home + "/" { return "~" }
        let components = trimmedPath.split(separator: "/")
        return components.last.map(String.init) ?? "/"
    }

    /// Shortens `title` until `measure` says it fits in `maxWidth`, cutting characters out of the
    /// middle and leaving an ellipsis behind: the ends of a title -- the program at one end, the
    /// directory at the other -- are the parts worth keeping.
    ///
    /// The caller supplies `measure` because the width of a string is a property of the font the
    /// tab bar draws with, which is not something this module knows about. It must not shrink as
    /// characters are added.
    public static func truncatedInMiddle(_ title: String, maxWidth: Double,
                                         measure: (String) -> Double) -> String {
        guard maxWidth > 0 else { return "" }
        if measure(title) <= maxWidth { return title }
        let characters = Array(title)
        guard characters.count > 1 else { return measure(ellipsis) <= maxWidth ? ellipsis : "" }
        // The largest number of characters that can be kept and still fit. Binary search rather
        // than a scan because `measure` is the expensive part.
        var low = 0, high = characters.count - 1, best = -1
        while low <= high {
            let middle = (low + high) / 2
            if measure(keeping(middle, of: characters)) <= maxWidth {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard best >= 0 else { return "" }
        return keeping(best, of: characters)
    }

    /// `count` characters of `characters`, split between the head and the tail with the odd one
    /// going to the head, joined by an ellipsis.
    private static func keeping(_ count: Int, of characters: [Character]) -> String {
        let head = (count + 1) / 2
        let tail = count - head
        return String(characters[0..<head]) + ellipsis + String(characters[(characters.count - tail)...])
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
