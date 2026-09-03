import Foundation

public struct SessionConfig {
    public var shellPath: String
    public var argv: [String]
    public var environment: [String: String]
    public var cwd: String?
    public var cols: Int
    public var rows: Int
    public var scrollbackLimit: Int
    public var palette: Palette

    public init(shellPath: String, argv: [String], environment: [String: String], cwd: String?,
                cols: Int, rows: Int, scrollbackLimit: Int = 10_000, palette: Palette) {
        self.shellPath = shellPath; self.argv = argv; self.environment = environment; self.cwd = cwd
        self.cols = cols; self.rows = rows; self.scrollbackLimit = scrollbackLimit; self.palette = palette
    }

    /// The user's login shell with terminal environment variables set.
    public static func loginShell(cols: Int, rows: Int, palette: Palette, cwd: String? = nil) -> SessionConfig {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Nyx"
        env["TERM_PROGRAM_VERSION"] = Terminal.version
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let name = "-" + (shell as NSString).lastPathComponent
        return SessionConfig(shellPath: shell, argv: [name], environment: env, cwd: cwd ?? env["HOME"],
                             cols: cols, rows: rows, palette: palette)
    }
}

/// Owns a PTY, its child process and a `Terminal`. A reader thread parses output; all access to the terminal goes through `withTerminal`.
///
/// Construction is two-phase on purpose: `init` spawns the child but does **not** read from it, so
/// the caller can wire `onUpdate`/`onEvent`/`onExit` and only then call `start()`. Starting the
/// reader in `init` would both lose callbacks (a short-lived child can exit before the caller gets
/// to assign `onExit`) and race the assignments themselves, which are plain stored properties.
///
/// The session stays alive until its child exits; call `terminate()` to end it. Callbacks fire on the reader thread.
public final class TerminalSession {
    /// Assign before calling `start()`; these are read on the reader thread and are not synchronised.
    public var onUpdate: (() -> Void)?
    public var onEvent: ((TerminalEvent) -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return _exitCode }
    public var pid: pid_t { pty.pid }

    private let terminal: Terminal
    private let pty: PTY
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "nyx.pty.write")
    private var thread: Thread?
    private var started = false
    private var _exitCode: Int32?

    /// Spawns the child process. No output is read until `start()` is called.
    public init(config: SessionConfig) throws {
        terminal = Terminal(cols: config.cols, rows: config.rows, scrollbackLimit: config.scrollbackLimit, palette: config.palette)
        pty = try PTY(path: config.shellPath, argv: config.argv, environment: config.environment,
                      cwd: config.cwd, cols: config.cols, rows: config.rows)
    }

    /// Starts the reader thread. Call exactly once, after the callbacks are wired; calling it again
    /// is a no-op (and a debug-build assertion failure).
    ///
    /// The reader thread holds `self` strongly: a session lives exactly as long as its child
    /// process. `terminate()` is the documented way to end it early (SIGHUP); once the child
    /// exits, the read loop returns, `wait()` reaps it, `onExit` fires, and only then does the
    /// thread release its reference to `self`, allowing `deinit` to close the fd.
    public func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else {
            assertionFailure("TerminalSession.start() called more than once")
            return
        }
        let t = Thread { self.readLoop() }
        t.name = "nyx.pty.read"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    deinit {
        // `send` hands `pty` to the write queue, so an enqueued write can still be in flight.
        // Closing on that same serial queue orders the close after every write already queued;
        // `PTY.write` additionally refuses to write once the flag is set.
        lock.lock()
        let wasStarted = started
        lock.unlock()
        // A session that was never started owns a child nobody will reap: hang it up on the way out.
        if !wasStarted { pty.terminate() }
        writeQueue.async { [pty] in pty.close() }
    }

    public func withTerminal<T>(_ body: (Terminal) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(terminal)
    }

    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [pty] in pty.write(bytes) }
    }

    public func resize(cols: Int, rows: Int) {
        withTerminal { $0.resize(cols: cols, rows: rows) }
        pty.resize(cols: cols, rows: rows)
    }

    /// Sends SIGHUP to the child, like closing a real terminal. The session ends asynchronously:
    /// the read loop observes EOF, `wait()` reaps the child, and `onExit` fires on the reader thread.
    public func terminate() {
        pty.terminate()
    }

    private func readLoop() {
        let capacity = 65536
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = pty.read(into: buffer)
            if n <= 0 { break }
            let bytes = UnsafeBufferPointer(start: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n)
            var responses: [UInt8] = []
            var events: [TerminalEvent] = []
            lock.lock()
            terminal.feed(bytes)
            if !terminal.responses.isEmpty { responses = terminal.responses; terminal.responses.removeAll(keepingCapacity: true) }
            if !terminal.events.isEmpty { events = terminal.events; terminal.events.removeAll() }
            lock.unlock()
            if !responses.isEmpty { send(responses) }
            for e in events { onEvent?(e) }
            onUpdate?()
        }
        let code = pty.wait()
        lock.lock(); _exitCode = code; lock.unlock()
        onExit?(code)
    }
}
