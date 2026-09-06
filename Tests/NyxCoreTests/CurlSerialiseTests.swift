import Testing
@testable import NyxCore

// MARK: - The law

@Test func roundTripLawOverTheCorpus() throws {
    // The whole point of the model: writing it out and reading it back must land on the same
    // value. Anything that fails here is a defect in the parser or the serialiser, never in the
    // fixture -- the fixtures are what people actually paste.
    for name in CurlFixtures.all {
        let original = try CurlFixtures.command(name)
        let line = original.shellLine(masking: .none, layout: .oneLine)
        let reparsed = CurlCommand.parse(line)
        #expect(reparsed != nil, "\(name): the serialised line did not parse:\n\(line)")
        #expect(reparsed == original, "\(name) did not round-trip:\n  out: \(line)")
    }
}

@Test func theMultilineLayoutRoundTripsToo() throws {
    // `\`-continuations are the shape people paste; if the multiline output did not read back,
    // the workbench would produce something it could not itself reopen.
    for name in CurlFixtures.all {
        let original = try CurlFixtures.command(name)
        let line = original.shellLine(masking: .none, layout: .multiline)
        #expect(CurlCommand.parse(line) == original, "\(name) did not round-trip as multiline:\n\(line)")
    }
}

@Test func wordsAreStableForUnderstoodOptions() throws {
    // Fixtures already written in curl's short spellings come back word for word. 02 is excluded
    // on purpose -- it is the Postman export, written entirely in long spellings, and the
    // serialiser is canonical: see `longSpellingsCanonicaliseToShortOnes`.
    for name in ["03-github-api", "04-stripe-basic-auth", "06-get-with-urlencode",
                 "08-json-flag", "12-head-and-timeouts"] {
        let command = try CurlFixtures.command(name)
        let out = command.shellLine(masking: .none, layout: .oneLine)
        let before = Set((ShellWords.split(try CurlFixtures.line(name)) ?? []).map(\.text))
        let after = Set((ShellWords.split(out) ?? []).map(\.text))
        #expect(after == before, "\(name) changed words:\n  gained \(after.subtracting(before))\n  lost \(before.subtracting(after))")
    }
}

@Test func longSpellingsCanonicaliseToShortOnes() throws {
    // `CurlCommand` does not record which spelling an option was written with, so a Postman
    // export comes back in curl's short forms. The model is unchanged, which is what the
    // round-trip law checks; only the text moves.
    let command = try CurlFixtures.command("02-postman")
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out.hasPrefix("curl -X PUT -L -H 'Content-Type: application/json'"))
    #expect(!out.contains("--location"))
    #expect(!out.contains("--request"))
    #expect(!out.contains("--header"))
    #expect(CurlCommand.parse(out) == command)
}

// MARK: - Layout

@Test func multilineBreaksAfterGroups() throws {
    let command = try CurlFixtures.command("03-github-api")
    let out = command.shellLine(masking: .none, layout: .multiline)
    let lines = out.components(separatedBy: "\n")

    // `curl -L`, two headers, the Authorization the parser lifted into `auth`, the URL.
    #expect(lines.count == 5, "got:\n\(out)")
    #expect(lines[0] == "curl -L \\")
    for line in lines.dropLast() {
        #expect(line.hasSuffix(" \\"), "line does not continue: \(line)")
    }
    #expect(!lines[lines.count - 1].hasSuffix("\\"))
    for line in lines.dropFirst() {
        #expect(line.hasPrefix("  "), "continuation is not indented: \(line)")
    }
}

@Test func oneLineAndMultilineCarryTheSameWords() throws {
    let command = try CurlFixtures.command("01-chrome-copy-as-curl")
    let flat = command.shellLine(masking: .none, layout: .oneLine)
    let tall = command.shellLine(masking: .none, layout: .multiline)
    #expect(ShellWords.split(flat)?.map(\.text) == ShellWords.split(tall)?.map(\.text))
}

@Test func theTailIsWrittenLastAndVerbatim() throws {
    let command = try CurlFixtures.command("10-pipeline")
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out.hasSuffix(" | jq '.items[]'"))
}

// MARK: - Order

@Test func flagsAreOneShortGroupInADefinedOrder() throws {
    let command = try #require(CurlCommand.parse("curl -N -f -v -i -k -L -S -s https://x/y"))
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out == "curl -sSLkivfN https://x/y")
}

@Test func compressedFollowsTheShortGroup() throws {
    let command = try #require(CurlCommand.parse("curl --compressed -s https://x/y"))
    #expect(command.shellLine(masking: .none, layout: .oneLine) == "curl -s --compressed https://x/y")
}

@Test func methodIsWrittenOnlyWhenItWasWritten() throws {
    let inferred = try #require(CurlCommand.parse("curl -d a=1 https://x/y"))
    #expect(inferred.effectiveMethod == "POST")
    #expect(!inferred.shellLine(masking: .none, layout: .oneLine).contains("-X"))

    let explicit = try #require(CurlCommand.parse("curl -X POST -d a=1 https://x/y"))
    #expect(explicit.shellLine(masking: .none, layout: .oneLine) == "curl -X POST -d a=1 https://x/y")
}

@Test func headerRemovalAndEmptyValueKeepTheirSpellings() throws {
    let command = try #require(CurlCommand.parse("curl -H 'Accept:' -H 'X-Empty;' https://x/y"))
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out == "curl -H Accept: -H 'X-Empty;' https://x/y")
    #expect(CurlCommand.parse(out) == command)
}

@Test func otherOptionsKeepTheirOrderAndTheirEqualsSpelling() throws {
    let command = try #require(CurlCommand.parse("curl --silent=1 --http2 --resolve x:443:1.2.3.4 https://x/y"))
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out == "curl --silent=1 --http2 --resolve x:443:1.2.3.4 https://x/y")
}

@Test func wholeNumberTimeoutsAreNotWrittenAsDecimals() throws {
    let command = try #require(CurlCommand.parse("curl --max-time 5 --retry-delay 2.5 https://x/y"))
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out.contains("--max-time 5 "))
    #expect(out.contains("--retry-delay 2.5"))
}

@Test func aGlobbedURLIsWrittenAsItWasTyped() throws {
    let command = try CurlFixtures.command("11-prefix-and-globs")
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out.contains("\"$API/users/[1-3]\""))
    #expect(out.hasPrefix("API=https://api.example.com curl "))
}

@Test func anEditedQueryIsRebuiltIntoTheURL() throws {
    // The workbench's reason for keeping `URLParts` split at all: edit a parameter, write the
    // command back out with the edit in it.
    var command = try #require(CurlCommand.parse("curl 'https://x.dev/a?page=1&limit=10'"))
    command.url.query[0].value = "7"
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out == "curl 'https://x.dev/a?page=7&limit=10'")
}

// MARK: - Masking

@Test func displayMasksBearer() throws {
    let token = "ghp_1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d9f2c"
    let command = try #require(CurlCommand.parse("curl -H 'Authorization: Bearer \(token)' https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine)
        == "curl -H 'Authorization: Bearer ••••9f2c' https://x/y")
    #expect(command.shellLine(masking: .none, layout: .oneLine).contains(token))
}

@Test func displayMasksBasicPassword() throws {
    let command = try #require(CurlCommand.parse("curl -u nik:hunter2 https://x/y"))
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("nik:••••"))
    // The bullets are not shell-safe bare, so the word is quoted -- the displayed line stays a
    // line you could paste, just not one that would work.
    #expect(out == "curl -u 'nik:••••' https://x/y")
}

@Test func displayMasksQueryToken() throws {
    let command = try #require(CurlCommand.parse("curl 'https://x/y?token=0123456789abcdef&page=2'"))
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("?token=••••cdef&page=2"))
}

@Test func displayMasksSecretBodyParameters() throws {
    let command = try #require(CurlCommand.parse("curl -d client_secret=0123456789abcdef -d grant_type=password https://x/y"))
    let out = command.shellLine(masking: .display, layout: .oneLine)
    // The bullets are not bare-safe, so the masked word is quoted; the unmasked one is not.
    #expect(out.contains("-d 'client_secret=••••cdef'"))
    #expect(out.contains("-d grant_type=password"))   // the *name* is what decides, not the value
}

@Test func displayMasksSecretFormFields() throws {
    let command = try #require(CurlCommand.parse("curl -F api_key=0123456789abcdef -F file=@a.png https://x/y"))
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("-F 'api_key=••••cdef'"))
    #expect(out.contains("-F file=@a.png"))
}

@Test func variablesAreNeverMasked() throws {
    // A variable is not a secret -- it is a reference to one. Masking it would show the user a
    // command that is missing the only part they could still act on.
    let command = try CurlFixtures.command("03-github-api")
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("$GITHUB_TOKEN"))
    #expect(!out.contains("••••"))
}

@Test func anEmptyPasswordIsNotGivenAFakeMask() throws {
    // Fixture 04's `-u sk_...:` has no password -- the secret is the user half, masked by
    // `aTokenAsUserIsMaskedWhenThePasswordIsEmpty`. What this pins is the other half: bullets
    // *after* the colon would invent a password that was never there, and a reader would go
    // looking for a credential that does not exist.
    let command = try CurlFixtures.command("04-stripe-basic-auth")
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(!out.contains(":••••"))
    #expect(out.contains("p7dc:'"))   // the line still ends at the colon
}

@Test func maskingDoesNotChangeTheModel() throws {
    // Masking is a view. It must not be reachable from any path that writes a command back.
    for name in CurlFixtures.all {
        let command = try CurlFixtures.command(name)
        _ = command.shellLine(masking: .display, layout: .multiline)
        let again = try CurlFixtures.command(name)
        #expect(again == command)
    }
}

// MARK: - Rulings on round 1 of the Task 3 review

@Test func everyMultilineBlockContinuesOnEveryLineButTheLast() throws {
    // Fixture 01's body carries a real newline; before `$'...'` quoting it put a bare line in the
    // middle of the block. This is the law that catches it for every fixture, not just that one.
    for name in CurlFixtures.all {
        let command = try CurlFixtures.command(name)
        let lines = command.shellLine(masking: .none, layout: .multiline).components(separatedBy: "\n")
        for line in lines.dropLast() {
            #expect(line.hasSuffix(" \\"), "\(name): line does not continue: \(line)")
        }
        #expect(!(lines.last ?? "").hasSuffix("\\"), "\(name): last line continues into nothing")
    }
}

@Test func aTokenAsUserIsMaskedWhenThePasswordIsEmpty() throws {
    // Stripe, Twilio and friends put the live secret in the *user* half and leave the password
    // empty. The trailing colon is what says "this is the token-as-user idiom".
    let command = try CurlFixtures.command("04-stripe-basic-auth")
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("-u '••••p7dc:'"))
    #expect(!out.contains("sk_test_4eC39HqLyjWDarjtT1zdp7dc"))
}

@Test func aUserWithNoColonIsNotMasked() throws {
    // No password half at all: curl prompts for it, so the user is just a username.
    let command = try #require(CurlCommand.parse("curl -u nik https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine) == "curl -u nik https://x/y")
}

@Test func aRealPasswordMasksOnlyThePassword() throws {
    let command = try #require(CurlCommand.parse("curl -u nik:hunter2 https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine) == "curl -u 'nik:••••' https://x/y")
}

@Test func aTokenAsUserThatIsAVariableIsNotMasked() throws {
    let command = try #require(CurlCommand.parse("curl -u $STRIPE_KEY: https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine).contains("$STRIPE_KEY:"))
}

@Test func cookieValuesAreMaskedOneByOne() throws {
    let command = try #require(CurlCommand.parse("curl -b 'session=0123456789abcd; theme=dark' https://x/y"))
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("-b 'session=••••abcd; theme=••••'"))
}

@Test func aCookieFileIsNotMasked() throws {
    // `-b` with no `=` names a file to read cookies from; there is no secret in the path.
    let command = try #require(CurlCommand.parse("curl -b cookies.txt https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine) == "curl -b cookies.txt https://x/y")
}

// MARK: - Round 1 of the Task 3 review

@Test func ampersandJoinedDataMasksEachPairByItsOwnName() throws {
    // curl joins every `-d` with `&`, so one `-d` word is a whole parameter *list*. Splitting only
    // at the first `=` masked the wrong thing: everything after the first value became "the value".
    let first = try #require(CurlCommand.parse("curl -d 'user=nik&password=0123456789abcd' https://x/y"))
    #expect(first.shellLine(masking: .display, layout: .oneLine)
        .contains("-d 'user=nik&password=••••abcd'"))

    let second = try #require(CurlCommand.parse("curl -d 'password=0123456789abcd&user=nik' https://x/y"))
    #expect(second.shellLine(masking: .display, layout: .oneLine)
        .contains("-d 'password=••••abcd&user=nik'"))
}

@Test func urlencodeIsOnePairAndIsNotSplitOnAmpersand() throws {
    // `--data-urlencode` names exactly one pair and encodes the value, so an `&` inside it is
    // data, not a separator.
    let command = try #require(CurlCommand.parse("curl -G --data-urlencode 'q=a&b' https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine).contains("--data-urlencode 'q=a&b'"))
}

@Test func aSecondBareURLKeepsItsPlace() throws {
    let command = try #require(CurlCommand.parse("curl https://a/1 https://b/2"))
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out == "curl https://a/1 https://b/2")
    #expect(CurlCommand.parse(out) == command)
}

@Test func repeatedOutputAndTwoURLsRoundTrip() throws {
    let command = try #require(CurlCommand.parse("curl -o a -o b https://a https://b"))
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out.contains("https://a https://b"))
    #expect(CurlCommand.parse(out) == command)
}

@Test func theCookieHeaderMasksPerValue() throws {
    let command = try #require(CurlCommand.parse("curl -H 'Cookie: session=0123456789abcd; theme=dark' https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine)
        .contains("-H 'Cookie: session=••••abcd; theme=••••'"))
}

@Test func secretsInOtherOptionsAreMasked() throws {
    let command = try #require(CurlCommand.parse(
        "curl -U proxyuser:0123456789abcd -E /etc/cert.pem:0123456789wxyz --key-password 0123456789efgh https://x/y"))
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("-U 'proxyuser:••••abcd'"))
    #expect(out.contains("-E '/etc/cert.pem:••••wxyz'"))
    #expect(out.contains("--key-password '••••efgh'"))
    #expect(CurlCommand.parse(command.shellLine(masking: .none, layout: .oneLine)) == command)
}

@Test func aCertPathWithNoPasswordIsNotMasked() throws {
    let command = try #require(CurlCommand.parse("curl -E /etc/cert.pem https://x/y"))
    #expect(command.shellLine(masking: .display, layout: .oneLine) == "curl -E /etc/cert.pem https://x/y")
}

@Test func anEmptyButPresentQueryIsKept() throws {
    for line in ["curl 'https://x/y?'", "curl 'https://x/y?#frag'"] {
        let command = try #require(CurlCommand.parse(line))
        let out = command.shellLine(masking: .none, layout: .oneLine)
        #expect(CurlCommand.parse(out) == command, "did not round-trip: \(out)")
    }
    let command = try #require(CurlCommand.parse("curl 'https://x/y?'"))
    #expect(command.url.emptyQuery)
    #expect(command.shellLine(masking: .none, layout: .oneLine) == "curl 'https://x/y?'")

    let plain = try #require(CurlCommand.parse("curl https://x/y"))
    #expect(!plain.url.emptyQuery)
}

@Test func deletingEveryQueryParameterDropsTheQuestionMark() throws {
    // The flag says the `?` was *written*, not that the query is empty now -- otherwise clearing
    // the parameters in the workbench would leave a `?` nobody asked for.
    var command = try #require(CurlCommand.parse("curl 'https://x/y?a=1'"))
    command.url.query = []
    #expect(command.shellLine(masking: .none, layout: .oneLine) == "curl https://x/y")
}

@Test func aFormFileReferenceIsNotASecret() throws {
    let command = try #require(CurlCommand.parse("curl -F api_key=@key.pem -F secret=<data.txt https://x/y"))
    let out = command.shellLine(masking: .display, layout: .oneLine)
    #expect(out.contains("-F api_key=@key.pem"))
    #expect(out.contains("-F 'secret=<data.txt'"))
}

@Test func numbersAreWrittenAsPlainDecimals() throws {
    // `String(1e-05)` is "1e-05", which curl rejects.
    let command = try #require(CurlCommand.parse("curl --max-time 5 --connect-timeout 0.00001 --retry-delay 2.50 https://x/y"))
    let out = command.shellLine(masking: .none, layout: .oneLine)
    #expect(out.contains("--max-time 5 "))
    #expect(out.contains("--connect-timeout 0.00001 "))
    #expect(out.contains("--retry-delay 2.5 "))
    #expect(!out.contains("e-"))
    #expect(CurlCommand.parse(out) == command)
}
