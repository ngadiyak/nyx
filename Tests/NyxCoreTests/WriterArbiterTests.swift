import Testing
@testable import NyxCore

/// `[(deviceID: String, role: AttachState.Role)]` has no `==` -- plain tuples never conform to
/// `Equatable`, only the standalone `==` operator exists for comparing two of them directly. This
/// wraps each element so the array as a whole can be compared in one `#expect`.
private struct Change: Equatable {
    let deviceID: String
    let role: AttachState.Role
}

private func changes(_ raw: [(deviceID: String, role: AttachState.Role)]) -> [Change] {
    raw.map { Change(deviceID: $0.deviceID, role: $0.role) }
}

@Test func firstAttacherBecomesWriter() {
    var a = WriterArbiter()
    #expect(a.attached("d1") == .writer)
    #expect(a.writer == "d1")
}

@Test func secondAttacherIsAnObserver() {
    var a = WriterArbiter()
    _ = a.attached("d1")
    #expect(a.attached("d2") == .observer)
    #expect(a.role(of: "d2") == .observer)
}

@Test func writerLeavingPromotesTheLongestAttachedObserver() {
    var a = WriterArbiter()
    _ = a.attached("d1")
    _ = a.attached("d2")
    _ = a.attached("d3")
    let result = a.detached("d1")
    #expect(changes(result) == [Change(deviceID: "d2", role: .writer)])
    #expect(a.writer == "d2")
    #expect(a.role(of: "d3") == .observer)
}

@Test func theSoleAttacherLeavingPromotesNobody() {
    var a = WriterArbiter()
    _ = a.attached("d1")
    let result = a.detached("d1")
    #expect(changes(result) == [])
    #expect(a.writer == nil)
}

@Test func anObserverLeavingChangesNoRoles() {
    var a = WriterArbiter()
    _ = a.attached("d1")
    _ = a.attached("d2")
    let result = a.detached("d2")
    #expect(changes(result) == [])
    #expect(a.writer == "d1")
}

@Test func takeControlSwapsWriterAndDemotesThePrevious() {
    var a = WriterArbiter()
    _ = a.attached("d1")
    _ = a.attached("d2")
    let result = a.takeControl("d2")
    #expect(changes(result) == [Change(deviceID: "d1", role: .observer), Change(deviceID: "d2", role: .writer)])
    #expect(a.writer == "d2")
    #expect(a.role(of: "d1") == .observer)
}

@Test func takeControlByTheCurrentWriterIsANoOp() {
    var a = WriterArbiter()
    _ = a.attached("d1")
    let result = a.takeControl("d1")
    #expect(changes(result) == [])
}

@Test func roleOfAnUnknownDeviceIsNil() {
    let a = WriterArbiter()
    #expect(a.role(of: "ghost") == nil)
}
