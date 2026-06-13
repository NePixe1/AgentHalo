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
        let failed = lines.contains { $0.hasPrefix("FAIL") }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        if failed { exit(1) }
    }

    static func writeSnapshot(to path: String) throws {
        let monitor = CodexSessionMonitor()
        _ = monitor.refresh()
        let aggregate = SessionAggregator.aggregate(snapshots: monitor.snapshots(), settings: SettingsStore().load())
        let report = "\(aggregate.label)\n\(aggregate.detail)\nSessions: \(aggregate.sessions.count)\n"
        try Data(report.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func renderStates(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for state in HaloState.allCases {
            try renderSmokePNG(name: state.rawValue, directory: directory)
        }
    }

    static func renderTransitionStrips(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for name in ["transition-thinking-working", "transition-working-done", "transition-done-standby", "transition-standby-thinking"] {
            try renderSmokePNG(name: name, directory: directory)
        }
    }

    static func writeBenchmark(to path: String) throws {
        let started = Date()
        for index in 0..<10_000 {
            _ = HaloVisualModel.targetVisual(state: .working, time: Double(index) / 60, errorPresentation: .flashing, steadyDone: false)
        }
        let elapsed = Date().timeIntervalSince(started)
        try Data("PASS\nelapsed=\(elapsed)\n".utf8).write(to: URL(fileURLWithPath: path))
    }

    static func renderSmokePNG(name: String, directory: String) throws {
        let image = NSImage(size: NSSize(width: 160, height: 160))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 160).fill()
        NSColor.white.setStroke()
        NSBezierPath(ovalIn: NSRect(x: 42, y: 42, width: 76, height: 76)).stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AgentHaloDiagnostics", code: 1)
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
