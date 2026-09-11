import Foundation

/// Which settings-window text fields the user is in the middle of, and what that means for the three
/// things the window does to a field: commit it to the config file, refresh it from the file, or
/// hand it a value a refresh was holding.
///
/// A value type in Core because the window came to keep three rules about text fields at once and
/// all three were invisible to every test. The one that hid was "a refresh must not overwrite a
/// field the user is in": assigning `stringValue` to an `NSTextField` with a live field editor
/// replaces what the user can see *and* what the editor holds, so a reload landing on a pasted relay
/// token wiped the paste, and the commit that followed wrote the empty string into the config file.
/// That reload became easy to hit the moment the config *file* was watched as well as its directory
/// -- `cat ~/projects/nyx-server/token >> ~/.config/nyx/config` with the settings window open is the
/// documented way to set the very field it destroyed.
public struct SettingsEdits: Equatable, Sendable {
    /// Keys whose field the user has typed or pasted into and which have not been committed yet.
    private var edited: Set<String> = []
    /// The text a refresh was not allowed to write, per key, until that field's edit ends.
    private var held: [String: String] = [:]

    public init() {}

    /// What a refresh should do with the text it wants to put in a field.
    public enum Refresh: Equatable, Sendable {
        /// Safe to assign: nobody is in that field.
        case write(String)
        /// Kept until the edit ends; `released(_:)` hands it over then.
        case hold
    }

    /// The user typed or pasted in `key`'s field.
    ///
    /// Driven by `controlTextDidChange`, which a programmatic `stringValue` never fires, so this is
    /// the user's own edits and nothing else -- which is what tells a field that was *edited* from
    /// one that was only focused.
    public mutating func record(_ key: String) { edited.insert(key) }

    /// What to do with `text` for `key`, given whether that field currently holds the caret.
    ///
    /// Both `beingEdited` and the recorded edits are asked, because they are different windows of
    /// time: the caret is in a field from the moment it is focused, while an edit outlives a focus
    /// lost to another *window* -- clicking a terminal does not end a field's editing in AppKit's
    /// sense -- right up to the commit.
    public mutating func refreshing(_ key: String, to text: String, beingEdited: Bool) -> Refresh {
        guard beingEdited || edited.contains(key) else {
            held[key] = nil
            return .write(text)
        }
        held[key] = text
        return .hold
    }

    /// Whether ending the edit of `key` has something to write to the file.
    ///
    /// Consumes the edit, because the window ends one edit through two paths -- the cell's action
    /// and `controlTextDidEndEditing` -- and the second must not write again. Anything held for the
    /// key goes with it: the write causes a reload, and that reload's refresh carries the value the
    /// file actually ended up with, which is never older than the held one.
    public mutating func committing(_ key: String) -> Bool {
        guard edited.remove(key) != nil else { return false }
        held[key] = nil
        return true
    }

    /// The text a refresh held for `key`, now that its edit has ended with nothing to commit.
    ///
    /// Nothing else can deliver it: no write means no reload, so no further refresh is coming, and
    /// the field would sit there showing a value the file no longer holds -- the window lying about
    /// the file, which is the one thing this window exists not to do.
    public mutating func released(_ key: String) -> String? {
        held.removeValue(forKey: key)
    }
}
