import Foundation
import NyxCore

/// The `~/.config/nyx/requests` file: one per application, read at launch and rewritten whenever a
/// request is run.
///
/// All the rules about the list itself -- dedup, order, the limit, the file's text -- live in
/// `RequestHistory`, which is a value type with tests. What is left here is a file and a queue:
///
/// - The model is read and mutated on the main thread only. Every caller (the pane finishing a
///   block, the palette building its rows, the palette running one) is already on it, so there is
///   no lock and no chance of a row's index addressing a list that has since changed underneath it.
/// - The write goes to a serial queue, because writing a file must not be on the path that draws a
///   frame, and because two writes racing would let the older list win.
/// - The file is written to a temporary name and renamed over the old one. A crash mid-write then
///   loses the *new* request rather than the previous fifty, and no reader ever sees half a file.
/// - Mode 0600: a curl line can carry a bearer token or a password in the URL. The default 0644
///   would put credentials in a file every process on the machine can read.
final class RequestHistoryStore {
    private let url: URL
    private var history: RequestHistory
    private static let queue = DispatchQueue(label: "nyx.request-history", qos: .utility)

    /// The file beside the config, under the built-in limit. Task 8 replaces `defaultLimit` with
    /// the `http_history` config key.
    static func standard(limit: Int = RequestHistory.defaultLimit) -> RequestHistoryStore {
        RequestHistoryStore(url: RequestHistoryPath.resolve(
            environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory()), limit: limit)
    }

    init(url: URL, limit: Int) {
        self.url = url
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        history = RequestHistory.parse(text, limit: limit)
    }

    /// Newest first, the way the palette shows them.
    var entries: [RequestHistory.Entry] { history.entries }

    /// The palette's Requests section. Masked: these rows are the surface a screenshot catches.
    func paletteItems(now: Date = Date()) -> [PaletteItem] {
        history.paletteItems(now: now)
    }

    /// The real, unmasked line behind a `.request(index:)` row -- what an editor opens on and what
    /// gets run. nil when the list changed since the row was built, which is why the caller is made
    /// to ask rather than being handed the line inside the row.
    func line(at index: Int) -> String? {
        history.entries.indices.contains(index) ? history.entries[index].line : nil
    }

    /// Remembers a request and rewrites the file. A line that is not a curl, or a duplicate of the
    /// top entry that would rewrite the file to the same bytes, does not touch the disk at all --
    /// every finished block on screen reaches here, and almost none of them are requests.
    func record(_ line: String, at: Date = Date()) {
        let before = history
        history.record(line, at: at)
        guard history != before else { return }
        let text = history.serialised()
        let url = self.url
        RequestHistoryStore.queue.async { RequestHistoryStore.write(text, to: url) }
    }

    private static func write(_ text: String, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // The temporary file carries the pid, so two Nyxes pointed at one directory cannot rename
        // each other's half-written file into place.
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        // `rename(2)`, not `moveItem`: it replaces an existing file atomically, which is the whole
        // point of writing to a temporary name, and `moveItem` fails when the destination exists.
        if rename(temporary.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
