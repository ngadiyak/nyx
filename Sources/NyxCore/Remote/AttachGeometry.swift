/// The screen size a host is allowed to claim in `attached`.
///
/// The two numbers in that message are the only thing on the wire that decides how big the mirror
/// `Terminal` is, and they are not signed by anything: the host signs its ephemeral key, not the
/// geometry, so a relay in the middle -- or a host that has been made to say anything -- can put
/// `2_000_000_000` in either field. `RemoteSession` applies them on the main thread, which is the
/// thread that draws, so the cost of believing them is the whole application stopping while it
/// allocates a grid that cannot exist.
///
/// The bounds are deliberately far outside anything real (a 6K display at the smallest usable font
/// is nowhere near a thousand columns) so that no honest host is ever refused: this is a sanity
/// floor, not a policy about window sizes.
public enum AttachGeometry {
    /// One column is not a screen -- nothing wraps in it -- and it is also what an `attached`
    /// carrying no geometry at all decodes to, which must be refused for the same reason.
    public static let columnRange = 2...1000
    public static let rowRange = 1...1000

    public static func isSane(cols: Int, rows: Int) -> Bool {
        columnRange.contains(cols) && rowRange.contains(rows)
    }
}

/// A terminal grid in cells. Two of these -- the host's and the pane's -- are what
/// `AttachState.geometryNote` compares; a pair of loose `Int`s in that call would be four
/// interchangeable numbers at every call site.
public struct GridSize: Equatable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}
