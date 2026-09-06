import Foundation

/// The pill Nyx floats at the end of a `curl` that has just been pasted: what it says, and whether
/// it belongs on screen at all.
///
/// The workbench is only worth having if somebody finds it. A pasted `curl` is the one moment when
/// saying "there is a form for this" is help rather than noise -- the user is looking at a wall of
/// quoted words they are about to have to edit by counting backslashes. Every other moment it would
/// be chrome nobody asked for, which is why this is three inputs and not a guess in a view handler:
/// the setting, the screen, and whether the line really is a request.
public enum WorkbenchHint {
    /// How long the pill stays up before it goes on its own.
    ///
    /// Long enough to be read after a paste and looked at again; short enough that a user who has
    /// carried on typing never has to dismiss it. A key press takes it away sooner -- the pane owns
    /// that half, because the pill is advice about a line nobody has started editing yet.
    public static let seconds: Double = 8

    /// `⌘E Workbench` -- the chord, then the word, in the order a Mac menu writes a shortcut and
    /// its item.
    ///
    /// The chord comes from the binding table rather than being written in here: `⌘E` is a default
    /// that a config file may well have moved, and a pill naming a chord that does nothing is worse
    /// than no pill. When the action is unbound entirely (`keybind = ⌘E: none`) there is no chord to
    /// name and the word stands alone -- the pill can still be clicked, and " Workbench" with a
    /// hole in front of it would look like a truncation.
    public static func text(chord: String) -> String {
        chord.isEmpty ? "Workbench" : "\(chord) Workbench"
    }

    /// Whether the pill may be shown over this command line.
    ///
    /// `commandLine` is what is on the shell's line editor right now, not what was pasted a moment
    /// ago: the pill has to go the instant the line stops being a request, because a user who has
    /// backspaced the `curl` away is looking at something else entirely. `altScreen` keeps it off
    /// a full-screen program for the same reason `CommandBlockChrome.isAllowed` keeps the spine
    /// off one -- vim owns every cell, and chrome floated over it is a bug that also eats a click.
    public static func shouldShow(commandLine: String, hintEnabled: Bool, altScreen: Bool) -> Bool {
        guard hintEnabled, !altScreen else { return false }
        return CurlDetection.isCurl(commandLine)
    }
}
