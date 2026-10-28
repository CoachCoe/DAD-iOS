import Foundation

// Donor events & volunteering (PRD E-1..E-10, §6.11). Pure value types and the display /
// eligibility rules live here so event availability, the check-in window, invite-only
// gating and reservation transitions are unit-testable without a network, a camera, or UI.
//
// The server is always authoritative for reservation and check-in (capacity races, the
// exact window). These rules are the *client-side* pre-checks that drive what the UI
// offers and disables — mirroring Phase C/D's "pure core, seam for I/O" shape.

// MARK: - Reservation status (E-3, E-4)

/// Where the signed-in donor stands on one event. Mirrors the contract's `reservation_status`
/// string so the detail screen can render the right primary action without re-deriving it.
public enum ReservationStatus: String, Sendable, Equatable, Codable {
    case none
    case reserved
    case waitlisted
    case checkedIn = "checked_in"

    /// The contract sends unknown future values as strings; decode defensively to `.none`
    /// rather than failing the whole event list.
    public init(contract raw: String) {
        self = ReservationStatus(rawValue: raw) ?? .none
    }
}

// MARK: - Availability (E-2, E-3, E-4)

/// What the detail screen's primary action should offer, derived from capacity, the donor's
/// current standing, and the booking window. Keeping this a pure function of the event makes
/// the "reserve vs join waitlist vs full vs not-yet-open" decision testable.
public enum EventAvailability: Sendable, Equatable {
    /// Booking has not opened yet (early-booking gate) — show the open time, no action.
    case notYetOpen(opensAt: Date)
    /// Spots remain — offer Reserve.
    case reservable(spotsLeft: Int)
    /// Full — offer Join waitlist (E-4).
    case waitlistable
    /// Donor already holds a reservation — offer Cancel (E-9).
    case reserved
    /// Donor is on the waitlist — show waitlisted, offer leave.
    case waitlisted
    /// Donor already checked in — terminal, no action.
    case checkedIn
    /// Event cancelled by the organiser — no action.
    case cancelled
}

// MARK: - Event (the detail/list model, decoded from EventView)

/// One event as the list and detail screens render it. Independent of the generated
/// `EventView` so the domain + tests never import transport types; `WireAPI` maps across.
public struct DonorEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    public let type: String
    public let venue: String
    public let city: String
    public let startsAt: Date
    public let endsAt: Date
    public let capacity: Int
    public let spotsLeft: Int
    public let status: ReservationStatus
    /// Present only for invite-only events the donor can see (E-5); nil = a public event.
    public let invitationNote: String?
    public let reportIssueURL: String?
    public let cancelled: Bool
    public let bookingOpensAt: Date?
    public let earlyBooking: Bool

    public init(
        id: String, slug: String, title: String, type: String, venue: String, city: String,
        startsAt: Date, endsAt: Date, capacity: Int, spotsLeft: Int, status: ReservationStatus,
        invitationNote: String? = nil, reportIssueURL: String? = nil, cancelled: Bool = false,
        bookingOpensAt: Date? = nil, earlyBooking: Bool = false
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.type = type
        self.venue = venue
        self.city = city
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.capacity = capacity
        self.spotsLeft = spotsLeft
        self.status = status
        self.invitationNote = invitationNote
        self.reportIssueURL = reportIssueURL
        self.cancelled = cancelled
        self.bookingOpensAt = bookingOpensAt
        self.earlyBooking = earlyBooking
    }

    /// Whether this event is invite-only (E-5): it carries an invitation note / guest-list marker.
    public var isInviteOnly: Bool { invitationNote != nil }

    /// The primary-action decision (E-3/E-4/E-9). `now` is injected so tests are deterministic.
    public func availability(now: Date) -> EventAvailability {
        if cancelled { return .cancelled }
        switch status {
        case .checkedIn: return .checkedIn
        case .reserved: return .reserved
        case .waitlisted: return .waitlisted
        case .none:
            if let opens = bookingOpensAt, now < opens { return .notYetOpen(opensAt: opens) }
            return spotsLeft > 0 ? .reservable(spotsLeft: spotsLeft) : .waitlistable
        }
    }

    /// "3 spots left" / "Full" line for the list row and detail header.
    public var spotsLabel: String {
        if cancelled { return "Cancelled" }
        if spotsLeft <= 0 { return "Full" }
        return spotsLeft == 1 ? "1 spot left" : "\(spotsLeft) spots left"
    }
}

// MARK: - Check-in window (E-8)

/// The client-side check-in gate. The server is authoritative, but the scanner should only
/// *offer* check-in inside the window and give a clear reason when it is too early / too late,
/// rather than firing a request that is bound to 422. The window opens `earlyGrace` before
/// start and closes at `endsAt` (configurable to match the server's rule).
public struct CheckInWindow: Sendable, Equatable {
    /// How long before `startsAt` check-in opens. Server rule: doors open 60 min early.
    public static let earlyGrace: TimeInterval = 60 * 60

    public let startsAt: Date
    public let endsAt: Date

    public init(startsAt: Date, endsAt: Date) {
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    public var opensAt: Date { startsAt.addingTimeInterval(-Self.earlyGrace) }

    public enum State: Sendable, Equatable {
        case tooEarly(opensAt: Date)
        case open
        case tooLate
    }

    public func state(now: Date) -> State {
        if now < opensAt { return .tooEarly(opensAt: opensAt) }
        if now > endsAt { return .tooLate }
        return .open
    }

    /// Whether the scanner should allow a check-in attempt right now.
    public func isOpen(now: Date) -> Bool { state(now: now) == .open }
}

// MARK: - Reservation outcome (E-4)

/// The result of a reserve attempt, from `ReservationResult.status`. Distinguishes a confirmed
/// seat from a waitlist placement so the confirmation screen shows the right copy (E-4).
public enum ReservationOutcome: Sendable, Equatable {
    case reserved
    case waitlisted

    public init(contract raw: String) {
        self = raw.lowercased() == "waitlisted" ? .waitlisted : .reserved
    }

    public var confirmationTitle: String {
        self == .waitlisted ? "You're on the waitlist" : "You're going"
    }

    public var confirmationDetail: String {
        self == .waitlisted
            ? "We'll notify you if a spot opens up."
            : "Your spot is confirmed. Add it to your calendar so you don't miss it."
    }
}
