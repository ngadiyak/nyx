import Foundation

/// Where the session snapshot lives: beside the config file, not inside the bundle.
///
/// Derived from `ConfigPath` rather than hardcoded, so pointing `$NYX_CONFIG` somewhere else --
/// which is how the tests and the smoke check run against a scratch directory -- moves the session
/// file with it, and a snapshot can never be written next to somebody else's config.
public enum SessionPath {
    public static let environmentVariable = "NYX_SESSION"
    public static let fileName = "session.json"

    /// `environment[NYX_SESSION]` if set and non-empty, else `session.json` in the directory the
    /// config file resolves to.
    public static func resolve(environment: [String: String], home: String) -> URL {
        if let override = environment[environmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return ConfigPath.resolve(environment: environment, home: home)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }
}

/// How much of a pane's buffer is worth keeping.
///
/// Quitting with ten tabs must not be a pause the user notices, and nobody scrolls back through
/// last week's build output anyway. The newest rows are the ones that mean something, so the cap
/// takes them from the end.
public enum SessionCapture {
    public static let maximumRowsPerPane = 5_000

    /// The rows to write for a pane with `totalRows` in its buffer: the last `limit` of them.
    /// Always a valid range, including for an empty buffer and for a nonsensical limit.
    public static func rowRange(totalRows: Int, limit: Int = maximumRowsPerPane) -> Range<Int> {
        let total = max(0, totalRows)
        let kept = max(0, min(limit, total))
        return (total - kept)..<total
    }
}

/// What launch should do with whatever was on disk.
///
/// A separate decision from reading the file so that every way of ending up with no windows --
/// the setting is off, the file is missing, it is corrupt, it is from another version, it is a
/// month old, it describes windows with no tabs in them -- reaches the same answer through one
/// tested function rather than through five guards spread over `AppDelegate`.
public enum SessionRestore {
    public enum Plan: Equatable {
        /// Rebuild these windows. Never empty, and no window in it is without tabs.
        case restore([WindowSnapshot])
        /// Open one ordinary window, exactly as a first launch does.
        case freshWindow
    }

    public static func plan(snapshot: SessionSnapshot?, enabled: Bool, now: Date = Date()) -> Plan {
        guard enabled, let snapshot, snapshot.isUsable(now: now) else { return .freshWindow }
        let windows = snapshot.windows.filter { !$0.tabs.isEmpty }
        return windows.isEmpty ? .freshWindow : .restore(windows)
    }

    /// The smallest window worth restoring to. Below this the title bar's own buttons do not fit,
    /// so a hand-edited or truncated frame would come back as something unusable.
    public static let minimumWindowSize = (width: 240.0, height: 120.0)

    /// A saved `[x, y, width, height]` as a rectangle, or nil when it does not describe a window
    /// anyone could use. The file is plain JSON a person can edit, so `["1e9", NaN]` has to be a
    /// possibility rather than an assumption.
    public static func frame(from saved: [Double]?) -> PaneRect? {
        guard let saved, saved.count == 4, saved.allSatisfy({ $0.isFinite }),
              saved[2] >= minimumWindowSize.width, saved[3] >= minimumWindowSize.height
        else { return nil }
        return PaneRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
    }
}

/// Reads and writes the session file. Nothing here throws: a session that cannot be saved is worth
/// a line in the log, and one that cannot be read is worth an empty window -- neither is worth
/// refusing to start or refusing to quit.
public struct SessionStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: String = NSHomeDirectory()) -> SessionStore {
        SessionStore(url: SessionPath.resolve(environment: environment, home: home))
    }

    /// The snapshot on disk, or nil when there is none, it cannot be read, or it is not a snapshot.
    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SessionSnapshot.decoded(from: data)
    }

    /// Writes the snapshot, creating its directory if need be. Returns whether it landed.
    @discardableResult
    public func save(_ snapshot: SessionSnapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try snapshot.encoded().write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Forgets the session. Used when the setting is turned off, so a stale file cannot come back
    /// to life if it is turned on again a fortnight later.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
