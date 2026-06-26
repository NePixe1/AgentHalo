// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentHaloMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentHaloCore", targets: ["AgentHaloCore"]),
        .executable(name: "AgentHaloMac", targets: ["AgentHaloMac"]),
        .executable(name: "AgentHaloCoreChecks", targets: ["AgentHaloCoreChecks"]),
        .executable(name: "AgentHaloDiagnostics", targets: ["AgentHaloDiagnostics"]),
        .executable(name: "ClaudeCodeStatusHook", targets: ["ClaudeCodeStatusHook"]),
        .executable(name: "ClaudeCodeStatusLineProxy", targets: ["ClaudeCodeStatusLineProxy"]),
    ],
    targets: [
        .target(
            name: "AgentHaloCore",
            dependencies: [],
            resources: [
                .copy("locales")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AgentHaloMac",
            dependencies: ["AgentHaloCore"]
        ),
        .executableTarget(
            name: "AgentHaloCoreChecks",
            dependencies: ["AgentHaloCore"]
        ),
        .executableTarget(
            name: "AgentHaloDiagnostics",
            dependencies: ["AgentHaloCore"]
        ),
        .executableTarget(
            name: "ClaudeCodeStatusHook",
            dependencies: []
        ),
        .executableTarget(
            name: "ClaudeCodeStatusLineProxy",
            dependencies: ["AgentHaloCore"]
        ),
    ]
)
