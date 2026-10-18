import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private struct TestTransport: ClientTransport {
    let json: String
    let validate: @Sendable (HTTPRequest) -> Void
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        validate(request)
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(json))
    }
}

@MainActor final class WireTests: XCTestCase {
    func testGeneratedClientSendsNativeBearerWithoutCookies() async throws {
        let transport = TestTransport(json: #"{"email":"donor@example.org","public_name":null,"referral_emails":true,"marketing_emails":false,"push_referral_converted":true,"push_streak_at_risk":true,"push_streak_milestone":true,"version":1,"consent_version":"synthetic"}"#) { request in
            XCTAssertEqual(request.headerFields[.authorization], "Bearer synthetic-access")
            XCTAssertEqual(request.headerFields[.init("X-DAD-Client")!], "native")
            XCTAssertNil(request.headerFields[.cookie])
            XCTAssertNil(request.headerFields[.init("Origin")!])
        }
        let api = WireAPI(origin: URL(string: "https://api.test")!, transport: transport)
        let profile = try await api.profile(access: "synthetic-access")
        XCTAssertEqual(profile, AccountProfile(email: "donor@example.org", publicName: nil))
    }
    func testBrowserClaimPayloadIsRejectedByNativeSessionAdapter() async throws {
        let transport = TestTransport(json: #"{"claimed":true}"#) { _ in }
        do {
            _ = try await WireAPI(origin: URL(string: "https://api.test")!, transport: transport).claim(token: String(repeating: "a", count: 32))
            XCTFail("browser payload accepted as native credentials")
        } catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
    }
    func testInsecureAndNonOriginURLsAreRejected() {
        for value in ["http://api.test", "https://user:pass@api.test", "https://api.test/path", "https://api.test?query=x"] {
            XCTAssertThrowsError(try WireAPI(origin: URL(string: value)!))
        }
    }
    func testOversizedResponseIsRejected() async throws {
        let transport = TestTransport(json: String(repeating: "x", count: 1_048_577)) { _ in }
        do {
            _ = try await WireAPI(origin: URL(string: "https://api.test")!, transport: transport).profile(access: "synthetic-access")
            XCTFail("unbounded response accepted")
        } catch { XCTAssertFalse(error is CancellationError) }
    }
}
