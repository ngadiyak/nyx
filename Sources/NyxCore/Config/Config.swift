import Foundation

public enum OptionAsMeta: String, Equatable { case none, left, right, both }
public enum BellStyle: String, Equatable { case visual, sound, none }
public enum TabBarVisibility: String, Equatable { case auto, always, never }

/// One line of diagnostic output from `ConfigParser`: a config file with a typo still starts the
/// terminal, so problems are reported here instead of thrown.
public struct ConfigDiagnostic: Equatable {
    public var line: Int      // 1-based
    public var message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

/// Everything the phase-2 config file can set. See spec §6.5 for the key list.
public struct Config: Equatable {
    public var fontFamily: String = "Menlo"
    public var fontThicken: Bool = false
    public var fontSize: Double = 13
    public var lineHeight: Double = 1.0
    public var themeName: String = "nyx-dark"
    public var darkThemeName: String?
    public var lightThemeName: String?
    public var cursorStyle: CursorShape = .block
    public var cursorBlink: Bool = true
    public var scrollbackLines: Int = 10_000
    public var padding: Double = 8
    public var backgroundOpacity: Double = 1.0
    public var backgroundBlur: Double = 0
    public var shell: String?
    public var workingDirectory: String = "inherit"
    public var copyOnSelect: Bool = false
    public var middleClickPaste: Bool = true
    public var optionAsMeta: OptionAsMeta = .none
    public var mouseScrollAltScreen: Bool = true
    public var bell: BellStyle = .visual
    public var confirmCloseProcess: Bool = true
    public var clipboardRead: Bool = false
    public var tabBar: TabBarVisibility = .auto
    public var windowDecorations: Bool = true
    public var wordSeparators: Set<Character> = Set(" ()[]{}'\"`,;:|<>")
    public var openFileCommand: String?
    /// Task 8 populates this from `keybind` lines; see `KeyBinding.parse`.
    public var keybinds: [KeyBinding] = []
    public var paletteOverrides: [Int: RGB] = [:]

    public static let defaults = Config()
}
