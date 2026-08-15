import Foundation

/// Full-URL HTTP used only for the local language-server Connect-RPC.
/// Cloud Code and Google OAuth stay on `UsageHTTPClient` (https + host + path).
public protocol AntigravityLoopbackHTTPClienting: Sendable {
    func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> UsageHTTPResponse
}

/// Production loopback client. The session accepts a self-signed cert only for
/// `127.0.0.1` / `localhost`; every other host uses system TLS validation.
public final class AntigravityLoopbackHTTPClient: AntigravityLoopbackHTTPClienting, @unchecked Sendable {
    private let session: URLSession

    public init() {
        session = URLSession(
            configuration: .ephemeral,
            delegate: AntigravityLoopbackTLSDelegate(),
            delegateQueue: nil
        )
    }

    public func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> UsageHTTPResponse {
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = method
        urlRequest.httpBody = body
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let start = Date()
        let data: Data
        let response: HTTPURLResponse
        do {
            let result = try await session.data(for: urlRequest)
            data = result.0
            guard let httpResponse = result.1 as? HTTPURLResponse else {
                throw UsageProviderFailure.invalidResponse
            }
            response = httpResponse
        } catch let failure as UsageProviderFailure {
            throw failure
        } catch {
            NSLog("[AntigravityLS] %@ %@ failed", method, url.host ?? "loopback")
            throw UsageProviderFailure.network
        }

        let elapsed = Date().timeIntervalSince(start)
        NSLog(
            "[AntigravityLS] %@ %@ status=%d elapsed=%.3fs",
            method,
            url.host ?? "loopback",
            response.statusCode,
            elapsed
        )

        var responseHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                responseHeaders[key.lowercased()] = value
            }
        }
        return UsageHTTPResponse(statusCode: response.statusCode, headers: responseHeaders, body: data)
    }
}

/// Trusts a self-signed server cert only for loopback hosts. Other hosts and
/// non-server-trust challenges fall through to default validation.
private final class AntigravityLoopbackTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              isLoopback,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
