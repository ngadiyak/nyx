import Testing
@testable import NyxCore

@Test func validatesInterval() {
    var m = WatchPlanEditorModel(interval: 5)
    #expect(m.intervalProblem == nil)
    #expect(m.plan == WatchPlan(interval: 5, stop: .never))

    // Half a second is the floor the Run menu already clamps to, so the popover cannot ask for
    // something the menu beside it refuses.
    m.interval = "0.5"
    #expect(m.intervalProblem == nil)
    #expect(m.plan == WatchPlan(interval: 0.5, stop: .never))

    for bad in ["", "   ", "abc", "0", "-1", "0.1", "3601", "nan"] {
        m.interval = bad
        #expect(m.intervalProblem != nil, "\(bad) should be refused")
        #expect(m.plan == nil, "\(bad) should build no plan")
    }
}

@Test func validatesCountAndCondition() {
    var m = WatchPlanEditorModel(interval: 5)
    m.stop = .count
    m.count = "10"
    #expect(m.problem == nil)
    #expect(m.plan == WatchPlan(interval: 5, stop: .count(10)))
    for bad in ["", "0", "-3", "1.5", "abc"] {
        m.count = bad
        #expect(m.countProblem != nil, "\(bad) should be refused")
        #expect(m.plan == nil)
    }
    // A bad count while the stop rule is "never" is not a problem: the field is not being read.
    m.stop = .never
    #expect(m.problem == nil)
    #expect(m.plan == WatchPlan(interval: 5, stop: .never))

    m.stop = .until
    m.condition = .status
    m.value = "200"
    #expect(m.problem == nil)
    #expect(m.plan == WatchPlan(interval: 5, stop: .until(.status(200))))
    for bad in ["", "99", "600", "2xx"] {
        m.value = bad
        #expect(m.conditionProblem != nil, "\(bad) should be refused as a status")
    }
    m.condition = .statusClass
    m.value = "2"
    #expect(m.plan == WatchPlan(interval: 5, stop: .until(.statusClass(2))))
    m.value = "9"
    #expect(m.conditionProblem != nil)
    m.condition = .bodyContains
    m.value = ""
    #expect(m.conditionProblem != nil)
    m.value = "ready"
    #expect(m.plan == WatchPlan(interval: 5, stop: .until(.bodyContains("ready"))))
}

@Test func buildsPlanTitles() {
    var m = WatchPlanEditorModel(interval: 5)
    #expect(m.title == "every 5 s")
    m.stop = .count
    m.count = "10"
    #expect(m.title == "10 times")
    m.stop = .until
    m.condition = .status
    m.value = "200"
    #expect(m.title == "every 5 s until 200")
    m.condition = .statusClass
    m.value = "2"
    #expect(m.title == "every 5 s until 2xx")
    m.condition = .statusNot
    m.value = "503"
    #expect(m.title == "every 5 s until not 503")
    m.condition = .bodyLacks
    m.value = "pending"
    #expect(m.title == "every 5 s until body lacks \"pending\"")
    // A title is a description of what the fields say, so a field that cannot be read has none:
    // "every  s" over a Start button that is disabled would be describing a plan nobody can run.
    m.interval = "zzz"
    #expect(m.title == "")
}

@Test func theHeaderIsTheSeriesAtAGlance() {
    var s = WatchSeries(plan: WatchPlan(interval: 5, stop: .never), command: "curl x", startedAt: 0)
    s.runStarted(id: 1, at: 0)
    let running = s.header()
    #expect(running.dots == [.running])
    #expect(running.showsStop)
    #expect(running.text == s.headerText)
    s.runFinished(id: 1, status: 200, exitStatus: 0, timeTotal: 0.1, body: "", at: 1)
    s.stop(.stopped)
    let stopped = s.header()
    #expect(stopped.dots == [.success])
    #expect(!stopped.showsStop)
}
