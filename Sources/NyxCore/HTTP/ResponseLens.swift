import Foundation

/// A way of looking at a response that has already been read out of the terminal.
///
/// One value per thing a person does with a response: read it, read its headers, find a word in it,
/// pull one field out of it, or see what changed since the last run. The lens is a *choice*, not a
/// mode -- nothing here mutates the exchange, and every rendering is a pure function of the
/// exchange and the lens, so a re-render after a fold, a poll or a theme change cannot drift from
/// what the last one showed.
public enum ResponseLens: Equatable {
    case raw
    case pretty
    case headers
    case body
    /// A `JSONPath` expression. See `LensRendering.filterError` for what happens when it is not one.
    case filter(String)
    /// A literal, case-insensitive search of the body.
    case grep(String)
    /// The run to compare with. The id is how the *caller* finds that run's exchange; the rendering
    /// takes the exchange itself in `LensInput.previous`, so nothing here has to know what a
    /// command id is or where the history lives.
    case diff(previousCommandID: UInt32)

    /// The name in the menu, the palette and the lens picker. One string, so those three cannot
    /// disagree about what this lens is called.
    public var title: String {
        switch self {
        case .raw: return "Raw"
        case .pretty: return "Pretty JSON"
        case .headers: return "Headers"
        case .body: return "Body"
        case .filter: return "Filter…"
        case .grep: return "Find in Body…"
        case .diff: return "Diff with Previous Run"
        }
    }

    /// The fold point the response's headers hang from.
    ///
    /// A `NodePath` like any other, so one `folded` set carries both the headers block and every
    /// node of the body. `$headers` cannot be reached by walking a JSON document -- a body whose
    /// root object really has a key of that name would share the fold, which is a cosmetic
    /// collision and the only one this sentinel can cause.
    ///
    /// The headers are folded when this path is *in* `folded`, like everything else. "Folded by
    /// default" is the caller seeding the set with it, rather than this one node meaning the
    /// opposite of every other one.
    public static let headersNode = NodePath([.key("$headers")])
}

/// One rendered line of a response, in the same shape `JSONDocument` produces: text with its indent
/// already in it, spans over Character offsets, and a fold point when the line has one.
public struct LensLine: Equatable {
    public typealias Span = JSONDocument.PrettyLine.Span

    public var text: String
    public var spans: [Span]
    /// Set when this line can be folded: the headers line, and the opening line of any container in
    /// the body.
    public var node: NodePath?
    public var depth: Int

    public init(_ text: String, spans: [Span] = [], node: NodePath? = nil, depth: Int = 0) {
        self.text = text
        self.spans = spans
        self.node = node
        self.depth = depth
    }
}

/// Everything a lens is allowed to see. A value, so a rendering can be tested, cached and compared
/// without a window, a pane or a pasteboard anywhere near it.
public struct LensInput: Equatable {
    public var exchange: HTTPExchange
    /// The previous run of the same request, for `.diff`. nil when there was not one.
    public var previous: HTTPExchange?
    public var folded: Set<NodePath>

    public init(exchange: HTTPExchange, previous: HTTPExchange? = nil,
                folded: Set<NodePath> = []) {
        self.exchange = exchange
        self.previous = previous
        self.folded = folded
    }
}

/// Turning a lens and an exchange into lines.
public enum LensRendering {
    /// Past either of these the answer is "show the transcript as it is".
    ///
    /// Not because the algorithms cannot cope -- the printer is bounded and the diff falls back --
    /// but because a person did not ask for two megabytes to be re-laid-out on the frame that
    /// arrives with it. The raw text is already on the screen and costs nothing to leave there.
    public static let maxBodyBytes = 2 * 1024 * 1024
    public static let maxBodyLines = 20_000

    /// Above this many differing lines a side, the diff stops being a diff -- see `changes`.
    static let maxDiffLines = 5_000
    /// And above this much *edit distance* within that, Myers' trace costs more memory than the
    /// answer is worth.
    static let maxEditDistance = 1_000
    /// Unchanged lines kept either side of a change. Three is the number `diff -u` settled on.
    static let context = 3

    public static func isTooLarge(_ exchange: HTTPExchange) -> Bool {
        if exchange.bodyLines.count > maxBodyLines { return true }
        // Summed rather than joined: measuring a 40 MB body must not first build a 40 MB string.
        var bytes = max(0, exchange.bodyLines.count - 1)
        for line in exchange.bodyLines {
            bytes += line.utf8.count
            if bytes > maxBodyBytes { return true }
        }
        return false
    }

    /// The lines to draw, or nil to show the raw transcript instead.
    ///
    /// nil is an instruction, not a failure: it means "this lens has nothing better than what is
    /// already on screen". It is the answer for `.raw` itself, for a body too large to re-lay-out,
    /// for `.filter` on a body that is not JSON or with a path this does not understand (ask
    /// `filterError` which), and for `.diff` with no previous run to compare against.
    public static func lines(for lens: ResponseLens, input: LensInput) -> [LensLine]? {
        let exchange = input.exchange
        // The headers are not the body: a 40 MB download still has a content type worth reading,
        // and listing twenty headers costs nothing however big the thing under them is.
        if case .headers = lens { return headersLens(exchange) }
        guard !isTooLarge(exchange) else { return nil }

        switch lens {
        case .raw, .headers:
            // `.raw` is the instruction to show the transcript untouched. `.headers` cannot reach
            // here -- it returned above, before the size check -- and is listed only because this
            // switch is exhaustive over the lens, which is how a lens added later gets a compiler
            // error here instead of silently rendering nothing.
            return nil
        case .pretty:
            var out: [LensLine] = []
            if let head = exchange.final {
                out += headerBlock(head, folded: input.folded)
            } else {
                // The same sentence the headers lens uses, so two views of one response cannot
                // describe it differently.
                out.append(dim(noHeaders))
            }
            out += bodyBlock(exchange, folded: input.folded)
            if let timing = exchange.timing { out.append(dim(latency(timing))) }
            return out
        case .body:
            return bodyBlock(exchange, folded: input.folded)
        case .filter(let path):
            guard let value = bodyValue(exchange), let expression = JSONPath.parse(path) else {
                return nil
            }
            let results = JSONPath.evaluate(expression, on: value)
            guard !results.isEmpty else { return [dim("no results for \"\(path)\"")] }
            // Each result is its own document, and every one of them has a root: unprefixed, all
            // of their roots are `NodePath([])` and folding the first folded every one of them.
            // The position in the result list is the namespace.
            return results.enumerated().flatMap { offset, result in
                prefixed(JSONDocument.pretty(result, folded: folds(input.folded, under: offset)),
                         with: .index(offset))
            }
        case .grep(let needle):
            // The body *as shown*, not as it arrived: a JSON response is usually one enormous
            // line, and searching that gives one hit on line 1 with forty highlights in it. The
            // numbers have to be the numbers the reader can see.
            return grep(needle, in: bodyLines(exchange, folded: []).map(\.text))
        case .diff:
            guard let previous = input.previous, !isTooLarge(previous) else { return nil }
            return diff(from: previous, to: exchange)
        }
    }

    /// Why `.filter` returned nil, in one sentence, or nil when the path is fine.
    ///
    /// The body first: a path cannot be wrong about a document there is none of, and telling
    /// someone their jq is unsupported when the real problem is that they are looking at HTML
    /// sends them off to fix the wrong thing.
    public static func filterError(_ text: String, body: JSONValue?) -> String? {
        guard body != nil else { return "Not JSON \u{2014} there is nothing here to filter" }
        return JSONPath.parse(text) == nil ? JSONPath.unsupportedMessage : nil
    }

    // MARK: - The body

    /// The body as a value, or nil when it is not JSON -- either because it never was, or because
    /// what arrived does not parse (a truncated stream, a body cut off by `--max-time`).
    public static func bodyValue(_ exchange: HTTPExchange) -> JSONValue? {
        guard exchange.bodyKind == .json else { return nil }
        return JSONDocument.parse(exchange.bodyLines.joined(separator: "\n"))
    }

    /// Pretty when it is JSON, the rows as they arrived when it is not, and a line saying so when
    /// there is no body: a pane that draws nothing looks like a lens that failed to run.
    private static func bodyBlock(_ exchange: HTTPExchange, folded: Set<NodePath>) -> [LensLine] {
        let lines = bodyLines(exchange, folded: folded)
        return lines.isEmpty ? [dim("empty body")] : lines
    }

    private static func bodyLines(_ exchange: HTTPExchange, folded: Set<NodePath>) -> [LensLine] {
        if let value = bodyValue(exchange) {
            return lensLines(JSONDocument.pretty(value, folded: folded))
        }
        return exchange.bodyLines.map { LensLine($0) }
    }

    private static func lensLines(_ pretty: [JSONDocument.PrettyLine]) -> [LensLine] {
        pretty.map { LensLine($0.text, spans: $0.spans, node: $0.node, depth: $0.depth) }
    }

    // MARK: - Headers

    /// One line, or the whole list under it. The folded line still carries the content type,
    /// because that is the header people actually read -- it is the difference between "this is the
    /// JSON I wanted" and "this is an HTML error page".
    private static func headerBlock(_ head: HTTPExchange.Head,
                                    folded: Set<NodePath>) -> [LensLine] {
        let count = head.headers.count
        let noun = count == 1 ? "header" : "headers"
        if folded.contains(ResponseLens.headersNode) {
            var text = "\u{25B8} \(count) \(noun)"
            if let type = head.value(of: "Content-Type"), !type.isEmpty {
                // The label is spelled the same way whatever the server sent (`Content-Type` over
                // HTTP/1.1, `content-type` over HTTP/2): this line is a summary, and the list under
                // it is where the header's own spelling belongs.
                text += " \u{b7} content-type: \(type)"
            }
            return [LensLine(text, spans: [span(.header, text)], node: ResponseLens.headersNode)]
        }
        let title = "\u{25BE} \(count) \(noun)"
        var out = [LensLine(title, spans: [span(.header, title)], node: ResponseLens.headersNode)]
        out += head.headers.map { header in
            LensLine("\(header.name): \(header.value)",
                     spans: [LensLine.Span(range: 0 ..< header.name.count, style: .header)],
                     depth: 1)
        }
        return out
    }

    private static func headersLens(_ exchange: HTTPExchange) -> [LensLine] {
        guard let head = exchange.final else {
            guard !exchange.redirects.isEmpty else { return [dim(noHeaders)] }
            return exchange.redirects.map(redirectLine)
        }
        var status = "HTTP/\(head.version) \(head.status)"
        if !head.reason.isEmpty { status += " \(head.reason)" }
        var out = [LensLine(status, spans: [span(.header, status)])]
        out += head.headers.map { header in
            LensLine("\(header.name): \(header.value)",
                     spans: [LensLine.Span(range: 0 ..< header.name.count, style: .header)])
        }
        // After the response rather than before it: the answer is what was asked for, and the hops
        // are the footnote explaining why it took as long as it did.
        out += exchange.redirects.map(redirectLine)
        return out
    }

    private static func redirectLine(_ hop: HTTPExchange.Head) -> LensLine {
        var text = "\u{21AA} \(hop.status)"
        if let location = hop.value(of: "Location"), !location.isEmpty {
            text += " \u{2192} \(location)"
        }
        return dim(text)
    }

    // MARK: - Latency

    /// `142 ms · DNS 3 · connect 12 · TLS 40 · TTFB 120`.
    ///
    /// curl's clocks are all cumulative from the start of the request, so the two middle parts are
    /// subtractions -- `connect` is the socket alone and `TLS` the handshake alone, which is what a
    /// reader comparing two runs wants. The other two are not: `DNS` is the first phase, so it is
    /// already its own duration, and `TTFB` is deliberately left cumulative, because "time to first
    /// byte" means from the start of the request and a from-the-handshake number under that name
    /// would be a different measurement wearing the same word.
    ///
    /// A part that measures nothing is left out rather than printed as `0` -- `TLS 0` on a
    /// plain-HTTP request reads as an instantaneous handshake rather than as no handshake at all.
    static func latency(_ timing: HTTPExchange.Timing) -> String {
        var parts = ["\(milliseconds(timing.total)) ms"]
        let dns = milliseconds(timing.nameLookup)
        if dns > 0 { parts.append("DNS \(dns)") }
        let connect = milliseconds(timing.connect - timing.nameLookup)
        if connect > 0 { parts.append("connect \(connect)") }
        if timing.appConnect > 0 {
            let tls = milliseconds(timing.appConnect - timing.connect)
            if tls > 0 { parts.append("TLS \(tls)") }
        }
        let ttfb = milliseconds(timing.startTransfer)
        if ttfb > 0 { parts.append("TTFB \(ttfb)") }
        return parts.joined(separator: " \u{b7} ")
    }

    static func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    // MARK: - Grep

    /// Every line holding `needle`, numbered from 1, with every occurrence marked.
    ///
    /// Case-insensitive and literal: this is the box under a response, not a regular-expression
    /// engine, and someone searching a body for `[` means `[`.
    private static func grep(_ needle: String, in bodyLines: [String]) -> [LensLine] {
        guard !needle.isEmpty else { return [dim("no matches for \"\(needle)\"")] }
        var out: [LensLine] = []
        for (offset, line) in bodyLines.enumerated() {
            var ranges: [Range<Int>] = []
            var from = line.startIndex
            while from < line.endIndex,
                  let found = line.range(of: needle, options: .caseInsensitive,
                                         range: from ..< line.endIndex) {
                let start = line.distance(from: line.startIndex, to: found.lowerBound)
                let length = line.distance(from: found.lowerBound, to: found.upperBound)
                ranges.append(start ..< start + length)
                // A case-insensitive match can be empty in principle; stepping one character on
                // guarantees the scan ends.
                from = found.upperBound > found.lowerBound
                    ? found.upperBound
                    : line.index(after: found.lowerBound)
            }
            guard !ranges.isEmpty else { continue }
            let prefix = "\(offset + 1): "
            let shift = prefix.count
            out.append(LensLine(prefix + line,
                                spans: ranges.map {
                                    LensLine.Span(range: $0.lowerBound + shift ..< $0.upperBound + shift,
                                                  style: .match)
                                }))
        }
        return out.isEmpty ? [dim("no matches for \"\(needle)\"")] : out
    }

    // MARK: - Diff

    /// What happened to a line between two runs.
    enum Change: Equatable {
        case same(String)
        case removed(String)
        case added(String)

        var isChange: Bool {
            if case .same = self { return false }
            return true
        }

        var text: String {
            switch self {
            case .same(let text), .removed(let text), .added(let text): return text
            }
        }
    }

    private static func diff(from previous: HTTPExchange, to current: HTTPExchange) -> [LensLine] {
        // Both sides rendered the same way and with nothing folded: a diff of two half-folded
        // documents would report the folds as changes.
        let before = bodyLines(previous, folded: []).map(\.text)
        let after = bodyLines(current, folded: []).map(\.text)
        let changes = changes(from: before, to: after)

        let removed = changes.filter { if case .removed = $0 { return true } else { return false } }
        let added = changes.filter { if case .added = $0 { return true } else { return false } }
        // A line that was replaced is *one* change, not a removal and an addition: `3 lines
        // changed` is what a person sees when they look at three edited rows.
        let count = max(removed.count, added.count)
        var summary = "\(count) line\(count == 1 ? "" : "s") changed"
        if let before = previous.status, let after = current.status {
            summary += " \u{b7} status \(before) \u{2192} \(after)"
        }
        if let before = previous.timing?.total, let after = current.timing?.total {
            summary += " \u{b7} \(milliseconds(before)) ms \u{2192} \(milliseconds(after)) ms"
        }
        return [dim(summary)] + rendered(changes)
    }

    /// The line diff, exactly where it can be and honestly coarse where it cannot.
    ///
    /// The common head and tail come off first, which is the whole game for a watched request: two
    /// polls of the same endpoint differ in a timestamp and nothing else, and what is left for the
    /// real algorithm is a handful of lines. Myers runs on that remainder, and gives up -- on size
    /// or on edit distance -- to a classification by set membership rather than to a stall.
    static func changes(from old: [String], to new: [String]) -> [Change] {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        let a = Array(old[head ..< old.count - tail])
        let b = Array(new[head ..< new.count - tail])
        let middle: [Change]
        if a.count > maxDiffLines || b.count > maxDiffLines {
            middle = classified(a, b)
        } else {
            middle = myers(a, b) ?? classified(a, b)
        }
        return old[0 ..< head].map(Change.same) + middle
            + old[(old.count - tail)...].map(Change.same)
    }

    /// Which lines are gone and which are new, by set membership. Their interleaving is not
    /// reconstructed -- that is the part that costs -- so the removals come first. A coarse answer
    /// that is still the truth, which is what a body of ten thousand changed lines deserves.
    private static func classified(_ a: [String], _ b: [String]) -> [Change] {
        let old = Set(a)
        let new = Set(b)
        return a.filter { !new.contains($0) }.map(Change.removed)
            + b.map { old.contains($0) ? Change.same($0) : Change.added($0) }
    }

    /// Myers' diff with its trace kept, or nil when the edit distance runs past `maxEditDistance`.
    ///
    /// The trace is what makes the *exact* diff possible rather than only its length, and it costs
    /// O(D²) integers -- hence the bound. Each round stores only the band it can be asked about
    /// (`-d ... d`), which is what keeps that square small enough to hold.
    private static func myers(_ a: [String], _ b: [String]) -> [Change]? {
        if a.isEmpty { return b.map(Change.added) }
        if b.isEmpty { return a.map(Change.removed) }
        let n = a.count
        let m = b.count
        let bound = n + m
        let offset = bound
        var v = [Int](repeating: 0, count: 2 * bound + 1)
        var trace: [[Int]] = []
        for d in 0...bound {
            if d > maxEditDistance { return nil }
            trace.append(Array(v[(offset - d) ... (offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { return backtrack(trace, a, b) }
            }
        }
        return nil
    }

    /// Walks the trace backwards, which is where the actual list of changes comes from: each round
    /// contributes one insertion or deletion and however many diagonal (unchanged) steps preceded
    /// it.
    private static func backtrack(_ trace: [[Int]], _ a: [String], _ b: [String]) -> [Change] {
        var out: [Change] = []
        var x = a.count
        var y = b.count
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]                        // holds k in -d ... d, at index k + d
            if d == 0 {
                while x > 0, y > 0 {
                    out.append(.same(a[x - 1]))
                    x -= 1
                    y -= 1
                }
                break
            }
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && v[k - 1 + d] < v[k + 1 + d]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = v[previousK + d]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                out.append(.same(a[x - 1]))
                x -= 1
                y -= 1
            }
            if x == previousX {
                out.append(.added(b[y - 1]))
            } else {
                out.append(.removed(a[x - 1]))
            }
            x = previousX
            y = previousY
        }
        return out.reversed()
    }

    /// The changes as lines: removals before additions inside one hunk, three lines of context
    /// either side, and everything further from a change than that collapsed into a line that says
    /// how much was left out. A response is read by scrolling, and forty untouched rows between two
    /// changes are forty rows of scrolling to find the second one.
    private static func rendered(_ changes: [Change]) -> [LensLine] {
        var ordered: [Change] = []
        var index = 0
        while index < changes.count {
            guard changes[index].isChange else {
                ordered.append(changes[index])
                index += 1
                continue
            }
            var removed: [Change] = []
            var added: [Change] = []
            while index < changes.count, changes[index].isChange {
                if case .removed = changes[index] { removed.append(changes[index]) }
                else { added.append(changes[index]) }
                index += 1
            }
            ordered += removed + added
        }

        var kept = [Bool](repeating: false, count: ordered.count)
        for (offset, change) in ordered.enumerated() where change.isChange {
            for near in max(0, offset - context) ... min(ordered.count - 1, offset + context) {
                kept[near] = true
            }
        }

        var out: [LensLine] = []
        var at = 0
        while at < ordered.count {
            guard kept[at] else {
                let start = at
                while at < ordered.count, !kept[at] { at += 1 }
                let run = at - start
                // Collapsing one line saves nothing and costs the reader a sentence to decode.
                guard run > 1 else {
                    out.append(LensLine("  " + ordered[start].text))
                    continue
                }
                out.append(dim("  \u{2026} \(run) unchanged lines"))
                continue
            }
            switch ordered[at] {
            case .same(let text):
                out.append(LensLine("  " + text))
            case .removed(let text):
                out.append(LensLine("- " + text, spans: [span(.removed, "- " + text)]))
            case .added(let text):
                out.append(LensLine("+ " + text, spans: [span(.added, "+ " + text)]))
            }
            at += 1
        }
        return out
    }

    // MARK: - Small things

    /// What a response with no head at all leaves to say. One string: the pretty lens and the
    /// headers lens both show it, and two views of one response must not word it differently.
    static let noHeaders = "No response headers in this transcript \u{2014} the request ran without -i"

    /// The folds that belong to result `offset`, with its prefix taken off, ready for a printer
    /// that knows nothing about being one of several.
    private static func folds(_ folded: Set<NodePath>, under offset: Int) -> Set<NodePath> {
        guard !folded.isEmpty else { return [] }
        return Set(folded.compactMap { path -> NodePath? in
            guard path.steps.first == .index(offset) else { return nil }
            return NodePath(Array(path.steps.dropFirst()))
        })
    }

    /// The printed lines with every fold point moved into result `step`'s namespace.
    private static func prefixed(_ pretty: [JSONDocument.PrettyLine],
                                 with step: NodePath.Step) -> [LensLine] {
        pretty.map { line in
            LensLine(line.text, spans: line.spans,
                     node: line.node.map { NodePath([step] + $0.steps) }, depth: line.depth)
        }
    }

    private static func dim(_ text: String) -> LensLine {
        LensLine(text, spans: [span(.dim, text)])
    }

    private static func span(_ style: LensStyle, _ text: String) -> LensLine.Span {
        LensLine.Span(range: 0 ..< text.count, style: style)
    }
}
