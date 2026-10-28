import Foundation

// Donor giving core (PRD G-*, S-*, §6.12). Pure value types and the amount rule live
// here so the arithmetic and state transitions are unit-testable without a network or UI.

/// A validated recurring gift amount. The canonical unit is integer USD cents charged
/// monthly; the product rule (G-1/G-2) is a whole number of dollars a day, $1…$30, times 30.
/// Construction is the only place the rule is enforced, so an out-of-range amount cannot exist.
public struct GiftAmount: Sendable, Equatable, Hashable, Comparable {
    /// Dollars per day, 1…30.
    public let dailyDollars: Int
    /// Monthly charge in integer USD cents (dailyDollars × 30 × 100 == dailyDollars × 3000).
    public var monthlyMinor: Int { dailyDollars * Self.centsPerDailyDollar }

    public static let minDailyDollars = 1
    public static let maxDailyDollars = 30
    /// A daily dollar maps to this many monthly cents: $1/day → $30/month → 3000¢.
    public static let centsPerDailyDollar = 3000

    /// Build from a per-day dollar figure, clamped to the $1…$30 rule. Returns nil only
    /// for a non-positive input; values above the ceiling clamp to $30 rather than fail,
    /// so a slider cannot wedge.
    public init?(dailyDollars: Int) {
        guard dailyDollars >= 1 else { return nil }
        self.dailyDollars = min(dailyDollars, Self.maxDailyDollars)
    }

    /// Reconstruct from a monthly-cents figure returned by the API. Accepts only exact
    /// multiples of the $1/day step within range; anything else (a legacy amount predating
    /// the daily rule) returns nil so the caller shows it as a raw figure, not a daily tier.
    public init?(monthlyMinor: Int) {
        guard monthlyMinor >= Self.minDailyDollars * Self.centsPerDailyDollar,
              monthlyMinor <= Self.maxDailyDollars * Self.centsPerDailyDollar,
              monthlyMinor % Self.centsPerDailyDollar == 0 else { return nil }
        self.dailyDollars = monthlyMinor / Self.centsPerDailyDollar
    }

    public static func < (lhs: GiftAmount, rhs: GiftAmount) -> Bool { lhs.dailyDollars < rhs.dailyDollars }

    /// "$5/day" — the headline the set-gift screen shows.
    public var dailyLabel: String { "$\(dailyDollars)/day" }
    /// "$150/mo" — the monthly equivalent, derived, never entered directly.
    public var monthlyLabel: String { "$\(monthlyMinor / 100)/mo" }
}

/// Format an integer-cents USD figure as "$12.34" / "$150". Whole-dollar amounts drop the
/// decimals; this is display-only and never used for arithmetic.
public func formatUSDMinor(_ minor: Int) -> String {
    let dollars = Double(minor) / 100
    if minor % 100 == 0 { return "$\(minor / 100)" }
    return String(format: "$%.2f", dollars)
}

/// The recurring gift as the giving screens see it: either none set yet, or an active
/// subscription, or one scheduled to stop at period end (the cancel path, G-8/G-9).
public enum RecurringState: Sendable, Equatable {
    case none
    case active(subscriptionID: String, amountMinor: Int, periodEnd: Date)
    /// Cancelled but still running until `stopsAt` — the streak continues until then.
    case ending(subscriptionID: String, amountMinor: Int, periodEnd: Date, stopsAt: Date)

    /// The subscription id recurring commands (change amount, cancel) need, when one exists.
    public var subscriptionID: String? {
        switch self {
        case .none: return nil
        case let .active(id, _, _), let .ending(id, _, _, _): return id
        }
    }

    public var amountMinor: Int? {
        switch self {
        case .none: return nil
        case let .active(_, amount, _), let .ending(_, amount, _, _): return amount
        }
    }

    public var isEnding: Bool { if case .ending = self { return true }; return false }
}

/// Copy for the cancel confirmation (G-8/G-9): cancelling ends the recurring gift at the
/// current period end and the streak lapses after that — stated plainly, counsel owns no
/// part of this string so it stays inline and testable.
public enum CancelCopy {
    public static func confirmation(periodEnd: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: periodEnd)
        return "Your gift stays active until \(date). After that it won't renew and your streak ends."
    }
}
