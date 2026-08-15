import Foundation
import AgentHaloCore

func runAntigravityUsageChecks() async {
    try! testAntigravityMapperKeepsOnlyGeminiWindows()
    testAntigravityMapperLegacyGeminiIsSessionOnly()
    testAntigravityMapperDropsMissingFraction()
    testAntigravityMapperIgnoresUnknownAnd3PBuckets()
    testAntigravityMapperRejectsNonSummary()
    testAntigravityMapperHTTPErrors()
    testAntigravityFormatPlan()
}

func testAntigravityMapperKeepsOnlyGeminiWindows() throws {
    let json = """
    {"groups":[
      {"buckets":[
        {"bucketId":"3p-weekly","remainingFraction":1,"resetTime":"2026-07-06T07:00:00Z"},
        {"bucketId":"3p-5h","remainingFraction":0.4,"resetTime":"2026-07-02T15:30:00Z"},
        {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-07-02T16:00:00Z"},
        {"bucketId":"gemini-weekly","remainingFraction":0.9,"resetTime":"2026-07-06T07:00:00Z"}
      ]}
    ]}
    """
    let key = AccountCacheKey(providerID: .antigravity, digest: "d")
    let snap = try AntigravityUsageMapper.mapQuotaSummary(
        response: UsageHTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8)),
        accountKey: key,
        planName: "Pro",
        now: Date(timeIntervalSince1970: 1)
    )
    expect(snap.windows.count, 2, "only gemini windows")
    expect(snap.windows[0].kind, .session, "gemini-5h → session, always first")
    expect(snap.windows[0].usedPercent, 25, "1-0.75")
    expect(snap.windows[0].duration, 18_000, "5h duration")
    expect(snap.windows[1].kind, .weekly, "gemini-weekly → weekly")
    expect(snap.windows[1].usedPercent, 10, "1-0.9")
    expect(snap.windows[1].duration, 604_800, "weekly duration")
    expect(snap.planName, "Pro", "plan passthrough")

    let wrapped = AntigravityUsageMapper.windowsFromQuotaSummaryBody(
        Data("{\"response\":\(json)}".utf8)
    )
    expect(wrapped?.count, 2, "wrapped response.groups is a summary")
}

func testAntigravityMapperLegacyGeminiIsSessionOnly() {
    let window = AntigravityUsageMapper.sessionWindowFromLegacyGeminiConfigs(
        remainingFractions: [0.8, 0.5],
        resetTime: Date(timeIntervalSince1970: 9)
    )
    expect(window?.kind, .session, "legacy is 5h only")
    expect(window?.usedPercent, 50, "worst remaining fraction")
    expect(
        AntigravityUsageMapper.sessionWindowFromLegacyGeminiConfigs(
            remainingFractions: [],
            resetTime: nil
        ) == nil,
        true,
        "no gemini configs → no window"
    )
}

func testAntigravityMapperDropsMissingFraction() {
    let json = """
    {"groups":[{"buckets":[
      {"bucketId":"gemini-5h","resetTime":"2026-07-02T16:00:00Z"},
      {"bucketId":"gemini-weekly","remainingFraction":0.5,"resetTime":"2026-07-06T07:00:00Z"}
    ]}]}
    """
    let windows = AntigravityUsageMapper.windowsFromQuotaSummaryBody(Data(json.utf8))
    expect(windows?.count, 1, "drop bucket without fraction")
    expect(windows?.first?.kind, .weekly, "weekly survives")
    expect(windows?.first?.usedPercent, 50, "used percent")
}

func testAntigravityMapperIgnoresUnknownAnd3PBuckets() {
    let json = #"{"groups":[{"buckets":[{"bucketId":"gemini-image-5h","remainingFraction":0.1}]}]}"#
    let windows = AntigravityUsageMapper.windowsFromQuotaSummaryBody(Data(json.utf8))
    expect(windows?.isEmpty, true, "unknown bucket dropped")
}

func testAntigravityMapperRejectsNonSummary() {
    expect(
        AntigravityUsageMapper.windowsFromQuotaSummaryBody(Data(#"{"foo":1}"#.utf8)) == nil,
        true,
        "no groups → not a summary"
    )
}

func testAntigravityMapperHTTPErrors() {
    let key = AccountCacheKey(providerID: .antigravity, digest: "d")
    let cases: [(Int, UsageProviderFailure)] = [
        (401, .signInAgain),
        (503, .serviceUnavailable),
        (418, .invalidResponse),
    ]
    for (code, expected) in cases {
        do {
            _ = try AntigravityUsageMapper.mapQuotaSummary(
                response: UsageHTTPResponse(statusCode: code, headers: [:], body: Data()),
                accountKey: key,
                planName: nil,
                now: Date()
            )
            fatalError("expected throw for \(code)")
        } catch let error as UsageProviderFailure {
            expect(error, expected, "status \(code)")
        } catch {
            fatalError("wrong error type \(error)")
        }
    }
}

func testAntigravityFormatPlan() {
    expect(AntigravityUsageMapper.formatPlan("Google AI Pro"), "Pro", "strip Google AI prefix")
    expect(AntigravityUsageMapper.formatPlan("Gemini Code Assist in Google One AI Ultra"), "Ultra", "keyword")
    expect(AntigravityUsageMapper.formatPlan("   "), nil, "blank")
}
