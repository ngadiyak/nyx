import Foundation

/// A theme file as it was found on disk: its name, and its text. Reading the directory is the
/// application's job -- this module decides what the contents mean.
public struct ThemeFile: Equatable {
    /// The file's name without its extension, which is the name a `theme = ` line uses.
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// Something wrong with a theme file, in the same shape as a config diagnostic so a window can put
/// it in the same banner.
public struct ThemeDiagnostic: Equatable {
    public let name: String
    public let message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

/// Every theme this installation has: the built-in ones, and whatever the user has put in their
/// themes directory.
///
/// The built-in palettes are argued over in `Themes` -- every colour there has to be visible on the
/// theme's own background, distinguishable from the foreground, and a bright that is actually
/// brighter than its normal. A user's file is not held to that: it is their terminal, and a person
/// pasting the palette from a scheme they like should get that scheme, not a corrected version of
/// it. What they do get for free is the *derived* colours -- accent, search highlight, block
/// spines, the selection tint -- because those are computed from whatever sixteen colours are in
/// force rather than written down per theme.
public struct ThemeCatalog: Equatable {
    /// Parsed user themes by name. A user file wins over a built-in of the same name: someone who
    /// writes their own `gruvbox-dark` means theirs, and silently preferring ours would look like
    /// the file being ignored.
    public private(set) var user: [String: Palette]

    public init(user: [String: Palette] = [:]) {
        self.user = user
    }

    /// Only what ships with Nyx. The state before the themes directory has been read, and what the
    /// tests and the snapshot renderer use.
    public static let builtinOnly = ThemeCatalog()

    /// Reads a directory's worth of files, in the order given -- the caller sorts, so that a name
    /// two files both claim resolves the same way on every launch. A file with no recognised colour
    /// key is reported rather than registered: a stray `.DS_Store` or a half-written file must not become a theme that
    /// quietly keeps every default and looks like the terminal ignoring your colours.
    public static func make(files: [ThemeFile]) -> (ThemeCatalog, [ThemeDiagnostic]) {
        var user: [String: Palette] = [:]
        var problems: [ThemeDiagnostic] = []
        for file in files {
            guard !file.name.isEmpty else { continue }
            guard let palette = Themes.parse(file.text) else {
                problems.append(ThemeDiagnostic(name: file.name,
                                                message: "no colours in theme \"\(file.name)\""))
                continue
            }
            // Two files can claim one name -- `mine` and `mine.bak` both mean `mine`, and the
            // second is exactly what a person makes before editing the first. The earlier file in
            // the caller's order wins, and the loser is named: a theme quietly resolving to
            // whichever file the filesystem happened to hand over first is unexplainable.
            if user[file.name] != nil {
                problems.append(ThemeDiagnostic(name: file.name,
                                                message: "two files both name the theme \"\(file.name)\"; using the first"))
                continue
            }
            user[file.name] = palette
        }
        return (ThemeCatalog(user: user), problems)
    }

    /// The palette for a name: the user's, then the built-in, then `nyx-dark` -- the same
    /// last-resort `Themes.palette(named:)` has, because a `theme =` line naming something that is
    /// not there is a typo, and a terminal that refuses to draw is a worse answer than a default.
    public func palette(named name: String) -> Palette {
        user[name] ?? Themes.palette(named: name)
    }

    /// Whether a name is a theme at all, for telling a typo from a deliberate choice.
    public func contains(_ name: String) -> Bool {
        user[name] != nil || Themes.builtin[name] != nil
    }

    /// Every theme that can be chosen, sorted, for the settings window and the command palette.
    public var names: [String] {
        Array(Set(Themes.builtin.keys).union(user.keys)).sorted()
    }
}
