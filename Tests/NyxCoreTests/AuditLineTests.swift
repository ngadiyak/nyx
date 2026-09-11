import Foundation
import Testing
@testable import NyxCore

private let date = Date(timeIntervalSince1970: 1_788_609_600) // 2026-09-05T12:00:00Z

@Test func attachedLineFormat() {
    let text = AuditLine.text(.attached(device: "MacBook", session: "zsh"), at: date)
    #expect(text == "2026-09-05T12:00:00Z  attached  MacBook → zsh")
}

@Test func tookControlLineFormat() {
    let text = AuditLine.text(.tookControl(device: "MacBook", session: "zsh"), at: date)
    #expect(text == "2026-09-05T12:00:00Z  took control  MacBook → zsh")
}

@Test func detachedLineFormat() {
    let text = AuditLine.text(.detached(device: "MacBook", session: "zsh"), at: date)
    #expect(text == "2026-09-05T12:00:00Z  detached  MacBook → zsh")
}

@Test func pairedLineFormat() {
    let text = AuditLine.text(.paired("MacBook"), at: date)
    #expect(text == "2026-09-05T12:00:00Z  paired  MacBook")
}

@Test func removedLineFormat() {
    let text = AuditLine.text(.removed("MacBook"), at: date)
    #expect(text == "2026-09-05T12:00:00Z  removed  MacBook")
}

@Test func sessionEndedLineFormat() {
    let text = AuditLine.text(.sessionEnded(session: "zsh"), at: date)
    #expect(text == "2026-09-05T12:00:00Z  session ended  zsh")
}

private let now = ISO8601DateFormatter().date(from: "2026-09-10T18:20:00Z")!

/// §7.4 and D15: the Remote page's "Recent activity" was the file, verbatim --
/// `2026-09-01T10:00:00Z  paired  Nik's MacBook Pro` -- which is the right format for `tail -f` and
/// the wrong one for a box six lines tall on a settings page. The words do not change; the stamp
/// becomes the age, from the same `RelativeAge` the palette's Requests rows use, so one application
/// cannot describe the same moment two ways.
@Test func anAuditLineIsShownWithARelativeAge() {
    #expect(AuditLine.display("2026-09-10T18:16:12Z  removed  alpha", now: now)
        == "3 min ago  removed  alpha")
    #expect(AuditLine.display("2026-09-10T18:19:50Z  attached  alpha → zsh — ~", now: now)
        == "just now  attached  alpha → zsh — ~")
    #expect(AuditLine.display("2026-09-01T10:00:00Z  paired  Nik's MacBook Pro", now: now)
        == "9 days ago  paired  Nik's MacBook Pro")
}

/// A line whose head is not a timestamp is passed through untouched. The file is plain text a
/// person may have opened in an editor, and a page that swallowed a line it did not recognise would
/// be hiding the one line worth reading.
@Test func aLineWithoutATimestampIsLeftAlone() {
    #expect(AuditLine.display("not a log line at all", now: now) == "not a log line at all")
    #expect(AuditLine.display("", now: now) == "")
}

/// The round trip, so the two halves cannot drift: whatever `text` writes, `display` reads.
@Test func everyEventTextRoundTripsThroughDisplay() {
    let at = ISO8601DateFormatter().date(from: "2026-09-10T18:19:00Z")!
    for event: AuditLine.Event in [.paired("beta"), .removed("beta"),
                                   .attached(device: "beta", session: "zsh"),
                                   .tookControl(device: "beta", session: "zsh"),
                                   .detached(device: "beta", session: "zsh"),
                                   .sessionEnded(session: "zsh")] {
        let shown = AuditLine.display(AuditLine.text(event, at: at), now: now)
        #expect(shown.hasPrefix("1 min ago  "), "\(event) -> \(shown)")
        #expect(!shown.contains("2026-"))
    }
}
