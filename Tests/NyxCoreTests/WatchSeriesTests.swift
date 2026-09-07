import Testing
@testable import NyxCore

private func watchSeries(interval: Double = 5, stop: WatchPlan.Stop = .never,
                         command: String = "curl -sS https://example.com",
                         startedAt: Double = 0) -> WatchSeries {
    WatchSeries(plan: WatchPlan(interval: interval, stop: stop), command: command, startedAt: startedAt)
}

/// One whole run, started and finished at the given clock readings.
private func watchRun(_ series: inout WatchSeries, id: UInt32, status: Int?, exitStatus: Int32 = 0,
                      timeTotal: Double? = 0.1, body: String = "", start: Double, end: Double) {
    series.runStarted(id: id, at: start)
    series.runFinished(id: id, status: status, exitStatus: exitStatus, timeTotal: timeTotal,
                       body: body, at: end)
}

@Test func waitsIntervalAfterTheRunEnds() {
    var series = watchSeries(interval: 5, startedAt: 0)
    // A watch starts by running: the first send is due the moment it is armed.
    #expect(series.shouldSend(now: 0, shellAtPrompt: true))

    series.runStarted(id: 1, at: 0)
    series.runFinished(id: 1, status: 200, exitStatus: 0, timeTotal: 3, body: "", at: 3)

    #expect(series.phase == .waiting(until: 8))
    // Five seconds after the run *started* is not enough; five after it ended is.
    #expect(!series.shouldSend(now: 5, shellAtPrompt: true))
    #expect(!series.shouldSend(now: 7.9, shellAtPrompt: true))
    #expect(series.shouldSend(now: 8, shellAtPrompt: true))
}

@Test func doesNotSendWhileRunning() {
    var series = watchSeries(interval: 5, startedAt: 0)
    series.runStarted(id: 1, at: 0)

    #expect(series.phase == .running(id: 1))
    #expect(!series.shouldSend(now: 100, shellAtPrompt: true))

    series.runFinished(id: 1, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 100)
    #expect(series.shouldSend(now: 105, shellAtPrompt: true))
}

@Test func strayFinishKeepsTheSeriesRunning() {
    var series = watchSeries(interval: 5, startedAt: 0)
    series.runStarted(id: 5, at: 0)

    // A block that is not this series' run finishing while run 5 is still going changes nothing:
    // the series is still waiting on 5, and must not send a second curl into a busy shell.
    series.runFinished(id: 9, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 1)
    #expect(series.phase == .running(id: 5))
    #expect(!series.shouldSend(now: 1_000_000, shellAtPrompt: true))
    #expect(series.runs.map(\.id) == [5])

    series.runFinished(id: 5, status: 200, exitStatus: 0, timeTotal: 0.2, body: "", at: 2)
    #expect(series.phase == .waiting(until: 7))
    #expect(series.timeline(last: 5) == [.success])

    // With nothing in flight, a finish for a start the pane missed is taken: the series would
    // otherwise sit on a deadline that had already passed and re-send on every tick.
    var missed = watchSeries(interval: 5, startedAt: 0)
    missed.runFinished(id: 1, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 3)
    #expect(missed.runs.map(\.id) == [1])
    #expect(missed.phase == .waiting(until: 8))
}

@Test func doesNotSendAwayFromPrompt() {
    let series = watchSeries(interval: 5, startedAt: 0)
    #expect(!series.shouldSend(now: 10, shellAtPrompt: false))
    #expect(series.shouldSend(now: 10, shellAtPrompt: true))
}

@Test func countStops() {
    var series = watchSeries(interval: 1, stop: .count(3), startedAt: 0)
    watchRun(&series, id: 1, status: 200, start: 0, end: 0.1)
    #expect(series.phase == .waiting(until: 1.1))
    watchRun(&series, id: 2, status: 200, start: 2, end: 2.1)
    #expect(!series.isFinished)

    watchRun(&series, id: 3, status: 200, start: 4, end: 4.1)
    #expect(series.phase == .finished(reason: .count))
    #expect(series.isFinished)
    #expect(!series.shouldSend(now: 1000, shellAtPrompt: true))
    #expect(series.runs.count == 3)
}

@Test func untilStopsWhenConditionHolds() {
    var byStatus = watchSeries(interval: 1, stop: .until(.status(200)), startedAt: 0)
    watchRun(&byStatus, id: 1, status: 503, start: 0, end: 0.1)
    #expect(!byStatus.isFinished)
    watchRun(&byStatus, id: 2, status: 200, start: 2, end: 2.1)
    #expect(byStatus.phase == .finished(reason: .condition))

    var byBody = watchSeries(interval: 1, stop: .until(.bodyContains("ready")), startedAt: 0)
    watchRun(&byBody, id: 1, status: 200, body: "{\"state\":\"pending\"}", start: 0, end: 0.1)
    #expect(!byBody.isFinished)
    watchRun(&byBody, id: 2, status: 200, body: "{\"state\":\"ready\"}", start: 2, end: 2.1)
    #expect(byBody.phase == .finished(reason: .condition))
}

@Test func untilKeepsGoingOtherwise() {
    var series = watchSeries(interval: 1, stop: .until(.statusClass(2)), startedAt: 0)
    watchRun(&series, id: 1, status: 503, start: 0, end: 0.1)
    watchRun(&series, id: 2, status: 404, start: 2, end: 2.1)
    // A run that never got an answer at all is not a 2xx either.
    watchRun(&series, id: 3, status: nil, exitStatus: 7, timeTotal: nil, start: 4, end: 4.1)

    #expect(!series.isFinished)
    #expect(series.phase == .waiting(until: 5.1))
    #expect(series.shouldSend(now: 5.1, shellAtPrompt: true))
}

@Test func statsPercentiles() throws {
    var series = watchSeries(interval: 1, startedAt: 0)
    for i in 1...20 {
        watchRun(&series, id: UInt32(i), status: i == 7 ? 500 : 200, timeTotal: Double(i) / 100,
                 start: Double(i), end: Double(i))
    }

    let stats = try #require(series.stats)
    #expect(stats.count == 20)
    #expect(stats.min == 0.01)
    #expect(stats.max == 0.20)
    // Nearest rank: p50 is the 10th of 20 sorted, p95 the 19th.
    #expect(stats.p50 == 0.10)
    #expect(stats.p95 == 0.19)
    #expect(stats.failures == 1)
    #expect(stats.text == "20 runs \u{b7} p50 100 ms \u{b7} p95 190 ms \u{b7} 1 failure")

    var thin = watchSeries(interval: 1, startedAt: 0)
    watchRun(&thin, id: 1, status: 200, timeTotal: 0.1, start: 0, end: 0.1)
    #expect(thin.stats == nil)
    watchRun(&thin, id: 2, status: 200, timeTotal: nil, start: 2, end: 2.1)
    #expect(thin.stats == nil)
}

@Test func timelineDots() {
    var series = watchSeries(interval: 1, startedAt: 0)
    watchRun(&series, id: 1, status: 200, start: 0, end: 0.1)
    watchRun(&series, id: 2, status: 302, start: 2, end: 2.1)
    watchRun(&series, id: 3, status: 404, start: 4, end: 4.1)
    watchRun(&series, id: 4, status: nil, exitStatus: 7, timeTotal: nil, start: 6, end: 6.1)
    // A curl that exited non-zero is a failure whatever the server said.
    watchRun(&series, id: 5, status: 200, exitStatus: 28, start: 8, end: 8.1)
    series.runStarted(id: 6, at: 10)

    #expect(series.timeline(last: 30) == [.success, .redirect, .failure, .failure, .failure, .running])
    #expect(series.timeline(last: 2) == [.failure, .running])
    #expect(series.timeline(last: 0).isEmpty)
}

@Test func foldsAllButLast() {
    var series = watchSeries(interval: 1, startedAt: 0)
    watchRun(&series, id: 1, status: 200, start: 0, end: 0.1)
    watchRun(&series, id: 2, status: 200, start: 2, end: 2.1)
    watchRun(&series, id: 3, status: 200, start: 4, end: 4.1)

    #expect(series.shouldFold(runAt: 0))
    #expect(series.shouldFold(runAt: 1))
    #expect(!series.shouldFold(runAt: 2))
    #expect(!series.shouldFold(runAt: 3))
    #expect(!series.shouldFold(runAt: -1))
}

@Test func keepsARunWhoseStatusClassChanged() {
    var series = watchSeries(interval: 1, startedAt: 0)
    watchRun(&series, id: 1, status: 200, start: 0, end: 0.1)
    watchRun(&series, id: 2, status: 503, start: 2, end: 2.1)
    watchRun(&series, id: 3, status: 503, start: 4, end: 4.1)
    watchRun(&series, id: 4, status: nil, exitStatus: 7, timeTotal: nil, start: 6, end: 6.1)
    watchRun(&series, id: 5, status: 200, start: 8, end: 8.1)

    #expect(series.shouldFold(runAt: 0))        // the first run: nothing before it to differ from
    #expect(!series.shouldFold(runAt: 1))       // 200 -> 503
    #expect(series.shouldFold(runAt: 2))        // 503 -> 503
    #expect(!series.shouldFold(runAt: 3))       // 503 -> no status at all
    #expect(!series.shouldFold(runAt: 4))       // the newest is never folded
}

@Test func userTypedStops() {
    var series = watchSeries(interval: 5, startedAt: 0)
    watchRun(&series, id: 1, status: 200, start: 0, end: 0.1)
    series.stop(.userTyped)

    #expect(series.phase == .finished(reason: .userTyped))
    #expect(series.isFinished)
    #expect(!series.shouldSend(now: 1000, shellAtPrompt: true))

    // The first reason is the true one: a pane closing later does not rewrite why it stopped.
    series.stop(.paneClosed)
    #expect(series.phase == .finished(reason: .userTyped))

    // A run in flight when the user typed still lands in the record, and does not restart the series.
    var interrupted = watchSeries(interval: 5, startedAt: 0)
    interrupted.runStarted(id: 1, at: 0)
    interrupted.stop(.userTyped)
    interrupted.runFinished(id: 1, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 0.2)
    #expect(interrupted.phase == .finished(reason: .userTyped))
    #expect(interrupted.runs.count == 1)
    #expect(interrupted.timeline(last: 5) == [.success])
}

@Test func conditionTitles() {
    #expect(WatchPlan.Condition.status(200).title == "until 200")
    #expect(WatchPlan.Condition.statusClass(2).title == "until 2xx")
    #expect(WatchPlan.Condition.statusNot(503).title == "until not 503")
    #expect(WatchPlan.Condition.bodyContains("ok").title == "until body contains \"ok\"")
    #expect(WatchPlan.Condition.bodyLacks("pending").title == "until body lacks \"pending\"")

    #expect(WatchPlan.Condition.statusNot(503).holds(status: 200, body: ""))
    #expect(!WatchPlan.Condition.statusNot(503).holds(status: 503, body: ""))
    // Nothing came back at all, which is not a 503.
    #expect(WatchPlan.Condition.statusNot(503).holds(status: nil, body: ""))
    #expect(!WatchPlan.Condition.statusClass(2).holds(status: nil, body: ""))
    #expect(WatchPlan.Condition.bodyLacks("pending").holds(status: 200, body: "ready"))
}

@Test func headerTexts() {
    #expect(WatchPlan(interval: 5, stop: .never).title == "every 5 s")
    #expect(WatchPlan(interval: 0.5, stop: .never).title == "every 0.5 s")
    #expect(WatchPlan(interval: 5, stop: .count(10)).title == "10 times")
    #expect(WatchPlan(interval: 5, stop: .until(.status(200))).title == "every 5 s until 200")
    // An interval that is not a number at all is printed, not converted to an Int that would trap.
    #expect(WatchPlan(interval: .infinity, stop: .never).title == "every inf s")

    var running = watchSeries(interval: 5, startedAt: 0)
    #expect(running.headerText == "every 5 s")
    for i in 1...12 {
        watchRun(&running, id: UInt32(i), status: 200, timeTotal: 0.142, start: Double(i * 10),
                 end: Double(i * 10) + 0.142)
    }
    #expect(running.headerText == "run 12 \u{b7} 200 \u{b7} 142 ms \u{b7} every 5 s")

    // While the next run is in flight the last answer stays: dropping it shrank the strip and
    // re-laid it out every interval. See `theHeaderKeepsTheLastAnswerWhileTheNextRunIsInFlight`.
    running.runStarted(id: 13, at: 200)
    #expect(running.headerText == "run 13 \u{b7} 200 \u{b7} 142 ms \u{b7} every 5 s")

    var finished = watchSeries(interval: 1, startedAt: 0)
    watchRun(&finished, id: 1, status: 200, timeTotal: 0.1, start: 0, end: 0.1)
    watchRun(&finished, id: 2, status: 500, timeTotal: 0.2, start: 2, end: 2.2)
    finished.stop(.stopped)
    #expect(finished.headerText == "2 runs \u{b7} p50 100 ms \u{b7} p95 200 ms \u{b7} 1 failure")

    // Too few timings to say anything about latency: the count is all there is.
    var untimed = watchSeries(interval: 1, startedAt: 0)
    for i in 1...3 {
        watchRun(&untimed, id: UInt32(i), status: nil, exitStatus: 7, timeTotal: nil,
                 start: Double(i), end: Double(i))
    }
    untimed.stop(.stopped)
    #expect(untimed.headerText == "stopped after 3 runs")

    var never = watchSeries(interval: 1, startedAt: 0)
    never.stop(.paneClosed)
    #expect(never.headerText == "stopped")

    // A run that failed outright says so instead of showing a status it never had.
    var failed = watchSeries(interval: 5, startedAt: 0)
    watchRun(&failed, id: 1, status: nil, exitStatus: 7, timeTotal: nil, start: 0, end: 0.1)
    #expect(failed.headerText == "run 1 \u{b7} exit 7 \u{b7} every 5 s")
}

/// A series adopts the run it is watching and the run it has just typed, and nothing else.
///
/// The regression this is for: a quick-action button, a paste or the workbench's own Run reaches
/// the shell without stopping a *waiting* series, and its block was taken as the series' newest
/// run -- carrying the header, the dots and the Stop button, folding the real newest run, and
/// counting a request nobody watched into the statistics and the stop rule.
@Test func ownsOnlyItsOwnRuns() {
    var series = watchSeries(interval: 5, startedAt: 0)
    // Waiting for its first run, nothing typed yet: no block in the pane is its own.
    #expect(!series.owns(finishedBlock: 9, outstanding: false, typedAfter: 8))

    // Typed and not yet seen to start. A local request can begin and end between two 250 ms
    // ticks, so the next command to finish is that run whatever its id turns out to be -- as long
    // as it is newer than everything that had already run when the line was typed.
    #expect(series.owns(finishedBlock: 9, outstanding: true, typedAfter: 8))

    series.runStarted(id: 4, at: 0)
    #expect(series.owns(finishedBlock: 4, outstanding: false, typedAfter: 3))
    // Somebody else's curl, finishing while the series' own run is still going.
    #expect(!series.owns(finishedBlock: 5, outstanding: false, typedAfter: 3))
    #expect(!series.owns(finishedBlock: 5, outstanding: true, typedAfter: 3))

    series.runFinished(id: 4, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 1)
    // Back to waiting: a stranger's block that finishes now is not a run of this series.
    #expect(!series.owns(finishedBlock: 5, outstanding: false, typedAfter: 4))
    // And the outstanding case has a floor. A block older than a run already recorded is never
    // the run just typed: the pane's exchange cache is trimmed, and a trimmed block that scrolls
    // back on screen is read again -- which without this counted last Tuesday's request as a run.
    #expect(!series.owns(finishedBlock: 3, outstanding: true, typedAfter: 4))
    #expect(series.owns(finishedBlock: 5, outstanding: true, typedAfter: 4))

    series.stop(.stopped)
    #expect(!series.owns(finishedBlock: 4, outstanding: true, typedAfter: 3))
}

/// The *first* run needs the floor too, and `runs.last` cannot give it one.
///
/// A series with no runs yet had a floor of zero, so every block in the pane was newer than it.
/// The outstanding window is the pane saying "I typed a run and have not seen it start", and the
/// block it hands over is whatever ran last -- which on a restored session, or a `curl` that
/// finished while the tab was in the background, is a stale block nobody watched. It became run 1:
/// its status went into the timeline, its body became the diff's "previous", and `Run until 200`
/// could stop on a response from before the watch existed.
@Test func theFirstRunHasAFloorToo() {
    var series = watchSeries(interval: 5, startedAt: 0)
    // Newest thing that had already run when the line was typed: block 12.
    #expect(!series.owns(finishedBlock: 12, outstanding: true, typedAfter: 12))
    #expect(!series.owns(finishedBlock: 7, outstanding: true, typedAfter: 12))
    // The run itself gets the next id, and is adopted.
    #expect(series.owns(finishedBlock: 13, outstanding: true, typedAfter: 12))

    // A pane with nothing behind it at all: floor zero, and the first block is still the run.
    series = watchSeries(interval: 5, startedAt: 0)
    #expect(series.owns(finishedBlock: 1, outstanding: true, typedAfter: 0))
}

/// The sentence keeps the last answer while the next run is in flight.
///
/// `run 12 · 200 · 142 ms` lost its status and its latency the moment run 13 was typed, so the
/// strip shrank and re-laid itself out every interval -- a header that flickers between two widths
/// for as long as the watch lasts. The number a reader wants is the last one that came back.
@Test func theHeaderKeepsTheLastAnswerWhileTheNextRunIsInFlight() {
    var series = watchSeries(interval: 5, startedAt: 0)
    watchRun(&series, id: 1, status: 200, timeTotal: 0.142, start: 0, end: 0.2)
    #expect(series.headerText == "run 1 \u{b7} 200 \u{b7} 142 ms \u{b7} every 5 s")

    series.runStarted(id: 2, at: 5)
    #expect(series.headerText == "run 2 \u{b7} 200 \u{b7} 142 ms \u{b7} every 5 s")

    // And the new answer replaces it once it is in.
    series.runFinished(id: 2, status: 503, exitStatus: 0, timeTotal: 0.31, body: "", at: 5.3)
    #expect(series.headerText == "run 2 \u{b7} 503 \u{b7} 310 ms \u{b7} every 5 s")

    // Nothing has come back yet: there is nothing to keep.
    var fresh = watchSeries(interval: 5, startedAt: 0)
    fresh.runStarted(id: 1, at: 0)
    #expect(fresh.headerText == "run 1 \u{b7} every 5 s")
}

/// The sentence describes the *series*, so its colour has to as well.
///
/// `11 runs · p50 150 ms · p95 200 ms · 1 failure` took its tone from the latest run and was drawn
/// in success green -- a sentence whose last three words say something failed.
@Test func aSeriesWithAFailureInItIsNotGreen() {
    var series = watchSeries(interval: 1, startedAt: 0)
    #expect(series.tone == .plain)

    watchRun(&series, id: 1, status: 200, start: 0, end: 0.1)
    #expect(series.tone == .success)

    watchRun(&series, id: 2, status: 503, start: 2, end: 2.1)
    #expect(series.tone == .failure)

    // A later success does not clear it: the failure happened and the sentence still counts it.
    watchRun(&series, id: 3, status: 200, start: 4, end: 4.1)
    #expect(series.tone == .failure)
    #expect(series.header().tone == .failure)

    // A run in flight does not decide the tone either way.
    var redirects = watchSeries(interval: 1, startedAt: 0)
    watchRun(&redirects, id: 1, status: 301, start: 0, end: 0.1)
    redirects.runStarted(id: 2, at: 2)
    #expect(redirects.tone == .redirect)
}

/// The running sentence is ordered the way the readout ladder drops it: the run number first, the
/// interval last, because the interval is the first thing a narrow strip gives up (§2.6).
@Test func theRunningHeaderPutsTheIntervalLast() {
    var series = WatchSeries(plan: WatchPlan(interval: 5, stop: .never), command: "curl x",
                             startedAt: 0)
    series.runStarted(id: 1, at: 0)
    series.runFinished(id: 1, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 1)
    #expect(series.headerText == "run 1 · 200 · 100 ms · every 5 s")
    let header = series.header(dots: 30)
    #expect(header.hiddenRuns == 0)
}

/// The timeline stops being silent about its cap: thirty dots and a `+N` in front of them.
@Test func theTimelineSaysHowManyRunsItIsNotShowing() {
    var series = WatchSeries(plan: WatchPlan(interval: 1, stop: .never), command: "curl x",
                             startedAt: 0)
    for id in UInt32(1)...48 {
        series.runStarted(id: id, at: Double(id))
        series.runFinished(id: id, status: 200, exitStatus: 0, timeTotal: 0.1, body: "",
                           at: Double(id) + 0.1)
    }
    let header = series.header(dots: 30)
    #expect(header.dots.count == 30)
    #expect(header.hiddenRuns == 18)
}
