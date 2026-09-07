# UX Round Wave 3 — Shell Integration for bash and fish, and Telling the User

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fish user, and a bash user whose bash is new enough, gets OSC 133 prompt marks without editing a single file of their own — and wherever the marks are missing, including on the bash Apple ships, Nyx says so in words that name their shell and offer the one thing that changes it.

**Architecture:** One Core primitive, `ShellIntegration.launch`, decides both halves of a launch (the environment *and* the argv) from one guard, so `--posix` can never be passed without an `ENV` that will actually be read. fish is reached by prepending Nyx's resource directory to `XDG_DATA_DIRS` and shipping `fish/vendor_conf.d/nyx.fish` inside it, which fish sources before the user's `config.fish`. bash is reached with `--posix` plus `ENV` pointing at `bash/nyx-shim.bash`, which turns POSIX mode straight back off, reads the user's own startup files in bash's own order and only then adds the marks — but **only from bash 4.4**: macOS's own 3.2.57 ignores `$ENV` under `--posix`, so `ShellCapabilities` probes the binary once per path and an older bash is launched untouched and offered a line to paste instead. A second Core value, `ShellIntegrationStatus`, owns every sentence about the state of the marks, so the new Settings ▸ Shell page, the no-marks banner and the corrected "Cannot watch" alert are three views of one value and cannot drift apart.

**Tech Stack:** Swift 6.0.3 in Swift 5 mode, SwiftPM, swift-testing, AppKit; POSIX `sh` for the bash shim, bash 3.2-compatible bash in the integration script (it has to run on a stock Mac when pasted by hand), fish ≥ 3.0. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-07-ux-round-design.md` (§4 in full, §8.1's `ShellIntegrationStatus` site, §8.5's plan-3 row, §10's "Wave 3 — shell integration", and the Coverage appendix's `findings-pm.md §2` row). Background: `.superpowers/sdd/2026-09-07-ux-round/findings-pm.md` §2.

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY; no AppKit, Metal, CoreText or QuartzCore. Decisions live in Core as pure values with tests; the AppKit layer converts and draws (`CLAUDE.md`).
- Tests are **swift-testing** (`import Testing`, `@Test`, `#expect`, `#require`). XCTest does not exist here. Hoist mutating calls out of `#expect`. Hang fix: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`.
- Warning-free build, library and tests. `make bench` ≥ 180 MB/s (nothing in this wave touches the render path, so a drop is a bug).
- **The existing guarantee, unchanged and extended to the two new shells:** "if anything is missing, return the environment unchanged. A terminal that will not start a shell because it could not find its own helper file is far worse than one without prompt marks" (spec §4.1).
- The scripts must emit exactly the sequences `Terminal.handleOSC` case 133 accepts: `ESC ] 133 ; A BEL`, `ESC ] 133 ; B BEL`, `ESC ] 133 ; C BEL`, `ESC ] 133 ; D ; <status> BEL`, plus OSC 7 `ESC ] 7 ; file://<host><percent-encoded path> BEL`. `B` must be emitted at the column where typing begins (`Terminal` records `inputStartColumn` from the cursor at that moment) and must be wrapped in the shell's own zero-width-prompt escape or line editing corrupts the display.
- **bash before 4.4 does not read `$ENV`, whatever the manual says.** Reproduced on this machine, over a PTY, as `execve("/bin/bash", ["-bash", "--posix"])` with `ENV` exported: bash 3.2.57 reports `posix on` from `set -o` and still reads `/etc/profile` + `~/.bash_profile` (login) or `~/.bashrc` (non-login), and **never `$ENV`** — on 3.2 only an argv[0] of `sh`/`-sh` arms that hook. Homebrew's bash 5.3 reads `$ENV` and nothing else, as documented. macOS ships 3.2.57, so **the default bash on every Mac is a manual-install shell**. kitty and Ghostty gate this same mechanism on bash ≥ 4.4; Nyx does too.
- **A shell is never launched with `--posix` unless the shim is known to run.** `--posix` without a readable, honoured `ENV` is a bash that reads no startup file at all: the version gate and the shim-exists gate are one guard, in one function, with one test each.
- `isAutomatic` becomes true for `.zsh`, `.fish` and **bash ≥ 4.4**; `.other` and bash < 4.4 stay false and keep `manualInstallCommand`'s line (spec §4.1, as amended by the version finding above).
- **The status sentences.** The first four are spec §4.2's, verbatim; `<shell>` is `ShellKind.name`. The fifth is this plan's, written on §4.2's shape for the state §4.2 did not know existed — a shell we have a script for and cannot install it into:
  - `Prompt marks are live. Blocks, folding, Copy Output, the pinned command and watches all work here.`
  - `Nyx installs prompt marks into <shell> automatically. This window has not seen one yet — open a new tab if this is the first launch after an update.`
  - `Your shell is <shell>. Nyx has no hooks for it, so blocks, folding, Copy Output, the ⋯ menu, the pinned command and watches are all off.`
  - `Prompt marks are off by your setting. Blocks, folding, Copy Output, the ⋯ menu, the pinned command and watches are all off.`
  - `Your shell is bash <version>, which cannot take prompt marks automatically: bash only reads the file Nyx installs them through from version 4.4. Paste the line below into ~/.bashrc, or install a newer bash.`
- **The manual line's caption, verbatim:** `Paste this into your startup file, then open a new tab:`, the line itself monospaced in a selectable field, with a `Copy` button.
- **The banner** — spec §4.3's sentence, and two more on its shape, each with a `Shell Settings…` button and a `✕`, remembered **per shell path for the life of the process** and never written to disk:
  - a shell Nyx cannot install into, or one it tried to install into and whose marks never came: `Nyx could not add prompt marks to <shell> — blocks, folding and watches are off in this pane.`
  - bash < 4.4, where there is a line to paste: `Nyx cannot add prompt marks to bash <version> by itself — paste the line from Settings ▸ Shell into ~/.bashrc.`
  - `shell-integration = off`: `Prompt marks are off by your setting — blocks, folding and watches are off in this pane.`
- **The alert, verbatim** (spec §4.3): message `Cannot watch a request in this pane`; informative `A watch sends its next run only when the shell is back at a prompt, and this shell does not tell Nyx where its prompts are. Nyx adds prompt marks to zsh, bash and fish by itself; this pane is running <shell>.`, whose second sentence becomes `Prompt marks are off by your setting.` when `mode == .off` and, for bash < 4.4, `Nyx adds prompt marks to zsh, fish and bash 4.4 or newer by itself; this pane is running bash <version>, whose line has to go into ~/.bashrc by hand — Settings ▸ Shell has it.`; buttons `Shell Settings…` (default) · `OK`.
- Every new piece of chrome gets its snapshot case **in the same commit** (`docs/testing.md`).
- Commit trailers on every commit:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP`
- `git add` **by name**, never `-A`. Never commit a QA hook. Never touch `CLAUDE.md`, `.claude/`, `docs/testing.md`, `docs/workflow.md`, `docs/checklist.md`.

## File map

| File | Responsibility | Task |
|---|---|---|
| `Sources/NyxCore/Shell/ShellIntegration.swift` | `ShellKind` (+`name`), `ShellLaunch`, `launch`, `environment`, `isAutomatic`, `manualInstallCommand` | 1 |
| `Sources/NyxCore/Shell/ShellCapabilities.swift` | what a shell binary can be asked to do — today only "does this bash read `$ENV`" — learned once per shell path, off the tab-creation path | 1 |
| `Resources/shell-integration/bash/nyx-shim.bash` | the file `ENV` points at: POSIX off, the user's startup files in bash's own order, then the marks | 2 |
| `Resources/shell-integration/bash/nyx-integration.bash` | the marks themselves, surviving the user's `PROMPT_COMMAND` and `DEBUG` trap | 2 |
| `Sources/NyxCore/Session/TerminalSession.swift` | `SessionConfig.loginShell` takes the configured shell and asks `launch` for argv + env | 2 |
| `Resources/shell-integration/fish/vendor_conf.d/nyx.fish` | the vendor snippet: restore `XDG_DATA_DIRS`, source the integration | 3 |
| `Resources/shell-integration/fish/nyx-integration.fish` | the marks, with the prompt wrapped on the first prompt rather than at load | 3 |
| `Sources/NyxCore/Shell/ShellIntegrationStatus.swift` | every sentence about the state of the marks, and the once-per-shell notice rule | 4 |
| `Sources/NyxApp/SettingsWindowController.swift` | the Shell page: the pop-up, the sentence, the paste line | 5 |
| `Sources/NyxApp/ConfigBanner.swift` | a note with a button of the caller's own | 6 |
| `Sources/NyxApp/Announce.swift` | `.announcementRequested` on `NSApp` (§8.1) | 6 |
| `Sources/NyxApp/Pane.swift` | the pane's shell path (nil for a remote pane), its status, the no-marks notice, the corrected refusal | 5, 6 |
| `Sources/NyxApp/AppDelegate.swift` | primes `ShellCapabilities` at launch and on every config reload, so no tab ever waits on a probe | 2, 5 |
| `Sources/NyxApp/UISnapshot.swift`, `MenuSnapshot.swift` | the pictures | 5, 6 |

---

### Task 1: `ShellLaunch` and `ShellCapabilities` — one guard decides the environment, the argv and whether this bash can be reached at all

**Files:**
- Modify: `Sources/NyxCore/Shell/ShellIntegration.swift`
- Create: `Sources/NyxCore/Shell/ShellCapabilities.swift`
- Test: `Tests/NyxCoreTests/ShellIntegrationTests.swift`, `Tests/NyxCoreTests/ShellCapabilitiesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
```swift
public enum ShellKind: Equatable {
    case zsh, bash, fish
    case other(String)
    public static func detect(shellPath: String) -> ShellKind
    /// The word every sentence about this shell uses: "zsh", "bash", "fish", or the binary's own
    /// name. One source, so the settings page, the banner and the alert cannot spell it three ways.
    public var name: String
}

/// What a shell binary can be asked to do, learned by running it once.
///
/// Today it answers one question -- does this bash read `$ENV` in POSIX mode -- and that question
/// has to be answered by *running the binary*, because the manual's answer is wrong for the bash
/// every Mac ships: 3.2.57 reports `posix on` and reads `~/.bashrc` anyway.
///
/// The probe is a `Process`, so it must never happen while a tab is being made. `prime` is called
/// from `AppDelegate` at launch and on every config reload, before any window exists; `supports`
/// answers from the cache and, for a path nobody primed, answers **no** -- the conservative answer
/// is the one that cannot break a shell.
public final class ShellCapabilities {
    public static let shared = ShellCapabilities()
    /// `probe` returns the shell's `BASH_VERSINFO[0] BASH_VERSINFO[1]`, e.g. `"3 2"`, or nil.
    public init(probe: @escaping (String) -> String? = ShellCapabilities.runVersionProbe)
    /// Runs the probe for this path unless it is already known. Blocking; call it off the
    /// tab-creation path.
    public func prime(shellPath: String)
    /// bash ≥ 4.4, which is the first bash that honours `$ENV` under `--posix`. False for a path
    /// that has not been primed, and for every non-bash path (they do not use this hook).
    public func bashSupportsENVStartup(shellPath: String) -> Bool
    /// `"3.2"`, for the sentence that names it. nil when unknown or not a bash.
    public func bashVersion(shellPath: String) -> String?
    public static func runVersionProbe(_ shellPath: String) -> String?
}

/// What a session needs to launch a shell: the two halves of the decision, taken together.
///
/// Together on purpose. bash's `--posix` is only survivable *because* `ENV` points at our shim and
/// *because* this bash is one that reads `ENV`: a posix-mode bash with no honoured `ENV` reads no
/// startup file at all, so the user's `~/.bashrc` would simply stop running. Handing the caller an
/// environment and an argv separately -- two functions, two guards -- is how those facts drift.
public struct ShellLaunch: Equatable {
    public var environment: [String: String]
    public var arguments: [String]
    public init(environment: [String: String], arguments: [String])
}

public enum ShellIntegration {
    public static let originalZDotDir = "NYX_ZDOTDIR"
    public static let originalXDGDataDirs = "NYX_XDG_DATA_DIRS"
    public static let originalENV = "NYX_ENV"
    public static let resourceDirectory = "NYX_SHELL_INTEGRATION_DIR"
    /// The XDG base-directory spec's own default, used when the user has no `XDG_DATA_DIRS`:
    /// setting the variable to *only* our directory would take `/usr/share` away from fish's own
    /// vendor snippets and from every other XDG-aware program started from that shell.
    public static let defaultXDGDataDirs = "/usr/local/share:/usr/share"
    /// The first bash that honours `$ENV` under `--posix`.
    public static let bashENVStartupVersion = (major: 4, minor: 4)
    public static var bundledResources: URL? { get }

    public static func launch(_ base: [String: String], arguments: [String], shellPath: String,
                              mode: ShellIntegrationMode, resources: URL?,
                              capabilities: ShellCapabilities = .shared,
                              pathExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> ShellLaunch
    /// The environment half, for callers with no argv to decide (the tests, and anything that only
    /// wants to know what a session's environment would be).
    public static func environment(_ base: [String: String], shellPath: String,
                                   mode: ShellIntegrationMode, resources: URL?,
                                   capabilities: ShellCapabilities = .shared,
                                   pathExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> [String: String]
    public static func isAutomatic(shellPath: String, mode: ShellIntegrationMode,
                                   capabilities: ShellCapabilities = .shared) -> Bool
    public static func manualInstallCommand(shellPath: String, resources: URL) -> String?
}
```

- [ ] **Step 1: Write the failing capability tests**

Create `Tests/NyxCoreTests/ShellCapabilitiesTests.swift`. The probe is injected, so nothing here runs a shell:

```swift
import Foundation
import Testing
@testable import NyxCore

private func capabilities(_ answers: [String: String], counter: (() -> Void)? = nil) -> ShellCapabilities {
    ShellCapabilities { path in counter?(); return answers[path] }
}

@Test func bashFourFourAndAboveReadsENV() {
    let caps = capabilities(["/opt/homebrew/bin/bash": "5 3", "/usr/local/bin/bash": "4 4"])
    caps.prime(shellPath: "/opt/homebrew/bin/bash")
    caps.prime(shellPath: "/usr/local/bin/bash")
    #expect(caps.bashSupportsENVStartup(shellPath: "/opt/homebrew/bin/bash"))
    #expect(caps.bashSupportsENVStartup(shellPath: "/usr/local/bin/bash"))
}

/// The bash every Mac ships. `--posix` + ENV does nothing on it, reproduced over a PTY, so the
/// whole automatic path has to stay off for this one.
@Test func theBashMacOSShipsDoesNot() {
    let caps = capabilities(["/bin/bash": "3 2"])
    caps.prime(shellPath: "/bin/bash")
    #expect(!caps.bashSupportsENVStartup(shellPath: "/bin/bash"))
    #expect(caps.bashVersion(shellPath: "/bin/bash") == "3.2")
}

@Test func fourZeroIsStillTooOld() {
    let caps = capabilities(["/bin/bash": "4 0"])
    caps.prime(shellPath: "/bin/bash")
    #expect(!caps.bashSupportsENVStartup(shellPath: "/bin/bash"))
}

/// The answer for a path nobody primed is "no": a pane that guessed "yes" and was wrong launches a
/// bash in POSIX mode that reads nothing at all.
@Test func anUnprimedPathIsAssumedIncapable() {
    let caps = capabilities(["/bin/bash": "5 2"])
    #expect(!caps.bashSupportsENVStartup(shellPath: "/bin/bash"))
    #expect(caps.bashVersion(shellPath: "/bin/bash") == nil)
}

@Test func aShellThatAnswersNothingIsAssumedIncapable() {
    let caps = capabilities([:])
    caps.prime(shellPath: "/bin/ksh")
    #expect(!caps.bashSupportsENVStartup(shellPath: "/bin/ksh"))
}

/// Once per shell path for the life of the process: a window with twelve bash tabs must not fork
/// twelve probes.
@Test func aShellIsProbedOnceAndRemembered() {
    var runs = 0
    let caps = capabilities(["/bin/bash": "5 2"], counter: { runs += 1 })
    caps.prime(shellPath: "/bin/bash")
    caps.prime(shellPath: "/bin/bash")
    _ = caps.bashSupportsENVStartup(shellPath: "/bin/bash")
    #expect(runs == 1)
}

/// The one case that touches a real binary: the probe has to produce the shape the parser expects
/// from the bash that is actually on this machine.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/bash")))
func theRealProbeReadsARealBashsVersion() {
    let answer = ShellCapabilities.runVersionProbe("/bin/bash")
    let parts = (answer ?? "").split(separator: " ")
    #expect(parts.count == 2, "unexpected probe output: \(answer ?? "nil")")
    #expect(Int(parts.first ?? "") != nil)
}
```

- [ ] **Step 2: Write the failing launch tests**

Replace the helper at the top of `Tests/NyxCoreTests/ShellIntegrationTests.swift` (the parameter is renamed from `directoryExists` to `pathExists`, because two of the guards now check a file, and a capability set is injected so no test runs a shell):

```swift
/// A bash that reads `$ENV`, and one that does not, without running either.
private let modernBash = ShellCapabilities { _ in "5 3" }
private let ancientBash = ShellCapabilities { _ in "3 2" }
private func primed(_ caps: ShellCapabilities, _ paths: String...) -> ShellCapabilities {
    for path in paths { caps.prime(shellPath: path) }
    return caps
}

private func launch(_ base: [String: String] = [:], argv: [String] = ["-zsh"],
                    shell: String = "/bin/zsh", mode: ShellIntegrationMode = .auto,
                    resources: URL? = resources,
                    capabilities: ShellCapabilities = primed(modernBash, "/bin/bash", "/opt/homebrew/bin/bash"),
                    exists: @escaping (URL) -> Bool = allExist) -> ShellLaunch {
    ShellIntegration.launch(base, arguments: argv, shellPath: shell, mode: mode,
                            resources: resources, capabilities: capabilities, pathExists: exists)
}

private func env(_ base: [String: String] = [:], shell: String = "/bin/zsh",
                 mode: ShellIntegrationMode = .auto, resources: URL? = resources,
                 capabilities: ShellCapabilities = primed(modernBash, "/bin/bash", "/opt/homebrew/bin/bash"),
                 exists: @escaping (URL) -> Bool = allExist) -> [String: String] {
    ShellIntegration.environment(base, shellPath: shell, mode: mode, resources: resources,
                                 capabilities: capabilities, pathExists: exists)
}
```

New cases, appended to the file:

```swift
// MARK: - Injecting into bash

/// `--posix` makes `ENV` the one startup file an interactive bash reads, login or not -- but only
/// from 4.4. `--rcfile` was the alternative and is worse at both ends: a login shell ignores it
/// outright, so a login bash would get no hooks at all, and a non-login shell reads our file
/// *instead of* `~/.bashrc`, so the user's own rc runs only if our file remembers to source it.
@Test func aModernBashIsLaunchedInPosixModeWithOurShimAsENV() {
    let l = launch(argv: ["-bash"], shell: "/opt/homebrew/bin/bash")
    #expect(l.arguments == ["-bash", "--posix"])
    #expect(l.environment["ENV"] == resources.appendingPathComponent("bash/nyx-shim.bash").path)
    #expect(l.environment[ShellIntegration.resourceDirectory] == resources.path)
}

/// The finding this gate exists for: macOS's own bash reports `posix on` and reads `~/.bashrc`
/// anyway, so `--posix` would buy nothing and cost the user every startup file they have.
@Test func aBashOlderThanFourFourIsLaunchedExactlyAsItWouldHaveBeen() {
    let l = launch(["PATH": "/usr/bin"], argv: ["-bash"], shell: "/bin/bash",
                   capabilities: primed(ancientBash, "/bin/bash"))
    #expect(l.arguments == ["-bash"], "an old bash must never be put into POSIX mode")
    #expect(l.environment["ENV"] == nil)
    // Still told where the scripts are: that is what makes the settings page's paste line real.
    #expect(l.environment[ShellIntegration.resourceDirectory] == resources.path)
}

/// A bash nobody primed is treated as an old one, for the same reason.
@Test func anUnprimedBashIsNotPutIntoPosixMode() {
    let l = launch(argv: ["-bash"], shell: "/bin/bash", capabilities: ShellCapabilities { _ in "5 3" })
    #expect(l.arguments == ["-bash"])
    #expect(l.environment["ENV"] == nil)
}

/// A user who exports `ENV` means it for their `sh`. The shim unsets ours on the way out, so
/// theirs has to travel or every `sh` started from that window loses it.
@Test func bashCarriesTheUsersOwnENVForItsChildren() {
    let l = launch(["ENV": "/Users/someone/.shinit"], argv: ["-bash"], shell: "/opt/homebrew/bin/bash")
    #expect(l.environment[ShellIntegration.originalENV] == "/Users/someone/.shinit")
    #expect(l.environment["ENV"]?.hasSuffix("bash/nyx-shim.bash") == true)
}

@Test func bashWithNoENVOfItsOwnCarriesNothing() {
    #expect(launch(argv: ["-bash"], shell: "/opt/homebrew/bin/bash").environment[ShellIntegration.originalENV] == nil)
}

/// The missing-file rule, for the half that can break a shell outright.
@Test func aMissingBashShimLeavesBothHalvesUntouched() {
    let l = launch(["PATH": "/usr/bin"], argv: ["-bash"], shell: "/opt/homebrew/bin/bash", exists: noneExist)
    #expect(l.arguments == ["-bash"])
    #expect(l.environment == ["PATH": "/usr/bin"])
}

// MARK: - Injecting into fish

/// fish sources every `fish/vendor_conf.d/*.fish` under every entry of `XDG_DATA_DIRS` at startup,
/// before the user's own `config.fish`. Prepended, never replaced: the entries already there carry
/// Homebrew's own vendor snippets.
@Test func fishGetsOurDirectoryPrependedToXDGDataDirs() {
    let l = launch(["XDG_DATA_DIRS": "/opt/homebrew/share:/usr/share"],
                   argv: ["-fish"], shell: "/opt/homebrew/bin/fish")
    #expect(l.environment["XDG_DATA_DIRS"] == resources.path + ":/opt/homebrew/share:/usr/share")
    #expect(l.environment[ShellIntegration.originalXDGDataDirs] == "/opt/homebrew/share:/usr/share")
    #expect(l.arguments == ["-fish"], "fish needs no argument of ours")
}

/// With no `XDG_DATA_DIRS` of their own, the spec's default has to be written out: setting the
/// variable to only our directory would hide `/usr/share/fish/vendor_conf.d` from fish and
/// `/usr/share` from everything else the shell starts.
@Test func fishWithoutXDGDataDirsKeepsTheSpecDefaults() {
    let l = launch(argv: ["-fish"], shell: "/opt/homebrew/bin/fish")
    #expect(l.environment["XDG_DATA_DIRS"] == resources.path + ":" + ShellIntegration.defaultXDGDataDirs)
    #expect(l.environment[ShellIntegration.originalXDGDataDirs] == nil)
}

@Test func anEmptyXDGDataDirsIsTreatedAsUnset() {
    let l = launch(["XDG_DATA_DIRS": ""], argv: ["-fish"], shell: "/opt/homebrew/bin/fish")
    #expect(l.environment[ShellIntegration.originalXDGDataDirs] == nil)
    #expect(l.environment["XDG_DATA_DIRS"] == resources.path + ":" + ShellIntegration.defaultXDGDataDirs)
}

@Test func aMissingFishSnippetLeavesTheEnvironmentUntouched() {
    let l = launch(["PATH": "/usr/bin"], argv: ["-fish"], shell: "/opt/homebrew/bin/fish", exists: noneExist)
    #expect(l.environment == ["PATH": "/usr/bin"])
}

// MARK: - Off, and shells we know nothing about

@Test func turningItOffLeavesTheArgumentsAloneToo() {
    let l = launch(["PATH": "/usr/bin"], argv: ["-bash"], shell: "/opt/homebrew/bin/bash", mode: .off)
    #expect(l.arguments == ["-bash"])
    #expect(l.environment == ["PATH": "/usr/bin"])
}

@Test func aShellWithNoShimIsToldWhereTheScriptsAreAndNothingMore() {
    let l = launch(["PATH": "/usr/bin"], argv: ["-ksh"], shell: "/bin/ksh")
    #expect(l.arguments == ["-ksh"])
    #expect(l.environment["ZDOTDIR"] == nil)
    #expect(l.environment["ENV"] == nil)
    #expect(l.environment["XDG_DATA_DIRS"] == nil)
    #expect(l.environment[ShellIntegration.resourceDirectory] == resources.path)
}

// MARK: - What to tell the user

@Test func everyShellWeCanReachIsAutomatic() {
    let caps = primed(modernBash, "/opt/homebrew/bin/bash")
    #expect(ShellIntegration.isAutomatic(shellPath: "/bin/zsh", mode: .auto, capabilities: caps))
    #expect(ShellIntegration.isAutomatic(shellPath: "/opt/homebrew/bin/fish", mode: .auto, capabilities: caps))
    #expect(ShellIntegration.isAutomatic(shellPath: "/opt/homebrew/bin/bash", mode: .auto, capabilities: caps))
    #expect(!ShellIntegration.isAutomatic(shellPath: "/bin/bash", mode: .auto,
                                          capabilities: primed(ancientBash, "/bin/bash")))
    #expect(!ShellIntegration.isAutomatic(shellPath: "/bin/ksh", mode: .auto, capabilities: caps))
    #expect(!ShellIntegration.isAutomatic(shellPath: "/bin/zsh", mode: .off, capabilities: caps))
}

@Test func theShellsNameIsTheWordEverySentenceUses() {
    #expect(ShellKind.detect(shellPath: "/opt/homebrew/bin/zsh").name == "zsh")
    #expect(ShellKind.detect(shellPath: "/bin/bash").name == "bash")
    #expect(ShellKind.detect(shellPath: "/opt/homebrew/bin/fish").name == "fish")
    #expect(ShellKind.detect(shellPath: "/usr/local/bin/nu").name == "nu")
}

/// The two entry points must not be able to disagree about whether injection happened.
@Test func theEnvironmentHelperAnswersExactlyWhatLaunchDoes() {
    for shell in ["/bin/zsh", "/opt/homebrew/bin/bash", "/bin/bash", "/opt/homebrew/bin/fish", "/bin/ksh"] {
        #expect(env(["PATH": "/usr/bin"], shell: shell)
                == launch(["PATH": "/usr/bin"], argv: ["-x"], shell: shell).environment, "\(shell)")
    }
}
```

The existing case `onlyZshIsAutomatic` is **deleted** (replaced by `everyShellWeCanReachIsAutomatic`), and `shellsWithNoShimAreToldWhereTheScriptsAreAndNothingMore` is **deleted** (replaced by `aShellWithNoShimIsToldWhereTheScriptsAreAndNothingMore`). Every other existing case in the file stays and must still pass.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter "ShellIntegration|ShellCapabilities"`
Expected: FAIL — `cannot find 'ShellLaunch' in scope`, `cannot find 'ShellCapabilities' in scope`.

- [ ] **Step 4: Implement `ShellCapabilities`**

Create `Sources/NyxCore/Shell/ShellCapabilities.swift`:

```swift
import Foundation

/// What a shell binary can be asked to do, learned by running it once and then remembered.
///
/// One question so far, and it is not one the documentation can answer. bash's manual says a shell
/// started with `--posix` reads `$ENV` and no other startup file; the bash macOS ships (3.2.57)
/// reports `posix on` from `set -o` and reads `/etc/profile` and `~/.bash_profile` anyway. Driving
/// it over a PTY is how that was found, and running the binary is the only way to know: the same
/// path can be 3.2 on one Mac and 5.3 on the next.
///
/// Being wrong in the optimistic direction costs the user every startup file they have, so an
/// unprimed path answers **no**.
public final class ShellCapabilities {
    public static let shared = ShellCapabilities()

    private let probe: (String) -> String?
    private var answers: [String: (major: Int, minor: Int)?] = [:]
    private let lock = NSLock()

    public init(probe: @escaping (String) -> String? = ShellCapabilities.runVersionProbe) {
        self.probe = probe
    }

    /// Runs the probe unless this path is already known. Forks a process, so it is called from
    /// `AppDelegate` at launch and on each config reload -- never from `Pane.init`, where it would
    /// put a fork between ⌘T and a window.
    public func prime(shellPath: String) {
        lock.lock()
        let known = answers.index(forKey: shellPath) != nil
        lock.unlock()
        guard !known else { return }
        let parsed = ShellCapabilities.parse(probe(shellPath))
        lock.lock()
        answers[shellPath] = parsed
        lock.unlock()
    }

    public func bashSupportsENVStartup(shellPath: String) -> Bool {
        guard ShellKind.detect(shellPath: shellPath) == .bash, let version = version(of: shellPath)
        else { return false }
        let floor = ShellIntegration.bashENVStartupVersion
        return (version.major, version.minor) >= (floor.major, floor.minor)
    }

    public func bashVersion(shellPath: String) -> String? {
        guard ShellKind.detect(shellPath: shellPath) == .bash, let version = version(of: shellPath)
        else { return nil }
        return "\(version.major).\(version.minor)"
    }

    private func version(of shellPath: String) -> (major: Int, minor: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return answers[shellPath] ?? nil
    }

    /// `BASH_VERSINFO`'s first two fields, which every bash back to 2.0 sets. `-c` with no `-i`:
    /// a non-interactive shell reads no startup file, so this costs a fork and nothing else, and
    /// cannot be broken by anything in the user's configuration.
    public static func runVersionProbe(_ shellPath: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shellPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", "echo ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ answer: String?) -> (major: Int, minor: Int)? {
        let parts = (answer ?? "").split(separator: " ")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return (major, minor)
    }
}
```

- [ ] **Step 5: Implement the launch rules**

In `Sources/NyxCore/Shell/ShellIntegration.swift`, add `name` to `ShellKind`, add `ShellLaunch`, and make `launch` the primitive:

```swift
    public var name: String {
        switch self {
        case .zsh: return "zsh"
        case .bash: return "bash"
        case .fish: return "fish"
        case .other(let name): return name
        }
    }
```

```swift
    public static func launch(_ base: [String: String], arguments: [String], shellPath: String,
                              mode: ShellIntegrationMode, resources: URL?,
                              capabilities: ShellCapabilities = .shared,
                              pathExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> ShellLaunch {
        let untouched = ShellLaunch(environment: base, arguments: arguments)
        guard mode == .auto, let resources else { return untouched }

        switch ShellKind.detect(shellPath: shellPath) {
        case .zsh:
            let shim = resources.appendingPathComponent("zsh", isDirectory: true)
            guard pathExists(shim) else { return untouched }
            var env = base
            // The user's own ZDOTDIR travels separately so the shim can source their .zshrc and
            // then put the variable back -- a nested zsh must see the value they set, not ours.
            if let existing = base["ZDOTDIR"], !existing.isEmpty { env[originalZDotDir] = existing }
            env["ZDOTDIR"] = shim.path
            env[resourceDirectory] = resources.path
            return ShellLaunch(environment: env, arguments: arguments)

        case .bash:
            // Two gates, one guard. `--posix` makes ENV the one startup file an interactive bash
            // reads -- but only from 4.4, and macOS ships 3.2.57, which reports `posix on` and
            // reads ~/.bashrc anyway. Putting *that* bash into POSIX mode would take away every
            // startup file it has and give nothing back, so it is launched untouched and told
            // where the scripts are: `ShellIntegrationStatus` turns that into the line to paste.
            let shim = resources.appendingPathComponent("bash/nyx-shim.bash")
            guard pathExists(shim), capabilities.bashSupportsENVStartup(shellPath: shellPath) else {
                var env = base
                env[resourceDirectory] = resources.path
                return ShellLaunch(environment: env, arguments: arguments)
            }
            var env = base
            if let existing = base["ENV"], !existing.isEmpty { env[originalENV] = existing }
            env["ENV"] = shim.path
            env[resourceDirectory] = resources.path
            return ShellLaunch(environment: env, arguments: arguments + ["--posix"])

        case .fish:
            // fish sources every `fish/vendor_conf.d/*.fish` under `XDG_DATA_DIRS` at startup,
            // before config.fish, for interactive and non-interactive shells alike. Prepended, and
            // the original travels in NYX_XDG_DATA_DIRS -- the snippet puts it back before the
            // user's own configuration, or every XDG-aware program they start would see ours.
            let snippet = resources.appendingPathComponent("fish/vendor_conf.d/nyx.fish")
            guard pathExists(snippet) else { return untouched }
            var env = base
            let existing = base["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
            if let existing { env[originalXDGDataDirs] = existing }
            env["XDG_DATA_DIRS"] = resources.path + ":" + (existing ?? defaultXDGDataDirs)
            env[resourceDirectory] = resources.path
            return ShellLaunch(environment: env, arguments: arguments)

        case .other:
            // No shim we could rely on. Told where the scripts are, so `manualInstallCommand` can
            // point at a real file and the settings page can show it.
            var env = base
            env[resourceDirectory] = resources.path
            return ShellLaunch(environment: env, arguments: arguments)
        }
    }

    public static func environment(_ base: [String: String], shellPath: String,
                                   mode: ShellIntegrationMode, resources: URL?,
                                   capabilities: ShellCapabilities = .shared,
                                   pathExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> [String: String] {
        launch(base, arguments: [], shellPath: shellPath, mode: mode, resources: resources,
               capabilities: capabilities, pathExists: pathExists).environment
    }
```

and

```swift
    /// True when this shell will pick the integration up on its own -- zsh through `ZDOTDIR`, fish
    /// through `XDG_DATA_DIRS`, and bash 4.4 or newer through `--posix` and `ENV`. An older bash is
    /// *not* automatic: it is a shell we have a script for and no way to install, which is the one
    /// state `manualInstallCommand` was written for.
    public static func isAutomatic(shellPath: String, mode: ShellIntegrationMode,
                                   capabilities: ShellCapabilities = .shared) -> Bool {
        guard mode == .auto else { return false }
        switch ShellKind.detect(shellPath: shellPath) {
        case .zsh, .fish: return true
        case .bash: return capabilities.bashSupportsENVStartup(shellPath: shellPath)
        case .other: return false
        }
    }
```

Update the type's own doc comment: the paragraph beginning "The trick for zsh is `ZDOTDIR`" gains the two new mechanisms, the version gate and the reason `--rcfile` was refused.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --no-parallel --filter "ShellIntegration|ShellCapabilities"`
Expected: PASS. Also `swift build 2>&1 | grep -c warning:` → `0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/NyxCore/Shell/ShellIntegration.swift Sources/NyxCore/Shell/ShellCapabilities.swift \
        Tests/NyxCoreTests/ShellIntegrationTests.swift Tests/NyxCoreTests/ShellCapabilitiesTests.swift
git commit -m "$(cat <<'MSG'
One decision for a shell's launch, and it asks the bash before trusting it

bash needs `--posix` and ENV or neither, and on macOS's own bash 3.2.57 it needs
neither: driven over a PTY it reports `posix on` and reads ~/.bash_profile
anyway, never $ENV. Putting that bash into POSIX mode would take away every
startup file it has and give nothing back, so the hook is gated on bash >= 4.4 --
the same floor kitty and Ghostty use -- and the version is learned by running the
binary once per path, primed off the tab-creation path, defaulting to "no".

fish is reached by prepending our resource directory to XDG_DATA_DIRS, with the
user's own value carried in NYX_XDG_DATA_DIRS and the XDG default written out
when they had none.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP
MSG
)"
```

---

### Task 2: bash — the shim, the marks, and real bashes driven through a PTY

**Files:**
- Create: `Resources/shell-integration/bash/nyx-shim.bash`
- Modify: `Resources/shell-integration/bash/nyx-integration.bash` (rewritten below)
- Modify: `Sources/NyxCore/Session/TerminalSession.swift:23-37` (`loginShell` takes the configured shell and asks `launch` for both halves)
- Modify: `Sources/NyxApp/Pane.swift:382-395` (`sessionConfig` passes `config.shell` instead of patching `argv` afterwards)
- Modify: `Sources/NyxApp/AppDelegate.swift` (prime `ShellCapabilities` at launch and on each config reload)
- Test: `Tests/NyxCoreTests/ShellIntegrationLiveTests.swift` (new), `Tests/NyxCoreTests/TerminalSessionTests.swift` (one new case)

**Interfaces:**
- Consumes: `ShellIntegration.launch(_:arguments:shellPath:mode:resources:capabilities:pathExists:) -> ShellLaunch`, `ShellCapabilities` (Task 1).
- Produces:
```swift
public static func loginShell(cols: Int, rows: Int, palette: Palette, cwd: String? = nil,
                              shell: String? = nil,
                              shellIntegration: ShellIntegrationMode = .auto,
                              shellIntegrationResources: URL? = ShellIntegration.bundledResources) -> SessionConfig
```
and, for later tasks' tests, the harness in `ShellIntegrationLiveTests.swift`:
```swift
let repoResources: URL                                   // <repo>/Resources/shell-integration
let modernBashPath: String?                              // the first bash on this machine that is >= 4.4
struct FixtureHome { let url: URL; init(_ files: [String: String]) throws; func remove() }
func realShellSession(shell: String, home: FixtureHome, mode: ShellIntegrationMode = .auto,
                      extraEnvironment: [String: String] = [:]) throws -> TerminalSession
@discardableResult
func waitFor(_ s: TerminalSession, _ condition: @escaping (Terminal) -> Bool,
             timeout: TimeInterval = 15) -> Bool
func screen(_ s: TerminalSession) -> String
func screenLine(_ t: Terminal, contains needle: String) -> Bool
```

- [ ] **Step 1: Write the failing live tests**

Create `Tests/NyxCoreTests/ShellIntegrationLiveTests.swift`. This is the rung-2 half of the spec's "a passing unit test proves nothing about a shell that will not start": it launches the real binary on a real PTY with the real scripts.

```swift
import Foundation
import Testing
@testable import NyxCore

/// The repository's own `Resources/shell-integration`, found from this file rather than from a
/// bundle: under `swift test` there is no app bundle, so `ShellIntegration.bundledResources` is
/// the test runner's resource directory and injection would be skipped entirely.
let repoResources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/NyxCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root
    .appendingPathComponent("Resources/shell-integration")

/// The automatic bash path needs a bash that honours `$ENV` under `--posix`, which macOS's own
/// 3.2.57 does not. Homebrew's first, because that is where a 5.x comes from on this machine.
/// When there is none, the automatic cases are **skipped and reported as skipped** -- never
/// silently rewritten to test the shell that happens to be installed.
let modernBashPath: String? = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"]
    .first { path in
        FileManager.default.isExecutableFile(atPath: path)
            && ShellCapabilities().alsoPrimed(path).bashSupportsENVStartup(shellPath: path)
    }

/// `prime` returns nothing, and a `let` needs an expression: this is the one-liner that gives one.
extension ShellCapabilities {
    func alsoPrimed(_ path: String) -> ShellCapabilities { prime(shellPath: path); return self }
}

/// A throwaway `HOME` holding exactly the startup files a test wants.
///
/// Without it these tests would read the rc files of whoever is running the suite -- a prompt
/// framework, an `exec fish`, a `set -e` -- and fail or pass for reasons that have nothing to do
/// with the code. Paths are relative to the fixture home, so `".config/fish/config.fish"` works.
struct FixtureHome {
    let url: URL

    init(_ files: [String: String]) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nyx-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, contents) in files {
            let file = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// A real interactive shell on a real PTY, launched exactly the way `Pane` launches one -- with the
/// capabilities for this path primed first, which is what `AppDelegate` does before any window.
func realShellSession(shell: String, home: FixtureHome, mode: ShellIntegrationMode = .auto,
                      extraEnvironment: [String: String] = [:]) throws -> TerminalSession {
    var base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
                "HOME": home.url.path, "LANG": "en_US.UTF-8"]
    for (key, value) in extraEnvironment { base[key] = value }
    let capabilities = ShellCapabilities().alsoPrimed(shell)
    let launch = ShellIntegration.launch(base, arguments: ["-" + (shell as NSString).lastPathComponent],
                                         shellPath: shell, mode: mode, resources: repoResources,
                                         capabilities: capabilities)
    let config = SessionConfig(shellPath: shell, argv: launch.arguments,
                               environment: launch.environment, cwd: home.url.path,
                               cols: 80, rows: 24, scrollbackLimit: 500, palette: .xtermDefault())
    return try TerminalSession(config: config)
}

/// Polls until the terminal says so, rather than sleeping a fixed time: a cold bash on a busy
/// machine takes longer than any constant anyone would guess, and a sleep long enough to be safe is
/// a suite nobody runs.
@discardableResult
func waitFor(_ s: TerminalSession, _ condition: @escaping (Terminal) -> Bool,
             timeout: TimeInterval = 15) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if s.withTerminal(condition) { return true }
        usleep(50_000)
    }
    return false
}

func screen(_ s: TerminalSession) -> String { s.withTerminal { $0.text().joined(separator: "\n") } }

func screenLine(_ t: Terminal, contains needle: String) -> Bool {
    t.text().contains { $0.contains(needle) }
}

@Test(.enabled(if: modernBashPath != nil))
func aRealModernBashEmitsTheMarksTheParserExpects() throws {
    let bash = try #require(modernBashPath)
    let home = try FixtureHome([".bashrc": "PS1='bash$ '\nexport NYX_FIXTURE_RC=1\n"])
    defer { home.remove() }
    let s = try realShellSession(shell: bash, home: home)
    s.start()
    defer { s.terminate() }

    #expect(waitFor(s) { $0.shellEmitsPromptMarks }, "no OSC 133 A from bash: \(screen(s))")

    // `B` at the right column is what makes the command line readable at all: `currentInput` is
    // taken from the column the shell said typing begins at.
    s.send(Array("echo rc=$NYX_FIXTURE_RC".utf8))
    #expect(waitFor(s) { $0.currentInput == "echo rc=$NYX_FIXTURE_RC" },
            "B landed in the wrong column: \(String(describing: s.withTerminal { $0.currentInput }))")

    s.send(Array("\r".utf8))
    #expect(waitFor(s) { $0.lastFinishedCommand?.exitStatus == 0 }, "no D;0 from bash: \(screen(s))")
    // The shim read the user's own ~/.bashrc, which POSIX mode would have skipped.
    #expect(s.withTerminal { screenLine($0, contains: "rc=1") }, "the fixture .bashrc did not run: \(screen(s))")

    s.send(Array("false\r".utf8))
    #expect(waitFor(s) { $0.lastFinishedCommand?.exitStatus == 1 }, "no exit status in D: \(screen(s))")
    let region = try s.withTerminal { try #require($0.lastFinishedCommand) }
    #expect(region.outputStart != nil, "no C mark, so the block has no output start")
}

/// The regression the rewrite exists for, and the one a reviewer reproduced against the first
/// draft of this plan. bash fires the `DEBUG` trap for the commands in `PROMPT_COMMAND` as well as
/// for the user's, so a trap that cannot tell them apart marks the *prompt* as a running command:
/// a single bare Enter emitted `C` and then `D;0` for a command that never ran.
@Test(.enabled(if: modernBashPath != nil))
func aBareEnterIsNotACommand() throws {
    let bash = try #require(modernBashPath)
    let home = try FixtureHome([".bashrc": "PS1='bash$ '\n"])
    defer { home.remove() }
    let s = try realShellSession(shell: bash, home: home)
    s.start()
    defer { s.terminate() }
    #expect(waitFor(s) { $0.shellEmitsPromptMarks }, "no marks: \(screen(s))")

    s.send(Array("\r\r\r".utf8))
    usleep(700_000)
    #expect(s.withTerminal { $0.lastFinishedCommand } == nil,
            "a prompt command was marked as a command: \(screen(s))")
    #expect(s.withTerminal { $0.runningCommand } == nil, "the prompt is marked as running: \(screen(s))")
}

/// The same guard, with the user's own hooks in place: their `PROMPT_COMMAND` entry and their
/// `DEBUG` trap both keep running, and neither of them becomes a block.
@Test(.enabled(if: modernBashPath != nil))
func aRealBashKeepsTheUsersPromptCommandAndDebugTrap() throws {
    let bash = try #require(modernBashPath)
    let home = try FixtureHome([".bashrc": """
    PS1='bash$ '
    NYX_PC=0
    NYX_DBG=0
    PROMPT_COMMAND='NYX_PC=$((NYX_PC+1))'
    trap 'NYX_DBG=$((NYX_DBG+1))' DEBUG
    """])
    defer { home.remove() }
    let s = try realShellSession(shell: bash, home: home)
    s.start()
    defer { s.terminate() }
    #expect(waitFor(s) { $0.shellEmitsPromptMarks }, "no marks: \(screen(s))")

    s.send(Array("\r\r".utf8))
    usleep(500_000)
    #expect(s.withTerminal { $0.lastFinishedCommand } == nil,
            "the user's PROMPT_COMMAND entry was marked as a command: \(screen(s))")

    s.send(Array("echo pc=$NYX_PC dbg=$NYX_DBG\r".utf8))
    #expect(waitFor(s) { $0.lastFinishedCommand?.exitStatus == 0 }, "no D: \(screen(s))")
    let text = screen(s)
    #expect(text.contains("pc=") && !text.contains("pc=0"), "the user's PROMPT_COMMAND stopped running: \(text)")
    #expect(text.contains("dbg=") && !text.contains("dbg=0"), "the user's DEBUG trap stopped running: \(text)")
}

/// A login bash reads `/etc/profile` and the first of `~/.bash_profile`, `~/.bash_login`,
/// `~/.profile`. POSIX mode reads none of them, so the shim has to do it in bash's own order --
/// this is the file most people's PATH comes from.
@Test(.enabled(if: modernBashPath != nil))
func aRealLoginBashStillReadsTheUsersLoginFiles() throws {
    let bash = try #require(modernBashPath)
    let home = try FixtureHome([".bash_profile": "PS1='bash$ '\nexport NYX_FIXTURE_PROFILE=yes\n",
                                ".profile": "export NYX_FIXTURE_PROFILE=wrong-file\n"])
    defer { home.remove() }
    let s = try realShellSession(shell: bash, home: home)
    s.start()
    defer { s.terminate() }
    #expect(waitFor(s) { $0.shellEmitsPromptMarks }, "no marks: \(screen(s))")
    s.send(Array("echo profile=$NYX_FIXTURE_PROFILE\r".utf8))
    #expect(waitFor(s) { screenLine($0, contains: "profile=yes") },
            "the login files were skipped, or the wrong one was read: \(screen(s))")
}

/// macOS's own bash, which is the one most people meet. Two claims: it is launched **exactly** as
/// it would have been without Nyx -- no `--posix`, no `ENV` -- and the line Settings ▸ Shell tells
/// the user to paste actually works when they paste it. The second half is the whole manual path,
/// and nothing else in the suite tests it.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/bash")))
func theBashMacOSShipsIsLeftAloneAndItsPasteLineWorks() throws {
    let script = repoResources.appendingPathComponent("bash/nyx-integration.bash").path
    let home = try FixtureHome([".bashrc": "PS1='bash$ '\nsource \"\(script)\"\n"])
    defer { home.remove() }

    let capabilities = ShellCapabilities().alsoPrimed("/bin/bash")
    let launch = ShellIntegration.launch(["HOME": home.url.path], arguments: ["-bash"],
                                         shellPath: "/bin/bash", mode: .auto,
                                         resources: repoResources, capabilities: capabilities)
    #expect(launch.arguments == ["-bash"], "an old bash must never be put into POSIX mode")
    #expect(launch.environment["ENV"] == nil)

    let s = try realShellSession(shell: "/bin/bash", home: home)
    s.start()
    defer { s.terminate() }
    #expect(waitFor(s) { $0.shellEmitsPromptMarks },
            "the line the settings page offers does not produce marks: \(screen(s))")
    s.send(Array("false\r".utf8))
    #expect(waitFor(s) { $0.lastFinishedCommand?.exitStatus == 1 }, "no D;1: \(screen(s))")
}

/// zsh, unchanged, as the control: this file is where a script regression would otherwise hide.
@Test func aRealZshStillEmitsTheMarks() throws {
    let home = try FixtureHome([".zshrc": "PS1='zsh%% '\n"])
    defer { home.remove() }
    let s = try realShellSession(shell: "/bin/zsh", home: home)
    s.start()
    defer { s.terminate() }
    #expect(waitFor(s) { $0.shellEmitsPromptMarks }, "no marks from zsh: \(screen(s))")
    s.send(Array("false\r".utf8))
    #expect(waitFor(s) { $0.lastFinishedCommand?.exitStatus == 1 }, "no D;1 from zsh: \(screen(s))")
}

/// `shell-integration = off` has to reach the PTY, not just the settings file.
@Test func aShellLaunchedWithIntegrationOffMarksNothing() throws {
    let home = try FixtureHome([".zshrc": "PS1='zsh%% '\n"])
    defer { home.remove() }
    let s = try realShellSession(shell: "/bin/zsh", home: home, mode: .off)
    s.start()
    defer { s.terminate() }
    s.send(Array("echo hello\r".utf8))
    #expect(waitFor(s) { screenLine($0, contains: "hello") }, "the shell never ran: \(screen(s))")
    #expect(!s.withTerminal { $0.shellEmitsPromptMarks })
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --no-parallel --filter ShellIntegrationLive`
Expected: FAIL — no marks from any bash, because `nyx-shim.bash` does not exist yet and the guard therefore left the environment alone.
If `modernBashPath` is nil (`brew install bash`), the four automatic cases report as **skipped**. That is not a pass: the wave cannot be closed on it, and Task 7's rung 6 needs the same binary.

- [ ] **Step 3: Write the shim**

Create `Resources/shell-integration/bash/nyx-shim.bash`:

```bash
# Nyx's bash shim: the file $ENV points at.
#
# bash 4.4 and newer, in POSIX mode, reads exactly one startup file -- $ENV, for interactive shells,
# login or not -- and no other. That is why Nyx launches such a bash with `--posix`: it is the one
# hook that works for an interactive login shell and an interactive non-login one alike.
#
# The alternative, `--rcfile`, is worse at both ends: a login shell ignores it outright, so a login
# bash would get no hooks at all, and a non-login shell reads the named file *instead of*
# ~/.bashrc, so the user's own rc runs only if the terminal's file remembers to source it.
#
# bash 3.2 -- the one macOS ships -- does not honour $ENV even with `--posix`, so Nyx never puts it
# into POSIX mode and offers the user a `source` line for ~/.bashrc instead. Nothing here runs on
# that shell; `ShellCapabilities` is what keeps it away.
#
# Everything this file borrows is put back before the user sees a prompt: POSIX mode off, $ENV
# restored or unset, and their own startup files sourced in bash's own order.

# Out of POSIX mode first. It changes far more than startup files -- `.` search rules, `set -e`
# inside subshells, no `function` keyword, no `!` history -- and the user's rc files have to be
# read by the same bash that would have read them without Nyx in the picture.
set +o posix

# $ENV is exported, so a nested `sh` or `bash --posix` would source this file again and re-source
# the user's rc files with it. Their own $ENV, if they had one, is put back for those children;
# it is deliberately *not* sourced here, because a normal interactive bash never reads $ENV.
if [ -n "${NYX_ENV:-}" ]; then
  ENV=$NYX_ENV
  export ENV
  unset NYX_ENV
else
  unset ENV
fi

_nyx_shim_dir=${NYX_SHELL_INTEGRATION_DIR:-}

# bash's own order, which POSIX mode skipped, and nothing more than bash's own order. A login shell
# reads /etc/profile and then the *first* of the three personal login files that exists -- first,
# not all three, which is the rule a ~/.profile written for `sh` depends on. An interactive
# non-login shell reads ~/.bashrc and only that: bash never reads /etc/bashrc by itself, and
# sourcing it here would apply it twice on macOS, where /etc/profile and most people's ~/.bashrc
# already do.
if shopt -q login_shell; then
  [ -r /etc/profile ] && . /etc/profile
  for _nyx_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -r "$_nyx_rc" ]; then
      . "$_nyx_rc"
      break
    fi
  done
  unset _nyx_rc
else
  [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
fi

# Last, so the marks attach to whatever prompt the user ended up with, and so the hooks see the
# PROMPT_COMMAND and DEBUG trap their configuration installed.
if [ -n "$_nyx_shim_dir" ] && [ -r "$_nyx_shim_dir/bash/nyx-integration.bash" ]; then
  . "$_nyx_shim_dir/bash/nyx-integration.bash"
fi
unset _nyx_shim_dir
```

- [ ] **Step 4: Rewrite the marks**

Replace `Resources/shell-integration/bash/nyx-integration.bash` in full. The `DEBUG` trap's guard is the whole difference between this file and a four-line one, and it has two parts, both required: the trap skips any command that is one of `PROMPT_COMMAND`'s own entries, and the arm is cleared at the top of `_nyx_prompt` so it cannot survive into the next prompt cycle.

```bash
# Nyx shell integration for bash.
#
# Emits the OSC 133 marks that tell the terminal where a prompt begins, where the user's typing
# begins, where a command's output begins and how the command ended. Without these, jumping between
# commands, the status gutter, folding, "copy the last command's output", the ⋯ menu, watches and
# the pinned command line have nothing to work from.
#
# On bash 4.4 and newer, Nyx sources this automatically through `nyx-shim.bash`, which bash reaches
# with `--posix` and $ENV; nothing in your home directory is modified. On bash 3.2 -- the version
# macOS ships, which ignores $ENV -- this is the file Settings ▸ Shell asks you to source from
# ~/.bashrc, and the two paths meet here.

# Only interactive shells have a prompt to mark. `return`, not `exit`: this file is sourced.
case $- in *i*) ;; *) return 0 ;; esac
# Guard against being sourced twice -- once automatically and once from a hand-edited rc file.
[ -n "${NYX_INTEGRATION_LOADED:-}" ] && return 0
NYX_INTEGRATION_LOADED=1

# OSC 7: tells the terminal the working directory, which is how a new pane or tab opens where you
# already are. The path is percent-encoded because it is a URL, and paths contain spaces.
_nyx_report_cwd() {
  local encoded="" i char
  local LC_ALL=C
  for (( i = 0; i < ${#PWD}; i++ )); do
    char=${PWD:i:1}
    case $char in
      [A-Za-z0-9/._~-]) encoded+=$char ;;
      *) encoded+=$(printf '%%%02X' "'$char") ;;
    esac
  done
  printf '\e]7;file://%s%s\a' "${HOSTNAME}" "$encoded"
}

# The first entry of PROMPT_COMMAND.
#
# The exit status has to be read on the very first line, before anything else can overwrite it, and
# it is handed straight back on the way out: the user's own PROMPT_COMMAND entries now run *after*
# this one, and a `history -a` or a prompt framework that colours itself by $? must still see the
# status of the command it is reporting on.
#
# It also disarms. The arm is set by the last prompt-command entry and must not survive into the
# next cycle: if it did, the DEBUG trap that fires ahead of *this* function would fire armed, and a
# bare Enter -- which runs no command at all -- would emit C and then D;0 for a command that never
# ran. (It did. That is what this line is.)
_nyx_prompt() {
  local exit_status=$?
  _nyx_armed=
  if [ -n "${_nyx_command_running:-}" ]; then
    printf '\e]133;D;%s\a' "$exit_status"
    unset _nyx_command_running
  fi
  _nyx_report_cwd
  printf '\e]133;A\a'
  return $exit_status
}

# The last entry of PROMPT_COMMAND: from here until the next `_nyx_prompt`, the next command bash
# runs is the user's.
_nyx_arm() { _nyx_armed=1; }

# Every entry of PROMPT_COMMAND, one per line, recorded as we compose it. bash has no preexec; the
# DEBUG trap is the nearest thing, and it fires for each of these too. A trap that cannot tell them
# from the user's command marks the prompt as a command, which is one command's worth of drift in
# every block in the window.
_nyx_prompt_command_entries=$'_nyx_prompt\n_nyx_arm'

# Exact-match against those entries. A user who *types* a command that is also in their
# PROMPT_COMMAND loses the marks for that one command; bash-preexec has the same limitation, and it
# is a far smaller price than marking every prompt.
_nyx_is_prompt_command() {
  local candidate=$1 entry found=1 unglob=
  candidate=${candidate#"${candidate%%[![:space:]]*}"}
  candidate=${candidate%"${candidate##*[![:space:]]}"}
  [ -z "$candidate" ] && return 0
  # An entry containing `*` would otherwise be expanded by the unquoted word split below.
  case $- in *f*) ;; *) unglob=1; set -f ;; esac
  local IFS=$'\n'
  for entry in $_nyx_prompt_command_entries; do
    entry=${entry#"${entry%%[![:space:]]*}"}
    entry=${entry%"${entry##*[![:space:]]}"}
    [ -n "$entry" ] || continue
    if [ "$candidate" = "$entry" ]; then found=0; break; fi
  done
  [ -n "$unglob" ] && set +f
  return $found
}

_nyx_preexec() {
  # Programmable completion runs commands through the trap too, and a Tab is not a command.
  [ -n "${COMP_LINE:-}" ] && return
  _nyx_is_prompt_command "${BASH_COMMAND:-}" && return
  [ -z "${_nyx_armed:-}" ] && return
  _nyx_armed=
  _nyx_command_running=1
  printf '\e]133;C\a'
}

# Keep the user's own DEBUG trap and run it after ours. Their trap text is recovered by letting
# bash unquote its own `trap -p` output -- unpicking the `'\''` escaping by hand gets a trap
# containing a quote wrong, and silently replacing a debugger's trap is how a terminal breaks a
# tool somebody depends on.
_nyx_trap_line=$(trap -p DEBUG)
if [ -n "$_nyx_trap_line" ]; then
  _nyx_trap_line=${_nyx_trap_line#trap -- }
  _nyx_trap_line=${_nyx_trap_line% DEBUG}
  eval "_nyx_user_debug_command=$_nyx_trap_line"
fi
unset _nyx_trap_line

_nyx_debug() {
  _nyx_preexec
  [ -n "${_nyx_user_debug_command:-}" ] && eval "$_nyx_user_debug_command"
  return 0
}
trap '_nyx_debug' DEBUG

# bash 5.1 lets PROMPT_COMMAND be an array, and assigning a string to it would throw the user's
# other entries away. `declare -p` answers which it is on every bash back to 3.2.
case $(declare -p PROMPT_COMMAND 2>/dev/null) in
  "declare -a"*|"typeset -a"*)
    for _nyx_entry in "${PROMPT_COMMAND[@]}"; do
      _nyx_prompt_command_entries="${_nyx_prompt_command_entries}"$'\n'"$_nyx_entry"
    done
    unset _nyx_entry
    PROMPT_COMMAND=(_nyx_prompt "${PROMPT_COMMAND[@]}" _nyx_arm)
    ;;
  *)
    if [ -n "${PROMPT_COMMAND:-}" ]; then
      _nyx_prompt_command_entries="${_nyx_prompt_command_entries}"$'\n'"${PROMPT_COMMAND//;/$'\n'}"
    fi
    PROMPT_COMMAND="_nyx_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND};_nyx_arm"
    ;;
esac

# `B` marks the end of the prompt, so it belongs at the end of PS1 rather than in a hook. The
# \[...\] wrapper tells readline the sequence occupies no columns, without which the prompt is
# mismeasured and line editing corrupts the display.
if [[ $PS1 != *'133;B'* ]]; then
  PS1="${PS1}\[\e]133;B\a\]"
fi
```

- [ ] **Step 5: Wire the launch into the session**

`Sources/NyxCore/Session/TerminalSession.swift` — `loginShell` learns the configured shell and takes both halves from `launch`:

```swift
    /// The user's login shell with terminal environment variables set.
    ///
    /// `shell` is `config.shell` when the user named one: it has to be known *here*, because the
    /// shell decides the argv as well as the environment, and patching `shellPath` afterwards used
    /// to leave a fish session carrying zsh's `ZDOTDIR` and would now leave a bash session with
    /// `ENV` and no `--posix`.
    ///
    /// `shellIntegrationResources` is the directory holding the OSC 133 hooks; passing nil, or
    /// `mode: .off`, launches the shell exactly as the user configured it.
    public static func loginShell(cols: Int, rows: Int, palette: Palette, cwd: String? = nil,
                                  shell: String? = nil,
                                  shellIntegration: ShellIntegrationMode = .auto,
                                  shellIntegrationResources: URL? = ShellIntegration.bundledResources) -> SessionConfig {
        var env = ProcessInfo.processInfo.environment
        let configured = shell.flatMap { $0.isEmpty ? nil : $0 }
        let shellPath = configured ?? env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Nyx"
        env["TERM_PROGRAM_VERSION"] = Terminal.version
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let name = "-" + (shellPath as NSString).lastPathComponent
        let launch = ShellIntegration.launch(env, arguments: [name], shellPath: shellPath,
                                             mode: shellIntegration,
                                             resources: shellIntegrationResources)
        return SessionConfig(shellPath: shellPath, argv: launch.arguments,
                             environment: launch.environment, cwd: cwd ?? env["HOME"],
                             cols: cols, rows: rows, palette: palette)
    }
```

`Sources/NyxApp/Pane.swift`, in `sessionConfig(for:cols:rows:palette:inheriting:)`, replace the three-line patch after `loginShell` with the parameter:

```swift
        var sc = SessionConfig.loginShell(cols: cols, rows: rows, palette: palette, cwd: cwd,
                                          shell: config.shell,
                                          shellIntegration: config.shellIntegration)
        sc.scrollbackLimit = config.scrollbackLines
        return sc
```

`Sources/NyxApp/AppDelegate.swift` — the probe runs here and nowhere else, so no tab ever waits on a fork:

```swift
    /// Learn what the shells we might launch can do, before any window exists.
    ///
    /// `ShellCapabilities.prime` runs the binary, which takes single-digit milliseconds and must
    /// never happen while a tab is being made: ⌘T has to be instant. Called once at launch and
    /// again on every config reload, because `shell = …` can name a bash we have never met. A path
    /// that somehow reaches `Pane` unprimed is treated as incapable, which costs marks and cannot
    /// break a shell.
    private func primeShellCapabilities(for config: Config) {
        var paths = [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"]
        if let shell = config.shell, !shell.isEmpty { paths.append(shell) }
        for path in paths { ShellCapabilities.shared.prime(shellPath: path) }
    }
```
called from `applicationDidFinishLaunching` **before the first window is made**, and from the config-reload handler beside the other `configChanged` work.

Add to `Tests/NyxCoreTests/TerminalSessionTests.swift`:

```swift
/// `config.shell` used to be applied after the environment had already been built for `$SHELL`,
/// so a `shell = /bin/bash` line got zsh's decision: the argv the shell is launched with and the
/// variables it is launched with have to be taken from the same answer.
@Test func aConfiguredShellDecidesTheArgvAndTheEnvironmentTogether() {
    let c = SessionConfig.loginShell(cols: 80, rows: 24, palette: .xtermDefault(),
                                     shell: "/bin/bash", shellIntegration: .off)
    #expect(c.shellPath == "/bin/bash")
    #expect(c.argv == ["-bash"])
    #expect(c.environment["ZDOTDIR"] == nil)
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pkill -9 -f swiftpm-testing-helper; swift test --no-parallel --filter "ShellIntegration|ShellCapabilities|TerminalSession"`
Expected: PASS, including the modern-bash cases, the 3.2 paste-line case and the zsh control.
If a bash case fails, read the screen the failure message carries before changing anything: a shell that started but printed a syntax error is a shim bug; a shell with a working prompt and no marks is an integration-script bug; a shell that never printed a prompt is `--posix`/`ENV` not reaching the child.

- [ ] **Step 7: Commit**

```bash
git add Resources/shell-integration/bash/nyx-shim.bash \
        Resources/shell-integration/bash/nyx-integration.bash \
        Sources/NyxCore/Session/TerminalSession.swift Sources/NyxApp/Pane.swift \
        Sources/NyxApp/AppDelegate.swift \
        Tests/NyxCoreTests/ShellIntegrationLiveTests.swift Tests/NyxCoreTests/TerminalSessionTests.swift
git commit -m "$(cat <<'MSG'
bash 4.4 and up gets prompt marks unasked; 3.2 gets a line that works

The shim bash reaches through --posix and ENV turns POSIX mode back off and reads
/etc/profile and the first login file, or ~/.bashrc, in bash's own order -- and
nothing else: bash never reads /etc/bashrc by itself, and sourcing it here would
apply macOS's own twice.

The DEBUG trap fires for PROMPT_COMMAND's own entries too, so it skips anything
that is one of them and the arm is cleared at the top of _nyx_prompt. Without
both halves a bare Enter emitted C and then D;0 for a command that never ran --
reproduced against the first draft of this script under bash 5.3.

Tested by driving real bashes through a PTY with a fixture HOME: a 4.4+ bash for
the automatic path, and /bin/bash sourcing the line the settings page offers for
the manual one, which is the path most Macs will actually take.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP
MSG
)"
```

---

### Task 3: fish — the vendor snippet, a prompt wrapped at the right moment, and a real fish

**Files:**
- Create: `Resources/shell-integration/fish/vendor_conf.d/nyx.fish`
- Modify: `Resources/shell-integration/fish/nyx-integration.fish` (rewritten below)
- Test: `Tests/NyxCoreTests/ShellIntegrationLiveTests.swift` (three new cases), `Tests/NyxCoreTests/ShellIntegrationTests.swift` (one new case)

**Interfaces:**
- Consumes: `repoResources`, `FixtureHome`, `realShellSession`, `waitFor`, `screen`, `screenLine` (Task 2); `ShellIntegration.launch`, `ShellIntegration.originalXDGDataDirs`, `ShellIntegration.resourceDirectory` (Task 1).
- Produces: nothing new in Swift. Two shipped files: `fish/vendor_conf.d/nyx.fish` (the path `ShellIntegration.launch`'s fish guard checks) and `fish/nyx-integration.fish` (the path `manualInstallCommand` names).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NyxCoreTests/ShellIntegrationLiveTests.swift`:

```swift
/// Homebrew's path first: on this machine `/usr/bin/fish` does not exist, and a test that silently
/// tested nothing would be worse than one that says it was skipped.
let fishPath: String? = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@Test(.enabled(if: fishPath != nil))
func aRealFishEmitsTheMarksTheParserExpects() throws {
    let fish = try #require(fishPath)
    // fish reads its configuration from XDG_CONFIG_HOME, so the fixture has to point that at the
    // throwaway home as well or the suite runs against whoever's config.fish is on this machine.
    let home = try FixtureHome([".config/fish/config.fish": """
    function fish_prompt
        printf 'FIXTUREPROMPT> '
    end
    set -gx NYX_FIXTURE_RC 1
    """])
    defer { home.remove() }
    let s = try realShellSession(shell: fish, home: home,
                                 extraEnvironment: ["XDG_CONFIG_HOME": home.url.path + "/.config"])
    s.start()
    defer { s.terminate() }

    #expect(waitFor(s) { $0.shellEmitsPromptMarks }, "no OSC 133 A from fish: \(screen(s))")
    #expect(screen(s).contains("FIXTUREPROMPT>"),
            "the user's own fish_prompt was replaced rather than wrapped: \(screen(s))")

    s.send(Array("echo rc=$NYX_FIXTURE_RC".utf8))
    #expect(waitFor(s) { $0.currentInput == "echo rc=$NYX_FIXTURE_RC" },
            "B landed in the wrong column: \(String(describing: s.withTerminal { $0.currentInput }))")
    s.send(Array("\r".utf8))
    #expect(waitFor(s) { screenLine($0, contains: "rc=1") }, "the user's config.fish did not run: \(screen(s))")
    #expect(waitFor(s) { $0.lastFinishedCommand?.exitStatus == 0 }, "no D;0 from fish: \(screen(s))")

    s.send(Array("false\r".utf8))
    #expect(waitFor(s) { $0.lastFinishedCommand?.exitStatus == 1 }, "no exit status in D: \(screen(s))")
}

/// The snippet runs for *every* fish, including `fish -c` in a Makefile. `exit` in a sourced file
/// ends the shell, so the guard has to be `return` -- with `exit` this test's shell dies before it
/// runs anything, which is the shape of the worst bug this wave could ship.
@Test(.enabled(if: fishPath != nil))
func aNonInteractiveFishStillRunsWithOurSnippetInPlace() throws {
    let fish = try #require(fishPath)
    let launch = ShellIntegration.launch(["PATH": "/usr/bin:/bin"], arguments: [], shellPath: fish,
                                         mode: .auto, resources: repoResources)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fish)
    process.arguments = ["-c", "echo ok; echo dirs=$XDG_DATA_DIRS"]
    process.environment = launch.environment
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "fish refused to run: \(out)")
    #expect(out.contains("ok"))
    // And the snippet handed XDG_DATA_DIRS back before anything else could read it: a path inside
    // the app bundle must not leak into every program the shell starts.
    #expect(!out.contains(repoResources.path), "XDG_DATA_DIRS was not restored: \(out)")
}
```

Append to `Tests/NyxCoreTests/ShellIntegrationTests.swift`:

```swift
/// The two files the fish rules name -- the snippet the guard checks for and the script the
/// settings page offers to paste -- have to be files the bundle actually ships.
@Test func theFishRulesNameFilesTheBundleShips() {
    let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/shell-integration")
    for path in ["fish/vendor_conf.d/nyx.fish", "fish/nyx-integration.fish",
                 "bash/nyx-shim.bash", "bash/nyx-integration.bash"] {
        #expect(FileManager.default.fileExists(atPath: bundled.appendingPathComponent(path).path),
                "missing \(path)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --no-parallel --filter ShellIntegration`
Expected: FAIL — `theFishRulesNameFilesTheBundleShips` fails on `fish/vendor_conf.d/nyx.fish`. If fish is not installed on this machine the two live cases report as skipped, **which is not a pass**: see Task 7's rung 6, which requires a real fish.

- [ ] **Step 3: Write the vendor snippet**

Create `Resources/shell-integration/fish/vendor_conf.d/nyx.fish`:

```fish
# Nyx's fish snippet, found through XDG_DATA_DIRS.
#
# fish sources every `fish/vendor_conf.d/*.fish` under every entry of XDG_DATA_DIRS at startup, for
# interactive and non-interactive shells alike, *before* it reads the user's own config.fish. It is
# the one hook fish offers that needs nothing in the user's directory, which is why Nyx prepends its
# resource directory to XDG_DATA_DIRS and ships this file inside it.
#
# `return`, never `exit`: this file is sourced by config.fish, and `exit` in a sourced file ends the
# shell -- with `exit` here, every `fish -c` in every Makefile would die on its first line.

# XDG_DATA_DIRS goes back to the user's own value before anything else can read it. This runs
# before config.fish, so their configuration sees the value they set, and so does every program
# they start; the original travels in NYX_XDG_DATA_DIRS the way their ZDOTDIR travels in
# NYX_ZDOTDIR. The cost is that a fish started from inside this one has no marks, which is exactly
# what a nested zsh already does.
if set -q NYX_SHELL_INTEGRATION_DIR
    if set -q NYX_XDG_DATA_DIRS
        set -gx XDG_DATA_DIRS $NYX_XDG_DATA_DIRS
        set -e NYX_XDG_DATA_DIRS
    else
        # They had none, so neither should their children.
        set -e XDG_DATA_DIRS
    end
end

status is-interactive; or return 0
set -q NYX_SHELL_INTEGRATION_DIR; or return 0
test -r $NYX_SHELL_INTEGRATION_DIR/fish/nyx-integration.fish; or return 0
source $NYX_SHELL_INTEGRATION_DIR/fish/nyx-integration.fish
```

- [ ] **Step 4: Rewrite the marks**

Replace `Resources/shell-integration/fish/nyx-integration.fish` in full:

```fish
# Nyx shell integration for fish.
#
# Emits the OSC 133 marks that tell the terminal where a prompt begins, where the user's typing
# begins, where a command's output begins and how the command ended. Sourced automatically by
# `vendor_conf.d/nyx.fish`, which fish finds through XDG_DATA_DIRS; nothing in your configuration
# directory is modified. The same file is what Settings ▸ Shell offers to paste into a config.fish
# for a fish Nyx did not launch itself.

status is-interactive; or return 0
set -q NYX_INTEGRATION_LOADED; and return 0
set -g NYX_INTEGRATION_LOADED 1

# OSC 7: the working directory, so a new pane or tab opens where you already are.
function _nyx_report_cwd --on-variable PWD --description 'Nyx: OSC 7, the working directory'
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url -- $PWD | string replace -a '%2F' '/')
end

# fish fires this event before it runs `fish_prompt`, so `A` lands ahead of the prompt's first
# character -- and it is also the only moment at which the prompt itself can be wrapped.
#
# `B` has to be printed *after* the prompt, which means wrapping `fish_prompt`; and this file is a
# conf.d snippet, so it is sourced **before** the user's config.fish. A wrapper installed at load
# time would be thrown away by their own `function fish_prompt` a moment later, and the mark that
# says where typing begins would never be emitted. Wrapping on the first prompt instead is late
# enough that their definition is the one being wrapped. `functions --query` is what makes fish
# autoload its own default prompt if the user defined none; if it is somehow not there yet, the
# guard stays unset and the next prompt tries again.
function _nyx_prompt --on-event fish_prompt --description 'Nyx: OSC 133 A, and the prompt wrapper'
    if not set -q _nyx_prompt_wrapped
        if functions --query fish_prompt
            set -g _nyx_prompt_wrapped 1
            functions --copy fish_prompt _nyx_original_prompt
            function fish_prompt --description 'Nyx: the user prompt, with OSC 133 B after it'
                _nyx_original_prompt
                printf '\e]133;B\a'
            end
        end
    end
    printf '\e]133;A\a'
end

function _nyx_preexec --on-event fish_preexec --description 'Nyx: OSC 133 C, the command starts'
    printf '\e]133;C\a'
end

# `$status` on the first line, for the same reason bash reads `$?` first: anything else here would
# overwrite the status of the command being reported on.
function _nyx_postexec --on-event fish_postexec --description 'Nyx: OSC 133 D with the exit status'
    printf '\e]133;D;%s\a' $status
end

_nyx_report_cwd
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --no-parallel --filter ShellIntegration`
Expected: PASS; the two fish live cases pass on a machine with fish, and `theFishRulesNameFilesTheBundleShips` passes everywhere.
If fish is missing: `brew install fish`, then re-run. Do not close this task on skipped cases.

- [ ] **Step 6: Check the bundle carries the new directory**

Run: `scripts/bundle.sh && ls build/Nyx.app/Contents/Resources/shell-integration/fish/vendor_conf.d/`
Expected: `nyx.fish`. (`bundle.sh` already copies the tree with `cp -R`; this step is the proof, not a change.)

- [ ] **Step 7: Commit**

```bash
git add Resources/shell-integration/fish/vendor_conf.d/nyx.fish \
        Resources/shell-integration/fish/nyx-integration.fish \
        Tests/NyxCoreTests/ShellIntegrationLiveTests.swift Tests/NyxCoreTests/ShellIntegrationTests.swift
git commit -m "$(cat <<'MSG'
fish gets prompt marks through XDG_DATA_DIRS, and keeps its own prompt

fish sources every fish/vendor_conf.d snippet under XDG_DATA_DIRS at startup and
touches nothing in the user's configuration directory, so Nyx prepends its
resource directory and ships the snippet inside it. The snippet hands
XDG_DATA_DIRS straight back -- config.fish and every program the shell starts
must see the user's own value, not a path inside an app bundle.

The prompt is wrapped on the first fish_prompt event rather than at load: conf.d
runs before config.fish, so a wrapper installed at load time would be overwritten
by the user's own `function fish_prompt` and the B mark would never appear.

`return`, not `exit`, in both files: `exit` in a sourced file ends the shell, and
this one is sourced by every `fish -c` there is.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP
MSG
)"
```

---

### Task 4: `ShellIntegrationStatus` — every sentence about the marks, in one value

**Files:**
- Create: `Sources/NyxCore/Shell/ShellIntegrationStatus.swift`
- Test: `Tests/NyxCoreTests/ShellIntegrationStatusTests.swift`

**Interfaces:**
- Consumes: `ShellKind`, `ShellKind.name`, `ShellIntegrationMode`, `ShellIntegration.isAutomatic`, `ShellIntegration.manualInstallCommand`, `ShellIntegration.bundledResources`, `ShellCapabilities` (Task 1).
- Produces:
```swift
/// Why a shell we ship a script for is not getting it installed for it.
public enum ShellIntegrationLimit: Equatable {
    /// bash before 4.4 does not read `$ENV` under `--posix`. `version` is nil when the probe never
    /// ran, which reads as plain "bash" rather than inventing a number.
    case bashCannotBeReached(version: String?)
    /// "bash 3.2", or "bash".
    public var shellDescription: String
}

public struct ShellIntegrationStatus: Equatable {
    public let shell: ShellKind
    public let mode: ShellIntegrationMode
    public let isAutomatic: Bool
    public let marksSeen: Bool
    public let limit: ShellIntegrationLimit?
    public let resources: URL?
    public init(shell: ShellKind, mode: ShellIntegrationMode, isAutomatic: Bool,
                marksSeen: Bool, limit: ShellIntegrationLimit? = nil, resources: URL?)
    public static func current(shellPath: String, mode: ShellIntegrationMode, marksSeen: Bool,
                               resources: URL? = ShellIntegration.bundledResources,
                               capabilities: ShellCapabilities = .shared) -> ShellIntegrationStatus
    public var sentence: String
    public var manualLine: String?
    public static let manualCaption = "Paste this into your startup file, then open a new tab:"
    public var bannerText: String?
    public static let watchRefusalMessage = "Cannot watch a request in this pane"
    public var watchRefusalDetail: String
}

public struct ShellIntegrationNotice {
    public static let graceSeconds: Double = 5
    public init()
    public mutating func shouldTell(about status: ShellIntegrationStatus, shellPath: String,
                                    startedAt: Double, now: Double) -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/NyxCoreTests/ShellIntegrationStatusTests.swift`:

```swift
import Foundation
import Testing
@testable import NyxCore

private let resources = URL(fileURLWithPath: "/Applications/Nyx.app/Contents/Resources/shell-integration")
private let modernBash = ShellCapabilities { _ in "5 3" }
private let ancientBash = ShellCapabilities { _ in "3 2" }

private func status(_ shell: String = "/bin/zsh", mode: ShellIntegrationMode = .auto,
                    marksSeen: Bool = false,
                    capabilities: ShellCapabilities = modernBash) -> ShellIntegrationStatus {
    capabilities.prime(shellPath: shell)
    return .current(shellPath: shell, mode: mode, marksSeen: marksSeen, resources: resources,
                    capabilities: capabilities)
}

private func oldBash(_ mode: ShellIntegrationMode = .auto, marksSeen: Bool = false) -> ShellIntegrationStatus {
    status("/bin/bash", mode: mode, marksSeen: marksSeen, capabilities: ancientBash)
}

// MARK: - The five sentences

@Test func marksLiveIsTheSentenceWhenTheWindowHasSeenOne() {
    #expect(status("/opt/homebrew/bin/bash", marksSeen: true).sentence
            == "Prompt marks are live. Blocks, folding, Copy Output, the pinned command and watches all work here.")
}

/// A shell we inject into that has not marked anything *yet* is the first-launch-after-an-update
/// case: the running shells were started by the old bundle, and only a new tab gets the new hooks.
@Test func aShellWeInjectIntoButHaveNotHeardFromIsToldToOpenATab() {
    #expect(status("/opt/homebrew/bin/fish").sentence
            == "Nyx installs prompt marks into fish automatically. This window has not seen one yet \u{2014} open a new tab if this is the first launch after an update.")
}

@Test func aShellWithNoShimIsNamedAndItsLossesListed() {
    #expect(status("/bin/ksh").sentence
            == "Your shell is ksh. Nyx has no hooks for it, so blocks, folding, Copy Output, the \u{22EF} menu, the pinned command and watches are all off.")
}

@Test func theSettingSaysSoInItsOwnWords() {
    #expect(status("/bin/zsh", mode: .off).sentence
            == "Prompt marks are off by your setting. Blocks, folding, Copy Output, the \u{22EF} menu, the pinned command and watches are all off.")
}

/// The bash every Mac ships. It is not "a shell Nyx has no hooks for" -- the hooks exist and work,
/// this bash just cannot be made to load them by itself -- so it gets a sentence of its own that
/// ends in the thing the user can actually do.
@Test func theBashMacOSShipsIsNamedWithItsVersionAndPointedAtTheLine() {
    #expect(oldBash().sentence
            == "Your shell is bash 3.2, which cannot take prompt marks automatically: bash only reads the file Nyx installs them through from version 4.4. Paste the line below into ~/.bashrc, or install a newer bash.")
    #expect(oldBash().manualLine == "source \"\(resources.path)/bash/nyx-integration.bash\"")
}

/// Marks that are live win over every other sentence. A user who sources the line by hand -- which
/// is exactly what a bash 3.2 user is told to do -- has a gutter full of marks, and any sentence
/// about them being missing is a lie about their own screen.
@Test func liveMarksBeatEveryOtherSentence() {
    #expect(oldBash(.auto, marksSeen: true).sentence.hasPrefix("Prompt marks are live."))
    #expect(status("/bin/zsh", mode: .off, marksSeen: true).sentence.hasPrefix("Prompt marks are live."))
}

// MARK: - The line to paste

@Test func theManualLineIsOfferedWhenNothingIsInjectedAndWeKnowTheShell() {
    #expect(status("/bin/zsh", mode: .off).manualLine
            == "source \"\(resources.path)/zsh/nyx-integration.zsh\"")
}

@Test func thereIsNoLineToPasteForAShellWeHaveNoScriptFor() {
    #expect(status("/bin/ksh").manualLine == nil)
}

/// Nothing to paste when the shell is already being injected into: the line would be a second
/// installation, and the scripts guard against being sourced twice precisely because people do it.
@Test func aShellBeingInjectedIntoIsOfferedNothing() {
    #expect(status("/opt/homebrew/bin/bash").manualLine == nil)
}

// MARK: - The banner

@Test func theBannerNamesTheShellAndWhatIsOff() {
    #expect(status("/bin/ksh").bannerText
            == "Nyx could not add prompt marks to ksh \u{2014} blocks, folding and watches are off in this pane.")
}

/// Deliberate: an automatic shell whose marks never arrived gets the same sentence. It is the one
/// case where "could not" is exactly right -- the hooks were installed and something ate them --
/// and without this the banner could never fire for zsh, fish or a modern bash at all.
@Test func anAutomaticShellWhoseMarksNeverCameIsStillWorthSaying() {
    #expect(status("/opt/homebrew/bin/fish").bannerText
            == "Nyx could not add prompt marks to fish \u{2014} blocks, folding and watches are off in this pane.")
}

/// bash 3.2 has a next move, so its banner says what it is rather than only what is lost.
@Test func theBannerForAnOldBashPointsAtTheLine() {
    #expect(oldBash().bannerText
            == "Nyx cannot add prompt marks to bash 3.2 by itself \u{2014} paste the line from Settings \u{25B8} Shell into ~/.bashrc.")
}

/// The setting's own case gets the setting's own words: "could not" would be false about a choice
/// the user made on purpose.
@Test func theBannerSaysTheSettingWhenTheSettingIsWhyTheMarksAreMissing() {
    #expect(status("/bin/zsh", mode: .off).bannerText
            == "Prompt marks are off by your setting \u{2014} blocks, folding and watches are off in this pane.")
}

@Test func thereIsNothingToSayOnceTheMarksArrive() {
    #expect(status("/opt/homebrew/bin/bash", marksSeen: true).bannerText == nil)
}

// MARK: - The refusal

@Test func theRefusalNamesTheShellAndTheThreeWeHandle() {
    #expect(ShellIntegrationStatus.watchRefusalMessage == "Cannot watch a request in this pane")
    #expect(status("/bin/ksh").watchRefusalDetail
            == "A watch sends its next run only when the shell is back at a prompt, and this shell does not tell Nyx where its prompts are. Nyx adds prompt marks to zsh, bash and fish by itself; this pane is running ksh.")
}

@Test func theRefusalSaysTheSettingWhenTheSettingIsTheReason() {
    #expect(status("/bin/zsh", mode: .off).watchRefusalDetail
            == "A watch sends its next run only when the shell is back at a prompt, and this shell does not tell Nyx where its prompts are. Prompt marks are off by your setting.")
}

/// "Nyx adds prompt marks to bash by itself" would be a lie to the majority of Mac users, who are
/// on 3.2 -- and the sentence has to end somewhere they can go.
@Test func theRefusalTellsAnOldBashWhereItsLineGoes() {
    #expect(oldBash().watchRefusalDetail
            == "A watch sends its next run only when the shell is back at a prompt, and this shell does not tell Nyx where its prompts are. Nyx adds prompt marks to zsh, fish and bash 4.4 or newer by itself; this pane is running bash 3.2, whose line has to go into ~/.bashrc by hand \u{2014} Settings \u{25B8} Shell has it.")
}

// MARK: - Telling them once

@Test func theNoticeIsGivenOncePerShellForTheLifeOfTheProcess() {
    var notices = ShellIntegrationNotice()
    let ksh = status("/bin/ksh")
    let first = notices.shouldTell(about: ksh, shellPath: "/bin/ksh", startedAt: 0, now: 10)
    let second = notices.shouldTell(about: ksh, shellPath: "/bin/ksh", startedAt: 0, now: 20)
    #expect(first)
    #expect(!second, "a second tab in the same shell says it again")
}

/// A user who changes shells in a new session is told again: that is the case where the sentence
/// is news rather than noise.
@Test func aDifferentShellIsNewsAgain() {
    var notices = ShellIntegrationNotice()
    _ = notices.shouldTell(about: status("/bin/ksh"), shellPath: "/bin/ksh", startedAt: 0, now: 10)
    #expect(notices.shouldTell(about: status("/bin/tcsh"), shellPath: "/bin/tcsh", startedAt: 0, now: 10))
}

/// The marks arrive after the shell does, and a cold zsh with a prompt framework can take seconds.
/// Saying "no marks" while the shell is still sourcing rc files would be a banner the gutter
/// contradicts half a second later, so the grace is generous: this sentence is a statement about a
/// shell that will *never* mark, and being late costs nothing.
@Test func nothingIsSaidBeforeTheShellHasHadItsGrace() {
    var notices = ShellIntegrationNotice()
    #expect(!notices.shouldTell(about: status("/bin/ksh"), shellPath: "/bin/ksh", startedAt: 0, now: 1))
    #expect(notices.shouldTell(about: status("/bin/ksh"), shellPath: "/bin/ksh",
                               startedAt: 0, now: ShellIntegrationNotice.graceSeconds))
}

@Test func aShellThatMarkedItsPromptIsNeverMentioned() {
    var notices = ShellIntegrationNotice()
    #expect(!notices.shouldTell(about: status("/opt/homebrew/bin/bash", marksSeen: true),
                                shellPath: "/opt/homebrew/bin/bash", startedAt: 0, now: 10))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --no-parallel --filter ShellIntegrationStatus`
Expected: FAIL — `cannot find 'ShellIntegrationStatus' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/NyxCore/Shell/ShellIntegrationStatus.swift`:

```swift
import Foundation

/// Why a shell Nyx ships a script for is not having it installed for it.
public enum ShellIntegrationLimit: Equatable {
    /// bash before 4.4 does not honour `$ENV` under `--posix` -- reproduced on 3.2.57, which is
    /// what macOS ships -- so there is no way to load the hooks without the user's help.
    case bashCannotBeReached(version: String?)

    /// How every sentence names it: "bash 3.2" when the probe answered, plain "bash" when it did
    /// not. Inventing a version number for a shell we failed to ask would be worse than omitting it.
    public var shellDescription: String {
        switch self {
        case .bashCannotBeReached(let version):
            return version.map { "bash \($0)" } ?? "bash"
        }
    }
}

/// The state of a pane's prompt marks, and every sentence anything says about it.
///
/// Three surfaces describe this one fact -- the Shell settings page, the banner a pane raises when
/// its shell marked nothing, and the refusal a watch gives -- and before this value they said three
/// different things, one of which ("Set shell-integration = auto and open a new tab") advised the
/// user to set the value it already had. Keeping the words here means the page, the banner and the
/// alert cannot drift, and that an announcement reads out what is on the screen (spec §8.1).
public struct ShellIntegrationStatus: Equatable {
    public let shell: ShellKind
    public let mode: ShellIntegrationMode
    /// From `ShellIntegration.isAutomatic(shellPath:mode:capabilities:)`: this shell picks the
    /// hooks up on its own.
    public let isAutomatic: Bool
    /// This window has seen an OSC 133 `A` since it opened.
    public let marksSeen: Bool
    /// Set when we have a script for this shell and no way to install it -- today, bash < 4.4.
    public let limit: ShellIntegrationLimit?
    /// Where the scripts are, for the line the user may want to paste. nil outside an app bundle.
    public let resources: URL?

    public init(shell: ShellKind, mode: ShellIntegrationMode, isAutomatic: Bool,
                marksSeen: Bool, limit: ShellIntegrationLimit? = nil, resources: URL?) {
        self.shell = shell
        self.mode = mode
        self.isAutomatic = isAutomatic
        self.marksSeen = marksSeen
        self.limit = limit
        self.resources = resources
    }

    public static func current(shellPath: String, mode: ShellIntegrationMode, marksSeen: Bool,
                               resources: URL? = ShellIntegration.bundledResources,
                               capabilities: ShellCapabilities = .shared) -> ShellIntegrationStatus {
        let shell = ShellKind.detect(shellPath: shellPath)
        let automatic = ShellIntegration.isAutomatic(shellPath: shellPath, mode: mode,
                                                     capabilities: capabilities)
        var limit: ShellIntegrationLimit?
        if shell == .bash, !capabilities.bashSupportsENVStartup(shellPath: shellPath) {
            limit = .bashCannotBeReached(version: capabilities.bashVersion(shellPath: shellPath))
        }
        return ShellIntegrationStatus(shell: shell, mode: mode, isAutomatic: automatic,
                                      marksSeen: marksSeen, limit: limit, resources: resources)
    }

    /// What the settings page says, and what an announcement reads out.
    ///
    /// `marksSeen` is asked first, before everything else: a bash 3.2 user who did paste the line,
    /// or anyone who installed the hooks by hand with `shell-integration = off`, has working marks,
    /// and "prompt marks are off" while their gutter fills up is exactly the sentence this type
    /// exists to prevent.
    public var sentence: String {
        if marksSeen {
            return "Prompt marks are live. Blocks, folding, Copy Output, the pinned command and watches all work here."
        }
        if mode == .off {
            return "Prompt marks are off by your setting. Blocks, folding, Copy Output, the \(Self.dots) menu, the pinned command and watches are all off."
        }
        if let limit {
            return "Your shell is \(limit.shellDescription), which cannot take prompt marks automatically: bash only reads the file Nyx installs them through from version 4.4. Paste the line below into ~/.bashrc, or install a newer bash."
        }
        if isAutomatic {
            return "Nyx installs prompt marks into \(shell.name) automatically. This window has not seen one yet \(Self.dash) open a new tab if this is the first launch after an update."
        }
        return "Your shell is \(shell.name). Nyx has no hooks for it, so blocks, folding, Copy Output, the \(Self.dots) menu, the pinned command and watches are all off."
    }

    public static let manualCaption = "Paste this into your startup file, then open a new tab:"

    /// The line to paste, shown whenever nothing is being injected and there is a script for this
    /// shell. `manualInstallCommand`'s first caller since it was written, and, on a stock Mac, the
    /// whole of the bash story.
    public var manualLine: String? {
        guard !isAutomatic, let resources else { return nil }
        return ShellIntegration.manualInstallCommand(shellPath: shell.name, resources: resources)
    }

    /// What the pane says once, the first time a shell finishes starting without marking anything.
    /// nil when there is nothing to say.
    ///
    /// An **automatic** shell reaches the third branch: the hooks were installed and the marks
    /// never came, which is a real failure and the one the §4.3 sentence describes exactly. Without
    /// that branch this banner could never fire for zsh, fish or a modern bash at all.
    public var bannerText: String? {
        guard !marksSeen else { return nil }
        if mode == .off {
            return "Prompt marks are off by your setting \(Self.dash) blocks, folding and watches are off in this pane."
        }
        if let limit {
            return "Nyx cannot add prompt marks to \(limit.shellDescription) by itself \(Self.dash) paste the line from Settings \(Self.pointer) Shell into ~/.bashrc."
        }
        return "Nyx could not add prompt marks to \(shell.name) \(Self.dash) blocks, folding and watches are off in this pane."
    }

    public static let watchRefusalMessage = "Cannot watch a request in this pane"

    /// Why a watch cannot start here, and what would change it. The old text told the user to set
    /// the value that is already the default, so a fish user followed it, was refused identically,
    /// and had no next move (`findings-pm.md` §2).
    public var watchRefusalDetail: String {
        let why: String
        if mode == .off {
            why = "Prompt marks are off by your setting."
        } else if let limit {
            why = "Nyx adds prompt marks to zsh, fish and bash 4.4 or newer by itself; this pane is running \(limit.shellDescription), whose line has to go into ~/.bashrc by hand \(Self.dash) Settings \(Self.pointer) Shell has it."
        } else {
            why = "Nyx adds prompt marks to zsh, bash and fish by itself; this pane is running \(shell.name)."
        }
        return "A watch sends its next run only when the shell is back at a prompt, and this shell does not tell Nyx where its prompts are. " + why
    }

    private static let dots = "\u{22EF}"    // ⋯, the same glyph the block strip's button carries
    private static let dash = "\u{2014}"    // —
    private static let pointer = "\u{25B8}" // ▸, as in "Settings ▸ Shell"
}

/// Which shells have already been mentioned, for the life of this process.
///
/// Per shell *path*, not per tab: a user with four ksh tabs is told once. Not written to disk
/// either -- a user who changes shells in a new session is told again, which is the case where the
/// sentence is news rather than noise (spec §4.3).
public struct ShellIntegrationNotice {
    /// How long a shell gets to mark its first prompt before Nyx concludes it never will.
    ///
    /// Generous on purpose. A cold zsh with a prompt framework can take seconds, and the sentence
    /// this gates is a statement about a shell that will *never* mark: being late costs nothing,
    /// being early puts a banner on screen that the gutter contradicts a moment later.
    public static let graceSeconds: Double = 5

    private var told: Set<String> = []

    public init() {}

    public mutating func shouldTell(about status: ShellIntegrationStatus, shellPath: String,
                                    startedAt: Double, now: Double) -> Bool {
        guard status.bannerText != nil else { return false }
        guard now >= startedAt + Self.graceSeconds else { return false }
        guard !told.contains(shellPath) else { return false }
        told.insert(shellPath)
        return true
    }
}
```

Note `manualLine` passes `shell.name` to `manualInstallCommand(shellPath:resources:)`, which identifies the shell by its last path component — `"bash"` and `"/bin/bash"` resolve identically, and this keeps the status from having to carry the whole path.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --no-parallel --filter ShellIntegrationStatus`
Expected: PASS (21 cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/NyxCore/Shell/ShellIntegrationStatus.swift \
        Tests/NyxCoreTests/ShellIntegrationStatusTests.swift
git commit -m "$(cat <<'MSG'
One value owns every sentence about a pane's prompt marks

The settings page, the banner and the watch refusal describe one fact, and until
now said three different things -- one of them advising the user to set the value
it already had. Five sentences, a line to paste, three banners and three
refusals, all derived from shell + mode + marks-seen + why-not, and all tested by
their exact words.

bash 3.2 gets sentences of its own rather than being lumped in with a shell we
have no hooks for: the hooks exist, this bash cannot load them, and the sentence
ends where the user can act -- the line to paste into ~/.bashrc.

Live marks beat everything: a user who pasted that line is looking at a full
gutter, and any sentence about missing marks would be a lie about their screen.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP
MSG
)"
```

---

### Task 5: A Shell page in Settings, and `manualInstallCommand` with a caller

**Files:**
- Modify: `Sources/NyxApp/SettingsWindowController.swift` (a `Shell` tab between Behaviour and Keys, its page, its refresh, `showShellPage()`, a snapshot setter)
- Modify: `Sources/NyxApp/AppDelegate.swift` (`openShellSettings(_:)`, and pointing the window at the focused pane)
- Modify: `Sources/NyxApp/TerminalWindowController.swift` (`focusedPane`, `focusedLocalPane`), `Sources/NyxApp/TabController.swift` (`everyPane`)
- Modify: `Sources/NyxApp/Pane.swift` (`shellPath`, optional, and `shellIntegrationStatus`)
- Modify: `Sources/NyxCore/Config/ConfigDiff.swift` (`shellIntegrationChanged` + its deferred note)
- Modify: `Sources/NyxApp/UISnapshot.swift` (`writeSettings` renders the four Shell states)
- Modify: `docs/configuration.md` (the `shell-integration` row and the environment table)
- Test: `Tests/NyxCoreTests/ConfigDiffTests.swift`

**Interfaces:**
- Consumes: `ShellIntegrationStatus` (`sentence`, `manualLine`, `manualCaption`) from Task 4.
- Produces:
```swift
// SettingsWindowController
var shellStatus: () -> ShellIntegrationStatus          // set by AppDelegate; defaults to $SHELL, .auto, no marks
func showShellPage()
func setShellStatusForSnapshot(_ status: ShellIntegrationStatus)
// TerminalWindowController
var focusedPane: Pane? { get }
var focusedLocalPane: Pane? { get }
// TabController
var everyPane: [Pane] { get }
// Pane
let shellPath: String?                                  // nil for a remote pane
var shellIntegrationStatus: ShellIntegrationStatus? { get }
// AppDelegate
@objc func openShellSettings(_ sender: Any?)
// ConfigDiff
public var shellIntegrationChanged: Bool
```

- [ ] **Step 1: Write the failing Core test**

Append to `Tests/NyxCoreTests/ConfigDiffTests.swift`:

```swift
/// The pop-up on the new Shell page writes a value that only a *new* shell can act on, so the
/// banner has to say so -- a setting that visibly does nothing is the shape of every "it didn't
/// work" report in this project.
@Test func changingShellIntegrationIsNotedAsApplyingToNewTabs() {
    var next = Config.defaults
    next.shellIntegration = .off
    let diff = ConfigDiff(from: .defaults, to: next)
    #expect(diff.shellIntegrationChanged)
    #expect(diff.deferredNotes.contains("shell-integration applies to new tabs only"))
    // Nothing on screen is rebuilt for it, so `apply` has nothing to do.
    #expect(diff.isEmpty)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --no-parallel --filter ConfigDiff`
Expected: FAIL — `value of type 'ConfigDiff' has no member 'shellIntegrationChanged'`.

- [ ] **Step 3: Implement the diff**

In `Sources/NyxCore/Config/ConfigDiff.swift`:

```swift
    /// `shell-integration`: read only when a session is created, so nothing on screen is rebuilt
    /// and this flag is not part of `isEmpty` -- it exists for the deferred note, which is the
    /// whole user-visible effect of changing it.
    public var shellIntegrationChanged: Bool
```
set in `init` with `shellIntegrationChanged = old.shellIntegration != new.shellIntegration`, and in `deferredNotes`:
```swift
        if shellIntegrationChanged { notes.append("shell-integration applies to new tabs only") }
```

- [ ] **Step 4: Give the pane a shell path and a status**

In `Sources/NyxApp/Pane.swift`, store the path the session was launched with and expose the status. **The path is optional**, and that is not defensiveness: `Pane`'s designated init (`Pane.swift:322`) takes a `PaneSession`, and only the local convenience init (`:299`) builds a `SessionConfig` at all. The remote init (`:317`) attaches to a session running on another Mac and has no shell path to record — a remote pane stores nil, is excluded from `reportShellIntegration()` (Task 6), and is never what the settings page describes.

```swift
    /// The shell *this pane* launched, or nil for a remote pane, which is attached to a session on
    /// another Mac and knows nothing about the shell behind it.
    ///
    /// Settings ▸ Shell, the banner and the watch refusal all describe a pane, not the process: a
    /// window can hold a zsh tab and a `shell = /bin/ksh` tab at the same time, and a sentence
    /// about "your shell" that names the wrong one is worse than no sentence.
    let shellPath: String?

    /// What every surface says about this pane's prompt marks. nil for a remote pane: the host
    /// decides its own shell integration and this Mac's settings page cannot speak for it.
    var shellIntegrationStatus: ShellIntegrationStatus? {
        guard let shellPath else { return nil }
        return .current(shellPath: shellPath, mode: config.shellIntegration,
                        marksSeen: session.withTerminal { $0.shellEmitsPromptMarks })
    }
```
The local convenience init passes `sc.shellPath` through to the designated one; the remote init passes nil.

In `Sources/NyxApp/TerminalWindowController.swift`:

```swift
    /// The pane the user is looking at in this window -- what Settings ▸ Shell describes and where
    /// a no-marks notice belongs.
    var focusedPane: Pane? { tabs?.focusedPane }

    /// The focused pane if it is a local one, else the first local pane in this window. A remote
    /// pane has no shell of ours to describe, and a settings page that went blank because the user
    /// happened to be looking at a remote tab would read as a bug.
    var focusedLocalPane: Pane? {
        if let focused = focusedPane, focused.shellIntegrationStatus != nil { return focused }
        // `TabController` reaches its panes through `tab.panes.allPanes` (`TabController:403`).
        return tabs?.everyPane.first { $0.shellIntegrationStatus != nil }
    }
```

and in `Sources/NyxApp/TabController.swift`, beside `focusedPane` (`:159`), the flat list the window needs — the pieces are already there, `tab.panes.allPanes` is what `closeTabs` walks (`:403`):

```swift
    /// Every pane in every tab of this window, in tab order.
    var everyPane: [Pane] { tabs.flatMap(\.panes.allPanes) }
```

- [ ] **Step 5: Build the page**

In `Sources/NyxApp/SettingsWindowController.swift`, add the tab between Behaviour and Keys:

```swift
        tabs.addTabViewItem(tab("Behaviour", behaviourPage()))
        tabs.addTabViewItem(tab("Shell", shellPage()))
        tabs.addTabViewItem(tab("Keys", keysPage()))
```

and the page itself, with its stored controls:

```swift
    private let shellStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let shellManualCaption = NSTextField(labelWithString: ShellIntegrationStatus.manualCaption)
    private let shellManualField = NSTextField(labelWithString: "")
    private lazy var shellCopyButton = NSButton(title: "Copy", target: self,
                                                action: #selector(copyShellLine(_:)))

    /// Who to ask about the pane the user is looking at. `AppDelegate` points this at the key
    /// window's focused pane; the default answers from the process's own `$SHELL` so the page is
    /// never blank when there is no window at all.
    var shellStatus: () -> ShellIntegrationStatus = {
        .current(shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                 mode: .auto, marksSeen: false)
    }

    private func shellPage() -> NSView {
        let rows = [row("Prompt marks", popUp("shell-integration", options: ["auto", "off"]))]
        let grid = NSGridView(views: rows.map { [$0.0, $0.1] })
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        shellStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        shellStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shellStatusLabel.preferredMaxLayoutWidth = 460
        shellStatusLabel.describeForAccessibility("Prompt mark status", role: .staticText)

        shellManualCaption.translatesAutoresizingMaskIntoConstraints = false
        shellManualCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shellManualCaption.textColor = .secondaryLabelColor

        // Selectable and monospaced: it is a line of shell, and being able to select it by hand is
        // what makes the Copy button a convenience rather than the only way out of this page.
        shellManualField.translatesAutoresizingMaskIntoConstraints = false
        shellManualField.isSelectable = true
        shellManualField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shellManualField.lineBreakMode = .byTruncatingMiddle
        shellManualField.describeForAccessibility("The line to paste into your startup file",
                                                  role: .staticText)

        shellCopyButton.translatesAutoresizingMaskIntoConstraints = false
        shellCopyButton.bezelStyle = .rounded
        shellCopyButton.setAccessibilityHelp("Copies the line above to the clipboard.")

        let note = footnote("Prompt marks are OSC 133 sequences: they tell Nyx where a prompt ends "
                            + "and a command begins, which is what blocks, folding, Copy Output, the "
                            + "pinned command line and watches are all built on. Nyx adds them to "
                            + "zsh, bash and fish without changing anything in your home directory.")

        let view = NSView()
        for subview in [grid, shellStatusLabel, shellManualCaption, shellManualField,
                        shellCopyButton, note] as [NSView] {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),

            // The sentence sits directly under the control it explains, not at the foot of the
            // page: the Remote page's status line is ~300 pt from the buttons it describes and the
            // owner never saw it (spec §5.3).
            shellStatusLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            shellStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            shellStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            shellManualCaption.topAnchor.constraint(equalTo: shellStatusLabel.bottomAnchor, constant: 14),
            shellManualCaption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            shellManualCaption.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),

            shellManualField.topAnchor.constraint(equalTo: shellManualCaption.bottomAnchor, constant: 4),
            shellManualField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            shellManualField.trailingAnchor.constraint(lessThanOrEqualTo: shellCopyButton.leadingAnchor, constant: -10),

            shellCopyButton.centerYAnchor.constraint(equalTo: shellManualField.centerYAnchor),
            shellCopyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            note.topAnchor.constraint(greaterThanOrEqualTo: shellManualField.bottomAnchor, constant: 16),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        refreshShellPage()
        return view
    }

    private func refreshShellPage() {
        let status = shellStatus()
        shellStatusLabel.stringValue = status.sentence
        shellStatusLabel.setAccessibilityValue(status.sentence)
        let line = status.manualLine
        shellManualField.stringValue = line ?? ""
        // Hidden rather than greyed: an empty caption over an empty field is three controls
        // explaining nothing.
        for control in [shellManualCaption, shellManualField, shellCopyButton] as [NSView] {
            control.isHidden = line == nil
        }
    }

    @objc private func copyShellLine(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellManualField.stringValue, forType: .string)
    }

    /// Settings ▸ Shell: where the no-marks banner's button and the watch refusal's default button
    /// both go, so that a user who has never opened this window still lands on the one control
    /// that changes what they were just told.
    func showShellPage() {
        selectPage(labelled: "Shell")
        refreshShellPage()
    }

    /// A fixed status for the snapshot run: the page must not render from whatever shell the
    /// machine taking the pictures happens to use.
    func setShellStatusForSnapshot(_ status: ShellIntegrationStatus) {
        shellStatus = { status }
        refreshShellPage()
    }
```

Generalise the page selector (`selectRemotePage` becomes one line over it):

```swift
    private func selectPage(labelled label: String) {
        guard let content = window?.contentView,
              let tabs = content.subviews.compactMap({ $0 as? NSTabView }).first else { return }
        for index in 0..<tabs.numberOfTabViewItems where tabs.tabViewItem(at: index).label == label {
            tabs.selectTabViewItem(at: index)
        }
    }

    private func selectRemotePage() { selectPage(labelled: "Remote") }
```

In `refresh(_:diagnostics:)`, beside the other pop-ups:

```swift
        set("shell-integration", c.shellIntegration.rawValue)
        refreshShellPage()
```

- [ ] **Step 6: Point the window at the pane, and give the banner and the alert somewhere to go**

In `Sources/NyxApp/AppDelegate.swift`:

```swift
    /// Settings ▸ Shell. Reached from the no-marks banner, from the watch refusal, and from ⌘, like
    /// any other page -- the two sentences that send a user here both name a control, so the
    /// control has to be one press away.
    @objc func openShellSettings(_ sender: Any?) {
        openConfig(nil)
        settings?.showShellPage()
    }
```
and, inside `openConfig(_:)`, immediately after the controller is constructed:
```swift
            controller.shellStatus = { [weak self] in
                self?.currentShellStatus() ?? .current(
                    shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                    mode: .auto, marksSeen: false)
            }
```
with
```swift
    /// The local pane the user is looking at, or any local pane, or the process's own shell: the
    /// settings page describes a pane, there may not be one, and a remote pane is not one -- its
    /// shell lives on another Mac, whose own copy of Nyx decides its integration.
    private func currentShellStatus() -> ShellIntegrationStatus {
        let pane = (NSApp.keyWindow?.windowController as? TerminalWindowController)?.focusedLocalPane
            ?? NSApp.windows.compactMap { ($0.windowController as? TerminalWindowController)?.focusedLocalPane }.first
        if let status = pane?.shellIntegrationStatus { return status }
        // No local pane: the shell a new window *would* launch, which is the honest answer to
        // "what is my shell doing" when there is nothing to point at.
        let shell = configStore.config.shell.flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return .current(shellPath: shell, mode: configStore.config.shellIntegration, marksSeen: false)
    }
```
`ShellCapabilities.shared` has been primed for both of those paths since launch (Task 2), so this
answers from the cache and never forks.
The window is a singleton kept in `settings`, so it can outlive the pane it described: `showWindow` already runs on every ⌘,, and `showShellPage()`/`refresh` both call `refreshShellPage()`, which re-asks the closure.

- [ ] **Step 7: The pictures**

In `Sources/NyxApp/UISnapshot.swift`, `writeSettings` gains a shell status and a page filter, mirroring `remotePageOnly`:

```swift
    private static func writeSettings(into directory: URL, appearance: NSAppearance.Name,
                                      suffix: String, remoteOn: Bool = true,
                                      remotePageOnly: Bool = false,
                                      shellPageOnly: Bool = false,
                                      shellStatus: ShellIntegrationStatus = fixtureShellStatus(.zsh, .auto, automatic: true, marksSeen: true)) {
```
with `controller.setShellStatusForSnapshot(shellStatus)` right after `controller.configChanged(...)`, and, in the per-page loop, `if shellPageOnly, label != "shell" { continue }` and `if !shellPageOnly, label == "shell" { continue }` — the Shell page is only ever written by the five dedicated calls below, so its picture never depends on the machine's own `$SHELL` or on which bash it happens to have.

```swift
    /// A `ShellIntegrationStatus` built for a picture rather than from this Mac. `automatic` and
    /// `limit` are stated outright rather than derived: `ShellIntegration.isAutomatic` would ask
    /// `ShellCapabilities`, which would probe whatever bash this machine has, and a picture that
    /// changes with the machine taking it is not a picture anyone can review.
    private static func fixtureShellStatus(_ shell: ShellKind, _ mode: ShellIntegrationMode,
                                           automatic: Bool, marksSeen: Bool,
                                           limit: ShellIntegrationLimit? = nil) -> ShellIntegrationStatus {
        ShellIntegrationStatus(
            shell: shell, mode: mode, isAutomatic: automatic, marksSeen: marksSeen, limit: limit,
            resources: URL(fileURLWithPath: "/Applications/Nyx.app/Contents/Resources/shell-integration"))
    }
```

and, beside the existing `writeSettings` calls, the five states — **five, not the spec §8.5 row's three.** `settings-shell-{automatic,manual,off}` was written before this wave found out which states exist: bash and fish became automatic, `waiting` is what every user sees on the first launch after an update, and `bash-3-2` is what the *majority* of Macs will show, since that is the bash Apple ships.

```swift
            for (state, status) in [
                ("automatic", fixtureShellStatus(.bash, .auto, automatic: true, marksSeen: true)),
                ("waiting", fixtureShellStatus(.bash, .auto, automatic: true, marksSeen: false)),
                ("bash-3-2", fixtureShellStatus(.bash, .auto, automatic: false, marksSeen: false,
                                                limit: .bashCannotBeReached(version: "3.2"))),
                ("unsupported", fixtureShellStatus(.other("ksh"), .auto, automatic: false, marksSeen: false)),
                ("off", fixtureShellStatus(.zsh, .off, automatic: false, marksSeen: false)),
            ] {
                writeSettings(into: directory, appearance: appearance,
                              suffix: "-\(state)-\(name)", shellPageOnly: true,
                              shellStatus: status)
            }
```
`name` is the `"light"`/`"dark"` string the surrounding appearance loop already carries. The loop
inside `writeSettings` writes `settings-\(label)\(suffix)` and `label` is already `shell`, so these
land as **`settings-shell-{automatic,waiting,bash-3-2,unsupported,off}-{light,dark}.png`**.

- [ ] **Step 8: Documentation**

`docs/configuration.md`:
- the `shell-integration` row becomes: `` `auto` injects the OSC 133 hooks for zsh (`ZDOTDIR`), bash (`--posix` + `ENV`) and fish (`XDG_DATA_DIRS`); `off` never touches the shell. Settings ▸ Shell shows what the current pane's shell is doing, and the line to paste for anything else. Applies to new tabs ``
- the environment row becomes: `` `NYX_SHELL_INTEGRATION_DIR`, `NYX_ZDOTDIR`, `NYX_XDG_DATA_DIRS`, `NYX_ENV` | the shell shims | Set by Nyx: where the scripts are, and the user's own `ZDOTDIR` / `XDG_DATA_DIRS` / `ENV`, which each shim puts back before the user's own configuration is read ``
- add a line under the table: `Nyx also sets `ENV` and passes `--posix` when it launches bash, and prepends its own directory to `XDG_DATA_DIRS` when it launches fish; both are handed back by the shim before your configuration runs.`

- [ ] **Step 9: Run everything**

Run: `swift build 2>&1 | grep -c warning:` → `0`; `swift test --no-parallel`; `scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/shots-shell ./build/Nyx.app/Contents/MacOS/Nyx`
Expected: ten new PNGs, `settings-shell-{automatic,waiting,bash-3-2,unsupported,off}-{light,dark}.png`. **Read all ten.** What is being checked: the sentence wraps rather than truncating at 460 pt — `bash-3-2`'s is the longest and is the one that will break first; the paste line is present in `bash-3-2` and `off` and absent in the other three; `Copy` sits on the field's centre line and does not overlap it; the pop-up reads `auto`/`off`; nothing is white-on-white in either appearance.

- [ ] **Step 10: Commit**

```bash
git add Sources/NyxApp/SettingsWindowController.swift Sources/NyxApp/AppDelegate.swift \
        Sources/NyxApp/TerminalWindowController.swift Sources/NyxApp/TabController.swift \
        Sources/NyxApp/Pane.swift \
        Sources/NyxApp/UISnapshot.swift Sources/NyxCore/Config/ConfigDiff.swift \
        Tests/NyxCoreTests/ConfigDiffTests.swift docs/configuration.md
git commit -m "$(cat <<'MSG'
A Shell page that says what this pane's marks are doing, and the line to paste

manualInstallCommand has had a doc comment promising a settings window since the
day it was written and no caller at all. It has one now: a page between Behaviour
and Keys carrying the shell-integration pop-up, one of four sentences about the
pane the user is looking at, and -- when nothing is being injected and we know the
shell -- the line to paste, monospaced, selectable, with Copy.

The pop-up writes a value only a new tab can act on, so ConfigDiff notes it and
the banner says so rather than the setting silently doing nothing.

Five pictures, not three: this wave found out which states exist -- live,
waiting, bash 3.2, a shell with no hooks, and off -- and bash 3.2 is the one the
majority of Macs will show.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP
MSG
)"
```

---

### Task 6: Saying it where it bites — the banner and the corrected refusal

**Files:**
- Create: `Sources/NyxApp/Announce.swift`
- Modify: `Sources/NyxApp/ConfigBanner.swift` (a note with a button of the caller's own)
- Modify: `Sources/NyxApp/TerminalWindowController.swift` (observe the notice, show the banner)
- Modify: `Sources/NyxApp/Pane.swift` (the notice, and `watchRefusedAlert(status:)`)
- Modify: `Sources/NyxApp/MenuSnapshot.swift` (two refusal pictures)
- Modify: `Sources/NyxApp/UISnapshot.swift` (`BannerKind.noMarks`)
- Modify: `docs/architecture.md`, `docs/status.md`, `README.md`
- Test: `Tests/NyxCoreTests/ShellIntegrationStatusTests.swift` is already the wording's test; no new Core type.

**Interfaces:**
- Consumes: `ShellIntegrationStatus`, `ShellIntegrationNotice` (Task 4); `Pane.shellPath`, `Pane.shellIntegrationStatus`, `TerminalWindowController.focusedPane` (Task 5); `AppDelegate.openShellSettings(_:)` (Task 5).
- Produces:
```swift
enum Announce { static func say(_ text: String) }
extension ConfigBanner {
    func showNote(_ text: String, actionTitle: String, action: @escaping () -> Void)
}
extension Pane {
    static let shellHasNoMarks: Notification.Name    // object: the Pane; userInfo["text"]: String
    static func watchRefusedAlert(status: ShellIntegrationStatus) -> NSAlert
}
```

- [ ] **Step 1: The announcement helper**

Create `Sources/NyxApp/Announce.swift`:

```swift
import AppKit

/// Says something out loud to VoiceOver.
///
/// Nothing in Nyx ever posted an accessibility notification: a command finishing, the palette's
/// selection, the search readout and every banner were all silent (`findings-a11y.md` 0.2). The
/// words always come from NyxCore -- `ShellIntegrationStatus`, `SearchSession.readout`,
/// `BlockHeader.summary` -- so what is announced and what is on the screen cannot differ.
///
/// (Wave 5b adds the remaining call sites listed in spec §8.1. If that plan lands first, keep its
/// version of this file and add nothing here.)
enum Announce {
    static func say(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
```

- [ ] **Step 2: A banner that can carry someone else's button**

In `Sources/NyxApp/ConfigBanner.swift`: make the action button a stored property, add the custom-action note, and reset the title on every other path.

```swift
    private let openButton = NSButton(title: "Edit Config", target: nil, action: nil)
    /// What the action button does when a caller supplied its own; nil restores "Edit Config".
    private var customAction: (() -> Void)?
```
(the button is built in `init` as before, with `target: self, action: #selector(openConfig)`), plus:

```swift
    /// A note whose button belongs to the caller -- the no-marks notice sends the user to
    /// Settings ▸ Shell, not to the config file, because the sentence it is carrying names a page.
    func showNote(_ text: String, actionTitle: String, action: @escaping () -> Void) {
        customAction = action
        openButton.title = actionTitle
        show(text: text, color: .systemBlue)
    }
```
and, at the top of `showProblems`, `showNote(_:)` and `showFailure`, `customAction = nil; openButton.title = "Edit Config"`, so a later config error does not inherit the shell button. `@objc private func openConfig()` becomes:
```swift
    @objc private func openConfig() {
        if let customAction { customAction() } else { onOpenConfig?() }
    }
```

- [ ] **Step 3: The pane raises the notice once**

In `Sources/NyxApp/Pane.swift`:

```swift
    /// A pane whose shell finished starting without marking a prompt. `object` is the pane, so the
    /// window it lives in can decide whether to say anything; `userInfo["text"]` is the sentence,
    /// which comes from NyxCore.
    static let shellHasNoMarks = Notification.Name("nyx.pane.shellHasNoMarks")

    /// Which shells have already been mentioned. Process-wide because that is what it describes:
    /// once per run of Nyx for a given shell, not once per tab (spec §4.3).
    private static var shellNotices = ShellIntegrationNotice()

    /// When this pane's shell was launched, so the notice rule can tell "no marks yet" from
    /// "no marks ever". Set in `init`; `CFAbsoluteTimeGetCurrent` because that is the clock the
    /// rest of the pane already measures command durations with.
    private var shellStartedAt: Double = 0
```
in `init`, after `session.start()`:
```swift
        shellStartedAt = CFAbsoluteTimeGetCurrent()
        // One shot, `ShellIntegrationNotice.graceSeconds` after the shell started, plus a tick:
        // the rule itself lives in NyxCore, and this timer only decides when to ask it.
        Timer.scheduledTimer(withTimeInterval: ShellIntegrationNotice.graceSeconds + 0.1,
                             repeats: false) { [weak self] _ in self?.reportShellIntegration() }
```
and:
```swift
    /// A remote pane is excluded by both guards falling out of `shellPath` being nil: its shell
    /// runs on another Mac, whose own copy of Nyx says this to its own user.
    private func reportShellIntegration() {
        guard let shellPath, let status = shellIntegrationStatus else { return }
        guard Pane.shellNotices.shouldTell(about: status, shellPath: shellPath,
                                           startedAt: shellStartedAt,
                                           now: CFAbsoluteTimeGetCurrent()),
              let text = status.bannerText else { return }
        NotificationCenter.default.post(name: Pane.shellHasNoMarks, object: self,
                                        userInfo: ["text": text])
    }
```

- [ ] **Step 4: The window shows it**

In `Sources/NyxApp/TerminalWindowController.swift`, beside `observeQuickActionFailures()`:

```swift
    /// The pane's own window says it, and only that window: the notification reaches every open
    /// one, and the same sentence in four windows is worse than useful.
    private func observeShellIntegrationNotices() {
        shellNotices = NotificationCenter.default.addObserver(
            forName: Pane.shellHasNoMarks, object: nil, queue: .main) { [weak self] note in
            guard let self, let pane = note.object as? Pane, pane.window === self.window,
                  let text = note.userInfo?["text"] as? String else { return }
            self.banner?.showNote(text, actionTitle: "Shell Settings\u{2026}") {
                NSApp.sendAction(#selector(AppDelegate.openShellSettings(_:)), to: nil, from: nil)
            }
            Announce.say(text)
        }
    }
```
with `private var shellNotices: Any?` stored and removed in `deinit` alongside `quickActionFailures`, and the call added where `observeQuickActionFailures()` is called.

- [ ] **Step 5: The corrected refusal**

In `Sources/NyxApp/Pane.swift`, replace `watchRefusedAlert()` and its caller:

```swift
    /// The refusal itself, built apart from being shown so `MenuSnapshot` can picture it: an alert
    /// nobody has looked at is a sentence nobody has read, and this one is three lines long.
    ///
    /// The words come from `ShellIntegrationStatus`, so this alert and the Shell page cannot drift.
    /// The old text said "Set shell-integration = auto and open a new tab" -- already the default,
    /// so a fish user followed it, was refused identically, and had no next move (PM §2).
    static func watchRefusedAlert(status: ShellIntegrationStatus) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ShellIntegrationStatus.watchRefusalMessage
        alert.informativeText = status.watchRefusalDetail
        alert.addButton(withTitle: "Shell Settings\u{2026}")   // the default: the one control that changes this
        alert.addButton(withTitle: "OK")
        return alert
    }

    private func reportWatchRefused() {
        // A remote pane cannot start a watch either, and has no local shell to name; the status of
        // the shell a new local tab would get is the nearest true sentence.
        let status = shellIntegrationStatus
            ?? .current(shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                        mode: config.shellIntegration, marksSeen: false)
        let alert = Pane.watchRefusedAlert(status: status)
        Announce.say(alert.messageText + " " + alert.informativeText)
        let openSettings: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSApp.sendAction(#selector(AppDelegate.openShellSettings(_:)), to: nil, from: nil)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: openSettings)
        } else {
            openSettings(alert.runModal())
        }
    }
```
(keep whatever the existing `else` branch does for a window-less pane; the point is that both paths now route the first button.)

- [ ] **Step 6: The pictures**

`Sources/NyxApp/MenuSnapshot.swift`, in `alerts(palette:)`, the one refusal becomes two — the two sentences differ, and only one of them had ever been written down:

```swift
            ("watch-refused",
             Pane.watchRefusedAlert(status: ShellIntegrationStatus(
                shell: .other("ksh"), mode: .auto, isAutomatic: false, marksSeen: false,
                resources: nil))),
            ("watch-refused-off",
             Pane.watchRefusedAlert(status: ShellIntegrationStatus(
                shell: .zsh, mode: .off, isAutomatic: false, marksSeen: false, resources: nil))),
            // The one most Mac users will meet, and the longest of the three sentences.
            ("watch-refused-bash-3-2",
             Pane.watchRefusedAlert(status: ShellIntegrationStatus(
                shell: .bash, mode: .auto, isAutomatic: false, marksSeen: false,
                limit: .bashCannotBeReached(version: "3.2"), resources: nil))),
```

`Sources/NyxApp/UISnapshot.swift`, `BannerKind` gains the case and the switch its arm:

```swift
    enum BannerKind: String, CaseIterable {
        case problems, note, failure
        case noMarks = "no-marks"
        case noMarksBash = "no-marks-bash"
    }
...
        case .noMarks:
            banner.showNote("Nyx could not add prompt marks to ksh \u{2014} blocks, folding and "
                            + "watches are off in this pane.",
                            actionTitle: "Shell Settings\u{2026}") {}
        case .noMarksBash:
            banner.showNote("Nyx cannot add prompt marks to bash 3.2 by itself \u{2014} paste the "
                            + "line from Settings \u{25B8} Shell into ~/.bashrc.",
                            actionTitle: "Shell Settings\u{2026}") {}
```
which writes `config-banner-no-marks-{light,dark}.png` and `config-banner-no-marks-bash-{light,dark}.png` through the existing loop. Both are pictured because they are different lengths against the same 900 pt strip, and the bash one is the sentence most Macs will show.

- [ ] **Step 7: Documentation**

- `docs/architecture.md`, the **Shell integration** paragraph: zsh through `ZDOTDIR` as today; bash through `--posix` + `ENV` at `bash/nyx-shim.bash`, which leaves POSIX mode, reads the user's own startup files in bash's order and then the hooks; fish through a Nyx directory prepended to `XDG_DATA_DIRS` carrying `fish/vendor_conf.d/nyx.fish`, which hands `XDG_DATA_DIRS` back before `config.fish`; `ShellIntegration.launch` decides argv and environment together; `ShellIntegrationStatus` owns the words the page, the banner and the alert use. Delete the sentence "bash and fish get a `source` line shown in the settings window" — the line is now only offered where nothing is injected.
- `docs/status.md`: the `Shell integration` row becomes `zsh (ZDOTDIR), bash (--posix + ENV) and fish (XDG_DATA_DIRS) injected automatically, nothing in $HOME modified; OSC 7 + 133 with exit status; Settings ▸ Shell says what a pane's shell is doing`. Delete the "bash / fish shell integration injected automatically" row from the not-done table.
- `README.md`, the **Shell integration, installed automatically** paragraph: name all three shells and the three mechanisms in one sentence each, keep "nothing in your home directory is modified" and `shell-integration = off`.

- [ ] **Step 8: Run everything**

Run: `swift build 2>&1 | grep -c warning:` → `0`; `swift test --no-parallel`; `scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/shots-w3 ./build/Nyx.app/Contents/MacOS/Nyx`
Expected: `config-banner-no-marks-{light,dark}.png`, `config-banner-no-marks-bash-{light,dark}.png`, `alert-watch-refused-{light,dark}.png` (re-taken, new words), `alert-watch-refused-off-{light,dark}.png` and `alert-watch-refused-bash-3-2-{light,dark}.png`. **Read all ten.** What is being checked: the banner's sentence is not truncated at 900 pt and `Shell Settings…` is legible on the blue fill in both appearances (`ConfigBanner.textColor(on:)` decides the ink — a white-on-blue title here is the Light-Mode bug coming back); the alert's informative text is three lines, not clipped, and `Shell Settings…` is the highlighted default.

- [ ] **Step 9: Commit**

```bash
git add Sources/NyxApp/Announce.swift Sources/NyxApp/ConfigBanner.swift \
        Sources/NyxApp/TerminalWindowController.swift Sources/NyxApp/Pane.swift \
        Sources/NyxApp/MenuSnapshot.swift Sources/NyxApp/UISnapshot.swift \
        docs/architecture.md docs/status.md README.md
git commit -m "$(cat <<'MSG'
The pane says its shell marks nothing, once, and the refusal has a next move

A shell that finishes starting without marking a prompt raises one banner in its
own window -- once per shell path for the life of the process, never written to
disk -- with a Shell Settings button, and it is announced, which is the first
accessibility notification this application has ever posted.

The watch refusal stops advising the user to set the value it already had. Both
sentences come from ShellIntegrationStatus, so the alert, the banner and the
settings page cannot say different things about the same pane.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP
MSG
)"
```

---

### Task 7: The ladder, the real shells in the built app, and every picture looked at

**Files:**
- Temporarily modify: `Sources/NyxApp/AppDelegate.swift` (a `NYX_SMOKE_QA=shell` hook, **removed before the commit**)
- Modify: nothing else. This task's output is evidence.

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: the verification report that closes the wave (`docs/workflow.md`).

- [ ] **Step 1: Rungs 1–3**

```bash
swift build 2>&1 | grep -c warning:            # 0
pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test
swift test --no-parallel                        # record the test count
make bench                                      # three times; ≥ 180 MB/s
```
Two binaries have to be there or the wave cannot be closed: `brew install fish` and `brew install bash` (a bash ≥ 4.4 — macOS's own 3.2.57 cannot take the automatic path at all, which is the point of the version gate). A live case reporting "skipped" is **not** a pass; say which ones skipped and why in the report.

- [ ] **Step 2: Add the rung-6 hook**

In `applicationDidFinishLaunching`, at the end:

```swift
        if ProcessInfo.processInfo.environment["NYX_SMOKE_QA"] == "shell" {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "(unset)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let pane = NSApp.windows.compactMap({
                    ($0.windowController as? TerminalWindowController)?.focusedPane }).first else {
                    print("SMOKE shell: no pane"); exit(1)
                }
                guard let status = pane.shellIntegrationStatus else {
                    print("SMOKE shell: remote pane, no local shell"); exit(1)
                }
                print("SMOKE shell=\(shell) automatic=\(status.isAutomatic) marks=\(status.marksSeen) "
                      + "argv=\(ProcessInfo.processInfo.arguments)")
                print("SMOKE limit=\(String(describing: status.limit))")
                print("SMOKE sentence=\(status.sentence)")
                print("SMOKE banner=\(status.bannerText ?? "(none)")")
                print("SMOKE manualLine=\(status.manualLine ?? "(none)")")
                pane.session.send(Array("printf 'one\\ntwo\\nthree\\n'; false\n".utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let (marks, region) = pane.session.withTerminal {
                        ($0.shellEmitsPromptMarks, $0.lastFinishedCommand)
                    }
                    print("SMOKE marks=\(marks) status=\(String(describing: region?.exitStatus)) "
                          + "output=\(String(describing: region?.outputRows))")
                    // The three things a bash or fish user has never had: a gutter mark, a fold,
                    // and Copy Output.
                    pane.tabController?.perform(.foldCommand)
                    pane.tabController?.perform(.copyCommandOutput)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        print("SMOKE clipboard=\(NSPasteboard.general.string(forType: .string) ?? "(empty)")")
                        exit(0)
                    }
                }
            }
        }
```
(If `session`, `tabController` or `focusedPane` are not reachable from here, add the narrowest accessor needed and delete it with the hook — `docs/testing.md` sanctions exactly that, and notes that needing one is a hint the decision belongs in NyxCore.)

- [ ] **Step 3: Run the hook against five shells — the real gate for this wave**

```bash
scripts/bundle.sh
SHELL=/opt/homebrew/bin/bash NYX_SMOKE_QA=shell ./build/Nyx.app/Contents/MacOS/Nyx   # bash >= 4.4: automatic
SHELL=/bin/bash              NYX_SMOKE_QA=shell ./build/Nyx.app/Contents/MacOS/Nyx   # bash 3.2: manual
SHELL=/opt/homebrew/bin/fish NYX_SMOKE_QA=shell ./build/Nyx.app/Contents/MacOS/Nyx
SHELL=/bin/ksh               NYX_SMOKE_QA=shell ./build/Nyx.app/Contents/MacOS/Nyx
NYX_CONFIG=/tmp/nyx-off-config SHELL=/bin/zsh NYX_SMOKE_QA=shell ./build/Nyx.app/Contents/MacOS/Nyx
```
(the last with a config file containing `shell-integration = off`).
Expected, and each one recorded in the task report:
- bash ≥ 4.4: `automatic=true`, `limit=nil`, `marks=true`, `status=Optional(1)`, a non-empty `output=`, `clipboard=one\ntwo\nthree`, `banner=(none)`, `manualLine=(none)`.
- fish: the same.
- **bash 3.2** (`/bin/bash`, the one every Mac has): `automatic=false`, `limit=Optional(bashCannotBeReached("3.2"))`, `marks=false`, the "Your shell is bash 3.2" sentence, the banner naming ~/.bashrc, and a `manualLine=` pointing inside the bundle. Then paste that exact line into a scratch `~/.bashrc`, open a new tab by hand, and confirm the marks appear and the banner does not come back — the manual path is the one most users will walk, and nothing else in the ladder walks it.
- ksh: `automatic=false`, `limit=nil`, `marks=false`, the "Your shell is ksh" sentence, and the banner naming ksh.
- off: `marks=false` and the "off by your setting" sentence and banner.
A bash ≥ 4.4 or fish run that prints `marks=false` is the failure this wave exists to prevent. A **`/bin/bash` run that prints `automatic=true`** is the other one: it means the version gate is not being consulted, and that shell has just been launched in POSIX mode with none of the user's startup files. A run where the shell prints a syntax error at startup is worse than both, and is a shim bug — read the window, not just the print.

- [ ] **Step 4: Remove the hook**

```bash
git diff --stat        # must show no change to AppDelegate.swift
```

- [ ] **Step 5: Rung 4 — every picture in this wave, looked at**

```bash
scripts/bundle.sh && NYX_UI_SNAPSHOT=/tmp/shots ./build/Nyx.app/Contents/MacOS/Nyx
```
Read, with `cmp` first to cut identical light/dark pairs:
- `settings-shell-{automatic,waiting,bash-3-2,unsupported,off}-{light,dark}.png` — the five sentences, the paste line present in `bash-3-2` and `off` and nowhere else, `Copy` beside the field, the page strip naming the page.
- `config-banner-no-marks-{light,dark}.png` and `config-banner-no-marks-bash-{light,dark}.png` — each sentence whole rather than truncated at 900 pt, `Shell Settings…` legible on blue in both appearances.
- `alert-watch-refused-{light,dark}.png`, `alert-watch-refused-off-{light,dark}.png` and `alert-watch-refused-bash-3-2-{light,dark}.png` — the corrected wording, `Shell Settings…` as the default button.
- `settings-{appearance,text,behaviour,keys,remote}-*` — unchanged except for the new tab in the strip; `cmp` against the previous run to prove the other pages did not move.

- [ ] **Step 6: The gates**

- `design-reviewer` over the eight settings pictures, the banner and the two alerts.
- A VoiceOver pass on the Shell page (the sentence and the paste field must be read out, and the `Copy` button reached with ⇥) and on the banner's announcement, per spec §8.1.
- `product-manager` last: the wave is not done until he says so.

- [ ] **Step 7: Commit the evidence**

Nothing but the report changes here; if the ladder found nothing, this task commits nothing and the wave ends at Task 6's commit. If it found something, fix it in a commit of its own naming the rung that caught it:

```bash
git commit -m "$(cat <<'MSG'
<what the ladder found, in one sentence>

Rung 6 with SHELL=<shell>: <what was printed, and what it should have been>.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01WjDoxfQwvuQVRRjWXbzavP
MSG
)"
```

---

## Self-review

**1. Spec coverage.**

| spec | task |
|---|---|
| §4.1 fish through `XDG_DATA_DIRS` + `fish/vendor_conf.d/nyx.fish`, original in `NYX_XDG_DATA_DIRS` | 1 (rule), 3 (scripts) |
| §4.1 bash through `--posix` + `ENV`, not `--rcfile` | 1 (rule + the ≥ 4.4 gate), 2 (shim + marks) |
| §4.1 "if anything is missing, return the environment unchanged" | 1 (`aMissingBashShimLeavesBothHalvesUntouched`, `aMissingFishSnippetLeavesTheEnvironmentUntouched`, `anUnprimedBashIsNotPutIntoPosixMode`) |
| §4.1 `isAutomatic` true for zsh/bash/fish, `.other` keeps `manualInstallCommand`'s line | 1 — **amended:** bash < 4.4 is not automatic and keeps the line too, because the mechanism §4.1 chose does not exist on it |
| §4.2 Shell page between Behaviour and Keys, the pop-up | 5 |
| §4.2 `ShellIntegrationStatus` with `shell`/`mode`/`isAutomatic`/`marksSeen`/`sentence`/`manualLine`, `ShellKind.name` | 4 (+ `name` in 1) |
| §4.2 the four sentences verbatim, and a fifth for bash < 4.4 | 4 |
| §4.2 the manual line, its caption, the monospaced selectable field, `Copy` — `manualInstallCommand`'s first caller | 5 |
| §4.3 the one-time banner, per shell path, for the life of the process, `Shell Settings…` + `✕` | 4 (rule), 6 (chrome) |
| §4.3 the corrected "Cannot watch" alert, all three variants, `Shell Settings…` default | 4 (words), 6 (alert) |
| §8.1 wording in Core; the banner announced | 4, 6 (`Announce`) |
| §8.5 plan-3 pictures: the Shell page, the banner, the alert | 5, 6 |
| §10 Core tests: `environment` for bash and fish, with and without `XDG_DATA_DIRS`, missing resources, `isAutomatic`, `manualInstallCommand`, the sentences | 1, 4 |
| §10 rung 6: the built app with a real bash, a real fish, then `off` and `/bin/ksh` | 7 (five shells, not four: `/bin/bash` and a ≥ 4.4 bash are different products now) |
| Coverage appendix, `findings-pm.md` §2 (zero callers, the wrong advice) | 5, 6 |

Four deliberate departures from the spec's letter, each recorded where it is made and each forced by something the spec could not have known:

1. **bash < 4.4 is not automatic.** §4.1 chose `--posix` + `ENV`; driven over a PTY, macOS's bash 3.2.57 reports `posix on` and reads `~/.bash_profile` anyway, never `$ENV`. Following §4.1 literally would put the default shell of every Mac into POSIX mode with **no** startup files and no marks. The mechanism stays for bash ≥ 4.4, the version is probed once per path, and 3.2 becomes the manual-install case — which is also what makes `manualInstallCommand` the load-bearing feature it was written to be, rather than a fallback nobody reaches.
2. **Five settings pictures, not §8.5's three.** The states changed with §4.1 and with departure 1.
3. **`marksSeen` is asked before everything else** in `sentence`: a bash 3.2 user who pasted the line has live marks, and every other sentence would be a lie about their own screen.
4. **The banner has three forms, not one.** §4.3's sentence is kept exactly for the shells it describes, and fires for an automatic shell whose marks never came — deliberately, because that is the only way it can ever fire for zsh, fish or a modern bash. `shell-integration = off` and bash 3.2 get their own, because "could not add" is false about a setting the user chose and useless without a next move.

**2. Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N". Every script is written out in full; every test body is code. The one place that says "keep whatever the existing `else` branch does" (Task 6, Step 5) points at code already in the file and names what must be true of it.

**3. Type consistency.** `ShellLaunch.environment`/`.arguments`; `ShellIntegration.launch(_:arguments:shellPath:mode:resources:capabilities:pathExists:)`, `.environment(...)` with the same tail, `.isAutomatic(shellPath:mode:capabilities:)`, `.bashENVStartupVersion`, `.originalENV`/`.originalXDGDataDirs`/`.originalZDotDir`/`.resourceDirectory`/`.defaultXDGDataDirs`; `ShellKind.name`; `ShellCapabilities.shared`/`init(probe:)`/`prime(shellPath:)`/`bashSupportsENVStartup(shellPath:)`/`bashVersion(shellPath:)`/`runVersionProbe(_:)`; `ShellIntegrationLimit.bashCannotBeReached(version:)`/`.shellDescription`; `ShellIntegrationStatus.current(shellPath:mode:marksSeen:resources:capabilities:)`, `.sentence`, `.manualLine`, `.manualCaption`, `.bannerText`, `.watchRefusalMessage`, `.watchRefusalDetail`, `.limit`; `ShellIntegrationNotice.shouldTell(about:shellPath:startedAt:now:)`/`.graceSeconds`; `Pane.shellPath: String?`, `Pane.shellIntegrationStatus: ShellIntegrationStatus?`, `Pane.shellHasNoMarks`, `Pane.watchRefusedAlert(status:)`; `TerminalWindowController.focusedPane`/`focusedLocalPane`; `TabController.everyPane`; `ConfigBanner.showNote(_:actionTitle:action:)`; `Announce.say(_:)`; `AppDelegate.openShellSettings(_:)`; `SettingsWindowController.shellStatus`/`showShellPage()`/`setShellStatusForSnapshot(_:)`; `ConfigDiff.shellIntegrationChanged`. Each is defined in exactly one task and spelled the same way in every later one. Two renames happen in Task 1 and move with their call sites: `directoryExists:` → `pathExists:`, and `isAutomatic`/`launch`/`environment` gain a defaulted `capabilities:`, so every existing caller still compiles.
