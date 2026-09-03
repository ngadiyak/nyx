@testable import NyxCore

func makeTerminal(cols: Int = 10, rows: Int = 3, scrollback: Int = 100) -> Terminal {
    Terminal(cols: cols, rows: rows, scrollbackLimit: scrollback)
}

extension Terminal {
    @discardableResult
    func run(_ s: String) -> Terminal { feed(s); return self }
    var cur: (Int, Int) { (screen.cursor.x, screen.cursor.y) }
    func cell(_ x: Int, _ y: Int) -> Cell { screen.rows[y].cells[x] }
    var responseText: String { String(decoding: responses, as: UTF8.self) }
    func scrollbackLine(_ i: Int) -> String {
        var s = ""
        for c in scrollback[i].cells where !c.attrs.contains(.wideSpacer) { s += c.content == 0 ? " " : clusterText(of: c) }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }
}
