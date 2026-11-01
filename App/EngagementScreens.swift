import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import DADFoundation

// Engagement (PRD A-3, I-*, K-*, N-*, R-*, B-*): impact totals, the 24-badge grid, the rankings choice, the
// referral network and the invite link / IRL code, plus the initiative spend drill-in. Bound to
// `EngagementModel` and `InitiativeSpendModel`. State is always carried in text as well as colour, a section
// the server did not answer says so instead of drawing a zero, and nothing here logs.

private struct EngagementBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(Color.dad(scheme == .dark ? "ink-deep" : "paper")).tint(Color.dad("brand-ink"))
    }
}

/// The unavailable-section line: one wording everywhere so a missing figure is never mistaken for none.
private func unavailableLine(_ what: String) -> some View {
    Text("\(what) can’t be shown right now.").font(.footnote).foregroundStyle(.secondary)
}

struct EngagementHome: View {
    @State var model: EngagementModel
    var onClose: (() -> Void)?
    var onSignedOut: () -> Void = {}
    @State private var showQR = false
    @State private var copied = false
    @State private var nameDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let onClose { Button("Close", action: onClose).accessibilityIdentifier("engagement-close") }
                Text("Your impact").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                switch model.phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("engagement-loading")
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 12) {
                        Text(message).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("engagement-error")
                        Button("Try again") { Task { await model.load() } }
                            .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("engagement-retry")
                    }
                case .ready:
                    if let notice = model.refreshNotice {
                        Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("engagement-notice")
                    }
                    if let error = model.actionError {
                        Text(error).font(.footnote).foregroundStyle(Color.dad("fail"))
                            .accessibilityIdentifier("engagement-action-error")
                    }
                    if let snapshot = model.snapshot { content(snapshot) }
                }
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("engagement-home")
        }
        .modifier(EngagementBackground())
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
        .sheet(isPresented: $showQR) {
            if let url = model.snapshot?.referral?.irlURL() { InviteQRSheet(url: url, onClose: { showQR = false }) }
        }
    }

    @ViewBuilder private func content(_ snapshot: EngagementSnapshot) -> some View {
        impactCard(snapshot.impact)
        badges(snapshot.badges)
        rankings
        network(snapshot.network)
        invite(snapshot)
    }

    // MARK: impact (I-1, I-3)

    private func impactCard(_ impact: ImpactTotals?) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lifetime given").font(.footnote).foregroundStyle(.secondary)
                if let impact {
                    Text(impact.givenLabel).font(.title.bold()).accessibilityIdentifier("impact-given")
                    Text("\(impact.initiativesFunded) \(impact.initiativesFunded == 1 ? "initiative" : "initiatives") · \(impact.eventsVolunteered) \(impact.eventsVolunteered == 1 ? "event" : "events")")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("impact-counts")
                } else {
                    Text("—").font(.title.bold()).accessibilityLabel("Not available").accessibilityIdentifier("impact-given")
                    unavailableLine("Your impact")
                }
            }
        }
    }

    // MARK: badges (B-1..B-3), earned/locked in text never colour alone

    @ViewBuilder private func badges(_ collection: BadgeCollection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let collection {
                Text(collection.summaryLabel).font(.headline).accessibilityIdentifier("badge-summary")
                if collection.hasInviteOnlyAccess {
                    Text("You have invite-only event access.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("badge-invite-access")
                }
                ForEach(collection.badges) { badge in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: badge.earned ? "checkmark.seal.fill" : "lock.fill")
                            .foregroundStyle(badge.earned ? Color.dad("brand-ink") : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(badge.shownTitle).fontWeight(badge.earned ? .semibold : .regular)
                            Text(badge.earned ? earnedLine(badge) : badge.rule).font(.caption).foregroundStyle(.secondary)
                            if badge.hasPerk {
                                Text("Perk: \(badge.perk)").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("badge-perk-\(badge.code)")
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(badge.accessibilitySummary)
                    .accessibilityIdentifier("badge-\(badge.code)")
                }
            } else {
                Text("Badges").font(.headline).accessibilityAddTraits(.isHeader)
                unavailableLine("Your badges")
            }
        }
    }

    private func earnedLine(_ badge: Badge) -> String {
        badge.earnedAt.map { "Earned \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Earned"
    }

    // MARK: rankings (K-1..K-3): opt-out hides the position entirely, never a name list

    private var rankings: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rankings").font(.headline).accessibilityAddTraits(.isHeader)
                if let ranking = model.displayedRanking {
                    if ranking.isOptedOut {
                        Text("You’re not shown in rankings.").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("ranking-optedout")
                    } else {
                        if let national = ranking.nationalLabel {
                            Text(national).accessibilityIdentifier("ranking-national")
                        } else if ranking.isNotRankedYet {
                            Text("Not ranked yet.").font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("ranking-unranked")
                        }
                        if let city = ranking.cityLabel {
                            Text(city).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("ranking-city")
                        }
                    }
                    Button(ranking.isOptedOut ? "Show my ranking" : "Hide my ranking") {
                        Task { await model.setRankingOptIn(ranking.isOptedOut) }
                    }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.pendingOptIn != nil)
                    .accessibilityIdentifier("ranking-toggle")
                    Text("Only you see your position. Rankings never list other donors.").font(.caption).foregroundStyle(.secondary)
                } else {
                    unavailableLine("Your ranking")
                }
            }
        }
    }

    // MARK: network (N-1..N-3)

    @ViewBuilder private func network(_ network: NetworkSummary?) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your network").font(.headline).accessibilityAddTraits(.isHeader)
                if let network {
                    Text("\(network.activeCount) active · \(network.annualizedLabel)").accessibilityIdentifier("network-active")
                    if let milestone = network.nextMilestone {
                        Text(milestone.progressLabel).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("network-milestone")
                    }
                    ForEach(Array(network.invitees.enumerated()), id: \.offset) { index, invitee in
                        Text("\(invitee.name) · \(invitee.statusLabel)").font(.footnote)
                            .accessibilityIdentifier("network-invitee-\(index)")
                    }
                    if network.hasAnonymous {
                        Text("\(network.anonymousActive) \(network.anonymousActive == 1 ? "person chooses" : "people choose") to stay anonymous")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network-anonymous")
                    }
                } else {
                    unavailableLine("Your network")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("network-section")
    }

    // MARK: invite link + IRL code (R-1..R-4)

    @ViewBuilder private func invite(_ snapshot: EngagementSnapshot) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Invite friends").font(.headline).accessibilityAddTraits(.isHeader)
                if let referral = snapshot.referral {
                    Text("Your code: \(referral.code)").accessibilityIdentifier("referral-code")
                    if let total = referral.totalConverted {
                        Text("\(total) \(total == 1 ? "person has" : "people have") joined through you")
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("referral-total")
                    } else {
                        unavailableLine("Your referral count")
                    }
                    if let link = referral.inviteURL() {
                        VStack(spacing: 10) {
                            ShareLink(item: link, message: Text(referral.shareMessage())) {
                                Label("Share invite", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }.buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("share-invite")
                            Button(copied ? "Copied" : "Copy link") {
                                UIPasteboard.general.string = link.absoluteString
                                copied = true
                            }.buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("copy-invite")
                            Button("Show QR") { showQR = true }
                                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("show-qr")
                        }
                        Text(link.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("invite-link")
                    } else {
                        Text("Invite links aren’t available in this build.").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("invite-unconfigured")
                    }
                    conversions(referral)
                } else if snapshot.needsPublicName {
                    namePrompt
                } else {
                    unavailableLine("Your invite link")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("invite-section")
    }

    @ViewBuilder private func conversions(_ referral: ReferralInfo) -> some View {
        if let list = referral.conversions {
            if list.isEmpty {
                Text("No one has given through your link yet.").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversions-empty")
            } else {
                Text("Recent first gifts").font(.subheadline.weight(.semibold))
                ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { index, conversion in
                    Text("\(conversion.convertedAt.formatted(date: .abbreviated, time: .omitted)) · \(conversion.kind.label)")
                        .font(.footnote).accessibilityIdentifier("conversion-\(index)")
                }
                if list.count > 5 || referral.hasMoreConversions {
                    Text("Older first gifts aren’t listed here.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            unavailableLine("Your recent first gifts")
        }
    }

    @ViewBuilder private var namePrompt: some View {
        Text("Choose the name your invite link goes out under. Friends see it when they open your link.").font(.footnote)
        TextField("Public name", text: $nameDraft)
            .textFieldStyle(.roundedBorder).textContentType(.name).textInputAutocapitalization(.words)
            .accessibilityLabel("Public name").accessibilityIdentifier("name-field")
        if let error = model.nameError {
            Text(error).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("name-error")
        }
        Button("Create my invite link") { Task { await model.choosePublicName(nameDraft) } }
            .buttonStyle(DADButtonStyle(.primary)).disabled(model.isSavingName || nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("save-name")
    }
}

/// The full-screen IRL code (R-1, R-2): a QR of the in-person link, drawn locally with CoreImage so no image
/// is fetched and no untrusted file is parsed. Meant to be scanned from a phone screen face to face.
private struct InviteQRSheet: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Button("Close", action: onClose).frame(maxWidth: .infinity, alignment: .trailing).accessibilityIdentifier("qr-close")
            Text("Show this code").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if let image = Self.qr(url.absoluteString) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 320).padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("QR code for your invite link").accessibilityIdentifier("qr-code")
            } else {
                Text("The code couldn’t be drawn. Share your link instead.").accessibilityIdentifier("qr-failed")
            }
            Text("A friend scans it with their phone camera to open your invite.").font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(28).modifier(EngagementBackground()).accessibilityElement(children: .contain).accessibilityIdentifier("qr-sheet")
    }

    private static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// "See every dollar this initiative has spent" (A-3): spend by category, totals only (PRD §5.2).
struct InitiativeSpendScreen: View {
    @State var model: InitiativeSpendModel
    let title: String
    let onClose: () -> Void
    var onSignedOut: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Close", action: onClose).accessibilityIdentifier("spend-close")
                Text("Where the money went").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(title).font(.headline)
                switch model.phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("spend-loading")
                case .unpublished:
                    Text("This initiative’s spending hasn’t been published yet.").accessibilityIdentifier("spend-unpublished")
                case .failed(let message):
                    Text(message).accessibilityIdentifier("spend-error")
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("spend-retry")
                case .ready(let summary):
                    DADCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total spent").font(.footnote).foregroundStyle(.secondary)
                            Text(summary.totalLabel).font(.title.bold()).accessibilityIdentifier("spend-total")
                        }
                    }
                    if summary.slices.isEmpty {
                        Text("No spending by category yet.").font(.footnote).accessibilityIdentifier("spend-empty")
                    }
                    ForEach(Array(summary.slices.enumerated()), id: \.offset) { index, slice in
                        HStack {
                            Text(slice.category)
                            Spacer()
                            Text(slice.amountLabel).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine).accessibilityIdentifier("spend-row-\(index)")
                    }
                    Text("Totals by category, not individual payments.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
        .modifier(EngagementBackground())
        .accessibilityElement(children: .contain).accessibilityIdentifier("spend-screen")
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
    }
}
