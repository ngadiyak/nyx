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
    /// `ids` is `Terminal.blockCursorIDs` -- the *buffer's* blocks, which is a walk and therefore a
    /// keystroke's work. Never the frame's `visibleBlocks(...)`: ⌘↑ has to be able to leave the
    /// screen, and among twenty visible ids it would stop at the top of the viewport instead.
    ///
    /// Clamps rather than wraps at the *old* end: ⌘↑ held down at the top of a session must stop
    /// there, not appear a thousand rows away at the bottom. From a cleared cursor the first ⌘↑
    /// takes the newest block and the first ⌘↓ the oldest, which is where each of those gestures
    /// already looks.
    ///
    /// **Past the newest block the cursor clears**, and does not clamp. There is somewhere to go
    /// past the newest block -- the prompt the user is typing at, which is not a block and so is
    /// exactly "no block" -- and `next_prompt` always went there. Clamping made ⌘↓ at the newest
    /// block report "nothing moved", which the pane turns into a beep: the one chord whose whole
    /// job is "forward" refused to reach the place the user is typing in. The caller reads a
    /// cleared answer from a cursor that had a block as "go to the bottom".
    ///
    /// A cursor whose block has been trimmed out of the scrollback re-anchors on the nearest
    /// survivor *in the direction of travel* rather than stepping from an id that no longer names
    /// anything: stepping from a hole skips whichever block now sits there. An id above every
    /// survivor is already past the newest block, so it takes the same answer a step off the newest
    /// block does.
    public static func moved(_ current: Self, by direction: Direction, among ids: [UInt32]) -> Self {
        guard let first = ids.first, let last = ids.last else { return BlockCursor() }
        guard let id = current.commandID else {
            return BlockCursor(commandID: direction == .previous ? last : first)
        }
        if let index = ids.firstIndex(of: id) {
            switch direction {
            case .previous: return BlockCursor(commandID: ids[max(index - 1, 0)])
            case .next: return index + 1 < ids.count ? BlockCursor(commandID: ids[index + 1])
                                                     : BlockCursor()
            }
        }
        switch direction {
        case .previous: return BlockCursor(commandID: ids.last(where: { $0 < id }) ?? first)
        case .next:
            guard let following = ids.first(where: { $0 > id }) else { return BlockCursor() }
            return BlockCursor(commandID: following)
        }
    }

    /// The viewport moved for a reason other than ⌘↑/⌘↓ -- a scroll, new output, a fold.
    ///
    /// `visible` is the *frame's* own ids -- `visibleBlocks(...).map(\.region.id)`, the blocks this
    /// frame is about to draw -- and never `blockCursorIDs`, whose buffer walk would say every block
    /// in the session is on screen and re-anchor nothing, ever. `fallback` is
    /// `Terminal.commandToFold()`'s answer, which is the same frame's viewport and may name a block
    /// that is not in `visible` at all.
    ///
    /// The cursor keeps its block while that block is still on screen, otherwise takes the fallback,
    /// and clears when there is no fallback either. A *cleared* cursor stays cleared: the cursor is
    /// drawn, and a pane that grew one on a scroll would light a block nobody asked about.
    public static func afterViewportMove(_ current: Self, visible: [UInt32], fallback: UInt32?) -> Self {
        guard let id = current.commandID else { return current }
        if visible.contains(id) { return current }
        return BlockCursor(commandID: fallback)
    }

    /// The cursor after a block-scoped action resolved the block it is about to act on.
    ///
    /// The lit block and the acted-on block could differ, and that was a trap either way round
    /// (PM P2). ⌘↑ lights block B; a pointer nudge over block A moves the strip to A, because the
    /// pointer wins while it is inside the pane; and ⌘⇧A then popped B's menu over a block drawn
    /// dark while A was the one visibly raised. With no cursor at all, ⌘⇧A popped twenty-nine rows
    /// belonging to `commandToFold()`'s block with nothing marking it anywhere on the screen.
    ///
    /// So the action adopts what it resolved, *before* acting: the acted-on block is the lit one,
    /// the pointer stops winning until it moves again, and the next ⌘↑ steps from where the last
    /// action landed. `resolved` is `BlockTarget.resolve`'s answer, which is the cursor's own block
    /// whenever there is one -- so on the ordinary path this changes nothing at all.
    ///
    /// nil resolves nothing and changes nothing: the caller is about to beep, and taking the light
    /// off the block the user was asking about is not what a refusal means. 0 is "no command"
    /// everywhere here, as in `seed`.
    public static func adopted(_ current: Self, resolved: UInt32?) -> Self {
        guard let resolved, resolved != 0 else { return current }
        return BlockCursor(commandID: resolved)
    }

    /// What one ⌘↑/⌘↓ press does. The whole press, so the sequence a user presses is testable.
    public enum Press: Equatable {
        /// Put the cursor on this block and bring the viewport to it.
        case go(UInt32)
        /// Clear the cursor and take the viewport to the live prompt at the bottom.
        case toBottom
        /// Nowhere to go. The caller beeps and changes nothing.
        case refused
    }

    /// One press, from the lists it needs: `among` is the buffer's blocks
    /// (`Terminal.blockCursorIDs`), `visible` the frame's own ids, `viewportBlock`
    /// `commandToFold()`'s answer, `atBottom` whether the viewport is already at the live prompt.
    ///
    /// Three answers, because a press has three honest outcomes and the pane must not decide which
    /// -- ⌘↓ off the newest block is not "nowhere to go", and ⌘↓ at the prompt is not "somewhere to
    /// go". Held as one function so the *sequence* a user presses is a thing a test can press.
    ///
    /// `among` and `viewportBlock` are autoclosures because both walk the buffer and the press that
    /// needs neither -- ⌘↓ at the live prompt, which is the one a user holds down -- must not pay
    /// for two walks to be told there is nowhere to go. The call site reads as if they were values.
    /// Each is evaluated at most once, and ⌘↑ onto a seed evaluates `among` not at all.
    public static func press(_ current: Self, forward: Bool,
                             among ids: @autoclosure () -> [UInt32],
                             visible: [UInt32],
                             viewportBlock: @autoclosure () -> UInt32?,
                             atBottom: Bool) -> Press {
        // ⌘↓ with no cursor and the viewport already at the live prompt: you are there. Without
        // this the press was seeded from what fills the screen -- the newest block, at the bottom --
        // and ⌘↓ *toggled* between the newest block and the prompt for as long as it was held. The
        // seeding ruling is about starting from the screen the reader is on, which is a rule for a
        // press that has somewhere to go; at the bottom, forwards, there is nowhere. Scrolled back
        // (`atBottom` false) ⌘↓ seeds too -- see below for where it goes from there.
        if forward, current.isEmpty, atBottom { return .refused }
        let next: Self
        // Whether this press had a real block to start from -- the cursor's or the seed's. Only
        // such a press can be "past the newest block"; one that started from nothing and found
        // nothing is a pane with no blocks in it, which beeps.
        let startedFromABlock: Bool
        if let seeded = seed(current, visible: visible, viewportBlock: viewportBlock()) {
            // ⌘↑ **lands on** the seed, and ⌘↓ **steps past** it. `commandToFold()` answers with the
            // block at the *top* of the screen -- its prompt row is at or above the viewport top --
            // so landing on it made the first ⌘↓ in a scrolled-back pane scroll the viewport
            // backwards, and an off-screen cursor walk backwards with it. Going up from what fills
            // the screen means that block; going down from it means the one after.
            next = forward ? moved(seeded, by: .next, among: ids()) : seeded
            startedFromABlock = true
        } else {
            next = moved(current, by: forward ? .next : .previous, among: ids())
            startedFromABlock = !current.isEmpty
        }
        if let id = next.commandID { return .go(id) }
        // Forward and cleared, from a cursor or a seed that *had* a block, is `moved` saying "past
        // the newest one", which is the live prompt. A backward press clearing means there were no
        // blocks at all, and so does a forward one with nothing to start from.
        if forward, startedFromABlock { return .toBottom }
        return .refused
    }

    /// Where a ⌘↑/⌘↓ press starts from.
    ///
    /// A cursor that is cleared, or on a block that is not on the screen the reader is looking at,
    /// is seeded from that screen: `visible` is the *frame's* own ids, as in `afterViewportMove`,
    /// and `viewportBlock` is `commandToFold()`'s answer -- the block at the top of a scrolled-back
    /// viewport, the newest one at the bottom of the session. Without it, ⌘↑ in a pane wheeled back
    /// two thousand rows would take the newest block and throw the viewport to the bottom, where
    /// `previous_prompt` has always gone to the prompt above what the reader can see.
    ///
    /// **The seed need not be a member of the `among` list the caller then steps through.**
    /// `commandToFold()` answers with the command whose *prompt row* is on screen, which for a
    /// command that printed nothing is the region the next prompt shares -- so a seed can name a
    /// block `blockCursorIDs` excludes. That is why the press lands on the seed instead of stepping
    /// from it: `moved` from an id it cannot find falls back to the nearest survivor in the
    /// direction of travel, which is the right answer for the *second* press and the wrong one for
    /// the first.
    ///
    /// **A seed of 0 is no seed at all** -- 0 is "no command" everywhere here. It comes from a
    /// region whose prompt row carries no command id (`command(containingAbsoluteRow:)` ends with
    /// `absoluteRow(start)?.commandID ?? 0`): a row the scrollback has trimmed under a region that
    /// still names it, or marks fed without one. It is *not* what a row above the first prompt
    /// answers -- there the region itself is nil, and there is nothing to seed from either way.
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
    /// same about itself. One resolution per block: `promptRows` gives one row per region, so each
    /// row asked here belongs to a different command and a `CommandRegionMemo` between them could
    /// never hit -- it would carry a cache that is written once and read never, and claim a saving
    /// in a doc comment that the next reader would believe.
    var blockCursorIDs: [UInt32] {
        guard shellEmitsPromptMarks else { return [] }
        var ids: [UInt32] = []
        for row in promptRows {
            guard let region = command(containingAbsoluteRow: row), region.id != 0,
                  region.outputStart != nil || region.exitStatus != nil else { continue }
            ids.append(region.id)
        }
        return ids
    }
}
