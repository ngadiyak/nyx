import Testing
@testable import NyxCore

@Test func remoteRunsWhenItIsOnAndHasAToken() {
    var c = Config.defaults
    c.remote = .on
    c.remoteRelayToken = "t0ken"
    #expect(RemoteCoordinatorPolicy.shouldRun(config: c))
}

@Test func remoteDoesNotRunWhenItIsOff() {
    var c = Config.defaults
    c.remote = .off
    c.remoteRelayToken = "t0ken"
    #expect(!RemoteCoordinatorPolicy.shouldRun(config: c))
}

/// The half that is not obvious. The relay closes a socket that presents no token before the
/// handshake finishes, so connecting without one is a guaranteed failure -- reported on the
/// settings page as "Relay unreachable", which sends the user looking at their network.
@Test func remoteDoesNotRunWithoutAToken() {
    var c = Config.defaults
    c.remote = .on
    #expect(!RemoteCoordinatorPolicy.shouldRun(config: c))
}

@Test func aTokenOfNothingButSpacesIsNoToken() {
    var c = Config.defaults
    c.remote = .on
    c.remoteRelayToken = "   "
    #expect(!RemoteCoordinatorPolicy.shouldRun(config: c))
}

// MARK: - What the two remote menu items do

/// Both items used to be greyed out unless the whole feature was runnable, so a user who had
/// switched remote sessions on and not yet pasted a token met two dead menu items and no
/// explanation. The item that opens the page holding the missing field is the answer.
@Test func theRemoteMenuItemsOpenSettingsWhenTheTokenIsMissing() {
    var c = Config.defaults
    c.remote = .on
    #expect(RemoteCoordinatorPolicy.menuOutcome(config: c) == .openSettings)
    c.remoteRelayToken = "  "
    #expect(RemoteCoordinatorPolicy.menuOutcome(config: c) == .openSettings)
}

@Test func theRemoteMenuItemsActOnceThereIsAToken() {
    var c = Config.defaults
    c.remote = .on
    c.remoteRelayToken = "t0ken"
    #expect(RemoteCoordinatorPolicy.menuOutcome(config: c) == .act)
}

/// Off is the one state where greying them out is the truth: there is no page to send anybody to
/// that the switch on it does not already say.
@Test func theRemoteMenuItemsAreDisabledOnlyWhenTheFeatureIsOff() {
    var c = Config.defaults
    c.remote = .off
    c.remoteRelayToken = "t0ken"
    #expect(RemoteCoordinatorPolicy.menuOutcome(config: c) == .disabled)
}
