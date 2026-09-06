import Foundation
import Testing
@testable import NyxCore

private let buffer = LensBuffer(commandID: 2, lens: .pretty, lines: [
    LensLine("{"),
    LensLine("  \"name\": \"nik\","),
    LensLine("  \"id\": 7"),
    LensLine("}"),
], contentVersion: 0)

private func selection(_ a: (Int, Int), _ b: (Int, Int)) -> LensSelection {
    LensSelection(commandID: 2, anchor: .init(line: a.0, character: a.1),
                  head: .init(line: b.0, character: b.1))
}

@Test func textAcrossLines() {
    // From inside line 1 to inside line 2: the first line from the anchor, the last up to the head.
    #expect(selection((1, 2), (2, 7)).text(from: buffer) == "\"name\": \"nik\",\n  \"id\":")
    // A whole middle line comes out whole.
    #expect(selection((0, 0), (2, 9)).text(from: buffer) == "{\n  \"name\": \"nik\",\n  \"id\": 7")
    // One line, part of it.
    #expect(selection((1, 2), (1, 8)).text(from: buffer) == "\"name\"")
    // Dragged backwards is the same text: the pair is normalised, not ordered by the mouse.
    #expect(selection((2, 7), (1, 2)).text(from: buffer) == "\"name\": \"nik\",\n  \"id\":")
}

/// A drag past the end of a short line, and past the end of the buffer, is the ordinary way people
/// select: down and to the right, well past where the text stops.
@Test func columnsClampToLineLength() {
    #expect(selection((0, 0), (0, 99)).text(from: buffer) == "{")
    #expect(selection((0, 0), (99, 99)).text(from: buffer) == "{\n  \"name\": \"nik\",\n  \"id\": 7\n}")
    #expect(selection((-4, -4), (1, 3)).text(from: buffer) == "{\n  \"")
    // And the drawn range on a line is clamped the same way.
    #expect(selection((0, 0), (2, 3)).characters(onLine: 1, in: buffer) == 0 ..< 16)
    #expect(selection((0, 0), (2, 3)).characters(onLine: 2, in: buffer) == 0 ..< 3)
    #expect(selection((1, 0), (2, 3)).characters(onLine: 0, in: buffer) == nil)
    #expect(selection((0, 0), (2, 3)).characters(onLine: 9, in: buffer) == nil)
}

/// A click that selects nothing is not a selection: it must not steal ⌘C from the terminal's own.
@Test func aSelectionOfNothingIsEmpty() {
    #expect(selection((1, 4), (1, 4)).isEmpty)
    #expect(selection((1, 4), (1, 4)).text(from: buffer).isEmpty)
    #expect(!selection((1, 4), (1, 5)).isEmpty)
    // A selection is for one block: another block's buffer is not what it was made on.
    let other = LensBuffer(commandID: 3, lens: .pretty, lines: [LensLine("x")], contentVersion: 0)
    #expect(selection((0, 0), (2, 3)).text(from: other).isEmpty)
}

/// The drawn range is in *cells*, because that is what the renderer highlights, and a wide glyph
/// takes two of them.
@Test func drawnColumnsAreCells() {
    let wide = LensBuffer(commandID: 2, lens: .pretty,
                          lines: [LensLine("日本語 ok")], contentVersion: 0)
    let whole = LensSelection(commandID: 2, anchor: .init(line: 0, character: 0),
                              head: .init(line: 0, character: 4))
    #expect(whole.characters(onLine: 0, in: wide) == 0 ..< 4)
    #expect(whole.columns(onLine: 0, in: wide) == 0 ..< 7)
    let tail = LensSelection(commandID: 2, anchor: .init(line: 0, character: 4),
                             head: .init(line: 0, character: 6))
    #expect(tail.columns(onLine: 0, in: wide) == 7 ..< 9)
}

/// The buffer answers both directions, because a click arrives as a cell column and the text it
/// selects is measured in characters.
@Test func cellsAndCharactersConvertBothWays() {
    let wide = LensBuffer(commandID: 2, lens: .pretty,
                          lines: [LensLine("日本語 ok")], contentVersion: 0)
    #expect(wide.characterOffset(atColumn: 0, line: 0) == 0)
    #expect(wide.characterOffset(atColumn: 1, line: 0) == 0, "the second cell of 日 is still 日")
    #expect(wide.characterOffset(atColumn: 2, line: 0) == 1)
    #expect(wide.characterOffset(atColumn: 6, line: 0) == 3)
    #expect(wide.characterOffset(atColumn: 99, line: 0) == 6, "past the end is the end")
    #expect(wide.characterOffset(atColumn: 3, line: 9) == 0, "no such line")
}
