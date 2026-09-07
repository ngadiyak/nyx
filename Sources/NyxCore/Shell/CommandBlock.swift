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

public extension CommandBlockChrome {
    /// Free columns after the command's last glyph. W3 ≥ 34, W2 18…33, W1 8…17, W0 < 8 (§2.6).
    enum WidthClass: Equatable { case w3, w2, w1, w0 }

    static func widthClass(freeColumns: Int) -> WidthClass {
        switch freeColumns {
        case 34...: return .w3
        case 18...33: return .w2
        case 8...17: return .w1
        default: return .w0
        }
    }

    /// The last column of a row that has anything in it -- **counting the second half of a wide
    /// glyph**, which has no content of its own. `Renderer.lastUsed` ignores it (D19), and a strip
    /// placed from that count began on top of the 世 it was avoiding.
    static func lastUsedColumn(of row: Row) -> Int {
        var last = -1
        for (column, cell) in row.cells.enumerated()
        where cell.content != 0 || cell.attrs.contains(.wideSpacer) {
            last = column
        }
        return last
    }

    static func freeColumns(cols: Int, lastUsedColumn: Int) -> Int {
        max(0, cols - lastUsedColumn - 1)
    }

    /// One control on the strip. What each one says is here rather than in the view, because a
    /// tooltip that disagrees with a VoiceOver label is two controls with one shape.
    enum Pill: Equatable, Hashable {
        public enum FoldLabel: Equatable, Hashable { case fold, unfold }
        public enum Actions: Equatable, Hashable { case labelled, glyph }
        public enum Glyph: Equatable, Hashable { case ellipsis }
        case fold(FoldLabel)
        /// `enabled` is `BlockHeader.hasOutput`: the pill and the ⋯ menu's `Copy Output` row answer
        /// to one bit. The table gives a block with nothing to copy the no-output row, so no plan
        /// built today carries a disabled Copy -- and if one ever does, it draws as disabled rather
        /// than beeping.
        case copy(enabled: Bool)
        case lens(name: String, on: Bool)
        case stop
        case actions(Actions)

        public var title: String {
            switch self {
            case .fold(.fold): return "Fold"
            case .fold(.unfold): return "Unfold"
            case .copy: return "Copy"
            case .lens(let name, _): return name
            case .stop: return "Stop"
            case .actions(.labelled): return "Actions"
            case .actions(.glyph): return ""
            }
        }

        public var glyph: Glyph? { if case .actions(.glyph) = self { return .ellipsis } else { return nil } }

        /// A `▾` after the title, drawn as an 8 pt path rather than set as a 5 pt text glyph -- the
        /// measured reason the old chevron read as "weak because of size" (design §2.7).
        public var trailingChevron: Bool {
            switch self {
            case .actions(.labelled), .lens: return true
            default: return false
            }
        }

        public var help: String {
            switch self {
            case .fold(.fold): return "Fold this command\u{2019}s output"
            case .fold(.unfold): return "Unfold this command\u{2019}s output"
            case .copy: return "Copy this command\u{2019}s output"
            case .lens: return "Choose how this response is shown"
            case .stop: return "Stop watching this request"
            case .actions: return "Command actions"
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .lens(let name, let on): return on ? "Response lens: \(name)" : "Show this response as \(name)"
            case .actions: return "Command actions"
            // "Stop" alone collides with ⌘.'s differently-scoped Stop (a11y 6.9): VoiceOver has to
            // hear what this one stops.
            case .stop: return help
            default: return title
            }
        }
    }

    /// What is on the strip, before anyone knows where it goes.
    struct StripContent: Equatable {
        public let readout: String
        public let readoutTone: SummaryTone
        public let dots: [WatchSeries.Dot]
        public let overflowDot: String?
        public let pills: [Pill]
        public init(readout: String, readoutTone: SummaryTone, dots: [WatchSeries.Dot],
                    overflowDot: String?, pills: [Pill]) {
            self.readout = readout; self.readoutTone = readoutTone; self.dots = dots
            self.overflowDot = overflowDot; self.pills = pills
        }
    }

    /// That content, placed: which column it begins at and whether it is allowed to sit on the
    /// command's own text.
    struct StripPlan: Equatable {
        public let content: StripContent
        public let firstColumn: Int
        public let overlapsCommand: Bool
        public init(content: StripContent, firstColumn: Int, overlapsCommand: Bool) {
            self.content = content; self.firstColumn = firstColumn; self.overlapsCommand = overlapsCommand
        }
        public var readout: String { content.readout }
        public var readoutTone: SummaryTone { content.readoutTone }
        public var dots: [WatchSeries.Dot] { content.dots }
        public var overflowDot: String? { content.overflowDot }
        public var pills: [Pill] { content.pills }
    }

    struct StripPlacement: Equatable {
        public let row: Int
        public let plan: StripPlan
        public init(row: Int, plan: StripPlan) { self.row = row; self.plan = plan }
    }

    /// The pills, per §2.6's table -- which wins over any single "richest control survives
    /// longest" sentence: `Fold` is already gone at the W3→W2 boundary, a labelled duplicate of the
    /// control the gutter cap already offers, while `Copy` (or the lens chip, or `Unfold`) can
    /// still be on the row; `Actions ▾` only collapses to `⋯` at the later W2→W1 boundary, where
    /// every pill but `Stop` goes. `Stop` and `Actions` are present at every width.
    ///
    /// A watched block takes `Stop` and never the lens chip: the two would share the one rung under
    /// Actions, and the lens stays in the ⋯ menu (§3.13). A watched block shows no fold pill
    /// either -- §2.6's two watch rows have none, because a series' newest run is the thing being
    /// read.
    static func pills(_ header: BlockHeader, at width: WidthClass) -> [Pill] {
        let watching = header.watch?.showsStop == true
        let watched = header.watch != nil
        let lensable = header.isHTTP && !header.lensTooLarge && (header.bodyIsJSON || header.lens != nil)
        // W0 is the row that costs a column of the user's own text, so only the one control with a
        // running side effect earns it.
        guard width != .w0 else { return watching ? [.stop] : [] }
        guard width != .w1 else { return watching ? [.stop, .actions(.glyph)] : [.actions(.glyph)] }

        // The rung under Actions: whichever of Stop, the lens chip and Unfold applies, and Copy
        // when none does. At W3 the rest of the ladder is added below it.
        var list: [Pill] = []
        if watching {
            list.append(.stop)
        } else if !watched, lensable {
            list.append(.lens(name: (header.lens ?? .pretty).chipTitle, on: header.lens != nil))
        } else if header.folded, header.hasOutput {
            list.append(.fold(.unfold))
        }
        if width == .w3 {
            // Fold is the widest labelled duplicate of a control the gutter already offers, so it
            // is the first pill to go; a folded block already carries `Unfold` above.
            if header.hasOutput, !watched, !header.folded { list.append(.fold(.fold)) }
            if header.hasOutput { list.append(.copy(enabled: header.hasOutput)) }
        } else if list.isEmpty, header.hasOutput, !watched {
            // W2 with no Stop, no chip and nothing folded: Copy is what the rung carries.
            list.append(.copy(enabled: header.hasOutput))
        }
        list.append(.actions(.labelled))
        return list
    }

    /// The readout, longest first: the whole sentence → drop the interval and the percentiles →
    /// drop the timing and the size → drop the run count → **the status or exit code alone, never
    /// dropped while a strip is drawn at all**.
    ///
    /// Dropping only ever removes whole ` · ` groups: §1 protects the vocabulary, so the sentence
    /// is cut, never re-worded. The one non-positional rule is a finished series' failure count --
    /// `11 runs` on its own says a series went fine, which is the sentence's whole news.
    static func readout(_ header: BlockHeader, at width: WidthClass) -> String {
        switch width {
        // W3 and W0 never split the sentence, so they never pay for `components(separatedBy:)`.
        case .w3: return header.summary
        case .w2:
            let parts = header.summary.components(separatedBy: " \u{b7} ")
            if parts.count > 2, let first = parts.first, let last = parts.last, isFailureCount(last) {
                return first + " \u{b7} " + last
            }
            return parts.prefix(2).joined(separator: " \u{b7} ")
        case .w1: return header.summary.components(separatedBy: " \u{b7} ").first ?? ""
        case .w0: return ""
        }
    }

    private static func isFailureCount(_ part: String) -> Bool {
        part.hasSuffix(" failure") || part.hasSuffix(" failures")
    }

    static func stripContent(_ header: BlockHeader, at width: WidthClass) -> StripContent? {
        let list = pills(header, at: width)
        guard !list.isEmpty else { return nil }
        // Thirty circles is the widest thing on the strip and the least of what it says, so the
        // timeline goes at the first squeeze -- the sentence beside it still carries the run number
        // and the last status.
        let dots = width == .w3 ? (header.watch?.dots ?? []) : []
        let hidden = width == .w3 ? (header.watch?.hiddenRuns ?? 0) : 0
        // `+N` *replaces* the leading dot rather than joining it: thirty circles and a `+18` beside
        // them would be thirty-one marks in the space the spec draws thirty.
        let visibleDots = hidden > 0 ? Array(dots.dropFirst()) : dots
        return StripContent(readout: readout(header, at: width), readoutTone: header.tone,
                            dots: visibleDots, overflowDot: hidden > 0 ? "+\(hidden)" : nil, pills: list)
    }

    /// Where a measured strip begins, or nil when it may not be drawn on this row at all.
    static func stripPlan(_ content: StripContent, widthClass: WidthClass,
                          lastUsedColumn: Int, cols: Int, stripColumns: Int) -> StripPlan? {
        guard stripColumns > 0, stripColumns <= cols else { return nil }
        let first = cols - stripColumns
        // The only content W0 ever produces is the lone Stop, and stopping a runaway watch must
        // always be one click: it is drawn over the command's tail on an opaque pill.
        let overlaps = widthClass == .w0
        guard overlaps || first > lastUsedColumn else { return nil }
        // `first` is already `>= 0`: the guard above requires `stripColumns <= cols`.
        return StripPlan(content: content, firstColumn: first, overlapsCommand: overlaps)
    }

    /// Whether the strip on `stripRow` speaks for the summary that would have gone on
    /// `summaryRow`, and may therefore replace it.
    ///
    /// Two rows of a wrapped command are two different width classes: a watched `curl` whose last
    /// row is full places its lone `Stop` there (W0, no readout at all) while the summary belongs
    /// on the roomier row above. Suppressing on "a strip exists somewhere on this block" then took
    /// `run 12 · 200 · 100 ms · every 5 s` off the screen the moment the pointer arrived -- the
    /// exact defect §2.5 exists to end. So: the same row, and something to say.
    static func suppressesSummary(_ plan: StripPlan, stripRow: Int, summaryRow: Int?) -> Bool {
        !plan.readout.isEmpty && stripRow == summaryRow
    }

    /// Which row of the command carries the strip, walked from the last upwards -- the same ladder
    /// and the same rows the summary uses, because a wrapped `curl` fills its first rows and leaves
    /// room on its last. `measure` is the view's own width for that content, in columns.
    static func stripPlacement(_ header: BlockHeader,
                               commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                               cols: Int,
                               measure: (StripContent) -> Int) -> StripPlacement? {
        for row in commandRows.reversed() {
            let width = widthClass(freeColumns: freeColumns(cols: cols, lastUsedColumn: row.lastUsedColumn))
            guard let content = stripContent(header, at: width),
                  let plan = stripPlan(content, widthClass: width, lastUsedColumn: row.lastUsedColumn,
                                       cols: cols, stripColumns: measure(content)) else { continue }
            return StripPlacement(row: row.absoluteRow, plan: plan)
        }
        return nil
    }

    /// The mark at the head of the spine: what shape it is, what colour, and whether it can be
    /// pressed. Shape rather than colour alone, because colour is the one thing a mark cannot say
    /// on its own (a11y 6.2).
    struct GutterCap: Equatable {
        public enum Shape: Equatable {
            /// A rounded capsule inset from the row's top and bottom: the command succeeded.
            case solid
            /// The full row height, square ends, so failures join up down a scrolling screen and
            /// carry more ink than successes -- the state that has to be findable. Task 2 draws
            /// this as the cap plus a full-row bar down the spine, both from this one shape.
            case bar
            /// A stroked capsule: still running.
            case hollow
            /// `solid` at 40 % and not pressable: a command that printed nothing to fold.
            case faded
            case chevronDown, chevronRight
        }
        public let shape: Shape
        public let tone: SummaryTone
        public let isPressable: Bool
        public init(shape: Shape, tone: SummaryTone, isPressable: Bool) {
            self.shape = shape; self.tone = tone; self.isPressable = isPressable
        }
    }

    static func gutterCap(_ header: BlockHeader, hasStarted: Bool, hovered: Bool) -> GutterCap? {
        // The prompt you are typing at carries a prompt mark and no status. Nothing is drawn there:
        // a mark that appeared the instant you pressed return would be a spinner, and the gutter is
        // a record.
        guard hasStarted else { return nil }
        // The command's own outcome, not the response's: a `curl` that reported 404 exited 0, and
        // the gutter says what the command did. The strip's tone is where a 404 goes red.
        let tone: SummaryTone = header.failed ? .failure : (header.isRunning ? .running : .success)
        // Shape from state first, `hasOutput` second: a failure or a still-running command is news
        // whether or not it has printed anything yet, and erasing `.bar`/`.hollow` in favour of a
        // blanket `.faded` the moment output is empty drew a `sleep 10` one second in -- and any
        // failure with no output -- as a quiet record rather than what it is. The 40 % `faded`
        // treatment, and the loss of pressability, belong only to a block that has *finished*
        // cleanly with nothing to fold.
        guard header.hasOutput else {
            if header.failed { return GutterCap(shape: .bar, tone: tone, isPressable: false) }
            if header.isRunning { return GutterCap(shape: .hollow, tone: tone, isPressable: false) }
            return GutterCap(shape: .faded, tone: tone, isPressable: false)
        }
        if hovered {
            return GutterCap(shape: header.folded ? .chevronRight : .chevronDown, tone: tone,
                             isPressable: true)
        }
        if header.failed { return GutterCap(shape: .bar, tone: tone, isPressable: true) }
        if header.isRunning { return GutterCap(shape: .hollow, tone: tone, isPressable: true) }
        return GutterCap(shape: .solid, tone: tone, isPressable: true)
    }

    /// The mark and the spine are one shape: the renderer and the gutter view read these two
    /// numbers, so the Metal spine and the AppKit cap cannot drift apart.
    /// **Replaces `CommandBlock.swift:111-112`**, which declared `spineWidth: Double = 2` beside a
    /// `spineGap: Double = 4` that the renderer never read (it computed `padding - 3` by hand).
    /// `spineGap` is deleted outright: it has no callers, and `spineLeadingInset` is the number the
    /// gap was standing in for.
    static let spineWidth: Double = 3
    /// 4 pt at the shipping `padding = 8`, which is outside the window's resize margin; 0 at
    /// `padding = 0`, where the mark draws over the first text column's leading 3 pt rather than
    /// off the window (Addendum 2).
    static func spineLeadingInset(padding: Double) -> Double { min(4, max(0, padding - 3)) }

    /// Which of a block's placed rows the *spine* is drawn on: everything below the row the cap
    /// owns. `placed` is the block's rows as display slots, `headOnScreen` is
    /// `CommandBlock.showsHeader`.
    ///
    /// The cap and the spine are deliberately the same colour, the same 3 pt width and at the same
    /// x, which is the whole point of `spineWidth` and `spineLeadingInset` -- and it means a spine
    /// painted over the prompt row fills in `.hollow`'s ring and paints through `.faded`'s 40 %.
    /// Both then read as a solid bar, and the *shape* that carries the state (§2.2, a11y 6.2)
    /// survives only in the isolated view. So the prompt row is the cap's alone: a `.bar` failure
    /// still shows a full-row mark there, because the cap draws that itself.
    ///
    /// With the prompt row scrolled off the top there is no cap on screen, so the first visible row
    /// is ordinary output and keeps its spine -- a block must not lose its left edge exactly when it
    /// is long enough to need one.
    static func spineRows(placed: Range<Int>, headOnScreen: Bool) -> Range<Int>? {
        let start = headOnScreen ? placed.lowerBound + 1 : placed.lowerBound
        guard start < placed.upperBound else { return nil }
        return start..<placed.upperBound
    }
    /// Every row-height *hit* target, clamped so `line-height = 0.8` cannot make it 13 pt (§8.4).
    /// The *drawn* mark stays `cellHeight` tall.
    static func hitRowHeight(cellHeight: Double) -> Double { max(cellHeight, 16) }
    static let stripHeight: Double = 20
    /// The strip's frame: tall enough for its pills and never below the hit floor. Decided here
    /// rather than from `stack.fittingSize`, which is what `Pane.blockHeaderChanged` used.
    static func stripFrameHeight(cellHeight: Double) -> Double {
        max(stripHeight, hitRowHeight(cellHeight: cellHeight))
    }
    /// What the strip actually *paints*: one row, whatever its frame is. A 20 pt opaque band on a
    /// 13 pt grid covers three rows of somebody's output (Addendum 2).
    static func stripGroundHeight(cellHeight: Double) -> Double { cellHeight }
    /// Column 0's fold triangle, widened to the same 20 pt the gutter uses, for the same reason.
    static let foldColumnWidth: Double = 20
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
/// `exit 1 · 8.8s ▾` with `Copy ⋯ ▾` and the exit code was nowhere on screen. The ⋯ menu, the
/// chevron and a running watch's **Stop** never go: the first two reach every action the block has,
/// and Stop is the one control on the strip with a running side effect. Which parts each level
/// carries is `BlockHeader.showsCopy(at:)` and its neighbours.
public enum OverlayControls: Equatable, Hashable, CaseIterable {
    /// Summary, Copy, ⋯, chevron.
    case full
    /// Summary, ⋯, chevron.
    case noCopy
    /// ⋯, the chevron, and Stop if a watch is running.
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
    /// The Lens group, on the same blocks. `setLens` carries the lens the row stands for -- an
    /// empty `filter`/`grep` string means "open the field", and the id in `diff` is a placeholder
    /// the pane fills in from its own cache, which is the only thing that knows which run came
    /// before this one.
    case setLens(ResponseLens), toggleLens, copyBody, copyHeaders
    /// Start this request again on a schedule. `runEvery` is the one-click form -- the configured
    /// interval, running until stopped -- and `watch` opens the popover on the plan it carries, so
    /// the menu row is built from the same default the popover then shows.
    ///
    /// The plan on `watch` is a *seed*, not the plan that will run: a menu built when nobody has
    /// filled the form in yet cannot carry the answer to it, and a case that pretended to would be
    /// a row that starts a watch the user never described.
    case runEvery(seconds: Double), watch(WatchPlan)
    /// Offered in place of the two above while this block's series is still going.
    case stopWatch
    /// What the Lens group becomes when the body is too large to re-lay-out: one row that says so
    /// and still does the thing that works. A case of its own rather than a second `.saveOutput`,
    /// because a menu row's title and its group break are properties of the action, and the two
    /// occurrences would have had to share them.
    case lensUnavailable
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
        // The lens names itself: the menu row, the `⌘⇧J` menu item and the palette row are the
        // same words for the same thing.
        case .setLens(let lens): return lens.title
        case .toggleLens: return "Toggle Pretty Response"
        case .copyBody: return "Copy Body"
        case .copyHeaders: return "Copy Headers"
        // The same words the header's own tail will then show ("every 5 s"), so the row a user
        // pressed and the sentence they end up reading are one plan described once.
        case .runEvery(let seconds): return "Run Every \(WatchPlan.secondsText(seconds)) s"
        case .watch: return "Watch\u{2026}"
        // The same title as the `stop_watch` action in the palette and the menu bar.
        case .stopWatch: return "Stop Watching"
        case .lensUnavailable: return "Body too large for lenses \u{2014} Save Output\u{2026}"
        case .toggleFold: return "Fold Output"
        case .toggleFoldAll: return "Fold Everything Long"
        case .notifyWhenDone: return "Notify When Done"
        }
    }

    /// Where a separator goes in the menu: before the first action of each group after the first.
    public var startsGroup: Bool {
        switch self {
        case .runAgain, .openInWorkbench, .toggleFold, .notifyWhenDone, .lensUnavailable: return true
        case .setLens(.raw): return true
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
    /// Which lens this block's response is being read through. nil is raw -- the rows as the
    /// terminal has them -- which is what every block starts as and what most stay as.
    public let lens: ResponseLens?
    /// The body is past `LensRendering`'s limits, so there is nothing to show through a lens and
    /// the group says so instead of offering seven rows that would each do nothing.
    public let lensTooLarge: Bool
    /// Whether the response body is JSON. The `{ }` control promises pretty JSON and nothing else,
    /// so this is what decides whether it is offered -- see `showsLens(at:)`.
    public let bodyIsJSON: Bool
    /// Whether an earlier block ran the same request. Only `Diff with Previous Run` needs it, and
    /// only the pane's cache can answer it -- see `RequestSummaryCache.previousRun`.
    ///
    /// `var` because it is answered *late*: finding the previous run parses every cached command
    /// line, which is right once on a menu press and wrong sixty times a second, so the header the
    /// frame builds leaves it false and whoever opens a menu fills it in. Left as a `let`, the row
    /// was greyed on every hover strip whatever the pane knew, and the feature read as unbuilt.
    public var hasPreviousRun: Bool
    /// The watch series this block is the newest run of, or nil -- which is every block in every
    /// pane where nobody has asked for one. Only the *newest* run carries it: the older runs of a
    /// series are ordinary finished requests, and a timeline drawn beside each of them would be the
    /// same twenty dots twenty times down the screen.
    public let watch: WatchHeader?
    /// What `Run Every … s` offers, from `http-watch-interval`. Carried rather than defaulted at
    /// the menu, so the row, the popover it sits beside and the settings window cannot name three
    /// different intervals.
    public let watchInterval: Double

    /// `httpSummary`, when there is one, *replaces* `summary` rather than sitting beside it: a
    /// request's status and latency are what the user ran the command to find out, and two sources
    /// for one string is two ways for the command row, the hover strip and the sticky strip to
    /// disagree about what a block did.
    public init(id: UInt32, state: State, folded: Bool, hasOutput: Bool, anyFolds: Bool,
                notifyArmed: Bool, summary: String, httpSummary: HTTPSummary? = nil,
                isHTTP: Bool = false, lens: ResponseLens? = nil, lensTooLarge: Bool = false,
                bodyIsJSON: Bool = false, hasPreviousRun: Bool = false, watch: WatchHeader? = nil,
                watchInterval: Double = 5) {
        self.id = id; self.state = state; self.folded = folded; self.hasOutput = hasOutput
        self.anyFolds = anyFolds; self.notifyArmed = notifyArmed
        self.lens = lens; self.lensTooLarge = lensTooLarge; self.bodyIsJSON = bodyIsJSON
        self.hasPreviousRun = hasPreviousRun
        self.watch = watch; self.watchInterval = watchInterval
        // And a watch's own sentence replaces the request's, for the same reason: `200 · 142 ms`
        // is already inside `run 12 · 200 · 142 ms · every 5 s`, and showing both puts the status
        // on the row twice.
        self.summary = watch?.text ?? httpSummary?.text ?? summary
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
        // A watch's sentence describes the series, not its latest run: `11 runs · p50 150 ms ·
        // p95 200 ms · 1 failure` drawn in success green is a sentence whose last three words say
        // something failed.
        if let watch { return watch.tone }
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

    // MARK: - What the hover strip carries
    //
    // One place, because two of them come apart. `BlockHeaderView` both *draws* the strip and
    // *measures* it for `overlayPlacement`, and when the two lists disagreed the placement rule
    // reserved room for a control that was not drawn, or drew one it had not reserved room for.

    /// Copy is the first control dropped: the ⋯ menu still copies, so nothing becomes unreachable.
    public func showsCopy(at controls: OverlayControls) -> Bool { controls == .full }

    /// The summary outlives Copy, because while the strip is up it is the *only* place the exit
    /// status is -- it suppresses both the drawn summary and the duration note on that row.
    public func showsSummary(at controls: OverlayControls) -> Bool {
        controls != .minimal && !summary.isEmpty
    }

    /// The timeline goes with Copy: thirty circles is the widest thing here and the least of what
    /// the header says, since the sentence beside it already carries the run number and the last
    /// status.
    public func showsTimeline(at controls: OverlayControls) -> Bool {
        controls == .full && !(watch?.dots.isEmpty ?? true)
    }

    /// **Stop is never dropped.** It is the only control on the strip with a running side effect,
    /// and a watch you cannot stop from the strip is the one that matters most -- on a command line
    /// crowded enough for the narrowest strip, the ⋯ menu is the only other way to reach it.
    public func showsStop(at controls: OverlayControls) -> Bool { watch?.showsStop ?? false }

    /// The `{ }` needs a request, a body a lens can do something with, JSON to pretty-print, and
    /// room for more than the two controls every block has.
    ///
    /// The JSON clause is the point: on a 301 with an HTML body `.pretty` falls through to the raw
    /// lines, so a button whose tooltip promises pretty JSON did nothing a user could see. A lens
    /// already open keeps its control whatever the body is -- the button is also how it is turned
    /// off, and a control that vanishes when pressed strands the reader inside a lens.
    public func showsLens(at controls: OverlayControls) -> Bool {
        guard isHTTP, !lensTooLarge, controls != .minimal else { return false }
        return bodyIsJSON || lens != nil
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
            // One row or two, never all three: while a series is running the only thing anyone
            // wants from this block is to stop it, and offering "Run Every 5 s" beside a watch
            // already running is two ways to start a second one.
            if watch?.showsStop == true {
                list.append((.stopWatch, true))
            } else {
                list += [(.runEvery(seconds: watchInterval), true),
                         (.watch(WatchPlan(interval: watchInterval, stop: .never)), true)]
            }
            if lensTooLarge {
                list.append((.lensUnavailable, hasOutput))
            } else {
                list += [(.setLens(.raw), true), (.setLens(.pretty), true),
                         (.setLens(.headers), true), (.setLens(.body), true),
                         (.setLens(.filter("")), true), (.setLens(.grep("")), true),
                         // The id is filled in by whoever performs it; what this row carries is
                         // "diff", and whether it can be pressed at all.
                         (.setLens(.diff(previousCommandID: 0)), hasPreviousRun),
                         (.copyBody, true), (.copyHeaders, true)]
            }
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

    /// Whether a menu row should carry a checkmark. The lens rows are a radio group -- one of them
    /// is what you are looking at -- and `Raw` is ticked when no lens is set, because raw is not
    /// the absence of a choice, it is one of the choices.
    ///
    /// A filter or a find is ticked by its *kind*: the row opens the field, and `Filter…` with
    /// `.a.b` in it is still the filter row. Titles are unique per case, which is why they are what
    /// is compared -- a `case` match would have to spell out the payload it is deliberately
    /// ignoring.
    public func isChecked(_ action: BlockAction) -> Bool {
        switch action {
        case .setLens(let candidate): return (lens ?? .raw).title == candidate.title
        case .notifyWhenDone(let armed): return armed
        default: return false
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
                isHTTP: Bool = false, lens: ResponseLens? = nil, lensTooLarge: Bool = false,
                bodyIsJSON: Bool = false, hasPreviousRun: Bool = false, watch: WatchHeader? = nil,
                watchInterval: Double = 5) -> BlockHeader {
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
                           isHTTP: isHTTP, lens: lens, lensTooLarge: lensTooLarge,
                           bodyIsJSON: bodyIsJSON, hasPreviousRun: hasPreviousRun, watch: watch,
                           watchInterval: watchInterval)
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
