import Testing
@testable import NyxCore

private func region(id: UInt32 = 4, output: Int = 5, status: Int32? = 0, duration: Double? = 8.8,
                    started: Bool = true) -> CommandRegion {
    // A region with no status and no duration is a running command; it started at clock 0.
    CommandRegion(promptRow: 0, outputStart: started ? 1 : nil, endRow: max(0, output),
                  exitStatus: status, duration: duration, id: id,
                  startedAt: (status == nil && duration == nil) ? 0 : nil)
}

private func block(_ region: CommandRegion) -> CommandBlock {
    CommandBlock(region: region, visibleRows: 0..<6, showsHeader: true)
}

@Test func aFinishedCommandSummarisesStatusAndTimeWithAnOpenChevron() {
    let h = block(region(status: 1)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(h.state == .failed(status: 1))
    #expect(h.summary == "exit 1 · 8.8s")
    #expect(h.chevron == "\u{25BE}")
    #expect(h.summaryWithChevron == "exit 1 · 8.8s \u{25BE}")
}

@Test func aQuickSuccessShowsOnlyTheChevron() {
    let h = block(region(duration: 0.2)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(h.summary == "")
    #expect(h.summaryWithChevron == "\u{25BE}")
}

@Test func aFoldedBlockPointsRight() {
    var f = OutputFolding()
    f.fold(4, .all)
    let h = block(region()).header(now: 100, folding: f, notifyArmed: false, anyFolds: true, hasOutput: true)
    #expect(h.folded)
    #expect(h.chevron == "\u{25B8}")
}

@Test func aRunningCommandCountsUpAfterOneSecond() {
    let running = region(status: nil, duration: nil)
    let early = block(running).header(now: 0.4, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(early.summary == "")
    #expect(early.isRunning)
    let later = block(running).header(now: 12.3, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(later.state == .running(elapsed: 12.3))
    #expect(later.summary == "12s")
}

@Test func aCommandWithoutOutputHasNoChevronAndNoOutputActions() {
    let h = block(region(output: 0, started: false)).header(now: 100, folding: OutputFolding(),
                                                            notifyArmed: false, anyFolds: false,
                                                            hasOutput: false)
    #expect(!h.hasOutput)
    #expect(h.chevron == "")
    #expect(h.actions.first { $0.action == .copyOutput }?.enabled == false)
    #expect(h.actions.first { $0.action == .toggleFold }?.enabled == false)
}

@Test func theMenuListsActionsInTheSpecifiedOrder() {
    let h = block(region(status: nil, duration: nil)).header(now: 5, folding: OutputFolding(),
                                                             notifyArmed: true, anyFolds: false, hasOutput: true)
    #expect(h.actions.map(\.action) == [
        .copyCommand, .copyOutput, .copyMarkdown, .saveOutput,
        .runAgain, .editAndRun,
        .toggleFold, .toggleFoldAll,
        .notifyWhenDone(armed: true),
    ])
}

@Test func notifyWhenDoneIsOfferedOnlyWhileRunning() {
    let done = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(!done.actions.contains { if case .notifyWhenDone = $0.action { return true } else { return false } })
}

@Test func failedIsTrueOnlyForTheFailedState() {
    let failed = block(region(status: 1)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    let finished = block(region(status: 0)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    let running = block(region(status: nil, duration: nil)).header(now: 1, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(failed.failed)
    #expect(!finished.failed)
    #expect(!running.failed)
}

@Test func titlesFollowTheState() {
    #expect(BlockAction.toggleFold.title == "Fold Output")
    #expect(BlockAction.notifyWhenDone(armed: false).title == "Notify When Done")
    var f = OutputFolding()
    f.fold(4, .all)
    let h = block(region()).header(now: 100, folding: f, notifyArmed: false, anyFolds: true, hasOutput: true)
    #expect(h.title(for: .toggleFold) == "Unfold Output")
    #expect(h.title(for: .toggleFoldAll) == "Unfold Everything")
}

// MARK: - The HTTP summary

private func httpSummary(_ text: String, _ tone: HTTPSummary.Tone) -> HTTPSummary {
    HTTPSummary(text: text, tone: tone)
}

/// The whole point of the request workbench's first visible piece: after a curl, the row says what
/// the server said, not how long the process took.
@Test func httpSummaryReplacesDuration() {
    let plain = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                       anyFolds: false, hasOutput: true)
    #expect(plain.summary == "8.8s")
    #expect(plain.tone == .plain)

    let http = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                      anyFolds: false, hasOutput: true,
                                      httpSummary: httpSummary("200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json", .success))
    #expect(http.summary == "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json")
    #expect(http.summaryWithChevron == "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json \u{25BE}")
    #expect(http.tone == .success)
}

/// A 3xx and a 4xx are two different things and must not be the same colour, which is the reason
/// `tone` exists at all rather than the view switching on `failed`.
@Test func theToneFollowsTheStatusClass() {
    func tone(_ summary: HTTPSummary?) -> SummaryTone {
        block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                               anyFolds: false, hasOutput: true, httpSummary: summary).tone
    }
    #expect(tone(httpSummary("301 \u{b7} 12 ms", .redirect)) == .redirect)
    #expect(tone(httpSummary("500 \u{b7} 12 ms", .failure)) == .failure)
    #expect(tone(nil) == .plain)
}

/// A curl that returned 404 exits 0, so the block itself is a success and only the summary says
/// otherwise. Without this the row would be grey and read as fine.
@Test func aFailedRequestInASucceedingCommandIsStillColouredAsAFailure() {
    let h = block(region(status: 0)).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                            anyFolds: false, hasOutput: true,
                                            httpSummary: httpSummary("404 \u{b7} 31 ms", .failure))
    #expect(!h.failed)
    #expect(h.tone == .failure)
}

/// A running block has no HTTP summary yet -- the transcript is half written -- and must keep the
/// amber the spine already uses for the same state.
@Test func aRunningBlockKeepsTheRunningTone() {
    let h = block(region(status: nil, duration: nil)).header(now: 12, folding: OutputFolding(),
                                                             notifyArmed: false, anyFolds: false,
                                                             hasOutput: true)
    #expect(h.tone == .running)
}

@Test func eachToneTakesItsColourFromTheTheme() {
    let palette = Palette.xtermDefault()
    #expect(SummaryTone.success.color(in: palette) == palette.readable(2))
    #expect(SummaryTone.redirect.color(in: palette) == palette.readable(3))
    #expect(SummaryTone.running.color(in: palette) == palette.readable(3))
    #expect(SummaryTone.failure.color(in: palette) == palette.readable(1))
    #expect(SummaryTone.plain.color(in: palette) == palette.noteForeground)
}

/// A curl that answered 200 but exited non-zero is a failed command, and the block that shows it
/// must not be green. The tone comes from the summary, so this is the one place it can go wrong.
@Test func aRequestThatAnsweredButFailedIsColouredAsAFailure() throws {
    let exchange = HTTPExchange.parse(lines: [
        "HTTP/2 200",
        "content-type: application/json",
        "",
        "{\"ok\":true}",
        "",
        "\(RequestRun.sentinelPrefix)200 0.142 0.003 0.049 0.106 0.140 1229 0 application/json",
    ])
    let summary = try #require(HTTPSummary.make(exchange: exchange, exitStatus: 23, duration: 0.2))
    let h = block(region(status: 23)).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                             anyFolds: false, hasOutput: true, httpSummary: summary)
    #expect(h.tone == .failure)
    #expect(h.summary.hasSuffix("exit 23"))
}
