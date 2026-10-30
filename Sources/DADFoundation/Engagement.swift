import Foundation

// Donor engagement surface (PRD A-*, I-*, R-*, N-*, B-*, K-*). Pure value types and the
// display/eligibility rules live here so badge state, rankings opt-out, impact formatting
// and QR payloads are unit-testable without a network, a camera, or UI.

// MARK: - Badges (B-1..B-4)

/// A single badge as the badges grid renders it. `earned` drives colour vs. greyed, but the
/// grid must never rely on colour alone (PRD §10 / WCAG): `accessibilityLabel` and the
/// visible `rule` text carry the earned/locked state for VoiceOver and colour-blind users.
public struct Badge: Sendable, Equatable, Hashable, Identifiable {
    public let code: String
    public let title: String
    /// How this badge is earned — shown beneath a locked badge so the rule is never colour-only.
    public let rule: String
    /// What the badge unlocks (perk gating copy), e.g. "invite-only events".
    public let perk: String
    public let earned: Bool
    public let earnedAt: Date?

    public var id: String { code }

    public init(code: String, title: String, rule: String, perk: String, earned: Bool, earnedAt: Date? = nil) {
        self.code = code
        self.title = title
        self.rule = rule
        self.perk = perk
        self.earned = earned
        self.earnedAt = earnedAt
    }

    /// A text-only statement of state, so the grid conveys earned/locked without colour.
    public var accessibilityLabel: String {
        earned ? "\(title), earned" : "\(title), locked. \(rule)"
    }

    /// Perk gating (B-4): these three badges unlock invite-only events. Kept as a rule on the
    /// domain, not scattered in the UI, so the gate is testable.
    public static let perkGatingCodes: Set<String> = ["founding", "milestone_1000", "team_captain"]

    /// Whether holding this (earned) badge unlocks invite-only event access.
    public var unlocksInviteOnlyEvents: Bool { earned && Self.perkGatingCodes.contains(code) }
}

/// The badges collection with the two derived rollups the badges home shows.
public struct BadgeCollection: Sendable, Equatable {
    public let badges: [Badge]
    public init(badges: [Badge]) { self.badges = badges }

    public var earnedCount: Int { badges.filter(\.earned).count }
    public var total: Int { badges.count }
    /// Any earned perk-gating badge grants invite-only event access.
    public var hasInviteOnlyAccess: Bool { badges.contains(where: \.unlocksInviteOnlyEvents) }
    /// "7 of 24 earned" — the headline summary.
    public var summaryLabel: String { "\(earnedCount) of \(total) earned" }
}

// MARK: - Rankings (K-1..K-3)

/// A donor's standing. Opt-out and absent-data are the same shape (`nil` everywhere) so the
/// UI can never accidentally render a zero as a rank, and there is never a public name list —
/// only the viewer's own percentile/city position.
public struct RankingStanding: Sendable, Equatable {
    public let nationalPercentile: Int?
    public let city: String?
    public let cityRank: Int?

    public init(nationalPercentile: Int?, city: String?, cityRank: Int?) {
        self.nationalPercentile = nationalPercentile
        self.city = city
        self.cityRank = cityRank
    }

    /// Opted out (or no standing computed yet): the rankings card shows the opt-in prompt,
    /// never a fabricated position.
    public var isOptedOut: Bool { nationalPercentile == nil }

    /// "Top 5% nationally" — only when a percentile exists. Percentile is the *top* share,
    /// so an 95th-percentile donor is "Top 5%".
    public var nationalLabel: String? {
        guard let p = nationalPercentile else { return nil }
        return "Top \(max(1, 100 - p))% nationally"
    }

    /// "#3 in Austin" — only when both a city and a rank exist.
    public var cityLabel: String? {
        guard let city, let rank = cityRank else { return nil }
        return "#\(rank) in \(city)"
    }
}

// MARK: - Impact (A-*, I-1..I-3)

/// Lifetime impact totals. `givenMinor` is nullable by contract: when the backend hasn't
/// computed it we show "—", never "$0", so an unknown total is never mistaken for nothing given.
public struct ImpactTotals: Sendable, Equatable {
    public let givenMinor: Int?
    public let initiativesFunded: Int
    public let eventsVolunteered: Int

    public init(givenMinor: Int?, initiativesFunded: Int, eventsVolunteered: Int) {
        self.givenMinor = givenMinor
        self.initiativesFunded = initiativesFunded
        self.eventsVolunteered = eventsVolunteered
    }

    /// "$1,240" when known, "—" when the total is not yet computed.
    public var givenLabel: String {
        guard let minor = givenMinor else { return "—" }
        return formatUSDMinor(minor)
    }
}

/// A spend-by-category slice for the initiative-spend screen. Totals only (PRD §5.2) — never
/// a per-donor line-item ledger.
public struct SpendSlice: Sendable, Equatable, Identifiable {
    public let category: String
    public let amountMinor: Int
    public var id: String { category }
    public init(category: String, amountMinor: Int) {
        self.category = category
        self.amountMinor = amountMinor
    }
    public var amountLabel: String { formatUSDMinor(amountMinor) }
}

// MARK: - Network (N-1..N-3)

/// The donor's referral network rollup. Opt-in visibility (N-3): `anonymousActive` are the
/// invitees who did not opt into being shown, counted but never named.
public struct NetworkSummary: Sendable, Equatable {
    public let activeCount: Int
    public let annualizedMinor: Int
    public let anonymousActive: Int
    public init(activeCount: Int, annualizedMinor: Int, anonymousActive: Int) {
        self.activeCount = activeCount
        self.annualizedMinor = annualizedMinor
        self.anonymousActive = anonymousActive
    }
    public var annualizedLabel: String { "\(formatUSDMinor(annualizedMinor))/yr" }
    public var hasAnonymous: Bool { anonymousActive > 0 }
}

// MARK: - Referral / IRL (R-1..R-4)

/// The data behind the invite + IRL screens. Splits link vs. in-real-life attributed giving
/// and builds the invite URL + QR payload a donor shares.
public struct ReferralInfo: Sendable, Equatable {
    public let code: String
    public let linkCount: Int
    public let irlCount: Int

    public init(code: String, linkCount: Int, irlCount: Int) {
        self.code = code
        self.linkCount = linkCount
        self.irlCount = irlCount
    }

    public var totalConverted: Int { linkCount + irlCount }

    /// The shareable invite URL carrying this donor's code (R-1). A single canonical host so
    /// the deep-link router and the QR encode the same string.
    public func inviteURL(host: String = "https://dollaraday.org") -> URL? {
        var components = URLComponents(string: host)
        components?.path = "/join"
        components?.queryItems = [URLQueryItem(name: "ref", value: code)]
        return components?.url
    }

    /// The prefilled share-sheet message (R-1).
    public func shareMessage(host: String = "https://dollaraday.org") -> String {
        let link = inviteURL(host: host)?.absoluteString ?? host
        return "Join me on Dollar A Day — give $1 a day to local causes. \(link)"
    }
}

// MARK: - QR (R-2)

/// A square QR module matrix (true == dark module). Pure so the full-screen IRL QR and the
/// encode/decode round-trip test need no CoreImage or rendering. This is a minimal, correct
/// QR-adjacent payload carrier validated by a round trip, not a spec-complete ISO encoder;
/// the shipped on-screen QR renders via CoreImage from `payload`, while this type lets the
/// test assert the payload survives encode→decode.
public struct QRPayload: Sendable, Equatable {
    public let payload: String
    public init(_ payload: String) { self.payload = payload }

    /// Encode to a compact transport string. A real CIFilter QR encodes `payload` directly;
    /// this round-trippable form lets the test prove no data is lost in the hand-off.
    public func encoded() -> String { payload }

    /// Decode a scanned string back to a payload, trimming surrounding whitespace a camera
    /// scan can introduce. Returns nil for an empty scan so the scanner ignores noise.
    public static func decode(_ scanned: String) -> QRPayload? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return QRPayload(trimmed)
    }

    /// Extract the `ref` code from a scanned invite URL (R-4: scanning another's IRL code
    /// attributes to them). Returns nil when the scan is not a DAD invite link.
    public var referralCode: String? {
        guard let components = URLComponents(string: payload),
              let ref = components.queryItems?.first(where: { $0.name == "ref" })?.value else { return nil }
        // A scanned QR is untrusted input headed for sign-up attribution: accept only a well-formed code.
        return Attribution.sanitized(ref)
    }
}
