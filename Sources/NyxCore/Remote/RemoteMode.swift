/// Whether this Mac publishes its sessions to the relay and accepts attaches at all. Off by
/// default: remote sessions read a device's whole scrollback and titles to another machine over the
/// network, which is not something a terminal should do until asked, however good the relay's own
/// security. Parsed the same way `shell-integration = auto|off` is -- a word, not a boolean -- so a
/// third state (e.g. a future `paused`) does not later require changing the config grammar.
public enum RemoteMode: String, Equatable {
    case off, on
}
