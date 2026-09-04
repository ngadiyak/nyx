/// The state machine behind mouse-driven selection: which selection a press produces, how a drag
/// grows it, and when it goes away.
///
/// It lives here rather than in the view because it is the part worth testing. The view is left
/// with nothing but the conversion from an `NSEvent` to a cell and a call to one of these methods.
public struct SelectionController {
    /// Word characters are everything that is not a separator; the defaults are the punctuation a
    /// shell command line puts around paths and arguments, so double-clicking a path takes the path.
    public static let defaultSeparators: Set<Character> = Set(" ()[]{}'\"`,;:|<>")

    public private(set) var selection: Selection?
    /// True between `begin` and `end`, so the caller knows whether to route a drag here.
    public private(set) var isDragging = false

    /// The cell the press landed on, before word or line expansion. Expansion has to start from it
    /// on every drag step: expanding the stored selection instead would ratchet outwards and never
    /// shrink when the drag came back.
    private var anchor: AbsolutePosition?
    private var mode: SelectionMode = .character
    /// The terminal's coordinate-space generation when the selection was made.
    private var generation: UInt64 = 0

    public init() {}

    /// A press. `clickCount` 1/2/3 picks character/word/line; `block` forces block mode regardless,
    /// which is what the Option modifier does. Returns whether the selection changed.
    @discardableResult
    public mutating func begin(at position: AbsolutePosition, clickCount: Int, block: Bool,
                               in terminal: Terminal,
                               separators: Set<Character> = defaultSeparators) -> Bool {
        if block {
            mode = .block
        } else {
            switch clickCount {
            case ..<2: mode = .character
            case 2: mode = .word
            default: mode = .line
            }
        }
        anchor = position
        isDragging = true
        generation = terminal.scrollbackGeneration
        return set(Self.expand(anchor: position, head: position, mode: mode, in: terminal, separators: separators))
    }

    /// Moves the head of an in-progress drag. Word and line modes re-expand both ends every time,
    /// so dragging in those modes keeps taking whole words or whole rows.
    @discardableResult
    public mutating func drag(to position: AbsolutePosition, in terminal: Terminal,
                              separators: Set<Character> = defaultSeparators) -> Bool {
        guard isDragging, let anchor else { return false }
        return set(Self.expand(anchor: anchor, head: position, mode: mode, in: terminal, separators: separators))
    }

    /// Ends the drag. A press that never moved leaves an empty selection, which is the gesture for
    /// "deselect": drop it, so that a non-nil `selection` always means something is selected.
    @discardableResult
    public mutating func end() -> Bool {
        guard isDragging else { return false }
        isDragging = false
        anchor = nil
        guard selection?.isEmpty ?? false else { return false }
        selection = nil
        return true
    }

    /// Drops the selection if the terminal has thrown away the coordinate space it was anchored
    /// in — a cleared scrollback, a reset, an alternate-screen swap. Absolute rows stay in range
    /// across all three, so without this the same `Selection` quietly starts addressing unrelated
    /// content instead of disappearing.
    @discardableResult
    public mutating func invalidateIfStale(_ terminal: Terminal) -> Bool {
        guard terminal.scrollbackGeneration != generation else { return false }
        generation = terminal.scrollbackGeneration
        return clear()
    }

    /// Drops the selection and any drag in progress. Typing does this.
    @discardableResult
    public mutating func clear() -> Bool {
        guard selection != nil || isDragging else { return false }
        selection = nil
        anchor = nil
        isDragging = false
        return true
    }

    private mutating func set(_ new: Selection) -> Bool {
        guard selection != new else { return false }
        selection = new
        return true
    }

    private static func expand(anchor: AbsolutePosition, head: AbsolutePosition, mode: SelectionMode,
                               in terminal: Terminal, separators: Set<Character>) -> Selection {
        switch mode {
        case .character, .block:
            return Selection(anchor: anchor, head: head, mode: mode)
        case .word:
            let forward = anchor <= head
            let a = wordSpan(anchor, in: terminal, separators: separators)
            let h = wordSpan(head, in: terminal, separators: separators)
            return Selection(anchor: AbsolutePosition(row: anchor.row, col: forward ? a.lowerBound : a.upperBound),
                             head: AbsolutePosition(row: head.row, col: forward ? h.upperBound : h.lowerBound),
                             mode: .word)
        case .line:
            let forward = anchor.row <= head.row
            return Selection(anchor: AbsolutePosition(row: anchor.row, col: forward ? 0 : terminal.cols),
                             head: AbsolutePosition(row: head.row, col: forward ? terminal.cols : 0),
                             mode: .line)
        }
    }

    /// The word around a position, or the bare cell when there is no word there, so that a
    /// double-click on a blank selects nothing instead of swallowing the run of blanks around it.
    private static func wordSpan(_ p: AbsolutePosition, in terminal: Terminal,
                                 separators: Set<Character>) -> Range<Int> {
        terminal.wordRange(at: p, separators: separators) ?? p.col..<p.col
    }
}
