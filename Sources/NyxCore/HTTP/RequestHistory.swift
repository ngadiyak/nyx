import Foundation

/// Where the request history lives: beside the config file, not inside the bundle.
///
/// Derived from `ConfigPath` for the same reason `SessionPath` is -- pointing `$NYX_CONFIG` at a
/// scratch directory, which is how the tests and the two-instance smoke check run, has to move the
/// history with it. Two Nyxes sharing one history file would each overwrite the other's.
public enum RequestHistoryPath {
    public static let environmentVariable = "NYX_REQUEST_HISTORY"
    public static let fileName = "requests"

    /// `environment[NYX_REQUEST_HISTORY]` if set and non-empty, else `requests` in the directory
    /// the config file resolves to.
    public static func resolve(environment: [String: String], home: String) -> URL {
        if let override = environment[environmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return ConfigPath.resolve(environment: environment, home: home)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }
}

/// The requests this Mac has run, newest first, for the palette's Requests section.
///
/// A value type with the whole rule in it: what counts as the same request, how many are kept, how
/// the file is written and read back, and what each row says. The app around it owns a file and a
/// queue and nothing else, so every question a reviewer can ask about the list -- does re-running
/// something move it or duplicate it, does turning the limit down take effect on the next launch,
/// does a half-written file lose more than the line it broke -- is answered by a test rather than
/// by reading `RequestHistoryStore`.
public struct RequestHistory: Equatable {
    /// One remembered request: the line as it was run, and when it was last run.
    public struct Entry: Equatable {
        /// The command line, unmasked. This is what a re-run sends, so it must be the real one;
        /// masking happens on the way to a *row* (`paletteItems`), never on the way to the file.
        public let line: String
        public let at: Date

        public init(line: String, at: Date) {
            self.line = line
            self.at = at
        }
    }

    /// How many lines of the file are worth reading to find `limit` requests: enough that a list
    /// of near-duplicates still fills the palette, few enough that a foreign file cannot stall
    /// launch.
    private static let readMultiple = 20

    /// Above this, a "line" is not a request anybody typed -- it is a base64 body or a corrupt
    /// file -- and parsing it per row is not worth the scrollback it came from.
    private static let maximumLineLength = 8_192

    /// How many requests are kept. `0` means the feature is off: nothing is recorded and nothing
    /// is written.
    public let limit: Int
    /// Newest first. Only `record` and `parse` build this, so it is always deduped and trimmed.
    public private(set) var entries: [Entry] = []

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Remembers a request, newest first.
    ///
    /// Dedup is on `CurlCommand.parse` equality rather than on the text, so re-running the same
    /// call moves its row to the top instead of adding a second one -- including when the second
    /// spelling differs (`--silent` for `-s`, a different header order). A line that does not
    /// parse as a curl with a URL is not kept at all: it could not be titled, deduped or re-run.
    public mutating func record(_ line: String, at: Date) {
        guard limit > 0, line.count <= RequestHistory.maximumLineLength else { return }
        guard let command = CurlCommand.parse(line) else { return }
        entries.removeAll { CurlCommand.parse($0.line) == command }
        entries.insert(Entry(line: line, at: at), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// Reads the file: one entry per line, `"<unix seconds>\t<line>"`, newest first.
    ///
    /// Every line is put back through `record`, oldest first, so a file written by an older build
    /// (or by a hand that edited it) comes back deduped and trimmed to the limit in force *now*.
    /// A line whose timestamp is not a number, that has no tab, or whose command is not a curl is
    /// dropped on its own; the rest of the file survives it.
    ///
    /// Split on any newline and with the `\r` taken off, because a file that has been through an
    /// editor or a Windows checkout otherwise comes back with a carriage return welded to the end
    /// of every command -- which parses as a *different* request each time and quietly turns dedup
    /// off. Only the newest `limit * 20` lines are read at all: this runs before the first window
    /// is drawn, and a file that grew unbounded elsewhere must not be a pause at launch.
    public static func parse(_ text: String, limit: Int) -> RequestHistory {
        var history = RequestHistory(limit: limit)
        let rows = text.split(whereSeparator: \.isNewline)
        for row in rows.prefix(max(0, limit) * RequestHistory.readMultiple).reversed() {
            guard let tab = row.firstIndex(of: "\t") else { continue }
            guard let seconds = TimeInterval(row[row.startIndex ..< tab]) else { continue }
            var line = String(row[row.index(after: tab)...])
            while line.hasSuffix("\r") { line.removeLast() }
            history.record(line, at: Date(timeIntervalSince1970: seconds))
        }
        return history
    }

    /// A stable handle for an entry, and what a palette row carries instead of its position.
    ///
    /// A hash rather than the line itself: a row is passed around, compared and printed, and the
    /// line it stands for can hold a bearer token or a password in its URL. FNV-1a rather than
    /// `Hasher`, whose seed changes per process -- an id has to mean the same thing to everything
    /// that sees it. Two entries can never share one: dedup keeps at most one entry per request.
    public static func identifier(for line: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in line.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The line behind a row, or nil when that request is no longer remembered -- trimmed off the
    /// end while the palette was open, or dropped by a hand edit. The caller says so rather than
    /// running whatever has taken its place.
    public func line(for id: String) -> String? {
        entries.first { RequestHistory.identifier(for: $0.line) == id }?.line
    }

    /// The file's contents, ending in a newline. Empty for an empty history, so a store that has
    /// nothing to say writes an empty file rather than a lone `"\n"`.
    public func serialised() -> String {
        guard !entries.isEmpty else { return "" }
        return entries.map { "\(Int($0.at.timeIntervalSince1970))\t\($0.line)" }
            .joined(separator: "\n") + "\n"
    }

    /// The palette's Requests section, in `entries` order.
    ///
    /// `kind` carries an id for the entry, not its position and not its line. Not the position,
    /// because a curl finishing in another tab while the palette is open moves every row down one
    /// and the row under the cursor would then run its neighbour's command. Not the line, because
    /// what a row shows is masked and what it runs must not be, and a row is passed around and
    /// printed. The caller reads the real line back with `line(for:)`, which says nil when that
    /// request is no longer remembered. Rows are dropped for entries that no longer parse, which a
    /// hand-edited file can produce.
    ///
    /// `searchText` ends in "request curl" so that either word finds the whole section, the way
    /// "theme" finds the themes: a palette you can only search by a host you already remember is a
    /// list, not a search.
    public func paletteItems(now: Date, masking: Masking = .display) -> [PaletteItem] {
        entries.compactMap { entry in
            guard let command = CurlCommand.parse(entry.line) else { return nil }
            let host = RequestHistory.displayHost(command.url.host, masking: masking)
            let path = command.url.path
            let title = "\(command.effectiveMethod) \(host)\(RequestHistory.shortened(path))"
            // The *whole* path, not the truncated one, and the method and host on their own: a row
            // is found by the segment that was cut off the end at least as often as by the part
            // that fits.
            return PaletteItem(title: title,
                               detail: RelativeAge.text(from: entry.at, to: now),
                               searchText: "\(title) \(host) \(path) \(command.effectiveMethod)"
                                   + " request curl",
                               kind: .request(id: RequestHistory.identifier(for: entry.line)))
        }
    }

    /// A palette row is one line of a list, not a URL bar: the age has to stay readable at the
    /// right-hand edge. Forty characters of path, the ellipsis included, so a cut row is visibly
    /// cut rather than looking like a request to a shorter path than the one that ran.
    private static func shortened(_ path: String, limit: Int = 40) -> String {
        guard path.count > limit else { return path }
        return String(path.prefix(limit - 1)) + "\u{2026}"
    }

    /// Bullets the password in a `user:password@host` URL when the row is for reading.
    ///
    /// The palette is the surface a screenshot catches, and this is the one credential that can
    /// reach a row's *title* -- headers and bodies never do. A userinfo carrying a `$` is a
    /// reference rather than a secret (`admin:$TOKEN@…`), and masking a reference hides the only
    /// part that says where the value comes from; the serialiser has the same rule.
    private static func displayHost(_ host: String, masking: Masking) -> String {
        guard masking == .display, let at = host.lastIndex(of: "@") else { return host }
        let userinfo = host[host.startIndex ..< at]
        guard let colon = userinfo.firstIndex(of: ":") else { return host }
        let password = userinfo[userinfo.index(after: colon)...]
        guard !password.isEmpty, !password.contains("$") else { return host }
        return userinfo[userinfo.startIndex ... colon] + SecretMasking.masked(String(password))
            + host[at...]
    }
}
