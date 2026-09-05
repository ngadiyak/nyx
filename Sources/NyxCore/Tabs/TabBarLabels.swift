import Foundation

/// What each control in the tab bar is called.
///
/// The bar draws itself: there are no subviews, so there is nothing AppKit can name on its own and
/// every control there is a rectangle that would otherwise reach VoiceOver as nothing at all. The
/// words are here rather than in the view because two things need them -- the tooltip under the
/// pointer and the accessibility label -- and a control that says one thing to a pointer and
/// another to a screen reader is a control with two different names.
///
/// The accessibility variants are the same words plus the state a sighted user reads off the
/// picture: which tab of how many, that a toggle is running, that a group is collapsed and how
/// many tabs it is standing in for. A label that says "Caffeine" when the button will stop
/// something is worse than no label.
public enum TabBarLabels {
    public static let bar = "Tabs"
    public static let newTab = "New tab (⌘T)"
    public static let tabList = "All tabs (⌘⇧P)"
    public static let addQuickAction = "Add a button for a command you run often"

    /// The chip standing in for the buttons the bar was too narrow to draw. Says how many, because
    /// a button that is simply absent looks like a button that broke.
    public static func moreQuickActions(count: Int) -> String {
        count == 1 ? "1 more button — no room for it here"
                   : "\(count) more buttons — no room for them here"
    }

    public static func close(tabTitled title: String?) -> String {
        guard let title, !title.isEmpty else { return "Close tab" }
        return "Close \(title) (⌘W)"
    }

    /// What clicking a group's chip or header will do. Already state-dependent, because that is
    /// the only useful thing to say about a control that toggles.
    public static func group(named name: String, isCollapsed: Bool) -> String {
        isCollapsed ? "Expand “\(name)”" : "Collapse “\(name)”"
    }

    /// A quick action's button: what pressing it does, and to what. The command itself is included
    /// because pressing a button must never be a guess about what it runs.
    public static func quickAction(named name: String, kind: QuickActionKind, command: String,
                                   isRunning: Bool) -> String {
        let what: String
        switch kind {
        case .send: what = "types"
        case .run: what = "opens a tab and runs"
        case .toggle: what = isRunning ? "stops" : "runs in the background"
        }
        return "\(name) — \(what): \(command)"
    }

    // MARK: - The same things, said to a screen reader

    /// A tab: what it is called, where it is in the strip, and what its indicator dot means. The
    /// position is what the drawn bar shows and a label alone cannot.
    /// `badge` is the chip a remote tab carries -- "observer" or "writer". It is drawn, so a screen
    /// reader has no other way to learn the one thing that decides whether typing into this tab
    /// reaches anything at all.
    public static func tab(titled title: String, position: Int, of count: Int,
                           indicator: TabIndicator, badge: String? = nil) -> String {
        var out = "\(title), tab \(position) of \(count)"
        switch indicator {
        case .none: break
        case .activity: out += ", new output"
        case .bell: out += ", bell rang"
        }
        if let badge, !badge.isEmpty { out += ", \(badge)" }
        return out
    }

    /// A collapsed group's chip stands in for tabs that are not on screen, so it says how many --
    /// otherwise it is a name with no indication that anything is hidden behind it.
    public static func collapsedGroup(named name: String, tabCount: Int) -> String {
        let tabs = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        return "\(name), group of \(tabs), collapsed. \(group(named: name, isCollapsed: true))"
    }

    public static func expandedGroup(named name: String) -> String {
        "\(name), group, expanded. \(group(named: name, isCollapsed: false))"
    }

    /// A running toggle says so outright. "Caffeine — stops: caffeinate -d" only implies it, and
    /// implication is exactly what a screen reader cannot see.
    public static func quickActionState(named name: String, kind: QuickActionKind, command: String,
                                        isRunning: Bool) -> String {
        let base = quickAction(named: name, kind: kind, command: command, isRunning: isRunning)
        return isRunning ? base + ", running now" : base
    }
}
