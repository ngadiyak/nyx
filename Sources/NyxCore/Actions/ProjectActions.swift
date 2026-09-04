import Foundation

/// Quick actions a project defines for itself, in a `.nyx` file at its root.
///
/// A repository knows its own commands far better than a global config does -- `make test`,
/// `docker compose up`, whatever this particular project needs -- and having those appear as
/// buttons when you `cd` into it is most of the value of having buttons at all.
///
/// **This executes commands a file in a directory asked for, so it is opt-in per directory.**
/// Cloning a repository must never be enough to put someone else's command behind a button in your
/// terminal. A project's actions appear only after the directory has been approved, the same
/// bargain direnv makes, and approval is recorded against the file's contents: editing the file --
/// or a `git pull` bringing in an edit -- revokes it until you look again.
public struct ProjectActions: Equatable {
    public let actions: [QuickAction]
    /// The digest the approval is recorded against.
    public let digest: String

    public init(actions: [QuickAction], digest: String) {
        self.actions = actions
        self.digest = digest
    }
}

public enum ProjectActionsFile {
    /// The file a project puts its actions in.
    public static let name = ".nyx"

    /// Parses a project file. The format is the `quick` lines of the main config and nothing else:
    /// a project may add buttons, and may not change a setting, open a font, or rebind a key.
    ///
    /// Anything else in the file is ignored rather than rejected, so a future format can add to it
    /// without every older Nyx refusing to read the file.
    public static func parse(_ text: String) -> ProjectActions {
        var actions: [QuickAction] = []
        for rawLine in ConfigGrammar.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "quick" else { continue }
            let value = ConfigGrammar.value(after: line[line.index(after: eq)...], stripComments: false)
            if let action = QuickAction.parse(value) { actions.append(action) }
        }
        return ProjectActions(actions: actions, digest: digest(of: text))
    }

    /// A content digest, so approving a project's actions approves *those* actions.
    ///
    /// Not a cryptographic hash and not trying to be: this defends against a file changing under
    /// the user between one look and the next, not against someone crafting a collision -- anyone
    /// who can write the file can simply put their command in it and wait to be approved.
    public static func digest(of text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// Which project directories the user has approved, and for which contents.
///
/// Kept as a value with explicit load and save so the decision logic can be tested without touching
/// the filesystem -- the part worth getting right is *when* something counts as approved.
public struct ProjectApprovals: Equatable {
    /// Directory path to the digest that was approved there.
    private var approved: [String: String]

    public init(_ approved: [String: String] = [:]) {
        // Normalised on the way in as well as on every lookup, so a file written by hand with a
        // trailing slash still matches the directory the shell reports.
        self.approved = [:]
        for (directory, digest) in approved { self.approved[Self.normalised(directory)] = digest }
    }

    /// Whether this exact content is approved for this directory.
    public func isApproved(directory: String, digest: String) -> Bool {
        approved[normalise(directory)] == digest
    }

    /// Whether the directory was approved before, for content that has since changed. The caller
    /// asks differently in this case: "this project's actions changed" rather than "this project
    /// wants to add actions".
    public func wasApprovedForDifferentContent(directory: String, digest: String) -> Bool {
        guard let known = approved[normalise(directory)] else { return false }
        return known != digest
    }

    public mutating func approve(directory: String, digest: String) {
        approved[normalise(directory)] = digest
    }

    public mutating func revoke(directory: String) {
        approved[normalise(directory)] = nil
    }

    public var directories: [String] { approved.keys.sorted() }

    /// The stored form: one `<digest> <directory>` line each, so it can be read and edited by
    /// hand. The digest comes first because a directory may contain spaces and a digest may not.
    public func serialised() -> String {
        var out = "# Project directories whose .nyx actions you approved, and the contents you saw.\n"
        out += "# Delete a line to be asked again next time you are in that directory.\n"
        for directory in directories {
            guard let digest = approved[directory] else { continue }
            out += "\(digest) \(directory)\n"
        }
        return out
    }

    public static func parse(_ text: String) -> ProjectApprovals {
        var approvals: [String: String] = [:]
        for rawLine in ConfigGrammar.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let space = line.firstIndex(of: " ") else { continue }
            let digest = String(line[line.startIndex..<space])
            let directory = String(line[line.index(after: space)...])
            guard !digest.isEmpty, !directory.isEmpty else { continue }
            approvals[directory] = digest
        }
        return ProjectApprovals(approvals)
    }

    /// A trailing slash is the same directory, and `cd` reports it either way depending on how the
    /// user typed it -- approving `/a/b` and then being asked again for `/a/b/` would look broken.
    private func normalise(_ directory: String) -> String { Self.normalised(directory) }

    private static func normalised(_ directory: String) -> String {
        var path = directory
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// What a directory's `.nyx` file may do right now.
///
/// The whole security boundary lives in this type. Only `.approved` carries actions that may run,
/// appear as a button or reach the palette; `.changed` and `.unseen` carry theirs as something to
/// *show* a user who has not agreed to them yet, and there is no accessor that hands those to a
/// runner. Cloning a repository puts a file on disk and nothing else.
public enum ProjectActionsState: Equatable {
    /// No `.nyx` here, or one that defines nothing worth offering.
    case none
    /// Approved for exactly this content.
    case approved(actions: [QuickAction], digest: String)
    /// This directory was approved before, for content that has since changed -- an edit, or a
    /// `git pull` that brought one in. The user is told that, not asked afresh: "these changed" is
    /// a different question from "this project wants to add actions".
    case changed(pending: ProjectActions)
    /// Never approved here.
    case unseen(pending: ProjectActions)

    /// The actions that may actually run. Empty for every state but `.approved`.
    ///
    /// One accessor, so "is this allowed to run" has exactly one answer and a caller cannot reach
    /// past it to the pending list by accident.
    public var runnableActions: [QuickAction] {
        guard case .approved(let actions, _) = self else { return [] }
        return actions
    }

    /// The actions to show the user for review, approved or not. Showing is not running.
    public var actionsToShow: [QuickAction] {
        switch self {
        case .none: return []
        case .approved(let actions, _): return actions
        case .changed(let pending), .unseen(let pending): return pending.actions
        }
    }

    /// The digest the user would be approving.
    public var digest: String? {
        switch self {
        case .none: return nil
        case .approved(_, let digest): return digest
        case .changed(let pending), .unseen(let pending): return pending.digest
        }
    }

    /// Whether the user has to be asked something before any of this can be used.
    public var needsApproval: Bool {
        switch self {
        case .changed, .unseen: return true
        case .none, .approved: return false
        }
    }
}

/// Deciding what a directory's project file is allowed to do, and what to say about it.
public enum ProjectActionsGate {
    /// The state of `directory`, given the `.nyx` file found there (nil when there is none) and
    /// what the user has approved.
    ///
    /// A file that parses to no actions is `.none`: a bar offering to approve a list of nothing is
    /// noise, and approving it would grant nothing. Note that this is decided *before* the
    /// approval check, so an empty file cannot be used to get a bar in front of somebody.
    public static func state(directory: String, fileContents: String?,
                             approvals: ProjectApprovals) -> ProjectActionsState {
        guard let fileContents else { return .none }
        let project = ProjectActionsFile.parse(fileContents)
        guard !project.actions.isEmpty else { return .none }

        if approvals.isApproved(directory: directory, digest: project.digest) {
            return .approved(actions: project.actions, digest: project.digest)
        }
        if approvals.wasApprovedForDifferentContent(directory: directory, digest: project.digest) {
            return .changed(pending: project)
        }
        return .unseen(pending: project)
    }

    /// What the bar says. Names the directory, because a pane's working directory is not always
    /// what the user thinks it is -- and because "some project wants to run things" is not a
    /// question anybody can answer.
    public static func barMessage(for state: ProjectActionsState, directory: String) -> String? {
        let name = displayName(of: directory)
        switch state {
        case .none, .approved:
            return nil
        case .changed(let pending):
            return "\(name) changed its actions (\(pending.actions.count)). "
                + "They will not run until you look at them again."
        case .unseen(let pending):
            return "\(name) defines \(pending.actions.count) "
                + "\(pending.actions.count == 1 ? "action" : "actions") for this terminal."
        }
    }

    /// The commands themselves, one per line, for the review sheet.
    ///
    /// The user is shown what will actually run before they approve it. A name alone would be worse
    /// than useless: a button called "Test" that runs `curl … | sh` is exactly the thing approval
    /// exists to stop, and the name is chosen by the same file as the command.
    public static func reviewText(_ actions: [QuickAction]) -> String {
        actions.map { "\($0.name)  [\($0.kind.rawValue)]\n    \($0.command)" }
            .joined(separator: "\n\n")
    }

    /// The last path component, or the path itself when that says nothing useful.
    public static func displayName(of directory: String) -> String {
        var path = directory
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.isEmpty ? path : last
    }
}

public extension ProjectApprovals {
    /// The record of what has been approved, kept beside the config file so `$NYX_CONFIG` moves
    /// both together -- a user who points Nyx at another config directory is setting up another
    /// Nyx, and would not expect it to inherit these.
    static let fileName = "approved-projects"

    static func path(besideConfigAt config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent(fileName)
    }
}
