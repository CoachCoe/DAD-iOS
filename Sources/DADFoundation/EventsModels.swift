import Foundation

// Events view models + the service seam. The models own explicit load/ready/failed state and
// the reserve/cancel/check-in transitions, so they are unit-tested without a network, a camera,
// or UI — the same shape as the giving and engagement models.

/// The seam the events models call. A conformer maps to the generated client (WireAPI) or a
/// preview/test double; all value types so the models stay testable. The server is
/// authoritative — these calls can throw (401/404/409/422) and the models surface that.
public protocol EventsService: Sendable {
    /// Events near the donor, soonest-first (E-2). Includes any invite-only events the donor
    /// is eligible to see (E-5); the service merges public + invite-only server-side.
    func events() async throws -> [DonorEvent]
    /// One event's detail (E-3).
    func event(id: String) async throws -> DonorEvent
    /// Reserve or join the waitlist (E-4). Returns the outcome so the model shows the right copy.
    func reserve(eventID: String) async throws -> ReservationOutcome
    /// Cancel a reservation (E-9).
    func cancel(eventID: String) async throws
    /// Check in with a scanned code (E-8). The server validates the window and returns whether
    /// the check-in took (or was already recorded).
    func checkIn(code: String) async throws -> CheckInResultValue
}

/// Domain mirror of the contract's `CheckInResult` so the model/tests never import transport.
public struct CheckInResultValue: Sendable, Equatable {
    public let eventID: String
    public let checkedIn: Bool
    public let alreadyCheckedIn: Bool

    public init(eventID: String, checkedIn: Bool, alreadyCheckedIn: Bool) {
        self.eventID = eventID
        self.checkedIn = checkedIn
        self.alreadyCheckedIn = alreadyCheckedIn
    }
}

// MARK: - Events list/detail model (E-2, E-3, E-4, E-9)

/// Drives the events list and detail. One load fetches the list; reserving/cancelling updates
/// the affected event in place so the list and detail re-render without a full reload.
@MainActor
@Observable
public final class EventsModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var events: [DonorEvent] = []
    /// The last reserve outcome, so the detail screen can present the confirmation (E-4).
    public private(set) var lastOutcome: ReservationOutcome?
    /// A transient action error (reserve/cancel 409 etc.) shown inline without losing the list.
    public private(set) var actionError: String?

    private let service: any EventsService

    public init(service: any EventsService) { self.service = service }

    public func load() async {
        let prior = phase
        phase = .loading
        do {
            events = try await service.events()
            phase = .ready
        } catch where error.isCancellation {
            phase = prior
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    /// Events already sorted soonest-first (E-2). The service returns server order; sorting here
    /// keeps the list stable even if a reserve re-fetch reorders.
    public var sortedEvents: [DonorEvent] { events.sorted { $0.startsAt < $1.startsAt } }

    public func reserve(eventID: String) async {
        actionError = nil
        do {
            let outcome = try await service.reserve(eventID: eventID)
            lastOutcome = outcome
            await refresh(eventID: eventID)
        } catch where error.isCancellation {
            return
        } catch {
            actionError = error.userMessage
        }
    }

    public func cancel(eventID: String) async {
        actionError = nil
        do {
            try await service.cancel(eventID: eventID)
            lastOutcome = nil
            await refresh(eventID: eventID)
        } catch where error.isCancellation {
            return
        } catch {
            actionError = error.userMessage
        }
    }

    /// Re-fetch one event after a mutation and splice it back into the list in place.
    private func refresh(eventID: String) async {
        // Best-effort: the mutation already succeeded, so a failed re-fetch leaves the row stale
        // until the next load rather than reporting a reserve/cancel that worked as an error.
        guard let updated = try? await service.event(id: eventID) else { return }
        if let index = events.firstIndex(where: { $0.id == eventID }) {
            events[index] = updated
        }
    }

    public func clearOutcome() { lastOutcome = nil }
}

// MARK: - Check-in model (E-8)

/// Drives the QR check-in flow. The camera scanner (a device seam, validated structurally) feeds
/// a scanned code in; this model applies the client-side window pre-check, calls the service, and
/// exposes a result the inline success/failure view renders. Server remains authoritative.
@MainActor
@Observable
public final class CheckInModel {
    public enum State: Sendable, Equatable {
        case idle
        case checking
        case success(alreadyCheckedIn: Bool)
        case outsideWindow(reason: String)
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let service: any EventsService

    public init(service: any EventsService) { self.service = service }

    /// Apply the client-side window gate, then (if open) check in. `window` and `now` are injected
    /// so the "too early / too late" branch is deterministic in tests; the server still validates.
    public func submit(code: String, window: CheckInWindow, now: Date) async {
        switch window.state(now: now) {
        case .tooEarly(let opensAt):
            state = .outsideWindow(reason: "Check-in opens \(Self.timeLabel(opensAt)).")
            return
        case .tooLate:
            state = .outsideWindow(reason: "Check-in for this event has closed.")
            return
        case .open:
            break
        }
        let prior = state
        state = .checking
        do {
            let result = try await service.checkIn(code: code)
            state = .success(alreadyCheckedIn: result.alreadyCheckedIn)
        } catch where error.isCancellation {
            state = prior
        } catch {
            state = .failed(error.userMessage)
        }
    }

    public func reset() { state = .idle }

    static func timeLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
