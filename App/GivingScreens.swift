import SwiftUI
import SafariServices
import DADFoundation

// Giving screens (PRD G-1..G-11, D-5): the recurring gift, its amount, the payment method, and the
// cancel path. Bound to `GivingModel`. The app never handles card data: starting a gift and updating
// the card both open a page hosted outside the app (the system's secure Safari view), and when that
// page closes the model re-reads the server until it reflects the outcome.

/// What the giving screens need from the composition root.
struct GivingKit {
    let service: any GivingService
    /// DEBUG `--stub-backend` only: stands in for the hosted page finishing (the Stripe webhook).
    /// Always nil in a release build, which therefore always opens the real hosted page.
    var stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    /// How long the model waits between re-reads after a hosted page closes.
    var pollDelay: Duration = .seconds(2)

    @MainActor func makeModel() -> GivingModel { GivingModel(service: service, pollDelay: pollDelay) }
}

/// The system's secure browser view, with a delegate so "Done" tells the model the page closed.
private struct SafariPage: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}

#if DEBUG
/// Stands in for the Stripe-hosted page under `--stub-backend`, where `stub.invalid` cannot load.
private struct StubHostedPage: View {
    let purpose: HostedHandoff.Purpose
    let complete: @Sendable (HostedHandoff.Purpose) -> Void
    let onFinish: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Secure payment page").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(purpose == .startGift ? "Pretend checkout for a monthly gift." : "Pretend card update.")
            Button("Complete payment") { complete(purpose); onFinish() }
                .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("stub-complete")
            Button("Close without paying") { onFinish() }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("stub-close")
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dadBackground()
        .accessibilityElement(children: .contain).accessibilityIdentifier("hosted-page-stub")
    }
}
#endif

/// The hosted page, presented as a sheet. Closing it by any route (Done, swipe down) ends in `onFinish`.
struct HostedPageSheet: View {
    let handoff: HostedHandoff
    let stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    let onFinish: () -> Void
    var body: some View {
        #if DEBUG
        if let stubComplete {
            StubHostedPage(purpose: handoff.purpose, complete: stubComplete, onFinish: onFinish)
        } else {
            SafariPage(url: handoff.url, onFinish: onFinish).ignoresSafeArea()
        }
        #else
        SafariPage(url: handoff.url, onFinish: onFinish).ignoresSafeArea()
        #endif
    }
}

private func shortDate(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

/// Set / change your recurring gift (G-1/G-2/G-7), start one (D-5), update the card, or cancel (G-8/G-9).
struct GiftScreen: View {
    @State var model: GivingModel
    var stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    var onSignedOut: () -> Void = {}
    @State private var confirmingCancel = false
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.recurring == .none && model.hasLoaded ? "Your gift" : "Set your gift")
                .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if !model.hasLoaded {
                loadingOrFailed
            } else {
                loaded
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gift-screen")
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
        .sheet(isPresented: Binding(get: { model.handoff != nil }, set: { shown in
            if !shown { Task { await model.handoffFinished() } }
        })) {
            if let handoff = model.handoff {
                HostedPageSheet(handoff: handoff, stubComplete: stubComplete, onFinish: { Task { await model.handoffFinished() } })
            }
        }
    }

    @ViewBuilder private var loadingOrFailed: some View {
        if case .failed(let message) = model.phase {
            VStack(alignment: .leading, spacing: 12) {
                Text(message).accessibilityIdentifier("gift-error")
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("gift-retry")
            }
        } else {
            ProgressView("Loading your gift…").accessibilityIdentifier("gift-loading")
        }
    }

    @ViewBuilder private var loaded: some View {
        status
        if case .active = model.recurring { stepper }
        if model.recurring.subscriptionID != nil { paymentSection }
        feedback
        if case .active = model.recurring { cancelSection }
    }

    // MARK: status

    @ViewBuilder private var status: some View {
        switch model.recurring {
        case .none:
            DADCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You don’t have a monthly gift yet.").font(.headline).accessibilityIdentifier("gift-none")
                    Text("You’ll finish on a secure page hosted by our payment provider. This app never handles your card details.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Start a monthly gift") { Task { await model.startGift() } }
                        .buttonStyle(DADButtonStyle(.primary)).disabled(model.isBusy).accessibilityIdentifier("start-gift")
                }
            }
        case .preparing:
            DADCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("We’re getting your first gift ready.").font(.headline)
                    Text("It can take a moment after checkout. Refresh to check again.").font(.footnote).foregroundStyle(.secondary)
                    Button("Refresh") { Task { await model.load() } }
                        .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("gift-refresh")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("gift-preparing")
        case .active, .ending:
            DADCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(formatUSDMinor(model.recurring.amountMinor ?? 0))/month").font(.title2.bold())
                        .accessibilityIdentifier("gift-monthly")
                    renewalLines
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("gift-status")
        }
    }

    @ViewBuilder private var renewalLines: some View {
        switch model.recurring {
        case let .active(_, amount, periodEnd):
            if let pending = model.offer?.pending {
                Text("Changing to \(formatUSDMinor(pending.amountMinor))/month from \(shortDate(pending.effectiveAt))\(pending.confirmed ? "" : ", awaiting confirmation").")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-pending-change")
            } else if let next = model.offer?.nextAmountMinor, next != amount {
                Text("Your next renewal will be \(formatUSDMinor(next)) on \(shortDate(model.offer?.effectiveAt ?? periodEnd)).")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-renewal")
            } else {
                Text("Renews \(shortDate(model.offer?.effectiveAt ?? periodEnd)).")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-renewal")
            }
        case let .ending(_, _, _, stopsAt):
            Text("Your gift won’t renew — it stays active until \(shortDate(stopsAt)).")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-ending")
        default: EmptyView()
        }
    }

    // MARK: amount

    private var stepper: some View {
        VStack(alignment: .leading, spacing: 16) {
            DADCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.selection.dailyLabel).font(.system(size: amountSize, weight: .bold))
                        .accessibilityIdentifier("gift-daily")
                    Text("\(model.selection.monthlyLabel) · charged monthly").foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button { model.decrement() } label: { Image(systemName: "minus.circle.fill").font(.title) }
                            .accessibilityLabel("Decrease gift")
                            .disabled(model.selection.dailyDollars <= GiftAmount.minDailyDollars || model.isBusy)
                        Button { model.increment() } label: { Image(systemName: "plus.circle.fill").font(.title) }
                            .accessibilityLabel("Increase gift")
                            .disabled(model.selection.dailyDollars >= GiftAmount.maxDailyDollars || model.isBusy)
                    }
                }
            }
            DADStreakBar(filled: min(model.selection.dailyDollars, 30))
            Button("Save gift") { Task { await model.applySelection() } }
                .buttonStyle(DADButtonStyle(.primary))
                .disabled(model.isBusy)
                .accessibilityIdentifier("save-gift")
        }
    }

    // MARK: payment method

    private var paymentSection: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Payment method").font(.headline).accessibilityAddTraits(.isHeader)
                Text(paymentLine).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("payment-status")
                if case .active = model.recurring {
                    Button("Update payment method") { Task { await model.updatePayment() } }
                        .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("update-payment")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("payment-card")
    }

    private var paymentLine: String {
        guard let payment = model.payment else { return "Update your card on a secure page hosted by our payment provider." }
        switch payment.kind {
        case .none: return "Update your card on a secure page hosted by our payment provider."
        case .pending, .open: return "A card update is in progress."
        case .applied: return payment.completedAt.map { "Card updated \(shortDate($0))." } ?? "Card updated."
        case .expired: return "The last card update expired. You can start again."
        case .cancelled: return "The last card update was cancelled. Your card is unchanged."
        }
    }

    // MARK: feedback + cancel

    @ViewBuilder private var feedback: some View {
        if model.isConfirming {
            ProgressView("Confirming with the payment provider…").accessibilityIdentifier("gift-confirming")
        }
        if let notice = model.notice {
            Text(notice).font(.footnote).accessibilityIdentifier("gift-notice")
        }
        if case .failed(let message) = model.phase {
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("gift-failure")
        }
    }

    @ViewBuilder private var cancelSection: some View {
        if confirmingCancel {
            // Inline confirmation rather than a `confirmationDialog`: the OS action sheet presents in a
            // separate layer whose buttons the simulator's XCUITest harness surfaces unreliably, so an
            // inline block is both deterministic to test and keeps the ends-streak copy beside the choice.
            VStack(alignment: .leading, spacing: 12) {
                Text("Cancel your gift?").font(.headline)
                if case let .active(_, _, periodEnd) = model.recurring {
                    Text(CancelCopy.confirmation(periodEnd: periodEnd)).font(.footnote).foregroundStyle(.secondary)
                }
                Button("End my gift") { confirmingCancel = false; Task { await model.cancel() } }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy)
                Button("Keep giving") { confirmingCancel = false }
                    .buttonStyle(DADButtonStyle(.primary))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cancel-confirm")
        } else {
            Button("Cancel gift") { confirmingCancel = true }
                .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy)
        }
    }
}

/// The gift screen presented as a sheet from the donor home or from Settings (cancel-before-delete).
struct GiftSheet: View {
    let model: GivingModel
    let stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    let onClose: () -> Void
    let onSignedOut: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button("Close", action: onClose).padding(.horizontal, 28).padding(.top, 20)
                    .accessibilityIdentifier("gift-close")
                GiftScreen(model: model, stubComplete: stubComplete, onSignedOut: onSignedOut)
            }
        }.dadBackground()
    }
}
