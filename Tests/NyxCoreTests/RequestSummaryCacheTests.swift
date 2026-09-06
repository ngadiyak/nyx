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

// MARK: - Which blocks reach the history

/// A request is recorded when it is *run*, not when it is read. Reading happens again whenever the
/// cache has been trimmed and the block comes back on screen -- so without this the timestamp of a
/// request from last Tuesday became "just now" the moment you scrolled back to it, and it jumped
/// to the top of the palette over things actually run since.
@Test func aBlockIsOfferedToTheHistoryOnce() {
    var cache = RequestSummaryCache()
    let first = cache.shouldRecord(id: 4)
    #expect(first)
    let again = cache.shouldRecord(id: 4)
    #expect(!again)
}

/// Command ids only ever increase (`prune` relies on the same fact), so an id at or below the
/// high-water mark names a block that has already had its turn -- whatever the cache has since
/// forgotten about it.
@Test func aReParsedBlockIsNotOfferedAgainAfterTheCacheIsTrimmed() {
    var cache = RequestSummaryCache()
    for id in UInt32(1)...5 {
        let offered = cache.shouldRecord(id: id)
        #expect(offered)
    }
    cache.trim(to: 0)
    cache.prune(olderThan: 100)
    #expect(cache.isEmpty)
    let old = cache.shouldRecord(id: 3)
    #expect(!old)
    let newest = cache.shouldRecord(id: 6)
    #expect(newest)
}

/// Scrolling far enough back to read blocks in any order still records nothing twice: the mark is
/// the highest id ever offered, not the last one.
@Test func readingOlderBlocksOutOfOrderOffersNone() {
    var cache = RequestSummaryCache()
    let newest = cache.shouldRecord(id: 9)
    #expect(newest)
    for id in UInt32(1)...8 {
        let old = cache.shouldRecord(id: id)
        #expect(!old)
    }
}

/// The bool behind `BlockHeader.isHTTP` and the ⋯ menu's Request group. False for a block nobody
/// has read -- one still running, or one whose prompt row has never been on screen -- because that
/// is the honest answer: nothing has looked at it, and a menu is not the place to start parsing.
@Test func isRequestAnswersFromWhatWasFound() {
    var cache = RequestSummaryCache()
    #expect(!cache.isRequest(id: 1))
    cache.remember(.notARequest, for: 1)
    #expect(!cache.isRequest(id: 1))
    cache.remember(.request(nil), for: 2)
    #expect(cache.isRequest(id: 2))
    cache.remember(.request(HTTPExchange(redirects: [],
                                         final: HTTPExchange.Head(version: "1.1", status: 200,
                                                                  reason: "OK", headers: []),
                                         bodyLines: [], bodyKind: .json, timing: nil)), for: 3)
    #expect(cache.isRequest(id: 3))
    // And it forgets with the entry, so a block whose rows have been evicted is not still claimed
    // to be a request by a menu built after the fact.
    cache.prune(olderThan: 3)
    #expect(!cache.isRequest(id: 2))
    #expect(cache.isRequest(id: 3))
}
