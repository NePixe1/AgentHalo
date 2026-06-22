import AgentHaloCore
import Darwin
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
let home = FileManager.default.homeDirectoryForCurrentUser
let agentHaloDirectory = home.appendingPathComponent(".agent-halo", isDirectory: true)
let snapshotURL = agentHaloDirectory.appendingPathComponent("claude-code-context.json")
let originalCommandURL = agentHaloDirectory.appendingPathComponent("claude-code-statusline-original-command")

_ = try? ClaudeStatusLineProxyRuntime.capture(input: input, snapshotURL: snapshotURL)

guard let commandData = try? Data(contentsOf: originalCommandURL),
      let command = String(data: commandData, encoding: .utf8),
      !command.isEmpty,
      !command.contains("claude-code-statusline-proxy") else {
    exit(0)
}

do {
    let result = try ClaudeStatusLineProxyRuntime.runOriginalCommand(command: command, input: input)
    try FileHandle.standardOutput.write(contentsOf: result.standardOutput)
    exit(result.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("AgentHalo statusline proxy: \(error)\n".utf8))
    exit(0)
}
