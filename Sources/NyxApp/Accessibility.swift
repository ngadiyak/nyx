import AppKit

/// One control inside a view that draws itself, described to the accessibility system.
///
/// `TabBarView` and the command palette's list have no subviews at all: a tab, a close button, a
/// quick-action chip and a palette row are rectangles their view draws and hit-tests by hand. That
/// is the right shape for drawing -- a handful of rects rather than a view per tab -- but it means
/// AppKit has nothing to report, and VoiceOver over that bar found one unlabelled group with
/// nothing in it. This puts the controls back: an element per rectangle, with the name the tooltip
/// already uses, the role it actually plays, and the press it actually performs.
final class DrawnControlElement: NSAccessibilityElement {
    private var press: (() -> Void)?

    /// `frame` is in the parent view's own coordinates, flipped or not; `parent` is asked which.
    static func make(label: String, role: NSAccessibility.Role, frame: NSRect, in parent: NSView,
                     value: Any? = nil, press: (() -> Void)? = nil) -> DrawnControlElement {
        let element = DrawnControlElement()
        element.setAccessibilityParent(parent)
        element.setAccessibilityRole(role)
        element.setAccessibilityLabel(label)
        if let value { element.setAccessibilityValue(value) }
        element.press = press
        // `accessibilityFrameInParentSpace` is measured from the bottom left whatever the parent
        // does, so a flipped view's rectangles have to be turned over here. Without this every
        // element in the tab bar reports a frame mirrored about the bar's middle, and VoiceOver's
        // cursor lands nowhere near the control it is naming.
        let y = parent.isFlipped ? parent.bounds.height - frame.maxY : frame.minY
        element.setAccessibilityFrameInParentSpace(NSRect(x: frame.minX, y: y,
                                                          width: frame.width, height: frame.height))
        return element
    }

    override func isAccessibilityElement() -> Bool { true }

    override func isAccessibilityEnabled() -> Bool { press != nil }

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}

extension NSView {
    /// Names a control and says what kind of thing it is. Most of the application's controls are
    /// AppKit's own and carry a title that names them already; these are the ones that do not --
    /// an icon button, a field whose only label is a placeholder, a value beside a slider.
    func describeForAccessibility(_ label: String, role: NSAccessibility.Role? = nil,
                                  help: String? = nil) {
        setAccessibilityLabel(label)
        if let role { setAccessibilityRole(role) }
        if let help { setAccessibilityHelp(help) }
        setAccessibilityElement(true)
    }
}
