import Foundation
import NyxCore

/// The file recording which project directories the user approved, and for which contents.
///
/// Read fresh whenever a directory is looked up rather than cached for the life of the app: the
/// file is meant to be editable by hand (deleting a line is how you revoke), and a cache would go
/// on offering buttons from a project whose approval the user had just taken away. Looking at a
/// directory happens when you `cd`, not sixty times a second.
final class ProjectApprovalsStore {
    static let shared = ProjectApprovalsStore()

    /// Beside the config file, so `$NYX_CONFIG` moves both together.
    static var path: URL { ProjectApprovals.path(besideConfigAt: ConfigStore.path) }

    private init() {}

    func load() -> ProjectApprovals {
        guard let text = try? String(contentsOf: ProjectApprovalsStore.path, encoding: .utf8) else {
            return ProjectApprovals()
        }
        return ProjectApprovals.parse(text)
    }

    /// Records an approval. A failure to write is reported so the caller can say so: silently
    /// failing would mean the user is asked again next time with no explanation.
    @discardableResult
    func approve(directory: String, digest: String) -> Bool {
        var approvals = load()
        approvals.approve(directory: directory, digest: digest)
        return write(approvals)
    }

    @discardableResult
    private func write(_ approvals: ProjectApprovals) -> Bool {
        let url = ProjectApprovalsStore.path
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try approvals.serialised().write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// The `.nyx` file in a directory, or nil when there is none.
    ///
    /// Reads a plain file only: a symlink out of the project, a directory named `.nyx`, or a
    /// device would each be a way to make Nyx read something the project does not contain.
    func projectFile(in directory: String) -> String? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(ProjectActionsFile.name)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        // A project file is a handful of lines. Anything enormous is not one, and reading it would
        // be the first thing a hostile file could cost us.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ProjectApprovalsStore.maximumProjectFileBytes else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let maximumProjectFileBytes = 64 * 1024
}
