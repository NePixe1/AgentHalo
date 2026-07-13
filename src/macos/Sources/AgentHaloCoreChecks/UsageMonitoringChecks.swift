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
}
