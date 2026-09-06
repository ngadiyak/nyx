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
    ///
    /// A wrapper for the ordinary, unfolded case, where the rows on screen are exactly
    /// `viewportTop ..< viewportTop + rows`. With a fold on screen they are not: hiding 27 rows
    /// pulls rows from far below into the same number of slots, and every block down there used to
    /// fall outside this window and lose its spine, summary and gutter mark.
    func visibleBlocks(rows visibleRows: Int) -> [CommandBlock] {
        let top = max(0, viewportTopRow)
        return visibleBlocks(from: top, through: top + visibleRows - 1)
    }

    /// The blocks overlapping an explicit window of absolute rows, indexed from `top`.
    func visibleBlocks(from top: Int, through last: Int) -> [CommandBlock] {
        guard shellEmitsPromptMarks else { return [] }
        let top = max(0, top)
        let bottom = min(totalRows, last + 1)
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
            // Straight to the row after this command; a block covers every row it owns. The last
            // command in the buffer is the end of the walk: its `endRow` is clamped to the last
            // written row, and the unwritten rows below it map back to this same command, which
            // would append it once per blank row.
            if region.isLastInBuffer { break }
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

    /// Which of a command's rows carries its summary, and how much of it fits.
    ///
    /// `summaryColumns` alone answers "does the whole thing fit on this row", and the answer for a
    /// realistic pasted `curl` in a 100-column pane -- or for any narrow split -- is no. That lost
    /// the chevron, which is the only thing on the row that folds the block: the status is a nicety
    /// and the control is not. So this walks the command's rows from the last to the first (a
    /// wrapped command line has several, and the last is usually the shortest), takes the first row
    /// with room for the whole summary, falls back to the first with room for the chevron alone,
    /// and only then gives up -- at which point the gutter mark is what folds the block.
    ///
    /// Placing it is one rule for the same reason `summaryColumns` is: the renderer draws it, the
    /// pane records the click target, and the hover overlay attaches to it. Three call sites
    /// deciding separately is three ways for the pixels, the click and the strip to disagree --
    /// and the overlay placed from the prompt row alone painted over the command's own text on
    /// exactly the rows where the summary had been refused.
    public static func summaryPlacement(commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                                        textCount: Int, chevronCount: Int, cols: Int) -> SummaryPlacement? {
        var chevronOnly: SummaryPlacement?
        for row in commandRows.reversed() {
            if let columns = summaryColumns(textCount: textCount, cols: cols,
                                            lastUsedColumn: row.lastUsedColumn) {
                return SummaryPlacement(row: row.absoluteRow, columns: columns, text: .full)
            }
            if chevronOnly == nil,
               let columns = summaryColumns(textCount: chevronCount, cols: cols,
                                            lastUsedColumn: row.lastUsedColumn) {
                chevronOnly = SummaryPlacement(row: row.absoluteRow, columns: columns, text: .chevronOnly)
            }
        }
        return chevronOnly
    }

    /// Which row the hover strip goes on and how much of it fits there.
    ///
    /// The same ladder `summaryPlacement` walks, for the same reason and against the same rows: the
    /// strip is chrome over a row of the user's own text, and the text wins. `stripColumns` is the
    /// view's measured width per control set, in columns (the pane rounds up, so a strip right
    /// aligned to the last column can never begin left of `lastUsedColumn + 1`). nil when not even
    /// the ⋯ and the chevron fit anywhere on the command.
    ///
    /// `fallbackToTail` decides what happens when no row has room for even the ⋯ and the chevron.
    ///
    /// The hover strip passes true: the minimal strip then goes over the tail of the **last** row
    /// anyway, because the command it covers is the one that needs it most -- a request run from
    /// the workbench is a single line hundreds of characters long, it fills every row it touches,
    /// and its ⋯ menu is the only place "Open in Workbench", the four exports and "Save as Button"
    /// are. Four cells are hidden *while the pointer is on the block* and come back the moment it
    /// leaves; a menu that could not be opened at all would not come back.
    ///
    /// Everything else passes false, and the workbench pill is why the parameter exists. The pill
    /// appears on its own, with no pointer anywhere near it, and covering four cells of a command
    /// somebody is still typing -- to advertise a feature they did not ask for -- is not a trade
    /// anyone agreed to. No room, no pill.
    ///
    /// A pane narrower than the smallest strip gets nothing either way: the strip would begin off
    /// the left edge. The chevron on the command row, the status mark in the gutter, ⌘⇧↑ and the
    /// right-click menu all still fold the block.
    public static func overlayPlacement(commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                                        stripColumns: [OverlayControls: Int],
                                        cols: Int,
                                        fallbackToTail: Bool) -> OverlayPlacement? {
        for row in commandRows.reversed() {
            let free = cols - row.lastUsedColumn - 1
            guard free > 0 else { continue }
            for controls in OverlayControls.allCases {
                guard let width = stripColumns[controls], width > 0, width <= free else { continue }
                return OverlayPlacement(row: row.absoluteRow, controls: controls)
            }
        }
        guard fallbackToTail, let last = commandRows.last, let minimal = stripColumns[.minimal],
              minimal > 0, minimal <= cols else { return nil }
        return OverlayPlacement(row: last.absoluteRow, controls: .minimal)
    }
}

/// How much of the hover strip there is room for on a row.
///
/// The strip is opaque and its content decides its width, so a strip sized only from itself paints
/// over whatever the row already holds: in a 28-column split, hovering `git status --short` covered
/// `--short` and left `~ % git status` on screen -- a different, real command.
///
/// The controls give way in the order of what they are worth. Copy goes first: the ⋯ menu still
/// copies, so nothing becomes unreachable. The summary outlives it because while the strip is up it
/// is the *only* place the exit status is -- the strip suppresses both the Metal summary and the
/// duration note on that row, so dropping it first meant hovering a crowded failed command replaced
/// `exit 1 · 8.8s ▾` with `Copy ⋯ ▾` and the exit code was nowhere on screen. The ⋯ menu and the
/// chevron never go: between them they reach every action the block has.
public enum OverlayControls: Equatable, Hashable, CaseIterable {
    /// Summary, Copy, ⋯, chevron.
    case full
    /// Summary, ⋯, chevron.
    case noCopy
    /// ⋯ and the chevron.
    case minimal

    /// Richest first, which is the order `overlayPlacement` tries them in.
    public static let allCases: [OverlayControls] = [.full, .noCopy, .minimal]
}

/// Which row of a command the hover strip goes on, and which controls it carries there.
public struct OverlayPlacement: Equatable {
    public let row: Int
    public let controls: OverlayControls

    public init(row: Int, controls: OverlayControls) {
        self.row = row; self.controls = controls
    }
}

/// Where a block's summary ended up: which row of the command, which columns, and whether the whole
/// thing fits there or only the chevron does.
public struct SummaryPlacement: Equatable {
    public enum Variant: Equatable {
        /// `exit 1 · 8.8s ▾`.
        case full
        /// The chevron on its own. The decision was "the chevron is always visible", so when a
        /// command line crowds the row it is the status that gives way, not the control.
        case chevronOnly
    }

    /// In whatever space the caller passed its rows in -- absolute rows from the pane, so it can be
    /// mapped back to a display slot through the same map the text went through.
    public let row: Int
    public let columns: Range<Int>
    public let text: Variant

    public init(row: Int, columns: Range<Int>, text: Variant) {
        self.row = row; self.columns = columns; self.text = text
    }
}

/// What can be done to a block, in the order the ⋯ menu lists it.
public enum BlockAction: Equatable {
    case copyCommand, copyOutput, copyMarkdown, saveOutput
    case runAgain, editAndRun
    /// The Request group, offered only on a block whose command was a `curl` -- see
    /// `BlockHeader.isHTTP`. These are the four things you can do to a *request* that mean nothing
    /// for `make test`: open it as a form, take it to another tool, keep it as a button.
    case openInWorkbench, copyAs(ExportFormat), saveAsButton, saveToProject
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
        case .openInWorkbench: return "Open in Workbench\u{2026}"
        // The same names the workbench's own Export menu uses, because they are the same act
        // reached from somewhere else: two words for one thing is two things to learn.
        case .copyAs(let format): return "Copy as \(format.title)"
        case .saveAsButton: return "Save as Button\u{2026}"
        case .saveToProject: return "Save to Project\u{2026}"
        case .toggleFold: return "Fold Output"
        case .toggleFoldAll: return "Fold Everything Long"
        case .notifyWhenDone: return "Notify When Done"
        }
    }

    /// Where a separator goes in the menu: before the first action of each group after the first.
    public var startsGroup: Bool {
        switch self {
        case .runAgain, .openInWorkbench, .toggleFold, .notifyWhenDone: return true
        default: return false
        }
    }
}

/// What colour a block's summary is drawn in, as a meaning rather than as an index.
///
/// One ladder for the three places a summary appears -- the glyphs Metal draws at the end of the
/// command row, the hover strip's label, and the pinned sticky strip's note. Each of them used to
/// pick its own colour from `failed`/`isRunning`, which is three chances to disagree, and the HTTP
/// summary adds a fourth state that none of them would have known about.
public enum SummaryTone: Equatable {
    /// A finished command with nothing remarkable to say -- the duration alone.
    case plain
    /// Still going.
    case running
    /// 2xx.
    case success
    /// 3xx.
    case redirect
    /// A non-zero exit, or a 4xx/5xx.
    case failure

    /// `Palette.readable(n)` rather than `colors[n]`: gruvbox's red is 2.7:1 against its own
    /// background and unreadable as a line of text, and this is text.
    ///
    /// And then `RGB.readable` on top of it, because picking is not enough. `Palette.readable`
    /// chooses between a colour and its bright variant; where *neither* reaches 4.5:1 it hands
    /// back the better of two unreadable colours, and nine of the built-in theme/tone pairs are in
    /// exactly that position -- Solarized Dark's red pair is 3.25:1 and 3.26:1, so a failed
    /// request's `404 · 12 ms` was drawn at 3.25:1, *worse* than the body text around it, on the
    /// one line that exists to be noticed. Lifting towards the theme's own foreground keeps the
    /// hue as far as the floor allows and only moves a colour that could not be read.
    public func color(in palette: Palette) -> RGB {
        let picked: RGB
        switch self {
        case .plain: picked = palette.noteForeground
        case .running, .redirect: picked = palette.readable(3)
        case .success: picked = palette.readable(2)
        case .failure: picked = palette.readable(1)
        }
        return RGB.readable(picked, on: palette.background, towards: palette.foreground)
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
    /// What the block's curl said, when the block was one. nil for everything else, which is almost
    /// every block.
    public let httpSummary: HTTPSummary?
    /// Whether the block's command line was a `curl` -- which is what the Request group in the ⋯
    /// menu turns on.
    ///
    /// Separate from `httpSummary != nil`, and it has to be: a request that could not connect, or
    /// one whose response was too large to read, is still a request you want to open in the
    /// workbench and still has no summary to show. The caller carries the bool because deciding it
    /// costs a `CurlCommand.parse` of a string built from the grid; the pane keeps it beside the
    /// exchange in `RequestSummaryCache` so it is decided once per block rather than once per frame.
    public let isHTTP: Bool

    /// `httpSummary`, when there is one, *replaces* `summary` rather than sitting beside it: a
    /// request's status and latency are what the user ran the command to find out, and two sources
    /// for one string is two ways for the command row, the hover strip and the sticky strip to
    /// disagree about what a block did.
    public init(id: UInt32, state: State, folded: Bool, hasOutput: Bool, anyFolds: Bool,
                notifyArmed: Bool, summary: String, httpSummary: HTTPSummary? = nil,
                isHTTP: Bool = false) {
        self.id = id; self.state = state; self.folded = folded; self.hasOutput = hasOutput
        self.anyFolds = anyFolds; self.notifyArmed = notifyArmed
        self.summary = httpSummary?.text ?? summary
        self.httpSummary = httpSummary
        // A block that produced a response is a request whatever the caller says: the summary could
        // not have been made otherwise, and a menu that disagreed with the row above it would be
        // the pane's cache being wrong in the one place a user can see it.
        self.isHTTP = isHTTP || httpSummary != nil
    }

    /// The colour meaning for this block's summary: the request's, when it made one, and otherwise
    /// what the command's own state says. One property, so the three places that draw a summary
    /// cannot pick three different colours for the same block.
    public var tone: SummaryTone {
        if let httpSummary {
            switch httpSummary.tone {
            case .success: return .success
            case .redirect: return .redirect
            case .failure: return .failure
            }
        }
        if failed { return .failure }
        if isRunning { return .running }
        return .plain
    }

    public var isRunning: Bool { if case .running = state { return true } else { return false } }

    /// Whether this command failed -- the one bit the overlay and the sticky strip both need to
    /// pick a colour, kept here rather than re-derived at each call site so a third one cannot
    /// switch on `state` a different way and disagree.
    public var failed: Bool { if case .failed = state { return true } else { return false } }

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
    ///
    /// The Request group is *absent* on an ordinary block rather than greyed out. A disabled item
    /// says "this could apply here and does not"; "Copy as Python requests" could never apply to
    /// `make test`, and eight dead rows under every menu in the terminal is the kind of chrome that
    /// makes a menu not worth opening.
    public var actions: [(action: BlockAction, enabled: Bool)] {
        var list: [(BlockAction, Bool)] = [
            (.copyCommand, true), (.copyOutput, hasOutput), (.copyMarkdown, true), (.saveOutput, hasOutput),
            (.runAgain, !isRunning), (.editAndRun, !isRunning),
        ]
        if isHTTP {
            list.append((.openInWorkbench, true))
            list += ExportFormat.allCases.map { (.copyAs($0), true) }
            list += [(.saveAsButton, true), (.saveToProject, true)]
        }
        list += [(.toggleFold, hasOutput), (.toggleFoldAll, true)]
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
    ///
    /// `hasOutput` is the caller's -- `Terminal.commandHasOutput(atAbsoluteRow:)`, the one rule the
    /// gutter's actionability and `toggleFold`'s precondition also use. Not `region.outputRows`:
    /// a command whose `C` has arrived but which has printed nothing has output rows and nothing in
    /// them, and a chevron there folds blank lines.
    ///
    /// `httpSummary` defaults to nil because almost no block has one and the caller that does --
    /// the pane, which parses a finished curl's transcript at most once -- is the only one that can
    /// afford to look.
    func header(now: Double, folding: OutputFolding, notifyArmed: Bool, anyFolds: Bool,
                hasOutput: Bool, httpSummary: HTTPSummary? = nil,
                isHTTP: Bool = false) -> BlockHeader {
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
                           hasOutput: hasOutput, anyFolds: anyFolds,
                           notifyArmed: notifyArmed, summary: summary, httpSummary: httpSummary,
                           isHTTP: isHTTP)
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

    /// The same hover with its overlay attached elsewhere, or nowhere.
    ///
    /// The overlay belongs on the row the summary was actually placed on: `SummaryPlacement` can
    /// move it onto a wrapped continuation of the command line, and can refuse a row altogether,
    /// in which case there is no overlay to show and the tint alone marks the block.
    public func attachingHeader(to row: Int?) -> BlockHover {
        BlockHover(id: id, rows: rows, headerRow: row)
    }

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
        guard let slots = DisplayRows.slots(coveredBy: rows, commandID: id, in: display,
                                            viewportTop: viewportTop) else { return nil }
        var headerSlot: Int?
        if let headerRow {
            for (slot, entry) in display.enumerated() {
                guard case .row(let absolute) = entry, absolute - viewportTop == headerRow else { continue }
                headerSlot = slot
                break
            }
        }
        return BlockHover(id: id, rows: slots, headerRow: headerSlot)
    }
}
