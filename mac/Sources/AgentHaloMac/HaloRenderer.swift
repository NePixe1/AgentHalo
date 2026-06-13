import AppKit
import AgentHaloCore

struct HaloRenderInput {
    var state: HaloState
    var errorPresentation: ErrorPresentation
    var steadyDone: Bool
    var time: Double
    var sinceState: Double
    var transition: Double
    var gapA: Double
    var gapB: Double
}

enum HaloRenderer {
    static func drawPureRing(context: CGContext, bounds: CGRect, input: HaloRenderInput) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let target = HaloVisualModel.targetVisual(
            state: input.state,
            time: input.sinceState,
            errorPresentation: input.errorPresentation,
            steadyDone: input.steadyDone
        )
        let color = nsColor(HaloVisualModel.stateColor(input.state))
        let intensity = min(max(target.intensity + HaloMath.stateBreath(input.state, time: input.time) * 0.18, 0), 1.32)
        let radius = min(bounds.width, bounds.height) / 112.0 * 35.8
        let bodyWidth = target.bodyWidth

        context.setLineCap(.round)
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: 19.5, color: color.withAlphaComponent(0.10 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: 14.5, color: color.withAlphaComponent(0.18 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: 11.2, color: color.withAlphaComponent(0.28 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: bodyWidth + 1.15, color: color.withAlphaComponent(0.72 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: bodyWidth - 2.25, color: NSColor.white.withAlphaComponent(0.60 * target.powered * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: 1.65, color: NSColor.white.withAlphaComponent(0.80 * target.powered * intensity))
    }

    private static func drawRingLayer(context: CGContext, center: CGPoint, radius: CGFloat, gapA: Double, gapB: Double, width: Double, color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        let gapASize = 30.0
        let gapBSize = 22.0
        drawArc(context: context, center: center, radius: radius, start: gapA + gapASize / 2, sweep: positiveModulo(gapB - gapBSize / 2 - (gapA + gapASize / 2), 360))
        drawArc(context: context, center: center, radius: radius, start: gapB + gapBSize / 2, sweep: positiveModulo(gapA - gapASize / 2 - (gapB + gapBSize / 2), 360))
    }

    private static func drawArc(context: CGContext, center: CGPoint, radius: CGFloat, start: Double, sweep: Double) {
        let startRadians = CGFloat(start * .pi / 180)
        let endRadians = CGFloat((start + sweep) * .pi / 180)
        context.addArc(center: center, radius: radius, startAngle: startRadians, endAngle: endRadians, clockwise: false)
        context.strokePath()
    }

    private static func positiveModulo(_ value: Double, _ modulus: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: modulus)
        return result < 0 ? result + modulus : result
    }

    static func nsColor(_ rgb: HaloRGB) -> NSColor {
        NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
    }
}
