import Foundation

/// What a finished curl block says about itself at the end of its command row: `200 · 142 ms ·
/// 1.2 KB · json`.
///
/// The four things a person actually checks after a request, in the order they check them, and
/// nothing else -- the headers, the timing breakdown and the body are a click away in the
/// workbench, and putting any of them on the command row would make the one line that must be
/// readable at a glance unreadable. A part that has nothing to say is left out entirely rather than
/// shown as zero: `0 B` on a 204 is not information.
public struct HTTPSummary: Equatable {
    /// How the summary reads, which is what its colour has to agree with. Three cases because HTTP
    /// has three answers; the block header's own `running` and `nothing to say` states are
    /// `SummaryTone`, which this maps into.
    public enum Tone: Equatable { case success, redirect, failure }

    public let text: String
    public let tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text; self.tone = tone
    }

    /// nil when there is nothing HTTP to say: not a request, or one that succeeded without ever
    /// producing a status. The block then keeps its ordinary duration-and-exit summary.
    ///
    /// `duration` is the shell's own timing for the block, used only when the sentinel is missing
    /// (a piped or redirected curl, or one that brought its own `-w`). It is the worse number --
    /// it includes process start-up and the shell's own overhead -- which is why `time_total` wins
    /// whenever it is there.
    public static func make(exchange: HTTPExchange?, exitStatus: Int32?, duration: Double?) -> HTTPSummary? {
        let failed = (exitStatus ?? 0) != 0
        if let exchange, let status = exchange.status {
            var text = "\(status)"
            if let time = timeText(exchange.timing?.total ?? duration) { text += " \u{b7} " + time }
            if let size = exchange.timing.flatMap({ sizeText($0.sizeDownload) }) { text += " \u{b7} " + size }
            if exchange.bodyKind == .json { text += " \u{b7} json" }
            // A server that answered and a command that failed are two different facts, and both
            // are the user's news: `-o` could not write the file (23), the transfer was cut short
            // (18), the timeout fired part way through the body (28). Showing only the 200 -- in
            // green -- said the request worked when the command did not. A failed command is never
            // green, whatever the status class says.
            //
            // The code without its words, here only. `curlFailureReason`'s seven strings are all
            // about *connecting*, which is what the exit code means when nothing else happened; once
            // a status is on the row the connection plainly succeeded and the reason describes the
            // wrong thing -- a `-o` that could not write its file exits 56, and "connection reset"
            // beside a 200 is a sentence that is not true.
            if let exitStatus, failed { text += " \u{b7} exit \(exitStatus)" }
            return HTTPSummary(text: text, tone: failed ? .failure : tone(forStatus: status))
        }
        // curl never got an answer. The exit code is the only thing that says why, and on its own
        // it is a number nobody remembers -- 6, 7 and 60 are three completely different problems.
        if let exitStatus, failed {
            let reason = HTTPExchange.curlFailureReason(exitStatus: exitStatus)
            return HTTPSummary(text: reason.map { "exit \(exitStatus) \u{b7} \($0)" } ?? "exit \(exitStatus)",
                               tone: .failure)
        }
        return nil
    }

    public static func tone(forStatus status: Int) -> Tone {
        switch status {
        case 200..<300: return .success
        case 300..<400: return .redirect
        default: return .failure
        }
    }

    /// Milliseconds up to a second, then one decimal of a second.
    ///
    /// Not `DurationText.short`: that is for how long a *command* took, where 4 ms versus 400 ms is
    /// the whole point and a space before the unit would waste a column. A request's latency is
    /// read against round numbers -- 142 ms, 1.4 s -- and the space is what stops `142ms` reading
    /// as one token beside the status.
    static func timeText(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1f s", seconds)
    }

    /// nil for a zero-byte response: a 204 or a HEAD has nothing to say about its size, and `0 B`
    /// beside the status is a word the eye has to read and then discard.
    ///
    /// 1024 rather than 1000, because the number this is compared against is the one `ls -l`, `du`
    /// and every other tool on the machine prints.
    public static func sizeText(_ bytes: Int) -> String? {
        guard bytes > 0 else { return nil }
        if bytes < 1024 { return "\(bytes) B" }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 { return String(format: "%.1f KB", kilobytes) }
        return String(format: "%.1f MB", kilobytes / 1024)
    }
}
