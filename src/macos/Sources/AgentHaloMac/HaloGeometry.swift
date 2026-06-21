import CoreGraphics

enum HaloGeometry {
    static let referenceSize: CGFloat = 112
    static let ringRadius: CGFloat = 35.8
    static let widestGlowWidth: CGFloat = 19.5
    static let hoverTolerance: CGFloat = 4

    static func scale(in bounds: CGRect) -> CGFloat {
        min(bounds.width, bounds.height) / referenceSize
    }

    static func contains(point: CGPoint, in bounds: CGRect) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else {
            return false
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = scale(in: bounds) * (ringRadius + widestGlowWidth / 2 + hoverTolerance)
        return dx * dx + dy * dy <= radius * radius
    }
}
