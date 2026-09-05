/// What the settings page (and later the palette's Remote section) says about the relay connection
/// -- one line, always present, because a feature that talks to the network and says nothing about
/// whether it is working is a feature nobody can tell is broken. `Connection` is deliberately not
/// `RelayConnection.Status` from `NyxRemote`: that type needs CryptoKit to exist, and `NyxCore` may
/// not import it, so this is the small, Core-only subset of it that the wording actually depends on.
public enum RemoteStatusText {
    public enum Connection: Equatable {
        /// Socket open or being opened; the relay hasn't said `welcome` yet.
        case connecting
        case online
        /// The relay's host, for "Relay unreachable (nyx.agentforge.cc)".
        case unreachable(host: String)
        case badToken
    }

    public static func text(mode: RemoteMode, connection: Connection, deviceName: String) -> String {
        guard mode == .on else { return "Remote sessions are off" }
        switch connection {
        case .connecting: return "Connecting\u{2026}"
        case .online: return "Online as \(deviceName)"
        case .unreachable(let host): return "Relay unreachable (\(host))"
        case .badToken: return "Relay rejected this device's token"
        }
    }
}
