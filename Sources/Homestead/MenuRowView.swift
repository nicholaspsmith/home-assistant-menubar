import AppKit

/// Base for a clickable row inside an NSMenu.
///
/// A view-based menu item buys two things a plain `NSMenuItem` cannot have —
/// real controls, and a click that does *not* dismiss the menu — but it also
/// gives up everything AppKit draws for free. This puts the highlight back:
/// `NSMenuItem.isHighlighted` is true while the pointer is over the item, even
/// for a view-based one, so the row paints the same selection bar a native item
/// would and the menu stops looking inert.
class MenuRowView: NSView {
    /// Run when the row is clicked. Subclasses with their own controls (a
    /// switch, a slider) leave this nil and let the control act instead.
    var onClick: (() -> Void)?

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }

    var isRowHighlighted: Bool {
        onClick != nil && enclosingMenuItem?.isHighlighted == true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isRowHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        // Inset to match a native menu item's highlight, which stops short of
        // the menu's rounded edge.
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    /// The label colour a row should use, so text stays readable on the
    /// highlight bar.
    var rowTextColor: NSColor { isRowHighlighted ? .selectedMenuItemTextColor : .labelColor }
}
