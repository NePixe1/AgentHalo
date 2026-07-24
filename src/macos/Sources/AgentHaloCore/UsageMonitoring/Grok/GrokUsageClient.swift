import Foundation

/// HTTP client for Grok OAuth token refresh and credits billing endpoints.
///
/// Hosts are fixed to official xAI surfaces only:
/// - credits/settings: `cli-chat-proxy.grok.com`
/// - refresh: `auth.x.ai`
///
/// Path for credits includes the `format=credits` query so
/// `URLSessionUsageHTTPClient` can assemble the full URL without a separate
/// query field (`https://host` + path).
public struct GrokUsageClient: Sendable {
    /// Matches Grok CLI / OpenUsage default OIDC client id.
    public static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let tokenAuthHeader = "xai-grok-cli"

    private let http: any UsageHTTPClient

    public init(
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(fixedHost: "Grok official endpoints")
    ) {
        self.http = http
    }

    public func refreshToken(_ refreshToken: String, clientID: String) async throws -> UsageHTTPResponse {
        let form = [
            "grant_type=refresh_token",
            "client_id=\(Self.formEncode(clientID))",
            "refresh_token=\(Self.formEncode(refreshToken))",
        ].joined(separator: "&")
        return try await send(UsageHTTPRequest(
            method: "POST",
            host: "auth.x.ai",
            path: "/oauth2/token",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8),
            timeout: 15
        ))
    }

    public func fetchCreditsConfig(accessToken: String) async throws -> UsageHTTPResponse {
        try await send(UsageHTTPRequest(
            method: "GET",
            host: "cli-chat-proxy.grok.com",
            path: "/v1/billing?format=credits",
            headers: authHeaders(accessToken: accessToken),
            body: nil,
            timeout: 10
        ))
    }

    public func fetchSettings(accessToken: String) async throws -> UsageHTTPResponse {
        try await send(UsageHTTPRequest(
            method: "GET",
            host: "cli-chat-proxy.grok.com",
            path: "/v1/settings",
            headers: authHeaders(accessToken: accessToken),
            body: nil,
            timeout: 10
        ))
    }

    private func authHeaders(accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            "X-XAI-Token-Auth": Self.tokenAuthHeader,
            "Accept": "application/json",
            "User-Agent": "AgentHalo",
        ]
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

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
