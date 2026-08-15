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
    testAntigravityResolveAccessNeverReturnsAPIKey()
    try! testAntigravityResolveAccessFromKeychainJSON()
    try! testAntigravityCachedAccessTokenMissesOnFingerprintMismatch()
    try! testAntigravityCachedAccessTokenMissesWhenExpiringWithinBuffer()
    testAntigravityExtractToken()
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

func testAntigravityResolveAccessNeverReturnsAPIKey() {
    let tmpHome = antigravityCheckHome()
    let emptyKeychain = FakeUsageKeychain()
    let store = AntigravityAuthStore(
        homeDirectory: tmpHome,
        keychain: emptyKeychain,
        files: FakeUsageFiles()
    )
    if case .apiKey = store.resolveAccess(lsAvailable: false) {
        fatalError("must not be apiKey")
    }
    if case .oauthNeedsSignIn = store.resolveAccess(lsAvailable: false) {} else {
        fatalError("expected sign-in")
    }
    if case .oauth(let access) = store.resolveAccess(lsAvailable: true) {
        expect(access.accessToken.isEmpty, true, "LS-only token empty")
        expect(access.accountKey.digest, AntigravityAuthStore.localLSAccountDigest, "fixed LS digest")
        expect(
            access.accountKey.digest,
            UsageDigest.sha256("antigravity-ls"),
            "LS digest is SHA-256 of antigravity-ls"
        )
        let expectedPath = AgentHaloPaths(homeDirectory: tmpHome).cacheDirectory
            .appendingPathComponent("antigravity-ls").path
        if case .file(let path) = access.source {
            expect(path, expectedPath, "LS-only source is cache/antigravity-ls")
        } else {
            fatalError("LS-only source must be file")
        }
        expect(access.providerID, .antigravity, "LS-only provider")
    } else {
        fatalError("LS-only must be oauth")
    }

    let throwingStore = AntigravityAuthStore(
        homeDirectory: tmpHome,
        keychain: ThrowingUsageKeychain(),
        files: FakeUsageFiles()
    )
    if case .oauthNeedsSignIn = throwingStore.resolveAccess(lsAvailable: false) {} else {
        fatalError("keychain throw without LS is sign-in")
    }
    if case .oauth(let access) = throwingStore.resolveAccess(lsAvailable: true) {
        expect(access.accessToken.isEmpty, true, "keychain throw with LS is empty oauth")
        expect(access.accountKey.digest, AntigravityAuthStore.localLSAccountDigest, "throw+LS uses LS digest")
    } else {
        fatalError("keychain throw with LS must be oauth")
    }
}

func testAntigravityResolveAccessFromKeychainJSON() throws {
    let tmpHome = antigravityCheckHome()
    let inner = """
    {"token":{"access_token":"ya29.test","refresh_token":"1//refresh","expiry":"2099-01-01T00:00:00Z"}}
    """
    let wrapped = antigravityCheckGoKeyring(inner)

    let wrappedKeychain = FakeUsageKeychain()
    try wrappedKeychain.write(
        service: AntigravityAuthStore.keychainService,
        account: AntigravityAuthStore.keychainAccount,
        value: wrapped
    )
    let wrappedStore = AntigravityAuthStore(
        homeDirectory: tmpHome,
        keychain: wrappedKeychain,
        files: FakeUsageFiles()
    )
    guard case .oauth(let wrappedAccess) = wrappedStore.resolveAccess(lsAvailable: false) else {
        fatalError("go-keyring keychain JSON must be oauth")
    }
    expect(wrappedAccess.accessToken, "ya29.test", "wrapped access")
    expect(wrappedAccess.refreshToken, "1//refresh", "wrapped refresh")
    expect(wrappedAccess.providerID, .antigravity, "keychain provider")
    if case .keychain(let service, let account) = wrappedAccess.source {
        expect(service, "gemini", "keychain service")
        expect(account, "antigravity", "keychain account")
    } else {
        fatalError("keychain oauth source must be keychain")
    }
    expect(wrappedKeychain.contains(service: "gemini", account: "antigravity"), true, "resolve must not drop keychain")

    let rawKeychain = FakeUsageKeychain()
    try rawKeychain.write(
        service: AntigravityAuthStore.keychainService,
        account: AntigravityAuthStore.keychainAccount,
        value: inner
    )
    let rawStore = AntigravityAuthStore(
        homeDirectory: tmpHome,
        keychain: rawKeychain,
        files: FakeUsageFiles()
    )
    guard case .oauth(let rawAccess) = rawStore.resolveAccess(lsAvailable: true) else {
        fatalError("bare keychain JSON must be oauth even when LS is available")
    }
    expect(rawAccess.accessToken, "ya29.test", "bare JSON access")
    expect(rawAccess.refreshToken, "1//refresh", "bare JSON refresh")
    if case .keychain = rawAccess.source {} else {
        fatalError("keychain wins over LS-only")
    }
}

func testAntigravityCachedAccessTokenMissesOnFingerprintMismatch() throws {
    let tmpHome = antigravityCheckHome()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let files = FakeUsageFiles()
    let store = AntigravityAuthStore(
        homeDirectory: tmpHome,
        keychain: FakeUsageKeychain(),
        files: files,
        now: { now }
    )
    try store.cacheAccessToken("ya29.cached", expiresIn: 7_200, sourceRefreshToken: "refresh-a")

    let cachePath = antigravityCheckCachePath(home: tmpHome)
    guard let written = try files.readDataIfPresent(at: cachePath),
          let text = String(data: written, encoding: .utf8)
    else {
        fatalError("cacheAccessToken must write antigravity-auth.json")
    }
    expect(text.contains("refresh-a"), false, "cache must not store raw refresh token")
    expect(text.contains("ya29.cached"), true, "cache stores access token")
    expect(text.contains(UsageDigest.sha256("refresh-a")), true, "cache stores hex fingerprint")

    let matching = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh-a", expiry: nil)
    expect(store.loadCachedAccessToken(matching: matching), "ya29.cached", "matching fingerprint hits")

    let other = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh-b", expiry: nil)
    expect(store.loadCachedAccessToken(matching: other) == nil, true, "fingerprint mismatch is a miss")
}

func testAntigravityCachedAccessTokenMissesWhenExpiringWithinBuffer() throws {
    let tmpHome = antigravityCheckHome()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let cachePath = antigravityCheckCachePath(home: tmpHome)
    let fingerprint = UsageDigest.sha256("refresh")
    let soonMs = (now.timeIntervalSince1970 + 30) * 1_000
    let soonJSON = """
    {"accessToken":"ya29.soon","expiresAtMs":\(soonMs),"credentialFingerprint":"\(fingerprint)"}
    """
    let files = FakeUsageFiles(contents: [cachePath: Data(soonJSON.utf8)])
    let store = AntigravityAuthStore(
        homeDirectory: tmpHome,
        keychain: FakeUsageKeychain(),
        files: files,
        now: { now }
    )
    let source = AntigravityKeychainToken(accessToken: nil, refreshToken: "refresh", expiry: nil)
    expect(store.loadCachedAccessToken(matching: source) == nil, true, "expires within 60s is a miss")

    try store.cacheAccessToken("ya29.far", expiresIn: 7_200, sourceRefreshToken: "refresh")
    expect(store.loadCachedAccessToken(matching: source), "ya29.far", "far expiry hits")

    let boundaryMs = (now.timeIntervalSince1970 + AntigravityAuthStore.refreshBuffer) * 1_000
    let boundaryJSON = """
    {"accessToken":"ya29.edge","expiresAtMs":\(boundaryMs),"credentialFingerprint":"\(fingerprint)"}
    """
    try files.writeAtomically(Data(boundaryJSON.utf8), to: cachePath, preservingModeOf: nil)
    expect(
        store.loadCachedAccessToken(matching: source) == nil,
        true,
        "exactly 60s remaining is a miss"
    )
}

func testAntigravityExtractToken() {
    let nested = #"{"token":{"access_token":"ya29.nested","refresh_token":"1//r"}}"#
    let nestedToken = AntigravityAuthStore.extractToken(fromKeychainRaw: nested)
    expect(nestedToken?.accessToken, "ya29.nested", "nested token.access_token")
    expect(nestedToken?.refreshToken, "1//r", "nested refresh")

    let bearer = AntigravityAuthStore.extractToken(fromKeychainRaw: "Bearer xyz")
    expect(bearer?.accessToken, "xyz", "Bearer prefix")
    expect(bearer?.refreshToken == nil, true, "Bearer has no refresh")

    expect(
        AntigravityAuthStore.extractToken(fromKeychainRaw: "{not-json") == nil,
        true,
        "bad JSON returns nil"
    )
    expect(
        AntigravityAuthStore.extractToken(fromKeychainRaw: "[") == nil,
        true,
        "broken array JSON returns nil"
    )

    let wrapped = antigravityCheckGoKeyring(nested)
    let wrappedToken = AntigravityAuthStore.extractToken(fromKeychainRaw: wrapped)
    expect(wrappedToken?.accessToken, "ya29.nested", "go-keyring unwrap then nested token")
    expect(wrappedToken?.refreshToken, "1//r", "go-keyring nested refresh")
}

private func antigravityCheckHome() -> URL {
    URL(fileURLWithPath: "/tmp/agent-halo-ag-auth-\(UUID().uuidString)", isDirectory: true)
}

private func antigravityCheckCachePath(home: URL) -> String {
    AgentHaloPaths(homeDirectory: home).cacheDirectory
        .appendingPathComponent("antigravity-auth.json").path
}

private func antigravityCheckGoKeyring(_ json: String) -> String {
    "go-keyring-base64:" + Data(json.utf8).base64EncodedString()
}

private struct ThrowingUsageKeychain: UsageKeychainAccessing {
    func read(service: String, account: String?) throws -> String? {
        throw NSError(domain: "AntigravityAuthCheck", code: 1)
    }

    func readFirstMatching(service: String) throws -> UsageKeychainItem? {
        throw NSError(domain: "AntigravityAuthCheck", code: 1)
    }

    func write(service: String, account: String?, value: String) throws {
        fatalError("AntigravityAuthStore must never write the keychain")
    }
}
