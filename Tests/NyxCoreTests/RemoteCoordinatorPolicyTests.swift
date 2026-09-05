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
