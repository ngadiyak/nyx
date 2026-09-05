import Testing
@testable import NyxCore

/// Anything that fits keeps exactly the width it asked for: an ordinary row -- an action and its
/// chord -- must look precisely as it always has.
@Test func aRowWithRoomForBothDrawsBothWhole() {
    let w = PaletteRowLayout.widths(rowWidth: 560, titleWidth: 180, detailWidth: 40)
    #expect(w.title == 180)
    #expect(w.detail == 40)
}

/// The overlap that made this type: a remote session's detail is a sentence, and drawn at its
/// natural width it ran through the title.
@Test func aDetailTooLongForTheRowIsCappedAndTheTitleKeepsTheRest() {
    let w = PaletteRowLayout.widths(rowWidth: 560, titleWidth: 300, detailWidth: 600)
    #expect(w.title + w.detail <= 560 - 12)
    #expect(w.detail <= (560 - 12) * 0.55)
    #expect(w.title > 0)
}

/// A short title hands its slack back rather than leaving a gap in the middle of the row.
@Test func aShortTitleLeavesTheRestToTheDetail() {
    let w = PaletteRowLayout.widths(rowWidth: 560, titleWidth: 60, detailWidth: 600)
    #expect(w.title == 60)
    #expect(w.detail == 560 - 12 - 60)
}

@Test func neitherHalfIsEverNegativeOrWiderThanItAskedFor() {
    for rowWidth in [0.0, 4, 12, 40, 200, 560] {
        for titleWidth in [0.0, 30, 400] {
            for detailWidth in [0.0, 30, 900] {
                let w = PaletteRowLayout.widths(rowWidth: rowWidth, titleWidth: titleWidth,
                                                detailWidth: detailWidth)
                #expect(w.title >= 0 && w.detail >= 0)
                #expect(w.title <= titleWidth)
                #expect(w.detail <= detailWidth)
                #expect(w.title + w.detail <= max(0, rowWidth - 12) + 0.001)
            }
        }
    }
}
