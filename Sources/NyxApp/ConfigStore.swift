import Foundation
import NyxCore

/// Loads `~/.config/nyx/config` (or `$NYX_CONFIG`) and republishes it on change.
///
/// Watches the config directory **and** the config file: a directory watch survives an editor's
/// write-then-rename (write a temp file, then rename it over the original, which invalidates a
/// file-descriptor watch on the file itself), and only a file watch sees a file rewritten through
/// its existing inode -- which is what `echo >>` does, and what the documented way to set the relay
/// token is. Multiple filesystem events from one save (the write, then the rename) are coalesced
/// with a short debounce so they produce exactly one reload.
///
/// A parse error never loses the user's working configuration: `reload()` parses starting from the
/// `Config` already in force (as `ConfigParser`'s `base`), so a line whose value can't be parsed
/// leaves that one field exactly as it was rather than resetting it to the compiled default -- every
/// other line in the same file, valid or not, is applied on top as usual, and `diagnostics` names
/// the problem line.
final class ConfigStore {
    /// The current configuration. Replaced atomically on reload; read on the main thread only.
    private(set) var config: Config
    private(set) var diagnostics: [ConfigDiagnostic]
    /// Every theme available: the built-in ones plus whatever is in the themes directory. Reloaded
    /// with the config, because a `theme =` line and the file it names have to change together --
    /// dropping a file in and then pointing at it is two edits, and either order must work.
    private(set) var themes: ThemeCatalog = .builtinOnly
    /// Called on the main thread after every successful or failed reload.
    var onChange: ((Config, [ConfigDiagnostic]) -> Void)?

    /// `$NYX_CONFIG` if set, else `~/.config/nyx/config`.
    static var path: URL {
        ConfigPath.resolve(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var themeSource: DispatchSourceFileSystemObject?
    private var debounceItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.1

    /// `~/.config/nyx/themes` -- beside the config file, wherever that turned out to be.
    static var themesDirectory: URL {
        path.deletingLastPathComponent().appendingPathComponent("themes")
    }

    init() {
        (config, diagnostics) = ConfigStore.load()
        loadThemes()
    }

    deinit { stopWatching() }

    /// Writes a commented default file if none exists, then returns the path.
    @discardableResult
    func createIfMissing() -> URL {
        let url = ConfigStore.path
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config.defaultFileText.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Writes settings into the config file, preserving everything else in it.
    ///
    /// It deliberately does not update `config` itself: the file watcher will see the write and
    /// reload through exactly the same path as an edit made in an editor. One path means the
    /// settings window cannot end up showing a value the file does not contain.
    ///
    /// Returns whether the write succeeded; a failure leaves the file untouched.
    @discardableResult
    func write(_ settings: [(key: String, value: String)]) -> Bool {
        guard !settings.isEmpty else { return true }
        let url = createIfMissing()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = ConfigWriter.settings(settings, in: existing)
        guard updated != existing else { return true }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Rewrites every line of an additive key -- `quick`, `keybind` -- so the file holds exactly
    /// `values`. Adding, editing, reordering and deleting a button are all this one operation.
    @discardableResult
    func writeList(_ key: String, values: [String]) -> Bool {
        let url = createIfMissing()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = ConfigWriter.settingList(key, values: values, in: existing)
        guard updated != existing else { return true }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func reload() {
        (config, diagnostics) = ConfigStore.load(base: config)
        loadThemes()
        // A config file created after launch (a fresh install, `Edit Config File...`) has no watch
        // on it yet: the directory watch is what noticed it appearing.
        if fileSource == nil, FileManager.default.fileExists(atPath: ConfigStore.path.path) {
            fileSource = watch(ConfigStore.path, isFile: true)
        }
        onChange?(config, diagnostics)
    }

    /// Reads the themes directory. Problems there are reported in the same banner as config
    /// problems: from where the user is standing, a theme file that does nothing and a `theme =`
    /// line that does nothing are the same complaint.
    private func loadThemes() {
        let (files, unreadable) = ConfigStore.themeFiles()
        let (catalog, problems) = ThemeCatalog.make(files: files)
        themes = catalog
        diagnostics += unreadable
        diagnostics += problems.map { ConfigDiagnostic(line: 0, message: $0.message) }
        // A `theme =` naming nothing that exists draws nyx-dark, which is right -- and looks
        // exactly like the file being ignored, which is the complaint this feature exists to end.
        for name in [config.themeName, config.darkThemeName, config.lightThemeName].compactMap({ $0 })
        where !catalog.contains(name) {
            diagnostics.append(ConfigDiagnostic(line: 0, message: "no theme named \"\(name)\""))
        }
    }

    /// Every readable file in the themes directory, named by its filename without the extension.
    ///
    /// Extension-agnostic on purpose: `gruvbox`, `gruvbox.conf` and `gruvbox.nyx` all name the
    /// theme `gruvbox`, because the extension a person gives the file is not something the terminal
    /// should have an opinion about. Hidden files are skipped -- `.DS_Store` is not a theme.
    ///
    /// Sorted by full filename so that two files claiming the same theme name resolve the same way
    /// on every launch instead of by whatever order the filesystem enumerated them in;
    /// `ThemeCatalog` reports the collision.
    private static func themeFiles() -> ([ThemeFile], [ConfigDiagnostic]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: themesDirectory,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return ([], []) }
        var files: [ThemeFile] = []
        var problems: [ConfigDiagnostic] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Resolved, not `isRegularFile` on the link itself: people who keep their dotfiles in a
            // repository symlink every one of them into place, and a theme that works when copied
            // and vanishes when linked is indistinguishable from a theme that does not work.
            let resolved = url.resolvingSymlinksInPath()
            if (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            guard let text = try? String(contentsOf: resolved, encoding: .utf8) else {
                // Says so rather than skipping it. A file the user can see in the directory and the
                // terminal cannot read -- a permission, a broken link, a file that is not UTF-8 --
                // is exactly the case where silence looks like the feature being broken.
                problems.append(ConfigDiagnostic(line: 0,
                                                 message: "could not read theme \"\(url.lastPathComponent)\""))
                continue
            }
            files.append(ThemeFile(name: url.deletingPathExtension().lastPathComponent, text: text))
        }
        return (files, problems)
    }

    /// Missing file means defaults, not an error: a fresh install with no config yet is not a typo.
    /// A file that *exists* but can't be read (permissions, a transient I/O error, bad encoding) is
    /// different -- silently falling back would look identical to an intentional reset to defaults,
    /// so it keeps `base` and reports a diagnostic instead, the same as a bad value on one line.
    private static func load(base: Config = .defaults) -> (Config, [ConfigDiagnostic]) {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (.defaults, [])
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (base, [ConfigDiagnostic(line: 0, message: "could not read \(url.path)")])
        }
        return ConfigParser.parse(text, base: base)
    }

    func startWatching() {
        stopWatching()
        let dir = ConfigStore.path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = watch(dir)
        // And the file itself. The directory watch catches an editor's write-then-rename, and
        // catches nothing at all when a file is rewritten through its existing inode -- which is
        // what `echo >> ~/.config/nyx/config` does, and what the documented way to set the relay
        // token is. Both watches, debounced together, so one save is still one reload; the file
        // watch is re-armed on `.delete`/`.rename`, which is the case a file watch alone loses.
        fileSource = watch(ConfigStore.path, isFile: true)
        // A second watch on the themes directory: a change *inside* a subdirectory does not reach
        // the parent's watch, so without this, editing a theme file would need a config save (or a
        // restart) before it was seen -- which is precisely the loop a person is in while they are
        // getting the colours right.
        try? FileManager.default.createDirectory(at: ConfigStore.themesDirectory,
                                                 withIntermediateDirectories: true)
        themeSource = watch(ConfigStore.themesDirectory)
    }

    private func watch(_ path: URL, isFile: Bool = false) -> DispatchSourceFileSystemObject? {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.handle(src.data, isFile: isFile) }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    func stopWatching() {
        debounceItem?.cancel()
        debounceItem = nil
        source?.cancel()
        source = nil
        fileSource?.cancel()
        fileSource = nil
        themeSource?.cancel()
        themeSource = nil
    }

    private func handle(_ event: DispatchSource.FileSystemEvent, isFile: Bool) {
        if event.contains(.delete) || event.contains(.rename) {
            // The *file* was replaced by a rename, which is every atomic save -- including this
            // class's own `write`. Its descriptor is now stale, so it is re-armed; and the save
            // still has to be read, which is why this falls through to the debounce instead of
            // returning the way the directory case does. Returning here would have been worse than
            // the bug it fixed: `startWatching()` cancels the *directory* source too, and
            // cancelling a source before its own pending event has been delivered loses that
            // event -- so the one reload that used to happen would have stopped happening.
            if isFile {
                fileSource?.cancel()
                fileSource = watch(ConfigStore.path, isFile: true)
            } else {
                // The watched directory itself was removed or replaced (`rm -rf ~/.config/nyx`, an
                // editor that renames directories): every descriptor under it is stale. `~/.config`
                // itself still exists, so this recreates `nyx/` and picks up what appears next.
                startWatching()
                return
            }
        }
        // `.write`/`.extend` on a directory fires once per entry added, removed or renamed inside
        // it, and on the file once per write to it -- an editor's write-then-rename is two or three
        // such events for one save, coalesced here into one reload.
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}
