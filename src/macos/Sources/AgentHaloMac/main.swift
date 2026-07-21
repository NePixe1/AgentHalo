import AppKit
import AgentHaloCore

let packagedVerificationArgument = "--packaged-verification"

if CommandLine.arguments.contains("--self-check") {
    Task { @MainActor in
        runHaloInteractionChecks()
        print("PASS AgentHaloMac checks")
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let runtimeMode: UsageMonitoringRuntimeMode = CommandLine.arguments.contains(packagedVerificationArgument)
    ? .packagedVerification
    : .production
let usageCoordinator = UsageMonitoringCoordinator.live(mode: runtimeMode)
if runtimeMode == .packagedVerification {
    FileHandle.standardError.write(Data("PACKAGED_VERIFICATION_KEYCHAIN_DISABLED\n".utf8))
}
let delegate = AppDelegate(usageCoordinator: usageCoordinator)
app.delegate = delegate
app.run()
