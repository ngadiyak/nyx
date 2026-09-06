import Foundation
import Testing
@testable import NyxCore

private let sampleText = """
{"items":[{"id":1,"name":"a"},{"id":2,"name":"b"},{"id":3,"name":"c"}],\
"meta":{"name":"root","count":3},"empty":null}
"""
private let sample = JSONDocument.parse(sampleText) ?? .null

@Test func theSampleParses() {
    #expect(sample != .null)
}

// MARK: - Parsing the subset

@Test func parsesTheSubset() {
    #expect(JSONPath.parse(".") == .identity)
    #expect(JSONPath.parse(".a") == .key("a"))
    #expect(JSONPath.parse(".a.b") == .chain([.key("a"), .key("b")]))
    #expect(JSONPath.parse(".a[\"k y\"]") == .chain([.key("a"), .key("k y")]))
    #expect(JSONPath.parse(".a[0]") == .chain([.key("a"), .index(0)]))
    #expect(JSONPath.parse(".a[-1]") == .chain([.key("a"), .index(-1)]))
    #expect(JSONPath.parse(".a[1:3]") == .chain([.key("a"), .slice(1, 3)]))
    #expect(JSONPath.parse(".a[:2]") == .chain([.key("a"), .slice(nil, 2)]))
    #expect(JSONPath.parse(".a[2:]") == .chain([.key("a"), .slice(2, nil)]))
    #expect(JSONPath.parse(".a[]") == .chain([.key("a"), .iterate(optional: false)]))
    #expect(JSONPath.parse(".a[]?.b") == .chain([.key("a"), .iterate(optional: true), .key("b")]))
    #expect(JSONPath.parse(".[]") == .iterate(optional: false))
    #expect(JSONPath.parse("keys") == .keys)
    #expect(JSONPath.parse("length") == .length)
    #expect(JSONPath.parse("..name") == .recurse("name"))
    #expect(JSONPath.parse(".[] | .id") == .pipe(.iterate(optional: false), .key("id")))
    #expect(JSONPath.parse(".items[]|keys") == .pipe(.chain([.key("items"),
                                                             .iterate(optional: false)]), .keys))
    // Whitespace around the whole thing is what a paste brings with it.
    #expect(JSONPath.parse("  .a  ") == .key("a"))
}

/// Everything jq can do that this box cannot. Guessing at `select` or `map` would be worse than
/// refusing: the reader would get a filtered list with no way to tell it was filtered wrongly.
@Test func rejectsOtherJq() {
    #expect(JSONPath.parse("select(.a)") == nil)
    #expect(JSONPath.parse("map(.x)") == nil)
    #expect(JSONPath.parse(".a as $x") == nil)
    #expect(JSONPath.parse("") == nil)
    #expect(JSONPath.parse("a") == nil, "a bare word is not a path")
    #expect(JSONPath.parse(".a |") == nil)
    #expect(JSONPath.parse(".a | .b | .c") == nil, "one pipe stage only")
    #expect(JSONPath.parse(".a?") == nil, "`?` is only understood after `[]`")
    #expect(JSONPath.parse(".a[") == nil)
    #expect(JSONPath.parse(".a[x]") == nil)
    #expect(JSONPath.parse("..name.x") == nil)
}

/// The one sentence the box shows when it cannot help, and it names the tool that can.
@Test func unsupportedSaysWhereToGo() {
    #expect(JSONPath.unsupportedMessage == "Not supported here — Run with jq")
}

// MARK: - Evaluating

@Test func evaluateKey() {
    #expect(JSONPath.evaluate(.identity, on: sample) == [sample])
    #expect(JSONPath.evaluate(.chain([.key("meta"), .key("count")]), on: sample) == [.number("3")])
    // jq's rule: a key that is not there is null, not an error and not nothing.
    #expect(JSONPath.evaluate(.key("nope"), on: sample) == [.null])
    #expect(JSONPath.evaluate(.key("a"), on: .number("1")) == [.null])
    #expect(JSONPath.evaluate(.key("a"), on: .null) == [.null])
}

@Test func evaluateIterateFansOut() {
    #expect(JSONPath.evaluate(.chain([.key("items"), .iterate(optional: false), .key("id")]),
                              on: sample) == [.number("1"), .number("2"), .number("3")])
    // On an object it is the values, in the order the object has them.
    #expect(JSONPath.evaluate(.chain([.key("meta"), .iterate(optional: false)]), on: sample)
            == [.string("root"), .number("3")])
}

/// `.[]?` on something that cannot be iterated is jq's "quietly nothing". We have no error channel
/// to draw the other half of jq's distinction with, so the plain `.[]` is quiet here too.
@Test func optionalIterateOnNonArrayIsEmpty() {
    let name = JSONValue.string("root")
    #expect(JSONPath.evaluate(.iterate(optional: true), on: name).isEmpty)
    #expect(JSONPath.evaluate(.iterate(optional: false), on: name).isEmpty)
    #expect(JSONPath.evaluate(.chain([.key("empty"), .iterate(optional: true), .key("x")]),
                              on: sample).isEmpty)
}

@Test func sliceAndNegativeIndex() {
    let items = JSONPath.evaluate(.key("items"), on: sample)[0]
    guard case .array(let all) = items else {
        Issue.record("items is not an array")
        return
    }
    #expect(JSONPath.evaluate(.chain([.key("items"), .index(-1)]), on: sample) == [all[2]])
    #expect(JSONPath.evaluate(.chain([.key("items"), .index(0)]), on: sample) == [all[0]])
    #expect(JSONPath.evaluate(.chain([.key("items"), .index(9)]), on: sample) == [.null])
    #expect(JSONPath.evaluate(.chain([.key("items"), .index(-9)]), on: sample) == [.null])
    #expect(JSONPath.evaluate(.chain([.key("items"), .slice(1, 3)]), on: sample)
            == [.array([all[1], all[2]])])
    // Out of range at either end clamps rather than failing -- `[0:100]` is how a person asks for
    // "the first hundred, however many there are".
    #expect(JSONPath.evaluate(.chain([.key("items"), .slice(0, 100)]), on: sample) == [items])
    #expect(JSONPath.evaluate(.chain([.key("items"), .slice(-2, nil)]), on: sample)
            == [.array([all[1], all[2]])])
    #expect(JSONPath.evaluate(.chain([.key("items"), .slice(2, 1)]), on: sample) == [.array([])])
}

@Test func keysAndLength() {
    // In the order the response has them, not sorted the way jq sorts: a reader who folded the
    // body and asked for its keys is asking about *this* document.
    #expect(JSONPath.evaluate(.pipe(.key("meta"), .keys), on: sample)
            == [.array([.string("name"), .string("count")])])
    #expect(JSONPath.evaluate(.pipe(.key("items"), .keys), on: sample)
            == [.array([.number("0"), .number("1"), .number("2")])])
    #expect(JSONPath.evaluate(.pipe(.key("empty"), .keys), on: sample).isEmpty)

    #expect(JSONPath.evaluate(.pipe(.key("items"), .length), on: sample) == [.number("3")])
    #expect(JSONPath.evaluate(.pipe(.key("meta"), .length), on: sample) == [.number("2")])
    #expect(JSONPath.evaluate(.pipe(.chain([.key("meta"), .key("name")]), .length), on: sample)
            == [.number("4")])
    #expect(JSONPath.evaluate(.pipe(.key("empty"), .length), on: sample) == [.number("0")])
}

/// `..name` is the one thing that makes a strange response readable: every `message`, wherever the
/// API decided to put it, in the order they appear.
@Test func recurseFindsAllNamed() {
    #expect(JSONPath.evaluate(.recurse("name"), on: sample)
            == [.string("a"), .string("b"), .string("c"), .string("root")])
    #expect(JSONPath.evaluate(.recurse("nope"), on: sample).isEmpty)
}

@Test func pipe() {
    #expect(JSONPath.evaluate(.pipe(.chain([.key("items"), .iterate(optional: false)]),
                                    .key("name")), on: sample)
            == [.string("a"), .string("b"), .string("c")])
    let parsed = JSONPath.parse(".items[] | .name")
    #expect(parsed != nil)
    #expect(JSONPath.evaluate(parsed ?? .identity, on: sample)
            == [.string("a"), .string("b"), .string("c")])
}
