import Foundation

/// How wide the two halves of a command-palette row may draw.
///
/// The row is a title on the left and a detail on the right, and until the Remote section existed
/// every detail was two or three characters -- "Theme", "Tab", `⌘⇧P` -- so nothing ever collided
/// and the view simply drew both at their natural widths. A remote session's detail is a sentence
/// (`~/projects/nyx  main · running: swift test · 2 min ago · last: make test`), and drawn that way
/// it ran straight through the title: two strings on top of each other, neither readable.
///
/// The rule keeps the title, because the title is what the row *is* and the detail is what it is
/// like. The detail may take a little over half the row and no more, and it hands back whatever a
/// short title does not need -- so an ordinary row still shows its chord flush right, exactly where
/// it has always been.
public enum PaletteRowLayout {
    /// The most each half may draw in. Both are clamped at their natural widths, so a caller that
    /// gets back what it asked for knows nothing had to be truncated.
    public static func widths(rowWidth: Double, titleWidth: Double, detailWidth: Double,
                              gap: Double = 12) -> (title: Double, detail: Double) {
        let available = max(0, rowWidth - gap)
        guard titleWidth + detailWidth > available else { return (titleWidth, detailWidth) }
        let detail = min(detailWidth, available * detailShare)
        let title = max(0, available - detail)
        // A title that does not need its whole share leaves the rest to the detail rather than to
        // empty space in the middle of the row.
        return (min(titleWidth, title), min(detailWidth, available - min(titleWidth, title)))
    }

    /// A little over half. The title is the more important of the two, but a detail squeezed below
    /// half a row stops carrying the directory and the branch, which is the part of it anybody
    /// reads first.
    private static let detailShare = 0.55
}
