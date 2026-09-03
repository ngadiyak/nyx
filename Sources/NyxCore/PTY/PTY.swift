import CNyxPTY
import Darwin
import Foundation

public struct PTYError: Error, CustomStringConvertible {
    public let code: Int32
    public var description: String { String(cString: strerror(code)) }
}

/// A pseudo-terminal with a spawned child process. `read` blocks; call it from a dedicated thread.
public final class PTY {
    public let fd: Int32
    public let pid: pid_t
    /// Guards `closed`. `write` and `close` can run on different threads (the write queue and
    /// `deinit`), so the flag must not be read torn: an unguarded check would let a write reach a
    /// descriptor that has already been closed and possibly reused by the kernel.
    private let stateLock = NSLock()
    private var closed = false

    public init(path: String, argv: [String], environment: [String: String], cwd: String?, cols: Int, rows: Int) throws {
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        let result = nyx_pty_spawn(path, cArgv, cEnv, cwd, UInt16(clamping: cols), UInt16(clamping: rows))
        if result.fd < 0 { throw PTYError(code: result.err) }
        fd = result.fd
        pid = result.pid
    }

    deinit { close() }

    /// Blocking read. Returns 0 on EOF, -1 on error (EIO once the child has exited).
    public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        Darwin.read(fd, buffer.baseAddress, buffer.count)
    }

    public var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    /// Writes every byte. Returns false on a hard error, or without writing anything once the
    /// descriptor has been closed.
    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            if isClosed { return false }
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { usleep(500); continue }
                return false
            }
            offset += n
        }
        return true
    }

    public func resize(cols: Int, rows: Int) {
        _ = nyx_pty_resize(fd, UInt16(clamping: cols), UInt16(clamping: rows))
    }

    public func close() {
        stateLock.lock()
        let wasClosed = closed
        closed = true
        stateLock.unlock()
        if !wasClosed { Darwin.close(fd) }
    }

    /// Asks the child to hang up (SIGHUP), like closing a real terminal.
    public func terminate() { Darwin.kill(pid, SIGHUP) }

    /// Waits for the child. Returns its exit code, or 128 + signal number.
    public func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }
}
