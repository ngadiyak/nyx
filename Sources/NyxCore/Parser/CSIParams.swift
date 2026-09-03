/// CSI parameter list. Each item is one parameter with its colon-separated sub-parameters.
///
/// Stored flat and inline: all sub-parameter values end to end in `flat`, with one end index per
/// parameter in `ends`. Fixed-size SIMD storage keeps the whole value trivial, so the parser can
/// hand a sequence's parameters to its receiver with no allocation and no retain/release traffic.
/// Sequences longer than the caps are truncated, which is what a terminal wants anyway.
public struct CSIParams: Equatable {
    /// Maximum total number of values across all parameters.
    public static let maxValues = 32
    /// Maximum number of parameters.
    public static let maxParams = 32

    private var flat = SIMD32<Int32>()
    /// `ends[i]` is one past the last index in `flat` belonging to parameter `i`.
    private var ends = SIMD32<UInt8>()
    /// Number of parameters; only the first `n` lanes of `ends` are meaningful.
    private var n = 0
    /// Number of values written to `flat`, including the parameter still being collected.
    private var used = 0

    public init() {}

    public init(_ items: [[Int]]) {
        for item in items {
            guard n < CSIParams.maxParams else { break }
            for v in item { append(v) }
            closeParameter()
        }
    }

    // MARK: - Building (used by the parser)

    /// Appends one value to the parameter currently being collected.
    @inline(__always)
    mutating func append(_ v: Int) {
        guard used < CSIParams.maxValues else { return }
        flat[used] = Int32(clamping: v)
        used += 1
    }

    /// Ends the parameter currently being collected.
    @inline(__always)
    mutating func closeParameter() {
        if n < CSIParams.maxParams {
            ends[n] = UInt8(used)
            n += 1
        } else {
            used = pendingStart   // over the cap: drop this parameter's values
        }
    }

    /// Start of the parameter currently being collected, as an index into `flat`.
    @inline(__always)
    var pendingStart: Int { n == 0 ? 0 : Int(ends[n - 1]) }

    /// True when values have been collected but not yet closed into a parameter.
    @inline(__always)
    var hasPendingValues: Bool { used > pendingStart }

    @inline(__always)
    mutating func reset() {
        n = 0
        used = 0
    }

    // MARK: - Reading

    public var count: Int { n }

    public static func == (a: CSIParams, b: CSIParams) -> Bool {
        guard a.n == b.n else { return false }
        for i in 0..<a.n where a.ends[i] != b.ends[i] { return false }
        let used = a.n == 0 ? 0 : Int(a.ends[a.n - 1])
        for i in 0..<used where a.flat[i] != b.flat[i] { return false }
        return true
    }

    /// The nested form: one array of sub-parameters per parameter. Allocates; prefer `get`/`value`.
    public var items: [[Int]] {
        var out: [[Int]] = []
        out.reserveCapacity(n)
        var start = 0
        for i in 0..<n {
            let end = Int(ends[i])
            out.append((start..<end).map { Int(flat[$0]) })
            start = end
        }
        return out
    }

    @inline(__always)
    private func start(of i: Int) -> Int { i == 0 ? 0 : Int(ends[i - 1]) }

    /// Number of sub-parameters of parameter `i` (0 when absent).
    public func subCount(_ i: Int) -> Int {
        i < n ? Int(ends[i]) - start(of: i) : 0
    }

    /// Sub-parameter `j` of parameter `i`, or 0 when absent.
    public func value(_ i: Int, _ j: Int) -> Int {
        guard i < n else { return 0 }
        let k = start(of: i) + j
        return k < Int(ends[i]) ? Int(flat[k]) : 0
    }

    /// The first value of parameter `i`, or `def` when the parameter is absent or zero.
    public func get(_ i: Int, _ def: Int = 0) -> Int {
        guard i < n else { return def }
        let s = start(of: i)
        guard s < Int(ends[i]) else { return def }
        let v = Int(flat[s])
        return v == 0 ? def : v
    }

    /// All sub-parameters of parameter `i` (empty when absent).
    public func sub(_ i: Int) -> [Int] {
        guard i < n else { return [] }
        return (start(of: i)..<Int(ends[i])).map { Int(flat[$0]) }
    }
}
