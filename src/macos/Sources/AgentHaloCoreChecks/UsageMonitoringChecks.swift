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

// MARK: - Codex auth checks

/// Build a synthetic JWT with a controlled `exp` claim. The signature segment
/// is base64url-encoded but not cryptographically signed — only the payload
/// `exp` is exercised. Never uses the developer machine's real auth file.
func codexCheckJWT(exp: TimeInterval) -> String {
    let header = #"{"alg":"HS256","typ":"JWT"}"#
    let payload = #"{"exp":\#(exp)}"#
    func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let headerB64 = base64URLEncode(Data(header.utf8))
    let payloadB64 = base64URLEncode(Data(payload.utf8))
    return "\(headerB64).\(payloadB64).sig"
}

/// Build JSON data for a Codex auth.json-shaped object from a dictionary.
func codexCheckJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

func codexCheckAuthPath(home: String) -> String {
    "\(home)/.codex/auth.json"
}

func codexCheckConfigPath(home: String) -> String {
    "\(home)/.config/codex/auth.json"
}

func runCodexAuthChecks() async {
    testCodexHomeWinsOverDefaultPaths()
    testCodexDiscoveryOrderWithoutCodexHome()
    testCodexOAuthWinsOverAPIKey()
    testCodexAPIKeyOnlyAndNoCredentialReturnAPIKey()
    testCodexAccountKeyDigest()
    testCodexNeedsRefresh()
    testCodexFileRotationPreservesCustomKeysAndMode()
    testCodexKeychainRotationWritesToCodexAuth()
    testCodexPersistRefusesOnVersionMismatch()
}

/// Case 1: `CODEX_HOME/auth.json` wins over default paths.
func testCodexHomeWinsOverDefaultPaths() {
    let codexHome = "/tmp/agent-halo-codex-home-\(UUID().uuidString)"
    let home = "/tmp/agent-halo-fake-home-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["CODEX_HOME": codexHome, "HOME": home])
    let files = FakeUsageFiles(contents: [
        "\(codexHome)/auth.json": codexCheckJSON([
            "tokens": ["access_token": "codex-home-token", "refresh_token": "rt-home"]
        ]),
        codexCheckConfigPath(home: home): codexCheckJSON([
            "tokens": ["access_token": "config-token"]
        ]),
        codexCheckAuthPath(home: home): codexCheckJSON([
            "tokens": ["access_token": "codex-token"]
        ]),
    ])
    let store = CodexAuthStore(environment: env, files: files, keychain: FakeUsageKeychain())

    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("CODEX_HOME should resolve to OAuth")
    }
    expect(access.accessToken, "codex-home-token", "CODEX_HOME auth.json should win over default paths")
    if case .file(let path) = access.source {
        expect(path, "\(codexHome)/auth.json", "source should point to CODEX_HOME/auth.json")
    } else {
        fatalError("CODEX_HOME source should be a file")
    }
}

/// Case 2: Without `CODEX_HOME`, `.config/codex`, then `.codex`, then Keychain.
func testCodexDiscoveryOrderWithoutCodexHome() {
    let home = "/tmp/agent-halo-order-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["HOME": home])

    // .config/codex wins over .codex.
    let filesConfig = FakeUsageFiles(contents: [
        codexCheckConfigPath(home: home): codexCheckJSON(["tokens": ["access_token": "config-token"]]),
        codexCheckAuthPath(home: home): codexCheckJSON(["tokens": ["access_token": "codex-token"]]),
    ])
    let storeConfig = CodexAuthStore(environment: env, files: filesConfig, keychain: FakeUsageKeychain())
    guard case .oauth(let configAccess) = storeConfig.resolveAccess() else {
        fatalError(".config/codex should resolve to OAuth")
    }
    expect(configAccess.accessToken, "config-token", ".config/codex/auth.json should win over .codex")

    // Only .codex/auth.json exists.
    let filesCodex = FakeUsageFiles(contents: [
        codexCheckAuthPath(home: home): codexCheckJSON(["tokens": ["access_token": "codex-only-token"]]),
    ])
    let storeCodex = CodexAuthStore(environment: env, files: filesCodex, keychain: FakeUsageKeychain())
    guard case .oauth(let codexAccess) = storeCodex.resolveAccess() else {
        fatalError(".codex should resolve to OAuth")
    }
    expect(codexAccess.accessToken, "codex-only-token", ".codex/auth.json should be found when .config absent")

    // Keychain fallback.
    let keychain = FakeUsageKeychain()
    try? keychain.write(
        service: CodexAuthStore.keychainService,
        account: nil,
        value: String(data: codexCheckJSON(["tokens": ["access_token": "key-token"]]), encoding: .utf8)!
    )
    let storeKey = CodexAuthStore(environment: env, files: FakeUsageFiles(), keychain: keychain)
    guard case .oauth(let keyAccess) = storeKey.resolveAccess() else {
        fatalError("keychain should resolve to OAuth")
    }
    expect(keyAccess.accessToken, "key-token", "keychain should be the last candidate")
    if case .keychain(let service, let account) = keyAccess.source {
        expect(service, CodexAuthStore.keychainService, "keychain service is Codex Auth")
        expect(account == nil, true, "keychain account is nil")
    } else {
        fatalError("keychain source should be a keychain")
    }
}

/// Case 3: Any nonempty `tokens.access_token` returns OAuth even when
/// `OPENAI_API_KEY` is also present. Also verifies an earlier API-key-only file
/// does not shadow a later OAuth login.
func testCodexOAuthWinsOverAPIKey() {
    let home = "/tmp/agent-halo-oauth-priority-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["HOME": home])

    // Same file has both OPENAI_API_KEY and tokens.access_token.
    let filesSame = FakeUsageFiles(contents: [
        codexCheckAuthPath(home: home): codexCheckJSON([
            "OPENAI_API_KEY": "sk-keep",
            "tokens": ["access_token": "oauth-token", "refresh_token": "rt"],
        ]),
    ])
    let storeSame = CodexAuthStore(environment: env, files: filesSame, keychain: FakeUsageKeychain())
    guard case .oauth(let access) = storeSame.resolveAccess() else {
        fatalError("OAuth should win when both OAuth and API key are present")
    }
    expect(access.accessToken, "oauth-token", "OAuth token wins over OPENAI_API_KEY")

    // Earlier file has only OPENAI_API_KEY; later file has OAuth tokens. The
    // later OAuth login must not be shadowed by the earlier API-key-only file.
    let filesShadow = FakeUsageFiles(contents: [
        codexCheckConfigPath(home: home): codexCheckJSON(["OPENAI_API_KEY": "sk-shadow"]),
        codexCheckAuthPath(home: home): codexCheckJSON(["tokens": ["access_token": "later-oauth"]]),
    ])
    let storeShadow = CodexAuthStore(environment: env, files: filesShadow, keychain: FakeUsageKeychain())
    guard case .oauth(let shadowAccess) = storeShadow.resolveAccess() else {
        fatalError("later OAuth login should not be shadowed by earlier API-key-only file")
    }
    expect(shadowAccess.accessToken, "later-oauth", "later OAuth file should win over earlier API-key-only file")
}

/// Case 4: API-key-only and no-recognized-credential cases both return API key.
func testCodexAPIKeyOnlyAndNoCredentialReturnAPIKey() {
    let home = "/tmp/agent-halo-apikey-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["HOME": home])

    // API-key-only file.
    let filesAPIKey = FakeUsageFiles(contents: [
        codexCheckAuthPath(home: home): codexCheckJSON(["OPENAI_API_KEY": "sk-only"]),
    ])
    let storeAPIKey = CodexAuthStore(environment: env, files: filesAPIKey, keychain: FakeUsageKeychain())
    guard case .apiKey = storeAPIKey.resolveAccess() else {
        fatalError("API-key-only file should resolve to API key mode")
    }

    // No recognized credential at all.
    let storeNone = CodexAuthStore(environment: env, files: FakeUsageFiles(), keychain: FakeUsageKeychain())
    guard case .apiKey = storeNone.resolveAccess() else {
        fatalError("no credential should safely degrade to API key mode")
    }
}

/// Case 5: `account_id` produces `SHA256(accountID)`; without it, source
/// identity plus refresh/access-token digest is used.
func testCodexAccountKeyDigest() {
    let home = "/tmp/agent-halo-acctkey-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["HOME": home])

    // With account_id → SHA256(accountID).
    let path = codexCheckAuthPath(home: home)
    let filesWithID = FakeUsageFiles(contents: [
        path: codexCheckJSON(["tokens": ["access_token": "tok", "account_id": "acct-123"]]),
    ])
    let storeWithID = CodexAuthStore(environment: env, files: filesWithID, keychain: FakeUsageKeychain())
    guard case .oauth(let accessWithID) = storeWithID.resolveAccess() else {
        fatalError("account_id case should resolve to OAuth")
    }
    expect(accessWithID.accountKey.digest, UsageDigest.sha256("acct-123"), "account_id digest is SHA256(accountID)")
    expect(accessWithID.accountID, "acct-123", "accountID is exposed")

    // Without account_id → source identity + refresh + access digest.
    let filesNoID = FakeUsageFiles(contents: [
        path: codexCheckJSON(["tokens": ["access_token": "tok", "refresh_token": "rt"]]),
    ])
    let storeNoID = CodexAuthStore(environment: env, files: filesNoID, keychain: FakeUsageKeychain())
    guard case .oauth(let accessNoID) = storeNoID.resolveAccess() else {
        fatalError("no-account_id case should resolve to OAuth")
    }
    let expectedDigest = UsageDigest.sha256("\(path)|rt|tok")
    expect(accessNoID.accountKey.digest, expectedDigest, "fallback digest uses source identity plus refresh/access-token")
    expect(accessNoID.accountID == nil, true, "accountID is nil when absent")
}

/// Case 6: JWT `exp` within 5 minutes requires refresh; unreadable JWT falls
/// back to `last_refresh > 8 days`; a new login without either does not refresh.
func testCodexNeedsRefresh() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let home = "/tmp/agent-halo-refresh-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["HOME": home])
    let store = CodexAuthStore(environment: env, files: FakeUsageFiles(), keychain: FakeUsageKeychain(), now: { now })

    // JWT exp within 5 minutes → needs refresh. Also verify resolveAccess
    // parsed exp into OAuthAccess.expiresAt.
    let soonExp = now.addingTimeInterval(3 * 60).timeIntervalSince1970
    let soonJWT = codexCheckJWT(exp: soonExp)
    let filesSoon = FakeUsageFiles(contents: [
        codexCheckAuthPath(home: home): codexCheckJSON(["tokens": ["access_token": soonJWT]]),
    ])
    let storeSoon = CodexAuthStore(environment: env, files: filesSoon, keychain: FakeUsageKeychain(), now: { now })
    guard case .oauth(let soonAccess) = storeSoon.resolveAccess() else {
        fatalError("soon-exp JWT should resolve to OAuth")
    }
    expect(soonAccess.expiresAt != nil, true, "resolveAccess should parse JWT exp into expiresAt")
    expect(
        soonAccess.expiresAt?.timeIntervalSince1970 ?? 0,
        soonExp,
        "expiresAt should match JWT exp"
    )
    expect(store.needsRefresh(soonAccess, lastRefresh: nil), true, "exp within 5 minutes needs refresh")

    // JWT exp beyond 5 minutes → no refresh.
    let farExp = now.addingTimeInterval(3600).timeIntervalSince1970
    let farJWT = codexCheckJWT(exp: farExp)
    let filesFar = FakeUsageFiles(contents: [
        codexCheckAuthPath(home: home): codexCheckJSON(["tokens": ["access_token": farJWT]]),
    ])
    let storeFar = CodexAuthStore(environment: env, files: filesFar, keychain: FakeUsageKeychain(), now: { now })
    guard case .oauth(let farAccess) = storeFar.resolveAccess() else {
        fatalError("far-exp JWT should resolve to OAuth")
    }
    expect(store.needsRefresh(farAccess, lastRefresh: nil), false, "exp beyond 5 minutes does not refresh")

    // Unreadable JWT → expiresAt is nil. Falls back to last_refresh.
    let filesBad = FakeUsageFiles(contents: [
        codexCheckAuthPath(home: home): codexCheckJSON(["tokens": ["access_token": "not-a-jwt"]]),
    ])
    let storeBad = CodexAuthStore(environment: env, files: filesBad, keychain: FakeUsageKeychain(), now: { now })
    guard case .oauth(let badAccess) = storeBad.resolveAccess() else {
        fatalError("unreadable JWT should still resolve to OAuth")
    }
    expect(badAccess.expiresAt == nil, true, "unreadable JWT should not produce expiresAt")

    let eightDays: TimeInterval = 8 * 24 * 60 * 60
    expect(
        store.needsRefresh(badAccess, lastRefresh: now.addingTimeInterval(-eightDays - 60)),
        true,
        "unreadable JWT with last_refresh older than 8 days needs refresh"
    )
    expect(
        store.needsRefresh(badAccess, lastRefresh: now.addingTimeInterval(-eightDays + 60)),
        false,
        "unreadable JWT with last_refresh newer than 8 days does not refresh"
    )
    // A new login with no exp and no last_refresh does not refresh.
    expect(
        store.needsRefresh(badAccess, lastRefresh: nil),
        false,
        "new login without exp or last_refresh does not refresh"
    )
}

/// Case 7: File rotation preserves a custom top-level key, a custom nested
/// token key and the original mode.
func testCodexFileRotationPreservesCustomKeysAndMode() {
    let home = "/tmp/agent-halo-rotate-file-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["HOME": home])
    let path = codexCheckAuthPath(home: home)
    let files = FakeUsageFiles(
        contents: [
            path: codexCheckJSON([
                "OPENAI_API_KEY": "sk-keep",
                "custom_top": "keep",
                "tokens": [
                    "access_token": "old-token",
                    "refresh_token": "old-rt",
                    "custom_nested": "keep",
                ],
            ])
        ],
        modes: [path: 0o644]
    )
    let store = CodexAuthStore(environment: env, files: files, keychain: FakeUsageKeychain())
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("file rotation should start from OAuth")
    }
    expect(access.accessToken, "old-token", "initial token before rotation")

    let refreshedAt = Date(timeIntervalSince1970: 2_000_000)
    let rotation = CodexTokenRotation(
        accessToken: "new-token",
        refreshToken: "new-rt",
        idToken: nil,
        refreshedAt: refreshedAt
    )
    let result: OAuthAccess?
    do {
        result = try store.persist(rotation: rotation, replacing: access)
    } catch {
        fatalError("persist should not throw: \(error)")
    }
    guard let rotated = result else {
        fatalError("persist should return a rotated OAuthAccess")
    }
    expect(rotated.accessToken, "new-token", "rotated access token")
    expect(rotated.refreshToken, "new-rt", "rotated refresh token")
    expect(rotated.sourceVersion != access.sourceVersion, true, "rotated source version should change")

    let writes = files.capturedWrites()
    expect(writes.count, 1, "exactly one file write")
    expect(writes[0].path, path, "write path")
    expect(writes[0].preservingModeOf, path, "write should preserve mode of original path")
    expect(files.storedMode(for: path), 0o644, "original mode preserved")

    guard let written = try? JSONSerialization.jsonObject(with: writes[0].data) as? [String: Any] else {
        fatalError("written data should be a JSON object")
    }
    expect(written["custom_top"] as? String, "keep", "custom top-level key preserved")
    expect(written["OPENAI_API_KEY"] as? String, "sk-keep", "OPENAI_API_KEY preserved")
    let tokens = written["tokens"] as? [String: Any]
    expect(tokens?["access_token"] as? String, "new-token", "access token rotated")
    expect(tokens?["refresh_token"] as? String, "new-rt", "refresh token rotated")
    expect(tokens?["custom_nested"] as? String, "keep", "custom nested token key preserved")
    let lastRefresh = written["last_refresh"] as? String
    expect(lastRefresh != nil, "last_refresh should be set")
    // last_refresh should parse back to the refreshedAt date.
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    expect(parser.date(from: lastRefresh ?? ""), refreshedAt, "last_refresh should round-trip to refreshedAt")
}

/// Case 8: Keychain rotation writes to service `Codex Auth` with the same
/// account form.
func testCodexKeychainRotationWritesToCodexAuth() {
    let env = FakeUsageEnvironment()
    let keychain = FakeUsageKeychain()
    let kcJSON = String(data: codexCheckJSON([
        "tokens": ["access_token": "old-token", "account_id": "acct-1", "refresh_token": "old-rt"],
    ]), encoding: .utf8)!
    try? keychain.write(service: CodexAuthStore.keychainService, account: nil, value: kcJSON)

    let store = CodexAuthStore(environment: env, files: FakeUsageFiles(), keychain: keychain)
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("keychain should resolve to OAuth")
    }
    expect(access.accessToken, "old-token", "initial keychain token")
    if case .keychain(let service, _) = access.source {
        expect(service, CodexAuthStore.keychainService, "source service is Codex Auth")
    } else {
        fatalError("keychain source should be a keychain")
    }

    let refreshedAt = Date(timeIntervalSince1970: 2_000_000)
    let rotation = CodexTokenRotation(
        accessToken: "new-token",
        refreshToken: "new-rt",
        idToken: "new-id",
        refreshedAt: refreshedAt
    )
    let result: OAuthAccess?
    do {
        result = try store.persist(rotation: rotation, replacing: access)
    } catch {
        fatalError("keychain persist should not throw: \(error)")
    }
    guard let rotated = result else {
        fatalError("keychain persist should return a rotated OAuthAccess")
    }
    expect(rotated.accessToken, "new-token", "rotated keychain access token")
    expect(rotated.refreshToken, "new-rt", "rotated keychain refresh token")
    expect(rotated.accountID, "acct-1", "account_id preserved")

    // The keychain entry should be updated at the same service/account.
    expect(keychain.contains(service: CodexAuthStore.keychainService, account: nil), "keychain entry present")
    let written = try? keychain.read(service: CodexAuthStore.keychainService, account: nil)
    guard let writtenObj = try? JSONSerialization.jsonObject(
        with: Data((written ?? "").utf8)
    ) as? [String: Any] else {
        fatalError("written keychain value should be a JSON object")
    }
    let tokens = writtenObj["tokens"] as? [String: Any]
    expect(tokens?["access_token"] as? String, "new-token", "keychain access token rotated")
    expect(tokens?["refresh_token"] as? String, "new-rt", "keychain refresh token rotated")
    expect(tokens?["id_token"] as? String, "new-id", "keychain id token rotated")
    expect(tokens?["account_id"] as? String, "acct-1", "keychain account_id preserved")
}

/// Case 9: If the source version changes before writeback, `persist` refuses
/// to overwrite it.
func testCodexPersistRefusesOnVersionMismatch() {
    let home = "/tmp/agent-halo-version-\(UUID().uuidString)"
    let env = FakeUsageEnvironment(["HOME": home])
    let path = codexCheckAuthPath(home: home)
    let files = FakeUsageFiles(contents: [
        path: codexCheckJSON(["tokens": ["access_token": "old-token", "refresh_token": "old-rt"]]),
    ])
    let store = CodexAuthStore(environment: env, files: files, keychain: FakeUsageKeychain())
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("version-mismatch check should start from OAuth")
    }
    let originalVersion = access.sourceVersion

    // Simulate an external change: rewrite the file with different content
    // through the same file accessor (updates the "disk" and the version).
    try? files.writeAtomically(
        codexCheckJSON(["tokens": ["access_token": "changed-externally", "refresh_token": "old-rt"]]),
        to: path,
        preservingModeOf: nil
    )

    let rotation = CodexTokenRotation(
        accessToken: "new-token",
        refreshToken: "new-rt",
        idToken: nil,
        refreshedAt: Date(timeIntervalSince1970: 2_000_000)
    )
    let result: OAuthAccess?
    do {
        result = try store.persist(rotation: rotation, replacing: access)
    } catch {
        fatalError("persist should not throw on version mismatch: \(error)")
    }
    expect(result == nil, "persist should refuse to write when the source version changed")
    // No additional write beyond the external one.
    expect(files.capturedWrites().count, 1, "persist must not write on version mismatch")
    expect(originalVersion != UsageDigest.sha256(""), true, "original version is a real digest")
}
