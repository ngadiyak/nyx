import Foundation

/// A scored match of a query against one candidate, with the characters that matched.
public struct FuzzyMatch: Equatable {
    public let score: Int
    /// Character offsets in the candidate that the query matched, for highlighting them.
    public let positions: [Int]

    public init(score: Int, positions: [Int]) {
        self.score = score
        self.positions = positions
    }
}

/// Subsequence matching with the bonuses that make a command palette feel like it read your mind.
///
/// Plain subsequence matching ranks badly: every candidate containing the letters in order scores
/// the same, so `nt` offers "Font Smaller" alongside "New Tab". The bonuses encode what a person
/// actually means when they type a few letters -- initials of words, and runs of adjacent
/// characters -- so the obvious answer comes first.
public enum FuzzySearch {
    private static let wordStartBonus = 12
    private static let consecutiveBonus = 8
    private static let firstCharacterBonus = 10
    private static let leadingGapPenalty = 1
    private static let maximumLeadingPenalty = 12
    /// Paid per character when the *whole* query matched as one unbroken run. A contiguous match is
    /// a far stronger signal than the same letters scattered across word starts: typing `tab` means
    /// "New Tab", not "The Absolute Best", even though the second begins with a `t`.
    private static let contiguousBonus = 10

    /// Scores `query` against `candidate`, or nil when the query is not a subsequence of it.
    ///
    /// An empty query matches everything with score 0, which is what an empty palette field means:
    /// show me the list.
    public static func match(_ query: String, _ candidate: String) -> FuzzyMatch? {
        guard !query.isEmpty else { return FuzzyMatch(score: 0, positions: []) }

        let target = Array(candidate)
        let lowerTarget = Array(candidate.lowercased())
        let needle = Array(query.lowercased())
        guard needle.count <= target.count else { return nil }

        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var score = 0
        var index = 0
        var previousMatch = -2

        for character in needle {
            guard let found = nextIndex(of: character, in: lowerTarget, from: index) else { return nil }
            score += bonus(at: found, target: target, lowerTarget: lowerTarget,
                           previousMatch: previousMatch, isFirstNeedle: positions.isEmpty)
            positions.append(found)
            previousMatch = found
            index = found + 1
        }

        if isContiguous(positions) { score += contiguousBonus * positions.count }

        // A match buried deep in a long string is usually not what was meant, so the further in it
        // starts the less it scores -- bounded, or long candidates could never win at all.
        let leading = min(positions[0] * leadingGapPenalty, maximumLeadingPenalty)
        return FuzzyMatch(score: score - leading, positions: positions)
    }

    private static func nextIndex(of character: Character, in target: [Character], from: Int) -> Int? {
        guard from < target.count else { return nil }
        return (from..<target.count).first { target[$0] == character }
    }

    private static func bonus(at index: Int, target: [Character], lowerTarget: [Character],
                              previousMatch: Int, isFirstNeedle: Bool) -> Int {
        var score = 1
        if index == previousMatch + 1 { score += consecutiveBonus }
        if index == 0 {
            score += wordStartBonus
            if isFirstNeedle { score += firstCharacterBonus }
        } else if isWordStart(index, target: target, lowerTarget: lowerTarget) {
            score += wordStartBonus
        }
        return score
    }

    private static func isContiguous(_ positions: [Int]) -> Bool {
        zip(positions, positions.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }

    /// The start of a word: after a separator, or a capital following a lowercase, so `newTab`
    /// and `New Tab` both give `T` the bonus.
    private static func isWordStart(_ index: Int, target: [Character], lowerTarget: [Character]) -> Bool {
        let previous = target[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "/" || previous == "." {
            return true
        }
        return target[index] != lowerTarget[index] && previous == Character(previous.lowercased())
    }

    /// Candidates that match, best first.
    ///
    /// Equal scores break towards the shorter candidate -- the same query filling more of a string
    /// is a better answer than it appearing inside a longer one -- and then towards the order the
    /// caller gave, so the menu's own ordering survives instead of the list scrambling as you type.
    public static func rank<T>(_ query: String, _ items: [T],
                               by text: (T) -> String) -> [(item: T, match: FuzzyMatch)] {
        var scored: [(offset: Int, length: Int, item: T, match: FuzzyMatch)] = []
        scored.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let candidate = text(item)
            guard let m = match(query, candidate) else { continue }
            scored.append((offset: offset, length: candidate.count, item: item, match: m))
        }
        // With nothing typed every candidate scores the same, so the tie-break *is* the order --
        // and "shortest first" shuffled the caller's sections into an arbitrary list the moment the
        // palette opened. An empty query keeps the order it was given; length still breaks ties
        // once something is typed, which is where it does what it is for: preferring the shorter of
        // two equally good matches.
        let untyped = query.isEmpty
        scored.sort { a, b in
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            if !untyped, a.length != b.length { return a.length < b.length }
            return a.offset < b.offset
        }
        return scored.map { (item: $0.item, match: $0.match) }
    }
}
