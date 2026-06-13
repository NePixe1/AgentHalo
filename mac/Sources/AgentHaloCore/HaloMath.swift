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
        switch state {
        case .thinking: livingBreath(time: time, period: 5.5, maximum: 1.0, minimum: 0.26, brightShare: 0.70)
        case .working: livingBreath(time: time, period: 7.2, maximum: 1.0, minimum: 0.22, brightShare: 0.78)
        case .done: livingBreath(time: time, period: 9.2, maximum: 0.92, minimum: 0.22, brightShare: 0.76)
        case .attention: 0.18 + 0.82 * attentionPulse(time)
        case .error: errorPulse(time, presentation: .flashing)
        case .idle: 0.18 + 0.22 * softWave(time / 6.8)
        }
    }

    public static func targetPowered(_ state: HaloState, time: Double) -> Double {
        switch state {
        case .thinking: livingBreath(time: time, period: 5.5, maximum: 1.0, minimum: 0.18, brightShare: 0.70)
        case .working: livingBreath(time: time, period: 7.2, maximum: 1.0, minimum: 0.16, brightShare: 0.78)
        case .done: livingBreath(time: time, period: 9.2, maximum: 0.84, minimum: 0.09, brightShare: 0.76)
        default: 0
        }
    }

    public static func attentionPulse(_ time: Double) -> Double {
        let cycle = positiveModulo(time, 5.8) / 5.8
        let first = smoothPulse(phase: cycle, center: 0.16, width: 0.095)
        let second = smoothPulse(phase: cycle, center: 0.38, width: 0.11) * 0.82
        let livingBase = 0.08 + 0.05 * softWave(cycle + 0.18)
        return clamp(livingBase + first + second, 0, 1)
    }

    public static func smoothPulse(phase: Double, center: Double, width: Double) -> Double {
        var distance = abs(phase - center)
        distance = min(distance, 1 - distance)
        return smootherStep(clamp(1 - distance / width, 0, 1))
    }

    public static func errorPulse(_ time: Double, presentation: ErrorPresentation) -> Double {
        if presentation == .bright { return 0.92 }
        if presentation == .dim { return 0.04 }
        let cycle = positiveModulo(time, 1.55)
        let first = exp(-pow((cycle - 0.12) / 0.055, 2))
        let second = exp(-pow((cycle - 0.34) / 0.065, 2))
        return clamp(first + second, 0, 1)
    }

    public static func transitionLight(from: Double, to: Double, progress rawProgress: Double) -> Double {
        let progress = smootherStep(clamp(rawProgress, 0, 1))
        let low = 0.08
        if progress < 0.36 {
            return lerp(from, min(from, low), smootherStep(progress / 0.36))
        }
        if progress < 0.58 {
            return min(from, low)
        }
        return lerp(min(from, low), to, smootherStep((progress - 0.58) / 0.42))
    }

    public static func diagnosticBrightDuration(_ state: HaloState) -> Double {
        switch state {
        case .thinking: 5.5 * 0.70
        case .working: 7.2 * 0.78
        case .done: 9.2 * 0.76
        default: 0
        }
    }

    public static func diagnosticGapSeparation(_ phase: Double) -> Double {
        lerp(40, 150, magneticRepulsionEase(phase))
    }

    public static func repulsionDurationFromOrbit(_ orbitVelocity: Double) -> Double {
        let speed = clamp(abs(orbitVelocity), 14, 92)
        return clamp(1.42 * sqrt(72 / speed), 1.28, 3.05)
    }

    public static func targetGapVelocity(_ state: HaloState) -> Double {
        switch state {
        case .thinking: 78
        case .working: 106
        case .attention: 46
        case .error: 60
        case .done: 38
        case .idle: 27
        }
    }

    public static func gapVelocityEnvelope(_ state: HaloState, time: Double) -> Double {
        let period: Double
        switch state {
        case .working: period = 2.2
        case .thinking: period = 4.2
        case .attention: period = 4.1
        case .error: period = 1.75
        case .done: period = 8.5
        case .idle: period = 7.6
        }
        let primary = softWave(time / period)
        let secondary = softWave(time / (period * 0.47) + 0.29)
        return 0.18 + 0.92 * pow(primary, 1.65) + 0.22 * secondary
    }

    public static func smallGapDriftOffset(state: HaloState, time: Double, cycle: Int) -> Double {
        let amplitude: Double
        let period: Double
        switch state {
        case .working:
            amplitude = 8.5
            period = 2.8
        case .thinking:
            amplitude = 7.0
            period = 3.6
        case .error:
            amplitude = 7.5
            period = 2.6
        case .attention:
            amplitude = 6.5
            period = 3.3
        case .done:
            amplitude = 4.2
            period = 5.5
        case .idle:
            amplitude = 5.2
            period = 4.8
        }
        let direction = cycle.isMultiple(of: 2) ? 1.0 : -1.0
        let primary = sin(time * .pi * 2 / period)
        let secondary = 0.22 * (sin(time * .pi * 2 / (period * 0.43) + 0.8) - sin(0.8))
        return direction * amplitude * (primary + secondary)
    }

    public static func smallGapInertiaDamping(_ state: HaloState) -> Double {
        switch state {
        case .working: 0.72
        case .thinking: 0.66
        case .error: 0.84
        case .attention: 0.76
        case .done: 0.58
        case .idle: 0.62
        }
    }

    public static func repulsionExitVelocityFromOrbit(_ orbitVelocity: Double) -> Double {
        clamp(abs(orbitVelocity) * 0.42, 9, 38)
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
