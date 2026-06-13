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

    public static func stateColor(_ state: HaloState) -> HaloRGB {
        switch state {
        case .thinking: HaloRGB(red: 226, green: 170, blue: 31)
        case .working: HaloRGB(red: 52, green: 158, blue: 199)
        case .done: HaloRGB(red: 38, green: 198, blue: 108)
        case .attention: HaloRGB(red: 213, green: 103, blue: 55)
        case .error: HaloRGB(red: 218, green: 50, blue: 86)
        case .idle: HaloRGB(red: 113, green: 132, blue: 140)
        }
    }

    public static func coreWhite(for state: HaloState) -> Double {
        switch state {
        case .thinking: 0.90
        case .working: 0.86
        case .error: 0.91
        case .done: 0.84
        default: 0.82
        }
    }

    public static func glowGain(for state: HaloState) -> Double {
        switch state {
        case .thinking: 1.13
        case .working: 1.07
        case .error: 1.12
        default: 1.00
        }
    }
}
