import XCTest
@testable import DADFoundation

final class AnalyticsRecordTests: XCTestCase {
    func testTaxonomyCoversAllThirtyEvents() {
        // The §9 taxonomy has 30 events; guard against an accidental drop.
        XCTAssertEqual(AnalyticsEvent.allCases.count, 30)
        XCTAssertEqual(AnalyticsEvent.appOpened.rawValue, "app_opened")
        XCTAssertEqual(AnalyticsEvent.pushOpened.rawValue, "push_opened")
    }

    func testCarrierEventsRequireTheirProperty() throws {
        // attribution_captured requires {source}, invite_shared {channel}, push_opened {type}.
        XCTAssertThrowsError(try AnalyticsRecord(.attributionCaptured)) { error in
            XCTAssertEqual(error as? AnalyticsRecord.ValidationError, .missingRequiredProperty("source"))
        }
        XCTAssertNoThrow(try AnalyticsRecord(.attributionCaptured, properties: ["source": "link"]))
        XCTAssertNoThrow(try AnalyticsRecord(.inviteShared, properties: ["channel": "sms"]))
        XCTAssertNoThrow(try AnalyticsRecord(.pushOpened, properties: ["type": "reminder"]))
    }

    func testNoPropertyEventRejectsProperties() {
        XCTAssertThrowsError(try AnalyticsRecord(.giftCompleted, properties: ["x": "y"])) { error in
            XCTAssertEqual(error as? AnalyticsRecord.ValidationError, .unexpectedProperties)
        }
    }

    func testEmptyRequiredValueIsRejected() {
        XCTAssertThrowsError(try AnalyticsRecord(.inviteShared, properties: ["channel": ""]))
    }
}

final class AnalyticsBatchTests: XCTestCase {
    private func records(_ n: Int) -> [AnalyticsRecord] {
        (0..<n).map { _ in try! AnalyticsRecord(.appOpened) }
    }

    func testChunkRespectsThe100Cap() {
        XCTAssertEqual(AnalyticsBatch.chunk(records(1)).count, 1)
        XCTAssertEqual(AnalyticsBatch.chunk(records(100)).count, 1)
        XCTAssertEqual(AnalyticsBatch.chunk(records(101)).count, 2)
        XCTAssertEqual(AnalyticsBatch.chunk(records(250)).count, 3)
        // Each chunk is wire-legal (1...100).
        for batch in AnalyticsBatch.chunk(records(250)) {
            XCTAssertTrue(batch.events.count >= 1 && batch.events.count <= 100)
        }
    }

    func testChunkPreservesOrder() {
        let recs = records(150)
        let flattened = AnalyticsBatch.chunk(recs).flatMap(\.events)
        XCTAssertEqual(flattened.map(\.id), recs.map(\.id))
    }
}

final class AnalyticsRecorderTests: XCTestCase {
    private actor SpySink: AnalyticsSink {
        private(set) var sent: [[AnalyticsRecord]] = []
        var failUntil = 0 // fail the first N send calls
        private var calls = 0
        func setFailUntil(_ n: Int) { failUntil = n }
        func send(_ batch: AnalyticsBatch) async throws {
            calls += 1
            if calls <= failUntil { throw AccountError.signedOut }
            sent.append(batch.events)
        }
        var flattened: [AnalyticsRecord] { sent.flatMap { $0 } }
    }

    func testEmitOnceEvenWhenRecordedTwice() async throws {
        let sink = SpySink()
        let recorder = AnalyticsRecorder(sink: sink)
        let record = try AnalyticsRecord(.giftCompleted)
        await recorder.record(record)
        await recorder.record(record) // same id — idempotent, not double-buffered
        let pending = await recorder.pending
        XCTAssertEqual(pending, 1)
        try await recorder.flush()
        let count = await sink.flattened.count
        XCTAssertEqual(count, 1)
    }

    func testFlushDeliversAndClears() async throws {
        let sink = SpySink()
        let recorder = AnalyticsRecorder(sink: sink)
        try await recorder.record(.appOpened)
        try await recorder.record(.giftStarted)
        try await recorder.flush()
        let pending = await recorder.pending
        XCTAssertEqual(pending, 0)
        let count = await sink.flattened.count
        XCTAssertEqual(count, 2)
    }

    func testFlushFailureKeepsBufferForRetry() async throws {
        let sink = SpySink()
        await sink.setFailUntil(1) // first send throws
        let recorder = AnalyticsRecorder(sink: sink)
        try await recorder.record(.appOpened)
        do { try await recorder.flush(); XCTFail("expected throw") } catch {}
        // Buffer kept — a retry delivers it, and the event is not duplicated.
        let pendingAfterFail = await recorder.pending
        XCTAssertEqual(pendingAfterFail, 1)
        try await recorder.flush()
        let count = await sink.flattened.count
        XCTAssertEqual(count, 1)
        let pendingAfterRetry = await recorder.pending
        XCTAssertEqual(pendingAfterRetry, 0)
    }

    func testAlreadyDeliveredIsNotRebuffered() async throws {
        let sink = SpySink()
        let recorder = AnalyticsRecorder(sink: sink)
        let record = try AnalyticsRecord(.badgeEarned)
        await recorder.record(record)
        try await recorder.flush()
        // Re-recording a delivered id is a no-op.
        await recorder.record(record)
        let pending = await recorder.pending
        XCTAssertEqual(pending, 0)
    }
}
