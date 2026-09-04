import AppKit
import NyxCore

/// Runs the user's quick actions and remembers which background ones are on.
///
/// `toggle` is the interesting kind. Something like `caffeinate -d` has to stay alive while you
/// work but is never worth looking at, and today it costs a whole tab spent babysitting it. Here it
/// is a button: press to start, press again to stop, and the button says which it is.
///
/// One runner for the application, not one per window: a background process belongs to the session
/// you are having, not to whichever window happened to start it, and a second window must not offer
/// to start a second `caffeinate`.
final class QuickActionRunner {
    static let shared = QuickActionRunner()

    /// Posted when a toggle starts or stops, so buttons can redraw. The object is the action's name.
    static let stateChanged = Notification.Name("NyxQuickActionStateChanged")

    private var running: [String: Process] = [:]

    private init() {
        // A background process is scoped to the time Nyx is open: `caffeinate` outliving the
        // terminal that started it is exactly the kind of thing that keeps a laptop awake in a bag.
        NotificationCenter.default.addObserver(self, selector: #selector(stopEverything),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    func isRunning(_ action: QuickAction) -> Bool {
        guard let process = running[action.name] else { return false }
        return process.isRunning
    }

    /// Carries out an action. `send` and `run` need a pane to act on; `toggle` does not.
    func perform(_ action: QuickAction, in target: (any ActionTarget)?, pane: Pane?) {
        switch action.kind {
        case .send:
            pane?.send(action.bytesToSend)
        case .run:
            // A new tab, then the command typed into it -- so it appears in history and can be
            // edited or re-run, rather than being a process nobody can see the command line of.
            target?.perform(.newTab)
            let bytes = action.bytesToSend
            // The pane is captured NOW, not looked up when the timer fires. Asking for "the focused
            // pane" a quarter of a second later types the command into whatever the user switched
            // to in the meantime -- press the button, hit ⌘⇧] , and the command lands in someone
            // else's shell.
            guard let pane = (target as? TabController)?.focusedPane else { return }
            // The shell still has to finish starting before it can be typed at.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak pane] in
                pane?.send(bytes)
            }
        case .toggle:
            toggle(action)
        }
    }

    // MARK: - Background processes

    private func toggle(_ action: QuickAction) {
        if let process = running[action.name], process.isRunning {
            process.terminate()
            running[action.name] = nil
            announce(action)
            return
        }
        start(action)
    }

    private func start(_ action: QuickAction) {
        let argv = action.argv
        guard let executable = argv.first else { return }

        let process = Process()
        // Resolved through the login shell's PATH rather than assumed: `caffeinate` is in
        // /usr/bin, but a user's toggle is as likely to be something they installed themselves.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + argv.dropFirst()
        // A background command's output has nowhere to go; discarding it beats filling a pipe
        // nobody reads until the process blocks on a full buffer.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            // It may have failed to start, or exited on its own; either way the button must stop
            // claiming it is on.
            DispatchQueue.main.async {
                guard let self, self.running[action.name] != nil else { return }
                self.running[action.name] = nil
                self.announce(action)
            }
        }

        do {
            try process.run()
            running[action.name] = process
        } catch {
            NSSound.beep()
        }
        announce(action)
    }

    @objc private func stopEverything() {
        for process in running.values where process.isRunning { process.terminate() }
        running.removeAll()
    }

    private func announce(_ action: QuickAction) {
        NotificationCenter.default.post(name: QuickActionRunner.stateChanged, object: action.name)
    }
}
