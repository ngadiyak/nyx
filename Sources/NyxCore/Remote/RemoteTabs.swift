import Foundation

/// Which open tab, if any, is already showing a given remote session.
///
/// Choosing the same palette row twice used to open a second tab on the same session, and the
/// second attach displaced the first -- so the tab the user had been working in said "Session
/// ended", which was a sentence about the host that was not true about anything. There is one
/// attachment per session id (a data frame carries nothing else to route on), so the honest answer
/// to "open this session" when it is already open is to go to the tab it is open in.
///
/// It is here rather than in `TabController` because it is a decision -- which of these tabs is the
/// one -- and a decision written into a view controller is one nothing in this project can test.
public enum RemoteTabs {
    /// One open tab that carries a remote pane, as the window can describe it.
    public struct Open: Equatable {
        /// Index into the window's tab strip.
        public let index: Int
        /// The host's device id. Part of the identity because a session id is 16 random bytes made
        /// on the host: two hosts can produce the same one, and a tab on the wrong Mac is not the
        /// tab the user asked for.
        public let hostID: String
        /// base64url, as the palette row and the wire both carry it.
        public let sessionID: String

        public init(index: Int, hostID: String, sessionID: String) {
            self.index = index
            self.hostID = hostID
            self.sessionID = sessionID
        }
    }

    /// The index of the tab already showing this session, or nil.
    ///
    /// An empty `sessionID` never matches: that is what the palette's placeholder rows carry (an
    /// offline Mac, a Mac with nothing open, the relay's status line), and matching them to each
    /// other would select a tab for a row that stands for nothing.
    public static func existing(sessionID: String, hostID: String, among tabs: [Open]) -> Int? {
        guard !sessionID.isEmpty else { return nil }
        return tabs.first { $0.sessionID == sessionID && $0.hostID == hostID }?.index
    }
}
