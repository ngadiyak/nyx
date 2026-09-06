import Testing
@testable import NyxCore

@Test func splitsOnWhitespaceAndKeepsQuotesTogether() {
    let line = "curl -H 'Accept: application/json' \"https://x/y z\""
    let words = ShellWords.split(line)
    #expect(words?.map(\.text) == ["curl", "-H", "Accept: application/json", "https://x/y z"])
}

@Test func backslashNewlineIsAContinuation() {
    let line = "curl \\\n  -s \\\n  https://x"
    let words = ShellWords.split(line)
    #expect(words?.map(\.text) == ["curl", "-s", "https://x"])
}

@Test func variablesSurvive() {
    let line = "-H \"Authorization: Bearer $TOKEN\""
    let words = ShellWords.split(line)
    #expect(words?.count == 2)
    #expect(words?[1].pieces == [.text("Authorization: Bearer "), .variable("$TOKEN")])
    #expect(words?[1].containsVariable == true)
    #expect(words?[1].isVariable == false)

    let bareVar = ShellWords.split("$TOKEN")
    #expect(bareVar?.count == 1)
    #expect(bareVar?[0].isVariable == true)
}

@Test func singleQuotesAreLiteral() {
    let words = ShellWords.split("'$NOT_A_VAR'")
    #expect(words?.count == 1)
    #expect(words?[0].pieces == [.text("$NOT_A_VAR")])
}

@Test func escapesInDoubleQuotes() {
    let line = #""a \"b\" \\ \$x""#
    let words = ShellWords.split(line)
    #expect(words?.count == 1)
    #expect(words?[0].text == #"a "b" \ $x"#)
}

@Test func unterminatedQuoteIsNil() {
    #expect(ShellWords.split("'abc") == nil)
    #expect(ShellWords.split("\"abc") == nil)
}

@Test func quoteRoundTrips() {
    let words: [ShellWord] = [
        ShellWord("plain"),
        ShellWord("has space"),
        ShellWord("it's"),
        ShellWord(pieces: [.variable("$TOKEN")]),
        ShellWord(pieces: [.text("Bearer "), .variable("$TOKEN")]),
        ShellWord("a\"b"),
    ]
    for word in words {
        let quoted = ShellWords.quote(word)
        let split = ShellWords.split(quoted)
        #expect(split == [word])
    }
}

@Test func quoteIsBareWhenSafe() {
    let quoted = ShellWords.quote(ShellWord("https://api.example.com/v1/users"))
    #expect(quoted == "https://api.example.com/v1/users")
}

@Test func queryStringIsQuoted() {
    let word = ShellWord("https://api.example.com/v1?x=1")
    let quoted = ShellWords.quote(word)
    #expect(quoted == "'https://api.example.com/v1?x=1'")
    #expect(ShellWords.split(quoted) == [word])
}
