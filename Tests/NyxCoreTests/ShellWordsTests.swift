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

@Test func ansiCQuotingIsLiteral() {
    let line = #"$'{"a":1}'"#
    let words = ShellWords.split(line)
    #expect(words?.count == 1)
    #expect(words?.first?.text == #"{"a":1}"#)
    #expect(words?.first?.pieces == [.text(#"{"a":1}"#)])

    guard let word = words?.first else { return }
    let quoted = ShellWords.quote(word)
    #expect(quoted == #"'{"a":1}'"#)
    #expect(ShellWords.split(quoted) == [word])
}

@Test func ansiCEscapesDecode() {
    let line = #"$'a\nb\x41'"#
    let words = ShellWords.split(line)
    #expect(words?.count == 1)
    #expect(words?.first?.text == "a\nbA")
}

@Test func crlfContinuation() {
    let line = "curl \\\r\n  -s \\\r\n  https://x"
    let words = ShellWords.split(line)
    #expect(words?.map(\.text) == ["curl", "-s", "https://x"])
}

@Test func backtickIsEscapedInDoubleQuotes() {
    let word = ShellWord(pieces: [.text("`echo hi` "), .variable("$TOKEN")])
    let quoted = ShellWords.quote(word)
    #expect(ShellWords.split(quoted) == [word])
}

@Test func specialParametersAreVariables() {
    let names = ["$0", "$1", "$9", "$?", "$#", "$@", "$*", "$$"]
    for name in names {
        let words = ShellWords.split(name)
        #expect(words?.count == 1)
        #expect(words?.first?.isVariable == true)
        #expect(words?.first?.pieces == [.variable(name)])
    }
}

@Test func anEmptyQuotedWordEqualsTheEmptyWord() {
    let words = ShellWords.split("curl -d ''")
    #expect(words?.count == 3)
    #expect(words?[2] == ShellWord(""))
    #expect(words?[2].text == "")
    #expect(words?[2].containsVariable == false)
    // Built directly with no pieces, it must still be that same word -- otherwise two spellings
    // of "empty" exist and `==` disagrees with `text`.
    #expect(ShellWord(pieces: []) == ShellWord(""))
    #expect(ShellWords.quote(ShellWord(pieces: [])) == "''")
}
