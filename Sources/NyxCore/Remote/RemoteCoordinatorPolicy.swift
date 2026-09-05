import Foundation

/// Whether the application's remote-sessions object should be running at all, for the configuration
/// in force.
///
/// It is two conditions, and it is here rather than beside the object it governs because a rule
/// that lives in the app layer is a rule nothing in this project can test: there is no
/// `NyxAppTests` target, by design. The token half is the part worth pinning down -- it is not
/// obvious that the switch alone is not enough, and a build that connected without a token would
/// have the relay close the socket before the handshake and report it on the settings page as
/// "Relay unreachable", which sends the user to look at their network instead of at the one field
/// they left empty.
public enum RemoteCoordinatorPolicy {
    public static func shouldRun(config: Config) -> Bool {
        config.remote == .on && !needsToken(config: config)
    }

    /// The switch is on and the token field is empty. The one half of `shouldRun` that has a
    /// sentence of its own, because it is the half the user can fix in ten seconds.
    public static func needsToken(config: Config) -> Bool {
        config.remoteRelayToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What `remote_sessions` and `remote_pair` do for a given configuration.
    ///
    /// Both used to be greyed out unless the whole feature was runnable, which meant a user who had
    /// switched remote sessions on and not yet pasted a token found two dead menu items and nothing
    /// saying why. A menu item that opens the page where the missing thing is typed is the answer;
    /// a disabled one is only correct when the feature is genuinely off.
    public enum MenuOutcome: Equatable {
        case disabled
        /// Bring Settings → Remote forward, which is where the token field is.
        case openSettings
        case act
    }

    public static func menuOutcome(config: Config) -> MenuOutcome {
        guard config.remote == .on else { return .disabled }
        return needsToken(config: config) ? .openSettings : .act
    }
}
