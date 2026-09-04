extension Terminal {
    // MARK: - Viewport

    /// Row `i` of the visible viewport (0 = top), taking `viewportOffset` into account.
    public func viewportRow(_ i: Int) -> Row {
        let start = scrollback.count - viewportOffset
        let abs = start + i
        return abs < scrollback.count ? scrollback[abs] : screen.rows[abs - scrollback.count]
    }

    /// Positive `lines` scroll towards older content. Clamped to the scrollback size.
    public func scrollViewport(by lines: Int) {
        let v = clamp(viewportOffset + lines, 0, modes.altScreen ? 0 : scrollback.count)
        if v != viewportOffset { viewportOffset = v; touch() }
    }

    public func scrollViewportToBottom() {
        if viewportOffset != 0 { viewportOffset = 0; touch() }
    }

    // MARK: - Resize

    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }
        var primary = modes.altScreen ? inactiveScreen : screen
        var alt = modes.altScreen ? screen : inactiveScreen
        reflowPrimary(&primary, newCols: newCols, newRows: newRows)
        simpleResize(&alt, newCols: newCols, newRows: newRows)
        if modes.altScreen { screen = alt; inactiveScreen = primary } else { screen = primary; inactiveScreen = alt }
        cols = newCols
        rows = newRows
        savedCursor = savedCursor.map { clampSaved($0) }
        savedCursorOther = savedCursorOther.map { clampSaved($0) }
        viewportOffset = min(viewportOffset, scrollback.count)
        touch()
    }

    private func clampSaved(_ s: SavedCursor) -> SavedCursor {
        var c = s
        c.cursor = Cursor(x: min(s.cursor.x, cols - 1), y: min(s.cursor.y, rows - 1))
        return c
    }

    /// Alternate screen: truncate or pad, no reflow (full-screen apps redraw themselves).
    private func simpleResize(_ s: inout Screen, newCols: Int, newRows: Int) {
        for y in 0..<s.rows.count {
            var cells = s.rows[y].cells
            if cells.count > newCols {
                cells.removeSubrange(newCols...)
                if cells[newCols - 1].attrs.contains(.wide) { cells[newCols - 1] = Cell() }
            } else if cells.count < newCols {
                cells.append(contentsOf: Array(repeating: Cell(), count: newCols - cells.count))
            }
            s.rows[y].cells = cells
            s.rows[y].dirty = true
        }
        if s.rows.count > newRows { s.rows.removeSubrange(newRows...) }
        while s.rows.count < newRows { s.rows.append(Row(cols: newCols)) }
        s.cursor = Cursor(x: min(s.cursor.x, newCols - 1), y: min(s.cursor.y, newRows - 1))
        resetMarginsAndTabs(&s, newCols: newCols, newRows: newRows, pendingWrap: false)
    }

    /// Primary screen: rejoin soft-wrapped rows into logical lines, re-wrap at the new width, redistribute between scrollback and screen.
    private func reflowPrimary(_ s: inout Screen, newCols: Int, newRows: Int) {
        // 1. Physical rows: scrollback + screen rows up to the last used one.
        var lastUsed = s.cursor.y
        for y in stride(from: s.rows.count - 1, to: lastUsed, by: -1) where !s.rows[y].isBlank {
            lastUsed = y
            break
        }
        var physical: [Row] = []
        physical.reserveCapacity(scrollback.count + lastUsed + 1)
        for i in 0..<scrollback.count { physical.append(scrollback[i]) }
        for y in 0...lastUsed { physical.append(s.rows[y]) }
        let cursorPhysical = scrollback.count + s.cursor.y

        // 2. Logical lines.
        struct Line { var cells: [Cell]; var mark: UInt8; var exitStatus: Int32?; var commandStatus: Int32? }
        var lines: [Line] = []
        var current: [Cell] = []
        var currentMark: UInt8 = 0
        var currentStatus: Int32?
        var currentCommandStatus: Int32?
        var cursorLine = 0
        var cursorOffset = 0
        for (i, row) in physical.enumerated() {
            // A logical line's marks are the union of its physical rows': a command long enough
            // to wrap puts its `A` on the first row and its `D` on the last, and taking only the
            // first would lose the status every time the window was narrowed.
            currentMark |= row.promptMark
            if currentStatus == nil { currentStatus = row.exitStatus }
            if currentCommandStatus == nil { currentCommandStatus = row.commandStatus }
            if i == cursorPhysical {
                cursorLine = lines.count
                cursorOffset = current.count + s.cursor.x
            }
            current.append(contentsOf: row.cells)
            if !row.wrapped || i == physical.count - 1 {
                var keep = current.count
                while keep > 0 && current[keep - 1].content == 0 && current[keep - 1].bg == .default { keep -= 1 }
                if lines.count == cursorLine && i >= cursorPhysical { keep = max(keep, cursorOffset) }
                current.removeSubrange(keep...)
                lines.append(Line(cells: current, mark: currentMark, exitStatus: currentStatus,
                                  commandStatus: currentCommandStatus))
                current = []
                currentMark = 0
                currentStatus = nil
                currentCommandStatus = nil
            }
        }

        // 3. Re-wrap.
        var out: [Row] = []
        var newCursor = Cursor()
        var pendingWrap = false
        for (li, line) in lines.enumerated() {
            var row = Row(cols: newCols)
            row.promptMark = line.mark
            row.exitStatus = line.exitStatus
            row.commandStatus = line.commandStatus
            var x = 0
            var placedCursor = false
            var index = 0
            while index < line.cells.count {
                let c = line.cells[index]
                if c.attrs.contains(.wideSpacer) { index += 1; continue }
                let w = c.attrs.contains(.wide) ? 2 : 1
                if x + w > newCols {
                    row.wrapped = true
                    out.append(row)
                    row = Row(cols: newCols)
                    x = 0
                }
                if li == cursorLine && index == cursorOffset {
                    newCursor = Cursor(x: x, y: out.count)
                    placedCursor = true
                }
                row.cells[x] = c
                if w == 2 {
                    var sp = Cell(); sp.bg = c.bg; sp.attrs.insert(.wideSpacer)
                    row.cells[x + 1] = sp
                }
                x += w
                index += 1
            }
            if li == cursorLine && !placedCursor {
                var cx = x + max(0, cursorOffset - line.cells.count)
                if cx >= newCols { cx = newCols - 1; pendingWrap = true }
                newCursor = Cursor(x: cx, y: out.count)
            }
            out.append(row)
        }

        // 4. Split between scrollback and screen. Rows before `first` go to scrollback and are
        // kept; rows past `first + newRows` have nowhere to go and would be *dropped*. So `first`
        // may only be lowered towards the cursor as far as the window still ends at or past the
        // last row holding content: content wins over cursor placement, and the only rows this can
        // discard are the genuinely blank ones trailing it. When the two conflict (a cursor parked
        // above the content that fits) the cursor clamps to the top of the new window.
        var lastContent = out.count - 1
        while lastContent > 0 && out[lastContent].isBlank { lastContent -= 1 }
        let earliestFirst = max(0, lastContent + 1 - newRows)
        var first = max(0, out.count - newRows)
        if newCursor.y < first { first = max(newCursor.y, earliestFirst) }
        scrollback.removeAll()
        for i in 0..<first { scrollback.push(out[i]) }
        var rows = Array(out[first..<min(out.count, first + newRows)])
        while rows.count < newRows { rows.append(Row(cols: newCols)) }
        for i in 0..<rows.count { rows[i].dirty = true }
        s.rows = rows
        s.cursor = Cursor(x: newCursor.x, y: clamp(newCursor.y - first, 0, newRows - 1))
        resetMarginsAndTabs(&s, newCols: newCols, newRows: newRows, pendingWrap: pendingWrap)
    }

    /// Scroll margins, pending wrap and tab stops all reset to their defaults for the new size --
    /// shared by both resize paths.
    private func resetMarginsAndTabs(_ s: inout Screen, newCols: Int, newRows: Int, pendingWrap: Bool) {
        s.pendingWrap = pendingWrap
        s.scrollTop = 0
        s.scrollBottom = newRows - 1
        s.tabStops = Screen.defaultTabStops(cols: newCols)
    }
}
