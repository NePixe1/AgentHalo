import Foundation
import AgentHaloCore

func runUsageModelChecks() async {
    let key = AccountCacheKey(providerID: .codex, digest: "abc")
    let snapshot = UsageSnapshot(
        providerID: .codex,
        accountKey: key,
        planName: "Pro 20x",
        windows: [UsageWindow(kind: .session, usedPercent: 4, resetsAt: nil, duration: 18_000)],
        refreshedAt: Date(timeIntervalSince1970: 100)
    )
    expect(snapshot.windows.first?.kind, .session, "usage window kind")
    expect(UsageDigest.sha256("secret").count, 64, "SHA256 must use lowercase hex")

    let response = UsageHTTPResponse(
        statusCode: 429,
        headers: ["Retry-After": "120"],
        body: Data()
    )
    expect(response.header("retry-after"), "120", "headers must be case insensitive")

    do {
        try testFilesystemUsageFilesWritesEmptyAndNonEmptyDataWithMode0600()
    } catch {
        fatalError("filesystem usage files checks failed: \(error)")
    }
}

/// Exercises the real `FilesystemUsageFiles.writeAtomically` path: an empty
/// `Data` must not crash (force-unwrap regression) and must still create the
/// file, and a non-empty buffer must persist exact bytes with mode 0600.
func testFilesystemUsageFilesWritesEmptyAndNonEmptyDataWithMode0600() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-fs-files-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let files = FilesystemUsageFiles()

    // Empty Data must not crash and must create a zero-byte file.
    let emptyURL = root.appendingPathComponent("empty.json")
    try files.writeAtomically(Data(), to: emptyURL.path, preservingModeOf: nil)
    expect(FileManager.default.fileExists(atPath: emptyURL.path), "empty write should create the file")
    let emptyAttrs = try FileManager.default.attributesOfItem(atPath: emptyURL.path)
    expect(
        (emptyAttrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600,
        "empty write mode should be 0600"
    )
    expect((try Data(contentsOf: emptyURL)).count, 0, "empty write should produce zero bytes")

    // Non-empty Data must persist the exact bytes with the same mode.
    let payload = Data(#"{"hello":"world"}"#.utf8)
    let dataURL = root.appendingPathComponent("data.json")
    try files.writeAtomically(payload, to: dataURL.path, preservingModeOf: nil)
    expect(FileManager.default.fileExists(atPath: dataURL.path), "non-empty write should create the file")
    let dataAttrs = try FileManager.default.attributesOfItem(atPath: dataURL.path)
    expect(
        (dataAttrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600,
        "non-empty write mode should be 0600"
    )
    expect((try Data(contentsOf: dataURL)), payload, "non-empty write should preserve bytes")
}
