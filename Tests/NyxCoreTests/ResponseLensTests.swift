import Foundation
import Testing
@testable import NyxCore

// MARK: - Fixtures

/// The timing the brief's example line is built from: `142 ms · DNS 3 · connect 12 · TLS 40 ·
/// TTFB 120`. curl's four clocks are cumulative from the start of the request, which is why the
/// numbers here are not the numbers on the line.
private func timing(total: Double = 0.142, nameLookup: Double = 0.003, connect: Double = 0.015,
                    appConnect: Double = 0.055, startTransfer: Double = 0.120,
                    status: Int = 200, contentType: String = "application/json")
    -> HTTPExchange.Timing {
    HTTPExchange.Timing(status: status, total: total, nameLookup: nameLookup, connect: connect,
                        appConnect: appConnect, startTransfer: startTransfer, sizeDownload: 512,
                        numRedirects: 0, contentType: contentType)
}

private func head(_ status: Int, _ headers: [(String, String)],
                  version: String = "2", reason: String = "") -> HTTPExchange.Head {
    HTTPExchange.Head(version: version, status: status, reason: reason,
                      headers: headers.map { HTTPExchange.Header(name: $0.0, value: $0.1) })
}

private func exchange(status: Int = 200,
                      headers: [(String, String)] = [("content-type", "application/json"),
                                                     ("server", "nginx")],
                      body: [String] = ["{\"a\":1}"],
                      kind: HTTPExchange.BodyKind = .json,
                      timing: HTTPExchange.Timing? = timing(),
                      redirects: [HTTPExchange.Head] = []) -> HTTPExchange {
    HTTPExchange(redirects: redirects, final: head(status, headers), bodyLines: body,
                 bodyKind: kind, timing: timing)
}

private func texts(_ lines: [LensLine]?) -> [String] { (lines ?? []).map(\.text) }

// MARK: - What the lenses are called

@Test func lensTitles() {
    #expect(ResponseLens.raw.title == "Raw")
    #expect(ResponseLens.pretty.title == "Pretty JSON")
    #expect(ResponseLens.headers.title == "Headers")
    #expect(ResponseLens.body.title == "Body")
    #expect(ResponseLens.filter(".a").title == "Filter…")
    #expect(ResponseLens.grep("x").title == "Find in Body…")
    #expect(ResponseLens.diff(previousCommandID: 7).title == "Diff with Previous Run")
}

// MARK: - Pretty

/// The headers are one line until asked for: what a reader wants from a response is the body, and
/// twelve rows of `x-amz-*` in front of it is the reason people pipe curl into jq in the first
/// place. The one line still says the thing they *do* read -- the content type.
@Test func prettyStartsWithFoldedHeaders() {
    let input = LensInput(exchange: exchange(), previous: nil, folded: [ResponseLens.headersNode])
    let lines = LensRendering.lines(for: .pretty, input: input) ?? []
    #expect(lines.first?.text == "\u{25B8} 2 headers \u{b7} content-type: application/json")
    #expect(lines.first?.node == ResponseLens.headersNode)
    #expect(lines.first?.spans.map(\.style) == [.header])
    #expect(lines.first?.depth == 0)
    // The body follows it, not another header line.
    #expect(lines[1].text == "{")
}

@Test func prettyUnfoldedListsEveryHeader() {
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: exchange(), previous: nil,
                                                     folded: [])) ?? []
    #expect(lines[0].text == "\u{25BE} 2 headers")
    #expect(lines[0].node == ResponseLens.headersNode)
    #expect(lines[1].text == "content-type: application/json")
    #expect(lines[1].depth == 1)
    #expect(lines[1].spans.map(\.style) == [.header])
    // The name only: the value is not a header name and colouring it as one would make the whole
    // row one word.
    #expect(lines[1].spans.first?.range == 0 ..< "content-type".count)
    #expect(lines[2].text == "server: nginx")
}

@Test func prettyEndsWithLatency() {
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: exchange(), previous: nil,
                                                     folded: [ResponseLens.headersNode])) ?? []
    #expect(lines.last?.text == "142 ms \u{b7} DNS 3 \u{b7} connect 12 \u{b7} TLS 40 \u{b7} TTFB 120")
    #expect(lines.last?.spans.map(\.style) == [.dim])
}

/// A part that measures nothing is not printed as zero: `TLS 0` on a plain-HTTP request says the
/// handshake was instant rather than that there was not one.
@Test func latencyOmitsThePartsThatDidNotHappen() {
    let plain = timing(total: 0.010, nameLookup: 0.0, connect: 0.002, appConnect: 0.0,
                       startTransfer: 0.008)
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: exchange(timing: plain),
                                                     previous: nil,
                                                     folded: [ResponseLens.headersNode])) ?? []
    #expect(lines.last?.text == "10 ms \u{b7} connect 2 \u{b7} TTFB 8")
}

/// No sentinel, no line. An invented latency is worse than none.
@Test func withoutTimingThereIsNoLatencyLine() {
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: exchange(timing: nil), previous: nil,
                                                     folded: [ResponseLens.headersNode])) ?? []
    #expect(lines.last?.text == "}")
    #expect(!texts(lines).contains { $0.contains("ms") })
}

/// A body that is not JSON is shown as it arrived. The lens is called Pretty JSON; on HTML it
/// prints HTML rather than refusing to draw anything.
@Test func prettyOnTextBodyIsRawLines() {
    let html = exchange(headers: [("content-type", "text/html")],
                        body: ["<html>", "  <body>hello</body>", "</html>"], kind: .text,
                        timing: timing(contentType: "text/html"))
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: html, previous: nil,
                                                     folded: [ResponseLens.headersNode])) ?? []
    // One header on this fixture, so the noun is singular.
    #expect(texts(lines) == ["\u{25B8} 1 header \u{b7} content-type: text/html",
                             "<html>", "  <body>hello</body>", "</html>",
                             "142 ms \u{b7} DNS 3 \u{b7} connect 12 \u{b7} TLS 40 \u{b7} TTFB 120"])
}

/// A body labelled JSON that does not parse -- truncated, or streaming -- is shown as it arrived
/// rather than as nothing at all.
@Test func prettyOnBrokenJSONFallsBackToTheRawLines() {
    let cut = exchange(body: ["{\"a\": [1, 2,"], kind: .json)
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: cut, previous: nil,
                                                     folded: [ResponseLens.headersNode])) ?? []
    #expect(lines[1].text == "{\"a\": [1, 2,")
}

// MARK: - Headers

@Test func headersListRedirects() {
    let hops = [head(301, [("location", "https://example.com/b")]),
                head(302, [("location", "https://example.com/c")])]
    let lines = LensRendering.lines(for: .headers,
                                    input: LensInput(exchange: exchange(redirects: hops),
                                                     previous: nil, folded: [])) ?? []
    #expect(texts(lines) == ["HTTP/2 200",
                             "content-type: application/json",
                             "server: nginx",
                             "\u{21AA} 301 \u{2192} https://example.com/b",
                             "\u{21AA} 302 \u{2192} https://example.com/c"])
    #expect(lines[0].spans.map(\.style) == [.header])
    #expect(lines[3].spans.map(\.style) == [.dim])
}

/// HTTP/1.1 still has a reason phrase and it is worth reading; HTTP/2 has none and the line must
/// not end in a space.
@Test func theStatusLineKeepsItsReasonPhrase() {
    let old = HTTPExchange(redirects: [], final: head(404, [], version: "1.1", reason: "Not Found"),
                           bodyLines: [], bodyKind: .empty, timing: nil)
    let lines = LensRendering.lines(for: .headers,
                                    input: LensInput(exchange: old, previous: nil, folded: []))
    #expect(texts(lines) == ["HTTP/1.1 404 Not Found"])
}

/// A run with no `-i` has no headers to show. It says so: an empty pane is a bug report waiting to
/// be filed.
@Test func headersWithoutAHeadSaysWhy() {
    let bodyOnly = HTTPExchange(redirects: [], final: nil, bodyLines: ["hello"], bodyKind: .text,
                                timing: timing())
    let lines = LensRendering.lines(for: .headers,
                                    input: LensInput(exchange: bodyOnly, previous: nil, folded: []))
    #expect(texts(lines) == ["No response headers in this transcript \u{2014} the request ran without -i"])
    #expect(lines?.first?.spans.map(\.style) == [.dim])
}

// MARK: - Filter

@Test func filterPrintsEachResult() {
    let body = exchange(body: ["{\"items\":[{\"id\":1},{\"id\":2}]}"])
    let lines = LensRendering.lines(for: .filter(".items[] | .id"),
                                    input: LensInput(exchange: body, previous: nil, folded: []))
    #expect(texts(lines) == ["1", "2"])
}

@Test func filterErrorForUnsupported() {
    let value = JSONDocument.parse("{\"a\":1}")
    #expect(LensRendering.filterError("map(.x)", body: value) == JSONPath.unsupportedMessage)
    #expect(LensRendering.filterError(".a", body: value) == nil)
    #expect(LensRendering.filterError(".a", body: nil)
            == "Not JSON \u{2014} there is nothing here to filter")
    // A body that is not JSON is the first thing to say: the path cannot be applied to anything at
    // all, whatever is wrong with it.
    #expect(LensRendering.filterError("map(.x)", body: nil)
            == "Not JSON \u{2014} there is nothing here to filter")
    let lines = LensRendering.lines(for: .filter("map(.x)"),
                                    input: LensInput(exchange: exchange(), previous: nil,
                                                     folded: []))
    #expect(lines == nil)
}

@Test func filterOnTextBodyIsNil() {
    let html = exchange(headers: [("content-type", "text/html")], body: ["<html>"], kind: .text)
    #expect(LensRendering.lines(for: .filter(".a"),
                                input: LensInput(exchange: html, previous: nil, folded: [])) == nil)
}

/// A path that is understood and matches nothing says so, rather than leaving a blank pane that
/// looks like a lens that failed to run.
@Test func filterWithNoResultsSaysSo() {
    let lines = LensRendering.lines(for: .filter(".nope[]"),
                                    input: LensInput(exchange: exchange(), previous: nil,
                                                     folded: []))
    #expect(texts(lines) == ["no results for \".nope[]\""])
    #expect(lines?.first?.spans.map(\.style) == [.dim])
}

// MARK: - Grep

@Test func grepNumbersAndHighlights() {
    let body = exchange(headers: [("content-type", "text/plain")],
                        body: ["alpha beta", "gamma", "beta BETA"], kind: .text)
    let lines = LensRendering.lines(for: .grep("beta"),
                                    input: LensInput(exchange: body, previous: nil, folded: [])) ?? []
    #expect(texts(lines) == ["1: alpha beta", "3: beta BETA"])
    // Every occurrence, case-insensitively, offset by the `"3: "` the line now carries.
    #expect(lines[0].spans.map(\.range) == [9 ..< 13])
    #expect(lines[1].spans.map(\.range) == [3 ..< 7, 8 ..< 12])
    #expect(lines[1].spans.map(\.style) == [.match, .match])
}

@Test func grepNoMatches() {
    let lines = LensRendering.lines(for: .grep("zebra"),
                                    input: LensInput(exchange: exchange(), previous: nil,
                                                     folded: []))
    #expect(texts(lines) == ["no matches for \"zebra\""])
    #expect(lines?.first?.spans.map(\.style) == [.dim])
}

// MARK: - Diff

private func twentyLines(changingAt changed: Range<Int>, marker: String) -> [String] {
    (1...20).map { changed.contains($0) ? "line \($0) \(marker)" : "line \($0)" }
}

@Test func diffSummaryAndMarks() {
    let before = exchange(headers: [("content-type", "text/plain")],
                          body: twentyLines(changingAt: 0..<0, marker: ""), kind: .text,
                          timing: timing(total: 0.142))
    let after = exchange(headers: [("content-type", "text/plain")],
                         body: twentyLines(changingAt: 10..<13, marker: "changed"), kind: .text,
                         timing: timing(total: 0.138))
    let lines = LensRendering.lines(for: .diff(previousCommandID: 1),
                                    input: LensInput(exchange: after, previous: before,
                                                     folded: [])) ?? []
    #expect(lines.first?.text
            == "3 lines changed \u{b7} status 200 \u{2192} 200 \u{b7} 142 ms \u{2192} 138 ms")
    #expect(lines.first?.spans.map(\.style) == [.dim])
    #expect(texts(lines) == [
        "3 lines changed \u{b7} status 200 \u{2192} 200 \u{b7} 142 ms \u{2192} 138 ms",
        "  \u{2026} 6 unchanged lines",
        "  line 7", "  line 8", "  line 9",
        "- line 10", "- line 11", "- line 12",
        "+ line 10 changed", "+ line 11 changed", "+ line 12 changed",
        "  line 13", "  line 14", "  line 15",
        "  \u{2026} 5 unchanged lines",
    ])
    #expect(lines[5].spans.map(\.style) == [.removed])
    #expect(lines[8].spans.map(\.style) == [.added])
    #expect(lines[2].spans.isEmpty)
    #expect(lines[1].spans.map(\.style) == [.dim])
}

/// Nothing changed is a result, and the most reassuring one a watch can give.
@Test func diffOfAnUnchangedBodySaysNothingChanged() {
    let body = exchange(headers: [("content-type", "text/plain")],
                        body: twentyLines(changingAt: 0..<0, marker: ""), kind: .text)
    let lines = LensRendering.lines(for: .diff(previousCommandID: 1),
                                    input: LensInput(exchange: body, previous: body,
                                                     folded: [])) ?? []
    #expect(lines[0].text.hasPrefix("0 lines changed"))
    #expect(lines[1].text == "  \u{2026} 20 unchanged lines")
    #expect(lines.count == 2)
}

/// What is unknown is left out rather than printed as a guess.
@Test func theDiffSummaryOmitsWhatItDoesNotKnow() {
    let before = HTTPExchange(redirects: [], final: nil, bodyLines: ["a"], bodyKind: .text,
                              timing: nil)
    let after = HTTPExchange(redirects: [], final: nil, bodyLines: ["b"], bodyKind: .text,
                             timing: nil)
    let lines = LensRendering.lines(for: .diff(previousCommandID: 1),
                                    input: LensInput(exchange: after, previous: before,
                                                     folded: [])) ?? []
    #expect(lines.first?.text == "1 line changed")
}

@Test func diffWithoutPreviousIsNil() {
    #expect(LensRendering.lines(for: .diff(previousCommandID: 1),
                                input: LensInput(exchange: exchange(), previous: nil,
                                                 folded: [])) == nil)
}

/// Past the cap the diff stops being a diff and becomes a classification -- which lines are gone
/// and which are new. It still has to answer, and it has to say that is what it did.
@Test func aHugeDiffFallsBackToClassifying() {
    let previous = exchange(headers: [("content-type", "text/plain")],
                            body: (0..<6_000).map { "old line \($0)" }, kind: .text)
    let current = exchange(headers: [("content-type", "text/plain")],
                           body: (0..<6_000).map { "new line \($0)" }, kind: .text)
    let lines = LensRendering.lines(for: .diff(previousCommandID: 1),
                                    input: LensInput(exchange: current, previous: previous,
                                                     folded: [])) ?? []
    #expect(lines.first?.text.hasPrefix("6000 lines changed") == true)
    #expect(texts(lines).contains("- old line 10"))
    #expect(texts(lines).contains("+ new line 10"))
}

/// And the case the trimming is for: a six-thousand-line body with one line different still gets
/// the exact diff, because the head and the tail come off before the algorithm sees anything.
@Test func aTinyChangeInAHugeBodyIsStillExact() {
    let before = (0..<6_000).map { "line \($0)" }
    var afterLines = before
    afterLines[10] = "line 10 changed"
    let previous = exchange(headers: [("content-type", "text/plain")], body: before, kind: .text)
    let current = exchange(headers: [("content-type", "text/plain")], body: afterLines, kind: .text)
    let lines = LensRendering.lines(for: .diff(previousCommandID: 1),
                                    input: LensInput(exchange: current, previous: previous,
                                                     folded: [])) ?? []
    #expect(lines.first?.text.hasPrefix("1 line changed") == true)
    #expect(texts(lines) == ["1 line changed \u{b7} status 200 \u{2192} 200 \u{b7} 142 ms \u{2192} 142 ms",
                             "  \u{2026} 7 unchanged lines",
                             "  line 7", "  line 8", "  line 9",
                             "- line 10",
                             "+ line 10 changed",
                             "  line 11", "  line 12", "  line 13",
                             "  \u{2026} 5986 unchanged lines"])
}

// MARK: - Too large

@Test func tooLargeIsNil() {
    let huge = exchange(headers: [("content-type", "text/plain")],
                        body: (0..<20_001).map { "line \($0)" }, kind: .text)
    #expect(LensRendering.isTooLarge(huge))
    let input = LensInput(exchange: huge, previous: nil, folded: [])
    #expect(LensRendering.lines(for: .pretty, input: input) == nil)
    #expect(LensRendering.lines(for: .body, input: input) == nil)
    #expect(LensRendering.lines(for: .grep("line"), input: input) == nil)
    #expect(LensRendering.lines(for: .filter(".a"), input: input) == nil)
    // The headers are not the body: a 40 MB download still has a content type worth reading, and
    // showing it costs nothing.
    #expect(LensRendering.lines(for: .headers, input: input) != nil)
}

@Test func twoMegabytesOfBodyIsTooLarge() {
    let line = String(repeating: "x", count: 1_000)
    let big = exchange(headers: [("content-type", "text/plain")],
                       body: (0..<2_100).map { _ in line }, kind: .text)
    #expect(big.bodyLines.count < LensRendering.maxBodyLines)
    #expect(LensRendering.isTooLarge(big))
    #expect(!LensRendering.isTooLarge(exchange()))
}

/// `.raw` is the lens that says "do not render": the caller shows the transcript it already has.
@Test func rawRendersNothingOfItsOwn() {
    #expect(LensRendering.lines(for: .raw, input: LensInput(exchange: exchange(), previous: nil,
                                                            folded: [])) == nil)
}

/// The body lens is the pretty one without the frame around it.
@Test func bodyIsTheBodyAlone() {
    let lines = LensRendering.lines(for: .body,
                                    input: LensInput(exchange: exchange(), previous: nil,
                                                     folded: []))
    #expect(texts(lines) == ["{", "  \"a\": 1", "}"])
}

@Test func anEmptyBodySaysSo() {
    let empty = HTTPExchange(redirects: [], final: head(204, []), bodyLines: [], bodyKind: .empty,
                             timing: nil)
    let lines = LensRendering.lines(for: .body,
                                    input: LensInput(exchange: empty, previous: nil, folded: []))
    #expect(texts(lines) == ["empty body"])
    #expect(lines?.first?.spans.map(\.style) == [.dim])
}

/// A JSON body arrives as one line and is *read* as thirty. Searching it has to number the lines
/// the reader can see, or every hit is "line 1".
@Test func grepSearchesTheBodyAsItIsShown() {
    let body = exchange(body: ["{\"error\":\"nope\",\"errors\":[\"one\"]}"])
    let lines = LensRendering.lines(for: .grep("error"),
                                    input: LensInput(exchange: body, previous: nil,
                                                     folded: [])) ?? []
    #expect(texts(lines) == ["2:   \"error\": \"nope\",", "3:   \"errors\": ["])
}

// MARK: - End to end, from a transcript

/// The one test that starts where the feature does: rows off the grid, through the exchange
/// parser, out as the lines a pane would draw. Every other test here builds an `HTTPExchange` by
/// hand, which is exactly how a lens comes to work on a shape curl never produces.
@Test func aRealTranscriptRendersThroughTheLens() throws {
    let parsed = try #require(HTTPExchange.parse(lines: [
        "HTTP/2 200",
        "alt-svc: h3=\":443\"; ma=2592000",
        "content-type: application/json",
        "date: Sun, 06 Sep 2026 05:35:54 GMT",
        "via: 1.1 Caddy",
        "content-length: 61",
        "",
        "{\"online\":0,\"pairings\":0,\"attachments\":0,\"dropped_binary\":0}",
        "",
        "--nyx-http-- 200 0.157325 0.003921 0.051385 0.108482 0.157108 61 0 application/json",
    ]))
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: parsed, previous: nil,
                                                     folded: [ResponseLens.headersNode])) ?? []
    #expect(texts(lines) == [
        "\u{25B8} 5 headers \u{b7} content-type: application/json",
        "{",
        "  \"online\": 0,",
        "  \"pairings\": 0,",
        "  \"attachments\": 0,",
        "  \"dropped_binary\": 0",
        "}",
        "157 ms \u{b7} DNS 4 \u{b7} connect 47 \u{b7} TLS 57 \u{b7} TTFB 157",
    ])
    // And the fold point the pane will hang a click on: the body's root, on the `{` line.
    #expect(lines[1].node == NodePath([]))
}

// MARK: - The minors

/// Two results of one filter are two documents, and folding the first must not fold the second.
/// Every result's paths are prefixed with its position, so the roots cannot collide on `NodePath([])`.
@Test func filterResultsHaveTheirOwnFoldPaths() {
    let body = exchange(body: ["{\"items\":[{\"a\":[1,2]},{\"b\":[3,4]}]}"])
    let open = LensRendering.lines(for: .filter(".items[]"),
                                   input: LensInput(exchange: body, previous: nil,
                                                    folded: [])) ?? []
    #expect(texts(open) == ["{", "  \"a\": [", "    1,", "    2", "  ]", "}",
                            "{", "  \"b\": [", "    3,", "    4", "  ]", "}"])
    #expect(open[0].node == NodePath([.index(0)]))
    #expect(open[1].node == NodePath([.index(0), .key("a")]))
    #expect(open[6].node == NodePath([.index(1)]))

    let folded = LensRendering.lines(for: .filter(".items[]"),
                                     input: LensInput(exchange: body, previous: nil,
                                                      folded: [NodePath([.index(0)])])) ?? []
    #expect(texts(folded) == ["\u{25B8} {…} 1 key",
                              "{", "  \"b\": [", "    3,", "    4", "  ]", "}"])
}

/// The cap that is about the *shape* of the change rather than its size: sixteen hundred lines,
/// well inside the size cap, but moving a block of eight hundred is an edit distance of sixteen
/// hundred and Myers' trace is not worth that. The coarse answer is the honest one -- every line is
/// still here -- and it is visibly coarse rather than quietly wrong.
@Test func pastTheEditDistanceCapTheDiffClassifiesInstead() {
    let alpha = (0..<800).map { "alpha \($0)" }
    let beta = (0..<800).map { "beta \($0)" }
    let previous = exchange(headers: [("content-type", "text/plain")], body: alpha + beta,
                            kind: .text)
    let current = exchange(headers: [("content-type", "text/plain")], body: beta + alpha,
                           kind: .text)
    #expect(alpha.count + beta.count < LensRendering.maxDiffLines)
    let lines = LensRendering.lines(for: .diff(previousCommandID: 1),
                                    input: LensInput(exchange: current, previous: previous,
                                                     folded: [])) ?? []
    #expect(lines.first?.text.hasPrefix("0 lines changed") == true)
    #expect(lines.count == 2)
    #expect(lines[1].text == "  \u{2026} 1600 unchanged lines")
}

/// Collapsing one line saves nothing and costs the reader a sentence to decode. It is only worth
/// doing when there is more than one line behind it.
@Test func aSingleUnchangedLineIsNotCollapsed() {
    let before = (1...10).map { "line \($0)" }
    let after = before.enumerated().map { $0.offset == 0 || $0.offset == 8 ? "\($0.element) changed" : $0.element }
    let previous = exchange(headers: [("content-type", "text/plain")], body: before, kind: .text)
    let current = exchange(headers: [("content-type", "text/plain")], body: after, kind: .text)
    let lines = LensRendering.lines(for: .diff(previousCommandID: 1),
                                    input: LensInput(exchange: current, previous: previous,
                                                     folded: [])) ?? []
    #expect(texts(lines).dropFirst() == ["- line 1", "+ line 1 changed",
                                         "  line 2", "  line 3", "  line 4", "  line 5",
                                         "  line 6", "  line 7", "  line 8",
                                         "- line 9", "+ line 9 changed",
                                         "  line 10"])
    #expect(!texts(lines).contains("  \u{2026} 1 unchanged line"))
}

/// The pretty lens says the same thing the headers lens says when there are no headers: a body with
/// nothing above it looks like a lens that lost them.
@Test func prettyWithoutAHeadSaysWhy() {
    let bodyOnly = HTTPExchange(redirects: [], final: nil, bodyLines: ["hello"], bodyKind: .text,
                                timing: nil)
    let lines = LensRendering.lines(for: .pretty,
                                    input: LensInput(exchange: bodyOnly, previous: nil,
                                                     folded: [ResponseLens.headersNode])) ?? []
    #expect(texts(lines) == ["No response headers in this transcript \u{2014} the request ran without -i",
                             "hello"])
    #expect(lines[0].spans.map(\.style) == [.dim])
    // Word for word what the headers lens says, so two views of one response cannot describe it
    // differently.
    let headers = LensRendering.lines(for: .headers,
                                      input: LensInput(exchange: bodyOnly, previous: nil,
                                                       folded: []))
    #expect(headers?.first?.text == lines[0].text)
}

/// The chip carries the lens' *name*, and it is the short head of the menu's own wording -- never a
/// third spelling of the same lens.
@Test func everyLensHasAChipTitle() {
    #expect(ResponseLens.raw.chipTitle == "Raw")
    #expect(ResponseLens.pretty.chipTitle == "Pretty")
    #expect(ResponseLens.headers.chipTitle == "Headers")
    #expect(ResponseLens.body.chipTitle == "Body")
    #expect(ResponseLens.filter(".a").chipTitle == "Filter")
    #expect(ResponseLens.grep("x").chipTitle == "Find")
    #expect(ResponseLens.diff(previousCommandID: 3).chipTitle == "Diff")
    for lens in [ResponseLens.raw, .pretty, .headers, .body, .filter(""), .grep(""),
                 .diff(previousCommandID: 0)] {
        #expect(lens.title.hasPrefix(lens.chipTitle) || lens.chipTitle == "Find",
                "\(lens.chipTitle) is not the head of \(lens.title)")
    }
}
