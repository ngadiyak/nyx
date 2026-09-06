import Foundation
@testable import NyxCore

/// Loads the hand-written curl command lines in `Fixtures/curl/`. They live in files rather than
/// in string literals because the shapes that matter -- Chrome's `$'...'` bodies, backslash-newline
/// continuations, single quotes around JSON -- are exactly the ones a Swift literal would have to
/// re-escape, which is where a fixture stops being the thing a user actually pasted.
enum CurlFixtures {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        let reason: String
        var description: String { "curl fixture \(name): \(reason)" }
    }

    /// The raw text of `Fixtures/curl/<name>.sh`, newlines and continuations intact.
    static func line(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sh", subdirectory: "Fixtures/curl") else {
            throw Missing(name: name, reason: "not in the test bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The fixture parsed, throwing rather than returning nil so a test reads as a straight line
    /// of assertions instead of unwrapping first.
    static func command(_ name: String) throws -> CurlCommand {
        let text = try line(name)
        guard let command = CurlCommand.parse(text) else {
            throw Missing(name: name, reason: "CurlCommand.parse returned nil")
        }
        return command
    }
}

extension CurlFixtures {
    /// Every fixture, in order. The round-trip law runs over all of them: a corpus that only
    /// covers the shapes the serialiser already handles proves nothing.
    static let all = [
        "01-chrome-copy-as-curl",
        "02-postman",
        "03-github-api",
        "04-stripe-basic-auth",
        "05-multiline-continuations",
        "06-get-with-urlencode",
        "07-form-upload",
        "08-json-flag",
        "09-body-from-file",
        "10-pipeline",
        "11-prefix-and-globs",
        "12-head-and-timeouts",
    ]
}
