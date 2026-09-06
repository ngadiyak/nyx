import Foundation

/// A selection made over a lensed block's lines rather than over the terminal's rows.
///
/// A separate type from `Selection` because the two are in different coordinate spaces and mixing
/// them would be a bug that only shows up when someone drags across the boundary: a terminal
/// selection is absolute rows and cells of the grid, and these lines are Nyx's own text, which
/// exists nowhere in the buffer. Kept in **Character** offsets rather than cells, because that is
/// what the text is measured in; `columns(onLine:in:)` converts for drawing, since the renderer
/// highlights cells.
public struct LensSelection: Equatable {
    public struct Point: Equatable, Comparable {
        public let line: Int
        public let character: Int

        public init(line: Int, character: Int) {
            self.line = line
            self.character = character
        }

        public static func < (a: Point, b: Point) -> Bool {
            a.line == b.line ? a.character < b.character : a.line < b.line
        }
    }

    /// The block this was dragged over. A selection belongs to one response: the rows around it
    /// belong to the terminal, and a buffer for another block is not what it was made on.
    public let commandID: UInt32
    public var anchor: Point
    public var head: Point

    public init(commandID: UInt32, anchor: Point, head: Point) {
        self.commandID = commandID
        self.anchor = anchor
        self.head = head
    }

    /// Ordered, whichever way the drag went.
    public var range: (start: Point, end: Point) {
        anchor <= head ? (anchor, head) : (head, anchor)
    }

    public var isEmpty: Bool { anchor == head }

    /// The selected characters of one line, clamped to what that line holds, or nil when the line
    /// is outside the selection. This is what a drag past the end of a short line -- which is how
    /// everyone selects -- has to answer.
    public func characters(onLine line: Int, in buffer: LensBuffer) -> Range<Int>? {
        guard buffer.commandID == commandID, let text = buffer.line(line)?.text else { return nil }
        let (start, end) = range
        guard line >= start.line, line <= end.line else { return nil }
        let count = text.count
        let from = line == start.line ? min(max(0, start.character), count) : 0
        let to = line == end.line ? min(max(0, end.character), count) : count
        return from < to ? from ..< to : nil
    }

    /// The same range in cells, which is what the renderer draws: a wide glyph takes two of them.
    public func columns(onLine line: Int, in buffer: LensBuffer) -> Range<Int>? {
        guard let characters = characters(onLine: line, in: buffer) else { return nil }
        return buffer.columnRange(ofCharacters: characters, line: line)
    }

    /// What ⌘C puts on the pasteboard: the lines as they are drawn, cut at both ends.
    public func text(from buffer: LensBuffer) -> String {
        guard buffer.commandID == commandID, !isEmpty else { return "" }
        let (start, end) = range
        var out: [String] = []
        for line in max(0, start.line) ... max(0, end.line) {
            guard buffer.line(line) != nil else { continue }
            guard let characters = characters(onLine: line, in: buffer) else {
                // A line inside the selection with nothing selected on it is a blank line, and a
                // blank line between two selected ones is part of what was selected.
                if line > start.line, line < end.line { out.append("") }
                continue
            }
            let text = Array(buffer.line(line)?.text ?? "")
            out.append(String(text[characters]))
        }
        return out.joined(separator: "\n")
    }
}
