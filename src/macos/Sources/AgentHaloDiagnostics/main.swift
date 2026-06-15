import Foundation
import AppKit
import AgentHaloCore

let args = Array(CommandLine.arguments.dropFirst())

func requireOutput(_ command: String) -> String {
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("usage: AgentHaloDiagnostics \(command) <output>\n".utf8))
        exit(2)
    }
    return args[1]
}

switch args.first {
case "--self-test":
    let output = requireOutput("--self-test")
    try Diagnostics.writeSelfTest(to: output)
case "--snapshot":
    let output = requireOutput("--snapshot")
    try Diagnostics.writeSnapshot(to: output)
case "--render-states":
    let output = requireOutput("--render-states")
    try Diagnostics.renderStates(to: output)
case "--transition-strip":
    let output = requireOutput("--transition-strip")
    try Diagnostics.renderTransitionStrips(to: output)
case "--benchmark":
    let output = requireOutput("--benchmark")
    try Diagnostics.writeBenchmark(to: output)
default:
    print("usage: AgentHaloDiagnostics --self-test|--snapshot|--render-states|--transition-strip|--benchmark <output>")
    exit(2)
}

enum Diagnostics {
    static func writeSelfTest(to path: String) throws {
        var lines: [String] = []
        lines.append(HaloMath.transitionLight(from: 0.9, to: 0.0, progress: 0.99) < 0.01 ? "PASS transition-light" : "FAIL transition-light")
        lines.append(HaloMath.diagnosticBrightDuration(.thinking) < HaloMath.diagnosticBrightDuration(.working) ? "PASS bright-duration" : "FAIL bright-duration")
        lines.append(abs(HaloMath.diagnosticGapSeparation(0) - 40) < 0.001 ? "PASS gap-start" : "FAIL gap-start")
        lines.append(abs(HaloMath.diagnosticGapSeparation(1) - 150) < 0.001 ? "PASS gap-end" : "FAIL gap-end")
        lines.append(HaloVisualModel.completionDoubleFlash(sinceState: 0.28) > 0.95 ? "PASS completion-double-flash" : "FAIL completion-double-flash")
        let working = HaloVisualModel.targetVisual(state: .working, time: 0.8, errorPresentation: .flashing, steadyDone: false)
        let material = HaloVisualModel.materialSnapshot(color: working.color, visual: working, intensity: 1.0)
        lines.append(material.poweredCore.red > working.color.red ? "PASS powered-white-core" : "FAIL powered-white-core")
        lines.append(material.whiteSparkAlpha > 180 ? "PASS white-center-spark" : "FAIL white-center-spark")
        let failed = lines.contains { $0.hasPrefix("FAIL") }
        try DiagnosticsOutput.write(lines.joined(separator: "\n") + "\n", to: path)
        if failed { exit(1) }
    }

    static func writeSnapshot(to path: String) throws {
        let monitor = CodexSessionMonitor()
        _ = monitor.refresh()
        let aggregate = SessionAggregator.aggregate(snapshots: monitor.snapshots(), settings: SettingsStore().load())
        let report = "\(aggregate.label)\n\(aggregate.detail)\nSessions: \(aggregate.sessions.count)\n"
        try DiagnosticsOutput.write(report, to: path)
    }

    static func renderStates(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for state in HaloState.allCases {
            try renderStatePNG(state: state, directory: directory)
        }
    }

    static func renderTransitionStrips(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try renderTransitionPNG(name: "transition-thinking-working", directory: directory, state: .working, time: 1.2)
        try renderTransitionPNG(name: "transition-working-done", directory: directory, state: .done, time: 1.2)
        try renderTransitionPNG(name: "transition-done-standby", directory: directory, state: .done, time: 4.0)
        try renderTransitionPNG(name: "transition-standby-thinking", directory: directory, state: .thinking, time: 1.2)
    }

    static func writeBenchmark(to path: String) throws {
        let started = Date()
        for index in 0..<10_000 {
            _ = HaloVisualModel.targetVisual(state: .working, time: Double(index) / 60, errorPresentation: .flashing, steadyDone: false)
        }
        let elapsed = Date().timeIntervalSince(started)
        try DiagnosticsOutput.write("PASS\nelapsed=\(elapsed)\n", to: path)
    }

    static func renderStatePNG(state: HaloState, directory: String) throws {
        let data = try DiagnosticHaloRenderer.renderPNG(input: DiagnosticHaloRenderInput(
            state: state,
            errorPresentation: state == .error ? .bright : .flashing,
            steadyDone: false,
            transitionFrom: HaloVisualModel.targetVisual(
                state: state,
                time: 0,
                errorPresentation: state == .error ? .bright : .flashing,
                steadyDone: false
            ),
            time: 2.4,
            sinceState: state == .done ? 0.55 : 2.4,
            transition: 1,
            gapA: 97,
            gapB: 247
        ))
        try DiagnosticsOutput.write(data, to: URL(fileURLWithPath: directory).appendingPathComponent("\(state.rawValue).png").path(percentEncoded: false))
    }

    static func renderTransitionPNG(name: String, directory: String, state: HaloState, time: Double) throws {
        let data = try DiagnosticHaloRenderer.renderPNG(input: DiagnosticHaloRenderInput(
            state: state,
            errorPresentation: .flashing,
            steadyDone: name.contains("standby"),
            transitionFrom: HaloVisualModel.targetVisual(
                state: .done,
                time: 0,
                errorPresentation: .flashing,
                steadyDone: false
            ),
            time: time,
            sinceState: time,
            transition: HaloMath.smootherStep(min(1, time / 1.45)),
            gapA: 97 + time * 38,
            gapB: 247 + time * 38
        ))
        try DiagnosticsOutput.write(data, to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png").path(percentEncoded: false))
    }
}
