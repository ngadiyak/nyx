import Foundation

/// The block the keyboard is on.
///
/// Eight block-scoped actions used to answer "which block" five different ways -- `commandToFold()`,
/// `lastFinishedCommand`, pointer-or-hovered-or-last, and newest-run-is-last -- so the pointer path
/// and the keyboard path targeted different blocks with nothing on screen to say which. Each of the
/// five was individually correct, which is why no unit test could have found it. One value replaces
/// them: moved by ⌘↑/⌘↓, re-anchored when the viewport moves for another reason, drawn as a hovered
/// block so it can never be a trap, and cleared when there is nothing to be on.
public struct BlockCursor: Equatable {
    public enum Direction: Equatable { case previous, next }

    /// The block, or nil for a pane nobody has pressed ⌘↑ in. nil is drawn as nothing at all.
    public var commandID: UInt32?

    public init(commandID: UInt32? = nil) { self.commandID = commandID }

    public var isEmpty: Bool { commandID == nil }

    /// One step, among the blocks the pane has, oldest first.
    ///
    /// Clamps rather than wraps: ⌘↑ held down at the top of a session must stop there, not appear
    /// a thousand rows away at the bottom. From a cleared cursor the first ⌘↑ takes the newest
    /// block and the first ⌘↓ the oldest, which is where each of those gestures already looks.
    ///
    /// A cursor whose block has been trimmed out of the scrollback re-anchors on the nearest
    /// survivor *in the direction of travel* rather than stepping from an id that no longer names
    /// anything: stepping from a hole skips whichever block now sits there.
    public static func moved(_ current: Self, by direction: Direction, among ids: [UInt32]) -> Self {
        guard let first = ids.first, let last = ids.last else { return BlockCursor() }
        guard let id = current.commandID else {
            return BlockCursor(commandID: direction == .previous ? last : first)
        }
        if let index = ids.firstIndex(of: id) {
            let step = direction == .previous ? index - 1 : index + 1
            return BlockCursor(commandID: ids[min(max(step, 0), ids.count - 1)])
        }
        switch direction {
        case .previous: return BlockCursor(commandID: ids.last(where: { $0 < id }) ?? first)
        case .next: return BlockCursor(commandID: ids.first(where: { $0 > id }) ?? last)
        }
    }

    /// The viewport moved for a reason other than ⌘↑/⌘↓ -- a scroll, new output, a fold.
    ///
    /// `fallback` is `Terminal.commandToFold()`'s answer. The cursor keeps its block while that
    /// block is still on screen, otherwise takes the fallback, and clears when there is no
    /// fallback either. A *cleared* cursor stays cleared: the cursor is drawn, and a pane that
    /// grew one on a scroll would light a block nobody asked about.
    public static func afterViewportMove(_ current: Self, visible: [UInt32], fallback: UInt32?) -> Self {
        guard let id = current.commandID else { return current }
        if visible.contains(id) { return current }
        return BlockCursor(commandID: fallback)
    }

    /// Where a ⌘↑/⌘↓ press starts from.
    ///
    /// A cursor that is cleared, or on a block that is not on the screen the reader is looking at,
    /// is seeded from that screen: `viewportBlock` is `commandToFold()`'s answer -- the block at
    /// the top of a scrolled-back viewport, the newest one at the bottom of the session. Without
    /// it, ⌘↑ in a pane wheeled back two thousand rows would take the newest block and throw the
    /// viewport to the bottom, where `previous_prompt` has always gone to the prompt above what
    /// the reader can see.
    ///
    /// The press then **lands on the seed** rather than stepping past it -- the same thing `moved`
    /// does with an id scrollback has trimmed, for the same reason: the block filling the screen is
    /// the one the reader means, and stepping over it skips the output they are in the middle of.
    /// A second press steps.
    ///
    /// nil when there is nothing to seed from, or when the seed is where the cursor already is, in
    /// which case the caller runs `moved` as usual.
    public static func seed(_ current: Self, visible: [UInt32], viewportBlock: UInt32?) -> Self? {
        if let id = current.commandID, visible.contains(id) { return nil }
        guard let seed = viewportBlock, seed != 0, seed != current.commandID else { return nil }
        return BlockCursor(commandID: seed)
    }
}

/// Which block a block-scoped action acts on: one rule, with the fallback each caller names.
///
/// The cursor is the answer whenever it names a block that is still in the buffer. The fallback is
/// only what a pane with *no cursor at all* means -- `commandToFold()` for the six ordinary
/// actions, the last request in the pane for the two that need a response -- and it is one
/// documented line per caller instead of five rules spread over four files.
public enum BlockTarget {
    public static func resolve(cursor: BlockCursor, exists: (UInt32) -> Bool,
                               fallback: UInt32?) -> UInt32? {
        if let id = cursor.commandID, exists(id) { return id }
        return fallback
    }
}

public extension Terminal {
    /// Every block the keyboard can be on, oldest first.
    ///
    /// A block is one the shell has actually run: it has output or a status. The prompt the user is
    /// typing at has an id and neither, and landing ⌘↑ on it would raise a strip with no summary,
    /// no Copy and nothing to fold -- the first thing anyone pressing ⌘↑ would see.
    ///
    /// Walks the buffer, so it belongs on a keystroke and not in a frame; `promptRows` says the
    /// same about itself. One `CommandRegionMemo` keeps it linear in the rows rather than
    /// quadratic in the block lengths.
    var blockCursorIDs: [UInt32] {
        guard shellEmitsPromptMarks else { return [] }
        let memo = CommandRegionMemo()
        var ids: [UInt32] = []
        for row in promptRows {
            guard let region = region(containing: row, memo: memo), region.id != 0,
                  region.outputStart != nil || region.exitStatus != nil else { continue }
            ids.append(region.id)
        }
        return ids
    }
}
