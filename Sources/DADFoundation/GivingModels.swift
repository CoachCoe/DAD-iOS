import Foundation

// Giving view models + the service seam. The models own explicit state machines driven
// through `GivingService`, so the set-gift / change-amount / cancel flows are unit-tested
// without a network, exactly like the auth models.

/// The payment path resolved for this build. The §10 / Risk-1 decision is "support both":
/// in-app Apple Pay only once DAD is an Apple-approved nonprofit, otherwise hand off to the
/// Stripe web checkout. The app never charges in-app directly in R1 — the first charge is
/// backend-driven after payment-method setup — so this only decides which setup affordance
/// the payment screen presents.
public enum PaymentPath: Sendable, Equatable {
    /// Open the hosted Stripe checkout / setup in Safari and return via the deep link.
    case webCheckoutHandoff(URL)
    /// Present the in-app Apple Pay setup sheet (gated behind nonprofit approval).
    case applePay
}

/// The seam the giving models call. A conformer maps to the generated client (WireAPI) or
/// to a preview/test double. Everything is value types so the models stay testable.
public protocol GivingService: Sendable {
    /// Current recurring gift (or `.none`).
    func recurring() async throws -> RecurringState
    /// Change the monthly amount of an existing subscription; returns the resulting state.
    func changeAmount(subscriptionID: String, to amountMinor: Int) async throws -> RecurringState
    /// Cancel at period end; returns the resulting (`.ending`) state.
    func cancel(subscriptionID: String, periodEnd: Date) async throws -> RecurringState
    /// Begin payment-method setup; returns which path to present.
    func beginPayment() async throws -> PaymentPath
}

/// Drives the "set / change your gift" screen. Holds a selected daily amount and the known
/// recurring state, and exposes the operations the screen can perform with explicit phases
/// so the UI never has to infer "is a request in flight".
@MainActor
@Observable
public final class GivingModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case working
        case failed(String)
    }

    public private(set) var recurring: RecurringState = .none
    public private(set) var phase: Phase = .idle
    /// The daily amount the stepper/slider currently shows. Starts at the active amount when
    /// one exists, else the $1/day floor.
    public private(set) var selection: GiftAmount

    private let service: any GivingService

    public init(service: any GivingService, initial: GiftAmount = GiftAmount(dailyDollars: 1)!) {
        self.service = service
        self.selection = initial
    }

    /// Clamp to the $1…$30 daily rule. Out-of-range requests are ignored at the edges rather
    /// than erroring, so the stepper simply stops.
    public func setDaily(_ dollars: Int) {
        guard let amount = GiftAmount(dailyDollars: max(dollars, GiftAmount.minDailyDollars)) else { return }
        selection = amount
    }

    public func increment() { setDaily(selection.dailyDollars + 1) }
    public func decrement() { setDaily(selection.dailyDollars - 1) }

    /// Load the current recurring gift and sync the selection to it.
    public func load() async {
        phase = .working
        do {
            let state = try await service.recurring()
            recurring = state
            if let minor = state.amountMinor, let amount = GiftAmount(monthlyMinor: minor) {
                selection = amount
            }
            phase = .idle
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    /// Apply the current selection to the existing subscription (G-7). No-op with a clear
    /// failure when there is no subscription to change — the set-up-first case the UI gates on.
    public func applySelection() async {
        guard let id = recurring.subscriptionID else {
            phase = .failed("Set up a gift before changing the amount.")
            return
        }
        phase = .working
        do {
            recurring = try await service.changeAmount(subscriptionID: id, to: selection.monthlyMinor)
            phase = .idle
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    /// Cancel at period end (G-8/G-9). Requires an active subscription with a known period end.
    public func cancel() async {
        guard case let .active(id, _, periodEnd) = recurring else {
            phase = .failed("There's no active gift to cancel.")
            return
        }
        phase = .working
        do {
            recurring = try await service.cancel(subscriptionID: id, periodEnd: periodEnd)
            phase = .idle
        } catch {
            phase = .failed(error.userMessage)
        }
    }
}
