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
    /// the Run menu one step earlier: the item a user clicks ("every 5 s") and the header they then
    /// read ("watch every 5 s") have to be the same words, or the header looks like a different
    /// plan from the one they chose.
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

    /// The newest `n` runs, oldest first -- the order the dots are drawn in, which is the order
    /// they happened in.
    public func timeline(last n: Int) -> [Dot] {
        guard n > 0 else { return [] }
        return runs.suffix(n).map { run in
            run.id == runningRunID ? .running
                                   : WatchSeries.dot(status: run.status, exitStatus: run.exitStatus)
        }
    }

    /// "watch every 5 s · run 12 · 200 · 142 ms" while it runs; the statistics, or "stopped after
    /// 3 runs", once it has stopped.
    ///
    /// The running form is the plan, how far through it is, and the last answer -- the three things
    /// someone glancing at a watching pane wants, and they are the ones that change. The finished
    /// form drops the plan (it is over; how often it ran no longer matters) for what it found.
    public var headerText: String {
        if isFinished {
            if let stats { return stats.text }
            guard !runs.isEmpty else { return "stopped" }
            return "stopped after \(runs.count) \(runs.count == 1 ? "run" : "runs")"
        }
        var parts = ["watch " + plan.title]
        if !runs.isEmpty { parts.append("run \(runs.count)") }
        if let last = runs.last, last.id != runningRunID {
            if let status = last.status { parts.append("\(status)") }
            if let time = HTTPSummary.timeText(last.timeTotal) { parts.append(time) }
            // A curl that failed is news even beside a status, and the only news when there is no
            // status at all -- the same rule as `HTTPSummary`, which never shows a failed command
            // as if it went well.
            if last.exitStatus != 0 { parts.append("exit \(last.exitStatus)") }
        }
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
