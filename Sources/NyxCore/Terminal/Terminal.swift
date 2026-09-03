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
    public var keypadApp = false         // DECKPAM / DECKPNM
    public var originMode = false        // DECOM ?6
    public var autoWrap = true           // DECAWM ?7
    public var cursorBlink = true        // ?12
    public var showCursor = true         // DECTCEM ?25
    public var mouse: MouseMode = .none  // ?9 ?1000 ?1002 ?1003
    public var mouseSGR = false          // ?1006
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

    public private(set) var cols: Int
    public private(set) var rows: Int
    public var screen: Screen
    var inactiveScreen: Screen
    public var scrollback: Scrollback
    public var pen = Pen()
    public var modes = TerminalModes()
    public var palette: Palette
    let initialPalette: Palette
    public private(set) var title = ""
    public private(set) var cwd: String?
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
    /// Increments on every visible change. Renderers compare it to decide whether to redraw.
    public private(set) var generation: UInt64 = 0
    /// Text area size in pixels, set by the view, reported by XTWINOPS 14/16.
    public var pixelSize: (width: Int, height: Int) = (0, 0)

    private var parser: VTParser!
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
        parser = VTParser(actions: self)
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
        clearWideRemnants(x: x, y: y)
        if width == 2 { clearWideRemnants(x: x + 1, y: y) }
        var cell = pen.makeCell()
        cell.content = s.value
        if width == 2 {
            cell.attrs.insert(.wide)
            setCell(x, y, cell)
            var spacer = pen.makeCell()
            spacer.attrs.insert(.wideSpacer)
            setCell(x + 1, y, spacer)
        } else {
            setCell(x, y, cell)
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
            var spacer = pen.makeCell()
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
        for _ in 0..<count {
            var removed = screen.rows.remove(at: top)
            if save {
                removed.dirty = true
                scrollback.push(removed)
                if viewportOffset > 0 { viewportOffset = min(viewportOffset + 1, scrollback.count) }
            }
            screen.rows.insert(Row(cols: cols, fill: blank), at: bottom)
        }
        for y in top...bottom { screen.rows[y].dirty = true }
        touch()
    }

    func scrollDown(_ n: Int, top: Int, bottom: Int) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            screen.rows.remove(at: bottom)
            screen.rows.insert(Row(cols: cols, fill: blank), at: top)
        }
        for y in top...bottom { screen.rows[y].dirty = true }
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

    // The following are completed in Task 6. Keep these stubs until then.
    // Minimal SGR (final 'm') is implemented here now because `eraseUsesPenBackground` needs
    // `pen.bg` to reflect CSI 44 m before ED runs; Task 6 will replace this with full SGR
    // (attributes, 256-color, RGB, underline styles, hyperlinks).
    func csiWithIntermediates(_ p: CSIParams, intermediates: [UInt8], final: UInt8) {}
    func csiExtended(_ p: CSIParams, final: UInt8) {
        guard final == 0x6D else { return }   // SGR
        guard p.count > 0 else { pen = Pen(); return }
        for i in 0..<p.count {
            switch p.get(i) {
            case 0: pen = Pen()
            case 30...37: pen.fg = .indexed(UInt8(p.get(i) - 30))
            case 39: pen.fg = .default
            case 40...47: pen.bg = .indexed(UInt8(p.get(i) - 40))
            case 49: pen.bg = .default
            case 90...97: pen.fg = .indexed(UInt8(p.get(i) - 90 + 8))
            case 100...107: pen.bg = .indexed(UInt8(p.get(i) - 100 + 8))
            default: break
            }
        }
    }
    public func osc(_ data: [UInt8]) {}
    public func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8) {
        dcsData.removeAll(keepingCapacity: true); dcsFinal = final; dcsIntermediates = intermediates
    }
    public func dcsPut(_ byte: UInt8) { if dcsData.count < 4096 { dcsData.append(byte) } }
    public func dcsUnhook() {}

    func respond(_ s: String) { responses += Array(s.utf8) }
}
