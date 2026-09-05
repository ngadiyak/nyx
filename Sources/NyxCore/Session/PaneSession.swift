import Foundation

/// Everything a pane needs from the thing it is a view of.
///
/// It exists so a pane showing a session on another Mac is a second conformer rather than a second
/// copy of the pane: without it, every one of the ~60 `session.` calls in `Pane` would need an `if
/// remote` beside it, and each of those is a branch no test in this project can reach.
///
/// The surface is deliberately exactly what `Pane` uses and nothing more. Two of the members are
/// meaningless for a remote attachment and are documented here as what a remote conformer answers,
/// so the pane never has to ask which kind it holds:
///
/// - `pid` is the local child's process id; a remote conformer has no local child and answers 0,
///   which the pane already treats as "no process to inspect" (`proc_pidinfo` on 0 fails).
/// - `foregroundProcessGroup` is nil for a remote attachment, so the pane falls back to the cwd the
///   host reported through OSC 7 rather than asking this machine's kernel about another machine's
///   process.
///
/// The output tap (`TerminalSession.onOutput`/`tapOutput`) is deliberately not part of this: it is
/// a single slot with one consumer -- the remote host that publishes a session -- and a pane draws
/// from the terminal, not from the byte stream. A conformer that is itself a remote attachment has
/// no PTY to tap.
///
/// `resize` on a remote attachment does not resize the host's PTY (the host's own user owns that
/// window size); it is the pane's request, and a remote conformer may ignore it.
public protocol PaneSession: AnyObject {
    /// The reference must not escape the closure: everything else here is safe to call from any
    /// thread, but the terminal itself is only consistent while the lock is held.
    func withTerminal<T>(_ body: (Terminal) throws -> T) rethrows -> T
    func send(_ bytes: [UInt8])
    /// Call once, after the callbacks are wired.
    func start()
    func resize(cols: Int, rows: Int)
    /// Ends the session: a local one hangs up its child, a remote one detaches.
    func terminate()
    var onUpdate: (() -> Void)? { get set }
    var onEvent: ((TerminalEvent) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var pid: pid_t { get }
    var foregroundProcessGroup: pid_t? { get }
}

extension TerminalSession: PaneSession {}
