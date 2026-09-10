import Foundation

/// What "watch this request" was asked to do: how often, and when to stop.
///
/// The plan is what the user chose; `WatchSeries` is what became of it. Split in two because the
/// plan is written once (in a menu or a popover) and read forever, while the series changes on
/// every run -- and because a plan with no series yet still has to be able to say what it will do,
/// which is what `title` is for.
public struct WatchPlan: Equatable {
    /// What has to be true of a run for the series to stop at it.
    ///
    /// Every case is answerable from what a finished block already holds -- its status and the text
    /// of its body. Nothing here may need the network, the headers, or a second request: a stop
    /// rule that could not be evaluated from the transcript would be a watch that never stops.
    public enum Condition: Equatable {
        case status(Int)
        /// The hundreds digit: `2` for any 2xx.
        case statusClass(Int)
        case statusNot(Int)
        case bodyContains(String)
        case bodyLacks(String)

        /// `status` is nil when curl never got an answer -- DNS failed, the connection was refused.
        ///
        /// That case decides two of these differently, and deliberately: a run with no status is
        /// not a 2xx (`statusClass` is false, so "until 2xx" keeps waiting through an outage), but
        /// it is also *not a 503* (`statusNot` is true, so "until not 503" stops -- the server the
        /// user was waiting out has stopped answering at all, which is news they asked for).
        public func holds(status: Int?, body: String) -> Bool {
            switch self {
            case .status(let code): return status == code
            case .statusClass(let hundreds):
                guard let status else { return false }
                return status / 100 == hundreds
            case .statusNot(let code): return status != code
            case .bodyContains(let text): return body.contains(text)
            case .bodyLacks(let text): return !body.contains(text)
            }
        }

        /// Reads as the tail of a plan: "every 5 s **until 200**".
        public var title: String {
            switch self {
            case .status(let code): return "until \(code)"
            case .statusClass(let hundreds): return "until \(hundreds)xx"
            case .statusNot(let code): return "until not \(code)"
            case .bodyContains(let text): return "until body contains \"\(text)\""
            case .bodyLacks(let text): return "until body lacks \"\(text)\""
            }
        }
    }

    public enum Stop: Equatable {
        /// Until the user stops it, the shell is typed into, or the pane closes.
        case never
        case count(Int)
        case until(Condition)
    }

    /// Seconds between the end of one run and the start of the next. See `WatchSeries.runFinished`
    /// for why it is measured from the end.
    public let interval: Double
    public let stop: Stop

    public init(interval: Double, stop: Stop) {
        self.interval = interval; self.stop = stop
    }

    /// "every 5 s", "10 times", "every 5 s until 200" -- the words in the header, the ⋯ menu and
    /// the popover, so a plan cannot be described two ways in one window.
    ///
    /// A counted plan says only how many times, not how often: "10 times" is what the user asked
    /// for, and "every 5 s, 10 times" is a longer line that answers a question nobody asked while
    /// they are waiting for the tenth.
    public var title: String {
        switch stop {
        case .never: return "every \(WatchPlan.secondsText(interval)) s"
        case .count(let times): return "\(times) times"
        case .until(let condition): return "every \(WatchPlan.secondsText(interval)) s \(condition.title)"
        }
    }

    /// Whole seconds without a decimal point, anything else as it was written.
    ///
    /// Deliberately the same rule as `WatchPlanRequest.summary`, which names the same interval in
    /// the Run menu one step earlier: the item a user clicks ("every 5 s") and the tail of the
    /// header they then read ("run 12 · 200 · 142 ms · every 5 s") have to be the same words, or the
    /// header looks like a different plan from the one they chose.
    ///
    /// The finite guard is not decoration: `Int(.infinity)` traps, and an interval arrives here
    /// from a text field. A nonsensical one is printed as it stands -- a plan that reads oddly is
    /// recoverable, a crashed terminal is not.
    static func secondsText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds.magnitude < 1e9 else { return String(seconds) }
        return seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

/// A watched request as it happens: what has run, what is running, and when the next one is due.
///
/// Pure and clock-injected -- every method that cares about time takes the reading as an argument.
/// The pane owns a `Timer` and a prompt state; this owns the decisions, so "does it run again now"
/// is a question a test can ask a thousand times without waiting a thousand seconds.
///
/// The two rules that keep a watch from ruining a shell are both here rather than in the pane:
/// a run is only ever sent at a prompt (typing into a half-written command line would be a disaster
/// the user cannot undo), and never while the previous one is still going (two curls interleaving
/// their output into one block is unreadable, and a slow endpoint would queue an unbounded number
/// of them).
public struct WatchSeries: Equatable {
    /// One run of the watched command. Written twice: once when it starts (status and timing
    /// unknown) and once when it finishes.
    public struct Run: Equatable {
        /// The block id, which is how the pane finds the rows this run produced -- to fold them,
        /// to lens them, to diff them against the run before.
        public let id: UInt32
        public let status: Int?
        public let exitStatus: Int32
        /// curl's own `time_total`. nil for a run that never reported one -- a command that failed
        /// before the sentinel, or one that brought its own `-w`.
        public let timeTotal: Double?
        /// When this run last changed: its start while it is running, its finish once it has
        /// finished. The finish is what the next run's interval is measured from.
        public let at: Double

        public init(id: UInt32, status: Int?, exitStatus: Int32, timeTotal: Double?, at: Double) {
            self.id = id; self.status = status; self.exitStatus = exitStatus
            self.timeTotal = timeTotal; self.at = at
        }
    }

    /// One run in the header's strip of dots. The same three classes as `HTTPSummary.Tone` -- so a
    /// dot and the block's own summary can never disagree about whether a run went well -- plus the
    /// one state a finished summary has no word for.
    public enum Dot: Equatable { case success, redirect, failure, running }

    /// What a series of runs came to, in the words the header uses once it has stopped.
    public struct Stats: Equatable {
        /// Every finished run, not only the timed ones: it answers "how many times did this run",
        /// and a run that failed before curl could report a timing still ran.
        public let count: Int
        public let min: Double
        public let p50: Double
        public let p95: Double
        public let max: Double
        public let failures: Int

        public init(count: Int, min: Double, p50: Double, p95: Double, max: Double, failures: Int) {
            self.count = count; self.min = min; self.p50 = p50
            self.p95 = p95; self.max = max; self.failures = failures
        }

        /// "20 runs · p50 138 ms · p95 210 ms · 1 failure".
        ///
        /// The median and the tail, because those are the two numbers that say whether an endpoint
        /// is well: a mean would hide the one request in twenty that took two seconds, which is the
        /// request the user is watching for. `min` and `max` are carried for a caller that wants
        /// them (a tooltip, a copied line) but stay off a header that has to be read at a glance.
        /// A run with no failures says nothing about failures rather than "0 failures".
        public var text: String {
            var parts = ["\(count) \(count == 1 ? "run" : "runs")"]
            if let median = HTTPSummary.timeText(p50) { parts.append("p50 " + median) }
            if let tail = HTTPSummary.timeText(p95) { parts.append("p95 " + tail) }
            if failures > 0 { parts.append("\(failures) \(failures == 1 ? "failure" : "failures")") }
            return parts.joined(separator: " \u{b7} ")
        }
    }

    /// Waiting for the next run to be due, running one, or done. `waiting(until:)` carries the
    /// deadline rather than the pane holding it, so a series restored or inspected out of band
    /// still knows when it is next due.
    public enum Phase: Equatable {
        case waiting(until: Double)
        case running(id: UInt32)
        case finished(reason: Finish)
    }

    /// Why a series stopped. Kept apart from `Phase` because the header says different things for
    /// a plan that completed and a plan that was interrupted, and because "why did my watch stop"
    /// is the first question a user asks when it did.
    public enum Finish: Equatable {
        /// The plan's `count` was reached.
        case count
        /// The plan's `until` condition held.
        case condition
        /// The Stop button.
        case stopped
        /// The user typed into the shell. A watch that kept sending into a command line someone is
        /// writing would be a bug they cannot escape from except by killing the tab.
        case userTyped
        case paneClosed
    }

    public let plan: WatchPlan
    /// The exact line sent each run, kept verbatim rather than rebuilt from a `CurlCommand`: the
    /// twentieth run has to be the same request as the first, or the numbers in the header are
    /// comparing two different things.
    public let command: String
    public private(set) var runs: [Run] = []
    public private(set) var phase: Phase
    /// The run that has started and not finished, if there is one. Needed because `Run` looks the
    /// same whether it is in flight or came back with nothing -- both have no status -- and the
    /// difference decides a `.running` dot from a `.failure` one.
    private var runningRunID: UInt32?

    /// A series starts *due*: the point of asking for a watch is that the first run happens now.
    public init(plan: WatchPlan, command: String, startedAt: Double) {
        self.plan = plan; self.command = command
        self.phase = .waiting(until: startedAt)
    }

    public var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// Whether `⌘.` may stop this series while the keyboard is on `cursorRequest` -- the request
    /// block the cursor is on, with its command line spelled as `command` is (`Pane.watchLine`),
    /// and nil for every other position.
    ///
    /// The scope is the **series**, not its newest run. Requiring the newest run read as a bug from
    /// either side (PM P3): scrolling up one run to compare two answers -- the obvious thing to do
    /// with a watch -- refused the chord, while a request belonging to no series at all accepted it,
    /// because the pane's request target falls back to the last request in the pane.
    ///
    /// What belongs to the series is any of its runs **and the block it was armed from**, which is
    /// the same request and is not in `runs`: `startWatch` opens a series with none, and the runs
    /// are the blocks the series itself sent afterwards. That block is where the cursor is when
    /// somebody presses `Run Every 5 s` and then changes their mind, so refusing there would be a
    /// worse trap than the one this rule removes -- found by pressing the keys in the built app,
    /// where `canStop` came back false on the block the watch had just been armed from.
    ///
    /// A request that is neither is somebody else's block: greying the row beats quietly killing a
    /// watch elsewhere in the pane. No request under the keyboard at all is not a reason to refuse
    /// -- there is nothing to mean anything else -- and a series with no runs yet passes from
    /// anywhere, because until the first run there is no `Stop` pill either and the chord is the
    /// only way to take it back.
    public func mayBeStopped(byChordOn cursorRequest: (id: UInt32, command: String)?) -> Bool {
        guard !isFinished else { return false }
        guard let cursorRequest else { return true }
        if runs.isEmpty || cursorRequest.command == command { return true }
        return runs.contains { $0.id == cursorRequest.id }
    }

    // MARK: - The clock

    /// Whether the pane should send the command now: the series is waiting, its deadline has
    /// passed, and the shell is at a prompt.
    ///
    /// The prompt condition is not an optimisation. Sending a line while a command is running feeds
    /// it to that command's stdin; sending one while the user is typing splices a curl into the
    /// middle of their sentence. Both are unrecoverable from the user's side, so the send waits --
    /// however long that takes -- and goes out on the first tick after the prompt comes back.
    public func shouldSend(now: Double, shellAtPrompt: Bool) -> Bool {
        guard shellAtPrompt, case .waiting(let until) = phase else { return false }
        return now >= until
    }

    public mutating func runStarted(id: UInt32, at: Double) {
        guard !isFinished, runningRunID == nil else { return }
        runs.append(Run(id: id, status: nil, exitStatus: 0, timeTotal: nil, at: at))
        runningRunID = id
        phase = .running(id: id)
    }

    /// Records what the run came back with and decides what happens next.
    ///
    /// The interval is measured from `at` -- the moment this run *ended* -- not from when it began.
    /// A 5-second watch of an endpoint that takes 4 seconds is a request every 9 seconds, which is
    /// the honest reading of "every 5 s" for something you are watching: the alternative starts the
    /// next run the instant the last one lands whenever the endpoint is slower than the interval,
    /// which is how a watch turns into a load test.
    ///
    /// A finish for a run nobody saw start, with nothing else in flight, is still recorded and does
    /// schedule the next one. It means the pane missed the start (a command that came and went
    /// between two timer ticks), and ignoring it would leave the series waiting on a deadline that
    /// already passed -- sending the same request again and again, one per tick, forever.
    ///
    /// A finish for an unknown run while one *is* in flight is a different animal and is dropped
    /// whole: it is not this series' run, and the run this series is waiting on has not come back.
    /// Recording it would put someone else's block in the timeline and the statistics, and -- far
    /// worse -- moving the phase for it would leave the series `.waiting` while a curl is still
    /// running, which is exactly the second-request-into-a-busy-shell this type exists to prevent.
    ///
    /// A finish that arrives after `stop` is the other asymmetry: the run was this series' own, so
    /// its result is kept, but the series does not come back to life.
    public mutating func runFinished(id: UInt32, status: Int?, exitStatus: Int32,
                                     timeTotal: Double?, body: String, at: Double) {
        let finished = Run(id: id, status: status, exitStatus: exitStatus, timeTotal: timeTotal, at: at)
        let wasInFlight = runningRunID == id
        if let index = runs.lastIndex(where: { $0.id == id }) {
            runs[index] = finished
        } else if !isFinished, runningRunID == nil {
            runs.append(finished)
        } else {
            return
        }
        if wasInFlight { runningRunID = nil }
        // Only the run the series was actually waiting on -- or a finish that arrived with nothing
        // in flight at all -- may set the next deadline. Anything else leaves the phase alone.
        guard !isFinished, wasInFlight || runningRunID == nil else { return }

        switch plan.stop {
        case .count(let times) where runs.count >= times:
            phase = .finished(reason: .count)
        case .until(let condition) where condition.holds(status: status, body: body):
            phase = .finished(reason: .condition)
        default:
            phase = .waiting(until: at + plan.interval)
        }
    }

    /// Whether a block that has just finished is one of this series' own runs.
    ///
    /// Two ways in and no third. The run the series is watching -- `.running(id)` -- is the one it
    /// asked for and the only block that may finish it. And a run that was typed and has not been
    /// seen to start: a local request can begin and end between two of the pane's ticks, so while
    /// one is `outstanding` the next command to finish is that run, whatever id it turns out to
    /// have. `outstanding` is the pane saying "I typed a run and have not seen it start".
    ///
    /// Everything else is somebody else's command. Adopting one was a real defect: a quick-action
    /// button, a paste or the workbench's own Run reaches the shell without stopping a *waiting*
    /// series, and the stranger's block became the series' newest run -- taking the header, the
    /// dots and the Stop button, folding the real newest run, and counting a request nobody
    /// watched into the statistics and the stop rule. An id comparison alone cannot tell them
    /// apart: every later block has a larger id, which is exactly what a stranger's has too.
    ///
    /// The outstanding case has two floors, and needs both.
    ///
    /// A block *older* than a run already recorded is never this run: the pane's exchange cache is
    /// trimmed, and a trimmed block that comes back on screen is read again, so without that floor
    /// an old request scrolling past during the gap between typing a run and seeing it start was
    /// counted as that run.
    ///
    /// `typedAfter` is the same floor for the run that has no run before it. It is the newest
    /// command in the pane that had already *run* when the line was typed, and the run being
    /// waited for is necessarily newer than it. Without it the first run's floor was zero, so any
    /// block at all was newer -- and the block the pane hands over while outstanding is "whatever
    /// ran last", which on a restored session, or after a `curl` that finished while the tab was
    /// in the background, is a stale block nobody watched. It became run 1: its status went into
    /// the timeline, its body became the diff's "previous", and `Run until 200` could stop on a
    /// response from before the watch existed.
    public func owns(finishedBlock id: UInt32, outstanding: Bool, typedAfter newest: UInt32) -> Bool {
        guard !isFinished else { return false }
        if case .running(let expected) = phase { return expected == id }
        return outstanding && id >= (runs.last?.id ?? 0) && id > newest
    }

    /// Ends the series. The first reason wins: a watch that stopped because the user typed did not
    /// then stop again because the pane closed, and the header should say what actually happened.
    public mutating func stop(_ reason: Finish) {
        guard !isFinished else { return }
        phase = .finished(reason: reason)
    }

    // MARK: - What the header says

    /// nil under two timed runs: a median and a 95th percentile of one number are that number
    /// twice, dressed up as statistics.
    public var stats: Stats? {
        let finished = runs.filter { $0.id != runningRunID }
        let timings = finished.compactMap(\.timeTotal).sorted()
        guard timings.count >= 2 else { return nil }
        let failures = finished.filter {
            WatchSeries.dot(status: $0.status, exitStatus: $0.exitStatus) == .failure
        }.count
        return Stats(count: finished.count,
                     min: timings[0],
                     p50: WatchSeries.percentile(timings, 50),
                     p95: WatchSeries.percentile(timings, 95),
                     max: timings[timings.count - 1],
                     failures: failures)
    }

    /// The newest run that has actually come back. nil while the first one is still in flight.
    var lastCompletedRun: Run? { runs.last { $0.id != runningRunID } }

    /// The colour for a sentence that describes the **series** rather than its latest run.
    ///
    /// Any failure among the runs makes it a failure: `11 runs · p50 150 ms · p95 200 ms ·
    /// 1 failure` took its tone from the newest run and was drawn in success green -- a sentence
    /// whose last three words say something failed. Otherwise it is the last answer that came
    /// back, and `.plain` while nothing has.
    public var tone: SummaryTone {
        let completed = runs.filter { $0.id != runningRunID }
        if completed.contains(where: {
            WatchSeries.dot(status: $0.status, exitStatus: $0.exitStatus) == .failure
        }) { return .failure }
        guard let last = completed.last else { return .plain }
        return WatchSeries.dot(status: last.status, exitStatus: last.exitStatus).tone
    }

    /// The newest `n` runs, oldest first -- the order the dots are drawn in, which is the order
    /// they happened in.
    public func timeline(last n: Int) -> [Dot] {
        guard n > 0 else { return [] }
        return runs.suffix(n).map { run in
            run.id == runningRunID ? .running
                                   : WatchSeries.dot(status: run.status, exitStatus: run.exitStatus)
        }
    }

    /// "run 12 · 200 · 142 ms · every 5 s" while it runs; the statistics, or "stopped after
    /// 3 runs", once it has stopped.
    ///
    /// The running form is how far through it is, the last answer, and the plan, in that order --
    /// the readout ladder in `CommandBlockChrome.readout` drops from the right, and the interval is
    /// the first thing a narrow strip can do without (§2.6's W2 cell reads `run 12 · 200`), so it
    /// goes last rather than first. The verb ("watch") is gone too: the dots and the `Stop` pill
    /// already say a watch is running, and its home is the menu titles and the popover instead. The
    /// finished form drops the plan outright (it is over; how often it ran no longer matters) for
    /// what it found.
    public var headerText: String {
        if isFinished {
            if let stats { return stats.text }
            guard !runs.isEmpty else { return "stopped" }
            return "stopped after \(runs.count) \(runs.count == 1 ? "run" : "runs")"
        }
        var parts: [String] = []
        if !runs.isEmpty { parts.append("run \(runs.count)") }
        // The last run that *came back*, not `runs.last`. While the next run is in flight
        // `runs.last` is that run, with no status and no timing yet, so the sentence lost
        // `· 200 · 142 ms` every interval and the strip shrank and re-laid itself out with it --
        // for as long as the watch lasted. The number a reader wants is the last one that arrived.
        if let last = lastCompletedRun {
            if let status = last.status { parts.append("\(status)") }
            if let time = HTTPSummary.timeText(last.timeTotal) { parts.append(time) }
            // A curl that failed is news even beside a status, and the only news when there is no
            // status at all -- the same rule as `HTTPSummary`, which never shows a failed command
            // as if it went well.
            if last.exitStatus != 0 { parts.append("exit \(last.exitStatus)") }
        }
        // Last, not first: the readout ladder drops from the right, and the interval is the first
        // thing a narrow strip can do without (§2.6's W2 cell reads `run 12 · 200`).
        parts.append(plan.title)
        return parts.joined(separator: " \u{b7} ")
    }

    /// Whether the run at `index` should be collapsed to its command row.
    ///
    /// A watch of twenty runs is twenty blocks of output, and nineteen of them are the same
    /// response as the one above. Everything but the newest folds away -- *unless* its status class
    /// changed, which is the moment the user set the watch up to catch: the run where the 503s
    /// became a 200, or the 200s became a 500, stays open so the transition is still on screen
    /// after scrolling past it.
    ///
    /// "Class" is the hundreds digit, and having no status at all is a class of its own: a run that
    /// never reached the server is exactly as interesting a change as one that came back 500.
    public func shouldFold(runAt index: Int) -> Bool {
        guard runs.indices.contains(index), index < runs.count - 1 else { return false }
        guard index > 0 else { return true }
        return WatchSeries.statusClass(of: runs[index]) == WatchSeries.statusClass(of: runs[index - 1])
    }

    // MARK: - Classification

    /// A run's colour. A non-zero exit status is a failure whatever the status line said: `-o`
    /// could not write the file, the transfer was cut short, the timeout fired half way through the
    /// body. A green dot for any of those would say the run was fine when it was not.
    static func dot(status: Int?, exitStatus: Int32) -> Dot {
        guard exitStatus == 0, let status else { return .failure }
        switch HTTPSummary.tone(forStatus: status) {
        case .success: return .success
        case .redirect: return .redirect
        case .failure: return .failure
        }
    }

    private static func statusClass(of run: Run) -> Int? {
        run.status.map { $0 / 100 }
    }

    /// Nearest rank: the smallest sample at or above the given share of them. No interpolation --
    /// every number in the header is then a latency that really happened, which matters when a user
    /// takes it to a colleague and says "the p95 is 210 ms".
    private static func percentile(_ sorted: [Double], _ share: Double) -> Double {
        let rank = Int((share / 100 * Double(sorted.count)).rounded(.up))
        return sorted[Swift.min(Swift.max(rank - 1, 0), sorted.count - 1)]
    }
}

/// What a watched block's header shows: the dots, the sentence, and whether there is still
/// something to stop.
///
/// A value rather than the `WatchSeries` itself, for the reason every other `BlockHeader` field is
/// one: the header is compared on every frame to decide whether the strip needs re-styling, and a
/// series compares its whole run list. Three small fields is the comparison that costs nothing.
public struct WatchHeader: Equatable {
    /// `WatchSeries.headerText`.
    public let text: String
    /// Oldest first, the order they happened in.
    public let dots: [WatchSeries.Dot]
    /// A series that has stopped has nothing to stop; the header stays to show the statistics.
    public let showsStop: Bool
    /// What colour the sentence is drawn in. `WatchSeries.tone` -- the series', not the newest
    /// run's, because the sentence is about the series.
    public let tone: SummaryTone
    /// Runs older than the dots shown -- the timeline's own cap, not a truncation the reader has to
    /// guess at. Zero for a series that has not yet run past the cap, which is every series most of
    /// its life.
    public let hiddenRuns: Int

    public init(text: String, dots: [WatchSeries.Dot], showsStop: Bool, tone: SummaryTone = .plain,
                hiddenRuns: Int = 0) {
        self.text = text; self.dots = dots; self.showsStop = showsStop; self.tone = tone
        self.hiddenRuns = hiddenRuns
    }
}

public extension WatchSeries {
    /// The header for this series' newest run.
    ///
    /// **Twelve** dots, and `+N` for everything older.
    ///
    /// Thirty was the spec's number (§2.3) and it did not survive its own pictures. Thirty dots on a
    /// 10 pt pitch is **300 pt** -- 41 % of a 730 pt window, thirty-four columns -- and the design
    /// review's ruling names three reasons the strip cannot pay that: nobody reads a timeline
    /// dot-by-dot; the extra dots carry no information even when drawn, because amber and red are
    /// not separable by eye at 8 pt (finding 9, next wave); and §2.6's amendment made the dots
    /// outlive `Copy`, which only pays off if they are cheap enough for the rest of the ladder to
    /// survive them -- at thirty they were the reason it did not. The measured consequence was a W3
    /// watch cell needing **76 of an 84-column pane**, and a width class whose content needs 76 of
    /// 84 is not a class, it is a special case.
    ///
    /// At twelve the cell needs about forty columns, inside the ≥ 34 the class *promises*, and the
    /// W3 threshold does not move (the ruling is explicit: do not raise it). Twelve is still a
    /// minute of a five-second watch and still shows the shape of a flapping endpoint; the runs
    /// past it are counted in `hiddenRuns` and drawn as `+N`, so the cap says how much it is hiding
    /// rather than truncating in silence.
    ///
    /// The caller may ask for fewer. Asking for more grows the strip past the row it is drawn on.
    func header(dots n: Int = 12) -> WatchHeader {
        // `n <= 0` is "no timeline", not "a cap the reader should be told about" -- `timeline`
        // already answers `[]` for it, and a `hiddenRuns` of every run ever made would claim a
        // cap that was never applied.
        WatchHeader(text: headerText, dots: timeline(last: n), showsStop: !isFinished, tone: tone,
                   hiddenRuns: n > 0 ? max(0, runs.count - n) : 0)
    }
}

public extension WatchSeries.Dot {
    /// The colour ladder every other block status already comes down, so a dot and the summary
    /// beside it cannot disagree about whether a run went well.
    var tone: SummaryTone {
        switch self {
        case .success: return .success
        case .redirect: return .redirect
        case .failure: return .failure
        case .running: return .running
        }
    }
}
