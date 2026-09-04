import Foundation

/// How a session should get its shell integration.
public enum ShellIntegrationMode: String, Equatable {
    /// Inject automatically when the shell is one we can inject into. The default.
    case auto
    /// Never inject. For users who install the hooks in their own rc files, or who would rather we
    /// kept out of their shell entirely.
    case off
}

/// The shells we can inject into, and how.
public enum ShellKind: Equatable {
    case zsh
    case bash
    case fish
    case other(String)

    /// Identified by the executable's name, since `SHELL` is a path and may be a symlink or live
    /// somewhere unusual (Homebrew's zsh, a Nix store path).
    public static func detect(shellPath: String) -> ShellKind {
        switch (shellPath as NSString).lastPathComponent {
        case "zsh": return .zsh
        case "bash": return .bash
        case "fish": return .fish
        case let other: return .other(other)
        }
    }
}

/// Getting `OSC 133` marks into the user's shell without editing their rc files.
///
/// Everything built on prompt marks -- jumping between commands, the status gutter, copying a
/// command's output, the completion notification -- is inert unless the shell announces where its
/// prompt ends and a command begins. Almost no shell does that out of the box, which makes this the
/// difference between those features existing and existing on paper.
///
/// The trick for zsh is `ZDOTDIR`: point it at a directory of ours holding a `.zshrc` that sources
/// the user's real one and then our hooks. Nothing of the user's is modified, an upgrade cannot
/// leave stale hooks behind in their home directory, and turning it off is a config line rather
/// than an uninstall.
///
/// The rules are pure functions over an environment dictionary so they can be tested without
/// launching a shell -- the failure mode being guarded against is the one where a mistake here
/// stops the user's shell from starting at all.
public enum ShellIntegration {
    /// The variable the shim reads to find the user's own `ZDOTDIR`, so it can restore it.
    public static let originalZDotDir = "NYX_ZDOTDIR"
    /// Set for the shim to find our scripts; also how a session reports that injection happened.
    public static let resourceDirectory = "NYX_SHELL_INTEGRATION_DIR"

    /// Where the scripts live inside the app bundle. nil when running outside one -- the test
    /// suite, or the benchmark -- in which case nothing is injected and shells start normally.
    public static var bundledResources: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("shell-integration", isDirectory: true)
    }

    /// The environment a session should launch with.
    ///
    /// `resources` is the directory holding `zsh/.zshrc` and the integration scripts. Returns the
    /// environment unchanged whenever injection is off, the shell is one we have no shim for, or
    /// the resources are missing -- a terminal that will not start a shell because it could not
    /// find its own helper file would be a far worse bug than one without prompt marks.
    public static func environment(_ base: [String: String], shellPath: String,
                                   mode: ShellIntegrationMode, resources: URL?,
                                   directoryExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> [String: String] {
        guard mode == .auto, let resources else { return base }

        switch ShellKind.detect(shellPath: shellPath) {
        case .zsh:
            let shim = resources.appendingPathComponent("zsh", isDirectory: true)
            guard directoryExists(shim) else { return base }
            var env = base
            // The user's own ZDOTDIR travels separately so the shim can source their .zshrc and
            // then put the variable back -- a nested zsh must see the value they set, not ours.
            if let existing = base["ZDOTDIR"], !existing.isEmpty {
                env[originalZDotDir] = existing
            }
            env["ZDOTDIR"] = shim.path
            env[resourceDirectory] = resources.path
            return env

        case .bash, .fish, .other:
            // bash's startup-file rules differ between login and interactive shells, and fish has
            // no equivalent hook, so neither gets a shim it cannot be relied on to run. They are
            // told where the scripts are so `manualInstallCommand` can point at a real file.
            var env = base
            env[resourceDirectory] = resources.path
            return env
        }
    }

    /// True when this shell will pick the integration up on its own.
    public static func isAutomatic(shellPath: String, mode: ShellIntegrationMode) -> Bool {
        guard mode == .auto else { return false }
        return ShellKind.detect(shellPath: shellPath) == .zsh
    }

    /// The line to paste into an rc file, for shells we cannot inject into. Shown in the settings
    /// window rather than left for the user to work out from the source.
    public static func manualInstallCommand(shellPath: String, resources: URL) -> String? {
        switch ShellKind.detect(shellPath: shellPath) {
        case .zsh:
            return "source \"\(resources.path)/zsh/nyx-integration.zsh\""
        case .bash:
            return "source \"\(resources.path)/bash/nyx-integration.bash\""
        case .fish:
            return "source \"\(resources.path)/fish/nyx-integration.fish\""
        case .other:
            return nil
        }
    }
}
