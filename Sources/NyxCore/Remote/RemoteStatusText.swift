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
        /// The relay let go of this device for a reason retrying cannot fix and that is not the
        /// token: `bad_signature`, or `replaced` -- another connection presenting the same device
        /// id, which is what two Nyx instances sharing one identity file look like. Rare, and named
        /// rather than folded into "unreachable", because "the relay is down" would send the user
        /// looking in the wrong place entirely.
        case refused(String)
    }

    /// `failure` is something that went wrong before the relay was ever reached -- an identity file
    /// this Mac cannot read or write. It outranks the connection (there is no connection to report)
    /// but not `off`, because a feature that is switched off has nothing to fail at.
    public static func text(mode: RemoteMode, connection: Connection, deviceName: String,
                            failure: String? = nil) -> String {
        guard mode == .on else { return "Remote sessions are off" }
        if let failure { return failure }
        switch connection {
        case .connecting: return "Connecting\u{2026}"
        case .online: return "Online as \(deviceName)"
        case .unreachable(let host): return "Relay unreachable (\(host))"
        case .badToken: return "Relay rejected this device's token"
        case .refused(let reason): return "Relay refused this device (\(reason))"
        }
    }
}
