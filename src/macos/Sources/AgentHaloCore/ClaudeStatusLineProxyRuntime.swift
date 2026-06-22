import Foundation

public struct ClaudeStatusLineCommandResult: Equatable, Sendable {
    public var standardOutput: Data
    public var terminationStatus: Int32

    public init(standardOutput: Data, terminationStatus: Int32) {
        self.standardOutput = standardOutput
        self.terminationStatus = terminationStatus
    }
}

public enum ClaudeStatusLineProxyRuntime {
    @discardableResult
    public static func capture(
        input: Data,
        snapshotURL: URL,
        updatedAt: Date = Date()
    ) throws -> ClaudeContextUsageSnapshot? {
        guard let snapshot = ClaudeStatusLineUsageParser.parse(data: input, updatedAt: updatedAt) else {
            return nil
        }

        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: [.atomic])
        return snapshot
    }

    public static func runOriginalCommand(command: String, input: Data) throws -> ClaudeStatusLineCommandResult {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: input)
        try standardInput.fileHandleForWriting.close()
        let output = try standardOutput.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        return ClaudeStatusLineCommandResult(
            standardOutput: output,
            terminationStatus: process.terminationStatus
        )
    }
}
