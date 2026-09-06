import Testing
@testable import NyxCore

private func exchange(status: Int) -> HTTPExchange? {
    HTTPExchange.parse(lines: ["HTTP/1.1 \(status) OK", "", "body"])
}

/// The whole point of the cache: a block's transcript is read once, ever.
@Test func aBlockIsReadOnceAndThenAnsweredFromTheCache() {
    var cache = RequestSummaryCache()
    #expect(cache.shouldParse(id: 4))
    cache.remember(.request(exchange(status: 200)), for: 4)
    #expect(!cache.shouldParse(id: 4))
    #expect(cache.entry(for: 4) == .request(exchange(status: 200)))
}

/// A block found not to be a curl is remembered as such, so `CurlCommand.parse` and the string
/// build behind `commandLine(of:)` do not run again on the next frame.
@Test func aBlockThatIsNotARequestIsRememberedToo() {
    var cache = RequestSummaryCache()
    cache.remember(.notARequest, for: 9)
    #expect(!cache.shouldParse(id: 9))
    #expect(cache.entry(for: 9) == .notARequest)
}

/// A curl whose transcript said nothing parseable -- it never connected -- is still an answer, and
/// re-reading it every frame would be the same nothing at whatever the output cost.
@Test func aRequestWithNoExchangeIsStillAnAnswer() {
    var cache = RequestSummaryCache()
    cache.remember(.request(nil), for: 3)
    #expect(!cache.shouldParse(id: 3))
    #expect(cache.entry(for: 3) == .request(nil))
}

/// The defect this replaces: the pane only allowed a parse on a frame whose `contentVersion` had
/// moved, so a block that finished while scrolled off screen was never read on an idle shell --
/// scrolling back to it showed the duration and never the status. Whether a block has been read is
/// the only question; when the buffer last changed is not part of it.
@Test func aBlockScrolledIntoViewLongAfterItFinishedIsStillRead() {
    var cache = RequestSummaryCache()
    cache.remember(.request(exchange(status: 200)), for: 1)
    // Nothing has been written to the buffer since, and block 7 has still never been looked at.
    #expect(cache.shouldParse(id: 7))
}

/// Ids only ever go up, so the buffer evicting everything below `oldest` retires exactly the
/// entries whose rows are gone.
@Test func pruningDropsEverythingBelowTheOldestSurvivingCommand() {
    var cache = RequestSummaryCache()
    for id in UInt32(1)...10 { cache.remember(.notARequest, for: id) }
    cache.prune(olderThan: 6)
    #expect(cache.count == 5)
    #expect(cache.shouldParse(id: 5))
    #expect(!cache.shouldParse(id: 6))
}

/// Over the cap the *oldest* entries go, not all of them: wiping the lot made every block on screen
/// pay for its command line again, and wiping only one of two side-by-side caches made the two
/// disagree about which blocks had been looked at.
@Test func trimmingDropsTheOldestRatherThanEverything() {
    var cache = RequestSummaryCache()
    for id in UInt32(1)...10 { cache.remember(.notARequest, for: id) }
    cache.trim(to: 4)
    #expect(cache.count == 4)
    #expect(cache.shouldParse(id: 6))
    #expect(!cache.shouldParse(id: 7))
    #expect(!cache.shouldParse(id: 10))
}

@Test func trimmingBelowTheCapChangesNothing() {
    var cache = RequestSummaryCache()
    for id in UInt32(1)...3 { cache.remember(.notARequest, for: id) }
    cache.trim(to: 4)
    #expect(cache.count == 3)
    #expect(cache.isEmpty == false)
    #expect(RequestSummaryCache().isEmpty)
}
