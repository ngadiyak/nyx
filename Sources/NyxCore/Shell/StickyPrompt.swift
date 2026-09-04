import Foundation

/// The command line to pin above the viewport while its output is being read.
public struct StickyPrompt: Equatable {
    /// The absolute row holding the command line -- what to draw in the pinned strip.
    public let row: Int
    /// Whether the command failed, so the strip can say so without the user scrolling back.
    public let failed: Bool
    /// nil while the command is still running.
    public let exitStatus: Int32?

    public init(row: Int, failed: Bool, exitStatus: Int32?) {
        self.row = row
        self.failed = failed
        self.exitStatus = exitStatus
    }
}

public extension Terminal {
    /// The command whose output fills the top of the viewport, or nil when there is nothing worth
    /// pinning.
    ///
    /// Scrolling through a long build leaves the command that produced it far above, and what is on
    /// screen becomes a wall of text with no attribution. Pinning its command line answers "what am
    /// I even looking at" without scrolling back to find out and losing your place.
    ///
    /// Returns nil when the prompt is already on screen -- pinning a copy of a line the user can
    /// already see wastes a row and reads as a rendering bug -- and nil when the shell emits no
    /// marks, since then there is no command line to name.
    func stickyPrompt(viewportTop: Int? = nil) -> StickyPrompt? {
        let top = viewportTop ?? viewportTopRow
        guard let region = command(containingAbsoluteRow: top) else { return nil }

        // The prompt is on screen already, so there is nothing to remind anyone of.
        guard region.promptRow < top else { return nil }

        // A command with no output has nothing to read, so nothing to lose track of. This also
        // keeps the strip from appearing over the prompt the user is typing at.
        guard let outputStart = region.outputStart, outputStart <= top else { return nil }

        return StickyPrompt(row: region.promptRow, failed: region.failed,
                            exitStatus: region.exitStatus)
    }
}
