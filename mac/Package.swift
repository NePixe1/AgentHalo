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
        .executable(name: "AgentHaloDiagnostics", targets: ["AgentHaloDiagnostics"])
    ],
    targets: [
        .target(name: "AgentHaloCore"),
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
        )
    ]
)
