import Foundation

/// A command and its output, treated as one thing.
///
/// The terminal already knows where each command began, where its output started, how it ended and
/// how long it took. A block is that knowledge made visible and actionable: a spine down the left
/// of the rows it owns, a status, and things you can do to the whole of it — fold it, copy its
/// output, run it again.
///
/// Warp made this famous and paid for it by replacing the terminal underneath: its blocks break in
/// tmux, over ssh and in full-screen programs, because they are a different rendering model rather
/// than a reading of an ordinary one. Here the grid is untouched and the block is drawn over it, so
/// vim and htop behave exactly as they did — the chrome simply steps aside.
public struct CommandBlock: Equatable {
    public let region: CommandRegion
    /// The rows the block covers on screen, clamped to the viewport: `nil` when none of it is
    /// visible.
    public let visibleRows: Range<Int>
    /// Whether the block's own prompt row is one of the visible ones. The header is only worth
    /// drawing where the command is.
    public let showsHeader: Bool

    public init(region: CommandRegion, visibleRows: Range<Int>, showsHeader: Bool) {
        self.region = region
        self.visibleRows = visibleRows
        self.showsHeader = showsHeader
    }

    /// Something is actually running: output has begun and no status has arrived. The prompt you
    /// are typing at has neither, and calling that "running" leaves an amber marker beside an idle
    /// cursor forever.
    public var isRunning: Bool {
        region.outputStart != nil && region.exitStatus == nil && region.duration == nil
    }
    public var failed: Bool { region.failed }

    /// What the header says to the right of the command: how it ended and how long it took.
    ///
    /// Empty for a command still running that has not been going long enough to be worth a word --
    /// a status that appears the instant you press return is noise, and one that never appears is
    /// a terminal that looks stuck.
    public func summary() -> String {
        var parts: [String] = []
        if let status = region.exitStatus, status != 0 { parts.append("exit \(status)") }
        if let duration = region.duration, DurationText.isWorthShowing(duration) {
            parts.append(DurationText.short(duration))
        }
        return parts.joined(separator: " · ")
    }
}

public extension Terminal {
    /// The blocks any part of which is on screen, in order.
    ///
    /// Walks the visible rows and nothing else. The whole point of recording each command's status
    /// and duration on its own prompt row was that this can be answered without scanning the
    /// buffer, on every frame, under the session lock.
    func visibleBlocks(rows visibleRows: Int) -> [CommandBlock] {
        guard visibleRows > 0, shellEmitsPromptMarks else { return [] }
        let top = max(0, viewportTopRow)
        let bottom = min(totalRows, top + visibleRows)
        guard top < bottom else { return [] }

        var blocks: [CommandBlock] = []
        var row = top
        while row < bottom {
            guard let region = command(containingAbsoluteRow: row) else {
                row += 1
                continue
            }
            let first = max(region.promptRow, top)
            let last = min(region.endRow, bottom - 1)
            if first <= last {
                blocks.append(CommandBlock(region: region,
                                           visibleRows: (first - top)..<(last - top + 1),
                                           showsHeader: region.promptRow >= top && region.promptRow < bottom))
            }
            // Straight to the row after this command; a block covers every row it owns.
            row = max(row + 1, region.endRow + 1)
        }
        return blocks
    }

    /// The block under a point, for a click on the spine or the header.
    func block(atAbsoluteRow row: Int, rows visibleRows: Int) -> CommandBlock? {
        visibleBlocks(rows: visibleRows).first { block in
            let top = max(0, viewportTopRow)
            return block.visibleRows.contains(row - top)
        }
    }
}

/// Where the chrome for a block goes, and when it should not be drawn at all.
public enum CommandBlockChrome {
    /// The spine's width in cells' worth of points, and the gap between it and the text.
    public static let spineWidth: Double = 2
    public static let spineGap: Double = 4

    /// Whether block chrome may be drawn over this screen at all.
    ///
    /// Not while a full-screen program owns the display or the mouse. `vim`, `htop` and anything
    /// else on the alternate screen are drawing their own interface across every cell, and a spine
    /// down the side of it is a bug -- as is a header that eats a click the program was waiting
    /// for. This is the rule Warp's blocks do not have, and the reason its blocks break in tmux.
    public static func isAllowed(altScreen: Bool, mouseReporting: Bool, hasMarks: Bool) -> Bool {
        hasMarks && !altScreen && !mouseReporting
    }

    /// Where a right-aligned summary of `textCount` cells may be drawn on a row whose last used
    /// column is `lastUsedColumn` (-1 for an empty row), or nil when it would touch the text.
    ///
    /// One rule, so the renderer (deciding whether to draw it) and the pane (deciding whether a
    /// click landed on it) can never disagree about where the summary is -- or whether it is
    /// showing at all. A command line long enough to reach the summary's column, or a pane too
    /// narrow to fit it, means no summary rather than one drawn over the text or off the left edge.
    public static func summaryColumns(textCount: Int, cols: Int, lastUsedColumn: Int) -> Range<Int>? {
        let start = cols - textCount
        guard textCount > 0, start > 0, lastUsedColumn < start - 1 else { return nil }
        return start..<cols
    }
}

/// What can be done to a block, in the order the ⋯ menu lists it.
public enum BlockAction: Equatable {
    case copyCommand, copyOutput, copyMarkdown, saveOutput
    case runAgain, editAndRun
    case toggleFold, toggleFoldAll
    case notifyWhenDone(armed: Bool)

    /// The neutral title. `BlockHeader.title(for:)` adjusts the two fold titles to the state.
    public var title: String {
        switch self {
        case .copyCommand: return "Copy Command"
        case .copyOutput: return "Copy Output"
        case .copyMarkdown: return "Copy as Markdown"
        case .saveOutput: return "Save Output\u{2026}"
        case .runAgain: return "Run This Command Again"
        case .editAndRun: return "Edit and Run This Command\u{2026}"
        case .toggleFold: return "Fold Output"
        case .toggleFoldAll: return "Fold Everything Long"
        case .notifyWhenDone: return "Notify When Done"
        }
    }

    /// Where a separator goes in the menu: before the first action of each group after the first.
    public var startsGroup: Bool {
        switch self {
        case .runAgain, .toggleFold, .notifyWhenDone: return true
        default: return false
        }
    }
}

/// Everything the command row and the hover overlay say about one block, decided once.
public struct BlockHeader: Equatable {
    public enum State: Equatable {
        case running(elapsed: Double)
        case finished
        case failed(status: Int32)
    }

    public let id: UInt32
    public let state: State
    public let folded: Bool
    public let hasOutput: Bool
    /// Whether any block in the pane is folded, which is what "Unfold Everything" needs to know.
    public let anyFolds: Bool
    public let notifyArmed: Bool
    /// "exit 1 · 8.8s" for a failure, "8.8s" for a slow success, "12s" for a command still going,
    /// and nothing for a quick success -- a status that appears the instant you press return is
    /// noise. Computed by `CommandBlock.header(now:...)`, stored here so the view compares one value.
    public let summary: String

    public init(id: UInt32, state: State, folded: Bool, hasOutput: Bool, anyFolds: Bool,
                notifyArmed: Bool, summary: String) {
        self.id = id; self.state = state; self.folded = folded; self.hasOutput = hasOutput
        self.anyFolds = anyFolds; self.notifyArmed = notifyArmed; self.summary = summary
    }

    public var isRunning: Bool { if case .running = state { return true } else { return false } }

    public var chevron: String {
        guard hasOutput else { return "" }
        return folded ? "\u{25B8}" : "\u{25BE}"
    }

    /// What the renderer draws at the end of the command row: the summary, a space, the chevron.
    public var summaryWithChevron: String {
        switch (summary.isEmpty, chevron.isEmpty) {
        case (true, true): return ""
        case (true, false): return chevron
        case (false, true): return summary
        case (false, false): return summary + " " + chevron
        }
    }

    /// The ⋯ menu, in order, each with whether it can do anything right now.
    public var actions: [(action: BlockAction, enabled: Bool)] {
        var list: [(BlockAction, Bool)] = [
            (.copyCommand, true), (.copyOutput, hasOutput), (.copyMarkdown, true), (.saveOutput, hasOutput),
            (.runAgain, !isRunning), (.editAndRun, !isRunning),
            (.toggleFold, hasOutput), (.toggleFoldAll, true),
        ]
        if isRunning { list.append((.notifyWhenDone(armed: notifyArmed), true)) }
        return list.map { (action: $0.0, enabled: $0.1) }
    }

    public func title(for action: BlockAction) -> String {
        switch action {
        case .toggleFold: return folded ? "Unfold Output" : "Fold Output"
        case .toggleFoldAll: return anyFolds ? "Unfold Everything" : "Fold Everything Long"
        default: return action.title
        }
    }
}

public extension CommandBlock {
    /// The header for this block at clock reading `now`.
    func header(now: Double, folding: OutputFolding, notifyArmed: Bool, anyFolds: Bool) -> BlockHeader {
        let state: BlockHeader.State
        let summary: String
        if isRunning {
            let elapsed = max(0, now - (region.startedAt ?? now))
            state = .running(elapsed: elapsed)
            summary = elapsed >= 1 ? DurationText.short(elapsed) : ""
        } else if let status = region.exitStatus, status != 0 {
            state = .failed(status: status)
            summary = self.summary()
        } else {
            state = .finished
            summary = self.summary()
        }
        return BlockHeader(id: region.id, state: state, folded: folding.isFolded(region.id),
                           hasOutput: !region.outputRows.isEmpty, anyFolds: anyFolds,
                           notifyArmed: notifyArmed, summary: summary)
    }
}

/// Which block the pointer is over, and where its chrome goes. Pure so the answer for "pointer on
/// the row after the last block" or "chrome disallowed while a TUI runs" is a test, not a guess.
public struct BlockHover: Equatable {
    public let id: UInt32
    /// Visible rows to tint.
    public let rows: Range<Int>
    /// The visible row to attach the overlay to, nil when the command line is above the viewport.
    public let headerRow: Int?

    public static func resolve(pointerRow: Int?, blocks: [CommandBlock], allowed: Bool) -> BlockHover? {
        guard allowed, let pointerRow,
              let block = blocks.first(where: { $0.visibleRows.contains(pointerRow) }),
              block.region.id != 0 else { return nil }
        return BlockHover(id: block.region.id, rows: block.visibleRows,
                          headerRow: block.showsHeader ? block.visibleRows.lowerBound : nil)
    }
}

public extension BlockHover {
    /// The same hover in display slots, for a viewport with folds on screen.
    ///
    /// `rows` and `headerRow` come out of `visibleBlocks`/`resolve` in viewport-relative *absolute*
    /// space, which only equals a display slot when nothing is folded. With a fold on screen a
    /// slot's row content is not `viewportTop + slot`, so tinting or attaching the overlay by slot
    /// number would land on whatever the fold happened to pull into that index. This walks the
    /// actual slots the renderer is about to draw and asks each one whether it belongs to this
    /// block. The block's own fold placeholder counts as one of its rows: it stands for the block's
    /// output, and hovering it should tint and unfold the same thing a visible output row would.
    func placed(onDisplayRows display: [DisplayRow], viewportTop: Int) -> BlockHover? {
        var slots: [Int] = []
        var headerSlot: Int?
        for (slot, entry) in display.enumerated() {
            switch entry {
            case .row(let absolute):
                let relative = absolute - viewportTop
                guard rows.contains(relative) else { continue }
                slots.append(slot)
                if headerRow == relative { headerSlot = slot }
            case .fold(let commandID, _):
                guard commandID == id else { continue }
                slots.append(slot)
            }
        }
        guard let first = slots.min(), let last = slots.max() else { return nil }
        return BlockHover(id: id, rows: first..<(last + 1), headerRow: headerSlot)
    }
}
