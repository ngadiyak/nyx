import AppKit
import NyxCore
import NyxRemote

/// A session running on another Mac, in the shape a `Pane` can draw.
///
/// It is the second conformer of `PaneSession`: a `Terminal` fed from an attachment's decrypted
/// byte stream instead of from a PTY, with no child process of its own. Everything the pane does
/// with a local session -- blocks, folds, search, selection, ⌘↑, the sticky prompt -- works here
/// unchanged, because the host's snapshot carries prompt marks and the live stream is the same
/// bytes the host's own terminal saw.
///
/// Three things are deliberately not what a local session does:
///
/// - `resize` is a no-op. The grid is the host pane's, and the person sitting in front of it owns
///   that window size (spec §5.4); a viewer on a bigger screen is letterboxed rather than resizing
///   somebody else's shell out from under them.
/// - `terminate` detaches. Closing the tab must never end the host's session.
/// - Terminal *responses* (DSR, DA, cursor-position reports) are dropped rather than sent back. The
///   host's own terminal already answered every query in the stream before it was ever forwarded;
///   answering again would type a second reply into the host's shell.
final class RemoteSession: PaneSession {
    /// Assigned by `Pane` before anything is fed, exactly as for a local session.
    var onUpdate: (() -> Void)?
    var onEvent: ((TerminalEvent) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// The attachment's phase, role and strip text changed, delivered on the main queue. The pane
    /// redraws its strip from it and the tab bar its badge.
    var onStateChange: ((AttachState) -> Void)?

    let attachment: RemoteClient.Attachment

    private let terminal: Terminal
    private let lock = NSLock()
    /// Feeding happens here, never on main: a 2,000-line snapshot is a parse of a few hundred
    /// kilobytes, and the thread that draws is the wrong one to do it on. Serial, so the bytes are
    /// fed in the order the relay delivered them.
    private let feedQueue = DispatchQueue(label: "nyx.remote.session.feed", qos: .userInitiated)
    private var started = false

    /// There is no local child, and `PaneSession` documents what a remote conformer answers: 0 is
    /// what the pane already treats as "no process to ask about".
    var pid: pid_t { 0 }
    var foregroundProcessGroup: pid_t? { nil }

    var state: AttachState { attachment.state }

    init(attachment: RemoteClient.Attachment, config: Config, palette: Palette) {
        self.attachment = attachment
        // 80×24 until `attached` says otherwise. The host's real size arrives with that message,
        // moments later, and `applyHostSize` resizes to it before the snapshot is drawn.
        terminal = Terminal(cols: 80, rows: 24, scrollbackLimit: config.scrollbackLines,
                            palette: palette)
        terminal.setDefaultCursorShape(config.cursorStyle)
        terminal.modes.cursorBlink = config.cursorBlink
    }

    // MARK: - PaneSession

    func withTerminal<T>(_ body: (Terminal) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(terminal)
    }

    /// Keystrokes and pastes. The attachment drops them unless this device is the writer and the
    /// snapshot is over, which is what makes the observer strip the truth rather than a label:
    /// there is no path from a key to the host's shell while it says "Observing".
    func send(_ bytes: [UInt8]) {
        attachment.send(bytes)
    }

    /// Wires the attachment's callbacks. The attach itself was already sent by `RemoteClient`, so
    /// unlike a local session this does not start anything -- it starts *listening*, and a
    /// snapshot that arrived in the meantime is delivered as soon as it does.
    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }
        attachment.onBytes = { [weak self] bytes in self?.feed(bytes) }
        attachment.onState = { [weak self] state in
            DispatchQueue.main.async { self?.stateChanged(state) }
        }
        // The state may already have moved between `attach` and here (the host is fast and the
        // relay is local); report what it is now rather than waiting for the next change.
        let state = attachment.state
        DispatchQueue.main.async { [weak self] in self?.stateChanged(state) }
    }

    /// The grid stays the host's. Kept as an explicit empty body rather than left unimplemented so
    /// the reason is next to the call the pane makes on every layout pass.
    func resize(cols: Int, rows: Int) {}

    func terminate() {
        attachment.onBytes = nil
        attachment.onState = nil
        attachment.detach()
    }

    // MARK: - The byte stream

    /// One chunk of decrypted output, from `RemoteCoordinator` on the main queue. Handed straight
    /// to the feed queue, which is the same shape a local session has: the thread that receives
    /// bytes is never the thread that parses them.
    private func feed(_ bytes: [UInt8]) {
        feedQueue.async { [weak self] in
            guard let self else { return }
            var events: [TerminalEvent] = []
            self.lock.lock()
            self.terminal.feed(bytes)
            // Dropped, not sent: see the type's note. The host's terminal answered these already.
            self.terminal.responses.removeAll(keepingCapacity: true)
            if !self.terminal.events.isEmpty {
                events = self.terminal.events
                self.terminal.events.removeAll()
            }
            self.lock.unlock()
            for event in events { self.onEvent?(event) }
            self.onUpdate?()
        }
    }

    /// A state change from the relay's thread, hopped to main.
    private func stateChanged(_ state: AttachState) {
        applyHostSize()
        onStateChange?(state)
    }

    /// Takes the host's terminal size, which arrives with `attached`. Resizing the *mirror* is not
    /// resizing the host: nothing is sent, the host's PTY is untouched, and all this does is give
    /// the grid the same shape the host's has so its rows land where they did there.
    private func applyHostSize() {
        let cols = attachment.cols, rows = attachment.rows
        guard cols > 0, rows > 0 else { return }
        let changed: Bool = withTerminal { terminal in
            guard terminal.cols != cols || terminal.rows != rows else { return false }
            terminal.resize(cols: cols, rows: rows)
            return true
        }
        if changed { onUpdate?() }
    }
}
