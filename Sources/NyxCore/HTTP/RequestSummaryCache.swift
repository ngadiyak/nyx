import Foundation

/// Which finished blocks have already been read for a request, and what was found.
///
/// Reading a block means building its whole output as one string and walking it -- far too much to
/// do per frame, and the pane draws sixty a second. A finished block's output cannot change, so one
/// reading answers forever; this is the record of which ones have been read.
///
/// Whether a block has been read is the *only* question. The pane's first version also gated the
/// reading on the terminal's `contentVersion` having moved since the last frame, which is wrong in
/// a way that is invisible until it bites: a request that finished while its prompt row was
/// scrolled off screen was never read at all on an idle shell, so scrolling back to it showed the
/// command's duration and never its status, for as long as nothing else was typed.
public struct RequestSummaryCache: Equatable {
    /// What was found when a block was read.
    public enum Entry: Equatable {
        /// The block's command line is not a curl. Remembered as firmly as a request is: deciding
        /// it again costs `Terminal.commandLine(of:)` (a string built from the grid) and a full
        /// `CurlCommand.parse`, per block, per frame, and almost every block on a screen is this.
        case notARequest
        /// It is a request. nil when its transcript held neither a status line nor a sentinel --
        /// a connection that never happened, which still has a summary ("exit 7 · connection
        /// refused") built from the block's exit status alone.
        case request(HTTPExchange?)
    }

    private var entries: [UInt32: Entry] = [:]
    /// The command line each block ran, when it was one. Kept beside the entry rather than inside
    /// it so that "is there an earlier run of this same request" can be answered without walking
    /// the grid again -- the line was in hand when the block was read, and asking the buffer for it
    /// a second time means rebuilding a string out of cells for every block below this one.
    private var lines: [UInt32: String] = [:]
    /// The highest block id ever offered to the request history. See `shouldRecord`.
    private var highestRecorded: UInt32 = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Whether this block's transcript still has to be read. Deliberately not a function of the
    /// clock, the frame, or the buffer's version: see the type's note.
    public func shouldParse(id: UInt32) -> Bool { entries[id] == nil }

    public func entry(for id: UInt32) -> Entry? { entries[id] }

    /// Whether this block's command was a `curl`, from what was found when it was read -- the bool
    /// behind `BlockHeader.isHTTP` and the ⋯ menu's Request group.
    ///
    /// Read from the cache rather than decided again, because deciding it means building the
    /// command line out of the grid and parsing it, and the menu is built on a click while the
    /// header is built sixty times a second. False for a block nobody has read yet -- one still
    /// running, or one whose prompt row has never been on screen -- which is the honest answer:
    /// nothing has looked at it.
    public func isRequest(id: UInt32) -> Bool {
        if case .request = entries[id] { return true }
        return false
    }

    public mutating func remember(_ entry: Entry, line: String? = nil, for id: UInt32) {
        entries[id] = entry
        if let line { lines[id] = line }
    }

    /// The command line this block ran, as it was read off the grid.
    public func commandLine(of id: UInt32) -> String? { lines[id] }

    /// The nearest earlier block that ran the same request, or nil when there is not one. This is
    /// what `Diff with Previous Run` is enabled by, and what it diffs against.
    ///
    /// Nearest rather than oldest: a watched endpoint polled ten times should diff against the
    /// ninth, not the first. Parsing happens here rather than at `remember` time because this runs
    /// when a menu opens and that runs on every finished block.
    public func previousRun(before id: UInt32, matching command: CurlCommand) -> UInt32? {
        for candidate in lines.keys.filter({ $0 < id }).sorted(by: >) {
            guard case .request = entries[candidate], let line = lines[candidate],
                  let parsed = CurlCommand.parse(line) else { continue }
            if RequestSummaryCache.sameRequest(parsed, command) { return candidate }
        }
        return nil
    }

    /// Whether two command lines are the same *request*.
    ///
    /// The workbench's own run flags come off first (`RequestRun.stripAdditions`), because a
    /// request run from the sheet and the same one typed by hand are one request -- the request
    /// history draws the same line. Then the options this model keeps verbatim, the shell prefix
    /// and any trailing pipeline: a `--resolve`, a proxy or a `| jq` is how the call was made, not
    /// what was asked for, and two polls of one endpoint through different proxies are still worth
    /// diffing.
    public static func sameRequest(_ a: CurlCommand, _ b: CurlCommand) -> Bool {
        func core(_ command: CurlCommand) -> CurlCommand {
            var stripped = RequestRun.stripAdditions(from: command)
            stripped.other = []
            stripped.prefix = []
            stripped.trailingPipeline = ""
            return stripped
        }
        return core(a) == core(b)
    }

    /// Drops everything the buffer has evicted. Command ids only ever increase, so `oldest` is a
    /// clean cut: an id below it names rows that are gone and a block that can never come back.
    public mutating func prune(olderThan oldest: UInt32) {
        guard !entries.isEmpty else { return }
        entries = entries.filter { $0.key >= oldest }
        lines = lines.filter { $0.key >= oldest }
    }

    /// Whether this block's command should be written to the request history -- true once per
    /// block, ever.
    ///
    /// Separate from `shouldParse` because the two questions have different answers after a trim:
    /// a block whose entry has been evicted is read again when it comes back on screen, and
    /// recording it again would stamp a request from last Tuesday with the time you scrolled past
    /// it and lift it over everything actually run since. Command ids only ever increase (`prune`
    /// relies on the same fact, and a terminal `reset` does not restart them), so an id at or
    /// below the high-water mark names a block that has already had its turn.
    public mutating func shouldRecord(id: UInt32) -> Bool {
        guard id > highestRecorded else { return false }
        highestRecorded = id
        return true
    }

    /// Keeps the `limit` most recent entries.
    ///
    /// The oldest go, rather than all of them. Wiping the cache made every block still on screen
    /// pay for its command line again on the next frame; wiping one of two side-by-side caches --
    /// which is what this type replaced -- left the two disagreeing about which blocks had been
    /// looked at, so a block could be "known not to be a request" and unparsed at the same time.
    public mutating func trim(to limit: Int) {
        guard entries.count > limit else { return }
        let survivors = Set(entries.keys.sorted().suffix(limit))
        entries = entries.filter { survivors.contains($0.key) }
        lines = lines.filter { survivors.contains($0.key) }
    }
}
