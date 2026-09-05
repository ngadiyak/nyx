import Testing
@testable import NyxCore

@Test func backoffDoublesAndCaps() {
    var b = Backoff(initial: 1, maximum: 60)
    let sequence = (0..<8).map { _ in b.next() }
    #expect(sequence == [1, 2, 4, 8, 16, 32, 60, 60])
}

@Test func resetGoesBackToInitial() {
    var b = Backoff(initial: 1, maximum: 60)
    _ = b.next()
    _ = b.next()
    _ = b.next()
    b.reset()
    #expect(b.next() == 1)
}

@Test func customInitialAndMaximum() {
    var b = Backoff(initial: 2, maximum: 10)
    #expect(b.next() == 2)
    #expect(b.next() == 4)
    #expect(b.next() == 8)
    #expect(b.next() == 10)
    #expect(b.next() == 10)
}
