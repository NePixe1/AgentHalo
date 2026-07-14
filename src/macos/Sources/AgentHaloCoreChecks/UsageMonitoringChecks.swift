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

    await runCodexAuthChecks()
    runClaudeAuthChecks()
    await runCodexUsageChecks()
    await runClaudeUsageChecks()
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
    testCodexNeedsRefreshUsesStoredLastRefresh()
    testCodexFileRotationPreservesCustomKeysAndMode()
    testCodexKeychainRotationWritesToCodexAuth()
    testCodexPersistRefusesOnVersionMismatch()
    testCodexSourceVersionHashesRawDataBytes()
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

/// The convenience path used by the provider must parse `last_refresh` from
/// the exact stored JSON instead of requiring the caller to reconstruct it.
func testCodexNeedsRefreshUsesStoredLastRefresh() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    func storedResult(lastRefresh: Date?) -> Bool {
        let home = "/tmp/agent-halo-stored-refresh-\(UUID().uuidString)"
        let path = codexCheckAuthPath(home: home)
        var object: [String: Any] = ["tokens": ["access_token": "not-a-jwt"]]
        if let lastRefresh {
            object["last_refresh"] = formatter.string(from: lastRefresh)
        }
        let store = CodexAuthStore(
            environment: FakeUsageEnvironment(["HOME": home]),
            files: FakeUsageFiles(contents: [path: codexCheckJSON(object)]),
            keychain: FakeUsageKeychain(),
            now: { now }
        )
        guard case .oauth(let access) = store.resolveAccess() else {
            fatalError("stored last_refresh case should resolve to OAuth")
        }
        return store.needsRefresh(access)
    }

    let eightDays: TimeInterval = 8 * 24 * 60 * 60
    expect(
        storedResult(lastRefresh: now.addingTimeInterval(-eightDays - 60)),
        true,
        "stored last_refresh older than 8 days requires refresh"
    )
    expect(
        storedResult(lastRefresh: now.addingTimeInterval(-eightDays + 60)),
        false,
        "stored last_refresh newer than 8 days does not require refresh"
    )
    expect(
        storedResult(lastRefresh: nil),
        false,
        "stored login without exp or last_refresh does not require refresh"
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

/// A source version must hash the exact bytes, not a lossy UTF-8 decoding.
/// These UTF-16LE documents differ only by a non-ASCII custom value; both are
/// valid JSON, while neither can be decoded as UTF-8.
func testCodexSourceVersionHashesRawDataBytes() {
    func utf16JSON(marker: String) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(
            #"{"marker":"\#(marker)","tokens":{"access_token":"same-token","refresh_token":"same-rt"}}"#
                .data(using: .utf16LittleEndian)!
        )
        return data
    }

    let home = "/tmp/agent-halo-raw-version-\(UUID().uuidString)"
    let path = codexCheckAuthPath(home: home)
    let originalData = utf16JSON(marker: "é")
    let changedData = utf16JSON(marker: "ê")
    expect(String(data: originalData, encoding: .utf8) == nil, true, "original UTF-16 JSON is not UTF-8")
    expect(String(data: changedData, encoding: .utf8) == nil, true, "changed UTF-16 JSON is not UTF-8")
    expect(
        (try? JSONSerialization.jsonObject(with: originalData)) != nil,
        true,
        "original UTF-16 JSON remains parseable"
    )
    expect(
        (try? JSONSerialization.jsonObject(with: changedData)) != nil,
        true,
        "changed UTF-16 JSON remains parseable"
    )

    let environment = FakeUsageEnvironment(["HOME": home])
    let originalStore = CodexAuthStore(
        environment: environment,
        files: FakeUsageFiles(contents: [path: originalData]),
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let originalAccess) = originalStore.resolveAccess() else {
        fatalError("original UTF-16 JSON should resolve to OAuth")
    }
    let changedStore = CodexAuthStore(
        environment: environment,
        files: FakeUsageFiles(contents: [path: changedData]),
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let changedAccess) = changedStore.resolveAccess() else {
        fatalError("changed UTF-16 JSON should resolve to OAuth")
    }
    expect(
        originalAccess.sourceVersion != changedAccess.sourceVersion,
        true,
        "different raw JSON bytes must produce different source versions"
    )

    let mutableFiles = FakeUsageFiles(contents: [path: originalData])
    let mutableStore = CodexAuthStore(
        environment: environment,
        files: mutableFiles,
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let expected) = mutableStore.resolveAccess() else {
        fatalError("mutable UTF-16 JSON should resolve to OAuth")
    }
    try? mutableFiles.writeAtomically(changedData, to: path, preservingModeOf: path)
    let result = try? mutableStore.persist(
        rotation: CodexTokenRotation(
            accessToken: "rotated-token",
            refreshToken: nil,
            idToken: nil,
            refreshedAt: Date(timeIntervalSince1970: 2_000_000)
        ),
        replacing: expected
    )
    expect(result == nil, true, "persist must refuse a raw-byte source version change")
    expect(mutableFiles.capturedWrites().count, 1, "persist must not write after raw-byte version mismatch")
}

// MARK: - Claude auth checks

func claudeCheckJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

func claudeCheckCredential(
    accessToken: String,
    refreshToken: String? = "refresh-token",
    expiresAtMilliseconds: Double? = nil,
    subscriptionType: String? = nil,
    rateLimitTier: String? = nil,
    scopes: [String]? = ["user:profile"],
    extraOAuth: [String: Any] = [:],
    extraRoot: [String: Any] = [:]
) -> Data {
    var oauth: [String: Any] = extraOAuth
    oauth["accessToken"] = accessToken
    if let refreshToken { oauth["refreshToken"] = refreshToken }
    if let expiresAtMilliseconds { oauth["expiresAt"] = expiresAtMilliseconds }
    if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
    if let rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }
    if let scopes { oauth["scopes"] = scopes }
    var root = extraRoot
    root["claudeAiOauth"] = oauth
    return claudeCheckJSON(root)
}

func claudeCheckString(_ data: Data) -> String {
    String(data: data, encoding: .utf8)!
}

func claudeCheckPath(home: String) -> String {
    "\(home)/.claude/.credentials.json"
}

func runClaudeAuthChecks() {
    testSecurityUsageKeychainResolvesLegacyAccountBeforeReadingValue()
    testSecurityUsageKeychainRejectsMissingOrUnparseableLegacyMetadata()
    testClaudeDiscoveryIsKeychainFirst()
    testClaudeConfigDirChangesPathAndKeychainService()
    testClaudeConfigDirServiceHashNormalizesUnicode()
    testClaudeStoredOAuthWinsOverEnvironmentToken()
    testClaudeEnvironmentTokenAloneIsAPIKeyMode()
    testClaudeScopesKeepOAuthModeAndAccountIdentity()
    testClaudeExactSourceResolvedReloadHonorsScopes()
    testClaudeAccountKeyUsesSourceAndTokenDigest()
    testClaudeExpiresAtUsesEpochMilliseconds()
    testClaudePlanHintsArePreserved()
    testClaudeFileAndKeychainRotationPreserveUnknownFieldsAndSource()
    testClaudeLegacyRotationWritesToDiscoveredAccount()
    testClaudePersistRefusesServiceOnlySourceWithoutAccount()
    testClaudePersistRefusesCredentialGenerationMismatch()
    testClaudeRejectsNonProductionOAuthOverrides()
}

func testSecurityUsageKeychainResolvesLegacyAccountBeforeReadingValue() {
    let service = "Claude Code-credentials"
    let legacyAccount = " legacy-account "
    let metadata = #""acct"<blob>=" legacy-account ""#
    let runner = RecordingUsageProcessRunner(results: [
        UsageProcessResult(
            exitCode: 0,
            standardOutput: Data(),
            standardError: Data(metadata.utf8)
        ),
        UsageProcessResult(
            exitCode: 0,
            standardOutput: Data("credential-json\n".utf8),
            standardError: Data()
        ),
    ])
    let keychain = SecurityUsageKeychain(processRunner: runner)
    let item: UsageKeychainItem?
    do {
        item = try keychain.readFirstMatching(service: service)
    } catch {
        fatalError("legacy keychain lookup should not throw: \(error)")
    }
    expect(item?.account, legacyAccount, "legacy lookup returns the exact matched account")
    expect(item?.value, "credential-json", "legacy lookup returns value from explicit-account read")

    let calls = runner.capturedCalls()
    expect(calls.count, 2, "legacy lookup performs metadata then explicit-account read")
    expect(calls[0].executable, "/usr/bin/security", "legacy metadata executable")
    expect(
        calls[0].arguments,
        ["find-generic-password", "-s", service, "-g"],
        "legacy metadata query uses only service-scoped metadata arguments"
    )
    expect(
        calls[1].arguments,
        ["find-generic-password", "-s", service, "-a", legacyAccount, "-w"],
        "legacy value query must use the parsed explicit account"
    )
}

func testSecurityUsageKeychainRejectsMissingOrUnparseableLegacyMetadata() {
    let service = "Claude Code-credentials"
    let notFoundRunner = RecordingUsageProcessRunner(results: [
        UsageProcessResult(exitCode: 44, standardOutput: Data(), standardError: Data()),
    ])
    let notFound = SecurityUsageKeychain(processRunner: notFoundRunner)
    expect(
        try? notFound.readFirstMatching(service: service),
        nil,
        "not-found legacy keychain lookup returns no candidate"
    )
    expect(notFoundRunner.capturedCalls().count, 1, "not-found lookup stops after metadata query")

    let malformedRunner = RecordingUsageProcessRunner(results: [
        UsageProcessResult(
            exitCode: 0,
            standardOutput: Data(),
            standardError: Data(#""svce"<blob>="Claude Code-credentials""#.utf8)
        ),
    ])
    let malformed = SecurityUsageKeychain(processRunner: malformedRunner)
    expect(
        try? malformed.readFirstMatching(service: service),
        nil,
        "metadata without acct returns no legacy candidate"
    )
    expect(malformedRunner.capturedCalls().count, 1, "unparseable metadata must not read or write a value")
}

func testClaudeDiscoveryIsKeychainFirst() {
    let home = "/tmp/agent-halo-claude-order-\(UUID().uuidString)"
    let user = "agent-halo-user"
    let environment = FakeUsageEnvironment(["HOME": home, "USER": user])
    let filePath = claudeCheckPath(home: home)
    let files = FakeUsageFiles(contents: [
        filePath: claudeCheckCredential(accessToken: "file-token"),
    ])

    let bothKeychainForms = FakeUsageKeychain()
    try? bothKeychainForms.write(
        service: "Claude Code-credentials",
        account: nil,
        value: claudeCheckString(claudeCheckCredential(accessToken: "legacy-token"))
    )
    try? bothKeychainForms.write(
        service: "Claude Code-credentials",
        account: user,
        value: claudeCheckString(claudeCheckCredential(accessToken: "current-user-token"))
    )
    let currentUserStore = ClaudeAuthStore(
        environment: environment,
        files: files,
        keychain: bothKeychainForms
    )
    guard case .oauth(let currentUser) = currentUserStore.resolveAccess() else {
        fatalError("current-user Claude keychain credential should resolve to OAuth")
    }
    expect(currentUser.accessToken, "current-user-token", "current-user keychain should win")
    expect(
        currentUser.source,
        .keychain(service: "Claude Code-credentials", account: user),
        "current-user keychain source identity"
    )

    let legacyOnly = FakeUsageKeychain()
    try? legacyOnly.write(
        service: "Claude Code-credentials",
        account: "legacy-account",
        value: claudeCheckString(claudeCheckCredential(accessToken: "legacy-token"))
    )
    let legacyStore = ClaudeAuthStore(environment: environment, files: files, keychain: legacyOnly)
    guard case .oauth(let legacy) = legacyStore.resolveAccess() else {
        fatalError("legacy Claude keychain credential should resolve to OAuth")
    }
    expect(legacy.accessToken, "legacy-token", "legacy service-only keychain should precede file")
    expect(
        legacy.source,
        .keychain(service: "Claude Code-credentials", account: "legacy-account"),
        "legacy source keeps the actual discovered account"
    )

    let fileStore = ClaudeAuthStore(
        environment: environment,
        files: files,
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let file) = fileStore.resolveAccess() else {
        fatalError("Claude credential file should be the final stored OAuth fallback")
    }
    expect(file.accessToken, "file-token", "credential file should load after keychain misses")
    expect(file.source, .file(path: filePath), "file source should retain its exact path")

    guard let exactFile = currentUserStore.reload(source: .file(path: filePath)) else {
        fatalError("reload should read the exact requested file source")
    }
    expect(exactFile.accessToken, "file-token", "exact file reload must not rediscover keychain")
}

func testClaudeConfigDirChangesPathAndKeychainService() {
    let configDir = "/tmp/agent-halo-claude-config-\(UUID().uuidString)"
    let home = "/tmp/agent-halo-claude-home-\(UUID().uuidString)"
    let user = "config-user"
    let suffix = String(UsageDigest.sha256(configDir).prefix(8))
    let scopedService = "Claude Code-credentials-\(suffix)"
    let environment = FakeUsageEnvironment([
        "CLAUDE_CONFIG_DIR": configDir,
        "HOME": home,
        "USER": user,
    ])
    let files = FakeUsageFiles(contents: [
        "\(configDir)/.credentials.json": claudeCheckCredential(accessToken: "config-file-token"),
        claudeCheckPath(home: home): claudeCheckCredential(accessToken: "default-file-token"),
    ])
    let keychain = FakeUsageKeychain()
    try? keychain.write(
        service: "Claude Code-credentials",
        account: user,
        value: claudeCheckString(claudeCheckCredential(accessToken: "base-keychain-token"))
    )
    try? keychain.write(
        service: scopedService,
        account: user,
        value: claudeCheckString(claudeCheckCredential(accessToken: "scoped-keychain-token"))
    )
    let store = ClaudeAuthStore(environment: environment, files: files, keychain: keychain)
    guard case .oauth(let scoped) = store.resolveAccess() else {
        fatalError("config-scoped Claude keychain should resolve to OAuth")
    }
    expect(scoped.accessToken, "scoped-keychain-token", "config-scoped service should precede base service")
    expect(
        scoped.source,
        .keychain(service: scopedService, account: user),
        "config-scoped service should use 8-character SHA256 suffix"
    )

    let fileOnlyStore = ClaudeAuthStore(
        environment: environment,
        files: files,
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let configFile) = fileOnlyStore.resolveAccess() else {
        fatalError("CLAUDE_CONFIG_DIR credential file should resolve to OAuth")
    }
    expect(configFile.source, .file(path: "\(configDir)/.credentials.json"), "config dir changes file path")
}

func testClaudeConfigDirServiceHashNormalizesUnicode() {
    let composedConfigDir = "/tmp/agent-halo-caf\u{00e9}"
    let decomposedConfigDir = composedConfigDir.decomposedStringWithCanonicalMapping
    expect(
        Array(composedConfigDir.utf8) == Array(decomposedConfigDir.utf8),
        false,
        "Unicode fixture must use distinct UTF-8 code units"
    )

    let user = "unicode-user"
    let normalized = decomposedConfigDir.precomposedStringWithCanonicalMapping
    let suffix = String(UsageDigest.sha256(normalized).prefix(8))
    let service = "Claude Code-credentials-\(suffix)"
    let keychain = FakeUsageKeychain()
    try? keychain.write(
        service: service,
        account: user,
        value: claudeCheckString(claudeCheckCredential(accessToken: "unicode-config-token"))
    )
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment([
            "CLAUDE_CONFIG_DIR": decomposedConfigDir,
            "USER": user,
        ]),
        files: FakeUsageFiles(),
        keychain: keychain
    )
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("canonically equivalent CLAUDE_CONFIG_DIR should discover the same keychain service")
    }
    expect(access.source, .keychain(service: service, account: user), "config service hash uses NFC path")
}

func testClaudeStoredOAuthWinsOverEnvironmentToken() {
    let home = "/tmp/agent-halo-claude-env-shadow-\(UUID().uuidString)"
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment([
            "HOME": home,
            "CLAUDE_CODE_OAUTH_TOKEN": "inference-only-token",
        ]),
        files: FakeUsageFiles(contents: [
            claudeCheckPath(home: home): claudeCheckCredential(accessToken: "stored-oauth-token"),
        ]),
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("stored Claude OAuth should win over inference-only environment token")
    }
    expect(access.accessToken, "stored-oauth-token", "stored OAuth wins over environment token")
}

func testClaudeEnvironmentTokenAloneIsAPIKeyMode() {
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "inference-only-token"]),
        files: FakeUsageFiles(),
        keychain: FakeUsageKeychain()
    )
    guard case .apiKey = store.resolveAccess() else {
        fatalError("CLAUDE_CODE_OAUTH_TOKEN alone must remain API key mode")
    }
}

func testClaudeScopesKeepOAuthModeAndAccountIdentity() {
    let home = "/tmp/agent-halo-claude-scopes-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    let environment = FakeUsageEnvironment(["HOME": home])

    for scopes in [Optional<[String]>.none, []] {
        let store = ClaudeAuthStore(
            environment: environment,
            files: FakeUsageFiles(contents: [
                path: claudeCheckCredential(accessToken: "allowed-token", scopes: scopes),
            ]),
            keychain: FakeUsageKeychain()
        )
        guard case .oauth = store.resolveAccess() else {
            fatalError("absent or empty Claude scopes should remain OAuth mode")
        }
    }

    let missingStore = ClaudeAuthStore(
        environment: environment,
        files: FakeUsageFiles(contents: [
            path: claudeCheckCredential(accessToken: "missing-scope-token", scopes: ["user:inference"]),
        ]),
        keychain: FakeUsageKeychain()
    )
    guard let parsed = missingStore.reload(source: .file(path: path)) else {
        fatalError("explicitly under-scoped credential should still parse as stored OAuth")
    }
    guard case .oauthNeedsSignIn(let accountKey) = missingStore.resolveAccess() else {
        fatalError("stored OAuth missing user:profile should request OAuth sign-in again")
    }
    expect(accountKey, parsed.accountKey, "scope failure keeps the same OAuth account key")
}

func testClaudeExactSourceResolvedReloadHonorsScopes() {
    let home = "/tmp/agent-halo-claude-exact-scopes-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    let files = FakeUsageFiles()
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["HOME": home]),
        files: files,
        keychain: FakeUsageKeychain()
    )

    for scopes in [Optional<[String]>.none, []] {
        try? files.writeAtomically(
            claudeCheckCredential(accessToken: "exact-allowed", scopes: scopes),
            to: path,
            preservingModeOf: path
        )
        guard case .oauth = store.reloadResolved(source: .file(path: path)) else {
            fatalError("exact-source reload should allow absent or empty Claude scopes")
        }
    }

    try? files.writeAtomically(
        claudeCheckCredential(accessToken: "exact-under-scoped", scopes: ["user:inference"]),
        to: path,
        preservingModeOf: path
    )
    guard case .oauthNeedsSignIn(let accountKey) = store.reloadResolved(source: .file(path: path)) else {
        fatalError("exact-source reload missing user:profile should require sign in")
    }
    expect(accountKey?.providerID, .claude, "exact-source scope failure preserves Claude account identity")
}

func testClaudeAccountKeyUsesSourceAndTokenDigest() {
    let home = "/tmp/agent-halo-claude-account-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    let environment = FakeUsageEnvironment(["HOME": home])

    func resolved(accessToken: String, refreshToken: String?) -> OAuthAccess {
        let store = ClaudeAuthStore(
            environment: environment,
            files: FakeUsageFiles(contents: [
                path: claudeCheckCredential(accessToken: accessToken, refreshToken: refreshToken),
            ]),
            keychain: FakeUsageKeychain()
        )
        guard case .oauth(let access) = store.resolveAccess() else {
            fatalError("Claude account-key fixture should resolve to OAuth")
        }
        return access
    }

    let withRefresh = resolved(accessToken: "access-token", refreshToken: "stable-refresh")
    expect(
        withRefresh.accountKey.digest,
        UsageDigest.sha256("\(path)|\(UsageDigest.sha256("stable-refresh"))"),
        "Claude account key uses source identity plus refresh-token digest"
    )
    let accessOnly = resolved(accessToken: "access-only", refreshToken: nil)
    expect(
        accessOnly.accountKey.digest,
        UsageDigest.sha256("\(path)|\(UsageDigest.sha256("access-only"))"),
        "Claude account key falls back to source identity plus access-token digest"
    )
    expect(accessOnly.sourceVersion.count, 64, "Claude source version remains a SHA256 digest")
}

func testClaudeExpiresAtUsesEpochMilliseconds() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let home = "/tmp/agent-halo-claude-expiry-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    func access(after seconds: TimeInterval) -> (ClaudeAuthStore, OAuthAccess) {
        let store = ClaudeAuthStore(
            environment: FakeUsageEnvironment(["HOME": home]),
            files: FakeUsageFiles(contents: [
                path: claudeCheckCredential(
                    accessToken: "expiry-token-\(seconds)",
                    expiresAtMilliseconds: now.addingTimeInterval(seconds).timeIntervalSince1970 * 1000
                ),
            ]),
            keychain: FakeUsageKeychain(),
            now: { now }
        )
        guard case .oauth(let access) = store.resolveAccess() else {
            fatalError("Claude expiresAt fixture should resolve to OAuth")
        }
        return (store, access)
    }

    let (soonStore, soon) = access(after: 3 * 60)
    expect(soon.expiresAt, now.addingTimeInterval(3 * 60), "expiresAt parses epoch milliseconds")
    expect(soonStore.needsRefresh(soon), true, "Claude token within five minutes needs refresh")
    let (farStore, far) = access(after: 10 * 60)
    expect(farStore.needsRefresh(far), false, "Claude token beyond five minutes does not need refresh")
}

func testClaudePlanHintsArePreserved() {
    let home = "/tmp/agent-halo-claude-plan-\(UUID().uuidString)"
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["HOME": home]),
        files: FakeUsageFiles(contents: [
            claudeCheckPath(home: home): claudeCheckCredential(
                accessToken: "plan-token",
                subscriptionType: "max",
                rateLimitTier: "default_claude_max_20x"
            ),
        ]),
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("Claude plan-hint fixture should resolve to OAuth")
    }
    expect(access.planHint?.subscriptionType, "max", "subscriptionType plan hint")
    expect(access.planHint?.rateLimitTier, "default_claude_max_20x", "rateLimitTier plan hint")
}

func testClaudeFileAndKeychainRotationPreserveUnknownFieldsAndSource() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let rotatedExpiry = now.addingTimeInterval(3600)
    let home = "/tmp/agent-halo-claude-rotate-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    let files = FakeUsageFiles(
        contents: [
            path: claudeCheckCredential(
                accessToken: "old-file-token",
                extraOAuth: ["oauthCustom": "keep"],
                extraRoot: ["rootCustom": "keep"]
            ),
        ],
        modes: [path: 0o640]
    )
    let fileStore = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["HOME": home]),
        files: files,
        keychain: FakeUsageKeychain(),
        now: { now }
    )
    guard case .oauth(let fileAccess) = fileStore.resolveAccess() else {
        fatalError("Claude file rotation should start from OAuth")
    }
    let fileRotated = try? fileStore.persist(
        rotation: ClaudeTokenRotation(
            accessToken: "new-file-token",
            refreshToken: "new-file-refresh",
            expiresAt: rotatedExpiry
        ),
        replacing: fileAccess
    )
    expect(fileRotated?.source, .file(path: path), "file rotation keeps exact source")
    expect(files.storedMode(for: path), 0o640, "file rotation preserves original permissions")
    guard let fileWrite = files.capturedWrites().last,
          let fileObject = try? JSONSerialization.jsonObject(with: fileWrite.data) as? [String: Any],
          let fileOAuth = fileObject["claudeAiOauth"] as? [String: Any]
    else {
        fatalError("Claude file rotation should write valid merged JSON")
    }
    expect(fileObject["rootCustom"] as? String, "keep", "file rotation preserves unknown root field")
    expect(fileOAuth["oauthCustom"] as? String, "keep", "file rotation preserves unknown OAuth field")
    expect(fileOAuth["accessToken"] as? String, "new-file-token", "file access token rotates")
    expect(fileOAuth["expiresAt"] as? Double, rotatedExpiry.timeIntervalSince1970 * 1000, "expiry writes epoch ms")

    let user = "rotate-user"
    let keychain = FakeUsageKeychain()
    try? keychain.write(
        service: "Claude Code-credentials",
        account: user,
        value: claudeCheckString(claudeCheckCredential(
            accessToken: "old-keychain-token",
            extraOAuth: ["keychainCustom": "keep"]
        ))
    )
    let keychainStore = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["USER": user]),
        files: FakeUsageFiles(),
        keychain: keychain,
        now: { now }
    )
    guard case .oauth(let keychainAccess) = keychainStore.resolveAccess() else {
        fatalError("Claude keychain rotation should start from OAuth")
    }
    let keychainRotated = try? keychainStore.persist(
        rotation: ClaudeTokenRotation(
            accessToken: "new-keychain-token",
            refreshToken: nil,
            expiresAt: rotatedExpiry
        ),
        replacing: keychainAccess
    )
    expect(
        keychainRotated?.source,
        .keychain(service: "Claude Code-credentials", account: user),
        "keychain rotation keeps exact service/account source"
    )
    let writtenKeychain = try? keychain.read(service: "Claude Code-credentials", account: user)
    guard let keychainData = writtenKeychain.flatMap({ Data($0.utf8) }),
          let keychainObject = try? JSONSerialization.jsonObject(with: keychainData) as? [String: Any],
          let keychainOAuth = keychainObject["claudeAiOauth"] as? [String: Any]
    else {
        fatalError("Claude keychain rotation should write valid merged JSON")
    }
    expect(keychainOAuth["keychainCustom"] as? String, "keep", "keychain rotation preserves unknown field")
    expect(keychainOAuth["refreshToken"] as? String, "refresh-token", "nil rotated refresh preserves stored refresh")
}

func testClaudeLegacyRotationWritesToDiscoveredAccount() {
    let service = "Claude Code-credentials"
    let legacyAccount = "legacy-account"
    let storedValue = claudeCheckString(
        claudeCheckCredential(accessToken: "old-legacy-token")
    )
    let metadata = #""acct"<blob>="legacy-account""#
    let runner = RecordingUsageProcessRunner(results: [
        UsageProcessResult(exitCode: 44, standardOutput: Data(), standardError: Data()),
        UsageProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data(metadata.utf8)),
        UsageProcessResult(
            exitCode: 0,
            standardOutput: Data("\(storedValue)\n".utf8),
            standardError: Data()
        ),
        UsageProcessResult(
            exitCode: 0,
            standardOutput: Data("\(storedValue)\n".utf8),
            standardError: Data()
        ),
        UsageProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data()),
    ])
    let keychain = SecurityUsageKeychain(processRunner: runner)
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["USER": "different-current-user"]),
        files: FakeUsageFiles(),
        keychain: keychain
    )
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("legacy service-only fallback should resolve to OAuth")
    }
    expect(
        access.source,
        .keychain(service: service, account: legacyAccount),
        "legacy access stores the actual matched account"
    )

    let rotated: OAuthAccess?
    do {
        rotated = try store.persist(
            rotation: ClaudeTokenRotation(
                accessToken: "new-legacy-token",
                refreshToken: "new-legacy-refresh",
                expiresAt: Date(timeIntervalSince1970: 4_000_000)
            ),
            replacing: access
        )
    } catch {
        fatalError("legacy exact-account persist should not throw: \(error)")
    }
    expect(rotated?.source, access.source, "legacy rotation keeps exact service/account")
    expect(rotated?.accessToken, "new-legacy-token", "legacy account receives rotation")

    let calls = runner.capturedCalls()
    expect(calls.count, 5, "resolve and persist use the expected production keychain calls")
    expect(
        calls[3].arguments,
        ["find-generic-password", "-s", service, "-a", legacyAccount, "-w"],
        "persist reloads the exact discovered account"
    )
    let writeArguments = calls[4].arguments
    expect(writeArguments.first, "add-generic-password", "persist uses keychain update command")
    guard let accountIndex = writeArguments.firstIndex(of: "-a"),
          writeArguments.indices.contains(accountIndex + 1)
    else {
        fatalError("legacy production write must include an explicit account")
    }
    expect(writeArguments[accountIndex + 1], legacyAccount, "persist writes the discovered legacy account")
    expect(
        writeArguments.contains("different-current-user"),
        false,
        "persist must not migrate legacy credentials to the current user"
    )
}

func testClaudePersistRefusesServiceOnlySourceWithoutAccount() {
    let service = "Claude Code-credentials"
    let home = "/tmp/agent-halo-claude-unsafe-source-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    let storedData = claudeCheckCredential(accessToken: "old-token")
    let keychain = FakeUsageKeychain()
    try? keychain.write(
        service: service,
        account: nil,
        value: claudeCheckString(storedData)
    )
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["HOME": home]),
        files: FakeUsageFiles(contents: [path: storedData]),
        keychain: keychain
    )
    guard case .oauth(var ambiguous) = store.resolveAccess() else {
        fatalError("unsafe-source fixture should start from file OAuth")
    }
    ambiguous.source = .keychain(service: service, account: nil)

    let result = try? store.persist(
        rotation: ClaudeTokenRotation(
            accessToken: "must-not-write",
            refreshToken: "must-not-write-refresh",
            expiresAt: Date(timeIntervalSince1970: 5_000_000)
        ),
        replacing: ambiguous
    )
    expect(result == nil, true, "Claude persist refuses an ambiguous service-only source")
    let stored = try? keychain.read(service: service, account: nil)
    expect(
        stored,
        claudeCheckString(storedData),
        "refused service-only persist leaves the original credential unchanged"
    )
}

func testClaudePersistRefusesCredentialGenerationMismatch() {
    let home = "/tmp/agent-halo-claude-version-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    let files = FakeUsageFiles(contents: [
        path: claudeCheckCredential(accessToken: "old-token", refreshToken: "old-refresh"),
    ])
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["HOME": home]),
        files: files,
        keychain: FakeUsageKeychain()
    )
    guard case .oauth(let expected) = store.resolveAccess() else {
        fatalError("Claude version check should start from OAuth")
    }
    try? files.writeAtomically(
        claudeCheckCredential(accessToken: "external-login", refreshToken: "external-refresh"),
        to: path,
        preservingModeOf: path
    )
    let result = try? store.persist(
        rotation: ClaudeTokenRotation(
            accessToken: "refreshed-old-login",
            refreshToken: "refreshed-old-refresh",
            expiresAt: Date(timeIntervalSince1970: 3_000_000)
        ),
        replacing: expected
    )
    expect(result == nil, true, "external Claude re-login must invalidate credential generation")
    expect(files.capturedWrites().count, 1, "mismatched generation must not be overwritten")
}

func testClaudeRejectsNonProductionOAuthOverrides() {
    let home = "/tmp/agent-halo-claude-custom-oauth-\(UUID().uuidString)"
    let files = FakeUsageFiles(contents: [
        claudeCheckPath(home: home): claudeCheckCredential(accessToken: "stored-token"),
    ])
    for override in [
        ("CLAUDE_CODE_CUSTOM_OAUTH_URL", "https://custom.invalid"),
        ("CLAUDE_LOCAL_OAUTH_API_BASE", "http://localhost:8000"),
        ("ANTHROPIC_BASE_URL", "https://inference-proxy.invalid"),
        ("USE_STAGING_OAUTH", "1"),
    ] {
        let store = ClaudeAuthStore(
            environment: FakeUsageEnvironment(["HOME": home, override.0: override.1]),
            files: files,
            keychain: FakeUsageKeychain()
        )
        guard case .apiKey = store.resolveAccess() else {
            fatalError("non-production OAuth override \(override.0) must not use stored OAuth")
        }
    }
}

// MARK: - Codex usage checks

func codexUsageResponse(
    statusCode: Int = 200,
    headers: [String: String] = [:],
    _ body: String
) -> UsageHTTPResponse {
    UsageHTTPResponse(statusCode: statusCode, headers: headers, body: Data(body.utf8))
}

func expectCodexFailure(
    _ expected: UsageProviderFailure,
    _ message: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        fatalError("\(message): expected \(expected), got success")
    } catch let failure as UsageProviderFailure {
        expect(failure, expected, message)
    } catch {
        fatalError("\(message): unexpected error type")
    }
}

func runCodexUsageChecks() async {
    await testCodexUsageClientBuildsOnlyOfficialRequests()
    await testCodexUsageClientClassifiesFailures()
    testCodexUsageMapperPlansWindowsAndRestrictedFields()
    testCodexUsageMapperClassifiesInvalidResponses()
    await testCodexProviderAdoptsExternalSourceWithoutMigration()
    await testCodexProviderRefreshesProactively()
    await testCodexProviderRetriesOneUnauthorizedAndMigratesCache()
    await testCodexProviderStopsAfterSecondUnauthorized()
    await testCodexProviderRefreshCodesRequireSignIn()
    await testCodexProviderUsesRotatedTokenWhenWritebackFails()
}

func testCodexUsageClientBuildsOnlyOfficialRequests() async {
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: codexUsageResponse(#"{"plan_type":"plus"}"#))
    await http.enqueue(response: codexUsageResponse(#"{"access_token":"new-access","refresh_token":"new-refresh","id_token":"new-id"}"#))
    let client = CodexUsageClient(http: http, now: { Date(timeIntervalSince1970: 2_000_000_000) })

    _ = try? await client.fetchUsage(accessToken: "access token", accountID: "account-1")
    let refreshed = try? await client.refreshToken("refresh token+/=")
    expect(refreshed?.accessToken, "new-access", "refresh response access token")

    let requests = await http.capturedRequests
    expect(requests.count, 2, "client should issue exactly usage and refresh requests")
    expect(requests[0].method, "GET", "usage method")
    expect(requests[0].host, "chatgpt.com", "usage official host")
    expect(requests[0].path, "/backend-api/wham/usage", "usage official path")
    expect(requests[0].timeout, 10, "usage timeout")
    expect(requests[0].headers["authorization"], "Bearer access token", "usage bearer header")
    expect(requests[0].headers["chatgpt-account-id"], "account-1", "usage account header")

    expect(requests[1].method, "POST", "refresh method")
    expect(requests[1].host, "auth.openai.com", "refresh official host")
    expect(requests[1].path, "/oauth/token", "refresh official path")
    expect(requests[1].timeout, 15, "refresh timeout")
    expect(requests[1].headers["content-type"], "application/x-www-form-urlencoded", "refresh content type")
    let form = String(data: requests[1].body ?? Data(), encoding: .utf8) ?? ""
    expect(form.contains("grant_type=refresh_token"), "refresh form grant type")
    expect(form.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"), "refresh form client id")
    expect(form.contains("refresh_token=refresh%20token%2B%2F%3D"), "refresh token must be form encoded")
    expect(
        requests.allSatisfy {
            !$0.path.contains("reset-credit") && !$0.path.contains("balance") &&
                !$0.path.contains("spend") && ["chatgpt.com", "auth.openai.com"].contains($0.host)
        },
        "Codex client must call only the two approved official endpoints"
    )

    let noAccountHTTP = RecordingUsageHTTPClient()
    await noAccountHTTP.enqueue(response: codexUsageResponse(#"{"plan_type":"free"}"#))
    _ = try? await CodexUsageClient(http: noAccountHTTP).fetchUsage(accessToken: "a", accountID: nil)
    let noAccountRequests = await noAccountHTTP.capturedRequests
    expect(noAccountRequests.first?.headers["chatgpt-account-id"] == nil, "account header must be optional")
}

func testCodexUsageClientClassifiesFailures() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    let transport = RecordingUsageHTTPClient()
    await transport.enqueue(error: .network)
    await expectCodexFailure(.network, "transport failure") {
        _ = try await CodexUsageClient(http: transport, now: { now }).fetchUsage(accessToken: "a", accountID: nil)
    }

    let unavailable = RecordingUsageHTTPClient()
    await unavailable.enqueue(response: codexUsageResponse(statusCode: 503, "{}"))
    await expectCodexFailure(.serviceUnavailable, "5xx failure") {
        _ = try await CodexUsageClient(http: unavailable, now: { now }).fetchUsage(accessToken: "a", accountID: nil)
    }

    let limited = RecordingUsageHTTPClient()
    await limited.enqueue(response: codexUsageResponse(statusCode: 429, headers: ["Retry-After": "120"], "{}"))
    await expectCodexFailure(.rateLimited(retryAt: now.addingTimeInterval(120)), "Retry-After seconds") {
        _ = try await CodexUsageClient(http: limited, now: { now }).fetchUsage(accessToken: "a", accountID: nil)
    }

    let dateLimited = RecordingUsageHTTPClient()
    await dateLimited.enqueue(response: codexUsageResponse(
        statusCode: 429,
        headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"],
        "{}"
    ))
    let retryDate = Date(timeIntervalSince1970: 1_445_412_480)
    await expectCodexFailure(.rateLimited(retryAt: retryDate), "Retry-After HTTP date") {
        _ = try await CodexUsageClient(http: dateLimited, now: { now }).fetchUsage(accessToken: "a", accountID: nil)
    }

    let malformed = RecordingUsageHTTPClient()
    await malformed.enqueue(response: codexUsageResponse("not-json"))
    await expectCodexFailure(.invalidResponse, "malformed successful usage body") {
        _ = try await CodexUsageClient(http: malformed).fetchUsage(accessToken: "a", accountID: nil)
    }
}

func testCodexUsageMapperPlansWindowsAndRestrictedFields() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let accountKey = AccountCacheKey(providerID: .codex, digest: "mapper")
    let planCases: [(String, String?)] = [
        ("prolite", "Pro 5x"), ("pro", "Pro 20x"), ("free", "Free"),
        ("plus", "Plus"), ("", nil), ("team_plan", "Team Plan"),
    ]
    for (raw, expected) in planCases {
        let mapped = try? CodexUsageMapper.map(
            response: codexUsageResponse(
                #"{"plan_type":"\#(raw)","rate_limit":{"primary_window":{"used_percent":1}}}"#
            ),
            accountKey: accountKey,
            now: now
        )
        expect(mapped?.planName, expected, "Codex plan mapping for \(raw)")
    }

    let response = codexUsageResponse("""
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "used_percent": -5,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 60
        },
        "secondary_window": {
          "used_percent": 140,
          "limit_window_seconds": 604800,
          "reset_at": "2033-05-18T03:35:00Z"
        }
      },
      "additional_rate_limits": [{"rate_limit":{"primary_window":{"used_percent":55}}}],
      "credits": {"balance": 100},
      "rate_limit_reset_credits": {"available_count": 9},
      "balance": 100,
      "spend": 50
    }
    """)
    guard let mapped = try? CodexUsageMapper.map(response: response, accountKey: accountKey, now: now) else {
        fatalError("valid Codex usage should map")
    }
    expect(mapped.windows.count, 2, "mapper must expose exactly the two supported windows")
    expect(mapped.windows[0].kind, .session, "primary 5-hour window kind")
    expect(mapped.windows[0].usedPercent, 0, "used percent lower clamp")
    expect(mapped.windows[0].duration, 18_000, "session duration")
    expect(mapped.windows[0].resetsAt, now.addingTimeInterval(60), "reset-after seconds")
    expect(mapped.windows[1].kind, .weekly, "secondary weekly window kind")
    expect(mapped.windows[1].usedPercent, 100, "used percent upper clamp")
    expect(mapped.windows[1].duration, 604_800, "weekly duration")
    expect(mapped.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2033-05-18T03:35:00Z"), "ISO reset time")

    let weeklyOnly = try? CodexUsageMapper.map(
        response: codexUsageResponse("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800}}}
        """),
        accountKey: accountKey,
        now: now
    )
    expect(weeklyOnly?.windows.count, 1, "missing secondary must stay absent")
    expect(weeklyOnly?.windows.first?.kind, .weekly, "sole 7-day primary must reclassify as weekly")
}

func testCodexUsageMapperClassifiesInvalidResponses() {
    let key = AccountCacheKey(providerID: .codex, digest: "invalid")
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let cases: [(UsageHTTPResponse, UsageProviderFailure)] = [
        (codexUsageResponse("{}"), .invalidResponse),
        (codexUsageResponse(#"{"credits":{"balance":100}}"#), .invalidResponse),
        (codexUsageResponse(statusCode: 401, "{}"), .signInAgain),
        (codexUsageResponse(statusCode: 503, "{}"), .serviceUnavailable),
    ]
    for (response, expected) in cases {
        do {
            _ = try CodexUsageMapper.map(response: response, accountKey: key, now: now)
            fatalError("invalid Codex response should fail")
        } catch let failure as UsageProviderFailure {
            expect(failure, expected, "Codex mapper failure classification")
        } catch {
            fatalError("unexpected Codex mapper error")
        }
    }
}

func makeCodexProviderFixture(
    token: String,
    refreshToken: String = "refresh-old",
    accountID: String? = nil,
    now: Date,
    files: (any UsageFileAccessing)? = nil
) -> (CodexAuthStore, OAuthAccess, any UsageFileAccessing, String) {
    let home = "/tmp/agent-halo-provider-\(UUID().uuidString)"
    let path = codexCheckAuthPath(home: home)
    var tokens: [String: Any] = ["access_token": token, "refresh_token": refreshToken]
    if let accountID { tokens["account_id"] = accountID }
    let initial = codexCheckJSON(["tokens": tokens, "last_refresh": "2030-01-01T00:00:00Z"])
    let resolvedFiles: any UsageFileAccessing = files ?? FakeUsageFiles(contents: [path: initial])
    if let custom = resolvedFiles as? CodexCheckFailingFiles {
        custom.setData(initial, at: path)
    }
    let store = CodexAuthStore(
        environment: FakeUsageEnvironment(["HOME": home]),
        files: resolvedFiles,
        keychain: FakeUsageKeychain(),
        now: { now }
    )
    guard case .oauth(let access) = store.resolveAccess() else {
        fatalError("provider fixture should resolve OAuth")
    }
    return (store, access, resolvedFiles, path)
}

func testCodexProviderAdoptsExternalSourceWithoutMigration() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let oldJWT = codexCheckJWT(exp: now.addingTimeInterval(60).timeIntervalSince1970)
    let fixture = makeCodexProviderFixture(token: oldJWT, now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let externalJWT = codexCheckJWT(exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
    try? files.writeAtomically(
        codexCheckJSON(["tokens": ["access_token": externalJWT, "refresh_token": "external-refresh"]]),
        to: fixture.3,
        preservingModeOf: fixture.3
    )
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: codexUsageResponse(#"{"plan_type":"plus"}"#))
    let provider = CodexUsageProvider(authStore: fixture.0, usageClient: CodexUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "external source adoption should succeed")
    expect(result.migrateCacheFrom == nil, "external source adoption must not migrate cache")
    expect(requests.count, 1, "fresh external token must avoid refresh")
    expect(requests.first?.headers["authorization"], "Bearer \(externalJWT)", "usage must use external token")
}

func testCodexProviderRefreshesProactively() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let expiring = codexCheckJWT(exp: now.addingTimeInterval(60).timeIntervalSince1970)
    let fixture = makeCodexProviderFixture(token: expiring, accountID: "stable-account", now: now)
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: codexUsageResponse(#"{"access_token":"proactive-access","refresh_token":"proactive-refresh"}"#))
    await http.enqueue(response: codexUsageResponse(#"{"plan_type":"free"}"#))
    let provider = CodexUsageProvider(authStore: fixture.0, usageClient: CodexUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "proactive refresh should succeed")
    expect(requests.map(\.path), ["/oauth/token", "/backend-api/wham/usage"], "proactive refresh order")
    expect(requests.last?.headers["authorization"], "Bearer proactive-access", "proactive token must serve usage")
    expect(result.migrateCacheFrom == nil, "stable account id should not require cache migration")
}

func testCodexProviderRetriesOneUnauthorizedAndMigratesCache() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fresh = codexCheckJWT(exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
    let fixture = makeCodexProviderFixture(token: fresh, now: now)
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: codexUsageResponse(statusCode: 401, "{}"))
    await http.enqueue(response: codexUsageResponse(#"{"access_token":"retry-access","refresh_token":"retry-refresh"}"#))
    await http.enqueue(response: codexUsageResponse(#"{"plan_type":"pro"}"#))
    let provider = CodexUsageProvider(authStore: fixture.0, usageClient: CodexUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "first 401 should refresh and retry")
    expect(
        requests.map(\.path),
        ["/backend-api/wham/usage", "/oauth/token", "/backend-api/wham/usage"],
        "401 retry request order"
    )
    expect(requests.last?.headers["authorization"], "Bearer retry-access", "retry must use rotated token")
    expect(result.migrateCacheFrom, fixture.1.accountKey, "internal rotation should return old cache key")
}

func testCodexProviderStopsAfterSecondUnauthorized() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fresh = codexCheckJWT(exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
    let fixture = makeCodexProviderFixture(token: fresh, now: now)
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: codexUsageResponse(statusCode: 401, "{}"))
    await http.enqueue(response: codexUsageResponse(#"{"access_token":"retry-access"}"#))
    await http.enqueue(response: codexUsageResponse(statusCode: 401, "{}"))
    let provider = CodexUsageProvider(authStore: fixture.0, usageClient: CodexUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure, .signInAgain, "second 401 should require sign in")
    expect(requests.filter { $0.path == "/backend-api/wham/usage" }.count, 2, "usage must retry at most once")
}

func testCodexProviderRefreshCodesRequireSignIn() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    for code in ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"] {
        let fresh = codexCheckJWT(exp: now.addingTimeInterval(3_600).timeIntervalSince1970)
        let fixture = makeCodexProviderFixture(token: fresh, now: now)
        let http = RecordingUsageHTTPClient()
        await http.enqueue(response: codexUsageResponse(statusCode: 401, "{}"))
        await http.enqueue(response: codexUsageResponse(statusCode: 400, #"{"error":{"code":"\#(code)"}}"#))
        let provider = CodexUsageProvider(authStore: fixture.0, usageClient: CodexUsageClient(http: http), now: { now })
        let result = await provider.refresh(using: .oauth(fixture.1))
        expect(result.failure, .signInAgain, "refresh code \(code) should require sign in")
    }
}

final class CodexCheckFailingFiles: UsageFileAccessing, @unchecked Sendable {
    private let data = LockedBox<[String: Data]>([:])

    func setData(_ value: Data, at path: String) {
        data.withValue { $0[path] = value }
    }

    func readDataIfPresent(at path: String) throws -> Data? {
        data.value[path]
    }

    func writeAtomically(_ data: Data, to path: String, preservingModeOf existingPath: String?) throws {
        throw UsageProviderFailure.network
    }
}

func testCodexProviderUsesRotatedTokenWhenWritebackFails() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let files = CodexCheckFailingFiles()
    let expiring = codexCheckJWT(exp: now.addingTimeInterval(60).timeIntervalSince1970)
    let fixture = makeCodexProviderFixture(token: expiring, now: now, files: files)
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: codexUsageResponse(#"{"access_token":"memory-access","refresh_token":"memory-refresh"}"#))
    await http.enqueue(response: codexUsageResponse(#"{"plan_type":"plus"}"#))
    let provider = CodexUsageProvider(authStore: fixture.0, usageClient: CodexUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "writeback failure must not fail current usage request")
    expect(requests.last?.headers["authorization"], "Bearer memory-access", "in-memory token must serve current request")
    expect(result.migrateCacheFrom, fixture.1.accountKey, "in-memory internal rotation should still migrate cache")
}

// MARK: - Claude usage checks

func claudeUsageResponse(
    statusCode: Int = 200,
    headers: [String: String] = [:],
    _ body: String
) -> UsageHTTPResponse {
    UsageHTTPResponse(statusCode: statusCode, headers: headers, body: Data(body.utf8))
}

func runClaudeUsageChecks() async {
    await testClaudeUsageClientBuildsOnlyOfficialRequests()
    testClaudeUsageMapperPlansWindowsAndRestrictedFields()
    testClaudeUsageMapperClassifiesFailuresAndRetryAfter()
    await testClaudeProviderScopeFailureSkipsHTTP()
    await testClaudeProviderRejectsUnderScopedInitialReload()
    await testClaudeProviderAdoptsExternalSourceWithoutMigration()
    await testClaudeProviderAdoptsExternalSourceChangedDuringRefresh()
    await testClaudeProviderAdoptsExternalSourceAfterRefreshFailure()
    await testClaudeProviderRejectsUnderScopedRefreshChange()
    await testClaudeProviderAdoptsExternalSourceChangedDuringUsage()
    await testClaudeProviderAdoptsExternalSourceAfterUsageTransportFailure()
    await testClaudeProviderRejectsUnderScopedUsageChange()
    await testClaudeProviderAdoptsExternalSourceChangedDuringUnauthorizedRetry()
    await testClaudeProviderRefreshesProactively()
    await testClaudeProviderRetriesOneUnauthorizedAndMigratesCache()
    await testClaudeProviderClassifiesRefreshFailures()
    await testClaudeProviderUsesRotatedTokenWhenWritebackFails()
}

func testClaudeUsageClientBuildsOnlyOfficialRequests() async {
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: claudeUsageResponse(#"{"five_hour":{"utilization":1}}"#))
    await http.enqueue(response: claudeUsageResponse(#"{"access_token":"new-access"}"#))
    let client = ClaudeUsageClient(http: http)

    _ = try? await client.fetchUsage(accessToken: " access token ")
    _ = try? await client.refreshToken("refresh token")

    let requests = await http.capturedRequests
    expect(requests.count, 2, "Claude client should issue exactly usage and refresh requests")
    expect(requests[0].method, "GET", "Claude usage method")
    expect(requests[0].host, "api.anthropic.com", "Claude usage official host")
    expect(requests[0].path, "/api/oauth/usage", "Claude usage official path")
    expect(requests[0].timeout, 10, "Claude usage timeout")
    expect(requests[0].headers["authorization"], "Bearer access token", "Claude usage bearer header")
    expect(requests[0].headers["accept"], "application/json", "Claude usage accept header")
    expect(requests[0].headers["content-type"], "application/json", "Claude usage content type")
    expect(requests[0].headers["anthropic-beta"], "oauth-2025-04-20", "Claude OAuth beta header")
    expect(requests[0].headers["user-agent"], "claude-code/2.1.69", "Claude Code user agent")

    expect(requests[1].method, "POST", "Claude refresh method")
    expect(requests[1].host, "platform.claude.com", "Claude refresh official host")
    expect(requests[1].path, "/v1/oauth/token", "Claude refresh official path")
    expect(requests[1].timeout, 15, "Claude refresh timeout")
    expect(requests[1].headers["content-type"], "application/json", "Claude refresh content type")
    let body = (try? JSONSerialization.jsonObject(with: requests[1].body ?? Data())) as? [String: String]
    expect(body?["grant_type"], "refresh_token", "Claude refresh grant type")
    expect(body?["refresh_token"], "refresh token", "Claude refresh token")
    expect(body?["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "Claude refresh client id")
    expect(
        body?["scope"],
        "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
        "Claude refresh must request the complete official scope set"
    )
    expect(
        requests.allSatisfy { ["api.anthropic.com", "platform.claude.com"].contains($0.host) },
        "Claude client must call only approved official endpoints"
    )
}

func testClaudeUsageMapperPlansWindowsAndRestrictedFields() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let accountKey = AccountCacheKey(providerID: .claude, digest: "mapper")
    expect(ClaudeUsageMapper.formatPlan(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"), "Max 5x", "Claude Max plan")
    expect(ClaudeUsageMapper.formatPlan(subscriptionType: "pro", rateLimitTier: nil), "Pro", "Claude Pro plan")
    expect(ClaudeUsageMapper.formatPlan(subscriptionType: "  ", rateLimitTier: "default_5x"), nil, "blank Claude plan")

    let response = claudeUsageResponse("""
    {
      "five_hour": {"utilization": -5, "resets_at": "2033-05-18T03:35:00Z"},
      "seven_day": {"utilization": 140, "resets_at": 2000001000},
      "seven_day_sonnet": {"utilization": 55, "resets_at": 2000002000},
      "limits": [{"kind":"weekly_scoped","percent":66}],
      "extra_usage": {"is_enabled":true,"used_credits":500,"monthly_limit":1000},
      "balance": 999
    }
    """)
    let hint = OAuthPlanHint(subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
    guard let mapped = try? ClaudeUsageMapper.map(
        response: response,
        accountKey: accountKey,
        planHint: hint,
        now: now
    ) else {
        fatalError("valid Claude usage should map")
    }
    expect(mapped.planName, "Max 5x", "Claude plan comes from credential hints")
    expect(mapped.windows.count, 2, "Claude mapper exposes exactly five-hour and seven-day windows")
    expect(mapped.windows[0].kind, .session, "Claude five-hour window kind")
    expect(mapped.windows[0].usedPercent, 0, "Claude utilization lower clamp")
    expect(mapped.windows[0].duration, 18_000, "Claude five-hour duration")
    expect(mapped.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2033-05-18T03:35:00Z"), "Claude ISO reset")
    expect(mapped.windows[1].kind, .weekly, "Claude seven-day window kind")
    expect(mapped.windows[1].usedPercent, 100, "Claude utilization upper clamp")
    expect(mapped.windows[1].duration, 604_800, "Claude seven-day duration")
    expect(mapped.windows[1].resetsAt, Date(timeIntervalSince1970: 2_000_001_000), "Claude epoch-second reset")

    let milliseconds = try? ClaudeUsageMapper.map(
        response: claudeUsageResponse(#"{"seven_day":{"utilization":3,"resets_at":2000001000000}}"#),
        accountKey: accountKey,
        planHint: nil,
        now: now
    )
    expect(milliseconds?.windows.first?.resetsAt, Date(timeIntervalSince1970: 2_000_001_000), "Claude epoch-millisecond reset")

    let microsecondsWithoutZone = try? ClaudeUsageMapper.map(
        response: claudeUsageResponse(#"{"five_hour":{"utilization":3,"resets_at":"2099-06-01T12:00:00.123456"}}"#),
        accountKey: accountKey,
        planHint: nil,
        now: now
    )
    let expectedFormatter = ISO8601DateFormatter()
    expectedFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let expectedMicroseconds = expectedFormatter.date(from: "2099-06-01T12:00:00.123Z") else {
        fatalError("Claude microsecond fixture should produce a valid expected date")
    }
    expect(
        microsecondsWithoutZone?.windows.first?.resetsAt,
        expectedMicroseconds,
        "Claude microsecond reset without timezone assumes UTC"
    )
}

func testClaudeUsageMapperClassifiesFailuresAndRetryAfter() {
    let key = AccountCacheKey(providerID: .claude, digest: "invalid")
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let limited = claudeUsageResponse(statusCode: 429, headers: ["Retry-After": "120"], "{}")
    expect(ClaudeUsageMapper.retryAfterDate(limited, now: now), now.addingTimeInterval(120), "Claude Retry-After seconds")
    let dated = claudeUsageResponse(
        statusCode: 429,
        headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"],
        "{}"
    )
    expect(ClaudeUsageMapper.retryAfterDate(dated, now: now), Date(timeIntervalSince1970: 1_445_412_480), "Claude Retry-After HTTP date")

    let cases: [(UsageHTTPResponse, UsageProviderFailure)] = [
        (claudeUsageResponse("{}"), .invalidResponse),
        (claudeUsageResponse(#"{"seven_day_sonnet":{"utilization":1},"extra_usage":{"used_credits":1}}"#), .invalidResponse),
        (claudeUsageResponse(statusCode: 401, "{}"), .signInAgain),
        (limited, .rateLimited(retryAt: now.addingTimeInterval(120))),
        (claudeUsageResponse(statusCode: 503, "{}"), .serviceUnavailable),
    ]
    for (response, expected) in cases {
        do {
            _ = try ClaudeUsageMapper.map(response: response, accountKey: key, planHint: nil, now: now)
            fatalError("invalid Claude response should fail")
        } catch let failure as UsageProviderFailure {
            expect(failure, expected, "Claude mapper failure classification")
        } catch {
            fatalError("unexpected Claude mapper error")
        }
    }
}

func makeClaudeProviderFixture(
    accessToken: String,
    refreshToken: String = "refresh-old",
    expiresAt: Date,
    subscriptionType: String? = "pro",
    rateLimitTier: String? = nil,
    scopes: [String]? = ["user:profile"],
    now: Date,
    files: (any UsageFileAccessing)? = nil
) -> (ClaudeAuthStore, OAuthAccess, any UsageFileAccessing, String) {
    let home = "/tmp/agent-halo-claude-provider-\(UUID().uuidString)"
    let path = claudeCheckPath(home: home)
    let initial = claudeCheckCredential(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAtMilliseconds: expiresAt.timeIntervalSince1970 * 1000,
        subscriptionType: subscriptionType,
        rateLimitTier: rateLimitTier,
        scopes: scopes
    )
    let resolvedFiles: any UsageFileAccessing = files ?? FakeUsageFiles(contents: [path: initial])
    if let failing = resolvedFiles as? CodexCheckFailingFiles { failing.setData(initial, at: path) }
    let store = ClaudeAuthStore(
        environment: FakeUsageEnvironment(["HOME": home]),
        files: resolvedFiles,
        keychain: FakeUsageKeychain(),
        now: { now }
    )
    guard let access = store.reload(source: .file(path: path)) else {
        fatalError("Claude provider fixture should parse the exact credential source")
    }
    return (store, access, resolvedFiles, path)
}

func testClaudeProviderScopeFailureSkipsHTTP() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(
        accessToken: "under-scoped",
        expiresAt: now.addingTimeInterval(3_600),
        scopes: ["user:inference"],
        now: now
    )
    let http = RecordingUsageHTTPClient()
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })
    let access = await provider.resolveAccess(accountKey: nil)
    guard case .oauthNeedsSignIn = access else { fatalError("missing user:profile should require sign in") }
    let result = await provider.refresh(using: access)
    expect(result.failure, .signInAgain, "under-scoped Claude OAuth requires sign in")
    expect(await http.capturedRequests.count, 0, "under-scoped Claude OAuth must not reach HTTP")
}

func testClaudeProviderRejectsUnderScopedInitialReload() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "initial-allowed", expiresAt: now.addingTimeInterval(3_600), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    try? files.writeAtomically(
        claudeCheckCredential(
            accessToken: "initial-under-scoped",
            refreshToken: "initial-under-refresh",
            expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
            scopes: ["user:inference"]
        ),
        to: fixture.3,
        preservingModeOf: fixture.3
    )
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: claudeUsageResponse(#"{"five_hour":{"utilization":99}}"#))
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    expect(result.failure, .signInAgain, "under-scoped exact-source reload must require sign in")
    expect(result.migrateCacheFrom == nil, "under-scoped exact-source reload must not migrate cache")
    expect(await http.capturedRequests.count, 0, "under-scoped exact-source reload must skip HTTP")
}

func testClaudeProviderAdoptsExternalSourceWithoutMigration() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "old-access", expiresAt: now.addingTimeInterval(60), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    try? files.writeAtomically(
        claudeCheckCredential(
            accessToken: "external-access",
            refreshToken: "external-refresh",
            expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_5x"
        ),
        to: fixture.3,
        preservingModeOf: fixture.3
    )
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: claudeUsageResponse(#"{"five_hour":{"utilization":9}}"#))
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "external Claude source adoption should succeed")
    expect(result.migrateCacheFrom == nil, "external Claude login change must not migrate cache")
    expect(result.snapshot?.planName, "Max 5x", "external Claude plan hint should be adopted")
    expect(requests.count, 1, "fresh external Claude token avoids refresh")
    expect(requests.first?.headers["authorization"], "Bearer external-access", "Claude usage uses exact-source reread")
}

actor ClaudeCheckMutatingHTTPClient: UsageHTTPClient {
    private var responses: [UsageHTTPResponse]
    private let mutationPath: String
    private let mutation: @Sendable () -> Void
    private let mutationMatchNumber: Int
    private var matchingRequestCount = 0
    private(set) var capturedRequests: [UsageHTTPRequest] = []

    init(
        responses: [UsageHTTPResponse],
        mutationPath: String,
        mutationMatchNumber: Int = 1,
        mutation: @escaping @Sendable () -> Void
    ) {
        self.responses = responses
        self.mutationPath = mutationPath
        self.mutationMatchNumber = mutationMatchNumber
        self.mutation = mutation
    }

    func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse {
        capturedRequests.append(request)
        if request.path == mutationPath {
            matchingRequestCount += 1
            if matchingRequestCount == mutationMatchNumber { mutation() }
        }
        guard !responses.isEmpty else {
            throw UsageProviderFailure.invalidResponse
        }
        return responses.removeFirst()
    }
}

enum ClaudeCheckHTTPOutcome: Sendable {
    case response(UsageHTTPResponse)
    case failure(UsageProviderFailure)
}

actor ClaudeCheckMutatingOutcomeHTTPClient: UsageHTTPClient {
    private var outcomes: [ClaudeCheckHTTPOutcome]
    private let mutationPath: String
    private let mutation: @Sendable () -> Void
    private(set) var capturedRequests: [UsageHTTPRequest] = []

    init(
        outcomes: [ClaudeCheckHTTPOutcome],
        mutationPath: String,
        mutation: @escaping @Sendable () -> Void
    ) {
        self.outcomes = outcomes
        self.mutationPath = mutationPath
        self.mutation = mutation
    }

    func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse {
        capturedRequests.append(request)
        if request.path == mutationPath { mutation() }
        guard !outcomes.isEmpty else { throw UsageProviderFailure.invalidResponse }
        switch outcomes.removeFirst() {
        case .response(let response):
            return response
        case .failure(let failure):
            throw failure
        }
    }
}

func testClaudeProviderAdoptsExternalSourceChangedDuringRefresh() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "expiring-old", expiresAt: now.addingTimeInterval(60), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let externalData = claudeCheckCredential(
        accessToken: "external-during-refresh",
        refreshToken: "external-refresh",
        expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_5x"
    )
    let http = ClaudeCheckMutatingHTTPClient(
        responses: [
            claudeUsageResponse(#"{"access_token":"stale-rotation","refresh_token":"stale-refresh","expires_in":3600}"#),
            claudeUsageResponse(#"{"five_hour":{"utilization":6}}"#),
        ],
        mutationPath: "/v1/oauth/token",
        mutation: {
            try? files.writeAtomically(externalData, to: fixture.3, preservingModeOf: fixture.3)
        }
    )
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "Claude source change during refresh should adopt the external login")
    expect(result.migrateCacheFrom == nil, "external Claude login during refresh must not migrate old cache")
    expect(result.snapshot?.planName, "Max 5x", "external plan hint during refresh should be adopted")
    expect(
        requests.last?.headers["authorization"],
        "Bearer external-during-refresh",
        "usage after generation mismatch must use the external credential"
    )
}

func testClaudeProviderAdoptsExternalSourceAfterRefreshFailure() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "expiring-invalid-grant", expiresAt: now.addingTimeInterval(60), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let externalData = claudeCheckCredential(
        accessToken: "external-after-invalid-grant",
        refreshToken: "external-invalid-grant-refresh",
        expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_5x"
    )
    let http = ClaudeCheckMutatingOutcomeHTTPClient(
        outcomes: [
            .response(claudeUsageResponse(statusCode: 400, #"{"error":"invalid_grant"}"#)),
            .response(claudeUsageResponse(#"{"five_hour":{"utilization":13}}"#)),
        ],
        mutationPath: "/v1/oauth/token",
        mutation: {
            try? files.writeAtomically(externalData, to: fixture.3, preservingModeOf: fixture.3)
        }
    )
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "external Claude login during invalid_grant refresh should be adopted")
    expect(result.migrateCacheFrom == nil, "external login after invalid_grant clears migration")
    expect(result.snapshot?.planName, "Max 5x", "invalid_grant race snapshot uses external plan")
    expect(
        requests.last?.headers["authorization"],
        "Bearer external-after-invalid-grant",
        "invalid_grant race restarts with external credential"
    )
}

func testClaudeProviderRejectsUnderScopedRefreshChange() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "refresh-allowed", expiresAt: now.addingTimeInterval(60), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let underScoped = claudeCheckCredential(
        accessToken: "refresh-under-scoped",
        refreshToken: "refresh-under-refresh",
        expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
        scopes: ["user:inference"]
    )
    let http = ClaudeCheckMutatingHTTPClient(
        responses: [
            claudeUsageResponse(#"{"access_token":"old-refresh-result","refresh_token":"old-refresh-next","expires_in":3600}"#),
        ],
        mutationPath: "/v1/oauth/token",
        mutation: {
            try? files.writeAtomically(underScoped, to: fixture.3, preservingModeOf: fixture.3)
        }
    )
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure, .signInAgain, "under-scoped refresh generation must require sign in")
    expect(result.migrateCacheFrom == nil, "under-scoped refresh generation must not migrate cache")
    expect(requests.count, 1, "under-scoped refresh generation must stop after refresh response")
    expect(requests.first?.path, "/v1/oauth/token", "under-scoped refresh fixture request")
}

func testClaudeProviderAdoptsExternalSourceChangedDuringUsage() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "old-usage-access", expiresAt: now.addingTimeInterval(3_600), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let externalData = claudeCheckCredential(
        accessToken: "external-during-usage",
        refreshToken: "external-usage-refresh",
        expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_5x"
    )
    let http = ClaudeCheckMutatingHTTPClient(
        responses: [
            claudeUsageResponse(#"{"five_hour":{"utilization":91}}"#),
            claudeUsageResponse(#"{"five_hour":{"utilization":8}}"#),
        ],
        mutationPath: "/api/oauth/usage",
        mutation: {
            try? files.writeAtomically(externalData, to: fixture.3, preservingModeOf: fixture.3)
        }
    )
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "Claude source change during usage should adopt the external login")
    expect(result.migrateCacheFrom == nil, "external Claude login during usage must not migrate old cache")
    expect(result.snapshot?.planName, "Max 5x", "usage-race snapshot must use external plan hint")
    expect(result.snapshot?.windows.first?.usedPercent, 8, "usage-race snapshot must discard the old account response")
    expect(requests.count, 2, "usage-race adoption should retry once with the external credential")
    expect(
        requests.last?.headers["authorization"],
        "Bearer external-during-usage",
        "usage-race retry must use the external credential"
    )
}

func testClaudeProviderAdoptsExternalSourceAfterUsageTransportFailure() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "old-transport-access", expiresAt: now.addingTimeInterval(3_600), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let externalData = claudeCheckCredential(
        accessToken: "external-after-network",
        refreshToken: "external-network-refresh",
        expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_5x"
    )
    let http = ClaudeCheckMutatingOutcomeHTTPClient(
        outcomes: [
            .failure(.network),
            .response(claudeUsageResponse(#"{"seven_day":{"utilization":14}}"#)),
        ],
        mutationPath: "/api/oauth/usage",
        mutation: {
            try? files.writeAtomically(externalData, to: fixture.3, preservingModeOf: fixture.3)
        }
    )
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "external Claude login during usage transport failure should be adopted")
    expect(result.migrateCacheFrom == nil, "external login after usage transport failure clears migration")
    expect(result.snapshot?.planName, "Max 5x", "transport-race snapshot uses external plan")
    expect(
        requests.last?.headers["authorization"],
        "Bearer external-after-network",
        "transport-race retry uses external credential"
    )

    let unchangedFixture = makeClaudeProviderFixture(
        accessToken: "unchanged-network",
        expiresAt: now.addingTimeInterval(3_600),
        now: now
    )
    let unchangedHTTP = RecordingUsageHTTPClient()
    await unchangedHTTP.enqueue(error: .network)
    let unchangedProvider = ClaudeUsageProvider(
        authStore: unchangedFixture.0,
        usageClient: ClaudeUsageClient(http: unchangedHTTP),
        now: { now }
    )
    let unchangedResult = await unchangedProvider.refresh(using: .oauth(unchangedFixture.1))
    expect(unchangedResult.failure, .network, "unchanged Claude usage transport failure stays network")
}

func testClaudeProviderRejectsUnderScopedUsageChange() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "usage-allowed", expiresAt: now.addingTimeInterval(3_600), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let underScoped = claudeCheckCredential(
        accessToken: "usage-under-scoped",
        refreshToken: "usage-under-refresh",
        expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
        scopes: ["user:inference"]
    )
    let http = ClaudeCheckMutatingHTTPClient(
        responses: [claudeUsageResponse(#"{"five_hour":{"utilization":77}}"#)],
        mutationPath: "/api/oauth/usage",
        mutation: {
            try? files.writeAtomically(underScoped, to: fixture.3, preservingModeOf: fixture.3)
        }
    )
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure, .signInAgain, "under-scoped usage generation must require sign in")
    expect(result.migrateCacheFrom == nil, "under-scoped usage generation must not migrate cache")
    expect(requests.count, 1, "under-scoped usage generation must not retry Usage HTTP")
}

func testClaudeProviderAdoptsExternalSourceChangedDuringUnauthorizedRetry() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "old-retry-access", expiresAt: now.addingTimeInterval(3_600), now: now)
    guard let files = fixture.2 as? FakeUsageFiles else { fatalError("expected fake files") }
    let externalData = claudeCheckCredential(
        accessToken: "external-during-retry",
        refreshToken: "external-retry-refresh",
        expiresAtMilliseconds: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000,
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_5x"
    )
    let http = ClaudeCheckMutatingHTTPClient(
        responses: [
            claudeUsageResponse(statusCode: 401, "{}"),
            claudeUsageResponse(#"{"access_token":"internal-retry","refresh_token":"internal-refresh","expires_in":3600}"#),
            claudeUsageResponse(statusCode: 401, "{}"),
            claudeUsageResponse(#"{"five_hour":{"utilization":12}}"#),
        ],
        mutationPath: "/api/oauth/usage",
        mutationMatchNumber: 2,
        mutation: {
            try? files.writeAtomically(externalData, to: fixture.3, preservingModeOf: fixture.3)
        }
    )
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "external Claude login during second 401 should be adopted")
    expect(result.migrateCacheFrom == nil, "external login during second 401 clears internal migration")
    expect(result.snapshot?.planName, "Max 5x", "second-401 race snapshot uses external plan")
    expect(
        requests.last?.headers["authorization"],
        "Bearer external-during-retry",
        "second-401 race restarts with external credential"
    )
}

func testClaudeProviderRefreshesProactively() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "expiring", expiresAt: now.addingTimeInterval(60), now: now)
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: claudeUsageResponse(#"{"access_token":"proactive-access","refresh_token":"proactive-refresh","expires_in":3600}"#))
    await http.enqueue(response: claudeUsageResponse(#"{"seven_day":{"utilization":7}}"#))
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "Claude proactive refresh should succeed")
    expect(requests.map(\.path), ["/v1/oauth/token", "/api/oauth/usage"], "Claude proactive refresh order")
    expect(requests.last?.headers["authorization"], "Bearer proactive-access", "Claude proactive token serves usage")
    expect(result.migrateCacheFrom, fixture.1.accountKey, "Claude internal proactive rotation migrates cache binding")
}

func testClaudeProviderRetriesOneUnauthorizedAndMigratesCache() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let fixture = makeClaudeProviderFixture(accessToken: "fresh", expiresAt: now.addingTimeInterval(3_600), now: now)
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: claudeUsageResponse(statusCode: 401, "{}"))
    await http.enqueue(response: claudeUsageResponse(#"{"access_token":"retry-access","refresh_token":"retry-refresh","expires_in":3600}"#))
    await http.enqueue(response: claudeUsageResponse(#"{"five_hour":{"utilization":4}}"#))
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "first Claude 401 refreshes and retries")
    expect(requests.map(\.path), ["/api/oauth/usage", "/v1/oauth/token", "/api/oauth/usage"], "Claude 401 retry order")
    expect(requests.last?.headers["authorization"], "Bearer retry-access", "Claude retry uses rotated token")
    expect(result.migrateCacheFrom, fixture.1.accountKey, "Claude internal 401 rotation migrates cache binding")

    let secondFixture = makeClaudeProviderFixture(accessToken: "fresh-2", expiresAt: now.addingTimeInterval(3_600), now: now)
    let secondHTTP = RecordingUsageHTTPClient()
    await secondHTTP.enqueue(response: claudeUsageResponse(statusCode: 401, "{}"))
    await secondHTTP.enqueue(response: claudeUsageResponse(#"{"access_token":"retry-once","expires_in":3600}"#))
    await secondHTTP.enqueue(response: claudeUsageResponse(statusCode: 401, "{}"))
    let secondProvider = ClaudeUsageProvider(authStore: secondFixture.0, usageClient: ClaudeUsageClient(http: secondHTTP), now: { now })
    let secondResult = await secondProvider.refresh(using: .oauth(secondFixture.1))
    expect(secondResult.failure, .signInAgain, "second Claude 401 requires sign in")
    let secondRequests = await secondHTTP.capturedRequests
    expect(secondRequests.filter { $0.path == "/api/oauth/usage" }.count, 2, "Claude usage retries at most once")
}

func testClaudeProviderClassifiesRefreshFailures() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    for (body, expected) in [
        (#"{"error":"invalid_grant"}"#, UsageProviderFailure.signInAgain),
        (#"{"error":"proxy_failure"}"#, UsageProviderFailure.invalidResponse),
    ] {
        let fixture = makeClaudeProviderFixture(accessToken: "refresh-classification", expiresAt: now.addingTimeInterval(60), now: now)
        let http = RecordingUsageHTTPClient()
        await http.enqueue(response: claudeUsageResponse(statusCode: 400, body))
        let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })
        let result = await provider.refresh(using: .oauth(fixture.1))
        expect(result.failure, expected, "Claude refresh failure taxonomy")
    }
}

func testClaudeProviderUsesRotatedTokenWhenWritebackFails() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let files = CodexCheckFailingFiles()
    let fixture = makeClaudeProviderFixture(
        accessToken: "expiring",
        expiresAt: now.addingTimeInterval(60),
        now: now,
        files: files
    )
    let http = RecordingUsageHTTPClient()
    await http.enqueue(response: claudeUsageResponse(#"{"access_token":"memory-access","refresh_token":"memory-refresh","expires_in":3600}"#))
    await http.enqueue(response: claudeUsageResponse(#"{"five_hour":{"utilization":2}}"#))
    let provider = ClaudeUsageProvider(authStore: fixture.0, usageClient: ClaudeUsageClient(http: http), now: { now })

    let result = await provider.refresh(using: .oauth(fixture.1))
    let requests = await http.capturedRequests
    expect(result.failure == nil, "Claude writeback failure must not fail current request")
    expect(requests.last?.headers["authorization"], "Bearer memory-access", "Claude in-memory token serves current request")
    expect(result.migrateCacheFrom, fixture.1.accountKey, "Claude in-memory internal rotation migrates cache")
}
