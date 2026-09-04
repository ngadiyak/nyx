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
    /// Whether Nyx injects its OSC 133 hooks into the shell. Everything built on prompt marks --
    /// jumping between commands, the status gutter, copying a command's output -- is inert without
    /// them, and almost no shell emits them unaided.
    public var shellIntegration: ShellIntegrationMode = .auto
    /// Task 8 populates this from `keybind` lines; see `KeyBinding.parse`.
    public var keybinds: [KeyBinding] = []
    /// User-defined buttons: `quick = <name> | <kind> | <command>`. Additive, like `keybind`.
    public var quickActions: [QuickAction] = []
    public var paletteOverrides: [Int: RGB] = [:]

    public static let defaults = Config()
}

public extension Config {
    /// A commented file listing every setting at its default value, for `⌘,` to create. Every line
    /// is commented out, so `ConfigParser.parse` of this text returns exactly `Config.defaults` with
    /// no diagnostics -- `ConfigTests.theDefaultFileTextParsesBackToTheDefaults` checks that, which
    /// is what stops this file drifting from `Config`'s actual defaults as settings are added.
    static var defaultFileText: String {
        #"""
        # Nyx configuration file.
        #
        # Every setting below is shown at its default value and commented out. Uncomment a line and
        # edit it to change that setting; Nyx watches this file and reloads automatically on save.
        # Lines starting with '#' are comments. `nyx-dark` and the other built-in theme names are
        # documented in the reference; a `key = value` you don't recognise is reported, not fatal --
        # the rest of the file, and your previous working config, stay in force.

        # --- Font ---
        # font-family = Menlo
        # font-size = 13
        # line-height = 1.0
        # font-thicken = false

        # --- Theme ---
        # A single theme name, or `dark:<name>,light:<name>` to follow the system appearance.
        # theme = nyx-dark
        # One override per line: `palette = <0-255>=<#rrggbb>`.
        # palette = 0=#1a1b26

        # --- Cursor ---
        # cursor-style = block
        # cursor-blink = true

        # --- Scrollback ---
        # scrollback-lines = 10000

        # --- Window ---
        # padding = 8
        # background-opacity = 1.0
        # background-blur = 0
        # window-decorations = true
        # tab-bar = auto

        # --- Shell ---
        # shell =
        # working-directory = inherit

        # --- Behaviour ---
        # copy-on-select = false
        # middle-click-paste = true
        # option-as-meta = none
        # mouse-scroll-alt-screen = true
        # bell = visual
        # confirm-close-process = true
        # clipboard-read = false
        # word-separators = ()[]{}'"`, ;:|<>
        # --- Quick actions ---
        # Buttons for commands you run over and over. `send` types it into the current pane, `run`
        # opens a new tab for it, and `toggle` starts it in the background and stops it when you
        # press again -- which is what something like `caffeinate -d` wants, rather than a whole tab
        # spent babysitting it. The kind may be left out, and defaults to `send`.
        # quick = Caffeine | toggle | caffeinate -d
        # quick = Deploy | ./deploy.sh

        # shell-integration = auto
        # open-file-command =

        # --- Key bindings ---
        # One per line: `modifier+modifier+key=action`. See the reference for the action list.
        # keybind = cmd+t=new_tab
        """#
    }
}
