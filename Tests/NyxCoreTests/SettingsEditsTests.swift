import Testing
@testable import NyxCore

/// C1. The rule that hid in a view handler: a refresh must not overwrite a field the user is in.
/// Assigning `stringValue` to an `NSTextField` with a live field editor replaces what the user can
/// see *and* what the editor holds, so a reload landing on a pasted relay token wiped the paste and
/// the commit that followed wrote the empty string into the config file.
@Test func aFieldNobodyIsInTakesTheRefreshedValue() {
    var edits = SettingsEdits()
    let refresh = edits.refreshing("font-size", to: "13", beingEdited: false)
    #expect(refresh == .write("13"))
    let released = edits.released("font-size")
    #expect(released == nil, "nothing was held, so there is nothing to release")
}

@Test func aFieldWithTheCaretInItHoldsTheRefreshedValue() {
    var edits = SettingsEdits()
    let refresh = edits.refreshing("remote-relay-token", to: "from-the-file", beingEdited: true)
    #expect(refresh == .hold)
}

/// `beingEdited` is not enough on its own: clicking a terminal window does not end a text field's
/// editing in AppKit's sense, and a palette action that writes the config file reloads while that
/// field still holds an uncommitted paste. The edited set outlives the caret, right up to the
/// commit.
@Test func anEditedFieldHoldsTheRefreshedValueEvenWithoutTheCaret() {
    var edits = SettingsEdits()
    edits.record("remote-relay-token")
    let refresh = edits.refreshing("remote-relay-token", to: "from-the-file", beingEdited: false)
    #expect(refresh == .hold)
}

/// The other half of holding it: the held value has to land eventually. A field that was only
/// *focused* while a reload arrived has nothing to commit, so no write happens, so no further
/// refresh is coming -- and the window would sit there showing a value the file no longer holds.
@Test func endingAnEditThatChangedNothingHandsOverTheHeldValue() {
    var edits = SettingsEdits()
    let refresh = edits.refreshing("remote-relay", to: "wss://new/v1/ws", beingEdited: true)
    #expect(refresh == .hold)
    let wrote = edits.committing("remote-relay")
    #expect(!wrote, "the user never typed in it, so there is nothing to write")
    let released = edits.released("remote-relay")
    #expect(released == "wss://new/v1/ws")
    let again = edits.released("remote-relay")
    #expect(again == nil, "released once, not once per end-editing path")
}

/// The window ends one edit through two paths -- the cell's action and `controlTextDidEndEditing` --
/// and the second must write nothing.
@Test func aCommitConsumesTheEditSoTheSecondPathWritesNothing() {
    var edits = SettingsEdits()
    edits.record("padding")
    let first = edits.committing("padding")
    #expect(first)
    let second = edits.committing("padding")
    #expect(!second)
}

/// A commit drops what was held for that key. The write causes a reload, and that reload's refresh
/// carries the value the file actually ended up with -- which is never older than the held one, so
/// letting the held one land on top of it would show the user the value they just replaced.
@Test func aCommitDropsTheHeldValueBecauseItsOwnReloadIsNewer() {
    var edits = SettingsEdits()
    edits.record("remote-relay-token")
    let refresh = edits.refreshing("remote-relay-token", to: "older", beingEdited: true)
    #expect(refresh == .hold)
    let wrote = edits.committing("remote-relay-token")
    #expect(wrote)
    let released = edits.released("remote-relay-token")
    #expect(released == nil)
}

/// A refresh that was allowed through clears anything stale that was held for the same key, so a
/// value held during one edit cannot reappear after a later, unrelated one.
@Test func aRefreshThatLandsClearsWhatWasHeldBefore() {
    var edits = SettingsEdits()
    let held = edits.refreshing("padding", to: "20", beingEdited: true)
    #expect(held == .hold)
    let landed = edits.refreshing("padding", to: "24", beingEdited: false)
    #expect(landed == .write("24"))
    let released = edits.released("padding")
    #expect(released == nil)
}

/// Keys do not interfere: the token being edited must not stop the padding field being refreshed,
/// which is the whole reason this is per key rather than one "somebody is editing" flag.
@Test func holdingOneFieldDoesNotHoldTheOthers() {
    var edits = SettingsEdits()
    edits.record("remote-relay-token")
    let token = edits.refreshing("remote-relay-token", to: "from-the-file", beingEdited: false)
    #expect(token == .hold)
    let padding = edits.refreshing("padding", to: "20", beingEdited: false)
    #expect(padding == .write("20"))
}
