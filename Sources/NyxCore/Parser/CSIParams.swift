/// CSI parameter list. Each item is one parameter with its colon-separated sub-parameters.
public struct CSIParams: Equatable {
    public var items: [[Int]]

    public init(_ items: [[Int]] = []) { self.items = items }

    public var count: Int { items.count }

    /// The first value of parameter `i`, or `def` when the parameter is absent or zero.
    public func get(_ i: Int, _ def: Int = 0) -> Int {
        guard i < items.count, let v = items[i].first, v != 0 else { return def }
        return v
    }

    /// All sub-parameters of parameter `i` (empty when absent).
    public func sub(_ i: Int) -> [Int] { i < items.count ? items[i] : [] }
}
