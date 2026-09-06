import Foundation

/// What the request editor is showing, as a value.
///
/// The sheet is a form over one `CurlCommand`: every control writes into this model and the whole
/// sheet is then redrawn from it. Nothing about the request lives in a view -- not which rows the
/// Params tab has, not whether a value is masked, not what the Options tab's badge says -- because
/// a rule kept in a control's target/action is a rule nothing on this machine can test.
///
/// Reading and running are deliberately different strings. `preview` is masked and can only be
/// looked at; `runLine` is what would actually be sent, with the workbench's own `-sS -i -w`
/// additions; `copyLine` is the user's own command in one line with nothing added and nothing
/// hidden. Mixing them up is how a credential ends up on a screen share or a `••••` ends up in a
/// shell.
public struct RequestEditorModel: Equatable {
    public enum Tab: String, CaseIterable {
        case params = "Params"
        case headers = "Headers"
        case body = "Body"
        case auth = "Auth"
        case options = "Options"
    }

    /// One row of the Params or Headers table, ready to draw.
    ///
    /// `isEditable` is false for a row the model derives rather than stores (`--json`'s implied
    /// headers, a `-G` data pair, every parameter of a URL that carries a variable) **and** for a
    /// row whose value is currently masked: a masked field that accepted typing would write four
    /// bullets into the request. Revealing secrets is what makes those editable.
    public struct Field: Equatable {
        public var name: String
        public var value: String
        public var isEditable: Bool

        public init(name: String, value: String, isEditable: Bool) {
            self.name = name
            self.value = value
            self.isEditable = isEditable
        }
    }

    /// Which of curl's authentication spellings the Auth tab is showing.
    public enum AuthKind: String, CaseIterable {
        case none = "None"
        case basic = "Basic"
        case bearer = "Bearer"
        case header = "Header"
    }

    /// The Auth tab's fields as they should be shown right now. `user` is empty for everything but
    /// Basic; `secret` is the password, the bearer token or the whole `Authorization` value.
    public struct AuthFields: Equatable {
        public var kind: AuthKind
        public var user: String
        public var secret: String
        public var isEditable: Bool

        public init(kind: AuthKind, user: String, secret: String, isEditable: Bool) {
            self.kind = kind
            self.user = user
            self.secret = secret
            self.isEditable = isEditable
        }
    }

    /// What the response should be shown as. These four rewrite `-i`, `-o` and `-w` between them;
    /// nothing else on the command is touched.
    public enum OutputMode: String, CaseIterable {
        case headersAndBody = "Headers and body"
        case bodyOnly = "Body only"
        case statusOnly = "Status line only"
        case saveBody = "Save body to file…"
    }

    public var command: CurlCommand
    public var tab: Tab

    public init(command: CurlCommand) {
        self.command = command
        self.tab = .params
    }

    // MARK: - The method popup

    /// The seven methods the popup offers.
    public static let standardMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    /// The popup's items: the seven, plus this command's own method when it is not one of them.
    /// A popup that cannot show `PURGE` is a popup that silently turns it into `GET` the first
    /// time the sheet is redrawn.
    public var methods: [String] {
        let current = command.effectiveMethod
        return Self.standardMethods.contains(current) ? Self.standardMethods
            : Self.standardMethods + [current]
    }

    /// Sets the method, writing `-X` only when curl would otherwise send something else. A body
    /// already means POST and `-I` already means HEAD, so spelling those out adds a word that
    /// changes nothing -- and the command the user pasted stops round-tripping to itself.
    public mutating func setMethod(_ m: String) {
        var without = command
        without.method = nil
        command.method = without.effectiveMethod == m ? nil : m
    }

    // MARK: - The URL field

    /// The URL as the field should show it.
    public var urlString: String { command.url.string }

    /// Re-reads the URL field. The text is taken as literal except for variable references, so
    /// `$API/v1` stays expandable and a URL with a `?` or a `&` in a value is not re-quoted.
    public mutating func setURLString(_ s: String) {
        command.url = CurlCommand.URLParts.parse(ShellWords.word(literal: s))
    }

    /// Whether the query rows can be written back. A URL carrying a variable or one of curl's own
    /// `[1-3]` / `{a,b}` globs is written back out **as typed** -- the split into host and query is
    /// a guess there -- so an edited row would be silently dropped. `paramsNote` says so on screen.
    public var queryIsEditable: Bool {
        let raw = command.url.raw
        return !raw.containsVariable && !raw.text.contains("[") && !raw.text.contains("{")
    }

    public mutating func setQuery(_ items: [CurlCommand.QueryItem]) {
        command.url.query = items
        // Deleting every parameter drops the `?` as well; a URL ending in a bare `?` is one
        // nobody typed.
        command.url.emptyQuery = false
        syncURLText()
    }

    /// Writes the parts back into `raw` and `string` so the URL field, the serialiser and the run
    /// line all agree after a query edit. Draft rows are left out: a row whose name has not been
    /// typed yet must not turn the URL field into `…?=`.
    private mutating func syncURLText() {
        guard queryIsEditable else { return }
        var parts = command.url
        parts.query = parts.query.filter { !$0.name.isEmpty }
        command.url.raw = ShellWord(parts.rebuilt)
        command.url.string = parts.rebuilt
    }

    /// The command without its half-typed rows.
    ///
    /// Pressing `+` puts a row in the table before it has a name, and that row has to be somewhere
    /// the table can see it -- so it lives in `command` like any other, and everything that leaves
    /// this sheet (the preview, the run line, the copy, an export, a saved button) goes through
    /// here instead. Without it, `+` followed by Run sent `?=`, and `-H ';'` -- which curl rejects
    /// outright -- for a header the user had not finished typing.
    public var serialisedCommand: CurlCommand {
        var serialised = command
        serialised.url.query = serialised.url.query.filter { !$0.name.isEmpty }
        serialised.headers = serialised.headers.filter { !$0.name.isEmpty }
        return serialised
    }

    // MARK: - Params

    /// The Params tab's rows: the URL's own query, then -- under `-G`, where curl appends the data
    /// to the query string instead of sending a body -- the `-d` and `--data-urlencode` pairs,
    /// read-only, because they live in the Body tab and this is where they will actually be sent.
    public func paramRows(revealed: Bool) -> [Field] {
        var rows = command.url.query.map { item in
            Field(name: item.name,
                  value: shown(parameter: item.name, value: item.value ?? "",
                               hasVariable: false, revealed: revealed),
                  isEditable: queryIsEditable
                      && (revealed || !isMaskedParameter(item.name, hasVariable: false)))
        }
        guard command.get, let body = command.body else { return rows }
        switch body {
        case .data(let items):
            for item in items {
                // curl joins every `-d` with `&`, so one word can be a whole list of pairs.
                for pair in item.text.split(separator: "&", omittingEmptySubsequences: false) {
                    rows.append(pairRow(String(pair), hasVariable: item.containsVariable,
                                        revealed: revealed))
                }
            }
        case .urlencoded(let items):
            // One pair per word here: an `&` inside a `--data-urlencode` value is data.
            for item in items {
                rows.append(pairRow(item.text, hasVariable: item.containsVariable,
                                    revealed: revealed))
            }
        default:
            break
        }
        return rows
    }

    /// Why some of the Params rows cannot be edited, or nil when they all can.
    public var paramsNote: String? {
        if !queryIsEditable {
            return "This URL is written with a variable or a glob, so its parameters can only be "
                + "changed in the URL field."
        }
        if command.get, let body = command.body, body.isParameterList {
            return "Under -G curl sends the body as query parameters. They are shown here and "
                + "edited in the Body tab."
        }
        return nil
    }

    private func pairRow(_ text: String, hasVariable: Bool, revealed: Bool) -> Field {
        guard let equals = text.firstIndex(of: "=") else {
            return Field(name: text, value: "", isEditable: false)
        }
        let name = String(text[text.startIndex ..< equals])
        let value = String(text[text.index(after: equals)...])
        return Field(name: name,
                     value: shown(parameter: name, value: value, hasVariable: hasVariable,
                                  revealed: revealed),
                     isEditable: false)
    }

    // MARK: - Headers

    /// The Headers tab's rows: the command's own `-H` values, then the two headers `--json` sends
    /// by itself. Without those two the tab would say a `--json` request has no headers at all,
    /// which is the opposite of what curl does.
    public func headerRows(revealed: Bool) -> [Field] {
        var rows = command.headers.map { header -> Field in
            let masked = !revealed && isMaskedHeader(header)
            return Field(name: header.name,
                         value: masked
                             ? SecretMasking.maskedHeaderValue(name: header.name, value: header.value.text)
                             : header.value.text,
                         isEditable: !masked)
        }
        if case .json = command.body {
            rows.append(Field(name: "Content-Type", value: "application/json", isEditable: false))
            rows.append(Field(name: "Accept", value: "application/json", isEditable: false))
        }
        return rows
    }

    public var headersNote: String? {
        if case .json = command.body {
            return "--json sends Content-Type and Accept itself; those two rows are not editable."
        }
        return nil
    }

    public mutating func setHeaders(_ headers: [CurlCommand.Header]) {
        command.headers = headers
    }

    /// Replaces the first header with this name, or appends it. Header names are case-insensitive
    /// on the wire, so `content-type` from Chrome and `Content-Type` from the popup are the same
    /// header and must not both be sent.
    private mutating func setHeader(name: String, value: String) {
        let word = ShellWords.word(literal: value)
        if let index = command.headers.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            command.headers[index].value = word
            command.headers[index].removes = false
        } else {
            command.headers.append(CurlCommand.Header(name: name, value: word, removes: false))
        }
    }

    /// Adds a header only when the request does not already have one by that name: a header the
    /// user wrote is the deliberate one, and an implied default must not overwrite it.
    private mutating func setHeaderIfAbsent(name: String, value: String) {
        guard !command.headers.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            return
        }
        command.headers.append(CurlCommand.Header(name: name, value: ShellWords.word(literal: value),
                                                  removes: false))
    }

    // MARK: - The body

    /// The body as editable text: every `-d` joined the way curl joins them, or the one word a
    /// `--data-raw` / `--data-binary` / `--json` carries. A multipart form or an uploaded file is
    /// not text, so it comes back empty and the tab says so rather than offering to overwrite it.
    public var bodyText: String {
        switch command.body {
        case .data(let items): return items.map(\.text).joined(separator: "&")
        case .urlencoded(let items): return items.map(\.text).joined(separator: "&")
        case .raw(let word), .binary(let word), .json(let word): return word.text
        case .form, .upload, nil: return ""
        }
    }

    /// Whether this body is sent as JSON: curl's own `--json`, or a `Content-Type` that says so.
    public var bodyIsJSON: Bool {
        if case .json = command.body { return true }
        return contentTypeHeader?.lowercased().contains("json") ?? false
    }

    /// Whether the Body tab can edit what is there at all. A `-F` form and a `-T` upload are files
    /// and fields, not a string; the tab shows what they are instead of an empty box.
    public var bodyIsEditable: Bool {
        switch command.body {
        case .form, .upload, .urlencoded: return false
        default: return true
        }
    }

    public var bodyNote: String? {
        switch command.body {
        case .form: return "This is a multipart form (-F). Edit it on the command line."
        case .upload: return "This body is a file upload (-T). Edit it on the command line."
        case .urlencoded:
            // Rewriting these as `--data-raw` would send them unescaped, which is the one thing
            // `--data-urlencode` exists to do.
            return "--data-urlencode escapes each value itself. Edit it on the command line."
        default: return nil
        }
    }

    /// The `Content-Type` this request declares, or nil.
    public var contentTypeHeader: String? {
        if case .json = command.body { return "application/json" }
        return command.headers.first { $0.name.lowercased() == "content-type" && !$0.removes }?
            .value.text
    }

    /// Replaces the body with the text in the box, as `--data-raw`: one spelling for anything the
    /// editor writes, so what is in the box is exactly what is sent, byte for byte. The content
    /// type comes from the popup beside it and replaces any header already there -- two
    /// `Content-Type` headers is a request whose meaning depends on which one the server reads.
    public mutating func setBodyText(_ text: String, contentType: String?) {
        // `--json` sends `Content-Type` *and* `Accept` by itself. Rewriting the body as
        // `--data-raw` takes both of those away, so both are written out here -- an edited request
        // that quietly stopped asking for JSON back is a different request from the one that was
        // pasted. An `Accept` the user already has is left alone; theirs is the deliberate one.
        var wasJSON = false
        if case .json = command.body { wasJSON = true }

        if let contentType, !contentType.isEmpty {
            setHeader(name: "Content-Type", value: contentType)
        }
        if wasJSON {
            setHeaderIfAbsent(name: "Accept", value: "application/json")
        }
        guard !text.isEmpty else {
            // An emptied box means "no body". `--data-raw ''` would keep making this a POST with
            // a zero-length body, which is not what deleting the text means.
            command.body = nil
            // `-X GET` was only there to override the POST the body implied. With the body gone it
            // is a word that changes nothing, and the command stops round-tripping to itself.
            normaliseMethod()
            return
        }
        command.body = .raw(ShellWords.word(literal: text))
    }

    /// Drops an explicit `-X` that says exactly what curl would do anyway.
    private mutating func normaliseMethod() {
        guard let method = command.method else { return }
        var without = command
        without.method = nil
        if without.effectiveMethod == method { command.method = nil }
    }

    /// Re-indents a JSON body, keeping the keys in the order they were written. Returns false --
    /// and changes nothing -- when the body is not JSON, so the button can say why instead of
    /// quietly doing nothing.
    public mutating func prettyPrintBody() -> Bool {
        let text = bodyText
        guard !text.isEmpty, let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return false }
        let printed = JSONIndent.reindent(text)
        guard printed != text else { return true }
        // `--json` keeps its own spelling: rewriting it as `--data-raw` would drop the two headers
        // curl sends for it, which is a different request than the one that was pretty-printed.
        if case .json = command.body {
            command.body = .json(ShellWords.word(literal: printed))
        } else {
            setBodyText(printed, contentType: nil)
        }
        return true
    }

    // MARK: - Auth

    public var authKind: AuthKind {
        switch command.auth {
        case .none: return .none
        case .basic: return .basic
        case .bearer: return .bearer
        case .header: return .header
        }
    }

    /// The Auth tab's fields. While secrets are hidden the value shown is the mask and the fields
    /// are not editable: typing into a masked field would put four bullets in the request.
    public func authFields(revealed: Bool) -> AuthFields {
        switch command.auth {
        case .none:
            return AuthFields(kind: .none, user: "", secret: "", isEditable: true)
        case .basic(let user, let password):
            // An empty *but present* password -- the trailing colon in `-u sk_test_…:` -- is the
            // token-as-user idiom Stripe and Twilio use, so there the secret is the user half.
            // `CurlSerialiser.basicWord` masks it the same way, and the two must agree or the
            // table and the preview would disagree about what is hidden.
            if let password, password.text.isEmpty, !password.containsVariable {
                let hide = !revealed && !user.contains("$")
                return AuthFields(kind: .basic, user: hide ? SecretMasking.masked(user) : user,
                                  secret: "", isEditable: !hide)
            }
            let secret = password?.text ?? ""
            let hide = !revealed && !secret.isEmpty && !(password?.containsVariable ?? false)
            return AuthFields(kind: .basic, user: user,
                              secret: hide ? SecretMasking.masked(secret) : secret,
                              isEditable: !hide)
        case .bearer(let token):
            let hide = !revealed && !token.containsVariable
            return AuthFields(kind: .bearer, user: "",
                              secret: hide ? SecretMasking.masked(token.text) : token.text,
                              isEditable: !hide)
        case .header(let value):
            let hide = !revealed && !value.containsVariable
            return AuthFields(kind: .header, user: "",
                              secret: hide ? SecretMasking.maskedHeaderValue(name: "Authorization", value: value.text) : value.text,
                              isEditable: !hide)
        }
    }

    public mutating func setAuth(_ a: CurlCommand.Auth) {
        command.auth = a
    }

    // MARK: - Options

    public mutating func toggle(_ flag: CurlCommand.Flags) {
        if command.flags.contains(flag) {
            command.flags.remove(flag)
        } else {
            command.flags.insert(flag)
        }
    }

    public mutating func setTiming(maxTime: Double?, retry: Int?) {
        command.timing.maxTime = maxTime
        command.timing.retry = retry
    }

    /// What `-w` a status-only run writes: the status on its own line for the user to read, then
    /// the sentinel the response side parses. Replacing the sentinel rather than preceding it
    /// would leave every run of this command with no status, no timings and no summary at all.
    public static let statusOnlyWriteOut = "%{http_code}\\n" + RequestRun.writeOutArgument

    /// Where "body only" sends the headers. `-D /dev/null` is the whole mechanism: `RequestRun`
    /// adds `-i` to any standalone command that is not already dumping its headers somewhere, so
    /// clearing `-i` alone got it added straight back and the mode did nothing a user could see.
    public static let discardHeaders = "/dev/null"

    public var outputMode: OutputMode {
        if let file = command.output.file {
            return file.text == Self.discardHeaders ? .statusOnly : .saveBody
        }
        return command.output.dumpHeaders?.text == Self.discardHeaders ? .bodyOnly : .headersAndBody
    }

    /// Rewrites `-i`, `-D`, `-o` and `-w` for the chosen mode. `saveBody` with no path chosen
    /// leaves the command exactly as it was: a request whose body goes to a file nobody named is
    /// worse than no change.
    public mutating func setOutputMode(_ m: OutputMode, savePath: String?) {
        switch m {
        case .headersAndBody:
            command.output.file = nil
            clearDiscardedHeaders()
            // Said out loud rather than left to `RequestRun`, which adds `-i` only to a command
            // that stands alone: a piped request would otherwise show a mode it does not have.
            command.flags.insert(.include)
            clearStatusWriteOut()
        case .bodyOnly:
            command.output.file = nil
            command.flags.remove(.include)
            command.output.dumpHeaders = ShellWord(Self.discardHeaders)
            clearStatusWriteOut()
        case .statusOnly:
            clearDiscardedHeaders()
            command.output.file = ShellWord(Self.discardHeaders)
            command.output.writeOut = ShellWord(Self.statusOnlyWriteOut)
        case .saveBody:
            guard let savePath, !savePath.isEmpty else { return }
            clearDiscardedHeaders()
            command.output.file = ShellWords.word(literal: savePath)
            clearStatusWriteOut()
        }
    }

    private mutating func clearStatusWriteOut() {
        if command.output.writeOut?.text == Self.statusOnlyWriteOut { command.output.writeOut = nil }
    }

    /// Only Nyx's own `-D /dev/null` goes; a `-D headers.txt` the user wrote is theirs.
    private mutating func clearDiscardedHeaders() {
        if command.output.dumpHeaders?.text == Self.discardHeaders { command.output.dumpHeaders = nil }
    }

    // MARK: - Badges, previews and lines

    /// The flags the Options tab has a checkbox for, in the order they are drawn.
    public static let optionFlags: [CurlCommand.Flags] = [.location, .insecure, .compressed,
                                                          .verbose, .fail]

    /// How many things each tab is holding, for the segmented control's labels ("Headers 14").
    public var tabBadges: [Tab: Int] {
        [
            .params: paramRows(revealed: true).count,
            .headers: headerRows(revealed: true).count,
            .body: command.body == nil ? 0 : 1,
            .auth: command.auth == .none ? 0 : 1,
            // Only what the Options tab actually has a control for. Counting every flag made the
            // badge say `1` for a `-s` nothing on the tab could show, let alone turn off.
            .options: Self.optionFlags.filter { command.flags.contains($0) }.count
                + (command.timing.maxTime == nil ? 0 : 1)
                + (command.timing.retry == nil ? 0 : 1)
                + (outputMode == .headersAndBody ? 0 : 1),
        ]
    }

    /// The command as a `\`-continued block with every credential masked. For reading only.
    public var preview: String { serialisedCommand.shellLine(masking: .display, layout: .multiline) }

    /// The same block with the credentials in it. Shown only when the sheet is revealing secrets.
    public var revealedPreview: String { serialisedCommand.shellLine(masking: .none, layout: .multiline) }

    /// The user's own command, one line, nothing added: what `Copy` puts on the pasteboard.
    public var copyLine: String { serialisedCommand.shellLine(masking: .none, layout: .oneLine) }

    /// The line Nyx would actually run, with the workbench's `-sS -i -w` additions.
    public var runLine: String { RequestRun.commandLine(for: serialisedCommand) }

    /// What the run cannot show, and why -- a pipeline or a redirection takes the headers and the
    /// timings away. Nil when nothing is missing.
    public var runNote: String? { RequestRun.note(for: serialisedCommand) }

    /// The name a button saved from this request gets by default: the method and where it goes.
    public var suggestedActionName: String {
        "\(command.effectiveMethod) \(command.url.host)\(command.url.path)"
    }

    /// The button this request would be saved as, before the user gets to rename it.
    ///
    /// `copyLine`, not `runLine`: a quick action is a command a person will read in their config
    /// file and may well run outside Nyx, so it is the request as they wrote it rather than the
    /// request with the workbench's own `-sS -i -w` measurement flags welded on. `.send`, because a
    /// request is a thing you run once and watch, not a background toggle.
    ///
    /// Here rather than in the sheet because two surfaces now save a button -- the workbench's Save
    /// menu and a block's ⋯ menu -- and a name suggested one way in one of them is exactly the kind
    /// of difference nobody notices until a user has two buttons for one request.
    public var quickActionDraft: QuickAction {
        QuickAction(name: suggestedActionName, kind: .send, command: copyLine)
    }

    /// A blank request, which is what the New Request action opens: `curl https://` with the
    /// caret in the URL field.
    public static func newRequest() -> RequestEditorModel {
        RequestEditorModel(command: CurlCommand(url: .parse(ShellWord("https://"))))
    }

    // MARK: - Masking

    private func isMaskedParameter(_ name: String, hasVariable: Bool) -> Bool {
        !hasVariable && SecretMasking.isSecretParameter(name)
    }

    private func isMaskedHeader(_ header: CurlCommand.Header) -> Bool {
        !header.value.containsVariable && SecretMasking.isSecretHeader(header.name)
    }

    /// A parameter value as the table should show it. A value that is a *reference* to a secret is
    /// never masked -- `$TOKEN` is not the token, and hiding it removes the only part of the row
    /// the reader could act on.
    private func shown(parameter name: String, value: String, hasVariable: Bool, revealed: Bool) -> String {
        guard !revealed, isMaskedParameter(name, hasVariable: hasVariable) else { return value }
        return SecretMasking.masked(value)
    }
}

private extension CurlCommand.Body {
    /// Whether `-G` would turn this body into query parameters.
    var isParameterList: Bool {
        switch self {
        case .data, .urlencoded: return true
        default: return false
        }
    }
}

/// What the `Run ▾` menu asks for beyond running once. The plan itself -- the timer, the stop
/// condition, where the results go -- belongs to the response side; this is only the request the
/// sheet makes of it, so the two can be built in either order.
public enum WatchPlanRequest: Equatable {
    case every(seconds: Double)
    case times(Int)
    case untilStatus(Int)

    /// What the menu item and the log line say. Written here rather than in the view so the two
    /// cannot drift apart.
    public var summary: String {
        switch self {
        case .every(let seconds):
            let text = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
            return "every \(text) s"
        case .times(let count):
            return "\(count) times"
        case .untilStatus(let code):
            return "until \(code)"
        }
    }
}

/// Re-indents JSON text without parsing it into a dictionary.
///
/// `JSONSerialization` would give back an `NSDictionary`, whose key order is a hash order: pretty-
/// printing through it re-orders the keys the user wrote, and `.sortedKeys` only trades one
/// reordering for another. Working on the text itself keeps the order by construction, and leaves
/// anything inside a string literal -- including a newline curl's `$'...'` body carries -- exactly
/// as it was.
enum JSONIndent {
    static func reindent(_ text: String) -> String {
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        var scalars = Array(text.unicodeScalars)
        // Trailing whitespace would otherwise become a blank line after the closing brace.
        while let last = scalars.last, last == "\n" || last == " " || last == "\t" || last == "\r" {
            scalars.removeLast()
        }

        func newline(_ level: Int) {
            out += "\n" + String(repeating: "  ", count: level)
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inString {
                out.unicodeScalars.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.unicodeScalars.append(c)
            case "{", "[":
                out.unicodeScalars.append(c)
                // `{}` and `[]` stay on one line: an empty object split over three is noise.
                if let next = nextSignificant(scalars, after: i), next == "}" || next == "]" {
                    break
                }
                depth += 1
                newline(depth)
            case "}", "]":
                if let previous = previousSignificant(scalars, before: i),
                   previous != "{" && previous != "[" {
                    depth = max(0, depth - 1)
                    newline(depth)
                }
                out.unicodeScalars.append(c)
            case ",":
                out.unicodeScalars.append(c)
                newline(depth)
            case ":":
                out += ": "
            case " ", "\t", "\n", "\r":
                break   // the layout is being rebuilt; the old one is dropped
            default:
                out.unicodeScalars.append(c)
            }
            i += 1
        }
        return out
    }

    private static func nextSignificant(_ scalars: [Unicode.Scalar], after index: Int) -> Unicode.Scalar? {
        var i = index + 1
        while i < scalars.count, isSpace(scalars[i]) { i += 1 }
        return i < scalars.count ? scalars[i] : nil
    }

    private static func previousSignificant(_ scalars: [Unicode.Scalar], before index: Int) -> Unicode.Scalar? {
        var i = index - 1
        while i >= 0, isSpace(scalars[i]) { i -= 1 }
        return i >= 0 ? scalars[i] : nil
    }

    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r"
    }
}
