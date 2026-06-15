import AppKit
import AgentHaloCore

struct HaloRenderInput {
    var state: HaloState
    var errorPresentation: ErrorPresentation
    var steadyDone: Bool
    var transitionFrom: HaloVisualSnapshot
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
        var visual = HaloVisualModel.transitionVisual(
            from: input.transitionFrom,
            to: target,
            progress: input.transition
        )
        let color = HaloVisualModel.animatedColor(
            from: input.transitionFrom.color,
            to: target.color,
            progress: input.transition
        )
        let completionFlash = input.state == .done && !input.steadyDone && input.transition >= 0.999
            ? HaloVisualModel.completionDoubleFlash(sinceState: input.sinceState)
            : 0
        visual.powered = HaloMath.clamp(visual.powered + completionFlash * 0.82, 0, 1)
        let scale = min(bounds.width, bounds.height) / 112.0
        let intensity = HaloMath.clamp(visual.intensity + HaloMath.stateBreath(input.state, time: input.time) * 0.18 + completionFlash * 0.5, 0, 1.32)
        let radius = scale * (35.8 + completionFlash * 0.45)
        let bodyWidth = scale * (visual.bodyWidth + completionFlash * 0.65)
        let material = HaloVisualModel.materialSnapshot(color: color, visual: visual, intensity: intensity)

        context.setLineCap(.round)
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: scale * 19.5, color: nsColor(material.emissionColor, alpha: material.glowAlphas[0]))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: scale * 14.5, color: nsColor(material.emissionColor, alpha: material.glowAlphas[1]))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: scale * 11.2, color: nsColor(material.emissionColor, alpha: material.glowAlphas[2]))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: scale * 9.8, color: nsColor(material.glowColor, alpha: material.glowAlphas[3]))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: bodyWidth + scale * 1.15, color: nsColor(material.darkMaterial, alpha: material.darkAlpha))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: bodyWidth, color: nsColor(material.poweredMaterial, alpha: material.materialAlpha))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: max(scale * 0.9, bodyWidth - scale * 2.25), color: nsColor(material.poweredCore, alpha: material.coreAlpha))
        drawRingLayer(context: context, center: center, radius: radius, gapA: input.gapA, gapB: input.gapB, width: scale * 1.65, color: nsColor(HaloRGB(red: 255, green: 255, blue: 255), alpha: material.whiteSparkAlpha))
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

    static func nsColor(_ rgb: HaloRGB, alpha: Double = 255) -> NSColor {
        NSColor(
            calibratedRed: HaloMath.clamp(rgb.red, 0, 255) / 255,
            green: HaloMath.clamp(rgb.green, 0, 255) / 255,
            blue: HaloMath.clamp(rgb.blue, 0, 255) / 255,
            alpha: HaloMath.clamp(alpha, 0, 255) / 255
        )
    }
}
