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

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Whether this block's transcript still has to be read. Deliberately not a function of the
    /// clock, the frame, or the buffer's version: see the type's note.
    public func shouldParse(id: UInt32) -> Bool { entries[id] == nil }

    public func entry(for id: UInt32) -> Entry? { entries[id] }

    public mutating func remember(_ entry: Entry, for id: UInt32) { entries[id] = entry }

    /// Drops everything the buffer has evicted. Command ids only ever increase, so `oldest` is a
    /// clean cut: an id below it names rows that are gone and a block that can never come back.
    public mutating func prune(olderThan oldest: UInt32) {
        guard !entries.isEmpty else { return }
        entries = entries.filter { $0.key >= oldest }
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
    }
}
