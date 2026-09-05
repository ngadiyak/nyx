import Foundation

/// Paths for the three files a device's remote-sessions state lives in. Kept beside the config
/// file rather than under Application Support so `NYX_CONFIG` -- already how a user or a test
/// points Nyx at a different config tree -- moves this state with it, instead of leaving a second,
/// config-blind location that could point at someone else's identity.
public enum RemoteFiles {
    /// `<dir of config>/remote` -- `config` is the config *file* URL (`ConfigPath.resolve()`'s
    /// result), so this is a sibling directory of `~/.config/nyx/config`, not a subdirectory of it.
    public static func directory(besideConfigAt config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent("remote", isDirectory: true)
    }

    public static func identity(in dir: URL) -> URL {
        dir.appendingPathComponent("identity")
    }

    public static func pairedDevices(in dir: URL) -> URL {
        dir.appendingPathComponent("paired.json")
    }

    public static func auditLog(in dir: URL) -> URL {
        dir.appendingPathComponent("audit.log")
    }
}
