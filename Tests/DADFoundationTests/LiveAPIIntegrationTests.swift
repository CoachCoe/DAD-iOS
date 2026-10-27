#if DAD_LIVE_API_TEST
import Foundation
import OpenAPIURLSession
import Security
import XCTest
@testable import DADFoundation

private final class LocalTestTrust: NSObject, URLSessionTaskDelegate, Sendable {
    let certificate: Data
    init(_ certificate: Data) { self.certificate = certificate }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor final class LiveAPIIntegrationTests: XCTestCase {
    private var step = "fixture"
    private struct Fixture: Decodable {
        let origin: URL
        let certificate_pem: String
        let claim_token: String
        let logout_claim_token: String
        let email: String
    }
    private func expectSignedOut(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Revoked credential was accepted") }
        catch AccountError.signedOut {}
        catch { XCTFail("Unexpected authentication failure type: \(type(of: error))") }
    }
    func testRealHTTPSAccountLifecycle() async {
        do { try await exerciseLifecycle() }
        catch { XCTFail("Real API lifecycle failed at \(step): \(String(describing: error as? AccountError)) (\(type(of: error)))") }
    }
    private func exerciseLifecycle() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["DONOR_NATIVE_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.origin.host == "127.0.0.1", fixture.origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        let base64 = fixture.certificate_pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        let certificate = try XCTUnwrap(Data(base64Encoded: base64))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let network = URLSession(configuration: configuration, delegate: LocalTestTrust(certificate), delegateQueue: nil)
        defer { network.invalidateAndCancel() }
        let api = WireAPI(origin: fixture.origin, transport: URLSessionTransport(configuration: .init(session: network)))
        step = "claim"
        let original = try await api.claim(token: fixture.claim_token)
        step = "initial profile"
        let initialProfile = try await api.profile(access: original.access)
        XCTAssertEqual(initialProfile.email, fixture.email)
        await expectSignedOut { _ = try await api.claim(token: fixture.claim_token) }
        let store = MemoryStore(Credentials(access: original.access, refresh: original.refresh, expiresAt: .distantPast))
        let session = try AccountSession(api: api, store: store)
        step = "expired access refresh"
        let profile = try await session.profile()
        XCTAssertEqual(profile.email, fixture.email)
        let rotated = try XCTUnwrap(store.load())
        XCTAssertTrue(rotated.access != original.access, "Refresh must replace the access token")
        XCTAssertTrue(rotated.refresh != original.refresh, "Refresh must rotate the refresh token")
        await expectSignedOut { _ = try await api.profile(access: original.access) }
        step = "remote revocation"
        try await api.logout(access: rotated.access)
        await expectSignedOut { _ = try await session.profile() }
        XCTAssertNil(try store.load())
        step = "claim after revocation"
        try await session.claim(token: fixture.logout_claim_token)
        let last = try XCTUnwrap(store.load())
        step = "session logout"
        try await session.logout()
        XCTAssertNil(try store.load())
        await expectSignedOut { _ = try await api.profile(access: last.access) }
        await expectSignedOut { _ = try await api.refresh(token: last.refresh) }
    }
}
#endif
