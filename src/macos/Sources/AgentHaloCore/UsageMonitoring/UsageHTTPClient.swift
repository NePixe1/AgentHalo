import Foundation

/// A single HTTP request to a usage endpoint. Headers are normalized to
/// lowercase keys on construction so downstream code never has to worry
/// about case. The request body is opaque and never logged.
public struct UsageHTTPRequest: Sendable {
    public var method: String
    public var host: String
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, host: String, path: String, headers: [String: String], body: Data?) {
        self.method = method
        self.host = host
        self.path = path
        self.headers = UsageHTTPRequest.normalizeHeaders(headers)
        self.body = body
    }

    /// Lowercase every header key so lookups are case-insensitive on both
    /// sides of the wire.
    static func normalizeHeaders(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (key, value) in headers {
            normalized[key.lowercased()] = value
        }
        return normalized
    }
}

/// An HTTP response from a usage endpoint. Header keys are lowercased on
/// construction so `header(_:)` is case-insensitive for both production
/// responses and synthetic checks.
public struct UsageHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = UsageHTTPRequest.normalizeHeaders(headers)
        self.body = body
    }

    /// Case-insensitive header lookup. Returns `nil` when absent.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Injectable HTTP client used by usage providers. Production uses
/// `URLSessionUsageHTTPClient`; checks use `RecordingUsageHTTPClient`.
public protocol UsageHTTPClient: Sendable {
    func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse
}

/// Production HTTP client backed by `URLSession`.
///
/// Logging discipline: only `method`, the fixed official `host`, `statusCode`
/// and elapsed time are ever logged. Request headers, request body, response
/// headers and response body are never logged.
public final class URLSessionUsageHTTPClient: UsageHTTPClient {
    private let session: URLSession
    private let fixedHost: String

    public init(session: URLSession = .shared, fixedHost: String) {
        self.session = session
        self.fixedHost = fixedHost
    }

    public func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse {
        let start = Date()
        var urlRequest = URLRequest(url: URL(string: "https://\(request.host)\(request.path)")!)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response): (Data, HTTPURLResponse)
        do {
            let result = try await session.data(for: urlRequest)
            data = result.0
            guard let httpResponse = result.1 as? HTTPURLResponse else {
                throw UsageProviderFailure.invalidResponse
            }
            response = httpResponse
        } catch {
            // Only safe-surface info: method, fixed host. No status/elapsed on
            // a transport failure; never log headers, body or the error text.
            NSLog("[UsageHTTP] %@ %@ failed", request.method, fixedHost)
            throw UsageProviderFailure.network
        }

        let elapsed = Date().timeIntervalSince(start)
        // Only safe-surface info: method, fixed official host, status, elapsed.
        NSLog("[UsageHTTP] %@ %@ status=%d elapsed=%.3fs", request.method, fixedHost, response.statusCode, elapsed)

        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        return UsageHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }
}
