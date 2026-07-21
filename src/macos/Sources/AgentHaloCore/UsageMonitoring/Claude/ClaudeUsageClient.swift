import Foundation

public struct ClaudeUsageClient: Sendable {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    private let http: any UsageHTTPClient

    public init(
        http: any UsageHTTPClient = URLSessionUsageHTTPClient(fixedHost: "Claude official endpoints")
    ) {
        self.http = http
    }

    public func fetchUsage(accessToken: String) async throws -> UsageHTTPResponse {
        try await send(UsageHTTPRequest(
            method: "GET",
            host: "api.anthropic.com",
            path: "/api/oauth/usage",
            headers: [
                "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.1.69",
            ],
            body: nil,
            timeout: 10
        ))
    }

    public func refreshToken(_ refreshToken: String) async throws -> UsageHTTPResponse {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes,
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw UsageProviderFailure.invalidResponse
        }
        return try await send(UsageHTTPRequest(
            method: "POST",
            host: "platform.claude.com",
            path: "/v1/oauth/token",
            headers: ["Content-Type": "application/json"],
            body: data,
            timeout: 15
        ))
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
}
