import AppKit

enum StatusIcon {
    /// Monochrome menu-bar template matching the Agent Halo brand mark
    /// (short left arc + long arc, two breakpoints). System tints it for
    /// light/dark menu bar; it does not follow live halo state color.
    @MainActor
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // Template images use the alpha mask; stroke in black.
            NSColor.black.setStroke()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6
            let path = NSBezierPath()
            path.lineWidth = 2.2
            path.lineCapStyle = .round

            // AppKit: 0° = east, positive = counter-clockwise.
            // Short arc on the left (breakpoint segment).
            // Upper gap (long end → short start) is intentionally a bit larger
            // than before so round caps don't fuse it shut, but still tighter
            // than the lower gap (short end → long start).
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 142,
                endAngle: 195
            )
            path.stroke()

            // Long arc the rest of the way (must go CCW so 230→110 wraps
            // through bottom → right → top; clockwise would only redraw the left).
            path.removeAllPoints()
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 230,
                endAngle: 112
            )
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
