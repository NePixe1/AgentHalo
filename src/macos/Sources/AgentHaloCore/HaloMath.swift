import Foundation

public struct HaloRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct HaloRingMorph: Equatable, Sendable {
    public var radiusOffset: Double
    public var bodyWidthOffset: Double
    public var secondaryOpacity: Double
    public var gapOpen: Double
    public var gapSkew: Double
    public var glowBoost: Double

    public init(
        radiusOffset: Double,
        bodyWidthOffset: Double,
        secondaryOpacity: Double,
        gapOpen: Double,
        gapSkew: Double,
        glowBoost: Double
    ) {
        self.radiusOffset = radiusOffset
        self.bodyWidthOffset = bodyWidthOffset
        self.secondaryOpacity = secondaryOpacity
        self.gapOpen = gapOpen
        self.gapSkew = gapSkew
        self.glowBoost = glowBoost
    }
}

public struct HaloRingStroke: Equatable, Sendable {
    public var radius: Double
    public var width: Double
    public var alphaScale: Double

    public init(radius: Double, width: Double, alphaScale: Double) {
        self.radius = radius
        self.width = width
        self.alphaScale = alphaScale
    }
}

public enum HaloMath {
    public static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    public static func lerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * amount
    }

    public static func positiveModulo(_ value: Double, _ modulus: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: modulus)
        return result < 0 ? result + modulus : result
    }

    public static func smootherStep(_ value: Double) -> Double {
        let value = clamp(value, 0, 1)
        return value * value * value * (value * (value * 6 - 15) + 10)
    }

    public static func easeInOutCubic(_ value: Double) -> Double {
        let value = clamp(value, 0, 1)
        return value < 0.5 ? 4 * value * value * value : 1 - pow(-2 * value + 2, 3) / 2
    }

    public static func easeOutCubic(_ value: Double) -> Double {
        1 - pow(1 - clamp(value, 0, 1), 3)
    }

    public static func easeOutQuint(_ value: Double) -> Double {
        1 - pow(1 - clamp(value, 0, 1), 5)
    }

    public static func damp(current: Double, target: Double, delta: Double, response: Double) -> Double {
        target + (current - target) * exp(-response * delta)
    }

    public static func softWave(_ phase: Double) -> Double {
        let cycle = positiveModulo(phase, 1)
        let triangle = cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2
        return smootherStep(triangle)
    }

    public static func livingBreath(time: Double, period: Double, maximum: Double, minimum: Double, brightShare: Double) -> Double {
        let phase = positiveModulo(time, period) / period
        let center = brightShare + (1 - brightShare) * 0.46
        var distance = abs(phase - center)
        distance = min(distance, 1 - distance)
        let width = max(0.075, (1 - brightShare) * 0.46)
        let dip = exp(-pow(distance / width, 4))
        let micro = 0.018 * sin(phase * .pi * 2) + 0.009 * sin(phase * .pi * 4 + 0.8)
        return clamp(maximum - (maximum - minimum) * dip + micro, minimum, maximum)
    }

    public static func stateBreath(_ state: HaloState, time: Double) -> Double {
        if state == .attention {
            return 0.18 + 0.82 * attentionPulse(time)
        }
        if state == .error {
            return errorPulse(time, presentation: .flashing)
        }
        let parameters = GeneratedHaloSpec.state(state)
        if state == .idle {
            return parameters.visualMinimum
                + (parameters.visualMaximum - parameters.visualMinimum)
                * softWave(time / parameters.breathPeriod)
        }
        return livingBreath(
            time: time,
            period: parameters.breathPeriod,
            maximum: parameters.visualMaximum,
            minimum: parameters.visualMinimum,
            brightShare: parameters.brightShare
        )
    }

    public static func targetPowered(_ state: HaloState, time: Double) -> Double {
        let parameters = GeneratedHaloSpec.state(state)
        guard parameters.poweredMaximum > 0 else {
            return 0
        }
        return livingBreath(
            time: time,
            period: parameters.breathPeriod,
            maximum: parameters.poweredMaximum,
            minimum: parameters.poweredMinimum,
            brightShare: parameters.brightShare
        )
    }

    public static func attentionPulse(_ time: Double) -> Double {
        let cycle = positiveModulo(time, GeneratedHaloSpec.attentionPeriod)
            / GeneratedHaloSpec.attentionPeriod
        let first = smoothPulse(
            phase: cycle,
            center: GeneratedHaloSpec.attentionFirstCenter,
            width: GeneratedHaloSpec.attentionFirstWidth
        ) * GeneratedHaloSpec.attentionFirstStrength
        let second = smoothPulse(
            phase: cycle,
            center: GeneratedHaloSpec.attentionSecondCenter,
            width: GeneratedHaloSpec.attentionSecondWidth
        ) * GeneratedHaloSpec.attentionSecondStrength
        let livingBase = GeneratedHaloSpec.attentionLivingBase
            + GeneratedHaloSpec.attentionLivingAmplitude
            * softWave(cycle + GeneratedHaloSpec.attentionLivingPhase)
        return clamp(livingBase + first + second, 0, 1)
    }

    public static func smoothPulse(phase: Double, center: Double, width: Double) -> Double {
        var distance = abs(phase - center)
        distance = min(distance, 1 - distance)
        return smootherStep(clamp(1 - distance / width, 0, 1))
    }

    public static func errorPulse(_ time: Double, presentation: ErrorPresentation) -> Double {
        if presentation == .bright { return GeneratedHaloSpec.errorBrightPower }
        if presentation == .dim { return GeneratedHaloSpec.errorDimPower }
        let cycle = positiveModulo(time, GeneratedHaloSpec.errorFlashPeriod)
        let first = exp(-pow(
            (cycle - GeneratedHaloSpec.errorFirstCenter)
                / GeneratedHaloSpec.errorFirstWidth, 2
        ))
        let second = exp(-pow(
            (cycle - GeneratedHaloSpec.errorSecondCenter)
                / GeneratedHaloSpec.errorSecondWidth, 2
        ))
        return clamp(first + second, 0, 1)
    }

    public static func transitionLight(from: Double, to: Double, progress rawProgress: Double) -> Double {
        let progress = smootherStep(clamp(rawProgress, 0, 1))
        let low = GeneratedHaloSpec.transitionLowPowered
        if progress < GeneratedHaloSpec.transitionDimEnd {
            return lerp(
                from,
                min(from, low),
                smootherStep(progress / GeneratedHaloSpec.transitionDimEnd)
            )
        }
        if progress < GeneratedHaloSpec.transitionColorBlendEnd {
            return min(from, low)
        }
        return lerp(
            min(from, low),
            to,
            smootherStep(
                (progress - GeneratedHaloSpec.transitionColorBlendEnd)
                    / (1 - GeneratedHaloSpec.transitionColorBlendEnd)
            )
        )
    }

    public static func diagnosticBrightDuration(_ state: HaloState) -> Double {
        let parameters = GeneratedHaloSpec.state(state)
        return parameters.poweredMaximum > 0
            ? parameters.breathPeriod * parameters.brightShare
            : 0
    }

    public static func diagnosticGapSeparation(_ phase: Double) -> Double {
        lerp(
            GeneratedHaloSpec.minimumGapSeparation,
            GeneratedHaloSpec.maximumGapSeparation,
            magneticRepulsionEase(phase)
        )
    }

    public static func repulsionDurationFromOrbit(_ orbitVelocity: Double) -> Double {
        let speed = clamp(
            abs(orbitVelocity),
            GeneratedHaloSpec.repulsionSpeedMinimum,
            GeneratedHaloSpec.repulsionSpeedMaximum
        )
        return clamp(
            GeneratedHaloSpec.repulsionDurationFactor
                * sqrt(GeneratedHaloSpec.repulsionReferenceSpeed / speed),
            GeneratedHaloSpec.repulsionDurationMinimum,
            GeneratedHaloSpec.repulsionDurationMaximum
        )
    }

    public static func targetGapVelocity(_ state: HaloState) -> Double {
        GeneratedHaloSpec.state(state).orbitVelocity
    }

    public static func gapVelocityEnvelope(_ state: HaloState, time: Double) -> Double {
        let period = GeneratedHaloSpec.state(state).envelopePeriod
        let primary = softWave(time / period)
        let secondary = softWave(time / (period * 0.47) + 0.29)
        return 0.18 + 0.92 * pow(primary, 1.65) + 0.22 * secondary
    }

    public static func smallGapDriftOffset(state: HaloState, time: Double, cycle: Int) -> Double {
        let parameters = GeneratedHaloSpec.state(state)
        let amplitude = parameters.driftAmplitude
        let period = parameters.driftPeriod
        let direction = cycle.isMultiple(of: 2) ? 1.0 : -1.0
        let primary = sin(time * .pi * 2 / period)
        let secondary = 0.22 * (sin(time * .pi * 2 / (period * 0.43) + 0.8) - sin(0.8))
        return direction * amplitude * (primary + secondary)
    }

    public static func smallGapInertiaDamping(_ state: HaloState) -> Double {
        GeneratedHaloSpec.state(state).inertiaDamping
    }

    public static func repulsionExitVelocityFromOrbit(_ orbitVelocity: Double) -> Double {
        clamp(
            abs(orbitVelocity) * GeneratedHaloSpec.exitVelocityScale,
            GeneratedHaloSpec.exitVelocityMinimum,
            GeneratedHaloSpec.exitVelocityMaximum
        )
    }

    public static func magneticRepulsionEase(_ value: Double) -> Double {
        let value = clamp(value, 0, 1)
        return clamp(smootherStep(value) + sin(value * .pi) * 0.055, 0, 1)
    }

    public static func ringMorph(state: HaloState, time: Double) -> HaloRingMorph {
        ringMorph(
            state: state,
            time: time,
            breath: stateBreath(state, time: time),
            powered: targetPowered(state, time: time)
        )
    }

    public static func ringMorph(
        state: HaloState,
        time: Double,
        breath: Double,
        powered: Double
    ) -> HaloRingMorph {
        let pace: Double
        let shapeAmount: Double
        switch state {
        case .working:
            pace = 3.2
            shapeAmount = 1.0
        case .thinking:
            pace = 4.8
            shapeAmount = 0.86
        case .done:
            pace = 6.7
            shapeAmount = 0.62
        case .attention:
            pace = 3.9
            shapeAmount = 0.92
        case .error:
            pace = 2.4
            shapeAmount = 0.95
        case .idle:
            pace = 7.2
            shapeAmount = 0.42
        }

        let cycle = positiveModulo(time, pace) / pace
        let swell = 0.5 - 0.5 * cos(cycle * .pi * 2)
        let folded = softWave(cycle + 0.08)
        let split = smoothPulse(phase: cycle, center: 0.33, width: 0.24)
        let secondSplit = smoothPulse(phase: cycle, center: 0.78, width: 0.18) * 0.55
        let powerBias = 0.34 + 0.66 * clamp(powered, 0, 1)
        let living = clamp(0.45 * swell + 0.35 * folded + 0.20 * clamp(breath, 0, 1), 0, 1)
        let secondary = clamp((split + secondSplit) * shapeAmount * (0.46 + 0.54 * powerBias), 0, 1)

        return HaloRingMorph(
            radiusOffset: shapeAmount * (-0.85 + 1.7 * living),
            bodyWidthOffset: shapeAmount * (-1.05 + 2.1 * swell) * (0.72 + 0.28 * powerBias),
            secondaryOpacity: secondary,
            gapOpen: clamp(0.18 + 0.72 * folded + 0.24 * secondary, 0, 1),
            gapSkew: shapeAmount * (4.6 * sin(cycle * .pi * 2) + 1.8 * sin(cycle * .pi * 4 + 0.7)),
            glowBoost: 0.08 * shapeAmount * secondary + 0.045 * shapeAmount * swell
        )
    }

    public static func ringHighlightStrokes(radius: Double, bodyWidth: Double, scale: Double) -> [HaloRingStroke] {
        let bodyWidth = max(bodyWidth, scale)
        let innerWidth = max(scale * 0.95, min(scale * 1.75, bodyWidth * 0.18))
        let outerWidth = max(scale * 0.80, min(scale * 1.35, bodyWidth * 0.14))
        return [
            HaloRingStroke(
                radius: radius - bodyWidth * 0.34,
                width: innerWidth,
                alphaScale: 0.52
            ),
            HaloRingStroke(
                radius: radius + bodyWidth * 0.31,
                width: outerWidth,
                alphaScale: 0.30
            )
        ]
    }

    public static func mixColor(_ from: HaloRGB, _ to: HaloRGB, amount: Double) -> HaloRGB {
        let amount = clamp(amount, 0, 1)
        return HaloRGB(
            red: linearToSrgb(lerp(srgbToLinear(from.red / 255), srgbToLinear(to.red / 255), amount)) * 255,
            green: linearToSrgb(lerp(srgbToLinear(from.green / 255), srgbToLinear(to.green / 255), amount)) * 255,
            blue: linearToSrgb(lerp(srgbToLinear(from.blue / 255), srgbToLinear(to.blue / 255), amount)) * 255
        )
    }

    public static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    public static func linearToSrgb(_ value: Double) -> Double {
        let value = clamp(value, 0, 1)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
