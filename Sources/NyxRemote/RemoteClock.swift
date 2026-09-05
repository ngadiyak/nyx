import Foundation

/// Where `RemoteClient` gets "now" and "in n seconds" from.
///
/// `RemoteClient` deliberately has no queue of its own (see that type's note), so every delayed
/// check it makes -- the attach timeout, and the backoff between re-attach attempts -- runs on a
/// timer queue. Putting both behind one value is what makes them testable at all: a re-attach that
/// retries at 1, 2, 4, 8 and 15 seconds and gives up at sixty takes a minute of wall clock to watch
/// happen, and a test that waited that minute would be a test nobody runs.
///
/// A struct of two closures rather than a protocol because there is exactly one production
/// implementation and the test one is three lines; a protocol here would be a second name for the
/// same pair of functions.
public struct RemoteClock {
    public var now: () -> Date
    /// Runs `body` after `seconds`, on some queue that is not the caller's. Never synchronously:
    /// callers hold no lock across it, but they do call it from inside their own state machine, and
    /// a synchronous body would re-enter.
    public var after: (TimeInterval, @escaping () -> Void) -> Void

    public init(now: @escaping () -> Date, after: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.now = now
        self.after = after
    }

    private static let queue = DispatchQueue(label: "nyx.remote.client.timers")

    public static let system = RemoteClock(now: { Date() }, after: { seconds, body in
        queue.asyncAfter(deadline: .now() + seconds, execute: body)
    })
}
