import Foundation

/// Parses the `~/.config/nyx/config` grammar: `key = value`, `#` comments, blank lines ignored.
/// Unknown keys and bad values are reported as diagnostics and the affected setting keeps its
/// default; parsing never fails outright, because a terminal that refuses to start over a typo is
/// useless.
public enum ConfigParser {
    public static func parse(_ text: String) -> (config: Config, diagnostics: [ConfigDiagnostic]) {
        var config = Config.defaults
        var diagnostics: [ConfigDiagnostic] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }

            guard let eq = trimmedLine.firstIndex(of: "=") else {
                diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "expected 'key = value', got '\(trimmedLine)'"))
                continue
            }
            let key = trimmedLine[trimmedLine.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmedLine[trimmedLine.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            func badValue() {
                diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid value for '\(key)': '\(value)'"))
            }

            switch key {
            case "font-family":
                config.fontFamily = value
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
                if let (idx, rgb) = parsePaletteEntry(value) {
                    config.paletteOverrides[idx] = rgb
                } else {
                    badValue()
                }
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

    private static func parsePaletteEntry(_ value: String) -> (Int, RGB)? {
        let parts = value.split(separator: "=", maxSplits: 1)
        guard parts.count == 2,
              let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let rgb = RGB(spec: parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (idx, rgb)
    }
}
