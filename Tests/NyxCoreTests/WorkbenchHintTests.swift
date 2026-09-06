import Testing
@testable import NyxCore

@Test func theHintNamesTheChordThatOpensTheWorkbench() {
    #expect(WorkbenchHint.text(chord: "\u{2318}E") == "\u{2318}E Workbench")
}

/// An unbound `edit_and_run_command` is a real configuration -- `keybind = ⌘E: none` -- and the
/// pill is still worth showing, because it can be clicked. What it must not say is " Workbench"
/// with a space where the chord would have been.
@Test func anUnboundActionLeavesNoGapInFrontOfTheWord() {
    #expect(WorkbenchHint.text(chord: "") == "Workbench")
}

@Test func aPastedCurlIsWorthAHint() {
    #expect(WorkbenchHint.shouldShow(commandLine: "curl -sS https://api.example.com/users",
                                     hintEnabled: true, altScreen: false))
}

@Test func anythingThatIsNotACurlIsNot() {
    #expect(!WorkbenchHint.shouldShow(commandLine: "git status --short",
                                      hintEnabled: true, altScreen: false))
    #expect(!WorkbenchHint.shouldShow(commandLine: "", hintEnabled: true, altScreen: false))
    // Somebody else's output being posted, not a request this terminal is making -- the same
    // distinction `CurlDetection` draws for the workbench itself.
    #expect(!WorkbenchHint.shouldShow(commandLine: "cat body.json | curl -d @- https://x.test/",
                                      hintEnabled: true, altScreen: false))
}

@Test func theHintIsOffWhenTheSettingIsOff() {
    #expect(!WorkbenchHint.shouldShow(commandLine: "curl https://api.example.com/",
                                      hintEnabled: false, altScreen: false))
}

/// vim, htop and anything else drawing its own interface owns every cell; a pill floated over one
/// of them is the bug block chrome already has a rule about (`CommandBlockChrome.isAllowed`).
@Test func theHintStaysOffTheAlternateScreen() {
    #expect(!WorkbenchHint.shouldShow(commandLine: "curl https://api.example.com/",
                                      hintEnabled: true, altScreen: true))
}

@Test func theHintIsShownForEightSeconds() {
    #expect(WorkbenchHint.seconds == 8)
}
