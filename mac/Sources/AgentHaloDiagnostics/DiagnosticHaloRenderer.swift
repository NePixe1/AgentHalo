import AppKit
import AgentHaloCore

struct DiagnosticHaloRenderInput {
    var state: HaloState
    var errorPresentation: ErrorPresentation
    var steadyDone: Bool
    var time: Double
    var sinceState: Double
    var gapA: Double
    var gapB: Double
}

enum DiagnosticHaloRenderer {
    static func renderPNG(input: DiagnosticHaloRenderInput, size: CGFloat = 160) throws -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            drawPureRing(context: context, bounds: CGRect(x: 0, y: 0, width: size, height: size), input: input)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AgentHaloDiagnostics", code: 2)
        }
        return png
    }

    static func drawPureRing(context: CGContext, bounds: CGRect, input: DiagnosticHaloRenderInput) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let target = HaloVisualModel.targetVisual(
            state: input.state,
            time: input.sinceState,
            errorPresentation: input.errorPresentation,
            steadyDone: input.steadyDone
        )
        let color = nsColor(HaloVisualModel.stateColor(input.state))
        let morph = HaloMath.ringMorph(
            state: input.state,
            time: input.sinceState,
            breath: target.breath,
            powered: target.powered
        )
        let scale = min(bounds.width, bounds.height) / 112.0
        let intensity = min(max(target.intensity + HaloMath.stateBreath(input.state, time: input.time) * 0.18 + morph.glowBoost, 0), 1.42)
        let radius = scale * (35.8 + morph.radiusOffset)
        let bodyWidth = scale * (target.bodyWidth + morph.bodyWidthOffset)
        let gapA = input.gapA + morph.gapSkew
        let gapB = input.gapB - morph.gapSkew * 0.62

        context.setLineCap(.round)
        drawRingLayer(context: context, center: center, radius: radius, gapA: gapA, gapB: gapB, gapOpen: morph.gapOpen, width: scale * 19.5, color: color.withAlphaComponent(0.10 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: gapA, gapB: gapB, gapOpen: morph.gapOpen, width: scale * 14.5, color: color.withAlphaComponent(0.18 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: gapA, gapB: gapB, gapOpen: morph.gapOpen, width: scale * 11.2, color: color.withAlphaComponent(0.28 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: gapA, gapB: gapB, gapOpen: morph.gapOpen, width: bodyWidth + scale * 1.15, color: color.withAlphaComponent(0.72 * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: gapA, gapB: gapB, gapOpen: morph.gapOpen, width: max(scale * 1.0, bodyWidth - scale * 2.25), color: NSColor.white.withAlphaComponent(0.60 * target.powered * intensity))
        drawRingLayer(context: context, center: center, radius: radius, gapA: gapA, gapB: gapB, gapOpen: morph.gapOpen, width: scale * 1.65, color: NSColor.white.withAlphaComponent(0.80 * target.powered * intensity))

        if morph.secondaryOpacity > 0.02 {
            let secondary = morph.secondaryOpacity * intensity
            let edgeColor = nsColor(HaloMath.mixColor(
                HaloVisualModel.stateColor(input.state),
                HaloRGB(red: 248, green: 253, blue: 252),
                amount: 0.48 + 0.24 * target.powered
            ))
            drawRingLayer(context: context, center: center, radius: radius - scale * 4.9, gapA: gapA + 4.5, gapB: gapB + 2.2, gapOpen: morph.gapOpen * 0.72, width: scale * 1.55, color: edgeColor.withAlphaComponent(0.52 * secondary))
            drawRingLayer(context: context, center: center, radius: radius + scale * 4.7, gapA: gapA - 3.6, gapB: gapB - 2.6, gapOpen: morph.gapOpen * 0.64, width: scale * 1.2, color: color.withAlphaComponent(0.36 * secondary))
        }
    }

    private static func drawRingLayer(context: CGContext, center: CGPoint, radius: CGFloat, gapA: Double, gapB: Double, gapOpen: Double, width: Double, color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        let gapASize = 27.0 + 13.0 * HaloMath.clamp(gapOpen, 0, 1)
        let gapBSize = 19.0 + 9.0 * HaloMath.clamp(gapOpen, 0, 1)
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

    private static func nsColor(_ rgb: HaloRGB) -> NSColor {
        NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
    }
}
