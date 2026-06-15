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
}
