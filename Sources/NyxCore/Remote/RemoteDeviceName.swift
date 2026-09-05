import Foundation

/// What this device calls itself to a paired Mac: the name in `remote-device-name` if the user set
/// one, else the machine's own name. The config field is stored empty by default rather than
/// pre-filled with the Mac's current name, so a renamed Mac (System Settings -> Sharing) picks up
/// the change automatically instead of showing whatever name it happened to have when Nyx first
/// wrote the config file. `hostName` is a parameter rather than read here because `Host.current()`
/// is Foundation-but-AppKit-adjacent housekeeping the caller (`NyxApp`) already has to do once for
/// the settings window; keeping it out of `NyxCore` keeps this a pure, table-driven function.
public enum RemoteDeviceName {
    public static func resolve(configured: String, hostName: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let host = hostName.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? "Mac" : host
    }
}
