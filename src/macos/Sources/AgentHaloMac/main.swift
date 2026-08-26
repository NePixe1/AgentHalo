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
    guard let resourcesDirectory = Bundle.main.resourceURL else {
        fatalError("Packaged app has no Resources directory")
    }
    let expectedResourceBundle = resourcesDirectory
        .appendingPathComponent(AgentHaloResources.bundleName, isDirectory: true)
        .standardizedFileURL
    let resolvedResourceBundle = AgentHaloResources.bundle.bundleURL.standardizedFileURL
    guard resolvedResourceBundle == expectedResourceBundle else {
        fatalError(
            "Packaged resources resolved outside the app bundle: \(resolvedResourceBundle.path)"
        )
    }
    let requiredResources = [
        ("en", "json", "locales"),
        ("zh", "json", "locales"),
        ("agent-halo-status", "ts", "integrations/pi"),
    ]
    guard requiredResources.allSatisfy({ name, extensionName, subdirectory in
        AgentHaloResources.bundle.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: subdirectory
        ) != nil
    }) else {
        fatalError("Packaged app is missing required Agent Halo resources")
    }
    FileHandle.standardError.write(Data("PACKAGED_VERIFICATION_KEYCHAIN_DISABLED\n".utf8))
    FileHandle.standardError.write(Data("PACKAGED_VERIFICATION_RESOURCES_OK\n".utf8))
}
let delegate = AppDelegate(
    settingsStore: SettingsStore(),
    usageCoordinator: usageCoordinator
)
app.delegate = delegate
app.run()
