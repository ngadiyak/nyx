import Foundation
import Testing
@testable import NyxCore

/// The characters a span covers, which is what a reader of these tests actually wants to see.
private func spanned(_ line: JSONDocument.PrettyLine) -> [(String, LensStyle)] {
    let characters = Array(line.text)
    return line.spans.map { (String(characters[$0.range]), $0.style) }
}

private func styles(_ line: JSONDocument.PrettyLine) -> [LensStyle] { line.spans.map(\.style) }

// MARK: - Parsing

/// Two things `JSONSerialization` cannot give us and both of which a person reading a response
/// would notice at once: the keys in the order the server sent them, and `1.50` still spelled
/// `1.50` rather than re-rendered as `1.5`.
@Test func keepsKeyOrderAndNumberSpelling() throws {
    let value = try #require(JSONDocument.parse("{\"b\":1.50,\"a\":2}"))
    #expect(value == JSONValue.object([JSONValue.Member(key: "b", value: .number("1.50")),
                                       JSONValue.Member(key: "a", value: .number("2"))]))
}

/// A body that is JSON *and then something else* is not JSON. Stopping at the first complete value
/// would pretty-print half of a log line and hide the rest.
@Test func rejectsTrailingGarbage() {
    #expect(JSONDocument.parse("{\"a\":1} oops") == nil)
    #expect(JSONDocument.parse("[1,2] [3]") == nil)
    #expect(JSONDocument.parse("{\"a\":1},") == nil)
    #expect(JSONDocument.parse("") == nil)
    #expect(JSONDocument.parse("{\"a\":1") == nil)
    #expect(JSONDocument.parse("{\"a\":01}") == nil, "a leading zero is not a JSON number")
}

/// What a real response actually arrives with: a byte-order mark from a Windows service, and the
/// newline every shell adds. Neither is garbage, and refusing both would have the lens fall back to
/// raw on bodies that are perfectly good JSON.
@Test func acceptsBOMAndNewline() {
    #expect(JSONDocument.parse("\u{FEFF}{\"a\":1}\n")
            == JSONValue.object([.init(key: "a", value: .number("1"))]))
    #expect(JSONDocument.parse("  [1]  \n\n") == JSONValue.array([.number("1")]))
    #expect(JSONDocument.parse("\u{FEFF}") == nil)
}

/// A thousand nested arrays is a response, not a program: it must come back as "not JSON I can
/// show" rather than as a stack overflow in the render pass.
@Test func nestedDeep() {
    func nested(_ levels: Int) -> String {
        String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
    }
    #expect(JSONDocument.parse(nested(512)) != nil)
    #expect(JSONDocument.parse(nested(513)) == nil)
    #expect(JSONDocument.parse(nested(1_000)) == nil)
}

// MARK: - Printing

@Test func objectPrintsTwoSpaceIndent() throws {
    let value = try #require(JSONDocument.parse("{\"a\":[1,{\"b\":null}]}"))
    #expect(JSONDocument.pretty(value).map(\.text) == [
        "{",
        "  \"a\": [",
        "    1,",
        "    {",
        "      \"b\": null",
        "    }",
        "  ]",
        "}",
    ])
    #expect(JSONDocument.pretty(value).map(\.depth) == [0, 1, 2, 2, 3, 2, 1, 0])
}

/// Every token a reader colours is a span, and nothing else is: the punctuation between them is
/// the page's own foreground, so a theme change does not have to know about commas.
@Test func spansCoverKeysStringsNumbersLiterals() throws {
    let value = try #require(JSONDocument.parse("{\"a\":\"x\",\"b\":1,\"c\":true,\"d\":null,\"e\":[2]}"))
    let lines = JSONDocument.pretty(value)
    #expect(spanned(lines[1]).map(\.0) == ["\"a\"", "\"x\""])
    #expect(styles(lines[1]) == [.key, .string])
    #expect(styles(lines[2]) == [.key, .number])
    #expect(styles(lines[3]) == [.key, .literal])
    #expect(styles(lines[4]) == [.key, .literal])
    // The opening line of a container has a key and nothing else to colour; its elements carry
    // their own value span with no key in front.
    #expect(spanned(lines[5]).map(\.0) == ["\"e\""])
    #expect(spanned(lines[6]).map(\.0) == ["2"])
    #expect(styles(lines[6]) == [.number])
    #expect(lines.last?.spans.isEmpty == true)
}

/// The offsets are Character offsets into `text`, so a key with an emoji in it does not send the
/// highlight sideways -- the view lays the line out in characters, not in bytes.
@Test func spanOffsetsAreCharacters() throws {
    let value = try #require(JSONDocument.parse("{\"e\\uD83D\\uDE80\":\"x\"}"))
    let line = JSONDocument.pretty(value)[1]
    #expect(line.text == "  \"e\u{1F680}\": \"x\"")
    #expect(spanned(line).map(\.0) == ["\"e\u{1F680}\"", "\"x\""])
}

/// A control character or a quote inside a value has to go back out escaped, or one string with a
/// newline in it would silently become two lines of a document whose lines are its fold points.
@Test func stringsGoBackOutEscaped() throws {
    let value = try #require(JSONDocument.parse("{\"a\":\"one\\ntwo \\\"q\\\" \\u0007\"}"))
    #expect(JSONDocument.pretty(value)[1].text == "  \"a\": \"one\\ntwo \\\"q\\\" \\u0007\"")
}

/// `{}` on its own line, then `}` on the next, is two lines that say what one line says. The empty
/// container is also not a fold point: there is nothing behind it to hide.
@Test func emptyContainersStayOnOneLine() throws {
    let value = try #require(JSONDocument.parse("{\"x\":{},\"y\":[],\"z\":1}"))
    let lines = JSONDocument.pretty(value)
    #expect(lines.map(\.text) == ["{", "  \"x\": {},", "  \"y\": [],", "  \"z\": 1", "}"])
    #expect(lines[1].node == nil)
    #expect(JSONDocument.pretty(.object([])).map(\.text) == ["{}"])
    #expect(JSONDocument.pretty(.array([])).map(\.text) == ["[]"])
}

/// The opening line of a container is the only line that can be folded, so it is the only line
/// that carries a path -- and it carries the count the placeholder will need, so folding does not
/// have to walk the tree again.
@Test func openingLinesCarryNodePathAndChildCount() throws {
    let value = try #require(JSONDocument.parse("{\"a\":[1,{\"b\":null}]}"))
    let lines = JSONDocument.pretty(value)
    #expect(lines.map(\.node) == [NodePath([]),
                                  NodePath([.key("a")]),
                                  nil,
                                  NodePath([.key("a"), .index(1)]),
                                  nil, nil, nil, nil])
    #expect(lines.map(\.childCount) == [1, 2, 0, 1, 0, 0, 0, 0])
}

/// A folded container is one line that says what is behind it, because a reader who folded
/// `"results"` still has to be able to tell it from `"errors"` at a glance.
@Test func foldedNodePrintsPlaceholder() throws {
    let value = try #require(JSONDocument.parse("{\"a\":[1,2],\"b\":3}"))
    let lines = JSONDocument.pretty(value, folded: [NodePath([.key("a")])])
    #expect(lines.map(\.text) == ["{", "  \"a\": \u{25B8} […] 2 items,", "  \"b\": 3", "}"])
    // Still the fold point, and still counted: clicking it again has to unfold it.
    #expect(lines[1].node == NodePath([.key("a")]))
    #expect(lines[1].childCount == 2)
    #expect(spanned(lines[1]).map(\.0) == ["\"a\"", "\u{25B8} […] 2 items"])
    #expect(styles(lines[1]) == [.key, .dim])

    let objects = try #require(JSONDocument.parse("{\"a\":{\"x\":1},\"b\":{\"y\":1,\"z\":2}}"))
    #expect(JSONDocument.pretty(objects, folded: [NodePath([.key("a")]),
                                                  NodePath([.key("b")])]).map(\.text)
            == ["{", "  \"a\": \u{25B8} {…} 1 key,", "  \"b\": \u{25B8} {…} 2 keys", "}"])

    // Folding the root leaves the one line, with no key in front of it.
    #expect(JSONDocument.pretty(objects, folded: [NodePath([])]).map(\.text)
            == ["\u{25B8} {…} 2 keys"])
    // An array element that is folded has no key either, and keeps its comma.
    let inArray = try #require(JSONDocument.parse("[{\"x\":1},2]"))
    #expect(JSONDocument.pretty(inArray, folded: [NodePath([.index(0)])]).map(\.text)
            == ["[", "  \u{25B8} {…} 1 key,", "  2", "]"])
    // A fold on a path that is not a container, or is not there at all, changes nothing.
    #expect(JSONDocument.pretty(value, folded: [NodePath([.key("b")]), NodePath([.key("zz")])])
            == JSONDocument.pretty(value))
}

/// The pretty printer runs on the main thread while the user is looking at the response, so a body
/// big enough to be worth folding must not be a pause.
///
/// Two megabytes of records shaped like an API's -- an id, some text, a list, a nested object --
/// because what this costs is a line, not a byte, and it is the *records* that decide how many
/// lines two megabytes is. The figure it guards is the one a regression would blow through by an
/// order of magnitude: a `String(repeating:)` per line, or a `NodePath` rebuilt for every value,
/// both of which this printer has had. The budget is a debug-build budget -- `swift test` is how it
/// is run -- and the same body prints roughly four times faster in the release build a user has.
@Test(.timeLimit(.minutes(1))) func prettyPrintsTwoMegabytesQuickly() throws {
    var text = "["
    var index = 0
    while text.utf8.count < 2_000_000 {
        if index > 0 { text += "," }
        text += """
        {"id":\(index),"name":"Deployment \(index) of the acme/nyx pipeline",\
        "message":"Rolled out to 3 of 3 regions with no failing health checks reported. \
        The previous revision stayed warm for ten minutes and was then retired; \
        no request was served by both revisions at once.",\
        "created_at":"2026-09-06T12:34:56Z","score":1.50,"active":true,"note":null,\
        "tags":["production","eu-west-1","rollout"],\
        "actor":{"login":"nik","id":\(index),"url":"https://api.example.com/users/nik"}}
        """
        index += 1
    }
    text += "]"
    #expect(text.utf8.count > 2_000_000)
    let value = try #require(JSONDocument.parse(text))

    let clock = ContinuousClock()
    var lines: [JSONDocument.PrettyLine] = []
    let elapsed = clock.measure { lines = JSONDocument.pretty(value) }
    #expect(lines.count > 80_000)
    #expect(elapsed < .milliseconds(200), "pretty took \(elapsed)")
}

/// A tree too deep to print says where it stopped. Returning nothing for the subtree was a silent
/// lie: the reader saw a `[` that never closed and no sign that anything had been left out.
@Test func aSubtreeTooDeepToPrintSaysSo() {
    var value = JSONValue.null
    for _ in 0 ..< 600 { value = .array([value]) }
    let lines = JSONDocument.pretty(value)
    let cut = JSONDocument.maximumDepth + 1
    #expect(lines.count == cut * 2 + 1)
    #expect(lines[cut].text == String(repeating: " ", count: cut * 2) + "\u{2026}")
    #expect(lines[cut].spans.map(\.style) == [.dim])
    #expect(lines[cut].node == nil)
    // The brackets above it still close, so the document is not left hanging open.
    #expect(lines.last?.text == "]")
}
