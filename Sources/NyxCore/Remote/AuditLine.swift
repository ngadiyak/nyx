import Foundation

/// One line of `~/.config/nyx/remote/audit.log` -- what happened, to which session, when. A host's
/// user never sees remote activity on screen (5.5 of the design spec), so this file is the only
/// record; the format is plain text on purpose, so `tail -f` is a complete tool for reading it.
public enum AuditLine {
    public enum Event: Equatable {
        case paired(String)
        case removed(String)
        case attached(device: String, session: String)
        case tookControl(device: String, session: String)
        case detached(device: String, session: String)
        /// The host ended the session itself -- the tab was closed, the shell exited. Distinct from
        /// `detached`, which is a client leaving a session that carries on: the log has to say which
        /// end walked away, because "detached" against every attached device is what a host looks
        /// like when it is the one that stopped, and that reads as the clients' doing.
        case sessionEnded(session: String)
    }

    public static func text(_ event: Event, at date: Date) -> String {
        let iso = ISO8601DateFormatter().string(from: date)
        switch event {
        case .paired(let device):
            return "\(iso)  paired  \(device)"
        case .removed(let device):
            return "\(iso)  removed  \(device)"
        case .attached(let device, let session):
            return "\(iso)  attached  \(device) → \(session)"
        case .tookControl(let device, let session):
            return "\(iso)  took control  \(device) → \(session)"
        case .detached(let device, let session):
            return "\(iso)  detached  \(device) → \(session)"
        case .sessionEnded(let session):
            return "\(iso)  session ended  \(session)"
        }
    }
}
