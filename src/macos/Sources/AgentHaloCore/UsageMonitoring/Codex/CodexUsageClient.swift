import Foundation

public struct CodexRefreshResponse: Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?

    public init(accessToken: String, refreshToken: String?, idToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
    }
}

public struct CodexUsageClient: Sendable {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let http: any UsageHTTPClient
    private let now: @Sendable () -> Date

    public init(
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(fixedHost: "Codex official endpoints"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.now = now
    }

    public func refreshToken(_ refreshToken: String) async throws -> CodexRefreshResponse {
        let form = [
            "grant_type=refresh_token",
            "client_id=\(Self.formEncode(Self.clientID))",
            "refresh_token=\(Self.formEncode(refreshToken))",
        ].joined(separator: "&")
        let response = try await send(UsageHTTPRequest(
            method: "POST",
            host: "auth.openai.com",
            path: "/oauth/token",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            timeout: 15
        ))

        try classifyCommon(response, allowUnauthorized: false)
        if response.statusCode == 400 || response.statusCode == 401 {
            if Self.requiresSignIn(response.body) {
                throw UsageProviderFailure.signInAgain
            }
            throw UsageProviderFailure.invalidResponse
        }
        guard (200..<300).contains(response.statusCode),
              let object = Self.jsonObject(response.body),
              let accessToken = Self.nonemptyString(object["access_token"])
        else {
            throw UsageProviderFailure.invalidResponse
        }
        return CodexRefreshResponse(
            accessToken: accessToken,
            refreshToken: Self.nonemptyString(object["refresh_token"]),
            idToken: Self.nonemptyString(object["id_token"])
        )
    }

    public func fetchUsage(accessToken: String, accountID: String?) async throws -> UsageHTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "AgentHalo",
        ]
        if let accountID = Self.nonemptyString(accountID) {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let response = try await send(UsageHTTPRequest(
            method: "GET",
            host: "chatgpt.com",
            path: "/backend-api/wham/usage",
            headers: headers,
            body: nil,
            timeout: 10
        ))

        try classifyCommon(response, allowUnauthorized: true)
        if response.statusCode == 401 {
            return response
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UsageProviderFailure.invalidResponse
        }
        guard Self.jsonObject(response.body) != nil else {
            throw UsageProviderFailure.invalidResponse
        }
        return response
    }

    private func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse {
        do {
            return try await http.send(request)
        } catch let failure as UsageProviderFailure {
            throw failure
        } catch {
            throw UsageProviderFailure.network
        }
    }

    private func classifyCommon(
        _ response: UsageHTTPResponse,
        allowUnauthorized: Bool
    ) throws {
        if response.statusCode == 429 {
            throw UsageProviderFailure.rateLimited(
                retryAt: Self.retryDate(response.header("Retry-After"), now: now())
            )
        }
        if (500...599).contains(response.statusCode) {
            throw UsageProviderFailure.serviceUnavailable
        }
        if response.statusCode == 401, allowUnauthorized {
            return
        }
    }

    private static func requiresSignIn(_ data: Data) -> Bool {
        guard let object = jsonObject(data) else { return false }
        let code: String?
        if let error = object["error"] as? [String: Any] {
            code = nonemptyString(error["code"]) ?? nonemptyString(error["error"])
        } else {
            code = nonemptyString(object["error"]) ?? nonemptyString(object["code"])
        }
        return [
            "refresh_token_expired",
            "refresh_token_reused",
            "refresh_token_invalidated",
        ].contains(code)
    }

    private static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value = nonemptyString(value) else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
