import SwiftUI
import DADFoundation

// Donor home reads (PRD S-1..S-4, A-1..A-5, I-1..I-3, gift history). Bound to `DashboardModel` and
// `GiftHistoryModel`; every state the server can produce has its own on-screen answer, and state is
// always carried in text as well as colour.

/// "2025-01-02" -> "Jan 2, 2025"; anything unparseable is shown as sent rather than dropped.
private func friendlyDate(_ value: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .omitted)
}

struct DonorHomeView: View {
    @State private var model: DashboardModel
    let onSignedOut: () -> Void
    private let service: any DashboardService
    @State private var showHistory = false

    init(service: any DashboardService, onSignedOut: @escaping () -> Void) {
        self.service = service
        self.onSignedOut = onSignedOut
        _model = State(initialValue: DashboardModel(service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = model.refreshNotice {
                Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("dashboard-notice")
            }
            switch model.phase {
            case .loading:
                ProgressView("Loading your dashboard…").accessibilityIdentifier("dashboard-loading")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).accessibilityIdentifier("dashboard-error")
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("dashboard-retry")
                }
            case .ready(.preparing):
                DADCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Getting your dashboard ready").font(.headline)
                        Text("Your numbers appear here once your first gift has been counted.").font(.footnote)
                        Button("Refresh") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.secondary))
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("dashboard-preparing")
            case .ready(.ready(let dashboard)):
                DashboardCards(dashboard: dashboard)
            }
            InitiativeCard(phase: model.initiative, onRetry: { Task { await model.load() } })
            Button("Gift history") { showHistory = true }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("open-history")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("donor-home")
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
        .sheet(isPresented: $showHistory) {
            GiftHistoryScreen(service: service, onClose: { showHistory = false }, onSignedOut: { showHistory = false; onSignedOut() })
        }
    }
}

private struct DashboardCards: View {
    let dashboard: DonorDashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            streak
            impact
            if let network = dashboard.network {
                DADCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your network").font(.headline).accessibilityAddTraits(.isHeader)
                        Text("Together your network funds \(formatUSDMinor(network.annualizedMinor)) a year")
                            .accessibilityIdentifier("network-annualized")
                        Text("\(network.activeCount) active \(network.activeCount == 1 ? "donor" : "donors")")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let referrals = dashboard.referrals {
                            Text("\(referrals.joined) joined through you · \(referrals.totalLabel) given")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("network-card")
            }
        }
    }

    @ViewBuilder private var streak: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                if dashboard.foundingDonor {
                    Label("Founding donor", systemImage: "star.fill").font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("founding-donor")
                }
                if let streak = dashboard.streak {
                    Text(streak.headline).font(.title.bold()).accessibilityIdentifier("streak-count")
                    if let ladder = streak.ladder {
                        let filled = ladder.bar.filter { $0 }.count
                        DADStreakBar(filled: filled, total: max(ladder.bar.count, 1))
                        if let next = ladder.nextLabel { Text(next).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("streak-next") }
                    }
                    if streak.atRisk {
                        Label(streak.graceEndsAt.map { "A renewal didn’t go through. Update your payment by \($0.formatted(date: .abbreviated, time: .omitted)) to keep your streak." }
                              ?? "A renewal didn’t go through. Update your payment to keep your streak.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).accessibilityIdentifier("streak-at-risk")
                    }
                } else {
                    // The server says the figure is not known: say so rather than show a zero streak.
                    Text("Your streak isn’t available right now.").font(.headline).accessibilityIdentifier("streak-unknown")
                }
                rankLine
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("streak-card")
    }

    @ViewBuilder private var rankLine: some View {
        switch dashboard.rank {
        case .ranked(let rank):
            Text(rank.nationalLabel).font(.subheadline.weight(.semibold)).accessibilityIdentifier("rank-national")
            if let city = rank.cityLabel { Text(city).font(.footnote).foregroundStyle(.secondary) }
        case .notRankedYet:
            Text("Not ranked yet.").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("rank-unranked")
        case .optedOut:
            EmptyView()   // S-4: a hidden donor shows no rank line at all
        }
    }

    private var impact: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Total given").font(.footnote).foregroundStyle(.secondary)
                Text(dashboard.impact.givenLabel).font(.title.bold()).accessibilityIdentifier("dash-given")
                Text("\(dashboard.impact.initiativesFunded) \(dashboard.impact.initiativesFunded == 1 ? "initiative" : "initiatives") funded · \(dashboard.impact.eventsVolunteered) \(dashboard.impact.eventsVolunteered == 1 ? "event" : "events") volunteered")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("impact-card")
    }
}

private struct InitiativeCard: View {
    let phase: DashboardModel.InitiativePhase
    let onRetry: () -> Void

    var body: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today your $1 funded").font(.headline).accessibilityAddTraits(.isHeader)
                switch phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("initiative-loading")
                case .none:
                    Text("Nothing is in today’s rotation yet. Check back tomorrow.").font(.footnote)
                        .accessibilityIdentifier("initiative-none")
                case .failed:
                    Text("Today’s initiative isn’t available right now.").font(.footnote).accessibilityIdentifier("initiative-error")
                    Button("Try again", action: onRetry).buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("initiative-retry")
                case .ready(let initiative):
                    Text(initiative.title).font(.title3.bold()).accessibilityIdentifier("initiative-title")
                    Text("\(initiative.location) · \(initiative.kind.capitalized) · Started \(friendlyDate(initiative.startedOn))")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !initiative.summary.isEmpty { Text(initiative.summary) }
                    ForEach(initiative.headlineMetrics) { metric in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(metric.valueLabel).font(.headline)
                            Text(metric.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(TodayInitiative.attributionNote).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("initiative-note")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("initiative-card")
    }
}

/// Gift history (paged) with an inline gift record per row and the calendar-year total on top.
struct GiftHistoryScreen: View {
    @State private var model: GiftHistoryModel
    let onClose: () -> Void
    let onSignedOut: () -> Void
    @Environment(\.colorScheme) private var scheme

    init(service: any DashboardService, onClose: @escaping () -> Void, onSignedOut: @escaping () -> Void) {
        self.onClose = onClose
        self.onSignedOut = onSignedOut
        _model = State(initialValue: GiftHistoryModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Close", action: onClose).accessibilityIdentifier("history-close")
                Text("Gift history").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let summary = model.summary {
                    DADCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(String(summary.year)) total").font(.footnote).foregroundStyle(.secondary)
                            Text(summary.netLabel).font(.title2.bold()).accessibilityIdentifier("history-year-total")
                            Text("Sandbox records, not tax receipts.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                content
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
        .modifier(HistoryBackground())
        .accessibilityElement(children: .contain).accessibilityIdentifier("history-screen")
        .task { await model.load() }
        .onDisappear { model.cancel() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().accessibilityIdentifier("history-loading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message).accessibilityIdentifier("history-error")
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("history-retry")
            }
        case .ready:
            if model.gifts.isEmpty {
                Text("No gifts yet. Once you give, each gift appears here.").accessibilityIdentifier("history-empty")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.gifts.enumerated()), id: \.element.id) { index, gift in
                        row(gift, index: index)
                    }
                }
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isLoadingMore { ProgressView().accessibilityIdentifier("history-more-loading") }
        if let error = model.moreError { Text(error).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("history-more-error") }
        if model.hasMore && !model.isLoadingMore {
            Button(model.moreError == nil ? "Load more" : "Try again") { model.requestMore() }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("history-more")
        }
        if model.reachedLimit {
            Text("Showing your \(GiftHistoryModel.maxRows) most recent gifts.").font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("history-limit")
        }
    }

    @ViewBuilder private func row(_ gift: GiftEntry, index: Int) -> some View {
        let open = model.receipt?.giftID == gift.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { model.hideReceipt() } else { Task { await model.showReceipt(giftID: gift.id) } }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gift.paidAt.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                    Text("\(gift.frequencyLabel) · \(gift.netLabel)").font(.subheadline)
                    if let refund = gift.refundLabel { Text(refund).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the gift record" : "Shows the gift record")
            .accessibilityIdentifier("gift-row-\(index)")
            if open { receiptView }
            Divider()
        }
    }

    @ViewBuilder private var receiptView: some View {
        switch model.receipt {
        case .loading:
            ProgressView().accessibilityIdentifier("receipt-loading")
        case .failed(_, let message):
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("receipt-error")
        case .ready(let receipt):
            VStack(alignment: .leading, spacing: 4) {
                Text("Gift record").font(.subheadline.weight(.semibold))
                Text("Amount \(receipt.gift.amountLabel)")
                if receipt.gift.refundedMinor > 0 { Text("Refunded \(formatUSDMinor(receipt.gift.refundedMinor))") }
                Text("Net \(receipt.gift.netLabel)")
                ForEach(receipt.refunds) { refund in
                    Text("Refund \(formatUSDMinor(refund.amountMinor)) · \(refund.status.capitalized)").font(.caption).foregroundStyle(.secondary)
                }
                if !receipt.taxReceipt {
                    Text("This is a sandbox record, not a tax receipt.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color.dad("ink") : Color.dad("line").opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain).accessibilityIdentifier("receipt-detail")
        case nil:
            EmptyView()
        }
    }
}

private struct HistoryBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(Color.dad(scheme == .dark ? "ink-deep" : "paper")).tint(Color.dad("brand-ink"))
    }
}
