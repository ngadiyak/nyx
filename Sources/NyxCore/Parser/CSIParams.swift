/// CSI parameter list. Each item is one parameter with its colon-separated sub-parameters.
///
/// Stored flat -- all sub-parameter values end to end, plus one end index per parameter -- so the
/// parser can hand a sequence's parameters over without allocating a nested array per parameter.
/// `items` rebuilds the nested form for callers that want it.
public struct CSIParams: Equatable {
    private var flat: [Int]
    /// `ends[i]` is one past the last index in `flat` belonging to parameter `i`.
    private var ends: [Int]
    /// Number of parameters, i.e. the used prefix of `ends`. The parser reuses oversized buffers
    /// across sequences rather than clearing them, so the arrays may be longer than this.
    private let n: Int

    public init(_ items: [[Int]] = []) {
        flat = []
        ends = []
        flat.reserveCapacity(items.count)
        ends.reserveCapacity(items.count)
        for item in items {
            flat.append(contentsOf: item)
            ends.append(flat.count)
        }
        n = ends.count
    }

    init(flat: [Int], ends: [Int], count: Int) {
        self.flat = flat
        self.ends = ends
        n = count
    }

    public var count: Int { n }

    public static func == (a: CSIParams, b: CSIParams) -> Bool {
        guard a.n == b.n else { return false }
        for i in 0..<a.n where a.ends[i] != b.ends[i] { return false }
        let used = a.n == 0 ? 0 : a.ends[a.n - 1]
        for i in 0..<used where a.flat[i] != b.flat[i] { return false }
        return true
    }

    /// The nested form: one array of sub-parameters per parameter. Allocates; prefer `get`/`value`.
    public var items: [[Int]] {
        var out: [[Int]] = []
        out.reserveCapacity(n)
        var start = 0
        for i in 0..<n {
            out.append(Array(flat[start..<ends[i]]))
            start = ends[i]
        }
        return out
    }

    @inline(__always)
    private func start(of i: Int) -> Int { i == 0 ? 0 : ends[i - 1] }

    /// Number of sub-parameters of parameter `i` (0 when absent).
    public func subCount(_ i: Int) -> Int {
        i < n ? ends[i] - start(of: i) : 0
    }

    /// Sub-parameter `j` of parameter `i`, or 0 when absent.
    public func value(_ i: Int, _ j: Int) -> Int {
        guard i < n else { return 0 }
        let k = start(of: i) + j
        return k < ends[i] ? flat[k] : 0
    }

    /// The first value of parameter `i`, or `def` when the parameter is absent or zero.
    public func get(_ i: Int, _ def: Int = 0) -> Int {
        guard i < n else { return def }
        let s = start(of: i)
        guard s < ends[i] else { return def }
        let v = flat[s]
        return v == 0 ? def : v
    }

    /// All sub-parameters of parameter `i` (empty when absent).
    public func sub(_ i: Int) -> [Int] {
        guard i < n else { return [] }
        return Array(flat[start(of: i)..<ends[i]])
    }
}
