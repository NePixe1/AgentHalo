import AppKit
import AgentHaloCore
import QuartzCore

struct HaloRenderInput {
    var state: HaloState
    var errorPresentation: ErrorPresentation
    var steadyDone: Bool
    var answerStreaming: Bool
    var transitionFrom: HaloVisualSnapshot
    var time: Double
    var sinceState: Double
    var transition: Double
    var gapA: Double
    var gapB: Double
}

enum HaloRenderer {
    // Eight stacked ring strokes share the same two-arc geometry (only line width
    // and stroke color differ). Hosted as CAShapeLayer sublayers so Core Animation
    // rasterizes them on the render server (GPU) instead of the app process
    // rasterizing a backing store via CGContext.draw(_:) every frame.
    static let ringLayerCount = 8

    static func applyRingLayers(_ layers: [CAShapeLayer], bounds: CGRect, input: HaloRenderInput) {
        guard layers.count == ringLayerCount else {
            return
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let visualState: HaloState = input.answerStreaming ? .done : input.state
        let target = HaloVisualModel.targetVisual(
            state: visualState,
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
        let streamingFlash = input.answerStreaming
            ? HaloVisualModel.completionDoubleFlash(
                sinceState: HaloMath.positiveModulo(input.sinceState, 1.8)
            )
            : 0
        let doneFlash = input.state == .done && !input.steadyDone && input.transition >= 0.999
            ? HaloVisualModel.completionDoubleFlash(sinceState: input.sinceState)
            : 0
        let completionFlash = max(doneFlash, streamingFlash)
        visual.powered = HaloMath.clamp(visual.powered + completionFlash * 0.82, 0, 1)
        let scale = HaloGeometry.scale(in: bounds)
        let intensity = HaloMath.clamp(visual.intensity + HaloMath.stateBreath(visualState, time: input.time) * 0.18 + completionFlash * 0.5, 0, 1.32)
        let radius = scale * (HaloGeometry.ringRadius + completionFlash * 0.45)
        let bodyWidth = scale * (visual.bodyWidth + completionFlash * 0.65)
        let material = HaloVisualModel.materialSnapshot(color: color, visual: visual, intensity: intensity)

        let path = ringPath(center: center, radius: radius, gapA: input.gapA, gapB: input.gapB)
        let styles: [(width: CGFloat, color: NSColor)] = [
            (scale * HaloGeometry.widestGlowWidth, nsColor(material.emissionColor, alpha: material.glowAlphas[0])),
            (scale * 14.5, nsColor(material.emissionColor, alpha: material.glowAlphas[1])),
            (scale * 11.2, nsColor(material.emissionColor, alpha: material.glowAlphas[2])),
            (scale * 9.8, nsColor(material.glowColor, alpha: material.glowAlphas[3])),
            (bodyWidth + scale * 1.15, nsColor(material.darkMaterial, alpha: material.darkAlpha)),
            (bodyWidth, nsColor(material.poweredMaterial, alpha: material.materialAlpha)),
            (max(scale * 0.9, bodyWidth - scale * 2.25), nsColor(material.poweredCore, alpha: material.coreAlpha)),
            (scale * 1.65, nsColor(HaloRGB(red: 255, green: 255, blue: 255), alpha: material.whiteSparkAlpha))
        ]
        // Disable implicit animations: these properties are updated every frame to
        // drive a manual animation, so each set must snap instantly to the new
        // value (matching the previous draw(_:) behavior) rather than be smoothed
        // by Core Animation's default 0.25s interpolation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, style) in zip(layers, styles) {
            layer.path = path
            layer.strokeColor = style.color.cgColor
            layer.lineWidth = style.width
        }
        CATransaction.commit()
    }

    private static func ringPath(center: CGPoint, radius: CGFloat, gapA: Double, gapB: Double) -> CGPath {
        let path = CGMutablePath()
        let gapASize = 30.0
        let gapBSize = 22.0
        addArc(to: path, center: center, radius: radius, start: gapA + gapASize / 2, sweep: positiveModulo(gapB - gapBSize / 2 - (gapA + gapASize / 2), 360))
        addArc(to: path, center: center, radius: radius, start: gapB + gapBSize / 2, sweep: positiveModulo(gapA - gapASize / 2 - (gapB + gapBSize / 2), 360))
        return path
    }

    private static func addArc(to path: CGMutablePath, center: CGPoint, radius: CGFloat, start: Double, sweep: Double) {
        guard sweep > 0.001 else {
            return
        }
        let startRadians = CGFloat(start * .pi / 180)
        let endRadians = CGFloat((start + sweep) * .pi / 180)
        // Each arc must begin a fresh subpath. CGPath.addArc otherwise draws a
        // line from the path's current point (the previous arc's end) to this
        // arc's start, and CAShapeLayer strokes that connector as a chord cutting
        // across the ring — collapsing the two gaps into one and making the ring
        // uneven. The original draw(_:) stroked each arc on a separately cleared
        // CGContext path, so it never had this connecting segment.
        let startPoint = CGPoint(
            x: center.x + radius * cos(startRadians),
            y: center.y + radius * sin(startRadians)
        )
        path.move(to: startPoint)
        path.addArc(center: center, radius: radius, startAngle: startRadians, endAngle: endRadians, clockwise: false)
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
