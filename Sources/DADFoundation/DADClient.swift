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
            try await operation(Client(serverURL: origin, configuration: .init(dateTranscoder: LenientDateTranscoder()),
                                       transport: transport, middlewares: [NativeHeaders(access: { access })]))
        }
    }
}

/// The server's timestamps are RFC 3339: whole seconds today, but a value with fractional seconds
/// (Go's encoder emits them whenever the instant has any) must not fail the whole response. Accepts
/// both on read and always writes the plain form.
struct LenientDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String { date.formatted(.iso8601) }
    func decode(_ dateString: String) throws -> Date {
        if let plain = try? Date(dateString, strategy: .iso8601) { return plain }
        if let fractional = try? Date(dateString, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return fractional }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected date string to be ISO8601-formatted."))
    }
}
