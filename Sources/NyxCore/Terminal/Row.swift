import Foundation

public struct Row: Equatable {
    public var cells: [Cell]
    /// True when the line continues on the next row (soft wrap). Used by reflow and selection.
    public var wrapped = false
    /// Maintained on every mutation but not consumed yet: the renderer rebuilds every row each
    /// frame, and `Terminal.clearDirty()` (called by the view after a frame) just resets the flags.
    /// This is the groundwork for the per-row partial redraw planned for phase 2.
    public var dirty = true
    /// OSC 133 marks as flags: 1 = prompt start (A), 2 = input start (B), 4 = output start (C),
    /// 8 = end (D). Flags rather than one value because a single row routinely carries A and B
    /// together, and the D of the previous command alongside the A of the next.
    /// `PromptMarks` is the typed view of it.
    public var promptMark: UInt8 = 0
    /// The status a command's own prompt row ends up carrying, written when its `D` arrives.
    ///
    /// The gutter draws a mark beside each visible prompt, so it needs the status *there*. Searching
    /// forward for the `D` at draw time meant walking to the end of the buffer on every frame
    /// whenever the command was still running -- measured at 0.48 ms per frame over 2,000 rows,
    /// under the session lock, contending with the PTY reader. Recording it once, when the mark
    /// arrives, makes drawing the gutter cost only the rows on screen.
    public var commandStatus: Int32?
    /// The column the user's typing starts at, from `OSC 133 ; B`. Without it the prompt and the
    /// command share a row and there is no way to say where one ends -- which is what "edit what I
    /// have typed" needs to know.
    public var inputStartColumn: Int?
    /// The exit status from `OSC 133 ; D ; <status>`, on the row carrying the D mark. nil when the
    /// shell reported the end of a command without a status, or on any other row.
    public var exitStatus: Int32?

    public init(cols: Int, fill: Cell = Cell()) {
        cells = Array(repeating: fill, count: cols)
    }

    /// Turns this row back into a blank one, reusing the cell storage when it is already the right
    /// size. Scrolling recycles rows this way instead of allocating a fresh cell array per line.
    mutating func reset(cols: Int, fill: Cell) {
        if cells.count == cols {
            cells.withUnsafeMutableBufferPointer { b in
                guard let p = b.baseAddress else { return }
                // `Cell` is a trivial 20-byte value whose all-zero bit pattern is exactly `Cell()`,
                // so the common case (erase with the default background) is a plain memset, which
                // beats a 200-iteration store loop of an awkwardly sized struct.
                if fill == Cell() {
                    memset(UnsafeMutableRawPointer(p), 0, cols * MemoryLayout<Cell>.stride)
                } else {
                    for i in 0..<cols { p[i] = fill }
                }
            }
        } else {
            cells = Array(repeating: fill, count: cols)
        }
        wrapped = false
        dirty = true
        promptMark = 0
        exitStatus = nil
        commandStatus = nil
        inputStartColumn = nil
    }

    public var isBlank: Bool { cells.allSatisfy { $0.content == 0 && $0.bg == .default } }
}

/// Fixed-capacity ring buffer of rows that have scrolled off the top of the primary screen.
public struct Scrollback {
    public let capacity: Int
    private var buffer: [Row] = []
    private var head = 0

    public init(capacity: Int) { self.capacity = max(0, capacity) }

    public var count: Int { buffer.count }

    /// Appends `row`, returning the row it evicted once the ring is full so the caller can reuse
    /// its cell storage.
    @discardableResult
    public mutating func push(_ row: Row) -> Row? {
        guard capacity > 0 else { return nil }
        if buffer.count < capacity {
            buffer.append(row)
            return nil
        }
        let evicted = buffer[head]
        buffer[head] = row
        head = (head + 1) % capacity
        return evicted
    }

    /// 0 is the oldest row.
    public subscript(i: Int) -> Row {
        get { buffer[(head + i) % buffer.count] }
        set { buffer[(head + i) % buffer.count] = newValue }
    }

    public mutating func removeAll() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }
}
