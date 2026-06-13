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
        path.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: 6, startAngle: -50, endAngle: 90)
        path.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY), radius: 6, startAngle: 110, endAngle: 300)
        path.stroke()
        return image
    }
}
