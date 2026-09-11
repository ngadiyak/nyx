import Foundation

/// Parses the `~/.config/nyx/config` grammar: `key = value`, `#` comments, blank lines ignored.
/// Unknown keys and bad values are reported as diagnostics and the affected setting keeps its
/// `base` value (`Config.defaults` unless the caller passes one); parsing never fails outright,
/// because a terminal that refuses to start over a typo is useless.
public enum ConfigParser {
    /// `base` is what a setting keeps when its line can't be parsed. Passing the config already in
    /// force (as `ConfigStore.reload` does) means a typo on reload leaves that one field exactly as
    /// it was rather than resetting it to the compiled default -- the user keeps everything that
    /// still parses plus everything that used to work. A first load, with nothing in force yet,
    /// omits `base` and gets `Config.defaults`.
    ///
    /// A key the file no longer mentions at all is a different thing from a key whose line will not
    /// parse, and goes back to its default: see `defaultsForKeysAbsent`.
    public static func parse(_ text: String,
                             base: Config = .defaults) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        applying(text, to: defaultsForKeysAbsent(from: text, in: base))
    }

    /// `base` with every key the file does not mention put back to its default.
    ///
    /// Starting from `base` alone is right for a line that is present and unparseable -- the field
    /// keeps what it had while somebody is typing -- and wrong for a line that is *gone*: deleting
    /// `remote-relay-token` is how a person takes a Mac off the relay, and it did nothing while Nyx
    /// ran, with the settings page still showing the token as the field's value.
    ///
    /// The defaults are re-applied as *text*, from the commented line each key has in
    /// `Config.defaultFileText`, rather than from a second copy of every field: a copy would be a
    /// list to keep in step with the switch below, and the list that drifts is the one nobody
    /// notices. `applying`, not `parse`, or this would recurse through its own synthesised text.
    private static func defaultsForKeysAbsent(from text: String, in base: Config) -> Config {
        guard base != .defaults else { return base }
        let present = Set(ConfigGrammar.lines(text).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return nil }   // a commented key is not set
            return ConfigGrammar.key(ofLine: trimmed)
        })
        let missing = ConfigGrammar.scalarKeys.filter { !present.contains($0) }
        guard !missing.isEmpty else { return base }
        let lines = Config.defaultFileText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in missing.contains { line.hasPrefix("# \($0) =") } }
            .map { $0.dropFirst(2) }
        guard !lines.isEmpty else { return base }
        return applying(lines.joined(separator: "\n"), to: base).config
    }

    /// Applies the file's lines on top of `base`. Split out of `parse` so that
    /// `defaultsForKeysAbsent` can apply its synthesised default lines without recursing.
    private static func applying(_ text: String,
                                 to base: Config) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        var config = base
        // `base` carries the settings currently in force so that a typo on one line cannot silently
        // revert every *other* setting to its compiled default. That reasoning holds only for scalar
        // settings, where the file's value replaces the base's. `keybinds` and `paletteOverrides` are
        // additive -- parsing appends to them -- so carrying them over from `base` would append the
        // same file's entries again on every reload, and would keep an override alive after the user
        // deleted its line. For those two the file is the only source, so they start empty each time.
        config.keybinds = Config.defaults.keybinds
        config.paletteOverrides = Config.defaults.paletteOverrides
        config.quickActions = Config.defaults.quickActions
        var diagnostics: [ConfigDiagnostic] = []

        let lines = ConfigGrammar.lines(text)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }

            guard let eq = trimmedLine.firstIndex(of: "=") else {
                diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "expected 'key = value', got '\(trimmedLine)'"))
                continue
            }
            let key = trimmedLine[trimmedLine.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            // A key whose value is a command line keeps its `#`: `quick = Note | send | echo '#1'`
            // is a command, not a comment, and silently truncating it would be a puzzling failure.
            let carriesACommand = ConfigGrammar.commentExemptKeys.contains(key)
            let value = ConfigGrammar.value(after: trimmedLine[trimmedLine.index(after: eq)...],
                                            stripComments: !carriesACommand)

            func badValue() {
                diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid value for '\(key)': '\(value)'"))
            }

            switch key {
            case "font-family":
                config.fontFamily = value
            case "font-thicken":
                if let b = parseBool(value) { config.fontThicken = b } else { badValue() }
            case "font-size":
                if let d = Double(value) { config.fontSize = min(max(d, 4), 144) } else { badValue() }
            case "line-height":
                if let d = Double(value) { config.lineHeight = min(max(d, 0.5), 3) } else { badValue() }
            case "theme":
                // One key, three fields, and every branch assigns all three. A branch that set only
                // the fields it mentioned meant editing `theme = dark:nord,light:solarized-light`
                // down to plain `theme = gruvbox` left the pair in force -- and the pair wins in
                // `Pane.resolvedPalette` -- so the edit did nothing until the app was restarted.
                // Deleting the line has the same shape and is handled by `defaultsForKeysAbsent`
                // re-applying the documented `# theme = ...` line through here.
                if let (dark, light) = parseThemePair(value) {
                    config.themeName = Config.defaults.themeName
                    config.darkThemeName = dark
                    config.lightThemeName = light
                } else if value.contains(":") {
                    badValue()
                } else {
                    config.themeName = value
                    config.darkThemeName = nil
                    config.lightThemeName = nil
                }
            case "cursor-style":
                switch value.lowercased() {
                case "block": config.cursorStyle = .block
                case "underline": config.cursorStyle = .underline
                case "bar": config.cursorStyle = .bar
                default: badValue()
                }
            case "cursor-blink":
                if let b = parseBool(value) { config.cursorBlink = b } else { badValue() }
            case "scrollback-lines":
                if let i = Int(value) { config.scrollbackLines = min(max(i, 0), 10_000_000) } else { badValue() }
            case "padding":
                if let d = Double(value) { config.padding = min(max(d, 0), 200) } else { badValue() }
            case "background-opacity":
                if let d = Double(value) { config.backgroundOpacity = min(max(d, 0), 1) } else { badValue() }
            case "background-blur":
                if let d = Double(value) { config.backgroundBlur = min(max(d, 0), 100) } else { badValue() }
            case "shell":
                config.shell = value.isEmpty ? nil : value
            case "working-directory":
                config.workingDirectory = value
            case "copy-on-select":
                if let b = parseBool(value) { config.copyOnSelect = b } else { badValue() }
            case "middle-click-paste":
                if let b = parseBool(value) { config.middleClickPaste = b } else { badValue() }
            case "option-as-meta":
                if let m = OptionAsMeta(rawValue: value.lowercased()) { config.optionAsMeta = m } else { badValue() }
            case "mouse-scroll-alt-screen":
                if let b = parseBool(value) { config.mouseScrollAltScreen = b } else { badValue() }
            case "bell":
                if let s = BellStyle(rawValue: value.lowercased()) { config.bell = s } else { badValue() }
            case "confirm-close-process":
                if let b = parseBool(value) { config.confirmCloseProcess = b } else { badValue() }
            case "restore-session":
                if let b = parseBool(value) { config.restoreSession = b } else { badValue() }
            case "clipboard-read":
                if let b = parseBool(value) { config.clipboardRead = b } else { badValue() }
            case "tab-bar":
                if let t = TabBarVisibility(rawValue: value.lowercased()) { config.tabBar = t } else { badValue() }
            case "window-decorations":
                if let b = parseBool(value) { config.windowDecorations = b } else { badValue() }
            case "word-separators":
                config.wordSeparators = Set(value)
            case "open-file-command":
                config.openFileCommand = value.isEmpty ? nil : value
            case "palette":
                if let (idx, rgb) = ConfigGrammar.paletteEntry(value) {
                    config.paletteOverrides[idx] = rgb
                } else {
                    badValue()
                }
            case "shell-integration":
                if let mode = ShellIntegrationMode(rawValue: value) { config.shellIntegration = mode }
                else { badValue() }
            case "multiline-paste":
                if let mode = MultilinePaste(rawValue: value) { config.multilinePaste = mode }
                else { badValue() }
            case "fold-keep-lines":
                if let i = Int(value) { config.foldKeepLines = min(max(i, 0), 100) } else { badValue() }
            case "fold-long-output":
                if let i = Int(value) { config.foldLongOutput = min(max(i, 0), 1_000_000) } else { badValue() }
            case "quick":
                if let action = QuickAction.parse(value) { config.quickActions.append(action) }
                else { badValue() }
            case "keybind":
                if let binding = KeyBinding.parse(value) {
                    config.keybinds.append(binding)
                } else {
                    badValue()
                }
            case "remote":
                if let mode = RemoteMode(rawValue: value.lowercased()) { config.remote = mode } else { badValue() }
            case "remote-device-name":
                config.remoteDeviceName = value
            case "remote-relay":
                config.remoteRelay = value
            case "remote-relay-token":
                config.remoteRelayToken = value
            case "remote-snapshot-lines":
                if let i = Int(value) { config.remoteSnapshotLines = min(max(i, 100), 20_000) } else { badValue() }
            case "http-lens":
                if let lens = HTTPLens(rawValue: value.lowercased()) { config.httpLens = lens } else { badValue() }
            case "http-hint":
                if let b = parseBool(value) { config.httpHint = b } else { badValue() }
            case "http-watch-interval":
                if let d = Double(value) { config.httpWatchInterval = min(max(d, 1), 3600) } else { badValue() }
            case "http-history":
                if let i = Int(value) { config.httpHistory = min(max(i, 0), 500) } else { badValue() }
            default:
                diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "unknown setting '\(key)'"))
            }
        }

        return (config, diagnostics)
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return nil
        }
    }

    /// Parses `dark:a,light:b`. Returns nil (without treating it as an error) for a bare theme name.
    private static func parseThemePair(_ value: String) -> (dark: String?, light: String?)? {
        guard value.contains(":") else { return nil }
        var dark: String?
        var light: String?
        for part in value.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "dark": dark = v
            case "light": light = v
            default: return nil
            }
        }
        guard dark != nil || light != nil else { return nil }
        return (dark, light)
    }
}
