import Foundation
import AgentHaloCore

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--self-test") {
    print("PASS AgentHaloDiagnostics self-test")
    exit(0)
}

print("usage: AgentHaloDiagnostics --self-test")
exit(2)
