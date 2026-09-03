import Testing
@testable import NyxCore

private func w(_ s: Unicode.Scalar) -> Int { CharWidth.width(s) }

@Test func asciiIsOne() { #expect(w("a") == 1); #expect(w(" ") == 1) }
@Test func cyrillicIsOne() { #expect(w("я") == 1); #expect(w("Ж") == 1) }
@Test func controlsAreZero() { #expect(w("\u{07}") == 0); #expect(w("\u{7F}") == 0); #expect(w("\u{9B}") == 0) }
@Test func combiningIsZero() { #expect(w("\u{0301}") == 0); #expect(w("\u{200D}") == 0); #expect(w("\u{FE0F}") == 0) }
@Test func cjkIsTwo() { #expect(w("漢") == 2); #expect(w("あ") == 2); #expect(w("한") == 2) }
@Test func emojiIsTwo() { #expect(w("😀") == 2); #expect(w("🚀") == 2) }
@Test func boxDrawingIsOne() { #expect(w("─") == 1); #expect(w("│") == 1); #expect(w("┌") == 1) }
@Test func privateUseIsOne() { #expect(w("\u{E0B0}") == 1) }   // nerd-font powerline glyph
@Test func hangulJamoMedialIsZero() { #expect(w("\u{1160}") == 0) }
@Test func softHyphenIsOne() { #expect(w("\u{00AD}") == 1) }
