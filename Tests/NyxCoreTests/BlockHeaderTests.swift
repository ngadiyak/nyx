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

@Test func aFinishedCommandSummarisesStatusAndTime() {
    let h = block(region(status: 1)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(h.state == .failed(status: 1))
    #expect(h.summary == "exit 1 · 8.8s")
}

/// A command that took a fifth of a second has nothing worth saying, so its row carries no summary
/// at all -- there is no chevron left to keep it on screen (§2.4).
@Test func aQuickSuccessHeaderSaysNothing() {
    let h = block(region(duration: 0.2)).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(h.summary == "")
}

@Test func aFoldedBlockKnowsItIsFolded() {
    var f = OutputFolding()
    f.fold(4, .all)
    let h = block(region()).header(now: 100, folding: f, notifyArmed: false, anyFolds: true, hasOutput: true)
    #expect(h.folded)
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

/// A `sleep 10` one second in has nothing to fold. That rule still decides the gutter cap and the
/// strip's `Fold` pill, which is why `hasOutput` and the disabled `.toggleFold` are still asserted.
@Test func aCommandWithoutOutputHasNoOutputActions() {
    let h = block(region(output: 0, started: false)).header(now: 100, folding: OutputFolding(),
                                                            notifyArmed: false, anyFolds: false,
                                                            hasOutput: false)
    #expect(!h.hasOutput)
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

// MARK: - The Request group

/// A block that ran a `curl` offers the four things you can do to a *request* -- open it as a form,
/// copy it as another tool's code, keep it as a button -- and it offers them after `Edit and Run`,
/// where the other "do it again" actions are.
@Test func httpBlocksOfferTheRequestGroup() {
    let h = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                   anyFolds: false, hasOutput: true, isHTTP: true)
    #expect(h.isHTTP)
    #expect(h.actions.map(\.action) == [
        .copyCommand, .copyOutput, .copyMarkdown, .saveOutput,
        .runAgain, .editAndRun,
        .openInWorkbench, .copyAs(.httpie), .copyAs(.fetch), .copyAs(.pythonRequests), .copyAs(.go),
        .saveAsButton, .saveToProject,
        // The two watch rows close the Request group; `theWatchActionsAreInTheRequestGroup` is
        // where their own rules live.
        .runEvery(seconds: 5), .watch(WatchPlan(interval: 5, stop: .never)),
        // The Lens group follows it; `lensGroupForHTTPBlocks` is where its own rules live.
        .setLens(.raw), .setLens(.pretty), .setLens(.headers), .setLens(.body),
        .setLens(.filter("")), .setLens(.grep("")), .setLens(.diff(previousCommandID: 0)),
        .copyBody, .copyHeaders,
        .toggleFold, .toggleFoldAll,
    ])
    // Hoisted: `allSatisfy` inside the macro is a throwing call the expansion cannot handle.
    // Everything but the diff, which needs a previous run of the same request to compare against.
    let allEnabled = h.actions.filter { $0.action != .setLens(.diff(previousCommandID: 0)) }
        .allSatisfy(\.enabled)
    #expect(allEnabled)
    // The separator before the group: the menu builders draw one wherever this is true.
    #expect(BlockAction.openInWorkbench.startsGroup)
}

/// Every other block -- which is almost every block -- has no Request group at all. Nothing is
/// greyed out: an action that cannot apply is absent, not offered and refused.
@Test func plainBlocksDoNot() {
    let h = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                   anyFolds: false, hasOutput: true)
    #expect(!h.isHTTP)
    #expect(!h.actions.contains { $0.action == .openInWorkbench })
    #expect(!h.actions.contains { if case .copyAs = $0.action { return true } else { return false } })
    #expect(!h.actions.contains { $0.action == .saveAsButton })
    #expect(!h.actions.contains { $0.action == .saveToProject })
}

@Test func theRequestActionsAreTitledForAMenu() {
    #expect(BlockAction.openInWorkbench.title == "Open in Workbench\u{2026}")
    #expect(BlockAction.copyAs(.httpie).title == "Copy as HTTPie")
    #expect(BlockAction.copyAs(.fetch).title == "Copy as JavaScript fetch")
    #expect(BlockAction.copyAs(.pythonRequests).title == "Copy as Python requests")
    #expect(BlockAction.copyAs(.go).title == "Copy as Go")
    #expect(BlockAction.saveAsButton.title == "Save as Button\u{2026}")
    #expect(BlockAction.saveToProject.title == "Save to Project\u{2026}")
}

// MARK: - The summary's colour is a line of text, and has to read like one

/// Every tone, in every built-in theme, at or above 4.5:1 against that theme's own background.
///
/// `Palette.readable(_:)` only ever *picks* between a colour and its bright variant; where neither
/// is legible it hands back the better of two unreadable colours. Solarized Dark's red pair is
/// 3.25:1 and 3.26:1, so a failed request's `404 · 12 ms` was drawn at 3.25:1 -- worse than the
/// body text around it, on the one line that exists to be noticed.
@Test func everyToneReadsAgainstEveryBuiltInTheme() {
    let tones: [SummaryTone] = [.plain, .running, .success, .redirect, .failure]
    for (name, palette) in Themes.builtin {
        for tone in tones {
            let colour = tone.color(in: palette)
            let ratio = RGB.contrast(colour, palette.background)
            #expect(ratio >= 4.5, "\(name)/\(tone): \(String(format: "%.2f", ratio)):1")
        }
    }
}

/// And a colour that was already legible is left exactly as the theme wrote it: lifting is a last
/// resort, not a wash over every theme's palette.
@Test func aLegibleToneIsNotTouched() {
    let palette = Palette.xtermDefault()
    let picked = palette.readable(2)
    if RGB.contrast(picked, palette.background) >= 4.5 {
        #expect(SummaryTone.success.color(in: palette) == picked)
    }
}

// MARK: - The Lens group

private func httpHeader(lens: ResponseLens? = nil, tooLarge: Bool = false,
                        hasPrevious: Bool = false) -> BlockHeader {
    block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false,
                           hasOutput: true, isHTTP: true, lens: lens, lensTooLarge: tooLarge,
                           hasPreviousRun: hasPrevious)
}

@Test func lensGroupForHTTPBlocks() {
    let actions = httpHeader().actions.map(\.action)
    #expect(actions == [
        .copyCommand, .copyOutput, .copyMarkdown, .saveOutput,
        .runAgain, .editAndRun,
        .openInWorkbench, .copyAs(.httpie), .copyAs(.fetch), .copyAs(.pythonRequests), .copyAs(.go),
        .saveAsButton, .saveToProject,
        .runEvery(seconds: 5), .watch(WatchPlan(interval: 5, stop: .never)),
        .setLens(.raw), .setLens(.pretty), .setLens(.headers), .setLens(.body),
        .setLens(.filter("")), .setLens(.grep("")), .setLens(.diff(previousCommandID: 0)),
        .copyBody, .copyHeaders,
        .toggleFold, .toggleFoldAll,
    ])
    // The group's own separator.
    #expect(BlockAction.setLens(.raw).startsGroup)
    #expect(!BlockAction.setLens(.pretty).startsGroup)
    // A block that is not a request has no lens group at all: an action that cannot apply is
    // absent, not greyed.
    let plain = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                       anyFolds: false, hasOutput: true)
    #expect(!plain.actions.contains { if case .setLens = $0.action { return true } else { return false } })
}

/// Diffing needs something to diff against. Offered and refused is worse than offered greyed: the
/// row says the feature exists and that this block cannot use it yet.
@Test func diffNeedsAPreviousRun() {
    let without = httpHeader().actions.first { $0.action == .setLens(.diff(previousCommandID: 0)) }
    #expect(without?.enabled == false)
    let with = httpHeader(hasPrevious: true).actions.first { $0.action == .setLens(.diff(previousCommandID: 0)) }
    #expect(with?.enabled == true)
}

@Test func activeLensIsChecked() {
    // Raw is the state a block starts in, and nil is how it is spelled.
    #expect(httpHeader().isChecked(.setLens(.raw)))
    #expect(!httpHeader().isChecked(.setLens(.pretty)))
    #expect(httpHeader(lens: .pretty).isChecked(.setLens(.pretty)))
    #expect(!httpHeader(lens: .pretty).isChecked(.setLens(.raw)))
    // A filter with a path in it still ticks the row that opens the field: the row is the *kind*
    // of lens, not the expression.
    #expect(httpHeader(lens: .filter(".a.b")).isChecked(.setLens(.filter(""))))
    #expect(httpHeader(lens: .grep("nope")).isChecked(.setLens(.grep(""))))
    #expect(!httpHeader(lens: .grep("nope")).isChecked(.setLens(.filter(""))))
    // And the checkmark is not a fold state: nothing else in the menu is ticked.
    #expect(!httpHeader(lens: .pretty).isChecked(.toggleFold))
}

/// A body too large to re-lay-out has no lens, and the menu says why rather than offering seven
/// rows that would all do nothing.
@Test func tooLargeReplacesTheGroup() {
    let actions = httpHeader(tooLarge: true).actions.map(\.action)
    #expect(!actions.contains { if case .setLens = $0 { return true } else { return false } })
    #expect(actions.contains(.lensUnavailable))
    #expect(!actions.contains(.copyBody))
    #expect(BlockAction.lensUnavailable.title
            == "Body too large for lenses \u{2014} Save Output\u{2026}")
    #expect(BlockAction.lensUnavailable.startsGroup)
    // It is a live item: it saves the output, which is the thing that still works.
    let entry = httpHeader(tooLarge: true).actions.first { $0.action == .lensUnavailable }
    #expect(entry?.enabled == true)
}

@Test func theLensActionsAreTitledForAMenu() {
    #expect(BlockAction.setLens(.raw).title == "Raw")
    #expect(BlockAction.setLens(.pretty).title == "Pretty JSON")
    #expect(BlockAction.setLens(.headers).title == "Headers")
    #expect(BlockAction.setLens(.body).title == "Body")
    #expect(BlockAction.setLens(.filter("")).title == "Filter\u{2026}")
    #expect(BlockAction.setLens(.grep("")).title == "Find in Body\u{2026}")
    #expect(BlockAction.setLens(.diff(previousCommandID: 0)).title == "Diff with Previous Run")
    #expect(BlockAction.copyBody.title == "Copy Body")
    #expect(BlockAction.copyHeaders.title == "Copy Headers")
    #expect(BlockAction.toggleLens.title == "Toggle Pretty Response")
}

/// A watched run's header says what the series is doing instead of what the one request answered.
///
/// The substitution is the point: `200 · 142 ms` is already inside `run 12 · 200 · 142 ms · every
/// 5 s`, and printing both would put the same status on the row twice.
@Test func watchHeaderReplacesSummary() {
    var series = WatchSeries(plan: WatchPlan(interval: 5, stop: .never), command: "curl x",
                             startedAt: 0)
    series.runStarted(id: 4, at: 0)
    series.runFinished(id: 4, status: 200, exitStatus: 0, timeTotal: 0.142, body: "", at: 1)
    let watched = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                         anyFolds: false, hasOutput: true,
                                         httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms",
                                                                  tone: .success),
                                         isHTTP: true, watch: series.header())
    #expect(watched.summary == "run 1 \u{b7} 200 \u{b7} 142 ms \u{b7} every 5 s")
    #expect(watched.watch?.showsStop == true)
    #expect(watched.watch?.dots == [.success])
    // The colour still comes from the request: a watch of a failing endpoint must not read green.
    #expect(watched.tone == .success)
    // Without a watch the HTTP summary is what it always was.
    let plain = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                       anyFolds: false, hasOutput: true,
                                       httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms",
                                                                tone: .success),
                                       isHTTP: true)
    #expect(plain.summary == "200 \u{b7} 142 ms")
    #expect(plain.watch == nil)
}

/// While a series is running its block offers Stop; otherwise a request block offers to start one.
@Test func theWatchActionsAreInTheRequestGroup() {
    var series = WatchSeries(plan: WatchPlan(interval: 5, stop: .never), command: "curl x",
                             startedAt: 0)
    series.runStarted(id: 4, at: 0)
    let watching = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                          anyFolds: false, hasOutput: true, isHTTP: true,
                                          watch: series.header())
    let watchingActions = watching.actions.map(\.action)
    #expect(watchingActions.contains(.stopWatch))
    #expect(!watchingActions.contains { if case .runEvery = $0 { return true } else { return false } })

    let idle = httpHeader()
    let idleActions = idle.actions.map(\.action)
    #expect(idleActions.contains(.runEvery(seconds: 5)))
    #expect(idleActions.contains(.watch(WatchPlan(interval: 5, stop: .never))))
    #expect(!idleActions.contains(.stopWatch))
    // Between the request group's last row and the lens group's first, so neither group grows a
    // stray separator.
    let names = idleActions.map { idle.title(for: $0) }
    #expect(names.firstIndex(of: "Run Every 5 s") == names.firstIndex(of: "Save to Project\u{2026}").map { $0 + 1 })
    #expect(BlockAction.runEvery(seconds: 5).title == "Run Every 5 s")
    #expect(BlockAction.runEvery(seconds: 0.5).title == "Run Every 0.5 s")
    #expect(BlockAction.watch(WatchPlan(interval: 5, stop: .never)).title == "Watch\u{2026}")
    #expect(BlockAction.stopWatch.title == "Stop Watching")
    // A block that is not a request cannot be watched: the rows are absent, not greyed.
    let plain = block(region()).header(now: 100, folding: OutputFolding(), notifyArmed: false,
                                       anyFolds: false, hasOutput: true)
    #expect(!plain.actions.contains { if case .runEvery = $0.action { return true } else { return false } })
}
