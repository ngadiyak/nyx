import Foundation

/// Whether the frame the view just built may go on screen, given DECSET 2026 (synchronised output).
///
/// tmux, neovim and starship wrap a repaint in BSU/ESU exactly so that nobody sees half of it: a
/// status line redrawn before the pane below it, a prompt drawn before the text it replaces. The
/// mode was already parsed and answered over DECRQM; what was missing was the only part that
/// matters to a reader, which is that the picture stops changing while the update is in flight.
///
/// Holding is only half the contract. An application that is killed, stopped with SIGSTOP or simply
/// buggy leaves the mode set, and a terminal that trusts it freezes until the user notices and kills
/// it. So the hold expires on its own, and this type is where both halves live -- pure, with time
/// passed in, so both halves are testable without a clock.
public struct SyncOutputGate {
    /// How long one synchronised update may hold the screen.
    ///
    /// 150 ms, matching Alacritty (`SYNC_UPDATE_TIMEOUT` in its vte parser). kitty is far more
    /// patient at 2 s, and tmux buffers for 1 s on the application side. The mode's own
    /// specification says there is no consensus and adds the sentence that settles it: "a too short
    /// timeout ... won't be worse than having no synchronized output at all". Overshooting costs
    /// tearing -- which is precisely what this terminal did before this existed -- while
    /// undershooting freezes a live screen for two seconds because some program died mid-frame.
    /// Nine frames at 60 Hz is longer than any repaint a TUI emits and short enough that the
    /// pathological case reads as a hitch rather than as a hang.
    public var timeout: TimeInterval

    /// When the current hold began. nil when nothing is being held.
    private var holdStartedAt: TimeInterval?
    /// Set once a hold has outlived `timeout`: from then on frames go through until the application
    /// clears the mode. Without it a program that never sends ESU would be granted a fresh hold on
    /// every tick and stutter the display forever at one frame per timeout.
    private var expired = false

    public init(timeout: TimeInterval = 0.15) { self.timeout = timeout }

    /// True when a frame may be presented now. Asking does not consume anything: two calls in the
    /// same tick, with the same `now`, answer the same thing.
    public mutating func shouldPresent(syncOutput: Bool, now: TimeInterval) -> Bool {
        guard syncOutput else {
            holdStartedAt = nil
            expired = false
            return true
        }
        if expired { return true }
        guard let started = holdStartedAt else {
            holdStartedAt = now
            return false
        }
        if now - started >= timeout {
            expired = true
            return true
        }
        return false
    }

    /// Whether a frame is being withheld right now, for tests and diagnostics.
    public var isHolding: Bool { holdStartedAt != nil && !expired }
}
