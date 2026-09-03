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
public final class TerminalSession {
    public var onUpdate: (() -> Void)?
    public var onEvent: ((TerminalEvent) -> Void)?
    public var onExit: ((Int32) -> Void)?
    public private(set) var exitCode: Int32?
    public var pid: pid_t { pty.pid }

    private let terminal: Terminal
    private let pty: PTY
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "nyx.pty.write")
    private var thread: Thread?

    public init(config: SessionConfig) throws {
        terminal = Terminal(cols: config.cols, rows: config.rows, scrollbackLimit: config.scrollbackLimit, palette: config.palette)
        pty = try PTY(path: config.shellPath, argv: config.argv, environment: config.environment,
                      cwd: config.cwd, cols: config.cols, rows: config.rows)
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "nyx.pty.read"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    deinit { pty.close() }

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
        exitCode = code
        onExit?(code)
    }
}
