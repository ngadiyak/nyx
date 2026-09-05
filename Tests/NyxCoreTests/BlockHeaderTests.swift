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
