import Foundation

/// Reconnect delays after a dropped relay connection: doubling, capped, with no randomness. Jitter
/// belongs to the caller (many devices reconnecting at once is a relay-side concern, and a caller
/// that wants it can add `Double.random(in: 0...delay)` on top) -- keeping this deterministic is
/// what makes it possible to test the sequence at all.
public struct Backoff: Equatable {
    private let initial: Double
    private let maximum: Double
    private var current: Double

    public init(initial: Double = 1, maximum: Double = 60) {
        self.initial = initial
        self.maximum = maximum
        self.current = initial
    }

    /// The delay to wait *now*, then advances for next time: 1, 2, 4, … doubling until `maximum`.
    public mutating func next() -> Double {
        let value = current
        current = min(current * 2, maximum)
        return value
    }

    /// A successful reconnect calls this, so the *next* drop starts back at `initial` instead of
    /// picking up where a much earlier, unrelated outage left off.
    public mutating func reset() {
        current = initial
    }
}
