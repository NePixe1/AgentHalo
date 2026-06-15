import AppKit

if CommandLine.arguments.contains("--self-check") {
    Task { @MainActor in
        runHaloInteractionChecks()
        print("PASS AgentHaloMac checks")
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
