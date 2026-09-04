// QA-TEMP: adversarial smoke harness. Drives real code paths in the built app and prints what
// happened. Remove this whole file and the `QASmoke.runIfRequested` call in AppDelegate before
// finishing.
import AppKit
import NyxCore

enum QASmoke {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["NYX_SMOKE_QA"] != nil }

    private static func say(_ s: String) {
        FileHandle.standardError.write(("QA| " + s + "\n").data(using: .utf8)!)
    }

    static func run(controllers: [TerminalWindowController], delegate: AppDelegate) {
        let which = ProcessInfo.processInfo.environment["NYX_SMOKE_QA"] ?? "all"
        guard let controller = controllers.first, let tabs = controller.qaTabController else {
            say("no window")
            NSApp.terminate(nil)
            return
        }
        var steps: [(String, (@escaping () -> Void) -> Void)] = []

        if which == "all" || which == "paste" {
            steps.append(("paste-empty-clipboard", { done in pasteWithEmptyClipboard(tabs); done() }))
            steps.append(("paste-image-only-clipboard", { done in pasteImageOnly(tabs); done() }))
        }
        if which == "all" || which == "toggle" {
            steps.append(("quick-action-missing-binary", { done in missingBinaryToggle(); done() }))
        }
        if which == "all" || which == "clear" {
            steps.append(("clear-screen-idle", { done in clearScreenIdle(tabs, done) }))
        }
        if which == "all" || which == "menu" {
            steps.append(("stale-tab-menu-index", { done in staleTabMenuIndex(tabs, done) }))
        }
        if which == "all" || which == "search" {
            steps.append(("global-search-race", { done in globalSearchRace(tabs, done) }))
        }

        func next(_ index: Int) {
            guard index < steps.count else {
                say("done")
                NSApp.terminate(nil)
                return
            }
            say("--- \(steps[index].0)")
            steps[index].1 { DispatchQueue.main.async { next(index + 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next(0) }
    }

    // MARK: - 1. Paste with nothing (or nothing textual) on the pasteboard

    private static func pasteWithEmptyClipboard(_ tabs: TabController) {
        NSPasteboard.general.clearContents()
        say("clipboard cleared")
        say("canPerform(.paste)          = \(tabs.canPerform(.paste))")
        say("canPerform(.pasteWithEditor)= \(tabs.canPerform(.pasteWithEditor))")
        guard let pane = tabs.focusedPane else { return }
        let before = pane.qaBytesSent
        tabs.perform(.paste)
        say("bytes written to the pty by Edit>Paste: \(pane.qaBytesSent - before)")
    }

    private static func pasteImageOnly(_ tabs: TabController) {
        NSPasteboard.general.clearContents()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        NSPasteboard.general.writeObjects([image])
        say("pasteboard now holds an image and no string")
        say("canPerform(.paste)          = \(tabs.canPerform(.paste))")
        say("canPerform(.pasteWithEditor)= \(tabs.canPerform(.pasteWithEditor))")
        guard let pane = tabs.focusedPane else { return }
        let before = pane.qaBytesSent
        tabs.perform(.paste)
        say("bytes written to the pty by Edit>Paste: \(pane.qaBytesSent - before)")
        NSPasteboard.general.clearContents()
    }

    // MARK: - 2. A toggle quick action whose executable does not exist

    private static func missingBinaryToggle() {
        let action = QuickAction(name: "QA Ghost", kind: .toggle,
                                 command: "definitely-not-a-real-binary-xyz --flag")
        say("isRunning before = \(QuickActionRunner.shared.isRunning(action))")
        QuickActionRunner.shared.perform(action, in: nil, pane: nil)
        say("isRunning right after press = \(QuickActionRunner.shared.isRunning(action))")
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        say("isRunning 1s later = \(QuickActionRunner.shared.isRunning(action))")
        say("(no alert, no beep path reached: /usr/bin/env always launches)")
    }

    // MARK: - 3. Clear Screen on a pane whose display link has gone to sleep

    private static func clearScreenIdle(_ tabs: TabController, _ done: @escaping () -> Void) {
        guard let pane = tabs.focusedPane else { done(); return }
        // Let the shell settle, then wait for the link to park itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            say("before clear: displayLinkPaused=\(pane.qaDisplayLinkPaused) dirty=\(pane.qaDirtyIsSet) frames=\(pane.qaFrameCount)")
            let framesBefore = pane.qaFrameCount
            pane.clearScreen()
            say("clearScreen() called")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                say("after clear:  displayLinkPaused=\(pane.qaDisplayLinkPaused) dirty=\(pane.qaDirtyIsSet) framesDrawn=\(pane.qaFrameCount - framesBefore)")
                say("=> a frame count of 0 means the wipe is in the buffer but not on screen")
                // Now the control: markDirty via a real key press path.
                let framesMid = pane.qaFrameCount
                pane.send([])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    say("control (send([]) -> markDirty): framesDrawn=\(pane.qaFrameCount - framesMid)")
                    done()
                }
            }
        }
    }

    // MARK: - 4. A tab context menu that outlives the tab it named

    private static func staleTabMenuIndex(_ tabs: TabController, _ done: @escaping () -> Void) {
        tabs.newTab(); tabs.newTab(); tabs.newTab(); tabs.newTab()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            tabs.qaSetTitles(["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO"])
            say("tabs: \(tabs.qaTabTitles)")
            // The user right-clicks BRAVO (index 1). The menu item carries index 1.
            let item = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "")
            item.representedObject = 1
            say("menu opened on index 1 = \(tabs.qaTabTitles[1])")
            // While the menu is up, ALPHA's shell exits and its tab goes.
            tabs.qaRemoveTab(at: 0)
            say("ALPHA closed while the menu was open; tabs now: \(tabs.qaTabTitles)")
            tabs.qaInvoke("menuCloseTab:", item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                say("after choosing Close Tab: \(tabs.qaTabTitles)")
                say("=> BRAVO was the tab pointed at; anything else means the wrong tab was closed")

                // And the same staleness on a destructive batch item.
                tabs.qaSetTitles(["P1", "P2", "P3", "P4"])
                let right = NSMenuItem(title: "Close Tabs to the Right", action: nil, keyEquivalent: "")
                right.representedObject = 2
                say("menu opened on index 2 = \(tabs.qaTabTitles[2]) (would close P4 only)")
                tabs.qaRemoveTab(at: 0)
                say("P1 closed while the menu was open; tabs now: \(tabs.qaTabTitles)")
                tabs.qaInvoke("menuCloseTabsToTheRight:", right)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    say("after choosing Close Tabs to the Right: \(tabs.qaTabTitles)")
                    done()
                }
            }
        }
    }

    // MARK: - 5. Search-all-tabs while output is flowing

    private static func globalSearchRace(_ tabs: TabController, _ done: @escaping () -> Void) {
        guard let pane = tabs.focusedPane else { done(); return }
        let terminal = pane.terminalForSearch
        let second = tabs.focusedPane.map { ObjectIdentifier($0.terminalForSearch) }
        say("terminalForSearch identity is stable across calls: \(second == ObjectIdentifier(terminal))")
        say("=> the Terminal object escapes withTerminal; GlobalSearch reads it with no lock held")
        pane.send(Array("while :; do echo connection refused aaaaaaaaaaaaaaaaaaaaaaaa; done\r".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            say("hammering runGlobalSearch while the pane floods...")
            for i in 0..<400 {
                let readout = tabs.runGlobalSearch(query: "refused")
                if i % 100 == 0 { say("  [\(i)] \(readout)") }
            }
            say("survived 400 global searches (a crash here would be the race biting)")
            pane.send([0x03])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
        }
    }
}
