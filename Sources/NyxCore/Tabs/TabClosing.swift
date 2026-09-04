import Foundation

/// Closing several tabs at once, and what is selected afterwards.
///
/// `TabStrip.selectionAfterClosing` answers this for a single tab. "Close Others" and "Close to the
/// Right" are the cases where the answer stops being obvious: the tab that survives may be to the
/// left of the selection, the selection itself may be among the casualties, and every index to the
/// right of a closed tab shifts. All of it is off-by-one arithmetic, so none of it belongs in a
/// view.
public enum TabClosing {
    /// Every tab except the one named. Empty for a strip with only that tab in it.
    public static func others(than index: Int, tabCount: Int) -> [Int] {
        guard tabCount > 0, (0..<tabCount).contains(index) else { return [] }
        return (0..<tabCount).filter { $0 != index }
    }

    /// Every tab after the one named.
    public static func toTheRight(of index: Int, tabCount: Int) -> [Int] {
        guard tabCount > 0, (0..<tabCount).contains(index) else { return [] }
        return Array((index + 1)..<tabCount)
    }

    /// Which tab is selected once `closed` has gone, in the indices of the *remaining* strip.
    ///
    /// A selection that survives keeps its tab, at whatever index that tab has moved to. A
    /// selection that is closed lands on the nearest survivor to its right, or on the last one when
    /// there is nothing to its right -- the same instinct `TabStrip.selectionAfterClosing` follows
    /// for a single close. nil means nothing is left.
    public static func selectionAfterClosing(_ closed: [Int], selected: Int, tabCount: Int) -> Int? {
        guard tabCount > 0 else { return nil }
        let doomed = Set(closed.filter { (0..<tabCount).contains($0) })
        let survivors = (0..<tabCount).filter { !doomed.contains($0) }
        guard !survivors.isEmpty else { return nil }
        if let position = survivors.firstIndex(of: selected) { return position }
        if let next = survivors.firstIndex(where: { $0 > selected }) { return next }
        return survivors.count - 1
    }
}

public extension TabTitle {
    /// The name a tab shows, in priority order: a title the user set by hand, then whatever the
    /// program set with OSC 0/2, then the program-and-directory fallback.
    ///
    /// A renamed tab keeps its name while its shell goes on setting titles -- which is the whole
    /// point of renaming one. "Reset Title" clears the custom name and the program's title takes
    /// over again on its next update.
    static func resolve(custom: String?, osc: String, fallback: String) -> String {
        if let custom, !custom.isEmpty { return custom }
        return osc.isEmpty ? fallback : osc
    }
}
