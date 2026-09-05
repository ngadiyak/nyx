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

/// Turns the ids an `AuditLine.Event` arrives with into the names §5.5 promises the file holds.
///
/// Everything on the wire is a base64url id -- that is what a device and a session *are* to the
/// relay and to `RemoteHost`, which has no business knowing what the user calls them. The host's
/// own user, reading `audit.log`, has the opposite problem: `attached  8hgFMxB9cg29wj9TIaSGnKA2…
/// → GntMPWQxgr1R_3FcRQke0g` is a true statement about nothing they can recognise. The mapping is
/// the app's -- it is the app that holds the paired list and the open panes -- but the *rule*, and
/// in particular what to say when there is no name, is here where it can be tested.
public enum AuditNames {
    /// How much of an id is shown when nothing names it. Enough to tell two ids apart and to grep
    /// `paired.json` with; short enough that the line still reads as a sentence.
    private static let idPrefixLength = 8

    /// `names` is `PairedDevices.namesByID`; `titles` maps a base64url session id to the title of
    /// the pane publishing it. Either may be missing an entry -- a device unpaired a moment ago, a
    /// pane already closed -- which is exactly when the id prefix is the honest answer.
    public static func resolve(deviceID: String, sessionID: String,
                               names: [String: String],
                               titles: [String: String]) -> (device: String, session: String) {
        (name(of: deviceID, in: names), name(of: sessionID, in: titles))
    }

    /// The same event with its ids replaced by names, so the caller has no `switch` of its own to
    /// get wrong: an app-layer switch over six cases is six branches no test in this project could
    /// reach. `paired` and `removed` already carry the peer's announced name and pass through.
    public static func naming(_ event: AuditLine.Event, names: [String: String],
                              titles: [String: String]) -> AuditLine.Event {
        switch event {
        case .paired, .removed:
            return event
        case .attached(let device, let session):
            let n = resolve(deviceID: device, sessionID: session, names: names, titles: titles)
            return .attached(device: n.device, session: n.session)
        case .tookControl(let device, let session):
            let n = resolve(deviceID: device, sessionID: session, names: names, titles: titles)
            return .tookControl(device: n.device, session: n.session)
        case .detached(let device, let session):
            let n = resolve(deviceID: device, sessionID: session, names: names, titles: titles)
            return .detached(device: n.device, session: n.session)
        case .sessionEnded(let session):
            return .sessionEnded(session: name(of: session, in: titles))
        }
    }

    private static func name(of id: String, in map: [String: String]) -> String {
        guard let found = map[id], !found.isEmpty else { return String(id.prefix(idPrefixLength)) }
        return found
    }
}
