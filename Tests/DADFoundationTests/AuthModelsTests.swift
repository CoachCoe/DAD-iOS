import Foundation
import XCTest
@testable import DADFoundation

// MARK: - Attribution

final class AttributionTests: XCTestCase {
    private final class MemoryStore: AttributionStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Attribution?
        func load() -> Attribution? { lock.withLock { value } }
        func save(_ attribution: Attribution) { lock.withLock { value = attribution } }
        func clear() { lock.withLock { value = nil } }
    }

    func testSanitizationRejectsNonCodeInput() {
        let a = Attribution(inviteCode: "ABC-123", irlCode: "has space", companyCode: "", source: "../etc/passwd")
        XCTAssertEqual(a.inviteCode, "ABC-123")
        XCTAssertNil(a.irlCode)       // space rejected
        XCTAssertNil(a.companyCode)   // empty rejected
        XCTAssertNil(a.source)        // slashes rejected
    }

    func testCaptureMergesFirstWriterWinsPerField() {
        let capture = AttributionCapture(store: MemoryStore())
        capture.capture(Attribution(inviteCode: "INV1", source: "share"))
        // A later touch supplies a company code and a DIFFERENT invite; invite must not change.
        let merged = capture.capture(Attribution(inviteCode: "INV2", companyCode: "ACME"))
        XCTAssertEqual(merged.inviteCode, "INV1")   // first writer wins
        XCTAssertEqual(merged.companyCode, "ACME")  // empty slot filled
        XCTAssertEqual(merged.source, "share")
    }

    func testEmptyCaptureIsNotPersisted() {
        let store = MemoryStore()
        let capture = AttributionCapture(store: store)
        capture.capture(Attribution())
        XCTAssertNil(capture.current())
    }

    func testConsumeClearsStore() {
        let capture = AttributionCapture(store: MemoryStore())
        capture.capture(Attribution(companyCode: "ACME"))
        XCTAssertNotNil(capture.current())
        capture.consume()
        XCTAssertNil(capture.current())
    }

    func testDefaultsStoreSurvivesAcrossStoreInstances() {
        let suite = "org.dad.attribution.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DefaultsAttributionStore(defaults: defaults).save(Attribution(irlCode: "IRL9"))
        // A fresh store instance (simulating a cold launch) reads the persisted value.
        XCTAssertEqual(DefaultsAttributionStore(defaults: defaults).load()?.irlCode, "IRL9")
    }
}

// MARK: - Phone sign-in state machine

final class PhoneSignInModelTests: XCTestCase {
    private actor FakeService: SignInService {
        enum Mode { case ok, badCode, unreachable }
        let mode: Mode
        private(set) var requested: [String] = []
        init(mode: Mode) { self.mode = mode }
        func requestPhoneCode(phone: String) async throws -> String {
            requested.append(phone)
            if mode == .unreachable { throw AccountError.unavailable }
            return "handle-\(phone)"
        }
        func verifyPhone(handle: String, code: String) async throws -> Credentials {
            switch mode {
            case .ok: return Credentials(access: "a", refresh: "r", expiresAt: .distantFuture)
            case .badCode: throw AccountError.signedOut
            case .unreachable: throw AccountError.unavailable
            }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Credentials?
        func set(_ v: Credentials) { lock.withLock { value = v } }
        var get: Credentials? { lock.withLock { value } }
    }

    @MainActor
    func testHappyPathRequestThenVerifyEstablishes() async {
        let established = Box()
        let model = PhoneSignInModel(service: FakeService(mode: .ok)) { established.set($0) }
        model.phone = "+14155551234"
        XCTAssertTrue(model.canRequestCode)
        await model.requestCode()
        guard case .enterCode(let handle) = model.phase else { return XCTFail("expected enterCode, got \(model.phase)") }
        XCTAssertEqual(handle, "handle-+14155551234")
        model.code = "123456"
        XCTAssertTrue(model.canVerify)
        await model.verify()
        guard case .signedIn = model.phase else { return XCTFail("expected signedIn, got \(model.phase)") }
        XCTAssertNotNil(established.get)
    }

    @MainActor
    func testInvalidPhoneBlocksRequest() async {
        let model = PhoneSignInModel(service: FakeService(mode: .ok)) { _ in }
        model.phone = "5551234"   // no +, too short
        XCTAssertFalse(model.canRequestCode)
        await model.requestCode()
        XCTAssertEqual(model.phase, .enterPhone)  // unchanged
    }

    @MainActor
    func testBadCodeFailsButRetryPreservesHandle() async {
        let model = PhoneSignInModel(service: FakeService(mode: .badCode)) { _ in }
        model.phone = "+14155551234"
        await model.requestCode()
        model.code = "000000"
        await model.verify()
        guard case .failed = model.phase else { return XCTFail("expected failed, got \(model.phase)") }
        model.retryCodeEntry()
        // Retry returns to code entry WITHOUT re-requesting a code (same handle).
        guard case .enterCode(let handle) = model.phase else { return XCTFail("expected enterCode, got \(model.phase)") }
        XCTAssertEqual(handle, "handle-+14155551234")
    }

    @MainActor
    func testUnreachableOnRequestSurfacesFailure() async {
        let model = PhoneSignInModel(service: FakeService(mode: .unreachable)) { _ in }
        model.phone = "+14155551234"
        await model.requestCode()
        guard case .failed = model.phase else { return XCTFail("expected failed, got \(model.phase)") }
        // retry with no handle falls back to the phone screen.
        model.retryCodeEntry()
        XCTAssertEqual(model.phase, .enterPhone)
    }
}
