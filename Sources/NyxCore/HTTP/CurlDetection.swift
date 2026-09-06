import Foundation

/// Whether a pasted or typed line is a `curl` invocation Nyx should offer the request workbench
/// for. Kept separate from `CurlCommand.parse` only in name -- callers that want the answer to
/// "is this curl" should not have to know that the answer happens to be free once you have
/// already parsed the line.
public enum CurlDetection {
    /// True when the first command word is `curl` (after any `VAR=...`, `sudo`, `time`, `env` or
    /// similar prefix), including when that `curl` is the first stage of a pipeline -- `curl … |
    /// jq .` is still a request Nyx made. A `curl` further down a pipeline, reading somebody
    /// else's output, is not: `cat body.json | curl -d @- …` sends `body.json`, it does not fetch
    /// it, and detecting it as a request line would show the workbench for the wrong command.
    ///
    /// Implemented as a full parse rather than a lighter heuristic: `CurlCommand.parse` already
    /// makes exactly this distinction (first-command-only, pipeline-aware), and it is one
    /// tokenizer pass -- cheap enough to run on every paste without a second, looser check that
    /// could disagree with it.
    public static func isCurl(_ line: String) -> Bool {
        CurlCommand.parse(line) != nil
    }
}
