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
        let transport = makeNativeTransport()
        let auth = NativeHeaders(access: { try await session.accessToken() })
        self.client = Client(serverURL: origin, transport: transport, middlewares: [auth])
    }
}
