import os

/// A one-bit mailbox between the PTY reader thread and the main thread.
final class AtomicFlag {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value = false

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit { lock.deallocate() }

    func set() {
        os_unfair_lock_lock(lock)
        value = true
        os_unfair_lock_unlock(lock)
    }

    func takeAndClear() -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let v = value
        value = false
        return v
    }
}
