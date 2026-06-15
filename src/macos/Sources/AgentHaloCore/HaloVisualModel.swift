import Foundation

public struct HaloVisualSnapshot: Equatable, Sendable {
    public var color: HaloRGB
    public var powered: Double
    public var breath: Double
    public var intensity: Double
    public var bodyWidth: Double
    public var coreWhite: Double
    public var glowGain: Double
}

public struct HaloMaterialSnapshot: Equatable, Sendable {
    public var emissionColor: HaloRGB
    public var glowColor: HaloRGB
    public var darkMaterial: HaloRGB
    public var poweredMaterial: HaloRGB
    public var poweredCore: HaloRGB
    public var glowAlphas: [Double]
    public var darkAlpha: Double
    public var materialAlpha: Double
    public var coreAlpha: Double
    public var whiteSparkAlpha: Double
}

public enum HaloVisualModel {
    public static func targetVisual(state: HaloState, time: Double, errorPresentation: ErrorPresentation, steadyDone: Bool) -> HaloVisualSnapshot {
        var result = HaloVisualSnapshot(
            color: stateColor(state),
            powered: HaloMath.targetPowered(state, time: time),
            breath: HaloMath.stateBreath(state, time: time),
            intensity: 0.50 + HaloMath.stateBreath(state, time: time) * 0.18,
            bodyWidth: 8.6,
            coreWhite: coreWhite(for: state),
            glowGain: glowGain(for: state)
        )
        if state == .done && steadyDone {
            result.powered = 0
            result.breath = 0.34
            result.intensity = 0.56
        } else if state == .attention {
            let pulse = HaloMath.attentionPulse(time)
            result.powered = 0.10 + 0.90 * pulse
            result.breath = 0.28 + 0.72 * pulse
            result.intensity = 0.56 + 0.18 * pulse
            result.bodyWidth = 8.6 + 0.30 * pulse
        } else if state == .error {
            let pulse = HaloMath.errorPulse(time, presentation: errorPresentation)
            result.powered = errorPresentation == .bright ? 1.0 : errorPresentation == .dim ? 0 : pulse
            result.breath = errorPresentation == .dim ? 0.10 : pulse
            result.intensity = errorPresentation == .dim ? 0.52 : 0.62 + 0.12 * pulse
            result.bodyWidth = 8.6 + 0.25 * pulse
        }
        return result
    }

    public static func transitionVisual(from: HaloVisualSnapshot, to: HaloVisualSnapshot, progress rawProgress: Double) -> HaloVisualSnapshot {
        let progress = HaloMath.clamp(rawProgress, 0, 1)
        let scalarProgress = HaloMath.smootherStep(HaloMath.clamp((progress - 0.34) / 0.66, 0, 1))
        return HaloVisualSnapshot(
            color: to.color,
            powered: HaloMath.transitionLight(from: from.powered, to: to.powered, progress: progress),
            breath: HaloMath.lerp(from.breath, to.breath, scalarProgress),
            intensity: HaloMath.lerp(from.intensity, to.intensity, scalarProgress),
            bodyWidth: HaloMath.lerp(from.bodyWidth, to.bodyWidth, scalarProgress),
            coreWhite: HaloMath.lerp(from.coreWhite, to.coreWhite, scalarProgress),
            glowGain: HaloMath.lerp(from.glowGain, to.glowGain, scalarProgress)
        )
    }

    public static func animatedColor(from: HaloRGB, to: HaloRGB, progress rawProgress: Double) -> HaloRGB {
        let colorProgress = HaloMath.smootherStep(HaloMath.clamp((rawProgress - 0.18) / 0.56, 0, 1))
        return HaloMath.mixColor(from, to, amount: colorProgress)
    }

    public static func completionDoubleFlash(sinceState: Double) -> Double {
        let first = exp(-pow((sinceState - 0.28) / 0.14, 2))
        let second = exp(-pow((sinceState - 0.92) / 0.18, 2))
        return HaloMath.clamp(first + second * 0.90, 0, 1)
    }

    public static func materialSnapshot(color: HaloRGB, visual: HaloVisualSnapshot, intensity rawIntensity: Double) -> HaloMaterialSnapshot {
        let intensity = HaloMath.clamp(rawIntensity, 0, 1.32)
        let powered = HaloMath.clamp(visual.powered, 0, 1)
        let dimColor = adjustSaturation(color, amount: 0.88)
        let emissionColor = adjustSaturation(color, amount: 0.92 + 0.36 * powered)
        let glowColor = HaloMath.mixColor(
            emissionColor,
            HaloRGB(red: 242, green: 248, blue: 249),
            amount: 0.18 + 0.08 * powered
        )
        let darkMaterial = HaloMath.mixColor(
            dimColor,
            HaloRGB(red: 18, green: 24, blue: 26),
            amount: 0.46
        )
        let litMaterial = HaloMath.mixColor(
            emissionColor,
            HaloRGB(red: 250, green: 253, blue: 252),
            amount: 0.56
        )
        let poweredMaterial = HaloMath.mixColor(
            darkMaterial,
            litMaterial,
            amount: 0.24 + 0.76 * powered
        )
        let poweredCore = HaloMath.mixColor(
            emissionColor,
            HaloRGB(red: 253, green: 255, blue: 255),
            amount: visual.coreWhite
        )
        let glowGain = visual.glowGain
        return HaloMaterialSnapshot(
            emissionColor: emissionColor,
            glowColor: glowColor,
            darkMaterial: darkMaterial,
            poweredMaterial: poweredMaterial,
            poweredCore: poweredCore,
            glowAlphas: [
                (12 + 39 * powered) * intensity * glowGain,
                (22 + 52 * powered) * intensity * glowGain,
                (38 + 70 * powered) * intensity * glowGain,
                82 * powered * intensity * glowGain
            ],
            darkAlpha: 242 * intensity,
            materialAlpha: (182 + 73 * powered) * intensity,
            coreAlpha: (5 + 235 * powered) * intensity,
            whiteSparkAlpha: 205 * powered * intensity
        )
    }

    public static func stateColor(_ state: HaloState) -> HaloRGB {
        let parameters = GeneratedHaloSpec.state(state)
        return HaloRGB(
            red: parameters.red,
            green: parameters.green,
            blue: parameters.blue
        )
    }

    public static func coreWhite(for state: HaloState) -> Double {
        GeneratedHaloSpec.state(state).coreWhite
    }

    public static func glowGain(for state: HaloState) -> Double {
        GeneratedHaloSpec.state(state).glowGain
    }

    private static func adjustSaturation(_ color: HaloRGB, amount: Double) -> HaloRGB {
        let hsl = rgbToHsl(color)
        return hslToRgb(hue: hsl.hue, saturation: HaloMath.clamp(hsl.saturation * amount, 0, 1), lightness: hsl.lightness)
    }

    private static func rgbToHsl(_ color: HaloRGB) -> (hue: Double, saturation: Double, lightness: Double) {
        let red = color.red / 255
        let green = color.green / 255
        let blue = color.blue / 255
        let maximum = max(red, max(green, blue))
        let minimum = min(red, min(green, blue))
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        if delta <= 0.000_001 {
            return (0, 0, lightness)
        }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        let hue: Double
        if maximum == red {
            hue = 60 * HaloMath.positiveModulo((green - blue) / delta, 6)
        } else if maximum == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        return (hue, saturation, lightness)
    }

    private static func hslToRgb(hue: Double, saturation: Double, lightness: Double) -> HaloRGB {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let segment = hue / 60
        let x = chroma * (1 - abs(HaloMath.positiveModulo(segment, 2) - 1))
        let values: (Double, Double, Double)
        switch segment {
        case 0..<1:
            values = (chroma, x, 0)
        case 1..<2:
            values = (x, chroma, 0)
        case 2..<3:
            values = (0, chroma, x)
        case 3..<4:
            values = (0, x, chroma)
        case 4..<5:
            values = (x, 0, chroma)
        default:
            values = (chroma, 0, x)
        }
        let match = lightness - chroma / 2
        return HaloRGB(
            red: (values.0 + match) * 255,
            green: (values.1 + match) * 255,
            blue: (values.2 + match) * 255
        )
    }
}
