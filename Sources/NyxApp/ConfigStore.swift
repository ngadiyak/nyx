import Foundation
import NyxCore

/// Loads `~/.config/nyx/config` (or `$NYX_CONFIG`) and republishes it on change.
///
/// Watches the config *directory*, not the file: editors replace files by rename (write a temp
/// file, then rename it over the original), which invalidates a file-descriptor watch on the file
/// itself after the first save. A directory watch survives that. Multiple filesystem events from
/// one editor save (the write, then the rename) are coalesced with a short debounce so they produce
/// exactly one reload.
///
/// A parse error never loses the user's working configuration: `reload()` only replaces `config`
/// when nothing already in force would be discarded silently -- the previous good `Config` stays
/// current and `diagnostics` names the problem line, exactly as `ConfigParser` already guarantees
/// for a single parse.
final class ConfigStore {
    /// The current configuration. Replaced atomically on reload; read on the main thread only.
    private(set) var config: Config
    private(set) var diagnostics: [ConfigDiagnostic]
    /// Called on the main thread after every successful or failed reload.
    var onChange: ((Config, [ConfigDiagnostic]) -> Void)?

    /// `$NYX_CONFIG` if set, else `~/.config/nyx/config`.
    static var path: URL {
        ConfigPath.resolve(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
    }

    private var watchedDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.1

    init() {
        (config, diagnostics) = ConfigStore.load()
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

    func reload() {
        (config, diagnostics) = ConfigStore.load()
        onChange?(config, diagnostics)
    }

    /// Missing file means defaults, not an error: a fresh install with no config yet is not a typo.
    private static func load() -> (Config, [ConfigDiagnostic]) {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return (.defaults, [])
        }
        return ConfigParser.parse(text)
    }

    func startWatching() {
        stopWatching()
        let dir = ConfigStore.path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.handle(src.data) }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    func stopWatching() {
        debounceItem?.cancel()
        debounceItem = nil
        source?.cancel()
        source = nil
        watchedDescriptor = -1
    }

    private func handle(_ event: DispatchSource.FileSystemEvent) {
        // The watched directory itself was removed or replaced (e.g. `rm -rf ~/.config/nyx`, or an
        // editor that renames directories): the descriptor is now stale, so reopen it. `~/.config`
        // itself still exists, so this recreates `nyx/` and picks up whatever appears there next.
        if event.contains(.delete) || event.contains(.rename) {
            startWatching()
            return
        }
        // `.write`/`.extend` on a directory fires once per entry added, removed or renamed inside
        // it -- an editor's write-then-rename is two such events for one save, coalesced here.
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }
}
