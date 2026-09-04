import Foundation

public enum TerminalEvent: Equatable {
    case titleChanged(String)
    case bell
    case cwdChanged(String)
    case clipboardWrite(String)
    case notification(title: String, body: String)
    case colorsChanged
}

public enum MouseMode: Equatable { case none, x10, normal, button, any }
public enum CursorShape: Equatable { case block, underline, bar }

public struct TerminalModes: Equatable {
    public var cursorKeysApp = false     // DECCKM ?1
    /// Tracked (DECKPAM/DECKPNM) but not implemented: numeric keypad encoding (phase 2, spec §11).
    public var keypadApp = false         // DECKPAM / DECKPNM
    public var originMode = false        // DECOM ?6
    public var autoWrap = true           // DECAWM ?7
    public var cursorBlink = true        // ?12
    public var showCursor = true         // DECTCEM ?25
    public var mouse: MouseMode = .none  // ?9 ?1000 ?1002 ?1003
    public var mouseSGR = false          // ?1006
    public var mouseUTF8 = false         // ?1005 (UTF-8 mouse coordinates)
    public var focusEvents = false       // ?1004
    public var altScreen = false         // ?1047 ?1049
    public var bracketedPaste = false    // ?2004
    public var syncOutput = false        // ?2026
    public var insertMode = false        // IRM 4
    public var lineFeedNewLine = false   // LNM 20
    public init() {}
}

struct SavedCursor {
    var cursor: Cursor
    var pen: Pen
    var charsets: [Charset]
    var activeCharset: Int
    var originMode: Bool
    var pendingWrap: Bool
}

@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

/// The terminal model: parses bytes into screen state. Not thread-safe; `TerminalSession` serialises access.
public final class Terminal: TerminalActions {
    public static let version = "0.1.0"

    public internal(set) var cols: Int
    public internal(set) var rows: Int
    public var screen: Screen
    var inactiveScreen: Screen
    public var scrollback: Scrollback
    /// Increments whenever absolute row indices stop referring to the same content: discarding the
    /// scrollback (ED 3), a full reset, or swapping the alternate screen in or out. Anything holding
    /// absolute coordinates — a selection above all — is meaningless once this changes, and has no
    /// other way to notice: the indices stay in range and silently address different rows.
    ///
    /// A resize deliberately does not bump it. Reflow moves content between rows but keeps it, so a
    /// selection made before a resize still points at the text the user chose.
    public private(set) var scrollbackGeneration: UInt64 = 0
    /// When the running command began, for the duration written on its prompt row at `D`.
    private var commandStartedAt: Double?
    /// Injectable so a test can run a command in a controlled number of seconds rather than in
    /// however long the test itself took.
    public var now: () -> Double = { Date.timeIntervalSinceReferenceDate }
    public var pen = Pen() { didSet { penCellDirty = true } }
    /// Cache of `pen.makeCell()`, rebuilt lazily whenever `pen` changes. Avoids rebuilding the
    /// pen-derived `Cell` template on every printed character, which is the common case in `put`.
    private var cachedPenCell = Cell()
    private var penCellDirty = true
    var penCell: Cell {
        if penCellDirty {
            cachedPenCell = pen.makeCell()
            penCellDirty = false
        }
        return cachedPenCell
    }
    public var modes = TerminalModes()
    public var palette: Palette
    let initialPalette: Palette
    public private(set) var title = ""
    /// OSC 1 (icon name). Kept apart from `title`: OSC 1 names the icon only, OSC 2 the window,
    /// OSC 0 both.
    public private(set) var iconName = ""
    public private(set) var cwd: String?
    /// Whether the shell in this terminal has ever emitted an `OSC 133` prompt mark.
    ///
    /// A session-level fact, and the cheap answer to a question several things ask on every frame
    /// and every menu validation: without marks there are no commands to pin, fold, jump between or
    /// copy the output of, and searching the buffer to find that out walks every row. Once true it
    /// stays true until a full reset -- a `clear` wipes the rows but not the shell's habits, and the
    /// very next prompt sets it again anyway.
    public private(set) var shellEmitsPromptMarks = false
    public private(set) var cursorShape: CursorShape = .block
    /// Bytes the terminal wants written back to the application (DA, CPR, ...). Drained by the session.
    public var responses: [UInt8] = []
    public var events: [TerminalEvent] = []
    public private(set) var graphemes: [String] = []
    private var graphemeIndex: [String: Int] = [:]
    public private(set) var hyperlinks: [String] = []
    private var hyperlinkIndex: [String: Int] = [:]
    /// Number of scrollback lines the viewport is scrolled up by. 0 = live view.
    public internal(set) var viewportOffset = 0
    /// A monotonically increasing counter of visible changes: it increments at least once per
    /// change -- a run of printed characters bumps it once, not once per cell. Nothing in the app
    /// reads it today (the view is driven by a dirty flag the session sets); it is used by the
    /// tests and is available to any consumer that wants cheap change detection.
    public private(set) var generation: UInt64 = 0
    /// Text area size in pixels, set by the view, reported by XTWINOPS 14/16.
    public var pixelSize: (width: Int, height: Int) = (0, 0)

    private var parser: VTParserOf<Terminal>!
    var charsets: [Charset] = [.ascii, .ascii]
    var activeCharset = 0
    var savedCursor: SavedCursor?
    var savedCursorOther: SavedCursor?
    private var lastPrinted: Unicode.Scalar?
    var savedModes: [Int: Bool] = [:]
    private var dcsData: [UInt8] = []
    private var dcsFinal: UInt8 = 0
    private var dcsIntermediates: [UInt8] = []

    public init(cols: Int, rows: Int, scrollbackLimit: Int = 10_000, palette: Palette = .xtermDefault()) {
        self.cols = max(cols, 2)
        self.rows = max(rows, 1)
        screen = Screen(cols: self.cols, rows: self.rows)
        inactiveScreen = Screen(cols: self.cols, rows: self.rows)
        scrollback = Scrollback(capacity: scrollbackLimit)
        self.palette = palette
        initialPalette = palette
        parser = VTParserOf(actions: self)
    }

    // MARK: - Public API

    public var cursor: Cursor { screen.cursor }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) { parser.feed(bytes) }
    public func feed(_ bytes: [UInt8]) { parser.feed(bytes) }
    public func feed(_ s: String) { feed(Array(s.utf8)) }

    public func clusterText(of cell: Cell) -> String {
        if let i = cell.graphemeIndex { return graphemes[i] }
        if let s = cell.scalar { return String(s) }
        return ""
    }

    /// Visible text of row `y` with trailing blanks trimmed. For tests and debugging.
    public func line(_ y: Int) -> String {
        var s = ""
        for c in screen.rows[y].cells where !c.attrs.contains(.wideSpacer) {
            s += c.content == 0 ? " " : clusterText(of: c)
        }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    public func text() -> [String] { (0..<rows).map(line) }

    public func clearDirty() {
        for y in 0..<rows { screen.rows[y].dirty = false }
    }

    func touch() { generation &+= 1 }

    func setCell(_ x: Int, _ y: Int, _ c: Cell) {
        screen.rows[y].cells[x] = c
        screen.rows[y].dirty = true
        touch()
    }

    /// Erase fill: current background, nothing else (BCE).
    var blank: Cell {
        var c = Cell()
        c.bg = pen.bg
        return c
    }

    func internGrapheme(_ s: String) -> Int {
        if let i = graphemeIndex[s] { return i }
        graphemes.append(s)
        graphemeIndex[s] = graphemes.count - 1
        return graphemes.count - 1
    }

    func internHyperlink(_ uri: String) -> Int {
        if let i = hyperlinkIndex[uri] { return i + 1 }
        guard hyperlinks.count < 65535 else { return 0 }
        hyperlinks.append(uri)
        hyperlinkIndex[uri] = hyperlinks.count - 1
        return hyperlinks.count
    }

    // MARK: - Printing

    public func print(_ raw: Unicode.Scalar) {
        put(charsets[activeCharset].map(raw))
    }

    /// Bulk form of `print` for a run of printable ASCII (0x20...0x7E), which is the overwhelming
    /// majority of bytes in real output. Writes whole spans of a row through one unsafe buffer
    /// access, marking the row dirty and bumping `generation` once per run rather than per cell.
    public func printASCII(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        // The fast path assumes each byte is exactly one cell wide and lands unmodified: that holds
        // for ASCII with the G0/G1 charset in ASCII mode, and only when characters are not shifted
        // right by insert mode.
        guard !modes.insertMode, charsets[activeCharset] == .ascii else {
            for i in 0..<count { self.print(Unicode.Scalar(bytes[i])) }
            return
        }
        let template = penCell
        var i = 0
        while i < count {
            if screen.pendingWrap {
                if modes.autoWrap { wrapToNextLine() } else { screen.pendingWrap = false }
            }
            let x = screen.cursor.x
            let y = screen.cursor.y
            let n = min(count - i, cols - x)
            writeRun(bytes + i, n, x: x, y: y, template: template)
            i += n
            let next = x + n
            if next >= cols {
                screen.cursor.x = cols - 1
                screen.pendingWrap = true
            } else {
                screen.cursor.x = next
            }
        }
        lastPrinted = Unicode.Scalar(bytes[count - 1])
        touch()
    }

    /// Writes `n` single-width cells into row `y` at column `x`. The caller guarantees
    /// `x + n <= cols`.
    private func writeRun(_ bytes: UnsafePointer<UInt8>, _ n: Int, x: Int, y: Int, template: Cell) {
        screen.rows.withUnsafeMutableBufferPointer { rows in
            rows[y].cells.withUnsafeMutableBufferPointer { cells in
                // Only the two ends of the run can orphan half of a wide glyph; any wide pair
                // strictly inside the run is overwritten in full.
                if cells[x].attrs.contains(.wideSpacer), x > 0 {
                    var b = Cell()
                    b.bg = cells[x - 1].bg
                    cells[x - 1] = b
                }
                let last = x + n - 1
                if cells[last].attrs.contains(.wide), last + 1 < cols {
                    var b = Cell()
                    b.bg = cells[last].bg
                    cells[last + 1] = b
                }
                var c = template
                for k in 0..<n {
                    c.content = UInt32(bytes[k])
                    cells[x + k] = c
                }
            }
            rows[y].dirty = true
        }
    }

    private func put(_ s: Unicode.Scalar) {
        let width = CharWidth.width(s)
        if width == 0 { appendZeroWidth(s); return }
        if screen.pendingWrap {
            if modes.autoWrap { wrapToNextLine() } else { screen.pendingWrap = false }
        }
        var x = screen.cursor.x
        if width == 2 && x == cols - 1 {
            setCell(x, screen.cursor.y, blank)
            guard modes.autoWrap else { return }
            wrapToNextLine()
            x = 0
        }
        let y = screen.cursor.y
        if modes.insertMode { insertBlanks(count: width, at: x, row: y) }
        var cell = penCell
        cell.content = s.value
        if width == 2 {
            clearWideRemnants(x: x, y: y)
            clearWideRemnants(x: x + 1, y: y)
            cell.attrs.insert(.wide)
            setCell(x, y, cell)
            var spacer = penCell
            spacer.attrs.insert(.wideSpacer)
            setCell(x + 1, y, spacer)
        } else {
            placeCell(cell, x: x, y: y)
        }
        lastPrinted = s
        let next = x + width
        if next >= cols {
            screen.cursor.x = cols - 1
            screen.pendingWrap = true
        } else {
            screen.cursor.x = next
        }
    }

    private func appendZeroWidth(_ s: Unicode.Scalar) {
        var x = screen.cursor.x
        let y = screen.cursor.y
        if !screen.pendingWrap { x -= 1 }
        guard x >= 0 else { return }
        if screen.rows[y].cells[x].attrs.contains(.wideSpacer) { x -= 1 }
        guard x >= 0 else { return }
        var cell = screen.rows[y].cells[x]
        guard cell.content != 0 else { return }
        var text = clusterText(of: cell)
        if s.value == 0xFE0F, !cell.attrs.contains(.wide), x + 1 < cols {
            cell.attrs.insert(.wide)
            var spacer = penCell
            spacer.attrs.insert(.wideSpacer)
            spacer.bg = cell.bg
            setCell(x + 1, y, spacer)
            if screen.cursor.x == x + 1 {
                if x + 2 >= cols { screen.cursor.x = cols - 1; screen.pendingWrap = true } else { screen.cursor.x = x + 2 }
            }
        }
        text.unicodeScalars.append(s)
        cell.content = Cell.graphemeFlag | UInt32(internGrapheme(text))
        setCell(x, y, cell)
    }

    /// Clears the orphaned half of any wide pair at (x, y) and writes `c` there, through a single
    /// access to the row's cells rather than a read and a write through the nested arrays.
    private func placeCell(_ c: Cell, x: Int, y: Int) {
        screen.rows[y].dirty = true
        screen.rows[y].cells.withUnsafeMutableBufferPointer { cells in
            guard let p = cells.baseAddress else { return }
            let old = p[x]
            if old.attrs.contains(.wideSpacer), x > 0 {
                var b = Cell()
                b.bg = p[x - 1].bg
                p[x - 1] = b
            } else if old.attrs.contains(.wide), x + 1 < cols {
                var b = Cell()
                b.bg = old.bg
                p[x + 1] = b
            }
            p[x] = c
        }
        touch()
    }

    /// If the cell at (x, y) is half of a wide glyph, blank both halves so no orphan half remains.
    private func clearWideRemnants(x: Int, y: Int) {
        let c = screen.rows[y].cells[x]
        if c.attrs.contains(.wideSpacer), x > 0 {
            var b = Cell(); b.bg = screen.rows[y].cells[x - 1].bg
            setCell(x - 1, y, b)
        } else if c.attrs.contains(.wide), x + 1 < cols {
            var b = Cell(); b.bg = c.bg
            setCell(x + 1, y, b)
        }
    }

    private func wrapToNextLine() {
        screen.rows[screen.cursor.y].wrapped = true
        screen.cursor.x = 0
        screen.pendingWrap = false
        lineFeed()
    }

    // MARK: - Cursor and scrolling primitives

    func setCursor(x: Int, y: Int) {
        screen.cursor.x = clamp(x, 0, cols - 1)
        screen.cursor.y = clamp(y, 0, rows - 1)
        screen.pendingWrap = false
        touch()
    }

    func setCursorAbsolute(row: Int, col: Int?) {
        var y = row
        if modes.originMode { y = clamp(y + screen.scrollTop, screen.scrollTop, screen.scrollBottom) }
        setCursor(x: col ?? screen.cursor.x, y: y)
    }

    private func cursorUp(_ n: Int) {
        let top = screen.cursor.y >= screen.scrollTop ? screen.scrollTop : 0
        setCursor(x: screen.cursor.x, y: max(top, screen.cursor.y - n))
    }

    private func cursorDown(_ n: Int) {
        let bottom = screen.cursor.y <= screen.scrollBottom ? screen.scrollBottom : rows - 1
        setCursor(x: screen.cursor.x, y: min(bottom, screen.cursor.y + n))
    }

    func lineFeed() {
        let y = screen.cursor.y
        if y == screen.scrollBottom { scrollUp(1, top: screen.scrollTop, bottom: screen.scrollBottom, saveToScrollback: true) }
        else if y < rows - 1 { screen.cursor.y = y + 1 }
        screen.pendingWrap = false
        touch()
    }

    private func reverseIndex() {
        screen.pendingWrap = false
        if screen.cursor.y == screen.scrollTop { scrollDown(1, top: screen.scrollTop, bottom: screen.scrollBottom) }
        else if screen.cursor.y > 0 { screen.cursor.y -= 1 }
        touch()
    }

    /// Removes `n` rows at `top`, inserts blank rows at `bottom`. Rows leaving from row 0 of the primary screen go to scrollback.
    func scrollUp(_ n: Int, top: Int, bottom: Int, saveToScrollback: Bool) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        let save = saveToScrollback && top == 0 && !modes.altScreen
        let fill = blank
        for _ in 0..<count {
            var removed = screen.rows.remove(at: top)
            // The blank row that replaces it reuses cell storage we already own: the row leaving
            // the region, or the one the scrollback ring just evicted. Allocating (and shortly
            // freeing) a fresh cell array per scrolled line was a measurable share of bulk output.
            var recycled: Row
            if save {
                removed.dirty = true
                recycled = scrollback.push(removed) ?? Row(cols: cols, fill: fill)
                if viewportOffset > 0 { viewportOffset = min(viewportOffset + 1, scrollback.count) }
            } else {
                recycled = removed
            }
            recycled.reset(cols: cols, fill: fill)
            screen.rows.insert(recycled, at: bottom)
        }
        screen.rows.withUnsafeMutableBufferPointer { r in
            for y in top...bottom { r[y].dirty = true }
        }
        touch()
    }

    func scrollDown(_ n: Int, top: Int, bottom: Int) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        let fill = blank
        for _ in 0..<count {
            var recycled = screen.rows.remove(at: bottom)
            recycled.reset(cols: cols, fill: fill)
            screen.rows.insert(recycled, at: top)
        }
        screen.rows.withUnsafeMutableBufferPointer { r in
            for y in top...bottom { r[y].dirty = true }
        }
        touch()
    }

    private func tabForward(_ n: Int) {
        var x = screen.cursor.x
        for _ in 0..<n {
            var nx = x + 1
            while nx < cols - 1 && !screen.tabStops[nx] { nx += 1 }
            x = min(nx, cols - 1)
        }
        screen.cursor.x = x
        screen.pendingWrap = false
        touch()
    }

    private func tabBackward(_ n: Int) {
        var x = screen.cursor.x
        for _ in 0..<n {
            var nx = x - 1
            while nx > 0 && !screen.tabStops[nx] { nx -= 1 }
            x = max(nx, 0)
        }
        screen.cursor.x = x
        screen.pendingWrap = false
        touch()
    }

    // MARK: - Erase and edit

    private func clearRow(_ y: Int) {
        screen.rows[y] = Row(cols: cols, fill: blank)
        touch()
    }

    private func eraseInRow(_ y: Int, from a: Int, to b: Int) {
        guard a <= b else { return }
        if a > 0, screen.rows[y].cells[a].attrs.contains(.wideSpacer) { screen.rows[y].cells[a - 1] = blank }
        if b + 1 < cols, screen.rows[y].cells[b].attrs.contains(.wide) { screen.rows[y].cells[b + 1] = blank }
        let fill = blank
        for x in a...b { screen.rows[y].cells[x] = fill }
        screen.rows[y].dirty = true
        touch()
    }

    private func eraseDisplay(_ mode: Int) {
        let c = screen.cursor
        switch mode {
        case 0:
            eraseInRow(c.y, from: c.x, to: cols - 1)
            if c.y + 1 < rows { for y in (c.y + 1)..<rows { clearRow(y) } }
        case 1:
            eraseInRow(c.y, from: 0, to: c.x)
            for y in 0..<c.y { clearRow(y) }
        case 2:
            for y in 0..<rows { clearRow(y) }
        case 3:
            scrollback.removeAll()
            viewportOffset = 0
            scrollbackGeneration &+= 1
            touch()
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        let c = screen.cursor
        switch mode {
        case 0: eraseInRow(c.y, from: c.x, to: cols - 1)
        case 1: eraseInRow(c.y, from: 0, to: c.x)
        case 2: eraseInRow(c.y, from: 0, to: cols - 1)
        default: break
        }
    }

    func insertBlanks(count: Int, at x: Int, row y: Int) {
        let n = min(count, cols - x)
        guard n > 0 else { return }
        clearWideRemnants(x: x, y: y)
        var cells = screen.rows[y].cells
        cells.removeSubrange((cols - n)..<cols)
        cells.insert(contentsOf: Array(repeating: blank, count: n), at: x)
        if cells[cols - 1].attrs.contains(.wide) { cells[cols - 1] = blank }
        screen.rows[y].cells = cells
        screen.rows[y].dirty = true
        touch()
    }

    private func deleteChars(_ count: Int) {
        let x = screen.cursor.x, y = screen.cursor.y
        let n = min(count, cols - x)
        guard n > 0 else { return }
        clearWideRemnants(x: x, y: y)
        if x + n < cols { clearWideRemnants(x: x + n, y: y) }
        var cells = screen.rows[y].cells
        cells.removeSubrange(x..<(x + n))
        cells.append(contentsOf: Array(repeating: blank, count: n))
        screen.rows[y].cells = cells
        screen.rows[y].dirty = true
        screen.pendingWrap = false
        touch()
    }

    private func eraseChars(_ count: Int) {
        let x = screen.cursor.x
        eraseInRow(screen.cursor.y, from: x, to: min(x + count, cols) - 1)
        screen.pendingWrap = false
    }

    private func insertLines(_ n: Int) {
        let y = screen.cursor.y
        guard y >= screen.scrollTop, y <= screen.scrollBottom else { return }
        scrollDown(n, top: y, bottom: screen.scrollBottom)
        screen.cursor.x = 0
        screen.pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        let y = screen.cursor.y
        guard y >= screen.scrollTop, y <= screen.scrollBottom else { return }
        scrollUp(n, top: y, bottom: screen.scrollBottom, saveToScrollback: false)
        screen.cursor.x = 0
        screen.pendingWrap = false
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let t = max(1, top), b = min(rows, bottom)
        guard t < b else { return }
        screen.scrollTop = t - 1
        screen.scrollBottom = b - 1
        setCursorAbsolute(row: 0, col: 0)
    }

    func saveCursor() {
        savedCursor = SavedCursor(cursor: screen.cursor, pen: pen, charsets: charsets, activeCharset: activeCharset,
                                  originMode: modes.originMode, pendingWrap: screen.pendingWrap)
    }

    func restoreCursor() {
        guard let s = savedCursor else {
            setCursor(x: 0, y: 0)
            pen = Pen()
            return
        }
        screen.cursor = Cursor(x: min(s.cursor.x, cols - 1), y: min(s.cursor.y, rows - 1))
        pen = s.pen
        charsets = s.charsets
        activeCharset = s.activeCharset
        modes.originMode = s.originMode
        screen.pendingWrap = s.pendingWrap
        touch()
    }

    func reset() {
        screen = Screen(cols: cols, rows: rows)
        inactiveScreen = Screen(cols: cols, rows: rows)
        modes = TerminalModes()
        pen = Pen()
        charsets = [.ascii, .ascii]
        activeCharset = 0
        savedCursor = nil
        savedCursorOther = nil
        savedModes = [:]
        cursorShape = .block
        palette = initialPalette
        viewportOffset = 0
        shellEmitsPromptMarks = false
        scrollbackGeneration &+= 1
        touch()
    }

    // MARK: - TerminalActions

    public func execute(_ byte: UInt8) {
        switch byte {
        case 0x07: events.append(.bell)
        case 0x08:
            if screen.cursor.x > 0 { screen.cursor.x -= 1 }
            screen.pendingWrap = false
        case 0x09: tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
            if modes.lineFeedNewLine { screen.cursor.x = 0 }
        case 0x0D:
            screen.cursor.x = 0
            screen.pendingWrap = false
        case 0x0E: activeCharset = 1
        case 0x0F: activeCharset = 0
        default: break
        }
        touch()
    }

    public func csi(_ p: CSIParams, intermediates: [UInt8], final: UInt8) {
        defer { touch() }
        if !intermediates.isEmpty {
            csiWithIntermediates(p, intermediates: intermediates, final: final)
            return
        }
        switch final {
        case 0x40: insertBlanks(count: p.get(0, 1), at: screen.cursor.x, row: screen.cursor.y)   // ICH
        case 0x41: cursorUp(p.get(0, 1))                                                       // CUU
        case 0x42, 0x65: cursorDown(p.get(0, 1))                                               // CUD, VPR
        case 0x43, 0x61: setCursor(x: screen.cursor.x + p.get(0, 1), y: screen.cursor.y)       // CUF, HPR
        case 0x44: setCursor(x: screen.cursor.x - p.get(0, 1), y: screen.cursor.y)             // CUB
        case 0x45: cursorDown(p.get(0, 1)); screen.cursor.x = 0                                // CNL
        case 0x46: cursorUp(p.get(0, 1)); screen.cursor.x = 0                                  // CPL
        case 0x47, 0x60: setCursor(x: p.get(0, 1) - 1, y: screen.cursor.y)                     // CHA, HPA
        case 0x48, 0x66: setCursorAbsolute(row: p.get(0, 1) - 1, col: p.get(1, 1) - 1)         // CUP, HVP
        case 0x49: tabForward(p.get(0, 1))                                                     // CHT
        case 0x4A: eraseDisplay(p.get(0))                                                      // ED
        case 0x4B: eraseLine(p.get(0))                                                         // EL
        case 0x4C: insertLines(p.get(0, 1))                                                    // IL
        case 0x4D: deleteLines(p.get(0, 1))                                                    // DL
        case 0x50: deleteChars(p.get(0, 1))                                                    // DCH
        case 0x53: scrollUp(p.get(0, 1), top: screen.scrollTop, bottom: screen.scrollBottom, saveToScrollback: true)  // SU
        case 0x54: scrollDown(p.get(0, 1), top: screen.scrollTop, bottom: screen.scrollBottom) // SD
        case 0x58: eraseChars(p.get(0, 1))                                                     // ECH
        case 0x5A: tabBackward(p.get(0, 1))                                                    // CBT
        case 0x62:                                                                             // REP
            if let s = lastPrinted { for _ in 0..<min(p.get(0, 1), cols) { put(s) } }
        case 0x64: setCursorAbsolute(row: p.get(0, 1) - 1, col: nil)                           // VPA
        case 0x67:                                                                             // TBC
            if p.get(0) == 3 { screen.tabStops = Array(repeating: false, count: cols) }
            else if p.get(0) == 0 { screen.tabStops[screen.cursor.x] = false }
        case 0x72: setScrollRegion(top: p.get(0, 1), bottom: p.get(1, rows))                   // DECSTBM
        case 0x73: saveCursor()                                                                // SCOSC
        case 0x75: restoreCursor()                                                             // SCORC
        default: csiExtended(p, final: final)
        }
    }

    public func esc(intermediates: [UInt8], final: UInt8) {
        defer { touch() }
        if let i = intermediates.first {
            switch (i, final) {
            case (0x28, _): charsets[0] = final == 0x30 ? .decSpecial : .ascii   // ESC ( x
            case (0x29, _): charsets[1] = final == 0x30 ? .decSpecial : .ascii   // ESC ) x
            case (0x23, 0x38):                                                   // DECALN
                var e = Cell(); e.content = 0x45
                for y in 0..<rows { screen.rows[y] = Row(cols: cols, fill: e) }
                screen.scrollTop = 0; screen.scrollBottom = rows - 1
                setCursor(x: 0, y: 0)
            default: break
            }
            return
        }
        switch final {
        case 0x37: saveCursor()                                  // ESC 7
        case 0x38: restoreCursor()                               // ESC 8
        case 0x44: lineFeed()                                    // IND
        case 0x45: lineFeed(); screen.cursor.x = 0               // NEL
        case 0x48: screen.tabStops[screen.cursor.x] = true       // HTS
        case 0x4D: reverseIndex()                                // RI
        case 0x63: reset()                                       // RIS
        case 0x3D: modes.keypadApp = true                        // DECKPAM
        case 0x3E: modes.keypadApp = false                       // DECKPNM
        default: break
        }
    }

    // MARK: - CSI with intermediates / private markers

    func csiWithIntermediates(_ p: CSIParams, intermediates: [UInt8], final: UInt8) {
        switch intermediates {
        case [0x3F]:                                   // ?
            switch final {
            case 0x68: for i in 0..<p.count { setPrivateMode(p.get(i), true) }
            case 0x6C: for i in 0..<p.count { setPrivateMode(p.get(i), false) }
            case 0x73: for i in 0..<p.count { if let v = privateMode(p.get(i)) { savedModes[p.get(i)] = v } }
            case 0x72: for i in 0..<p.count { if let v = savedModes[p.get(i)] { setPrivateMode(p.get(i), v) } }
            case 0x4A: eraseDisplay(p.get(0))
            case 0x4B: eraseLine(p.get(0))
            default: break
            }
        case [0x3F, 0x24]:                             // ? $ p  DECRQM (private)
            if final == 0x70 { requestMode(p.get(0), isPrivate: true) }
        case [0x24]:                                   // $ p  DECRQM (ANSI)
            if final == 0x70 { requestMode(p.get(0), isPrivate: false) }
        case [0x20]:                                   // SP q  DECSCUSR
            if final == 0x71 { setCursorShape(p.get(0)) }
        case [0x3E]:                                   // >
            if final == 0x63 { respond("\u{1B}[>1;10;0c") }                                  // DA2
            else if final == 0x71 { respond("\u{1B}P>|Nyx \(Terminal.version)\u{1B}\\") }   // XTVERSION
        case [0x3D]:                                   // =
            if final == 0x63 { respond("\u{1B}P!|00000000\u{1B}\\") }                        // DA3
        default: break
        }
    }

    func csiExtended(_ p: CSIParams, final: UInt8) {
        switch final {
        case 0x63: respond("\u{1B}[?62;22c")                                   // DA1
        case 0x68: for i in 0..<p.count { setMode(p.get(i), true) }            // SM
        case 0x6C: for i in 0..<p.count { setMode(p.get(i), false) }           // RM
        case 0x6D: applySGR(p)                                                 // SGR
        case 0x6E: deviceStatus(p.get(0))                                      // DSR
        case 0x74: windowOps(p)                                                // XTWINOPS
        default: break
        }
    }

    // MARK: - Modes

    private func setMode(_ m: Int, _ on: Bool) {
        switch m {
        case 4: modes.insertMode = on
        case 20: modes.lineFeedNewLine = on
        default: break
        }
    }

    func setPrivateMode(_ m: Int, _ on: Bool) {
        switch m {
        case 1: modes.cursorKeysApp = on
        case 3: eraseDisplay(2); setCursorAbsolute(row: 0, col: 0)
        case 6: modes.originMode = on; setCursorAbsolute(row: 0, col: 0)
        case 7: modes.autoWrap = on
        case 9: modes.mouse = on ? .x10 : .none
        case 12: modes.cursorBlink = on
        case 25: modes.showCursor = on
        case 1000: modes.mouse = on ? .normal : .none
        case 1002: modes.mouse = on ? .button : .none
        case 1003: modes.mouse = on ? .any : .none
        case 1004: modes.focusEvents = on
        case 1005: modes.mouseUTF8 = on
        case 1006: modes.mouseSGR = on
        case 1047: switchScreen(alt: on, clear: on, saveCursor: false)
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049: switchScreen(alt: on, clear: on, saveCursor: true)
        case 2004: modes.bracketedPaste = on
        case 2026: modes.syncOutput = on
        default: break
        }
    }

    func privateMode(_ m: Int) -> Bool? {
        switch m {
        case 1: return modes.cursorKeysApp
        case 6: return modes.originMode
        case 7: return modes.autoWrap
        case 9: return modes.mouse == .x10
        case 12: return modes.cursorBlink
        case 25: return modes.showCursor
        case 1000: return modes.mouse == .normal
        case 1002: return modes.mouse == .button
        case 1003: return modes.mouse == .any
        case 1004: return modes.focusEvents
        case 1005: return modes.mouseUTF8
        case 1006: return modes.mouseSGR
        case 1047, 1049: return modes.altScreen
        case 2004: return modes.bracketedPaste
        case 2026: return modes.syncOutput
        default: return nil
        }
    }

    private func requestMode(_ m: Int, isPrivate: Bool) {
        let state: Int
        if isPrivate {
            state = privateMode(m).map { $0 ? 1 : 2 } ?? 0
        } else {
            switch m {
            case 4: state = modes.insertMode ? 1 : 2
            case 20: state = modes.lineFeedNewLine ? 1 : 2
            default: state = 0
            }
        }
        respond("\u{1B}[\(isPrivate ? "?" : "")\(m);\(state)$y")
    }

    func switchScreen(alt: Bool, clear: Bool, saveCursor save: Bool) {
        guard alt != modes.altScreen else { return }
        if alt {
            if save { saveCursor() }
            let cursor = screen.cursor
            swap(&screen, &inactiveScreen)
            swap(&savedCursor, &savedCursorOther)
            modes.altScreen = true
            if clear { for y in 0..<rows { screen.rows[y] = Row(cols: cols, fill: blank) } }
            screen.cursor = cursor
            screen.pendingWrap = false
            screen.scrollTop = 0
            screen.scrollBottom = rows - 1
        } else {
            swap(&screen, &inactiveScreen)
            swap(&savedCursor, &savedCursorOther)
            modes.altScreen = false
            if save { restoreCursor() }
        }
        viewportOffset = 0
        // The screen under the scrollback changed wholesale; absolute rows now mean something else.
        scrollbackGeneration &+= 1
        for y in 0..<rows { screen.rows[y].dirty = true }
        touch()
    }

    private func setCursorShape(_ n: Int) {
        switch n {
        case 0, 1, 2: cursorShape = .block
        case 3, 4: cursorShape = .underline
        case 5, 6: cursorShape = .bar
        default: return
        }
        modes.cursorBlink = n == 0 || n % 2 == 1
    }

    /// Sets the cursor shape from outside (the app's `cursor-style` config setting). This is a
    /// default only: DECSCUSR (`SP q`, handled by the private `setCursorShape(_:Int)` above) still
    /// wins whenever the running application sends it, exactly as reapplying the config would win
    /// only until the next such escape sequence.
    public func setDefaultCursorShape(_ shape: CursorShape) {
        cursorShape = shape
    }

    // MARK: - SGR

    private func applySGR(_ p: CSIParams) {
        if p.count == 0 { resetPen(); return }
        let n = p.count
        var i = 0
        while i < n {
            let subCount = p.subCount(i)
            let code = p.value(i, 0)
            switch code {
            case 0: resetPen()
            case 1: pen.attrs.insert(.bold)
            case 2: pen.attrs.insert(.dim)
            case 3: pen.attrs.insert(.italic)
            case 4:
                let style = subCount > 1 ? p.value(i, 1) : 1
                pen.underline = UnderlineStyle(rawValue: UInt16(clamp(style, 0, 5))) ?? .single
            case 5, 6: pen.attrs.insert(.blink)
            case 7: pen.attrs.insert(.inverse)
            case 8: pen.attrs.insert(.hidden)
            case 9: pen.attrs.insert(.strike)
            case 21: pen.underline = .double
            case 22: pen.attrs.remove([.bold, .dim])
            case 23: pen.attrs.remove(.italic)
            case 24: pen.underline = .none
            case 25: pen.attrs.remove(.blink)
            case 27: pen.attrs.remove(.inverse)
            case 28: pen.attrs.remove(.hidden)
            case 29: pen.attrs.remove(.strike)
            case 30...37: pen.fg = .indexed(UInt8(code - 30))
            case 38, 48, 58:
                var color: Color?
                if subCount > 1 {
                    if p.value(i, 1) == 5, subCount > 2 {
                        color = .indexed(UInt8(clamp(p.value(i, 2), 0, 255)))
                    } else if p.value(i, 1) == 2, subCount >= 5 {
                        let o = subCount >= 6 ? 3 : 2
                        color = .rgb(u8(p.value(i, o)), u8(p.value(i, o + 1)), u8(p.value(i, o + 2)))
                    }
                } else if i + 1 < n {
                    let mode = p.value(i + 1, 0)
                    if mode == 5, i + 2 < n {
                        color = .indexed(u8(p.value(i + 2, 0))); i += 2
                    } else if mode == 2, i + 4 < n {
                        color = .rgb(u8(p.value(i + 2, 0)), u8(p.value(i + 3, 0)), u8(p.value(i + 4, 0))); i += 4
                    }
                }
                if let c = color {
                    switch code {
                    case 38: pen.fg = c
                    case 48: pen.bg = c
                    default: pen.ul = c
                    }
                }
            case 39: pen.fg = .default
            case 40...47: pen.bg = .indexed(UInt8(code - 40))
            case 49: pen.bg = .default
            case 59: pen.ul = .default
            case 90...97: pen.fg = .indexed(UInt8(code - 90 + 8))
            case 100...107: pen.bg = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            i += 1
        }
    }

    private func resetPen() {
        let link = pen.hyperlink
        pen = Pen()
        pen.hyperlink = link
    }

    private func u8(_ v: Int) -> UInt8 { UInt8(clamp(v, 0, 255)) }

    private func sgrString() -> String {
        var parts = ["0"]
        if pen.attrs.contains(.bold) { parts.append("1") }
        if pen.attrs.contains(.dim) { parts.append("2") }
        if pen.attrs.contains(.italic) { parts.append("3") }
        if pen.underline != .none { parts.append("4:\(pen.underline.rawValue)") }
        if pen.attrs.contains(.blink) { parts.append("5") }
        if pen.attrs.contains(.inverse) { parts.append("7") }
        if pen.attrs.contains(.hidden) { parts.append("8") }
        if pen.attrs.contains(.strike) { parts.append("9") }
        func color(_ c: Color, base: Int, ext: Int) -> String? {
            switch c.kind {
            case .default: return nil
            case .indexed:
                let i = Int(c.index)
                if i < 8 { return "\(base + i)" }
                if i < 16 { return "\(base + 60 + i - 8)" }
                return "\(ext):5:\(i)"
            case .rgb: return "\(ext):2::\(c.r):\(c.g):\(c.b)"
            }
        }
        if let f = color(pen.fg, base: 30, ext: 38) { parts.append(f) }
        if let b = color(pen.bg, base: 40, ext: 48) { parts.append(b) }
        if pen.ul.kind != .default, let u = color(pen.ul, base: 0, ext: 58) { parts.append(u) }
        return parts.joined(separator: ";")
    }

    // MARK: - Reports

    private func deviceStatus(_ n: Int) {
        switch n {
        case 5: respond("\u{1B}[0n")
        case 6:
            let y = modes.originMode ? screen.cursor.y - screen.scrollTop : screen.cursor.y
            respond("\u{1B}[\(y + 1);\(screen.cursor.x + 1)R")
        default: break
        }
    }

    private func windowOps(_ p: CSIParams) {
        switch p.get(0) {
        case 14: respond("\u{1B}[4;\(pixelSize.height);\(pixelSize.width)t")
        case 16: respond("\u{1B}[6;\(pixelSize.height / rows);\(pixelSize.width / cols)t")
        case 18: respond("\u{1B}[8;\(rows);\(cols)t")
        default: break
        }
    }

    // MARK: - OSC

    public func osc(_ data: [UInt8]) {
        defer { touch() }
        let s = String(decoding: data, as: UTF8.self)
        let code: Int
        let rest: String
        if let semi = s.firstIndex(of: ";") {
            guard let c = Int(s[..<semi]) else { return }
            code = c
            rest = String(s[s.index(after: semi)...])
        } else {
            guard let c = Int(s) else { return }
            code = c
            rest = ""
        }
        switch code {
        case 0, 2:
            title = rest
            if code == 0 { iconName = rest }
            events.append(.titleChanged(rest))
        case 1:
            iconName = rest
        case 4:
            handlePaletteOSC(rest)
        case 7:
            if let url = URL(string: rest), url.scheme == "file" {
                let path = url.path
                cwd = path
                events.append(.cwdChanged(path))
            }
        case 8:
            let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            let uri = parts.count > 1 ? String(parts[1]) : ""
            pen.hyperlink = uri.isEmpty ? 0 : UInt16(internHyperlink(uri))
        case 9:
            events.append(.notification(title: "", body: rest))
        case 777:
            let parts = rest.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3, parts[0] == "notify" {
                events.append(.notification(title: String(parts[1]), body: String(parts[2])))
            }
        case 10, 11, 12:
            if rest == "?" {
                let c = code == 10 ? palette.foreground : code == 11 ? palette.background : palette.cursor
                respond("\u{1B}]\(code);\(c.xtermSpec)\u{1B}\\")
            } else if let c = RGB(spec: rest) {
                switch code {
                case 10: palette.foreground = c
                case 11: palette.background = c
                default: palette.cursor = c
                }
                events.append(.colorsChanged)
            }
        case 52:
            let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[1] != "?", let d = Data(base64Encoded: String(parts[1])),
               let text = String(data: d, encoding: .utf8) {
                events.append(.clipboardWrite(text))
            }
        case 104:
            if rest.isEmpty {
                palette.colors = initialPalette.colors
            } else {
                for part in rest.split(separator: ";") {
                    if let i = Int(part), (0..<256).contains(i) { palette.colors[i] = initialPalette.colors[i] }
                }
            }
            events.append(.colorsChanged)
        case 110: palette.foreground = initialPalette.foreground; events.append(.colorsChanged)
        case 111: palette.background = initialPalette.background; events.append(.colorsChanged)
        case 112: palette.cursor = initialPalette.cursor; events.append(.colorsChanged)
        case 133:
            // A row commonly carries more than one of these: a shell emits A and B on the same
            // prompt line, and emits D for the finished command on the line the next prompt is
            // about to occupy. Storing one value per row loses whichever arrived first, so they
            // accumulate as flags.
            let mark: UInt8
            switch rest.first {
            case "A": mark = 1
            case "B": mark = 2
            case "C": mark = 4
            case "D": mark = 8
            default: return
            }
            screen.rows[screen.cursor.y].promptMark |= mark
            // Where the prompt ends and typing begins, on the row it happens on.
            if mark == 2 { screen.rows[screen.cursor.y].inputStartColumn = screen.cursor.x }
            shellEmitsPromptMarks = true
            // `D;<status>` reports how the command ended. Without it a failed command is
            // indistinguishable from one that succeeded, which is most of the point of the mark.
            // `C`: the command starts running. The clock starts here rather than at the prompt, so
            // a terminal left open overnight does not report the first command of the morning as a
            // nine-hour job.
            if mark == 4 { commandStartedAt = now() }
            if mark == 8 {
                let fields = rest.split(separator: ";", omittingEmptySubsequences: false)
                let status = fields.count > 1 ? Int32(fields[1]) : nil
                if let status { screen.rows[screen.cursor.y].exitStatus = status }
                // Also written onto the prompt this command belongs to, where the gutter draws its
                // mark. Once per command, walking back over its own output -- rather than forward
                // over the whole buffer on every frame, which is what searching at draw time cost.
                recordCommandStatus(status ?? 0)
                if let started = commandStartedAt {
                    recordCommandDuration(now() - started)
                    commandStartedAt = nil
                }
            }
        default:
            break
        }
    }

    /// What the user has typed at the current prompt but not yet run, or nil when there is nothing
    /// to read: no shell integration, or a command already running.
    ///
    /// This is the text of the command line itself, taken from where the shell said its prompt ends
    /// to wherever the cursor now is. It is what makes "edit what I just pasted" possible -- a long
    /// `curl` sitting on the command line is exactly the thing a shell's line editor is worst at,
    /// and until now the only way to change it was to fight the line editor.
    public var currentInput: String? {
        let cursorRow = scrollback.count + screen.cursor.y
        // The typing starts on the most recent row carrying a `B`, at or above the cursor.
        var row = cursorRow
        var startColumn: Int?
        while row >= 0, row > cursorRow - rows {
            if let column = absoluteRow(row)?.inputStartColumn {
                startColumn = column
                break
            }
            // A `C` means output began: a command is running, and there is no input to edit.
            if promptMarks(atAbsoluteRow: row).contains(.outputStart) { return nil }
            row -= 1
        }
        guard let startColumn, row <= cursorRow else { return nil }

        var text = ""
        for absolute in row...cursorRow {
            let line = rowText(absoluteRow: absolute)
            let from = absolute == row ? startColumn : 0
            let characters = Array(line.text)
            let to = absolute == cursorRow ? min(characters.count, screen.cursor.x) : characters.count
            guard from < to else { continue }
            text += String(characters[from..<to])
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Where the current command line begins, as an absolute row and a column, or nil when there is
    /// no editable command line.
    public var currentInputStart: (row: Int, column: Int)? {
        let cursorRow = scrollback.count + screen.cursor.y
        var row = cursorRow
        while row >= 0, row > cursorRow - rows {
            if let column = absoluteRow(row)?.inputStartColumn { return (row, column) }
            if promptMarks(atAbsoluteRow: row).contains(.outputStart) { return nil }
            row -= 1
        }
        return nil
    }

    /// How many cells lie between the start of the command line and a position on screen, or nil
    /// when the position is not on the command line at all.
    ///
    /// This is what lets a click move the shell's cursor: the difference between where the caret is
    /// and where it was clicked, counted in cells, is exactly the number of arrow keys to send.
    /// Counted through the wrap, because a pasted `curl` is longer than the window is wide, and
    /// that is precisely the case worth clicking into.
    public func inputOffset(atAbsoluteRow row: Int, column: Int) -> Int? {
        guard let start = currentInputStart else { return nil }
        let cursorRow = scrollback.count + screen.cursor.y
        guard row >= start.row, row <= cursorRow else { return nil }
        guard row > start.row || column >= start.column else { return nil }

        var offset = 0
        for absolute in start.row..<row {
            let from = absolute == start.row ? start.column : 0
            offset += max(0, cols - from)
        }
        offset += column - (row == start.row ? start.column : 0)
        return max(0, offset)
    }

    /// Where the shell's caret sits within the command line.
    public var currentInputCursorOffset: Int? {
        let cursorRow = scrollback.count + screen.cursor.y
        return inputOffset(atAbsoluteRow: cursorRow, column: screen.cursor.x)
    }

    /// Walks back from the cursor to the prompt this command started at and records how it ended.
    ///
    /// Bounded by the command's own output, and paid once when the command finishes.
    private func recordCommandDuration(_ seconds: Double) {
        withOwningPromptRow { row in
            if row < scrollback.count { scrollback[row].commandDuration = seconds }
            else { screen.rows[row - scrollback.count].commandDuration = seconds }
        }
    }

    /// Runs `body` with the absolute row of the prompt the finishing command belongs to.
    private func withOwningPromptRow(_ body: (Int) -> Void) {
        let cursorAbsolute = scrollback.count + screen.cursor.y
        var row = cursorAbsolute
        while row >= 0 {
            let flags = row < scrollback.count
                ? scrollback[row].promptMark
                : screen.rows[row - scrollback.count].promptMark
            if flags & 1 != 0 && row != cursorAbsolute {
                body(row)
                return
            }
            row -= 1
        }
    }

    private func recordCommandStatus(_ status: Int32) {
        let cursorAbsolute = scrollback.count + screen.cursor.y
        var row = cursorAbsolute
        while row >= 0 {
            let flags: UInt8
            if row < scrollback.count {
                flags = scrollback[row].promptMark
            } else {
                flags = screen.rows[row - scrollback.count].promptMark
            }
            // The `D` may share a row with the *next* prompt, which is not the one that ran.
            if flags & 1 != 0 && row != cursorAbsolute {
                if row < scrollback.count {
                    scrollback[row].commandStatus = status
                } else {
                    screen.rows[row - scrollback.count].commandStatus = status
                }
                return
            }
            row -= 1
        }
    }

    private func handlePaletteOSC(_ rest: String) {
        let parts = rest.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 1 < parts.count {
            defer { i += 2 }
            guard let idx = Int(parts[i]), (0..<256).contains(idx) else { continue }
            if parts[i + 1] == "?" {
                respond("\u{1B}]4;\(idx);\(palette.colors[idx].xtermSpec)\u{1B}\\")
            } else if let c = RGB(spec: parts[i + 1]) {
                palette.colors[idx] = c
                events.append(.colorsChanged)
            }
        }
    }

    // MARK: - DCS

    public func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8) {
        dcsData.removeAll(keepingCapacity: true); dcsFinal = final; dcsIntermediates = intermediates
    }
    public func dcsPut(_ byte: UInt8) { if dcsData.count < 4096 { dcsData.append(byte) } }

    public func dcsUnhook() {
        guard dcsIntermediates == [0x24], dcsFinal == 0x71 else { return }   // DECRQSS
        switch String(decoding: dcsData, as: UTF8.self) {
        case "m": respond("\u{1B}P1$r\(sgrString())m\u{1B}\\")
        case "r": respond("\u{1B}P1$r\(screen.scrollTop + 1);\(screen.scrollBottom + 1)r\u{1B}\\")
        case " q":
            let n: Int
            switch cursorShape {
            case .block: n = modes.cursorBlink ? 1 : 2
            case .underline: n = modes.cursorBlink ? 3 : 4
            case .bar: n = modes.cursorBlink ? 5 : 6
            }
            respond("\u{1B}P1$r\(n) q\u{1B}\\")
        default: respond("\u{1B}P0$r\u{1B}\\")
        }
    }

    func respond(_ s: String) { responses += Array(s.utf8) }
}
