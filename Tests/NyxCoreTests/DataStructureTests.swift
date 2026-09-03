import Testing
@testable import NyxCore

@Test func colorPackingRoundTrips() {
    let c = Color.rgb(10, 20, 30)
    #expect(c.kind == .rgb); #expect(c.r == 10); #expect(c.g == 20); #expect(c.b == 30)
    let i = Color.indexed(200)
    #expect(i.kind == .indexed); #expect(i.index == 200)
    #expect(Color.default.kind == .default)
    #expect(MemoryLayout<Cell>.size == 20)
}

@Test func rgbSpecParsing() {
    #expect(RGB(spec: "#ff8000") == RGB(255, 128, 0))
    #expect(RGB(spec: "rgb:ff/80/00") == RGB(255, 128, 0))
    #expect(RGB(spec: "rgb:ffff/8000/0000") == RGB(255, 128, 0))
    #expect(RGB(spec: "nope") == nil)
    #expect(RGB(255, 128, 0).xtermSpec == "rgb:ffff/8080/0000")
}

@Test func xtermPaletteDefaults() {
    let p = Palette.xtermDefault()
    #expect(p.colors.count == 256)
    #expect(p.colors[1] == RGB(hex: 0xCD0000))
    #expect(p.colors[9] == RGB(hex: 0xFF0000))
    #expect(p.colors[16] == RGB(0, 0, 0))
    #expect(p.colors[196] == RGB(255, 0, 0))
    #expect(p.colors[231] == RGB(255, 255, 255))
    #expect(p.colors[232] == RGB(8, 8, 8))
    #expect(p.colors[255] == RGB(238, 238, 238))
    #expect(p.resolve(.default, isForeground: true) == p.foreground)
    #expect(p.resolve(.default, isForeground: false) == p.background)
    #expect(p.resolve(.indexed(1), isForeground: true) == RGB(hex: 0xCD0000))
    #expect(p.resolve(.rgb(1, 2, 3), isForeground: true) == RGB(1, 2, 3))
}

@Test func cellUnderlineStyleBits() {
    var c = Cell()
    #expect(c.underline == .none)
    c.underline = .curly
    c.attrs.insert(.bold)
    #expect(c.underline == .curly)
    #expect(c.attrs.contains(.bold))
    c.underline = .none
    #expect(c.attrs.contains(.bold))
    #expect(c.underline == .none)
}

@Test func cellGraphemeFlag() {
    var c = Cell()
    c.content = Cell.graphemeFlag | 5
    #expect(c.graphemeIndex == 5)
    #expect(c.scalar == nil)
    c.content = 0x41
    #expect(c.graphemeIndex == nil)
    #expect(c.scalar == "A")
}

@Test func scrollbackRingKeepsNewest() {
    var sb = Scrollback(capacity: 3)
    for i in 0..<5 {
        var r = Row(cols: 1); r.cells[0].content = UInt32(0x30 + i)
        sb.push(r)
    }
    #expect(sb.count == 3)
    #expect(sb[0].cells[0].content == 0x32)
    #expect(sb[2].cells[0].content == 0x34)
    sb.removeAll()
    #expect(sb.count == 0)
}

@Test func scrollbackZeroCapacityDropsEverything() {
    var sb = Scrollback(capacity: 0)
    sb.push(Row(cols: 1))
    #expect(sb.count == 0)
}

@Test func screenDefaults() {
    let s = Screen(cols: 20, rows: 5)
    #expect(s.rows.count == 5)
    #expect(s.rows[0].cells.count == 20)
    #expect(s.scrollBottom == 4)
    #expect(s.tabStops[8] && s.tabStops[16] && !s.tabStops[9])
}

@Test func decSpecialGraphics() {
    #expect(Charset.decSpecial.map("q") == "─")
    #expect(Charset.decSpecial.map("l") == "┌")
    #expect(Charset.decSpecial.map("x") == "│")
    #expect(Charset.decSpecial.map("A") == "A")
    #expect(Charset.ascii.map("q") == "q")
}

@Test func scrollbackPushReturnsEvictedRow() {
    func row(_ c: UInt32) -> Row {
        var r = Row(cols: 1)
        r.cells[0].content = c
        return r
    }
    var sb = Scrollback(capacity: 2)
    #expect(sb.push(row(0x41)) == nil)                         // still filling
    #expect(sb.push(row(0x42)) == nil)
    #expect(sb.push(row(0x43))?.cells[0].content == 0x41)      // at capacity: the oldest comes back
    #expect(sb.push(row(0x44))?.cells[0].content == 0x42)
    #expect(sb.count == 2)
    #expect(sb[0].cells[0].content == 0x43)
    #expect(sb[1].cells[0].content == 0x44)

    var none = Scrollback(capacity: 0)
    #expect(none.push(row(0x41)) == nil)
}
