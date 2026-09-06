import Foundation
import Testing
@testable import NyxCore

@Test func setAndGet() {
    var choices = LensChoices()
    #expect(choices.isEmpty)
    #expect(choices.lens(of: 7) == nil)

    choices.set(.pretty, for: 7)
    #expect(choices.lens(of: 7) == .pretty)
    #expect(!choices.isEmpty)
    #expect(choices.lensedIDs == [7])
    #expect(choices.lens(of: 8) == nil)

    choices.set(.grep("x"), for: 7)
    #expect(choices.lens(of: 7) == .grep("x"))

    // nil is "back to raw".
    choices.set(nil, for: 7)
    #expect(choices.lens(of: 7) == nil)
    #expect(choices.isEmpty)
}

/// Command 0 is "no command": a block that predates ids, or a row nobody owns. A lens on it would
/// apply to every such row at once.
@Test func idZeroIsNotLensed() {
    var choices = LensChoices()
    choices.set(.pretty, for: 0)
    #expect(choices.lens(of: 0) == nil)
    #expect(choices.isEmpty)
}

/// The headers are folded the first time a response is shown -- what a reader wants is the body --
/// and a caller does not have to remember to seed that.
@Test func theHeadersStartFolded() {
    var choices = LensChoices()
    #expect(choices.folded(in: 7).isEmpty)
    choices.set(.pretty, for: 7)
    #expect(choices.folded(in: 7) == [ResponseLens.headersNode])
}

/// And once opened they stay open: switching lens, or going back to raw and returning, must not
/// re-fold what the reader deliberately unfolded. A terminal that argues with you is worse than
/// one with no folds at all.
@Test func aHandOpenedHeaderStaysOpen() {
    var choices = LensChoices()
    choices.set(.pretty, for: 7)
    choices.toggleFold(ResponseLens.headersNode, in: 7)
    #expect(choices.folded(in: 7).isEmpty)

    choices.set(.headers, for: 7)
    #expect(choices.folded(in: 7).isEmpty)

    choices.set(nil, for: 7)
    choices.set(.pretty, for: 7)
    #expect(choices.folded(in: 7).isEmpty)
}

@Test func toggleFold() {
    var choices = LensChoices()
    choices.set(.pretty, for: 7)
    let node = NodePath([.key("items")])
    choices.toggleFold(node, in: 7)
    #expect(choices.folded(in: 7) == [ResponseLens.headersNode, node])
    choices.toggleFold(node, in: 7)
    #expect(choices.folded(in: 7) == [ResponseLens.headersNode])
    // Folds belong to one command: two responses of the same shape fold independently.
    #expect(choices.folded(in: 8).isEmpty)
}

/// A fold made before any lens was chosen still belongs to that command -- and does not turn it
/// into a lensed one.
@Test func aFoldWithoutALensIsRemembered() {
    var choices = LensChoices()
    choices.toggleFold(NodePath([.key("a")]), in: 7)
    #expect(choices.folded(in: 7) == [NodePath([.key("a")])])
    #expect(choices.lens(of: 7) == nil)
    #expect(choices.isEmpty, "a fold is not a lens: the display path must stay on its fast route")
}

@Test func prune() {
    var choices = LensChoices()
    choices.set(.pretty, for: 3)
    choices.set(.raw, for: 9)
    choices.toggleFold(NodePath([.key("a")]), in: 3)
    choices.prune(olderThan: 5)
    #expect(choices.lens(of: 3) == nil)
    #expect(choices.folded(in: 3).isEmpty)
    #expect(choices.lens(of: 9) == .raw)
}
