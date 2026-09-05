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
        }
    }
}
