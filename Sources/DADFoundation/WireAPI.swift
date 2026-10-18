import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct NativeHeaders: ClientMiddleware {
    let access: String?
    func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.init("X-DAD-Client")!] = "native"
        request.headerFields[.cookie] = nil
        request.headerFields[.init("Origin")!] = nil
        request.headerFields[.authorization] = access.map { "Bearer \($0)" }
        let (response, responseBody) = try await next(request, body, baseURL)
        guard let responseBody else { return (response, nil) }
        let bytes = try await ArraySlice<UInt8>(collecting: responseBody, upTo: 1_048_576)
        return (response, HTTPBody(bytes))
    }
}

public struct WireAPI: AccountAPI {
    private let origin: URL
    private let transport: any ClientTransport

    public init(origin: URL) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { throw AccountError.invalidConfiguration }
        self.origin = origin
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.transport = URLSessionTransport(configuration: .init(session: URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)))
    }

    init(origin: URL, transport: any ClientTransport) { self.origin = origin; self.transport = transport }
    private func client(_ access: String? = nil) -> Client {
        Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: access)])
    }
    public func profile(access: String) async throws -> AccountProfile {
        switch try await client(access).profile(.init()) {
        case .ok(let response):
            let value = try response.body.json
            return AccountProfile(email: value.email, publicName: value.public_name)
        case .unauthorized: throw AccountError.signedOut
        default: throw AccountError.unavailable
        }
    }
    public func refresh(token: String) async throws -> Credentials {
        switch try await client().refresh(.init(body: .json(.init(refresh_token: token)))) {
        case .ok(let response): return try credentials(response.body.json)
        case .unauthorized: throw AccountError.signedOut
        default: throw AccountError.unavailable
        }
    }
    public func claim(token: String) async throws -> Credentials {
        switch try await client().claim(.init(body: .json(.init(token: token, platform: .IOS)))) {
        case .ok(let response):
            guard case .NativeSession(let value) = try response.body.json else { throw AccountError.invalidResponse }
            return try credentials(value)
        case .unauthorized: throw AccountError.signedOut
        default: throw AccountError.unavailable
        }
    }
    public func logout(access: String) async throws {
        guard case .ok = try await client(access).logout(.init()) else { throw AccountError.unavailable }
    }
    private func credentials(_ value: Components.Schemas.NativeSession) throws -> Credentials {
        guard !value.access_token.isEmpty, !value.refresh_token.isEmpty, value.expires_in > 0 else { throw AccountError.invalidResponse }
        return Credentials(access: value.access_token, refresh: value.refresh_token, expiresAt: Date().addingTimeInterval(Double(value.expires_in)))
    }
}
