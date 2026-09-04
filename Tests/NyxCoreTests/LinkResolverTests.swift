import Testing
@testable import NyxCore

private let home = "/Users/tester"
private let cwd = "/Users/tester/project"

/// A made-up disk: only these paths exist.
private let onDisk: Set<String> = [
    "/Users/tester/project/src/main.swift",
    "/Users/tester/project/README.md",
    "/Users/tester/notes.txt",
    "/etc/hosts",
]

private func resolve(_ token: TextToken, workingDirectory: String? = cwd) -> LinkTarget? {
    LinkResolver.target(for: token, home: home, workingDirectory: { workingDirectory },
                        fileExists: { onDisk.contains($0) })
}

private func token(_ text: String, _ kind: TokenKind) -> TextToken {
    TextToken(columns: 0..<text.count, text: text, kind: kind)
}

// MARK: - URLs

@Test func aUrlOpensAsItself() {
    #expect(resolve(token("https://example.com/a", .url)) == .url("https://example.com/a"))
}

/// Without the scheme the system has no idea a mail client is wanted, and refuses the address.
@Test func anEmailAddressBecomesAMailtoUrl() {
    #expect(resolve(token("nik@example.com", .email)) == .url("mailto:nik@example.com"))
}

@Test func anAddressThatAlreadyHasTheSchemeDoesNotGetASecondOne() {
    #expect(resolve(token("mailto:nik@example.com", .email)) == .url("mailto:nik@example.com"))
}

// MARK: - Paths

@Test func aRelativePathResolvesAgainstTheWorkingDirectory() {
    let target = resolve(token("src/main.swift", .path(line: nil, column: nil)))
    #expect(target == .file(path: "/Users/tester/project/src/main.swift", line: nil, column: nil))
}

@Test func anAbsolutePathIsUsedAsItIs() {
    #expect(resolve(token("/etc/hosts", .path(line: nil, column: nil)))
        == .file(path: "/etc/hosts", line: nil, column: nil))
}

@Test func aHomeRelativePathIsExpanded() {
    #expect(resolve(token("~/notes.txt", .path(line: nil, column: nil)))
        == .file(path: "/Users/tester/notes.txt", line: nil, column: nil))
}

@Test func aDotSlashPathIsStandardised() {
    #expect(resolve(token("./README.md", .path(line: nil, column: nil)))
        == .file(path: "/Users/tester/project/README.md", line: nil, column: nil))
}

/// The whole point of the compiler-style suffix: the position travels with the file.
@Test func theLineAndColumnComeThroughAndLeaveThePathClean() {
    let target = resolve(token("src/main.swift:12:5", .path(line: 12, column: 5)))
    #expect(target == .file(path: "/Users/tester/project/src/main.swift", line: 12, column: 5))
}

@Test func aLineWithNoColumnIsAlsoStripped() {
    let target = resolve(token("src/main.swift:12", .path(line: 12, column: nil)))
    #expect(target == .file(path: "/Users/tester/project/src/main.swift", line: 12, column: nil))
}

/// Terminal output is full of path-shaped text that is not a file -- diff headers, log lines, half
/// a traceback. Underlining those trains a user to distrust the underline.
@Test func aPathThatIsNotOnDiskIsNotALink() {
    #expect(resolve(token("src/nope.swift", .path(line: nil, column: nil))) == nil)
    #expect(resolve(token("a/b/c", .path(line: nil, column: nil))) == nil)
}

/// Guessing at `$HOME` would open the wrong file; refusing is the honest answer.
@Test func aRelativePathWithNoWorkingDirectoryIsNotALink() {
    #expect(resolve(token("src/main.swift", .path(line: nil, column: nil)), workingDirectory: nil) == nil)
}

@Test func thingsWithNothingToOpenAreNotLinks() {
    #expect(resolve(token("deadbeef1", .commitHash)) == nil)
    #expect(resolve(token("10.0.0.1", .ipAddress)) == nil)
    #expect(resolve(token("hello", .word)) == nil)
}

// MARK: - open-file-command

@Test func theTemplateIsSplitAndSubstituted() {
    let argv = OpenFileCommand.arguments(template: "code -g {file}:{line}",
                                         path: "/tmp/a.swift", line: 12, column: nil)
    #expect(argv == ["code", "-g", "/tmp/a.swift:12"])
}

@Test func theColumnIsSubstitutedWhenTheTemplateAsksForIt() {
    let argv = OpenFileCommand.arguments(template: "code -g {file}:{line}:{column}",
                                         path: "/tmp/a.swift", line: 12, column: 5)
    #expect(argv == ["code", "-g", "/tmp/a.swift:12:5"])
}

/// A path opened with a dangling colon glued to it is the most familiar version of this bug.
@Test func anAbsentLineLeavesNoDanglingPunctuation() {
    let argv = OpenFileCommand.arguments(template: "code -g {file}:{line}:{column}",
                                         path: "/tmp/a.swift", line: nil, column: nil)
    #expect(argv == ["code", "-g", "/tmp/a.swift"])
}

@Test func anAbsentColumnCollapsesTheSecondColon() {
    let argv = OpenFileCommand.arguments(template: "e {file}:{line}:{column}",
                                         path: "/tmp/a.swift", line: 7, column: nil)
    #expect(argv == ["e", "/tmp/a.swift:7"])
}

@Test func quotedWordsSurviveWithTheirSpaces() {
    let argv = OpenFileCommand.arguments(template: "\"/Applications/My Editor\" --wait {file}",
                                         path: "/tmp/a.swift", line: nil, column: nil)
    #expect(argv == ["/Applications/My Editor", "--wait", "/tmp/a.swift"])
}

@Test func aPathWithASpaceStaysOneArgument() {
    let argv = OpenFileCommand.arguments(template: "open {file}", path: "/tmp/my file.txt",
                                         line: nil, column: nil)
    #expect(argv == ["open", "/tmp/my file.txt"])
}

@Test func anEmptyTemplateRunsNothing() {
    #expect(OpenFileCommand.arguments(template: "   ", path: "/tmp/a", line: nil, column: nil) == nil)
}

/// An argument that was nothing but an absent placeholder is dropped rather than passed as "".
@Test func anArgumentThatSubstitutesAwayEntirelyIsDropped() {
    let argv = OpenFileCommand.arguments(template: "vim +{line} {file}", path: "/tmp/a",
                                         line: nil, column: nil)
    #expect(argv == ["vim", "+", "/tmp/a"])
}

// MARK: - Which schemes may be opened

private func urlToken(_ text: String) -> TextToken {
    TextToken(columns: 0..<text.count, text: text, kind: .url)
}

private func resolve(_ text: String, exists: @escaping (String) -> Bool = { _ in false }) -> LinkTarget? {
    LinkResolver.target(for: urlToken(text), home: "/Users/nik",
                        workingDirectory: { "/Users/nik/projects/nyx" }, fileExists: exists)
}

@Test func ordinaryWebLinksOpen() {
    #expect(resolve("https://example.com") == .url("https://example.com"))
    #expect(resolve("http://example.com/a?b=1") != nil)
    #expect(resolve("ssh://box.local") != nil)
}

/// A terminal shows whatever a program chose to print. `file://` naming an application bundle
/// would turn a line of output into a one-click launch, so it goes through the same "must exist"
/// rule as any other path rather than straight to the system opener.
@Test func aFileUrlIsTreatedAsThePathItIs() {
    #expect(resolve("file:///Users/nik/notes.txt") == nil)      // does not exist: not a link
    #expect(resolve("file:///Users/nik/notes.txt", exists: { $0 == "/Users/nik/notes.txt" })
            == .file(path: "/Users/nik/notes.txt", line: nil, column: nil))
}

@Test func aPercentEncodedFileUrlResolvesToTheRealPath() {
    let target = resolve("file:///Users/nik/My%20Files/a.txt",
                         exists: { $0 == "/Users/nik/My Files/a.txt" })
    #expect(target == .file(path: "/Users/nik/My Files/a.txt", line: nil, column: nil))
}

/// Any application on the machine can register a scheme. Output from a program should not be able
/// to reach one of them just by printing it.
@Test func anUnknownSchemeIsTextRatherThanALink() {
    #expect(resolve("x-unknown-app://do-something") == nil)
    #expect(resolve("javascript:alert(1)") == nil)
    #expect(resolve("vnc://box.local") == nil)
}
