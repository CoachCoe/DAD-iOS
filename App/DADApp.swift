import SwiftUI
import DADFoundation
import SafariServices
import CryptoKit

/// Preview/UITest launch switches exist only in DEBUG builds: a release binary ignores them, so a
/// shipped app can never be steered into synthetic data or a canned screen by launch arguments.
private func launchFlag(_ name: String) -> Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains(name)
    #else
    false
    #endif
}

private func tokenColor(_ name: String) -> Color { Color.dad(name) }

private struct AppBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.background(tokenColor(scheme == .dark ? "ink-deep" : "paper")) }
}

#if DEBUG
private final class PreviewStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    init(signedIn: Bool = true) {
        value = signedIn ? Credentials(access: "preview", refresh: "preview-refresh", expiresAt: .distantFuture) : nil
    }
    func load() throws -> Credentials? { lock.withLock { value } }
    func save(_ credentials: Credentials) throws { lock.withLock { value = credentials } }
    func clear() throws { lock.withLock { value = nil } }
}
#endif

#if DEBUG
private actor PreviewAPI: AccountAPI {
    private var failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }
    func profile(access: String) async throws -> AccountProfile {
        try await Task.sleep(for: .milliseconds(250))
        if failFirst { failFirst = false; throw AccountError.unavailable }
        return AccountProfile(email: "alex@example.org", publicName: "Alex")
    }
    func refresh(token: String) async throws -> Credentials { throw AccountError.signedOut }
    func claim(token: String) async throws -> Credentials { throw AccountError.unavailable }
    func logout(access: String) async throws {}
}
#endif

@MainActor @Observable
private final class AccountModel {
    enum State: Equatable { case loading, ready(AccountProfile), unavailable, signedOut }
    var state = State.loading
    let session: AccountSession?
    /// Sign-in transport for the unauthenticated stack: the real `WireAuth` against a configured
    /// origin, the scripted stub under `--stub-backend`, or a DEBUG preview double. Never a preview in Release.
    private(set) var signInService: any SignInService = UnconfiguredSignIn()
    private var settingsService: (any AccountSettingsService)?
    /// A user-facing line for the unauthenticated screen: a failed sign-in link or a build that has
    /// no API origin configured (never silently synthetic data).
    var notice: String?
    private var completedProof: String?
    private var activeProof: String?
    private var gate = NavigationGate()
    private var generation = 0
    private let router: LinkRouter?
    let preview: Bool
    /// Whether a session object exists. A `.unavailable`/`.signedOut` state with a session
    /// present is a transient sub-state of the donor shell (recoverable via "Try again"),
    /// NOT a reason to leave for the role-select splash — only a session-less app goes there.
    var hasSession: Bool { session != nil }
    /// A session whose credentials were found on launch: the donor shell (and its own loading and
    /// recovery states) is the right place to wait. A session with nothing stored goes straight to sign-in.
    var hasRestorableSession: Bool { session?.restoredCredentials == true }
    func makeSettings() -> (any AccountSettingsService)? { settingsService }
    /// Runs sign-in verification INSIDE the session so it owns the await and the epoch guard.
    func establish() -> PhoneSignInModel.Establish {
        guard let session else { return { _ in throw AccountError.invalidConfiguration } }
        return { produce in try await session.establish(produce) }
    }
    init() {
        let apiOrigin = Bundle.main.object(forInfoDictionaryKey: "DADAPIOrigin") as? String ?? ""
        #if DEBUG
        preview = apiOrigin.isEmpty && !launchFlag("--stub-backend")
        #else
        preview = false
        #endif
        router = (Bundle.main.object(forInfoDictionaryKey: "DADPublicOrigin") as? String)
            .flatMap(URL.init(string:)).flatMap { try? LinkRouter(publicOrigin: $0) }
        #if DEBUG
        if launchFlag("--stub-backend") {
            // The REAL conformers (WireAuth, WireAPI, WireAccountSettings, AccountSession) run on a
            // scripted in-process transport: UITests exercise release code paths with no network.
            do {
                let services = try StubBackend.make(deletionBlocked: launchFlag("--stub-delete-blocked"),
                                                    onLocalWipe: { DefaultsAttributionStore().clear() })
                session = services.session
                signInService = services.signIn
                settingsService = services.settings
                state = .loading
            } catch { session = nil; state = .unavailable }
            return
        }
        // A session-less launch (no stored credentials) lands on role-select + the auth shell;
        // the preview normally starts signed-in, so this path is opt-in for the auth journey/UITest.
        if launchFlag("--preview-signed-out") {
            session = try? AccountSession(api: PreviewAPI(failFirst: false), store: PreviewStore(signedIn: false))
            signInService = PreviewSignIn()
            if let session { settingsService = PreviewSessionSettings(session: session) }
            state = .signedOut
            return
        }
        #endif
        do {
            if apiOrigin.isEmpty {
                // The synthetic (PreviewAPI/PreviewStore) path must NEVER ship in a release build —
                // an empty origin there is a misconfiguration, not a demo mode, and falling back
                // would serve synthetic data as if real. Compile it only into DEBUG; a release
                // build with an empty origin is a hard configuration failure.
                #if DEBUG
                let built = try AccountSession(api: PreviewAPI(failFirst: launchFlag("--preview-unavailable")), store: PreviewStore())
                signInService = PreviewSignIn()
                settingsService = PreviewSessionSettings(session: built)
                session = built
                #else
                throw AccountError.invalidConfiguration
                #endif
            } else {
                guard let origin = URL(string: apiOrigin) else { throw AccountError.invalidConfiguration }
                // Namespace the keychain by the running bundle id so the release
                // (org.dad.foundation) and debug (.debug) builds never share a
                // credential bucket, and the name tracks the id automatically.
                let service = Bundle.main.bundleIdentifier ?? "org.dad.foundation"
                let built = try AccountSession(api: WireAPI(origin: origin), store: KeychainStore(service: service))
                let auth = try WireAuth(origin: origin, deviceName: UIDevice.current.name)
                let settings = try WireAccountSettings(origin: origin, session: built, onLocalWipe: { DefaultsAttributionStore().clear() })
                signInService = auth
                settingsService = settings
                session = built
            }
        } catch {
            session = nil
            state = .unavailable
            notice = "This build isn’t configured to reach DAD. Install a build with a valid API origin."
        }
    }
    func load() async {
        guard let session else { state = .unavailable; return }
        generation += 1
        let current = generation
        state = .loading
        do {
            let profile = try await session.profile()
            if current == generation { state = .ready(profile) }
        }
        catch is CancellationError { return }
        catch AccountError.signedOut { if current == generation { state = .signedOut } }
        catch { if current == generation { state = .unavailable } }
    }
    func receive(_ url: URL) -> URL? {
        guard let intent = router?.route(url) else { return nil }
        switch intent {
        case .account(.profile):
            let signedIn: Bool
            if case .ready = state { signedIn = true } else { signedIn = false }
            _ = gate.receive(.profile, signedIn: signedIn)
            Task { await load() }
            return nil
        case .claim(let token, let next):
            // Preserve the website's proof exchange for destinations this preview does not implement.
            if next != nil { return url }
            guard let session, !preview else { return url }
            let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
            guard activeProof == nil, completedProof != digest else { return nil }
            activeProof = digest
            generation += 1
            state = .loading
            Task {
                defer { activeProof = nil }
                do {
                    try await session.claim(token: token)
                    completedProof = digest
                    _ = gate.signedIn()
                    await load()
                } catch {
                    if await session.isSignedIn { state = .unavailable }
                    else {
                        state = .signedOut
                        notice = "That sign-in link didn’t work. It may have expired — request a new one."
                    }
                }
            }
            return nil
        default: return url
        }
    }
}

private struct WebDestination: Identifiable { let id = UUID(); let url: URL }
private struct WebFallback: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// The signed-in donor landing. Carries the exact copy the app has shown since the
/// preview shell, so the role-aware root is a structural change, not a visible one.
private struct DonorLanding: View {
    let state: AccountModel.State
    let preview: Bool
    let onRetry: () -> Void
    var onSettings: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("DAD").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Good things start together.").font(.title).accessibilityAddTraits(.isHeader)
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading your account…")
                case .ready(let profile):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome, \(profile.publicName ?? "friend")").font(.title2.bold())
                        Text("Your account has a home here.")
                    }
                case .unavailable:
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your account is unavailable right now.").font(.headline)
                        Text("Please try again in a moment.")
                        Button("Try again", action: onRetry).buttonStyle(.borderedProminent)
                    }
                case .signedOut:
                    Text("You’re signed out. Use your DAD sign-in link to continue.")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("account-state")
            // Settings hosts sign-out and the store-mandated in-app account deletion, so it is
            // reachable whenever the donor is signed in, including while the profile read is retrying.
            if let onSettings {
                Button("Settings", action: onSettings)
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("open-settings")
            }
            if preview { Text("Preview · Sample account").font(.footnote).foregroundStyle(.secondary) }
        }.frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
    }
}

/// Minimal partner stack placeholder — fleshed out in the partner phase. Present now so
/// the role-aware root compiles and routes both journeys.
private struct PartnerLanding: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Partner portal").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Your organization’s giving home.").font(.title3)
        }.frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
    }
}

/// Unauthenticated splash — pick a journey before signing in. The preview store starts
/// signed-in, so this path is exercised only when there is no session.
private struct RoleSelect: View {
    let notice: String?
    let onSelect: (AppRole) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("DAD").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Good things start together.").font(.title).accessibilityAddTraits(.isHeader)
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("auth-notice")
            }
            VStack(spacing: 12) {
                Button("I’m a donor") { onSelect(.donor) }.buttonStyle(DADButtonStyle(.primary))
                Button("I’m a partner") { onSelect(.partner) }.buttonStyle(DADButtonStyle(.secondary))
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityIdentifier("role-select")
    }
}

#if DEBUG
/// Preview sign-in transport — returns a handle and preview credentials so the auth journey
/// runs in the simulator with no backend. The wire implementation replaces this once the
/// phone/OIDC endpoints are consumed; the screens bind to the protocol, not this type.
private actor PreviewSignIn: SignInService {
    func requestPhoneCode(phone: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(150))
        return "preview-handle"
    }
    func verifyPhone(handle: String, code: String) async throws -> Credentials {
        try await Task.sleep(for: .milliseconds(150))
        return Credentials(access: "preview", refresh: "preview-refresh", expiresAt: .distantFuture)
    }
}
#endif

#if DEBUG
/// Preview giving transport — an in-memory recurring gift so the Phase C giving journey runs
/// in the simulator with no backend. The wire implementation (mapping the generated giving
/// client) replaces this; the screens bind to the `GivingService` protocol, not this type.
private actor PreviewGiving: GivingService {
    private var state: RecurringState
    init(state: RecurringState = .active(subscriptionID: "preview-sub", amountMinor: 3000, periodEnd: Date().addingTimeInterval(14 * 86_400))) {
        self.state = state
    }
    func recurring() async throws -> RecurringState { state }
    func changeAmount(subscriptionID: String, to amountMinor: Int) async throws -> RecurringState {
        if case let .active(id, _, end) = state { state = .active(subscriptionID: id, amountMinor: amountMinor, periodEnd: end) }
        return state
    }
    func cancel(subscriptionID: String, periodEnd: Date) async throws -> RecurringState {
        if case let .active(id, amount, end) = state { state = .ending(subscriptionID: id, amountMinor: amount, periodEnd: end, stopsAt: periodEnd) }
        return state
    }
    func beginPayment() async throws -> PaymentPath {
        .webCheckoutHandoff(URL(string: "https://give.example.org/setup")!)
    }
}
#endif

#if DEBUG
private actor PreviewEngagement: EngagementService {
    private var optedIn: Bool
    init(optedIn: Bool = true) { self.optedIn = optedIn }

    private func currentRanking() -> RankingStanding {
        optedIn
            ? RankingStanding(nationalPercentile: 92, city: "Austin", cityRank: 4)
            : RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
    }

    func snapshot() async throws -> EngagementSnapshot {
        EngagementSnapshot(
            impact: ImpactTotals(givenMinor: 124_000, initiativesFunded: 3, eventsVolunteered: 2),
            badges: BadgeCollection(badges: [
                Badge(code: "F", title: "Founding Donor", rule: "Start a monthly gift before January 2027, or join the website waitlist", perk: "Founding Donor Dinner and founding events", earned: true),
                Badge(code: "7", title: "One Week", rule: "Reach a 7-day streak", perk: "—", earned: true),
                Badge(code: "1K", title: "1,000 Days", rule: "Reach a 1,000-day streak", perk: "Invite-only milestone events", earned: false),
            ]),
            ranking: currentRanking(),
            network: NetworkSummary(activeCount: 6, annualizedMinor: 72_000, anonymousActive: 2),
            referral: ReferralInfo(code: "SHAWN42", linkCount: 4, irlCount: 2)
        )
    }

    func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding {
        optedIn = optIn
        return currentRanking()
    }
}
#endif

// MARK: - Events preview + screen (Phase E)

#if DEBUG
/// Preview double for the events service. One reservable public event, one full event (waitlist),
/// and one invite-only event, so the list/detail/reserve path is exercised without a network.
private actor PreviewEvents: EventsService {
    private var store: [String: DonorEvent]

    init() {
        let soon = Date().addingTimeInterval(60 * 60 * 24 * 7)
        let events = [
            DonorEvent(id: "e1", slug: "park-cleanup", title: "Park Cleanup", type: "volunteer", venue: "Zilker Park",
                       city: "Austin", startsAt: soon, endsAt: soon.addingTimeInterval(7200), capacity: 50, spotsLeft: 8,
                       status: .none, reportIssueURL: "mailto:help@dad.org"),
            DonorEvent(id: "e2", slug: "food-bank", title: "Food Bank Night", type: "volunteer", venue: "Central Kitchen",
                       city: "Austin", startsAt: soon.addingTimeInterval(86400), endsAt: soon.addingTimeInterval(86400 + 7200),
                       capacity: 30, spotsLeft: 0, status: .none, reportIssueURL: "mailto:help@dad.org"),
            DonorEvent(id: "e3", slug: "founders-dinner", title: "Founders Dinner", type: "social", venue: "The Loft",
                       city: "Austin", startsAt: soon.addingTimeInterval(2 * 86400), endsAt: soon.addingTimeInterval(2 * 86400 + 7200),
                       capacity: 20, spotsLeft: 5, status: .none, invitationNote: "Founding donors only",
                       reportIssueURL: "mailto:help@dad.org"),
        ]
        store = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    }

    func events() async throws -> [DonorEvent] { store.values.sorted { $0.startsAt < $1.startsAt } }
    func event(id: String) async throws -> DonorEvent {
        guard let event = store[id] else { throw AccountError.unavailable }
        return event
    }

    func reserve(eventID: String) async throws -> ReservationOutcome {
        guard let event = store[eventID] else { return .reserved }
        let outcome: ReservationOutcome = event.spotsLeft > 0 ? .reserved : .waitlisted
        store[eventID] = DonorEvent(
            id: event.id, slug: event.slug, title: event.title, type: event.type, venue: event.venue, city: event.city,
            startsAt: event.startsAt, endsAt: event.endsAt, capacity: event.capacity,
            spotsLeft: max(0, event.spotsLeft - 1), status: outcome == .reserved ? .reserved : .waitlisted,
            invitationNote: event.invitationNote, reportIssueURL: event.reportIssueURL, cancelled: event.cancelled,
            bookingOpensAt: event.bookingOpensAt, earlyBooking: event.earlyBooking)
        return outcome
    }

    func cancel(eventID: String) async throws {
        guard let event = store[eventID] else { return }
        store[eventID] = DonorEvent(
            id: event.id, slug: event.slug, title: event.title, type: event.type, venue: event.venue, city: event.city,
            startsAt: event.startsAt, endsAt: event.endsAt, capacity: event.capacity, spotsLeft: event.spotsLeft + 1,
            status: .none, invitationNote: event.invitationNote, reportIssueURL: event.reportIssueURL,
            cancelled: event.cancelled, bookingOpensAt: event.bookingOpensAt, earlyBooking: event.earlyBooking)
    }

    func checkIn(code: String) async throws -> CheckInResultValue {
        CheckInResultValue(eventID: "e1", checkedIn: true, alreadyCheckedIn: false)
    }
}
#endif

/// Events home (PRD E-1..E-10): the events list (soonest-first, invite-only marked), with an
/// inline reserve/cancel action per row and an inline confirmation — no OS action sheets, per
/// the hard-won UITest lesson. Bound to `EventsModel`.
private struct EventsHome: View {
    @State var model: EventsModel
    @State private var confirmingCancel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Events").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .loading:
                ProgressView().accessibilityIdentifier("events-loading")
            case let .failed(message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).foregroundStyle(Color.dad("fail"))
                    Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.primary))
                }
            case .ready:
                if let outcome = model.lastOutcome {
                    DADCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outcome.confirmationTitle).font(.headline).accessibilityIdentifier("reserve-confirm")
                            Text(outcome.confirmationDetail).font(.footnote).foregroundStyle(.secondary)
                            Button("Done") { model.clearOutcome() }.buttonStyle(DADButtonStyle(.secondary))
                        }
                    }
                }
                ForEach(model.sortedEvents) { event in row(event) }
            }
        }
        .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("events-home")
        .task { await model.load() }
    }

    @ViewBuilder private func row(_ event: DonorEvent) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.title).font(.headline)
                    if event.isInviteOnly {
                        Text("Invite-only").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.dad("brand-ink").opacity(0.12)).clipShape(Capsule())
                            .accessibilityIdentifier("invite-only-badge")
                    }
                }
                Text("\(event.venue) · \(event.city)").font(.footnote).foregroundStyle(.secondary)
                Text(event.spotsLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("spots-\(event.id)")
                action(event)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-\(event.id)")
    }

    @ViewBuilder private func action(_ event: DonorEvent) -> some View {
        switch event.availability(now: Date()) {
        case .reservable:
            Button("Reserve") { Task { await model.reserve(eventID: event.id) } }
                .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("reserve-\(event.id)")
        case .waitlistable:
            Button("Join waitlist") { Task { await model.reserve(eventID: event.id) } }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("waitlist-\(event.id)")
        case .reserved, .waitlisted:
            if confirmingCancel == event.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cancel your reservation?").font(.subheadline)
                    HStack {
                        Button("Yes, cancel") { Task { await model.cancel(eventID: event.id) }; confirmingCancel = nil }
                            .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("confirm-cancel-\(event.id)")
                        Button("Keep it") { confirmingCancel = nil }.buttonStyle(DADButtonStyle(.secondary))
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("cancel-confirm-\(event.id)")
            } else {
                Text(event.status == .waitlisted ? "On the waitlist" : "You're going").font(.subheadline.bold())
                Button("Cancel reservation") { confirmingCancel = event.id }
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("cancel-\(event.id)")
            }
        case .checkedIn:
            Text("Checked in").font(.subheadline.bold()).foregroundStyle(Color.dad("brand-ink"))
        case .notYetOpen:
            Text("Booking not open yet").font(.footnote).foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled").font(.footnote).foregroundStyle(Color.dad("fail"))
        }
    }
}


#if DEBUG
/// In-memory partner service for the preview/UITest. A `--preview-partner-pending` launch shows
/// the pending gate; `--preview-partner-viewer` loads as a VIEWER (read-only); otherwise an ADMIN
/// portal with one verified and one unverified figure, an unsuppressed workforce, and two users.
private actor PreviewPartner: PartnerService {
    private let pending: Bool
    private let role: PartnerRole
    private var userList: [PartnerUser]

    init(pending: Bool = false, role: PartnerRole = .admin) {
        self.pending = pending
        self.role = role
        userList = [
            PartnerUser(id: "u1", email: "ada@acme.com", name: "Ada Admin", role: .admin),
            PartnerUser(id: "u2", email: "val@acme.com", name: "Val Viewer", role: .viewer),
        ]
    }

    func overview() async throws -> PartnerOverview {
        if pending { throw PartnerPendingApproval() }
        return PartnerOverview(
            organization: "Acme Corp", description: "Doing good together.",
            userID: role == .admin ? "u1" : "u2", role: role, companyCode: "ACME",
            committed: VerifiedMoney(amountMinor: 5_000_000, verified: true),
            deployed: VerifiedMoney(amountMinor: 3_000_000, verified: false), // unverified -> hidden (§7.3)
            deployedPercent: 60,
            peopleReached: VerifiedCount(value: 12_400, verified: true),
            employeesEnrolled: 86, workforceSize: 240, enrolledPercent: 35,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000), hasLogo: false)
    }

    func initiatives() async throws -> [PartnerInitiative] {
        [PartnerInitiative(id: "i1", title: "Clean Water West", summary: "Wells across 6 counties.",
                           status: .active, region: "West", committedMinor: 2_000_000, deployedMinor: 1_200_000,
                           metrics: [PartnerMetric(label: "People reached", value: 8400, unit: .people),
                                     PartnerMetric(label: "Wells", value: 32, unit: .initiatives)])]
    }

    func spend() async throws -> [PartnerSpendCategory] {
        [PartnerSpendCategory(category: "Water", amountMinor: 1_800_000),
         PartnerSpendCategory(category: "Housing", amountMinor: 1_200_000)]
    }

    func people() async throws -> PartnerPeople {
        PartnerPeople(enrolled: 86, workforceSize: 240, givenMinor: 940_000, matchedMinor: 470_000,
                      avgStreakDays: 42, volunteerMinutes: 6_300, teams: 7, suppressed: false)
    }

    func users() async throws -> [PartnerUser] { userList }
    func inviteUser(email: String, role: PartnerRole) async throws {
        userList.append(PartnerUser(id: "u\(userList.count + 1)", email: email, name: email, role: role))
    }
    func removeUser(id: String) async throws { userList.removeAll { $0.id == id } }
    func registerPushDevice(token: String) async throws {}
    func unregisterPushDevice() async throws {}
}
#endif

/// Partner portal (PRD P-*, EM-*, §7). The pending-approval gate shows nothing else (P-2); the
/// loaded portal renders verified-or-hidden Overview tiles (§7.3), spend totals, the Our People
/// rollup with <5 suppression (EM-3), and user management gated to admins (§7.2) — all inline.
private struct PartnerPortal: View {
    @State var model: PartnerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Partner portal").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .loading:
                ProgressView().accessibilityIdentifier("partner-loading")
            case .pending:
                // P-2: pending approval shows nothing else.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Awaiting approval").font(.title3.bold())
                    Text("Your organization’s account is pending review. We’ll email you when it’s approved.")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("partner-pending")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).accessibilityIdentifier("partner-error")
                    Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.primary))
                }
            case .ready:
                if let overview = model.overview { PartnerContent(model: model, overview: overview) }
            }
        }
        .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("partner-portal")
        .task { await model.load() }
    }
}

private struct PartnerContent: View {
    let model: PartnerModel
    let overview: PartnerOverview
    @State private var inviteEmail = ""
    var body: some View {
        // Overview tiles — a figure renders ONLY when verified (§7.3); unverified is omitted.
        VStack(alignment: .leading, spacing: 4) {
            Text(overview.organization).font(.title2.bold())
            if let line = overview.verifiedLine() {
                Text(line).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("partner-verified-line")
            }
            if let committed = overview.committed.label {
                Text("Committed: \(committed)").accessibilityIdentifier("partner-committed")
            }
            // deployed is unverified in the preview -> intentionally absent (never estimated)
            if let reached = overview.peopleReached.label {
                Text("People reached: \(reached)").accessibilityIdentifier("partner-reached")
            }
            if let enrolled = overview.enrolledLabel {
                Text("Enrolled: \(enrolled)").accessibilityIdentifier("partner-enrolled")
            }
        }

        if model.sectionsUnavailable {
            VStack(alignment: .leading, spacing: 8) {
                Text("Some details couldn’t be loaded right now.").font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.secondary))
            }.accessibilityElement(children: .contain).accessibilityIdentifier("partner-partial")
        }

        // Our People rollup — figures or the suppression notice (EM-3).
        if let people = model.people {
            VStack(alignment: .leading, spacing: 4) {
                Text("Our people").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if let notice = people.suppressionNotice {
                    Text(notice).accessibilityIdentifier("partner-suppressed")
                } else if let given = people.givenLabel {
                    Text("Given: \(given)").accessibilityIdentifier("partner-given")
                }
            }
        }

        // Users — admin can invite/remove inline; a viewer sees the list read-only (§7.2).
        VStack(alignment: .leading, spacing: 6) {
            Text("Team").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ForEach(model.users) { user in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(user.name) · \(user.role.rawValue)")
                        if model.canRemove(user) {
                            Spacer()
                            Button("Remove") { model.requestRemoval(id: user.id) }
                                .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false))
                                .accessibilityLabel("Remove \(user.name)")
                                .accessibilityIdentifier("partner-remove-\(user.id)")
                        }
                    }
                    if model.pendingRemoval?.id == user.id {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Remove \(user.name) from your team?").font(.footnote)
                            HStack {
                                Button("Cancel") { model.cancelRemoval() }
                                    .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false))
                                    .accessibilityIdentifier("partner-remove-cancel")
                                Button("Confirm remove") { Task { await model.confirmRemoval() } }
                                    .buttonStyle(DADButtonStyle(.primary, fillsWidth: false))
                                    .accessibilityIdentifier("partner-remove-confirm")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("partner-remove-prompt")
                    }
                }
            }
            if model.role.canManageUsers {
                TextField("Colleague’s email", text: $inviteEmail)
                    .textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                    .textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("partner-invite-email")
                Button("Invite user") {
                    let email = inviteEmail
                    Task {
                        await model.inviteUser(email: email, role: .viewer)
                        if model.actionError == nil { inviteEmail = "" }
                    }
                }
                .buttonStyle(DADButtonStyle(.primary))
                .disabled(!PartnerModel.isPlausibleEmail(inviteEmail))
                .accessibilityIdentifier("partner-invite")
            } else {
                Text("Read-only access").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("partner-readonly")
            }
            if let error = model.actionError {
                Text(error).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("partner-action-error")
            }
        }
    }
}

#if DEBUG
/// In-memory settings service for the preview/UITest.
private actor PreviewAccountSettings: AccountSettingsService {
    private var prefs = AccountPreferences(
        version: 3, referralEmails: true, marketingEmails: false, pushReferralConverted: true,
        pushStreakAtRisk: true, pushStreakMilestone: true, pushStreakLapsed: true,
        pushBadgeEarned: true, pushEventNearby: false, pushEventReminder: true,
        pushEventPromoted: false, pushGiftProcessed: true, rankingsOptedOut: false,
        networkVisible: true, volunteer: true)

    private func snapshot() -> AccountSettingsSnapshot {
        AccountSettingsSnapshot(
            profile: AccountProfileSummary(email: "donor@example.com", accountRole: "DONOR",
                                           zip: "78701", city: "Austin", phone: nil),
            preferences: prefs)
    }

    func load() async throws -> AccountSettingsSnapshot { snapshot() }
    func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot {
        prefs = AccountPreferences(
            version: preferences.version + 1, referralEmails: preferences.referralEmails,
            marketingEmails: preferences.marketingEmails, pushReferralConverted: preferences.pushReferralConverted,
            pushStreakAtRisk: preferences.pushStreakAtRisk, pushStreakMilestone: preferences.pushStreakMilestone,
            pushStreakLapsed: preferences.pushStreakLapsed, pushBadgeEarned: preferences.pushBadgeEarned,
            pushEventNearby: preferences.pushEventNearby, pushEventReminder: preferences.pushEventReminder,
            pushEventPromoted: preferences.pushEventPromoted, pushGiftProcessed: preferences.pushGiftProcessed,
            rankingsOptedOut: preferences.rankingsOptedOut, networkVisible: preferences.networkVisible,
            volunteer: preferences.volunteer)
        return snapshot()
    }
    func deleteAccount() async throws {}
    func signOut() async throws {}
}

/// Preview settings tied to the live (preview) session, so signing out or deleting from the donor
/// shell really ends the session and routes back to sign-in, like a release build.
private struct PreviewSessionSettings: AccountSettingsService {
    let session: AccountSession
    private let inner = PreviewAccountSettings()
    init(session: AccountSession) { self.session = session }
    func load() async throws -> AccountSettingsSnapshot { try await inner.load() }
    func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot { try await inner.savePreferences(preferences) }
    func deleteAccount() async throws { try await session.discardLocal() }
    func signOut() async throws { try await session.logout() }
}
#endif

/// Account & settings (PRD §6.11/§6.12): profile header, notification + privacy toggles, sign
/// out, and the store-mandated delete-account flow with a typed-word confirm gate — all inline.
/// Bound to `AccountSettingsModel`.
private struct AccountSettingsScreen: View {
    @State var model: AccountSettingsModel
    var onSignedOut: (() -> Void)?
    @State private var confirmingDelete = false
    @State private var deleteTyped = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if model.signedOut {
                Text("You're signed out.").accessibilityIdentifier("settings-signed-out")
            } else {
                switch model.phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("settings-loading")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).accessibilityIdentifier("settings-error")
                        Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.primary))
                    }
                case .ready:
                    if let snapshot = model.snapshot {
                        settingsBody(snapshot)
                    }
                }
            }
            if let error = model.actionError {
                Text(error).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("settings-action-error")
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("settings-screen")
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut?() } }
    }

    @ViewBuilder private func settingsBody(_ snapshot: AccountSettingsSnapshot) -> some View {
        Text(snapshot.profile.email).font(.headline).accessibilityIdentifier("settings-email")
        Text("ZIP: \(snapshot.profile.zipLabel)").font(.footnote)

        // Notification toggles (§6.11) — payment-failure email is absent by design.
        ForEach(snapshot.preferences.pushToggles, id: \.key) { toggle in
            Toggle(toggle.label, isOn: Binding(
                get: { toggle.value },
                set: { newValue in Task { await model.toggle(toggle.key, newValue) } }
            )).disabled(model.isBusy).accessibilityIdentifier("pref-\(toggle.key)")
        }
        // Privacy: "Show my ranking" inverts rankings_opted_out.
        Toggle("Show my ranking", isOn: Binding(
            get: { snapshot.preferences.showRanking },
            set: { newValue in Task { await model.toggle("rankings_opted_out", !newValue) } }
        )).disabled(model.isBusy).accessibilityIdentifier("ranking-toggle")

        Button("Sign out") { Task { await model.signOut() } }
            .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("settings-signout")

        // Delete account (store-mandated, §6.12): typed-word confirm gate, inline.
        if !confirmingDelete {
            Button("Delete my account") { confirmingDelete = true }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("delete-start")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(DeleteAccountGate(typed: deleteTyped).helpText).font(.footnote)
                TextField("Type \(DeleteAccountGate.confirmWord)", text: $deleteTyped)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("delete-input")
                Button("Permanently delete") { Task { await model.deleteAccount(DeleteAccountGate(typed: deleteTyped)) } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!DeleteAccountGate(typed: deleteTyped).isConfirmed || model.isBusy)
                    .accessibilityIdentifier("delete-confirm")
                Button("Keep my account") { confirmingDelete = false; deleteTyped = "" }
                    .buttonStyle(DADButtonStyle(.secondary))
            }.accessibilityElement(children: .contain).accessibilityIdentifier("delete-confirm-block")
        }
    }
}
/// Engagement home (PRD A-*, I-*, R-*, N-*, B-*, K-*): lifetime impact totals, the badges
/// grid (earned/locked, state in text not colour), the rankings card with its opt-out toggle,
/// the referral network rollup, and the invite/IRL entry. Bound to `EngagementModel`.
private struct EngagementHome: View {
    @State var model: EngagementModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your impact").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .loading:
                ProgressView().accessibilityIdentifier("engagement-loading")
            case let .failed(message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message).foregroundStyle(Color.dad("fail"))
                    Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.primary))
                }
            case .ready:
                if let snapshot = model.snapshot {
                    if let error = model.actionError {
                        Text(error).font(.footnote).foregroundStyle(Color.dad("fail"))
                            .accessibilityIdentifier("engagement-action-error")
                    }
                    content(snapshot)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("engagement-home")
        .task { await model.load() }
    }

    @ViewBuilder private func content(_ snapshot: EngagementSnapshot) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lifetime given").font(.footnote).foregroundStyle(.secondary)
                Text(snapshot.impact.givenLabel).font(.title.bold()).accessibilityIdentifier("impact-given")
                Text("\(snapshot.impact.initiativesFunded) initiatives · \(snapshot.impact.eventsVolunteered) events")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }

        // Badges — earned/locked conveyed by text, never colour alone.
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.badges.summaryLabel).font(.headline).accessibilityIdentifier("badge-summary")
            ForEach(snapshot.badges.badges) { badge in
                HStack(spacing: 10) {
                    Image(systemName: badge.earned ? "checkmark.seal.fill" : "lock.fill")
                        .foregroundStyle(badge.earned ? Color.dad("brand-ink") : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(badge.title).fontWeight(badge.earned ? .semibold : .regular)
                        Text(badge.earned ? "Earned" : badge.rule).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(badge.accessibilityLabel)
            }
        }

        // Rankings — opt-out hides the position entirely (K-2/K-3), never a name list.
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rankings").font(.headline).accessibilityAddTraits(.isHeader)
                if snapshot.ranking.isOptedOut {
                    Text("You're not shown in rankings.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("ranking-optedout")
                    Button("Show my ranking") { Task { await model.setRankingOptIn(true) } }
                        .buttonStyle(DADButtonStyle(.secondary))
                } else {
                    if let national = snapshot.ranking.nationalLabel {
                        Text(national).accessibilityIdentifier("ranking-national")
                    } else if snapshot.ranking.isNotRankedYet {
                        Text("Not ranked yet.").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("ranking-unranked")
                    }
                    if let city = snapshot.ranking.cityLabel { Text(city).font(.footnote).foregroundStyle(.secondary) }
                    Button("Hide my ranking") { Task { await model.setRankingOptIn(false) } }
                        .buttonStyle(DADButtonStyle(.secondary))
                }
            }
        }

        // Network rollup (opt-in visibility: anonymous invitees counted, never named).
        DADCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your network").font(.headline).accessibilityAddTraits(.isHeader)
                Text("\(snapshot.network.activeCount) active · \(snapshot.network.annualizedLabel)")
                if snapshot.network.hasAnonymous {
                    Text("\(snapshot.network.anonymousActive) choose to stay anonymous")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        // Invite / IRL (share message + code; full-screen QR + scan live behind the share seam).
        DADCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Invite friends").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Your code: \(snapshot.referral.code)").accessibilityIdentifier("referral-code")
                Text("\(snapshot.referral.totalConverted) have joined through you").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Set / change your recurring gift (G-1/G-2/G-7). A $1–$30/day stepper with the monthly
/// equivalent (×30) shown derived, the streak bar, and a cancel path (G-8/G-9) with the
/// ends-streak confirmation copy. Bound to `GivingModel`.
private struct GiftScreen: View {
    @State var model: GivingModel
    @State private var confirmingCancel = false
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 44
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set your gift").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            DADCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.selection.dailyLabel).font(.system(size: amountSize, weight: .bold))
                        .accessibilityIdentifier("gift-daily")
                    Text("\(model.selection.monthlyLabel) · charged monthly").foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button { model.decrement() } label: { Image(systemName: "minus.circle.fill").font(.title) }
                            .accessibilityLabel("Decrease gift")
                            .disabled(model.selection.dailyDollars <= GiftAmount.minDailyDollars)
                        Button { model.increment() } label: { Image(systemName: "plus.circle.fill").font(.title) }
                            .accessibilityLabel("Increase gift")
                            .disabled(model.selection.dailyDollars >= GiftAmount.maxDailyDollars)
                    }
                }
            }
            DADStreakBar(filled: min(model.selection.dailyDollars, 30))
            if case .failed(let message) = model.phase {
                Text(message).font(.footnote).foregroundStyle(Color.dad("fail"))
            }
            Button("Save gift") { Task { await model.applySelection() } }
                .buttonStyle(DADButtonStyle(.primary))
                .disabled(model.phase == .working)
            if case .active = model.recurring {
                if confirmingCancel {
                    // Inline confirmation rather than a `confirmationDialog`: the OS action sheet
                    // presents in a separate layer whose buttons the simulator's XCUITest harness
                    // surfaces unreliably (the sheet animation races the automation idle-wait), so
                    // an inline block is both deterministic to test and keeps the ends-streak copy
                    // on screen beside the choice.
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cancel your gift?").font(.headline)
                        if case let .active(_, _, periodEnd) = model.recurring {
                            Text(CancelCopy.confirmation(periodEnd: periodEnd))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("End my gift") { Task { await model.cancel() }; confirmingCancel = false }
                            .buttonStyle(DADButtonStyle(.secondary))
                        Button("Keep giving") { confirmingCancel = false }
                            .buttonStyle(DADButtonStyle(.primary))
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("cancel-confirm")
                } else {
                    Button("Cancel gift") { confirmingCancel = true }
                        .buttonStyle(DADButtonStyle(.secondary))
                }
            }
            if model.recurring.isEnding {
                Text("Your gift won’t renew — it stays active until the period ends.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("gift-ending")
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gift-screen")
        .task { await model.load() }
    }
}

/// Sign-in method picker (PRD §5.1). Phone+SMS is the fully wired path here; the other
/// methods are present as labeled entry points fleshed out alongside their endpoints.
private struct SignInMethods: View {
    let onPhone: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            VStack(spacing: 12) {
                ForEach(SignInMethod.allCases) { method in
                    Button(method.title) { if method == .phone { onPhone() } }
                        .buttonStyle(DADButtonStyle(method == .phone ? .primary : .secondary))
                        .disabled(method != .phone)
                        .accessibilityHint(method == .phone ? "" : "Not available yet")
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityIdentifier("sign-in-methods")
    }
}

/// Phone + SMS one-time-code journey, bound to `PhoneSignInModel`.
private struct PhoneSignIn: View {
    @State var model: PhoneSignInModel
    let onSignedIn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with your phone").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if model.isAwaitingCode {
                TextField("Verification code", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Verification code")
                failure
                Button("Verify") { Task { await model.verify() } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!model.canVerify)
            } else if case .signedIn = model.phase {
                Text("You’re signed in.").font(.headline)
            } else {
                TextField("Phone number", text: $model.phone)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .accessibilityLabel("Phone number")
                failure
                Button("Send code") { Task { await model.requestCode() } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!model.canRequestCode)
            }
            if model.phase == .requestingCode || isVerifying { ProgressView() }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityIdentifier("phone-sign-in")
        .onChange(of: model.phase) { _, phase in if case .signedIn = phase { onSignedIn() } }
    }

    private var isVerifying: Bool {
        if case .verifying = model.phase { true } else { false }
    }

    @ViewBuilder private var failure: some View {
        if case .failed(let message) = model.phase {
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail"))
        }
    }
}

/// Used when no API origin is configured (Release): sign-in fails clearly instead of inheriting a preview double.
private struct UnconfiguredSignIn: SignInService {
    func requestPhoneCode(phone: String) async throws -> String { throw AccountError.invalidConfiguration }
    func verifyPhone(handle: String, code: String) async throws -> Credentials { throw AccountError.invalidConfiguration }
}

/// Partner sign-in is an emailed-link flow (`partnerRequestSignIn`) that lands with the partner
/// wiring phase; until then say so rather than offering a donor phone sign-in under a partner label.
private struct PartnerSignInNotice: View {
    let onBack: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Partner sign-in").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Partner sign-in isn’t available in the app yet. Use the DAD website to sign in as a partner.")
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary))
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityIdentifier("partner-sign-in-notice")
    }
}

/// The unauthenticated stack: role select → sign-in methods → the chosen method's flow. Verification
/// runs through `establish` so the session (not this view) owns the network await and its epoch guard.
private struct UnauthenticatedStack: View {
    let service: any SignInService
    let establish: PhoneSignInModel.Establish
    let notice: String?
    let onSignedIn: () -> Void
    @State private var step: Step = .roleSelect
    private enum Step: Equatable { case roleSelect, methods, phone, partner }

    var body: some View {
        switch step {
        case .roleSelect:
            RoleSelect(notice: notice) { role in step = role == .donor ? .methods : .partner }
        case .methods:
            SignInMethods { step = .phone }
        case .phone:
            PhoneSignIn(model: PhoneSignInModel(service: service, establish: establish), onSignedIn: onSignedIn)
        case .partner:
            PartnerSignInNotice { step = .roleSelect }
        }
    }
}

/// Settings presented from the donor shell: sign-out and deletion run against the real session, and
/// leaving the signed-in state dismisses the sheet so the root can route to sign-in.
private struct SettingsSheet: View {
    let service: any AccountSettingsService
    let onClose: () -> Void
    let onSignedOut: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button("Close", action: onClose).padding(.horizontal, 28).padding(.top, 20)
                    .accessibilityIdentifier("settings-close")
                AccountSettingsScreen(model: AccountSettingsModel(service: service), onSignedOut: onSignedOut)
            }
        }.modifier(AppBackground()).tint(tokenColor("brand-ink"))
    }
}

@main
struct DADApp: App {
    @State private var model = AccountModel()
    @State private var router = RoleRouter()
    @State private var web: WebDestination?
    @State private var showSettings = false

    @ViewBuilder private var donorRoot: some View {
        #if DEBUG
        if launchFlag("--preview-giving") {
            GiftScreen(model: GivingModel(service: PreviewGiving()))
        } else if launchFlag("--preview-engagement") {
            EngagementHome(model: EngagementModel(service: PreviewEngagement()))
        } else if launchFlag("--preview-events") {
            EventsHome(model: EventsModel(service: PreviewEvents()))
        } else if launchFlag("--preview-settings") {
            AccountSettingsScreen(model: AccountSettingsModel(service: PreviewAccountSettings()))
        } else {
            donorLanding
        }
        #else
        donorLanding
        #endif
    }

    private var donorLanding: some View {
        DonorLanding(state: model.state, preview: model.preview, onRetry: { Task { await model.load() } },
                     onSettings: model.makeSettings() == nil ? nil : { showSettings = true })
    }

    @ViewBuilder private var partnerRoot: some View {
        #if DEBUG
        if launchFlag("--preview-partner-pending") {
            PartnerPortal(model: PartnerModel(service: PreviewPartner(pending: true)))
        } else if launchFlag("--preview-partner-viewer") {
            PartnerPortal(model: PartnerModel(service: PreviewPartner(role: .viewer)))
        } else if launchFlag("--preview-partner") {
            PartnerPortal(model: PartnerModel(service: PreviewPartner()))
        } else {
            PartnerLanding()
        }
        #else
        PartnerLanding()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ScrollView {
                Group {
                    switch router.root {
                    case .authenticated(.donor):
                        donorRoot
                    case .restoring:
                        // During restore, show the donor landing only when a session exists
                        // (its loading state covers the wait); a session-less launch waits on a
                        // neutral progress view so it never flashes the signed-in screen.
                        if model.hasRestorableSession {
                            donorLanding
                        } else {
                            ProgressView().accessibilityIdentifier("restoring")
                        }
                    case .authenticated(.partner):
                        partnerRoot
                    case .unauthenticated:
                        UnauthenticatedStack(service: model.signInService, establish: model.establish(), notice: model.notice) {
                            // The session already holds the established credentials; read the profile
                            // through it, then enter the donor shell (which owns load/recovery states).
                            Task {
                                await model.load()
                                router.selectRole(.donor)
                                router.signedIn(as: .donor)
                                _ = router.flushPendingDestination()
                            }
                        }
                    }
                }
            }
            .modifier(AppBackground())
            .tint(tokenColor("brand-ink"))
            .task {
                #if DEBUG
                // A preview screen is launched straight into its router state, before the profile
                // await, so the target renders immediately instead of dwelling in `.restoring`.
                if ["--preview-giving", "--preview-engagement", "--preview-events", "--preview-settings"].contains(where: launchFlag) {
                    router.signedIn(as: .donor)
                    return
                }
                if ["--preview-partner", "--preview-partner-viewer", "--preview-partner-pending"].contains(where: launchFlag) {
                    router.signedIn(as: .partner)
                    return
                }
                #endif
                await model.load()
                // A session-backed shell is the donor journey — the donor landing owns every
                // account sub-state (loading / ready / unavailable / signed-out) and its own
                // recovery, so stay on it. Only a genuinely session-less app goes to role-select.
                // A session with nothing stored (or one the server revoked) is signed out: go to sign-in.
                if model.state == .signedOut || !model.hasSession { router.restoredSignedOut() } else { router.signedIn(as: .donor) }
            }
            .onChange(of: model.state) { _, state in
                switch state {
                case .ready where router.currentRole == nil:
                    router.signedIn(as: .donor)   // a claim link signed the person in from the sign-in screen
                case .signedOut where router.currentRole == .donor:
                    router.signedOut()            // sign-out, deletion, or a revoked session
                    showSettings = false
                default: break
                }
            }
            .sheet(isPresented: $showSettings) {
                if let service = model.makeSettings() {
                    SettingsSheet(service: service, onClose: { showSettings = false },
                                  onSignedOut: { showSettings = false; Task { await model.load() } })
                }
            }
            .onOpenURL { if let url = model.receive($0) { web = WebDestination(url: url) } }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
                if let url = $0.webpageURL, let fallback = model.receive(url) { web = WebDestination(url: fallback) }
            }
            .sheet(item: $web) { WebFallback(url: $0.url) }
        }
    }
}
