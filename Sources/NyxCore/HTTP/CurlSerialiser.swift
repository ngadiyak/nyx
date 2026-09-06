import Foundation

/// Whether the written line is for running or for reading.
///
/// `.display` is one-way: it replaces credentials with bullets, so the line it produces is not the
/// line that would be sent. Only `.none` may reach a clipboard, a re-parse, or a request.
public enum Masking: Equatable {
    case none
    case display
}

/// Whether the written line is one line or a `\`-continued block.
public enum CurlLayout: Equatable {
    case oneLine
    case multiline
}

extension CurlCommand {
    /// Writes the command back out as a shell line.
    ///
    /// With `masking: .none` this is the inverse of `parse`: `parse(x.shellLine(.none, .oneLine))`
    /// is `x` for every command `parse` accepts, which is the law the corpus test enforces. The
    /// spellings are canonical, not the ones that were typed -- `CurlCommand` does not record
    /// whether the user wrote `--header` or `-H` -- so the *text* may change where the *value*
    /// does not.
    public func shellLine(masking: Masking, layout: CurlLayout) -> String {
        let groups = serialisedGroups(masking: masking).filter { !$0.isEmpty }

        switch layout {
        case .oneLine:
            return groups.flatMap { $0 }.joined(separator: " ")

        case .multiline:
            let lines = groups.map { $0.joined(separator: " ") }
            return lines.enumerated().map { index, line in
                // Two spaces of indent on every line but the first, and a trailing ` \` on every
                // line but the last -- a line that continues and a line that ends must never look
                // the same, or a pasted block silently loses its tail.
                let body = index == 0 ? line : "  " + line
                return index == lines.count - 1 ? body : body + " \\"
            }.joined(separator: "\n")
        }
    }

    /// The command as groups of already-quoted words, in serialisation order. `.multiline` puts
    /// one group per line and `.oneLine` runs them together, so both layouts carry exactly the
    /// same words in the same order and only the whitespace between them differs.
    private func serialisedGroups(masking: Masking) -> [[String]] {
        var groups: [[String]] = []

        // 1. The command itself: what is being run, how, and with which switches.
        var head: [String] = prefix.map { ShellWords.quote($0) }
        head.append("curl")
        if let method {
            head.append("-X")
            head.append(ShellWords.quote(ShellWord(method)))
        }
        if self.head { head.append("-I") }
        if get { head.append("-G") }
        if let group = shortFlagGroup() { head.append(group) }
        if flags.contains(.compressed) { head.append("--compressed") }
        groups.append(head)

        // 2. Headers, one group each.
        for header in headers {
            groups.append(["-H", ShellWords.quote(headerWord(header, masking: masking))])
        }

        // 3. Auth. A bearer token is written as the header it came from rather than as
        //    `--oauth2-bearer`, so the far more common Chrome/GitHub spelling survives untouched.
        switch auth {
        case .none:
            break
        case .basic(let user, let password):
            groups.append(["-u", ShellWords.quote(basicWord(user: user, password: password, masking: masking))])
        case .bearer(let token):
            let shown = maskedSecret(token, masking: masking)
            groups.append(["-H", ShellWords.quote(ShellWord(pieces: [.text("Authorization: Bearer ")] + shown.pieces))])
        case .header(let value):
            let shown = maskedHeader(name: "Authorization", value: value, masking: masking)
            groups.append(["-H", ShellWords.quote(ShellWord(pieces: [.text("Authorization: ")] + shown.pieces))])
        }

        // 4. Body, one group per item so a long form or a list of `-d`s reads down the page.
        switch body {
        case nil:
            break
        case .data(let items):
            for item in items { groups.append(["-d", ShellWords.quote(maskedParameterList(item, masking: masking))]) }
        case .raw(let value):
            groups.append(["--data-raw", ShellWords.quote(value)])
        case .binary(let value):
            groups.append(["--data-binary", ShellWords.quote(value)])
        case .urlencoded(let items):
            for item in items { groups.append(["--data-urlencode", ShellWords.quote(maskedParameter(item, masking: masking))]) }
        case .json(let value):
            groups.append(["--json", ShellWords.quote(value)])
        case .form(let items):
            for item in items {
                let text = item.value.text
                let isFileReference = text.hasPrefix("@") || text.hasPrefix("<")
                let value = SecretMasking.isSecretParameter(item.name) && !isFileReference
                    ? maskedSecret(item.value, masking: masking)
                    : item.value
                groups.append(["-F", ShellWords.quote(ShellWord(pieces: [.text(item.name + "=")] + value.pieces))])
            }
        case .upload(let value):
            groups.append(["-T", ShellWords.quote(value)])
        }

        // 5. Output, timing, cookies: one group each, since they are read together.
        var out: [String] = []
        if let file = output.file { out += ["-o", ShellWords.quote(file)] }
        if output.remoteName { out.append("-O") }
        if let dump = output.dumpHeaders { out += ["-D", ShellWords.quote(dump)] }
        if let write = output.writeOut { out += ["-w", ShellWords.quote(write)] }
        groups.append(out)

        var time: [String] = []
        if let value = timing.maxTime { time += ["--max-time", number(value)] }
        if let value = timing.connectTimeout { time += ["--connect-timeout", number(value)] }
        if let value = timing.retry { time += ["--retry", String(value)] }
        if let value = timing.retryDelay { time += ["--retry-delay", number(value)] }
        groups.append(time)

        var jar: [String] = []
        if let send = cookies.send { jar += ["-b", ShellWords.quote(maskedCookie(send, masking: masking))] }
        if let store = cookies.jar { jar += ["-c", ShellWords.quote(store)] }
        groups.append(jar)

        // 6. Everything this model does not name, in the order it was written.
        for entry in other where !entry.option.isEmpty {
            if entry.option.contains("=") {
                // Already `--opt=value`: one word, or re-splitting it would change what curl sees.
                groups.append([ShellWords.quote(ShellWord(entry.option))])
                continue
            }
            var words = [ShellWords.quote(ShellWord(entry.option))]
            if let value = entry.value {
                words.append(ShellWords.quote(maskedOption(entry.option, value, masking: masking)))
            }
            groups.append(words)
        }

        // 7. The URL, then any further bare words -- curl reads those as more URLs, so writing
        //    them before this one would swap which request the command makes -- then whatever the
        //    line piped or redirected its output to.
        var tail = [urlWord(masking: masking)]
        for entry in other where entry.option.isEmpty {
            if let value = entry.value { tail.append(ShellWords.quote(value)) }
        }
        if !trailingPipeline.isEmpty { tail.append(trailingPipeline) }
        groups.append(tail)

        return groups
    }

    /// The boolean switches as one short group in a fixed order, so the same command always writes
    /// the same string. `--compressed` has no letter and is appended by the caller.
    private func shortFlagGroup() -> String? {
        let order: [(Flags, Character)] = [
            (.silent, "s"), (.showError, "S"), (.location, "L"), (.insecure, "k"),
            (.include, "i"), (.verbose, "v"), (.fail, "f"), (.noBuffer, "N"),
        ]
        let letters = order.filter { flags.contains($0.0) }.map { $0.1 }
        return letters.isEmpty ? nil : "-" + String(letters)
    }

    /// `Name: value`, or curl's two one-word spellings for the degenerate cases: `Name:` removes
    /// the header entirely and `Name;` sends it empty. Both collapse to the same text once written
    /// as `Name: `, which is why they get their own branches here rather than falling out of the
    /// general case.
    private func headerWord(_ header: Header, masking: Masking) -> ShellWord {
        if header.removes { return ShellWord(header.name + ":") }
        if header.value.text.isEmpty && !header.value.containsVariable { return ShellWord(header.name + ";") }
        let value = maskedHeader(name: header.name, value: header.value, masking: masking)
        return ShellWord(pieces: [.text(header.name + ": ")] + value.pieces)
    }

    /// `-u user:password`, with one wrinkle that matters: an empty *but present* password -- the
    /// trailing colon in `-u sk_test_…:` -- is the token-as-user idiom Stripe and Twilio use, so
    /// there the secret is the *user* half and that is what gets masked. `-u nik` with no colon at
    /// all is a plain username (curl prompts for the password) and stays as written, as does a
    /// user that is a variable reference rather than a value.
    private func basicWord(user: String, password: ShellWord?, masking: Masking) -> ShellWord {
        guard let password else { return ShellWord(user) }
        if password.text.isEmpty && !password.containsVariable {
            let shown = masking == .display && !user.contains("$") ? SecretMasking.masked(user) : user
            return ShellWord(shown + ":")
        }
        let shown = maskedSecret(password, masking: masking)
        return ShellWord(pieces: [.text(user + ":")] + shown.pieces)
    }

    /// Masking never touches a word that carries a variable: `$GITHUB_TOKEN` is a *reference* to a
    /// secret, not the secret, and hiding it would remove the only part of the line the reader
    /// could still act on.
    private func maskedSecret(_ word: ShellWord, masking: Masking) -> ShellWord {
        guard masking == .display, !word.containsVariable else { return word }
        return ShellWord(SecretMasking.masked(word.text))
    }

    private func maskedHeader(name: String, value: ShellWord, masking: Masking) -> ShellWord {
        guard masking == .display, !value.containsVariable else { return value }
        return ShellWord(SecretMasking.maskedHeaderValue(name: name, value: value.text))
    }

    /// `-b` carries either a cookie string or the name of a cookie file. The string is a header's
    /// worth of credentials; the filename is a path.
    private func maskedCookie(_ word: ShellWord, masking: Masking) -> ShellWord {
        guard masking == .display, !word.containsVariable else { return word }
        return ShellWord(SecretMasking.maskedCookieString(word.text))
    }

    /// A `--data-urlencode` word: one pair, so an `&` in the value is data.
    private func maskedParameter(_ word: ShellWord, masking: Masking) -> ShellWord {
        guard masking == .display, !word.containsVariable else { return word }
        return ShellWord(SecretMasking.maskedParameter(word.text))
    }

    /// A `-d` word: curl joins every `-d` with `&`, so one word is a whole parameter list and each
    /// pair is judged by its own name.
    private func maskedParameterList(_ word: ShellWord, masking: Masking) -> ShellWord {
        guard masking == .display, !word.containsVariable else { return word }
        return ShellWord(SecretMasking.maskedParameterList(word.text))
    }

    private func maskedOption(_ option: String, _ value: ShellWord, masking: Masking) -> ShellWord {
        guard masking == .display, !value.containsVariable else { return value }
        return ShellWord(SecretMasking.maskedOptionValue(option: option, value: value.text))
    }

    /// The URL, rebuilt from `URLParts` so an edited query is what gets written -- except where
    /// rebuilding would lose something. A word carrying a variable cannot be split reliably (the
    /// scheme may be inside `$API`), and `[1-3]` / `{a,b}` are curl's own glob syntax, which the
    /// query splitter has no reading for. In both cases the word as typed is written through.
    private func urlWord(masking: Masking) -> String {
        let raw = url.raw
        if raw.containsVariable || raw.text.contains("[") || raw.text.contains("{") {
            return ShellWords.quote(raw)
        }

        var text = ""
        if let scheme = url.scheme { text += scheme + "://" }
        text += url.host
        if let port = url.port { text += ":\(port)" }
        text += url.path
        if url.query.isEmpty {
            if url.emptyQuery { text += "?" }
        } else {
            text += "?" + url.query.map { item in
                guard let value = item.value else { return item.name }
                let shown = masking == .display && SecretMasking.isSecretParameter(item.name)
                    ? SecretMasking.masked(value)
                    : value
                return "\(item.name)=\(shown)"
            }.joined(separator: "&")
        }
        if let fragment = url.fragment { text += "#" + fragment }
        return ShellWords.quote(ShellWord(text))
    }

    /// `5`, not `5.0`: curl accepts both, but a command that grows a decimal point every time it
    /// is written back out stops looking like the one the user typed. Never exponent notation
    /// either -- `String(0.00001)` is `"1e-05"`, which curl rejects outright. The shortest plain
    /// decimal that reads back as the same `Double` is found by widening the precision until it
    /// does, so no digit the user typed is lost and none is invented.
    private func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        for precision in 1 ... 17 {
            var text = String(format: "%.\(precision)f", value)
            guard Double(text) == value else { continue }
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
        return String(value) // unreachable for any timeout a person would write
    }
}
