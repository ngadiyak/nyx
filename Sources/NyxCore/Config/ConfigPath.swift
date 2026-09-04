import Foundation

/// Resolves the config file's location. Factored out of `ConfigStore` (which lives in `NyxApp` and
/// is otherwise untestable without AppKit) so the resolution rule itself -- `$NYX_CONFIG` if set,
/// else `~/.config/nyx/config` -- is a pure function `NyxCoreTests` can exercise directly.
public enum ConfigPath {
    public static let environmentVariable = "NYX_CONFIG"

    /// `environment[NYX_CONFIG]` if set and non-empty, else `<home>/.config/nyx/config`.
    public static func resolve(environment: [String: String], home: String) -> URL {
        if let override = environment[environmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".config/nyx/config")
    }
}
