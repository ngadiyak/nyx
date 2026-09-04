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
    public static func parse(_ text: String, base: Config = .defaults) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        var config = base
        // `base` carries the settings currently in force so that a typo on one line cannot silently
        // revert every *other* setting to its compiled default. That reasoning holds only for scalar
        // settings, where the file's value replaces the base's. `keybinds` and `paletteOverrides` are
        // additive -- parsing appends to them -- so carrying them over from `base` would append the
        // same file's entries again on every reload, and would keep an override alive after the user
        // deleted its line. For those two the file is the only source, so they start empty each time.
        config.keybinds = Config.defaults.keybinds
        config.paletteOverrides = Config.defaults.paletteOverrides
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
            let value = ConfigGrammar.value(after: trimmedLine[trimmedLine.index(after: eq)...])

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
                if let (dark, light) = parseThemePair(value) {
                    config.darkThemeName = dark
                    config.lightThemeName = light
                } else if value.contains(":") {
                    badValue()
                } else {
                    config.themeName = value
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
            case "keybind":
                if let binding = KeyBinding.parse(value) {
                    config.keybinds.append(binding)
                } else {
                    badValue()
                }
            default:
                diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "unknown setting '\(key)'"))
            }
        }

        return (config, diagnostics)
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
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
