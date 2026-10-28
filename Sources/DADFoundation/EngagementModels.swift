import Foundation

// Engagement view models + the service seam. The models own explicit load/ready/failed
// state so the impact, badges, network, rankings and referral surfaces are unit-tested
// without a network, a camera, or UI — the same shape as the giving and auth models.

/// Everything the engagement home needs in one load. Grouping the reads lets the model
/// expose a single ready/failed phase to the UI instead of five independent spinners.
public struct EngagementSnapshot: Sendable, Equatable {
    public let impact: ImpactTotals
    public let badges: BadgeCollection
    public let ranking: RankingStanding
    public let network: NetworkSummary
    public let referral: ReferralInfo

    public init(
        impact: ImpactTotals,
        badges: BadgeCollection,
        ranking: RankingStanding,
        network: NetworkSummary,
        referral: ReferralInfo
    ) {
        self.impact = impact
        self.badges = badges
        self.ranking = ranking
        self.network = network
        self.referral = referral
    }
}

/// The seam the engagement model calls. A conformer maps to the generated client (WireAPI)
/// or a preview/test double; all value types so the model stays testable.
public protocol EngagementService: Sendable {
    func snapshot() async throws -> EngagementSnapshot
    /// Opt into or out of the public rankings (K-2). Returns the resulting standing —
    /// opting out yields an all-nil standing so no position is ever shown.
    func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding
}

/// Drives the engagement home. One load fetches the snapshot; `phase` tells the UI whether
/// to show the skeleton, the content, or a retryable error.
@MainActor
@Observable
public final class EngagementModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var snapshot: EngagementSnapshot?

    private let service: any EngagementService

    public init(service: any EngagementService) { self.service = service }

    public func load() async {
        phase = .loading
        do {
            snapshot = try await service.snapshot()
            phase = .ready
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// Toggle rankings visibility (K-2). On success the snapshot's ranking is replaced in
    /// place so the card re-renders to the opt-in prompt or the restored position.
    public func setRankingOptIn(_ optIn: Bool) async {
        guard let current = snapshot else { return }
        do {
            let ranking = try await service.setRankingOptIn(optIn)
            snapshot = EngagementSnapshot(
                impact: current.impact,
                badges: current.badges,
                ranking: ranking,
                network: current.network,
                referral: current.referral
            )
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    static func message(_ error: Error) -> String {
        if let account = error as? AccountError, account == .signedOut { return "Please sign in again." }
        return "Something went wrong. Please try again."
    }
}

/// Drives the IRL QR-scan attribution flow (R-4). The camera capture lives in the App layer
/// behind `ScanSource`; this model owns the state machine — a decoded scan that carries a
/// DAD referral code resolves to `.resolved(code)`, anything else is a clear failure — so the
/// attribution logic is tested without a camera (which the CI simulator cannot provide).
@MainActor
@Observable
public final class ScanModel {
    public enum Phase: Sendable, Equatable {
        case scanning
        case resolved(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .scanning

    public init() {}

    /// Feed a raw scanned string. A DAD invite link yields the referrer's code; anything else
    /// is rejected so a stray QR can't be mistaken for an invite.
    public func ingest(_ scanned: String) {
        guard let payload = QRPayload.decode(scanned) else {
            phase = .failed("That didn't scan. Try again.")
            return
        }
        guard let code = payload.referralCode else {
            phase = .failed("That QR code isn't a Dollar A Day invite.")
            return
        }
        phase = .resolved(code)
    }

    public func reset() { phase = .scanning }
}
