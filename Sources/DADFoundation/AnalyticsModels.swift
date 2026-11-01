import Foundation

// The analytics sink seam + the buffering recorder. A conformer maps a batch to the generated
// ingest client (WireAPI) or a test double; the recorder owns buffering, idempotent de-dup, and
// chunked flush so the "emit the taxonomy once, deliver reliably" behaviour is unit-testable.

/// The seam the recorder flushes through. A conformer POSTs the batch to /analytics/events.
public protocol AnalyticsSink: Sendable {
    func send(_ batch: AnalyticsBatch) async throws
}

/// One typed client-side event sink (§9). Call `record` from a flow; the recorder buffers and
/// flushes. Flushing is idempotent: each record carries a stable id, and a record already
/// delivered is never re-buffered, so a lifecycle that fires twice still emits one event.
public actor AnalyticsRecorder {
    private let sink: any AnalyticsSink
    private var buffer: [AnalyticsRecord] = []
    private var deliveredIDs: Set<UUID> = []

    public init(sink: any AnalyticsSink) { self.sink = sink }

    /// Buffer a validated record. A record whose id was already delivered (a retried emit) is
    /// dropped, so instrumenting a flow that can re-enter never double-counts (§9 "once").
    public func record(_ record: AnalyticsRecord) {
        guard !deliveredIDs.contains(record.id) else { return }
        guard !buffer.contains(where: { $0.id == record.id }) else { return }
        buffer.append(record)
    }

    /// Convenience: build + buffer in one call. Invalid events throw and are not buffered.
    public func record(
        _ name: AnalyticsEvent, occurredAt: Date = Date(),
        properties: [String: String] = [:], journeyID: UUID? = nil
    ) throws {
        record(try AnalyticsRecord(name, occurredAt: occurredAt, properties: properties, journeyID: journeyID))
    }

    public var pending: Int { buffer.count }

    /// Drop everything not yet delivered (the donor declined analytics).
    public func discardPending() { buffer.removeAll() }

    /// Flush the buffer in wire-legal (≤100) chunks. On success the delivered ids are remembered
    /// and the buffer cleared; on a sink failure the buffer is kept so the next flush retries,
    /// and already-delivered ids keep de-dup working across the retry.
    public func flush() async throws {
        guard !buffer.isEmpty else { return }
        let batches = AnalyticsBatch.chunk(buffer)
        var deliveredThisFlush: [UUID] = []
        do {
            for batch in batches {
                do {
                    try await sink.send(batch)
                } catch AccountError.invalidInput {
                    // The server rejects the whole batch for one bad event, so resending it would fail forever.
                }
                deliveredThisFlush.append(contentsOf: batch.events.map(\.id))
            }
        } catch {
            // Keep only the still-undelivered records so the next flush doesn't resend a chunk
            // that already landed.
            deliveredIDs.formUnion(deliveredThisFlush)
            buffer.removeAll { deliveredThisFlush.contains($0.id) }
            throw error
        }
        deliveredIDs.formUnion(deliveredThisFlush)
        buffer.removeAll()
    }
}
