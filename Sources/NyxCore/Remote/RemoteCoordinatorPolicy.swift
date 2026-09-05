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
        config.remote == .on && !config.remoteRelayToken.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
