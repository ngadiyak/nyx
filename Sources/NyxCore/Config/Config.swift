import Foundation

public enum OptionAsMeta: String, Equatable { case none, left, right, both }
public enum BellStyle: String, Equatable { case visual, sound, none }
public enum TabBarVisibility: String, Equatable { case auto, always, never }

/// What happens when several lines are pasted at once.
public enum MultilinePaste: String, Equatable {
    /// Open them in the editor. The default: a pasted block is usually something to look at before
    /// it runs, and once it is on the shell's command line it is nearly impossible to edit.
    case edit
    /// Ask, with a preview and an Edit button.
    case confirm
    /// Paste straight through, as any other terminal does.
    case direct
}

/// One line of diagnostic output from `ConfigParser`: a config file with a typo still starts the
/// terminal, so problems are reported here instead of thrown.
public struct ConfigDiagnostic: Equatable {
    public var line: Int      // 1-based
    public var message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

/// Everything the phase-2 config file can set. See spec §6.5 for the key list.
public struct Config: Equatable {
    /// `system` means macOS's own monospaced face, SF Mono -- which Apple exposes only through
    /// `NSFont.monospacedSystemFont`, so it cannot be named here like an installed family. It is
    /// the default because it is the best-looking monospace on the machine and needs no install.
    public var fontFamily: String = "system"
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
    /// Whether the windows, tabs, splits and scrollback that were open at quit come back at the
    /// next launch. On by default: re-setting up a workspace after every restart is the complaint
    /// people make about terminals more than any other. Off means one empty window, every time.
    public var restoreSession: Bool = true
    public var clipboardRead: Bool = false
    public var tabBar: TabBarVisibility = .auto
    public var windowDecorations: Bool = true
    public var wordSeparators: Set<Character> = Set(" ()[]{}'\"`,;:|<>")
    public var openFileCommand: String?
    /// Whether Nyx injects its OSC 133 hooks into the shell. Everything built on prompt marks --
    /// jumping between commands, the status gutter, copying a command's output -- is inert without
    /// them, and almost no shell emits them unaided.
    public var shellIntegration: ShellIntegrationMode = .auto
    /// What a multi-line paste does. See `MultilinePaste`.
    public var multilinePaste: MultilinePaste = .edit
    /// Rows of output a fold keeps visible at the end. Three, because the error and the summary
    /// line of nearly every tool are in its last lines; 0 hides everything.
    public var foldKeepLines: Int = 3
    /// Fold finished output longer than this many rows once the next command starts. Off by
    /// default: a terminal that hides things on its own has to earn that first.
    public var foldLongOutput: Int = 0
    /// Task 8 populates this from `keybind` lines; see `KeyBinding.parse`.
    public var keybinds: [KeyBinding] = []
    /// User-defined buttons: `quick = <name> | <kind> | <command>`. Additive, like `keybind`.
    public var quickActions: [QuickAction] = []
    public var paletteOverrides: [Int: RGB] = [:]

    /// Off by default: this Mac neither publishes its sessions to a relay nor accepts an attach
    /// until asked. See spec §5.1.
    public var remote: RemoteMode = .off
    /// Stored empty, not pre-filled with the Mac's current name -- `RemoteDeviceName.resolve`
    /// falls back to the machine's own name at the point of use, so a Mac renamed later picks that
    /// up instead of showing whatever name was baked into the file when remote was first turned on.
    public var remoteDeviceName: String = ""
    public var remoteRelay: String = "wss://nyx.agentforge.cc/v1/ws"
    /// Not comment-stripped (see `ConfigParser`): a token is an opaque secret that may itself
    /// contain `#`, the same reasoning as `open-file-command`.
    public var remoteRelayToken: String = ""
    /// Lines of scrollback a host sends a client as the initial snapshot before switching to the
    /// live stream. 2000 by default: enough to restore the block/fold state of a typical session
    /// without shipping an entire multi-day scrollback down the wire on every attach.
    public var remoteSnapshotLines: Int = 2000

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
        # font-family = system
        # font-size = 13
        # line-height = 1.0
        # font-thicken = false

        # --- Theme ---
        # A single theme name, or `dark:<name>,light:<name>` to follow the system appearance.
        # theme = nyx-dark
        # One override per line: `palette = <0-255>=<#rrggbb>`.
        # palette = 0=#1a1b26
        # Your own theme: a file in ~/.config/nyx/themes/ named after the theme, holding
        # `palette`, `foreground`, `background`, `cursor` and `selection` lines. A file whose
        # name matches a built-in theme replaces it. Saving the file re-colours every window.

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
        # Bring back the windows, tabs, splits and scrollback that were open at quit.
        # restore-session = true
        # clipboard-read = false
        # word-separators = ()[]{}'"`, ;:|<>
        # --- Quick actions ---
        # Buttons for commands you run over and over. `send` types it into the current pane, `run`
        # opens a new tab for it, and `toggle` starts it in the background and stops it when you
        # press again -- which is what something like `caffeinate -d` wants, rather than a whole tab
        # spent babysitting it. The kind may be left out, and defaults to `send`.
        # quick = Caffeine | toggle | caffeinate -d
        # quick = Deploy | ./deploy.sh

        # multiline-paste = edit
        # A folded command keeps its last few lines of output; 0 hides them all.
        # fold-keep-lines = 3
        # Fold output longer than this many rows once the next command starts. 0 is off.
        # fold-long-output = 0
        # shell-integration = auto
        # open-file-command =

        # --- Key bindings ---
        # One per line: `modifier+modifier+key=action`. See the reference for the action list.
        # keybind = cmd+t=new_tab

        # --- Remote ---
        # Publish this Mac's sessions to a relay so a paired Mac can find and attach to them, and
        # accept attaches from paired Macs in return. Off until you turn it on and pair a device.
        # remote = off
        # remote-device-name =
        # remote-relay = wss://nyx.agentforge.cc/v1/ws
        # remote-relay-token =
        # remote-snapshot-lines = 2000
        """#
    }
}
