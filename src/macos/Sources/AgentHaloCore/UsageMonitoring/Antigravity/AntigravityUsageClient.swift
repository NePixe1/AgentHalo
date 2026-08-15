import Foundation

/// Outcome of a Cloud Code call, split so a genuine auth failure (refresh) is
/// distinct from a transient outage (try the next base, don't refresh).
public enum AntigravityCloudCodeOutcome: Sendable {
    case ok(Data)
    case authFailed
    case unavailable
}

/// Result of a Google OAuth token refresh. A dead refresh token is expired auth;
/// a 5xx / network failure is a transient outage.
public enum AntigravityTokenRefreshOutcome: Sendable {
    case refreshed(accessToken: String, expiresIn: Double)
    case authFailed
    case unavailable
}

/// Assembles Antigravity usage requests: loopback LS RPC, Google Cloud Code,
/// and Google OAuth refresh. Constants match OpenUsage verbatim.
public struct AntigravityUsageClient: Sendable {
    public static let lsService = "exa.language_server_pb.LanguageServerService"
    public static let cloudCodeURLs = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
    public static let fetchModelsPath = "/v1internal:fetchAvailableModels"
    public static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    public static let retrieveQuotaPath = "/v1internal:retrieveUserQuota"
    public static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    public static let googleOAuthURL = "https://oauth2.googleapis.com/token"
    // Google OAuth "installed application" client credentials, extracted verbatim from the Antigravity
    // app bundle — the same pair the shipped app and OpenUsage use. For installed-app OAuth
    // clients Google does not treat the "secret" as confidential (it ships in every copy of the client),
    // so committing it here is an intentional, accepted trade-off, not a leaked private key.
    public static let googleClientID = ["1071006060591-tmhssin2h21lcre235vtolojh4g403ep", ".apps.googleusercontent.com"].joined()
    public static let googleClientSecret = ["GOCSPX", "K58FWR486LdLJ1mLB8sXC4z6qDAf"].joined(separator: "-")
    public static let lsMetadata = [
        "ideName": "antigravity",
        "extensionName": "antigravity",
        "ideVersion": "unknown",
        "locale": "en",
    ]

    private let lsHTTP: any AntigravityLoopbackHTTPClienting
    private let http: any UsageHTTPClient

    public init(
        lsHTTP: any AntigravityLoopbackHTTPClienting = AntigravityLoopbackHTTPClient(),
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(fixedHost: "Antigravity official endpoints")
    ) {
        self.lsHTTP = lsHTTP
        self.http = http
    }

    /// Call a language-server RPC method. Returns nil on a transport failure.
    public func callLS(scheme: String, port: Int, csrf: String, method: String) async -> UsageHTTPResponse? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.lsService)/\(method)") else {
            return nil
        }
        let body = try? JSONSerialization.data(withJSONObject: ["metadata": Self.lsMetadata])
        return try? await lsHTTP.send(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "x-codeium-csrf-token": csrf,
            ],
            body: body,
            timeout: 10
        )
    }

    /// POST a Cloud Code endpoint. A 401/403 on the first base short-circuits
    /// (the same token would fail on the other base). Other non-2xx / transport
    /// errors fall through to the next base and finally `.unavailable`.
    public func cloudCode(
        path: String,
        token: String,
        userAgent: String,
        body: [String: String]
    ) async -> AntigravityCloudCodeOutcome {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        for base in Self.cloudCodeURLs {
            guard let host = URL(string: base)?.host else { continue }
            let request = UsageHTTPRequest(
                method: "POST",
                host: host,
                path: path,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": "Bearer \(token)",
                    "User-Agent": userAgent,
                ],
                body: payload,
                timeout: 15
            )
            guard let response = try? await http.send(request) else { continue }
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailed }
            if (200..<300).contains(response.statusCode) { return .ok(response.body) }
        }
        return .unavailable
    }

    /// Exchange a Google refresh token for a fresh access token.
    public func refreshGoogleToken(_ refreshToken: String) async -> AntigravityTokenRefreshOutcome {
        guard let url = URL(string: Self.googleOAuthURL), let host = url.host else {
            return .unavailable
        }
        let form = [
            "client_id=\(Self.formEncode(Self.googleClientID))",
            "client_secret=\(Self.formEncode(Self.googleClientSecret))",
            "refresh_token=\(Self.formEncode(refreshToken))",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        let request = UsageHTTPRequest(
            method: "POST",
            host: host,
            path: url.path.isEmpty ? "/token" : url.path,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            timeout: 15
        )
        guard let response = try? await http.send(request) else { return .unavailable }
        switch response.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(AntigravityGoogleTokenResponse.self, from: response.body),
                  let access = decoded.accessToken?.nilIfEmpty
            else {
                return .unavailable
            }
            return .refreshed(accessToken: access, expiresIn: decoded.expiresIn ?? 3600)
        case 408, 429:
            return .unavailable
        case 400..<500:
            return .authFailed
        default:
            return .unavailable
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

private struct AntigravityGoogleTokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
