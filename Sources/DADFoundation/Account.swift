import Foundation

// Account & settings (PRD §6.11, §6.12) — the iOS counterpart of Android Phase 7, built here as
// the automatable slice of Phase H (release readiness): the App Store mandates an in-app
// account-deletion flow, which iOS did not yet have. Pure value types so the preferences block,
// its optimistic version, and the delete-account confirm gate are unit-testable without I/O.

// MARK: - Profile summary (read-only header)

/// The account header settings shows. `accountRole` is fixed at creation and immutable (D-1), so
/// it is display-only; `zip` drives the streak's local-day rollover (§10).
public struct AccountProfileSummary: Sendable, Equatable {
    public let email: String
    public let accountRole: String
    public let zip: String?
    public let city: String?
    public let phone: String?

    public init(email: String, accountRole: String, zip: String?, city: String?, phone: String?) {
        self.email = email
        self.accountRole = accountRole
        self.zip = zip
        self.city = city
        self.phone = phone
    }

    public var zipLabel: String {
        guard let zip, !zip.isEmpty else { return "Not set" }
        return zip
    }
}

// MARK: - Preferences (§6.11)

/// The donor's preference block, carrying the optimistic-concurrency `version` it was read at so a
/// stale overwrite is rejected server-side. Payment-failure email is deliberately absent — it is
/// non-toggleable server-side.
public struct AccountPreferences: Sendable, Equatable {
    public let version: Int
    public var referralEmails: Bool
    public var marketingEmails: Bool
    public var pushReferralConverted: Bool
    public var pushStreakAtRisk: Bool
    public var pushStreakMilestone: Bool
    public var pushStreakLapsed: Bool
    public var pushBadgeEarned: Bool
    public var pushEventNearby: Bool
    public var pushEventReminder: Bool
    public var pushEventPromoted: Bool
    public var pushGiftProcessed: Bool
    public var rankingsOptedOut: Bool
    public var networkVisible: Bool
    public var volunteer: Bool

    public init(
        version: Int, referralEmails: Bool, marketingEmails: Bool, pushReferralConverted: Bool,
        pushStreakAtRisk: Bool, pushStreakMilestone: Bool, pushStreakLapsed: Bool,
        pushBadgeEarned: Bool, pushEventNearby: Bool, pushEventReminder: Bool,
        pushEventPromoted: Bool, pushGiftProcessed: Bool, rankingsOptedOut: Bool,
        networkVisible: Bool, volunteer: Bool
    ) {
        self.version = version
        self.referralEmails = referralEmails
        self.marketingEmails = marketingEmails
        self.pushReferralConverted = pushReferralConverted
        self.pushStreakAtRisk = pushStreakAtRisk
        self.pushStreakMilestone = pushStreakMilestone
        self.pushStreakLapsed = pushStreakLapsed
        self.pushBadgeEarned = pushBadgeEarned
        self.pushEventNearby = pushEventNearby
        self.pushEventReminder = pushEventReminder
        self.pushEventPromoted = pushEventPromoted
        self.pushGiftProcessed = pushGiftProcessed
        self.rankingsOptedOut = rankingsOptedOut
        self.networkVisible = networkVisible
        self.volunteer = volunteer
    }

    public struct Toggle: Sendable, Equatable {
        public let key: String
        public let label: String
        public let value: Bool
    }

    /// The push category toggles (§6.11), in display order. Payment-failure email is absent
    /// (non-toggleable server-side).
    public var pushToggles: [Toggle] {
        [
            Toggle(key: "push_referral_converted", label: "Someone joined through you", value: pushReferralConverted),
            Toggle(key: "push_streak_at_risk", label: "Streak at risk", value: pushStreakAtRisk),
            Toggle(key: "push_streak_milestone", label: "Streak milestone", value: pushStreakMilestone),
            Toggle(key: "push_streak_lapsed", label: "Streak lapsed", value: pushStreakLapsed),
            Toggle(key: "push_badge_earned", label: "Badge earned", value: pushBadgeEarned),
            Toggle(key: "push_event_nearby", label: "Events nearby", value: pushEventNearby),
            Toggle(key: "push_event_reminder", label: "Event reminders", value: pushEventReminder),
            Toggle(key: "push_event_promoted", label: "Event promoted", value: pushEventPromoted),
            Toggle(key: "push_gift_processed", label: "Gift processed", value: pushGiftProcessed),
        ]
    }

    public var emailToggles: [Toggle] {
        [
            Toggle(key: "referral_emails", label: "Referral emails", value: referralEmails),
            Toggle(key: "marketing_emails", label: "Marketing emails", value: marketingEmails),
        ]
    }

    /// Inverted for display: "Show my ranking" = NOT opted out.
    public var showRanking: Bool { !rankingsOptedOut }

    /// A copy with one toggle flipped by key; an unknown key returns self unchanged.
    public func with(_ key: String, _ value: Bool) -> AccountPreferences {
        var copy = self
        switch key {
        case "referral_emails": copy.referralEmails = value
        case "marketing_emails": copy.marketingEmails = value
        case "push_referral_converted": copy.pushReferralConverted = value
        case "push_streak_at_risk": copy.pushStreakAtRisk = value
        case "push_streak_milestone": copy.pushStreakMilestone = value
        case "push_streak_lapsed": copy.pushStreakLapsed = value
        case "push_badge_earned": copy.pushBadgeEarned = value
        case "push_event_nearby": copy.pushEventNearby = value
        case "push_event_reminder": copy.pushEventReminder = value
        case "push_event_promoted": copy.pushEventPromoted = value
        case "push_gift_processed": copy.pushGiftProcessed = value
        case "rankings_opted_out": copy.rankingsOptedOut = value
        case "network_visible": copy.networkVisible = value
        case "volunteer": copy.volunteer = value
        default: break
        }
        return copy
    }
}

// MARK: - Delete account (store-mandated, §6.12)

/// The delete-account confirm gate. Deletion is irreversible (backend removes personal data, keeps
/// legally-required gift records), so the donor must type the exact word before the action enables.
public struct DeleteAccountGate: Sendable, Equatable {
    public static let confirmWord = "DELETE"

    public let typed: String
    public init(typed: String) { self.typed = typed }

    public var isConfirmed: Bool { typed == Self.confirmWord }

    public var helpText: String {
        "This permanently deletes your personal data. Your required gift records are kept. " +
            "Type \(Self.confirmWord) to confirm."
    }
}
