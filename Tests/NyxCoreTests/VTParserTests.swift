import Testing
@testable import NyxCore

enum Action: Equatable {
    case print(Unicode.Scalar)
    case execute(UInt8)
    case csi([[Int]], [UInt8], UInt8)
    case esc([UInt8], UInt8)
    case osc(String)
    case dcsHook([[Int]], [UInt8], UInt8)
    case dcsPut(UInt8)
    case dcsUnhook
}

final class Recorder: TerminalActions {
    var actions: [Action] = []
    func print(_ scalar: Unicode.Scalar) { actions.append(.print(scalar)) }
    func execute(_ byte: UInt8) { actions.append(.execute(byte)) }
    func csi(_ params: CSIParams, intermediates: [UInt8], final: UInt8) { actions.append(.csi(params.items, intermediates, final)) }
    func esc(intermediates: [UInt8], final: UInt8) { actions.append(.esc(intermediates, final)) }
    func osc(_ data: [UInt8]) { actions.append(.osc(String(decoding: data, as: UTF8.self))) }
    func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8) { actions.append(.dcsHook(params.items, intermediates, final)) }
    func dcsPut(_ byte: UInt8) { actions.append(.dcsPut(byte)) }
    func dcsUnhook() { actions.append(.dcsUnhook) }
}

func parse(_ s: String) -> [Action] { parse(Array(s.utf8)) }
func parse(_ bytes: [UInt8]) -> [Action] {
    let r = Recorder()
    let p = VTParser(actions: r)
    p.feed(bytes)
    return r.actions
}
func parseByteByByte(_ s: String) -> [Action] {
    let r = Recorder()
    let p = VTParser(actions: r)
    for b in s.utf8 { p.feed([b]) }
    return r.actions
}
private func prints(_ s: String) -> [Action] { s.unicodeScalars.map { .print($0) } }

@Test func plainTextPrints() { #expect(parse("hi") == prints("hi")) }
@Test func c0Executes() { #expect(parse("a\r\n") == [.print("a"), .execute(0x0D), .execute(0x0A)]) }
@Test func cupWithParams() { #expect(parse("\u{1B}[3;4H") == [.csi([[3], [4]], [], 0x48)]) }
@Test func csiWithoutParams() { #expect(parse("\u{1B}[H") == [.csi([], [], 0x48)]) }
@Test func csiEmptyFirstParam() { #expect(parse("\u{1B}[;5H") == [.csi([[0], [5]], [], 0x48)]) }
@Test func privateMarker() { #expect(parse("\u{1B}[?25h") == [.csi([[25]], [0x3F], 0x68)]) }
@Test func intermediateSpace() { #expect(parse("\u{1B}[2 q") == [.csi([[2]], [0x20], 0x71)]) }
@Test func sgrSubparams() { #expect(parse("\u{1B}[4:3;38:2:1:2:3m") == [.csi([[4, 3], [38, 2, 1, 2, 3]], [], 0x6D)]) }
@Test func c0InsideCsiExecutesAndContinues() { #expect(parse("\u{1B}[3\u{08}m") == [.execute(0x08), .csi([[3]], [], 0x6D)]) }
@Test func canAbortsCsi() { #expect(parse("\u{1B}[3\u{18}a") == [.execute(0x18), .print("a")]) }
@Test func escSequences() {
    #expect(parse("\u{1B}7") == [.esc([], 0x37)])
    #expect(parse("\u{1B}(0") == [.esc([0x28], 0x30)])
    #expect(parse("\u{1B}#8") == [.esc([0x23], 0x38)])
}
@Test func oscTerminatedByBel() { #expect(parse("\u{1B}]0;title\u{07}") == [.osc("0;title")]) }
@Test func oscTerminatedByST() { #expect(parse("\u{1B}]0;title\u{1B}\\x") == [.osc("0;title"), .esc([], 0x5C), .print("x")]) }
@Test func oscKeepsUTF8() { #expect(parse("\u{1B}]2;Привет\u{07}") == [.osc("2;Привет")]) }
@Test func oscOverflowIsDropped() {
    let big = String(repeating: "a", count: VTParser.maxOSCLength + 10)
    #expect(parse("\u{1B}]52;c;" + big + "\u{07}x") == [.print("x")])
}
@Test func dcsPassthrough() {
    #expect(parse("\u{1B}P$qm\u{1B}\\") == [.dcsHook([], [0x24], 0x71), .dcsPut(0x6D), .dcsUnhook, .esc([], 0x5C)])
}
@Test func utf8MultiByte() { #expect(parse("я😀") == prints("я😀")) }
@Test func invalidUTF8BecomesReplacement() { #expect(parse([0xFF, 0x61]) == [.print("\u{FFFD}"), .print("a")]) }
@Test func truncatedUTF8ThenAscii() { #expect(parse([0xD1, 0x61]) == [.print("\u{FFFD}"), .print("a")]) }
@Test func overlongUTF8Rejected() { #expect(parse([0xC0, 0x80]) == [.print("\u{FFFD}"), .print("\u{FFFD}")]) }
@Test func splitFeedMatchesWholeFeed() {
    let s = "a\u{1B}[1;31mЖ\u{1B}]0;t\u{07}😀\u{1B}[?1049h"
    #expect(parseByteByByte(s) == parse(s))
}
@Test func paramsCappedAt32() {
    let many = (0..<40).map(String.init).joined(separator: ";")
    guard case .csi(let items, _, _) = parse("\u{1B}[" + many + "m").first else { Issue.record("no csi"); return }
    #expect(items.count == 32)
}
@Test func csiParamsGetDefaults() {
    let p = CSIParams([[0], [7]])
    #expect(p.get(0, 1) == 1)
    #expect(p.get(1, 1) == 7)
    #expect(p.get(5, 3) == 3)
}
