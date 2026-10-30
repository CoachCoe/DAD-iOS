import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Authenticated transport seam for product (donor/partner) calls.
///
/// The generated client and its operation/schema types are `internal` to this module
/// (`accessModifier: internal` in the generator config), so typed product methods live here,
/// in-module, one `Wire<X>` conformer per `<X>Service`. Every call goes through `perform`, which
/// hands the closure a `Client` that carries a fresh bearer from `AccountSession.authorized`
/// (single-flight refresh, one bounded 401 retry, epoch-guarded) and the native middleware
/// (no cookies, no Origin, bounded response body).
struct ProductClient: Sendable {
    let origin: URL
    let transport: any ClientTransport
    let session: AccountSession

    init(origin: URL, session: AccountSession) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(), session: session)
    }

    init(origin: URL, transport: any ClientTransport, session: AccountSession) {
        self.origin = origin; self.transport = transport; self.session = session
    }

    func perform<T: Sendable>(_ operation: @Sendable (Client) async throws -> T) async throws -> T {
        let origin = origin, transport = transport
        return try await session.authorized { access in
            try await operation(Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { access })]))
        }
    }
}
