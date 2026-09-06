import Foundation
import Testing
@testable import NyxCore

/// The buckets a palette row's age is written in. Exact to the second at the boundaries, because
/// "59 min ago" turning into "0 h ago" is the kind of off-by-one nobody notices in a screenshot.
@Test func relativeAges() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func text(_ secondsAgo: TimeInterval) -> String {
        RelativeAge.text(from: now.addingTimeInterval(-secondsAgo), to: now)
    }
    #expect(text(0) == "just now")
    #expect(text(59) == "just now")
    #expect(text(60) == "1 min ago")
    #expect(text(120) == "2 min ago")
    #expect(text(3599) == "59 min ago")
    #expect(text(3600) == "1 h ago")
    #expect(text(86_399) == "23 h ago")
    #expect(text(86_400) == "yesterday")
    #expect(text(172_799) == "yesterday")
    #expect(text(172_800) == "2 days ago")
    #expect(text(864_000) == "10 days ago")
}

/// A clock that went backwards -- a restored session, a machine that resynced NTP -- reads as
/// "just now" rather than as a negative count of minutes.
@Test func aTimeInTheFutureIsJustNow() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(RelativeAge.text(from: now.addingTimeInterval(600), to: now) == "just now")
}

/// The Remote section's ages come from the same function, so the two sections of one palette can
/// never disagree about what "yesterday" means.
@Test func remoteRowsUseTheSameBuckets() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200))
    #expect(RemoteCatalogue.relative(iso, now: now) == "2 h ago")
}
