import Testing
@testable import NyxCore

@Test func configuredNameWins() {
    #expect(RemoteDeviceName.resolve(configured: "Work Mac", hostName: "Niks-MacBook-Pro") == "Work Mac")
}

@Test func emptyConfiguredNameFallsBackToTheHost() {
    #expect(RemoteDeviceName.resolve(configured: "", hostName: "Niks-MacBook-Pro") == "Niks-MacBook-Pro")
}

@Test func whitespaceOnlyConfiguredNameCountsAsEmpty() {
    #expect(RemoteDeviceName.resolve(configured: "   ", hostName: "Niks-MacBook-Pro") == "Niks-MacBook-Pro")
}

/// `Host.current().localizedName` can itself come back empty in a sandboxed or misconfigured
/// environment; the resolution must still hand back something to show and to send, not "".
@Test func emptyHostNameFallsBackToMac() {
    #expect(RemoteDeviceName.resolve(configured: "", hostName: "") == "Mac")
    #expect(RemoteDeviceName.resolve(configured: "  ", hostName: "  ") == "Mac")
}

@Test func configuredNameIsTrimmed() {
    #expect(RemoteDeviceName.resolve(configured: "  Work Mac  ", hostName: "host") == "Work Mac")
}
