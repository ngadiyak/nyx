import Foundation
import Testing
@testable import NyxCore

private let resources = URL(fileURLWithPath: "/Applications/Nyx.app/Contents/Resources/shell-integration")
private let allExist: (URL) -> Bool = { _ in true }
private let noneExist: (URL) -> Bool = { _ in false }

private func env(_ base: [String: String] = [:], shell: String = "/bin/zsh",
                 mode: ShellIntegrationMode = .auto, resources: URL? = resources,
                 exists: @escaping (URL) -> Bool = allExist) -> [String: String] {
    ShellIntegration.environment(base, shellPath: shell, mode: mode, resources: resources,
                                 directoryExists: exists)
}

// MARK: - Detection

@Test func theShellIsIdentifiedByItsExecutableName() {
    #expect(ShellKind.detect(shellPath: "/bin/zsh") == .zsh)
    #expect(ShellKind.detect(shellPath: "/opt/homebrew/bin/zsh") == .zsh)
    #expect(ShellKind.detect(shellPath: "/bin/bash") == .bash)
    #expect(ShellKind.detect(shellPath: "/opt/homebrew/bin/fish") == .fish)
    #expect(ShellKind.detect(shellPath: "/usr/local/bin/nu") == .other("nu"))
}

// MARK: - Injecting into zsh

@Test func zshGetsItsZDotDirPointedAtTheShim() {
    let e = env()
    #expect(e["ZDOTDIR"] == resources.appendingPathComponent("zsh").path)
    #expect(e[ShellIntegration.resourceDirectory] == resources.path)
}

/// The user's own `ZDOTDIR` has to survive, or their configuration is simply not read. It travels
/// separately so the shim can source their files and then put the variable back.
@Test func anExistingZDotDirIsCarriedThroughRatherThanLost() {
    let e = env(["ZDOTDIR": "/Users/someone/.config/zsh"])
    #expect(e[ShellIntegration.originalZDotDir] == "/Users/someone/.config/zsh")
    #expect(e["ZDOTDIR"] != "/Users/someone/.config/zsh")
}

@Test func noExistingZDotDirMeansNothingToCarry() {
    #expect(env()[ShellIntegration.originalZDotDir] == nil)
}

/// An empty value is not a directory anyone meant to set, and passing it on would make the shim
/// source files out of `""`.
@Test func anEmptyZDotDirIsTreatedAsUnset() {
    #expect(env(["ZDOTDIR": ""])[ShellIntegration.originalZDotDir] == nil)
}

@Test func everythingElseInTheEnvironmentIsLeftAlone() {
    let e = env(["PATH": "/usr/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"])
    #expect(e["PATH"] == "/usr/bin")
    #expect(e["TERM"] == "xterm-256color")
    #expect(e["LANG"] == "en_US.UTF-8")
}

// MARK: - Refusing to inject

@Test func turningItOffChangesNothingAtAll() {
    let base = ["ZDOTDIR": "/Users/someone/.config/zsh", "PATH": "/usr/bin"]
    #expect(env(base, mode: .off) == base)
}

/// A terminal that will not start a shell because it could not find its own helper file is a far
/// worse bug than one without prompt marks, so a missing shim is not fatal.
@Test func missingShimFilesLeaveTheEnvironmentUntouched() {
    #expect(env(["PATH": "/usr/bin"], exists: noneExist) == ["PATH": "/usr/bin"])
}

@Test func aMissingResourceDirectoryLeavesTheEnvironmentUntouched() {
    #expect(env(["PATH": "/usr/bin"], resources: nil) == ["PATH": "/usr/bin"])
}

/// bash and fish have no shim that can be relied on to run, so their `ZDOTDIR` -- which means
/// nothing to them anyway -- is not touched. They are only told where the scripts live.
@Test func shellsWithNoShimAreToldWhereTheScriptsAreAndNothingMore() {
    for shell in ["/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/nu"] {
        let e = env(["PATH": "/usr/bin"], shell: shell)
        #expect(e["ZDOTDIR"] == nil, "\(shell)")
        #expect(e[ShellIntegration.resourceDirectory] == resources.path, "\(shell)")
        #expect(e["PATH"] == "/usr/bin", "\(shell)")
    }
}

// MARK: - What to tell the user

@Test func onlyZshIsAutomatic() {
    #expect(ShellIntegration.isAutomatic(shellPath: "/bin/zsh", mode: .auto))
    #expect(!ShellIntegration.isAutomatic(shellPath: "/bin/bash", mode: .auto))
    #expect(!ShellIntegration.isAutomatic(shellPath: "/bin/zsh", mode: .off))
}

/// The settings window shows this line, so it has to name a file that is actually shipped.
@Test func theManualCommandNamesAFileTheBundleShips() {
    let bundled = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/shell-integration")
    for shell in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"] {
        let command = try! #require(ShellIntegration.manualInstallCommand(shellPath: shell,
                                                                          resources: bundled))
        // `source "<path>"` -- take the quoted path back out and check it exists in the repo.
        let path = command.split(separator: "\"").dropFirst().first.map(String.init)
        let file = try! #require(path)
        #expect(FileManager.default.fileExists(atPath: file), "\(shell) points at missing \(file)")
    }
}

@Test func aShellWeKnowNothingAboutGetsNoAdvice() {
    #expect(ShellIntegration.manualInstallCommand(shellPath: "/usr/local/bin/nu",
                                                  resources: resources) == nil)
}
