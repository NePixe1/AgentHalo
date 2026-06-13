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

    public static func magneticRepulsionEase(_ value: Double) -> Double {
        let value = clamp(value, 0, 1)
        return clamp(smootherStep(value) + sin(value * .pi) * 0.055, 0, 1)
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
