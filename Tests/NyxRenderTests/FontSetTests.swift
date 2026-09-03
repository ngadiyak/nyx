import Testing
import CoreText
@testable import NyxRender

@Test func menloMetricsAreSane() {
    let f = FontSet(family: "Menlo", pointSize: 13, scale: 2)
    let m = f.metrics
    #expect(m.width == 16)                      // Menlo 26px advance is 15.65 → ceil
    #expect(m.height > m.baseline && m.baseline > 0)
    #expect(m.underlineY > m.baseline && m.underlineY + m.thickness <= m.height)
    #expect(m.strikeY > 0 && m.strikeY < m.baseline)
    #expect(m.thickness >= 1)
}

@Test func lineHeightMultiplierGrowsCell() {
    let a = FontSet(family: "Menlo", pointSize: 13, scale: 2)
    let b = FontSet(family: "Menlo", pointSize: 13, scale: 2, lineHeight: 1.5)
    #expect(b.metrics.height > a.metrics.height)
    #expect(b.metrics.baseline > a.metrics.baseline)
}

@Test func unknownFamilyFallsBackToSomething() {
    let f = FontSet(family: "No Such Font 123", pointSize: 12, scale: 1)
    #expect(f.metrics.width > 0)
}

@Test func resolvesByFamilyAndPostScriptName() {
    let byFamily = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let byPostScript = FontSet(family: "Menlo-Regular", pointSize: 12, scale: 1)
    let byOtherFamily = FontSet(family: "Courier New", pointSize: 12, scale: 1)
    #expect(CTFontCopyPostScriptName(byFamily.regular) as String == "Menlo-Regular")
    #expect(CTFontCopyPostScriptName(byPostScript.regular) as String == "Menlo-Regular")
    #expect((CTFontCopyFamilyName(byOtherFamily.regular) as String) == "Courier New")
}
