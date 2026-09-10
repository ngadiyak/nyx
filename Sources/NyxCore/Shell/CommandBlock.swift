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

    /// Which row of a command carries its summary, and which columns.
    ///
    /// `summaryColumns` alone answers "does the whole thing fit on this row", and the answer for a
    /// realistic pasted `curl` in a 100-column pane -- or for any narrow split -- is no. So this
    /// walks the command's rows from the last to the first (a wrapped command line has several, and
    /// the last is usually the shortest) and takes the first with room for the whole sentence.
    ///
    /// It used to fall back to a row with room for the chevron alone, because the chevron was the
    /// only thing on that row that folded the block. It no longer folds anything -- the gutter cap
    /// does, at every width, and it costs no columns -- so a row with no room for the whole summary
    /// simply carries none, and the reader loses a nicety rather than a control (§2.4).
    ///
    /// Placing it is one rule for the same reason `summaryColumns` is: the renderer draws it and the
    /// strip's suppression rule compares against it. Two call sites deciding separately is two ways
    /// for the pixels and the strip to disagree -- and the overlay placed from the prompt row alone
    /// painted over the command's own text on exactly the rows where the summary had been refused.
    public static func summaryPlacement(commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                                        textCount: Int, cols: Int) -> SummaryPlacement? {
        for row in commandRows.reversed() {
            if let columns = summaryColumns(textCount: textCount, cols: cols,
                                            lastUsedColumn: row.lastUsedColumn) {
                return SummaryPlacement(row: row.absoluteRow, columns: columns)
            }
        }
        return nil
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
            // The chip is a state readout, not a suggestion -- `name` already names *this*
            // response's current lens (`Raw` when there is none), on or off, so the label says
            // what is showing and that the `▾` opens a menu rather than performing an action.
            case .lens(let name, _): return "Response shown as \(name); opens a menu"
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

    /// That content, placed: which columns it occupies and whether it is allowed to sit on the
    /// command's own text.
    struct StripPlan: Equatable {
        public let content: StripContent
        public let firstColumn: Int
        /// One past the strip's last column. The pane's own right edge for every rung but one: a
        /// **pills-only** strip is right-aligned against the *in-grid summary's* first column
        /// instead, because that rung exists to keep the summary and drawing to the pane's edge
        /// would put the pills on top of the sentence they were kept for.
        public let trailingColumn: Int
        public let overlapsCommand: Bool
        public init(content: StripContent, firstColumn: Int, trailingColumn: Int = -1,
                    overlapsCommand: Bool) {
            self.content = content
            self.firstColumn = firstColumn
            // -1 means "not said": the offscreen snapshots build a plan by hand at column 0 and
            // size the view from the content, so there is nothing sensible for them to pass.
            self.trailingColumn = trailingColumn
            self.overlapsCommand = overlapsCommand
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
    ///
    /// Two rungs of the order were ruled on after the first picture set (F4), and §2.6's two
    /// affected rows and its drop-order sentence were edited with them:
    ///
    /// - **On an HTTP block the chip outlives `Fold` and `Copy`.** It is the lens's only visible
    ///   state -- what the response is being read *as* -- and `Copy Output` is a row of the ⋯ menu.
    ///   Dropping it first meant the chip appeared in no composite of the whole set: a pasted `curl`
    ///   is long, so the strip a person actually gets is a rung or two below W3.
    /// - **On a watched block the dots outlive `Copy`.** The timeline is the series' whole shape and
    ///   there is a second route to the pasteboard; there is no second picture of eleven runs.
    static func pills(_ header: BlockHeader, at width: WidthClass) -> [Pill] {
        let watching = header.watch?.showsStop == true
        let watched = header.watch != nil
        let lensable = header.isHTTP && !header.lensTooLarge && (header.bodyIsJSON || header.lens != nil)
        // W0 is the row that costs a column of the user's own text, so only the one control with a
        // running side effect earns it -- not even the chip, which says something rather than doing
        // it.
        guard width != .w0 else { return watching ? [.stop] : [] }
        guard width != .w1 else {
            if watching { return [.stop, .actions(.glyph)] }
            if !watched, lensable {
                return [.lens(name: (header.lens ?? .raw).chipTitle, on: header.lens != nil),
                        .actions(.glyph)]
            }
            return [.actions(.glyph)]
        }

        // The rung under Actions: whichever of Stop, the lens chip and Unfold applies, and Copy
        // when none does. At W3 the rest of the ladder is added below it.
        var list: [Pill] = []
        if watching {
            list.append(.stop)
        } else if !watched, lensable {
            // The chip is a state readout, not a suggestion: `nil` is the response showing raw, so
            // the chip reads `Raw` unlit rather than naming the lens pressing it would switch to.
            list.append(.lens(name: (header.lens ?? .raw).chipTitle, on: header.lens != nil))
        } else if header.folded, header.hasOutput {
            list.append(.fold(.unfold))
        }
        if width == .w3 {
            // Fold is the widest labelled duplicate of a control the gutter already offers, so it
            // is the first pill to go; a folded block already carries `Unfold` above.
            if header.hasOutput, !watched, !header.folded { list.append(.fold(.fold)) }
            // `!watched`: the dots outlive `Copy`, and the dots are a W3-only feature, so a watched
            // block has no rung anywhere that carries `Copy` without them.
            if header.hasOutput, !watched { list.append(.copy(enabled: header.hasOutput)) }
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
    ///
    /// `rightEdge` is where the strip's last column is, exclusive; the pane's own edge unless the
    /// caller is placing a pills-only strip in the gap an in-grid summary leaves.
    static func stripPlan(_ content: StripContent, widthClass: WidthClass,
                          lastUsedColumn: Int, cols: Int, stripColumns: Int,
                          rightEdge: Int? = nil) -> StripPlan? {
        let edge = rightEdge ?? cols
        guard stripColumns > 0, stripColumns <= edge, edge <= cols else { return nil }
        let first = edge - stripColumns
        // The only content W0 ever produces is the lone Stop, and stopping a runaway watch must
        // always be one click: it is drawn over the command's tail on an opaque pill.
        let overlaps = widthClass == .w0
        guard overlaps || first > lastUsedColumn else { return nil }
        // `first` is already `>= 0`: the guard above requires `stripColumns <= edge`.
        return StripPlan(content: content, firstColumn: first, trailingColumn: edge,
                         overlapsCommand: overlaps)
    }

    /// Where the in-grid summary is going and what it says there. Always the whole sentence:
    /// `summaryPlacement` refuses a row rather than shortening what is on it (§2.4).
    typealias PlacedSummary = (row: Int, text: String)

    /// Whether the strip on `stripRow` speaks for the summary on `summary.row`, and may therefore
    /// replace it. Two conditions, and the second is the law of §2.5: **the same row, and the
    /// same words**.
    ///
    /// Two rows of a wrapped command are two different width classes: a watched `curl` whose last
    /// row is full places its lone `Stop` there (W0, no readout at all) while the summary belongs
    /// on the roomier row above. Suppressing on "a strip exists somewhere on this block" took
    /// `run 12 · 200 · 100 ms · every 5 s` off the screen the moment the pointer arrived.
    ///
    /// "Something to say" is not enough either. A W2 or W1 readout is a *shortened* sentence, so a
    /// strip that replaced the summary with one silently dropped `· 1.2 KB · json` -- the same
    /// defect one class further down. Hovering must never remove a fact, so the readout has to be
    /// the summary word for word; `stripPlacement` is what makes that reachable, by refusing to
    /// shorten the sentence on a row that is already showing it.
    static func suppressesSummary(_ plan: StripPlan, stripRow: Int,
                                  summary: PlacedSummary?) -> Bool {
        guard let summary, summary.row == stripRow, !summary.text.isEmpty else { return false }
        return plan.readout == summary.text
    }

    static func stripPlacement(_ header: BlockHeader,
                               commandRows: [(absoluteRow: Int, lastUsedColumn: Int)],
                               cols: Int,
                               summary: PlacedSummary?,
                               measure: (StripContent) -> Int) -> StripPlacement? {
        for row in commandRows.reversed() {
            let free = freeColumns(cols: cols, lastUsedColumn: row.lastUsedColumn)
            for (width, rung) in rungs(header, freeColumns: free) {
                var content = rung
                // On the row that is already showing the sentence, the readout ladder stops at the
                // sentence: it is the *pills* that keep giving way. A shortened readout on such a
                // row is the strip removing a fact the moment the pointer arrives (§2.5).
                if let summary, summary.row == row.absoluteRow, !summary.text.isEmpty,
                   content.readout != summary.text {
                    content = StripContent(readout: summary.text, readoutTone: content.readoutTone,
                                           dots: content.dots, overflowDot: content.overflowDot,
                                           pills: content.pills)
                }
                guard let plan = stripPlan(content, widthClass: width,
                                           lastUsedColumn: row.lastUsedColumn,
                                           cols: cols, stripColumns: measure(content)) else { continue }
                return StripPlacement(row: row.absoluteRow, plan: plan)
            }
        }
        // Nothing above fitted, so the sentence is what gives way -- never a pill. The strip carries
        // the **pills alone**, right-aligned against the in-grid summary's own first column so the
        // sentence it is making room for stays exactly where it was: nothing on the row moves when
        // the pointer arrives, controls simply appear in the gap. Refusing the row instead is what
        // left a running watch with no `Stop` anywhere across a wide middle band of command-line
        // lengths, and §2.6 says `Stop` and `Actions` are present at *every* width.
        for row in commandRows.reversed() {
            let free = freeColumns(cols: cols, lastUsedColumn: row.lastUsedColumn)
            let edge = rightEdge(cols: cols, row: row, summary: summary)
            for (width, rung) in rungs(header, freeColumns: free) {
                // Dots go with the sentence: they are the readout's own picture, and a timeline
                // with no run number beside it says less than nothing.
                let pillsOnly = StripContent(readout: "", readoutTone: rung.readoutTone,
                                             dots: [], overflowDot: nil, pills: rung.pills)
                guard let plan = stripPlan(pillsOnly, widthClass: width,
                                           lastUsedColumn: row.lastUsedColumn, cols: cols,
                                           stripColumns: measure(pillsOnly),
                                           rightEdge: edge) else { continue }
                return StripPlacement(row: row.absoluteRow, plan: plan)
            }
        }
        // And when even two pills will not fit beside the sentence: the one control with a running
        // side effect, over the command's tail on an opaque pill. This is §2.3's W0 exception
        // granted at any width, and only ever to `Stop` -- `pills(_:at: .w0)` is empty for
        // everything else, so nothing but a running watch can reach here and no finished block
        // ever spends a column of somebody's command on a control it could do without.
        for row in commandRows.reversed() {
            guard let content = stripContent(header, at: .w0),
                  let plan = stripPlan(content, widthClass: .w0,
                                       lastUsedColumn: row.lastUsedColumn, cols: cols,
                                       stripColumns: measure(content),
                                       // Against the summary's first column here too, for the same
                                       // reason: it is the *command's* tail this pill is allowed to
                                       // sit on. Placed at the pane's edge it covered the tail of
                                       // `run 12 · 200 · 100 ms · every 5 s` instead, which is the
                                       // one thing §2.5 forbids -- the first take of the pictures
                                       // read `run 12 · 200 · 100 ms · ev` with a Stop on top.
                                       rightEdge: rightEdge(cols: cols, row: row,
                                                            summary: summary)) else { continue }
            return StripPlacement(row: row.absoluteRow, plan: plan)
        }
        return nil
    }

    /// Where a strip's last column is, exclusive, on this row: the in-grid summary's first column
    /// when the summary is on it, the pane's own edge otherwise.
    private static func rightEdge(cols: Int, row: (absoluteRow: Int, lastUsedColumn: Int),
                                  summary: PlacedSummary?) -> Int {
        guard let summary, summary.row == row.absoluteRow, !summary.text.isEmpty,
              let columns = summaryColumns(textCount: summary.text.count, cols: cols,
                                           lastUsedColumn: row.lastUsedColumn)
        else { return cols }
        return columns.lowerBound
    }

    /// Every rung a row of this class may fall back to, richest first, paired with the width class
    /// each one is placed as.
    ///
    /// The classes' own contents, and then one more: the two pills §2.6 never drops -- `Stop` while
    /// a watch is running, and `Actions`, collapsed to the glyph -- carrying the narrowest readout.
    /// That rung exists because the drop order keeps `Actions` *longer* than the lens chip, so an
    /// HTTP row with no room for `[Pretty ▾] [⋯]` still gets its `⋯` and keeps the route to every
    /// action rather than losing the strip altogether. Not offered to a W0 row: there the only thing
    /// that may cost a column of somebody's command is `Stop`.
    private static func rungs(_ header: BlockHeader,
                              freeColumns free: Int) -> [(WidthClass, StripContent)] {
        let classes = narrowing(from: widthClass(freeColumns: free))
        var list = classes.compactMap { width in
            stripContent(header, at: width).map { (width, $0) }
        }
        guard classes != [.w0], let (width, narrowest) = list.last else { return list }
        let minimum = header.watch?.showsStop == true ? [Pill.stop, .actions(.glyph)]
                                                      : [Pill.actions(.glyph)]
        if narrowest.pills != minimum {
            list.append((width, StripContent(readout: narrowest.readout,
                                             readoutTone: narrowest.readoutTone,
                                             dots: narrowest.dots,
                                             overflowDot: narrowest.overflowDot,
                                             pills: minimum)))
        }
        return list
    }

    /// A row's class and every narrower one it may fall back to, richest first.
    private static func narrowing(from width: WidthClass) -> [WidthClass] {
        switch width {
        case .w3: return [.w3, .w2, .w1]
        case .w2: return [.w2, .w1]
        case .w1: return [.w1]
        case .w0: return [.w0]
        }
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
    /// An in-grid fold triangle's cell, widened to the same 20 pt the gutter uses, for the same
    /// reason: one cell is about 8 pt, which is not a target.
    static let foldColumnWidth: Double = 20
    /// An in-grid fold triangle's target: 20 pt wide, `hitRowHeight` tall. The same 20 pt the gutter
    /// uses, so the two fold controls on screen are the same size (§2.4, §8.4).
    ///
    /// Which *column* it starts at is the caller's: a fold placeholder's marker is at column 0, and
    /// a lens line's is wherever `LensBuffer.foldMarkerColumn` says, which for a pretty-printed body
    /// is past the indent and the key.
    ///
    /// A tuple of `Double`s rather than a `CGSize`: `NyxCore` has no CoreGraphics type in it.
    static func foldTriangleHit(cellHeight: Double) -> (width: Double, height: Double) {
        (width: foldColumnWidth, height: hitRowHeight(cellHeight: cellHeight))
    }

    /// Which of `rows` a point at `y` falls on, when each is a `hitHeight`-tall target centred on
    /// its row. `y` is measured from the top of the pane, padding included.
    ///
    /// This exists because `hitRowHeight`'s floor is only real if the *click* honours it. Dividing
    /// the point by the cell height is right for text and wrong for a target that overhangs its own
    /// row: at `line-height = 0.8` a row is 13 pt and the target is 16, so 1.5 pt of hand at each
    /// end of every fold control belonged to the neighbouring row, and a click there moved the caret
    /// instead of folding. One rule for the hand, the click and the accessibility frame.
    ///
    /// Where two targets genuinely overlap -- adjacent rows -- the nearer centre wins, and an exact
    /// tie goes to the upper row so the answer never depends on the order `rows` arrives in. That is
    /// `PromptGutter.markedRow`'s rule, and it forwards here so there is one of it.
    static func hitRow(atY y: Double, cellHeight: Double, padding: Double,
                       hitHeight: Double, rows: [Int]) -> Int? {
        guard cellHeight > 0, hitHeight > 0 else { return nil }
        var best: (row: Int, distance: Double)?
        for row in rows.sorted() {
            let centre = padding + (Double(row) + 0.5) * cellHeight
            let distance = abs(y - centre)
            guard distance <= hitHeight / 2 else { continue }
            if best == nil || distance < best!.distance { best = (row, distance) }
        }
        return best?.row
    }
}

/// Where a block's summary ended up: which row of the command, and which columns.
///
/// It carries no variant any more. There used to be a `chevronOnly` one, because the chevron on the
/// end of the sentence was a control and had to survive a crowded row; it is a readout now, so a
/// row either has space for the whole sentence or shows none of it (§2.4).
public struct SummaryPlacement: Equatable {
    /// In whatever space the caller passed its rows in -- absolute rows from the pane, so it can be
    /// mapped back to a display slot through the same map the text went through.
    public let row: Int
    public let columns: Range<Int>

    public init(row: Int, columns: Range<Int>) {
        self.row = row; self.columns = columns
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
    /// `on` is the ground the ink is actually painted on. Resolving against `palette.background`
    /// and then drawing on the hovered block's tint is what the plan-1a pictures measured as
    /// **4.17:1** for the neutral `8.8s` and **4.13:1** for `… 6 lines hidden` -- hovering a block
    /// made its own status *less* legible, which is the shape of the defect §2.5 exists to remove
    /// (design D1). Every other derived ink in the palette (`textOn`, `pillHairline`, `fadedMark`)
    /// was already pushed against the ground it lands on; this was the one that was not.
    ///
    /// The three block-chrome call sites pass `palette.blockHoverBackground` **unconditionally**
    /// rather than the ground of the frame in hand. The tint is the harder of the two grounds for
    /// all 35 theme×tone pairs -- it moves `background` toward `accent`, which is the direction
    /// these inks already sit in -- so one resolution clears both, and the fold placeholder (which
    /// is drawn as *cells*, through the row cache) does not become a row input that changes with
    /// hover while `RowKey` knows nothing about it.
    public func color(in palette: Palette, on ground: RGB? = nil) -> RGB {
        let picked: RGB
        switch self {
        case .plain: picked = palette.noteForeground
        case .running, .redirect: picked = palette.readable(3)
        case .success: picked = palette.readable(2)
        case .failure: picked = palette.readable(1)
        }
        return RGB.readable(picked, on: ground ?? palette.background, towards: palette.foreground)
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
    /// so this is what decides whether it is offered -- see `CommandBlockChrome.pills(_:at:)`.
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
