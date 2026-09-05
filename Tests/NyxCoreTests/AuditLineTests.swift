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
