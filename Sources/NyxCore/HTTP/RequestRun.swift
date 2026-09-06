import Foundation

/// The extra flags Nyx runs a captured curl command with, so the workbench can show headers and
/// timing without changing what request is made. All three additions are computed from the
/// command alone and applied to a *copy* -- the model an editor shows is exactly what the user
/// typed, never what Nyx decided to run it with.
public enum RequestRun {
    /// The line curl's `-w` argument writes, once expanded: the workbench scans stdout for this
    /// exact prefix to find the sentinel among whatever the response body printed.
    public static let sentinelPrefix = "--nyx-http-- "

    /// What goes inside the `-w` argument's quotes: nine named variables, not `%{json}` -- curl
    /// 8.2 put the certificate chain into `%{json}`, several kilobytes per request, right there in
    /// the transcript. `content_type` is last because it is the one value that may itself contain
    /// spaces; the other eight are split on single spaces (see the sentinel parser). These are
    /// curl's own `\n` escapes, written as the literal two-character sequences -- not Swift's
    /// actual newline -- because curl is the one that expands them; if this were a real newline
    /// here, `ShellWords.quote` would switch to `$'...'` quoting and the argument would no longer
    /// be the plain `'...'` curl users expect to see.
    public static let writeOutArgument = "\\n--nyx-http-- %{http_code} %{time_total} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{size_download} %{num_redirects} %{content_type}\\n"

    /// Which of Nyx's three additions apply. A field being `false` means the command already
    /// does that job itself (an explicit `-w`, a `-v` that would make `-sS` redundant) or that
    /// adding it would corrupt the command (headers or the sentinel landing in a redirected body).
    public struct Additions: Equatable {
        public var silent: Bool
        public var include: Bool
        public var writeOut: Bool

        public init(silent: Bool, include: Bool, writeOut: Bool) {
            self.silent = silent
            self.include = include
            self.writeOut = writeOut
        }
    }

    /// A command is standalone when nothing downstream is already consuming its output --
    /// `include` and `writeOut` both key off this, because a pipe or redirection means Nyx is not
    /// the only reader of stdout, and `-i` or the sentinel would land in whatever `trailingPipeline`
    /// points at instead of staying reserved for Nyx's own parsing.
    private static func isStandalone(_ command: CurlCommand) -> Bool {
        command.trailingPipeline.isEmpty
    }

    /// spec §5.4. `silent`: curl already prints its own progress meter unless told otherwise, and
    /// `-v`/`-N` both produce output a `-sS` would suppress or race with, so either one skips the
    /// addition entirely. Once neither is present, either curl is chatty by default (add `-sS`) or
    /// the command already asked for quiet but not for `-S` -- silencing errors along with
    /// everything else would hide the one thing Nyx still needs to show on failure.
    public static func additions(for command: CurlCommand) -> Additions {
        let flags = command.flags
        let silent = (!flags.contains(.verbose) && !flags.contains(.noBuffer) && !flags.contains(.silent))
            || (flags.contains(.silent) && !flags.contains(.showError))

        let standalone = isStandalone(command)
        let include = standalone
            && !command.head
            && command.output.file == nil
            && !command.output.remoteName
            && command.output.dumpHeaders == nil
            && !flags.contains(.include)

        let writeOut = standalone && command.output.writeOut == nil

        return Additions(silent: silent, include: include, writeOut: writeOut)
    }

    /// `command`, with the additions applied, as the one-line shell command Nyx actually runs.
    /// Flags join `command`'s own short-flag group rather than being written as separate `-x`
    /// words -- `shellLine` merges every set `Flags` bit into one string already, so a command
    /// that already has `-L` gets `-sSL` back, not a second `-s` group beside it.
    public static func commandLine(for command: CurlCommand) -> String {
        var run = command
        let add = additions(for: command)

        if add.silent {
            run.flags.insert(.silent)
            run.flags.insert(.showError)
        }
        if add.include {
            run.flags.insert(.include)
        }
        if add.writeOut {
            run.output.writeOut = ShellWord(writeOutArgument)
        }

        return run.shellLine(masking: .none, layout: .oneLine)
    }

    /// A pipe hands curl's stdout to another program that still receives it whole -- `-i` or the
    /// sentinel would land inside whatever that program reads. A redirection sends stdout
    /// somewhere Nyx is not reading it back from at all. Both make headers and timing unavailable,
    /// but for a different reason, so the message says which one applies. `nil` when the command
    /// stands alone and nothing is missing.
    public static func note(for command: CurlCommand) -> String? {
        guard !isStandalone(command) else { return nil }

        // `trailingPipeline` always starts with the operator word that ended the command --
        // see `CurlCommand.trailingPipeline` -- so its first token alone says which kind it is.
        let pipeOperators: Set<Substring> = ["|", "||", "&&", ";", "&"]
        let firstWord = command.trailingPipeline.prefix { $0 != " " }

        return pipeOperators.contains(firstWord)
            ? "Pipeline present: headers and timing unavailable"
            : "Output redirected: headers and timing unavailable"
    }
}
