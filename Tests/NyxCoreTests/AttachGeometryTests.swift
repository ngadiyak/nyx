import Testing
@testable import NyxCore

@Test func anOrdinaryScreenIsSane() {
    #expect(AttachGeometry.isSane(cols: 80, rows: 24))
    #expect(AttachGeometry.isSane(cols: 160, rows: 74))
}

@Test func theBoundsThemselvesAreSane() {
    #expect(AttachGeometry.isSane(cols: 2, rows: 1))
    #expect(AttachGeometry.isSane(cols: 1000, rows: 1000))
}

/// The reason this exists. `attached` arrives over the relay, and a relay -- or anything wearing
/// one -- can put any integer in it; the mirror `Terminal` is resized to it on the main thread,
/// allocating cols × rows cells. A thousand each way is far past any real display and still only a
/// million cells.
@Test func anAbsurdSizeIsNot() {
    #expect(!AttachGeometry.isSane(cols: 1_000_000, rows: 24))
    #expect(!AttachGeometry.isSane(cols: 80, rows: 2_000_000_000))
    #expect(!AttachGeometry.isSane(cols: 1001, rows: 1000))
    #expect(!AttachGeometry.isSane(cols: 1000, rows: 1001))
}

/// Zero and negative are the same refusal, and one column is: a grid a terminal cannot wrap in is
/// not a screen anybody is mirroring, and it is what an `attached` with no geometry at all decodes
/// to.
@Test func nothingBelowTheFloorIsAScreen() {
    #expect(!AttachGeometry.isSane(cols: 0, rows: 0))
    #expect(!AttachGeometry.isSane(cols: 1, rows: 24))
    #expect(!AttachGeometry.isSane(cols: 80, rows: 0))
    #expect(!AttachGeometry.isSane(cols: -80, rows: -24))
}
