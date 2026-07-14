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
    await runCodexUsageChecks()
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
