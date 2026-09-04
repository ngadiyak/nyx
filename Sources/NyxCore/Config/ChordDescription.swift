import Foundation

/// A chord written the way macOS writes it, for anywhere a shortcut has to be *shown* rather than
/// matched -- the command palette's right-hand column today.
///
/// A menu item gets its shortcut drawn by AppKit from a key equivalent and a modifier mask; a
/// palette row is drawn by us, and has to spell the same chord the same way. Doing it here rather
/// than in the view keeps the two from disagreeing, and makes the order of the symbols -- ⌃⌥⇧⌘,
/// which is the order every Mac menu uses -- something a test can pin.
public extension KeyBinding {
    var displayName: String {
        var text = ""
        if modifiers.contains(.ctrl) { text += "⌃" }
        if modifiers.contains(.alt) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.cmd) { text += "⌘" }
        return text + Key.displayName(key)
    }
}

public extension Key {
    /// The key on its own, without modifiers.
    static func displayName(_ key: Key) -> String {
        switch key {
        case .char(let scalar): return String(scalar).uppercased()
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .insert: return "Ins"
        case .delete: return "⌦"
        case .backspace: return "⌫"
        case .tab: return "⇥"
        case .enter: return "↩"
        case .escape: return "⎋"
        case .f(let n): return "F\(n)"
        }
    }
}
