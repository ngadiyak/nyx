import Foundation

/// Which open tab, anywhere in the application, is already showing a given remote session.
///
/// Choosing the same palette row twice used to open a second tab on the same session, and the
/// second attach displaced the first -- so the tab the user had been working in said "Session
/// ended", which was a sentence about the host that was not true about anything. There is one
/// attachment per session id (a data frame carries nothing else to route on) and it has one owner,
/// so the honest answer to "open this session" when it is already open is to go to the tab it is
/// open in -- *including* when that tab is in another window, which is the case that froze a tab
/// instead of merely duplicating it.
///
/// It is here rather than in `TabController` because it is a decision -- which of these tabs is the
/// one -- and a decision written into a view controller is one nothing in this project can test.
public enum RemoteTabs {
    /// One open tab that carries a remote pane, as the application can describe it.
    public struct Open: Equatable {
        /// Which window, as the caller numbers them. A window index rather than a window: this type
        /// has to be comparable in a test, and the caller is the only thing that can turn the
        /// answer back into a window to raise.
        public let window: Int
        /// Index into that window's tab strip.
        public let index: Int
        /// The host's device id. Part of the identity because a session id is 16 random bytes made
        /// on the host: two hosts can produce the same one, and a tab on the wrong Mac is not the
        /// tab the user asked for.
        public let hostID: String
        /// base64url, as the palette row and the wire both carry it.
        public let sessionID: String
        /// Whether this tab still holds the attachment (`AttachState.isAttached`): everything but a
        /// session that ended and an attach that failed.
        public let isLive: Bool

        public init(window: Int, index: Int, hostID: String, sessionID: String, isLive: Bool) {
            self.window = window
            self.index = index
            self.hostID = hostID
            self.sessionID = sessionID
            self.isLive = isLive
        }
    }

    /// Where a session is already open.
    public struct Match: Equatable {
        public let window: Int
        public let tab: Int

        public init(window: Int, tab: Int) {
            self.window = window
            self.tab = tab
        }
    }

    /// The tab already showing this session, or nil.
    ///
    /// A tab whose session has ended or whose attach failed is *not* a hit. It keeps its transcript
    /// and stays on screen by design, but it holds no attachment any more, so treating it as the
    /// session's tab would answer "open this session" by selecting a dead one -- the row would go
    /// on doing nothing for as long as the corpse was left open.
    ///
    /// An empty `sessionID` never matches: that is what the palette's placeholder rows carry (an
    /// offline Mac, a Mac with nothing open, the relay's status line), and matching them to each
    /// other would select a tab for a row that stands for nothing.
    public static func existing(sessionID: String, hostID: String, among tabs: [Open]) -> Match? {
        guard !sessionID.isEmpty else { return nil }
        guard let hit = tabs.first(where: {
            $0.isLive && $0.sessionID == sessionID && $0.hostID == hostID
        }) else { return nil }
        return Match(window: hit.window, tab: hit.index)
    }
}
