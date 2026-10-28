import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Authenticated transport seam for product (donor/partner) calls, Phase A.
///
/// The generated client and its operation/schema types are `internal` to this module
/// (`accessModifier: internal` in the generator config), so typed product methods are added
/// here, in-module, one per endpoint as each phase consumes it — Phase C (donor core) is the
/// first to do so. Phase A establishes only the authenticated `Client`: every call it issues
/// carries a fresh bearer from `AccountSession` (single-flight refresh, atomic swap) and the
/// native middleware (no cookies, no Origin, bounded response body).
///
/// `WireAPI` already proves this pattern for the session-bootstrap operations
/// (profile/refresh/claim/logout); `ProductClient` is the same pattern scoped to the widened
/// product surface, keyed off the live session rather than a single access token.
struct ProductClient {
    let client: Client

    init(origin: URL, session: AccountSession) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let transport = URLSessionTransport(
            configuration: .init(session: URLSession(configuration: configuration))
        )
        let auth = NativeProductMiddleware(accessProvider: { try await session.accessToken() })
        self.client = Client(serverURL: origin, transport: transport, middlewares: [auth])
    }
}

/// Native request shaping for product calls: native client marker, no cookies, no Origin,
/// per-request bearer resolved from the session, and a bounded response body.
private struct NativeProductMiddleware: ClientMiddleware {
    let accessProvider: @Sendable () async throws -> String
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.init("X-DAD-Client")!] = "native"
        request.headerFields[.cookie] = nil
        request.headerFields[.init("Origin")!] = nil
        request.headerFields[.authorization] = "Bearer \(try await accessProvider())"
        let (response, responseBody) = try await next(request, body, baseURL)
        guard let responseBody else { return (response, nil) }
        let bytes = try await ArraySlice<UInt8>(collecting: responseBody, upTo: 1_048_576)
        return (response, HTTPBody(bytes))
    }
}
