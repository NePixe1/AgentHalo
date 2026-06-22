import AppKit

enum StatusIcon {
    @MainActor
    static func image(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer {
            image.unlockFocus()
        }
        let rect = NSRect(x: 2, y: 2, width: 14, height: 14)
        color.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        // Short arc on the left (140° to 220°)
        path.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: 6, startAngle: 140, endAngle: 220)
        path.stroke()
        path.removeAllPoints()
        // Long arc on the right (-115° to 115° counterclockwise)
        path.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: 6, startAngle: -115, endAngle: 115)
        path.stroke()
        return image
    }
}
