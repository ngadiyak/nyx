public struct Row: Equatable {
    public var cells: [Cell]
    /// True when the line continues on the next row (soft wrap). Used by reflow and selection.
    public var wrapped = false
    public var dirty = true
    /// OSC 133 mark: 1 = prompt start (A), 2 = input start (B), 3 = output start (C), 4 = end (D).
    public var promptMark: UInt8 = 0

    public init(cols: Int, fill: Cell = Cell()) {
        cells = Array(repeating: fill, count: cols)
    }

    /// Turns this row back into a blank one, reusing the cell storage when it is already the right
    /// size. Scrolling recycles rows this way instead of allocating a fresh cell array per line.
    mutating func reset(cols: Int, fill: Cell) {
        if cells.count == cols {
            cells.withUnsafeMutableBufferPointer { b in
                for i in 0..<cols { b[i] = fill }
            }
        } else {
            cells = Array(repeating: fill, count: cols)
        }
        wrapped = false
        dirty = true
        promptMark = 0
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
    public subscript(i: Int) -> Row { buffer[(head + i) % buffer.count] }

    public mutating func removeAll() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }
}
