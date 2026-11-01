import SwiftUI
import DADFoundation
import SafariServices
import CryptoKit
import UserNotifications

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

struct AppBackground: ViewModifier {
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
    private(set) var kit = SignInKit.unconfigured
    private var settingsService: (any AccountSettingsService)?
    /// Set/change password in Settings; nil in previews, where there is no real account to change.
    private(set) var passwordSettings: (any PasswordSettingsService)?
    /// Contact details, account email, sessions and employer in Settings; nil in previews.
    private(set) var management: (any AccountManagementService)?
    /// Donor-home reads (dashboard, today's initiative, gift history): real `WireDashboard` or the
    /// scripted stub; nil in the synthetic DEBUG preview, which has no account to read.
    private(set) var dashboardService: (any DashboardService)?
    /// Giving (recurring gift, amount, payment method, cancel): real `WireGiving` or the scripted stub; nil in previews.
    private(set) var givingKit: GivingKit?
    /// Events (list, reserve, cancel, check-in, calendar): real `WireEvents` or the scripted stub; nil in previews.
    private(set) var eventsService: (any EventsService)?
    private(set) var engagementService: (any EngagementService)?
    /// The referral code as an Apple Wallet pass; nil in previews.
    private(set) var walletService: (any WalletPassService)?
    /// The partner portal under its own 12-hour session; nil when this build cannot reach DAD.
    private(set) var partnerService: (any PartnerService)?
    private(set) var partnerSignIn: (any PartnerSignInService)?
    private var partnerSession: PartnerSession?
    /// The public site, for links the app hands out (the partner's company sign-up link).
    private(set) var publicOrigin: URL?
    /// A tapped partner sign-in link waiting for the partner sign-in screen to accept it.
    var pendingPartnerToken: String?
    /// Opt-in usage analytics; nil in the synthetic preview, which never sends anything.
    private(set) var analytics: AnalyticsController?
    private var donorPush: (any DonorPushService)?
    /// The device token last registered for the current donor session.
    private var registeredPush: String?
    /// A screen a tapped notification or link asked for, opened by the donor shell once signed in.
    var destination: AccountDestination?
    /// A user-facing line for the unauthenticated screen: a failed sign-in link or a build that has
    /// no API origin configured (never silently synthetic data).
    var notice: String?
    /// "<name> invited you", after an invite link was opened before sign-in.
    var invitation: String?
    /// Referral and company-code link visits, kept and spent as the website's cookies are; nil in the preview.
    private var linkAttribution: LinkAttribution?
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
    var isReady: Bool { if case .ready = state { true } else { false } }
    func makeSettings() -> (any AccountSettingsService)? { settingsService }
    func hasPartnerSession() async -> Bool { await partnerSession?.isSignedIn ?? false }
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
        #if DEBUG
        let stubRouter = launchFlag("--stub-backend") ? try? LinkRouter(publicOrigin: StubBackend.origin) : nil
        #else
        let stubRouter: LinkRouter? = nil
        #endif
        let configuredPublicOrigin = (Bundle.main.object(forInfoDictionaryKey: "DADPublicOrigin") as? String).flatMap(URL.init(string:))
        router = stubRouter ?? configuredPublicOrigin.flatMap { try? LinkRouter(publicOrigin: $0) }
        publicOrigin = stubRouter == nil ? configuredPublicOrigin : StubBackend.origin
        #if DEBUG
        if preview {
            partnerSignIn = PreviewPartnerSignIn()
            partnerService = PreviewPartner(role: launchFlag("--preview-partner-viewer") ? .viewer : .admin)
        }
        #endif
        #if DEBUG
        if launchFlag("--stub-backend") {
            // The REAL conformers (WireAuth, WireAPI, WireAccountSettings, AccountSession) run on a
            // scripted in-process transport: UITests exercise release code paths with no network.
            do {
                let scenario: StubBackend.Scenario = launchFlag("--stub-dashboard-empty") ? .empty
                    : launchFlag("--stub-dashboard-fail-first") ? .failFirst
                    : launchFlag("--stub-dashboard-unranked") ? .unranked : .populated
                let gift: StubBackend.GiftScenario = launchFlag("--stub-gift-fail-first") ? .activeFailFirst
                    : launchFlag("--stub-gift-active") ? .active : .none
                let eventScenario: StubBackend.EventsScenario = launchFlag("--stub-events-ungated") ? .ungated
                    : launchFlag("--stub-events-fail-first") ? .failFirst : .standard
                let engagementScenario: StubBackend.EngagementScenario = launchFlag("--stub-rankings-fail-toggle") ? .rankingToggleFails
                    : launchFlag("--stub-no-public-name") ? .noPublicName : launchFlag("--stub-badges-down") ? .badgesDown : .standard
                let services = try StubBackend.make(deletionBlocked: launchFlag("--stub-delete-blocked"), scenario: scenario, gift: gift,
                                                    events: eventScenario, engagement: engagementScenario,
                                                    signedIn: launchFlag("--stub-signed-in"),
                                                    partnerSignedIn: launchFlag("--stub-partner-signed-in"),
                                                    onLocalWipe: { Self.wipeAttribution(linkTokens: StubBackend.linkTokensKey) })
                session = services.session
                kit = SignInKit(phone: services.signIn, signup: services.credentialAuth, link: services.credentialAuth,
                                password: services.credentialAuth,
                                oidc: nil, passkey: nil, capabilities: .none)
                settingsService = services.settings
                passwordSettings = services.passwords
                management = services.management
                dashboardService = services.dashboard
                eventsService = services.events
                engagementService = services.engagement
                walletService = services.wallet
                partnerService = services.partner
                partnerSignIn = services.partnerAuth
                partnerSession = services.partnerSession
                givingKit = GivingKit(service: services.giving, stubComplete: services.completeHandoff, pollDelay: .milliseconds(200))
                donorPush = services.push
                installAnalytics(AnalyticsController(consent: MemoryAnalyticsConsent(choice: launchFlag("--stub-analytics-unset") ? nil : false),
                                                     sink: services.analyticsSink))
                // Each stub launch starts as a fresh install: no link visit kept from an earlier run.
                DefaultsLinkTokenStore(key: StubBackend.linkTokensKey).clear()
                installLinkAttribution(services.linkAttribution, store: DefaultsLinkTokenStore(key: StubBackend.linkTokensKey))
                state = .loading
            } catch { session = nil; state = .unavailable }
            return
        }
        // A session-less launch (no stored credentials) lands on role-select + the auth shell;
        // the preview normally starts signed-in, so this path is opt-in for the auth journey/UITest.
        if launchFlag("--preview-signed-out") {
            session = try? AccountSession(api: PreviewAPI(failFirst: false), store: PreviewStore(signedIn: false))
            kit = .preview
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
                kit = .preview
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
                let credentialAuth = try WireCredentialAuth(origin: origin, deviceName: UIDevice.current.name)
                let settings = try WireAccountSettings(origin: origin, session: built, onLocalWipe: { Self.wipeAttribution() })
                // Apple, Google and passkeys stay off until the owner supplies their build settings.
                let capabilities = SignInCapabilities(config: SignInConfig(
                    appleFlag: Bundle.main.object(forInfoDictionaryKey: "DADAppleSignInEnabled") as? String,
                    googleClientID: Bundle.main.object(forInfoDictionaryKey: "DADGoogleClientID") as? String,
                    passkeyRelyingParty: Bundle.main.object(forInfoDictionaryKey: "DADPasskeyRelyingParty") as? String))
                kit = SignInKit(phone: auth, signup: credentialAuth, link: credentialAuth, password: credentialAuth,
                                oidc: capabilities.apple || capabilities.google ? credentialAuth : nil,
                                passkey: capabilities.passkey ? credentialAuth : nil, capabilities: capabilities,
                                passkeyRelyingParty: (Bundle.main.object(forInfoDictionaryKey: "DADPasskeyRelyingParty") as? String) ?? "")
                settingsService = settings
                passwordSettings = try WirePasswordSettings(origin: origin, session: built)
                management = try WireAccountManagement(origin: origin, session: built)
                dashboardService = try WireDashboard(origin: origin, session: built)
                givingKit = GivingKit(service: try WireGiving(origin: origin, session: built,
                                                              referral: { DefaultsLinkTokenStore().load().referral }))
                eventsService = try WireEvents(origin: origin, session: built)
                engagementService = try WireEngagement(origin: origin, session: built)
                walletService = try WireWalletPass(origin: origin, session: built)
                let partner = try PartnerSession(store: KeychainStore(service: service, account: "partner-session"))
                partnerSignIn = try WirePartnerAuth(origin: origin, session: partner)
                partnerService = try WirePartner(origin: origin, session: partner)
                partnerSession = partner
                donorPush = try WireDonorPush(origin: origin, session: built)
                let analyticsSink = try WireAnalytics(origin: origin, access: { try? await built.accessToken() })
                let links = try WireLinkAttribution(origin: origin, session: built)
                session = built
                installAnalytics(AnalyticsController(consent: DefaultsAnalyticsConsent(), sink: analyticsSink))
                installLinkAttribution(links, store: DefaultsLinkTokenStore())
            }
        } catch {
            session = nil
            state = .unavailable
            notice = "This build isn’t configured to reach DAD. Install a build with a valid API origin."
        }
    }
    private func installAnalytics(_ controller: AnalyticsController) {
        analytics = controller
        AnalyticsObservation.shared.install { controller.emit($0) }
    }
    private func installLinkAttribution(_ service: any LinkAttributionService, store: any LinkTokenStore) {
        let analytics = analytics
        linkAttribution = LinkAttribution(service: service, store: store) { analytics?.emit(.attributionCaptured, properties: ["source": $0]) }
    }
    /// Account deletion forgets where this install came from, link tokens included.
    private nonisolated static func wipeAttribution(linkTokens key: String = "org.dad.link-tokens") {
        DefaultsAttributionStore().clear()
        DefaultsLinkTokenStore(key: key).clear()
    }
    func load() async {
        guard let session else { state = .unavailable; return }
        generation += 1
        let current = generation
        state = .loading
        do {
            let profile = try await session.profile()
            if current == generation {
                state = .ready(profile)
                invitation = nil
                if let pending = gate.signedIn() { destination = pending }
                if let linkAttribution { Task { await linkAttribution.bindCompany() } }
            }
        }
        catch is CancellationError { return }
        catch AccountError.signedOut { if current == generation { state = .signedOut; registeredPush = nil } }
        catch { if current == generation { state = .unavailable } }
    }

    /// Best-effort, once per token and donor session: platforms rotate tokens, so the server wants every launch.
    func registerPush(_ token: String?) async {
        guard let token, let donorPush, case .ready = state, registeredPush != token else { return }
        registeredPush = token
        do { try await donorPush.register(token: token, environment: .ofThisBuild) } catch { registeredPush = nil }
    }

    /// A tapped notification: counted (`push_opened`), then its screen is opened, after sign-in if need be.
    func openNotification(_ tap: PushTap) {
        analytics?.emit(.pushOpened, properties: ["type": tap.category])
        guard let path = tap.path, let target = router?.notification(path: path) else { return }
        let signedIn: Bool
        if case .ready = state { signedIn = true } else { signedIn = false }
        if let now = gate.receive(target, signedIn: signedIn) { destination = now }
    }
    /// A sign-in link pasted from the "check your email" screen (the email may have been opened on
    /// another device or in a browser). A claim link, including its supported return path, goes through the
    /// same single-use proof exchange as a tapped link. Returns false when the text is not one.
    func openPastedLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let intent = router?.route(url), case .claim = intent else { return false }
        notice = nil
        return receive(url, role: nil) == nil
    }

    /// Routes a tapped link for the signed-in `role` (nil before sign-in); returns a URL for the web
    /// fallback when the app does not handle it here.
    func receive(_ url: URL, role: AppRole?) -> URL? {
        guard let intent = router?.route(url) else { return nil }
        switch intent {
        case .partnerSignIn(let token):
            // A partner already in the portal stays put; a donor's app cannot also be a partner's, so the
            // website takes the link.
            switch role {
            case nil: pendingPartnerToken = token; return nil
            case .partner: return nil
            case .donor: return url
            }
        case .account(let target):
            if role == .partner { return url }
            let signedIn: Bool
            if case .ready = state { signedIn = true } else { signedIn = false }
            if let now = gate.receive(target, signedIn: signedIn) { destination = now }
            Task { await load() }
            return nil
        case .referral(let code, let inPerson):
            guard let linkAttribution else { return url }
            Task {
                let name = await linkAttribution.captureReferral(code: code, inPerson: inPerson)
                if let name, !isReady { invitation = "\(name) invited you to give with DAD." }
            }
            return nil
        case .company(let code):
            guard let linkAttribution else { return url }
            Task {
                await linkAttribution.captureCompany(code: code)
                if isReady { await linkAttribution.bindCompany() }
            }
            return nil
        case .claim(let token, let next):
            if role == .partner { return url }
            guard let session, !preview else { return url }
            let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
            guard activeProof == nil, completedProof != digest else { return nil }
            activeProof = digest
            if let next { _ = gate.receive(next, signedIn: false) }
            generation += 1
            state = .loading
            Task {
                defer { activeProof = nil }
                do {
                    try await session.claim(token: token)
                    completedProof = digest
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

private struct PushRegistrationKey: Equatable { let token: String?; let ready: Bool }

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
    /// The real donor-home reads; nil in the synthetic preview, which keeps its placeholder line.
    var dashboard: (any DashboardService)?
    var giving: GivingKit?
    var events: (any EventsService)?
    var engagement: (any EngagementService)?
    var wallet: (any WalletPassService)?
    @Binding var destination: AccountDestination?
    var onSignedOut: () -> Void = {}
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
                        if dashboard == nil { Text("Your account has a home here.") }
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
            if case .ready = state, let dashboard { DonorHomeView(service: dashboard, giving: giving, events: events, engagement: engagement, wallet: wallet,
                                                                           destination: $destination, onSignedOut: onSignedOut) }
            if preview { Text("Preview · Sample account").font(.footnote).foregroundStyle(.secondary) }
        }.frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
    }
}

/// Unauthenticated splash — pick a journey before signing in. The preview store starts
/// signed-in, so this path is exercised only when there is no session.
private struct RoleSelect: View {
    let notice: String?
    var invitation: String?
    let onSelect: (AppRole) -> Void
    @Environment(AnalyticsController.self) private var analytics: AnalyticsController?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("DAD").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Good things start together.").font(.title).accessibilityAddTraits(.isHeader)
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("auth-notice")
            }
            if let invitation { Text(invitation).font(.body).accessibilityIdentifier("auth-invitation") }
            VStack(spacing: 12) {
                Button("I’m a donor") { analytics?.emit(.roleSelected); onSelect(.donor) }.buttonStyle(DADButtonStyle(.primary))
                Button("I’m a partner") { analytics?.emit(.roleSelected); onSelect(.partner) }.buttonStyle(DADButtonStyle(.secondary))
            }
            if let analytics, analytics.choice == nil { AnalyticsChoice(analytics: analytics) }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("role-select")
    }
}

/// Asks iOS for notification permission only when the donor chooses to, never at launch; once allowed the app
/// registers for a device token (see `PushAppDelegate`).
private struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus?
    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                Button("Turn on notifications") {
                    Task {
                        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                        if granted { UIApplication.shared.registerForRemoteNotifications() }
                        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    }
                }.buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("notifications-allow")
            case .denied:
                Text("Notifications are off for DAD in iOS Settings.").font(.footnote).accessibilityIdentifier("notifications-denied")
            default:
                EmptyView()
            }
        }
        .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }
}

/// The first-launch analytics question, worded as on the website; the answer can be changed in Settings.
private struct AnalyticsChoice: View {
    let analytics: AnalyticsController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow first-party usage analytics? DAD uses a temporary journey ID to measure signup, sharing and giving. "
                 + "No names, email addresses or payment details are sent. Observations are kept for 13 months. "
                 + "You can change this choice in Settings.").font(.footnote)
            Button("Allow usage analytics") { analytics.choose(true) }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("analytics-allow")
            Button("Decline usage analytics") { analytics.choose(false) }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("analytics-decline")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("analytics-choice")
    }
}

#if DEBUG
/// Preview sign-in transport — returns a handle and preview credentials so the auth journey
/// runs in the simulator with no backend. The wire implementation replaces this once the
/// phone/OIDC endpoints are consumed; the screens bind to the protocol, not this type.
private actor PreviewSignIn: SignInService, SignupService, SignInLinkService, PasswordSignInService {
    func requestSignup(_ form: SignupForm) async throws { try await Task.sleep(for: .milliseconds(150)) }
    func requestSignInLink(email: String) async throws { try await Task.sleep(for: .milliseconds(150)) }
    func signIn(email: String, password: String) async throws -> Credentials {
        try await Task.sleep(for: .milliseconds(150))
        return Credentials(access: "preview", refresh: "preview-refresh", expiresAt: .distantFuture)
    }
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
    func amountOffer() async throws -> AmountOffer? { nil }
    func paymentMethod() async throws -> PaymentMethodState { PaymentMethodState(kind: .none) }
    func beginGift(amountMinor: Int) async throws -> PaymentPath { .webCheckoutHandoff(URL(string: "https://give.example.org/checkout")!) }
}
#endif

#if DEBUG
private actor PreviewEngagement: EngagementService {
    private var optedIn: Bool
    init(optedIn: Bool = true) { self.optedIn = optedIn }

    private func currentRanking() -> RankingStanding {
        optedIn
            ? RankingStanding(nationalPercentile: 2, city: "Austin", cityRank: 4)
            : RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
    }

    func snapshot() async throws -> EngagementSnapshot {
        EngagementSnapshot(
            impact: ImpactTotals(givenMinor: 124_000, initiativesFunded: 3, eventsVolunteered: 2),
            badges: BadgeCollection(badges: [
                Badge(code: "F", title: "Founding Donor", rule: "Start a monthly gift before January 2027, or join the website waitlist", perk: Badge.perkCopy(forKey: "FOUNDING_EVENTS"), earned: true),
                Badge(code: "7", title: "One Week", rule: "Reach a 7-day streak", perk: "", earned: true),
                Badge(code: "1K", title: "1,000 Days", rule: "Reach a 1,000-day streak", perk: Badge.perkCopy(forKey: "MILESTONE_EVENTS"), earned: false),
            ]),
            ranking: currentRanking(),
            network: NetworkSummary(activeCount: 6, annualizedMinor: 72_000, anonymousActive: 2),
            referral: ReferralInfo(code: "SHAWN42", linkCount: 4, irlCount: 2,
                                   conversions: [Conversion(convertedAt: Date().addingTimeInterval(-86_400), kind: .link)])
        )
    }

    func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding {
        optedIn = optIn
        return currentRanking()
    }

    func choosePublicName(_ name: String) async throws {}

    func initiativeSpend(id: String) async throws -> InitiativeSpendSummary {
        InitiativeSpendSummary(initiativeID: id, totalMinor: 125_000, slices: [
            SpendSlice(category: "Food", amountMinor: 90_000), SpendSlice(category: "Delivery", amountMinor: 35_000)])
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

    func calendar(eventID: String) async throws -> Data {
        Data("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nSUMMARY:Preview event\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
    }
}
#endif

#if DEBUG
/// In-memory partner service for the preview/UITest. `--preview-partner-viewer` loads as a VIEWER (read-only);
/// `--preview-partner` is an ADMIN portal with one verified and one unverified figure, an unsuppressed
/// workforce, and two users.
actor PreviewPartner: PartnerService {
    private let role: PartnerRole
    private var userList: [PartnerUser]
    private var organization = "Acme Corp"
    private var about = "Doing good together."
    private var workforce = 240
    private var savedLogo: Data?

    init(role: PartnerRole = .admin) {
        self.role = role
        userList = [
            PartnerUser(id: "u1", email: "ada@acme.com", name: "Ada Admin", role: .admin),
            PartnerUser(id: "u2", email: "val@acme.com", name: "Val Viewer", role: .viewer),
        ]
    }

    func overview() async throws -> PartnerOverview {
        PartnerOverview(
            organization: organization, description: about,
            userID: role == .admin ? "u1" : "u2", role: role, companyCode: "ACME",
            committed: VerifiedMoney(amountMinor: 5_000_000, verified: true),
            deployed: VerifiedMoney(amountMinor: 3_000_000, verified: false), // unverified -> hidden (§7.3)
            deployedPercent: 60,
            peopleReached: VerifiedCount(value: 12_400, verified: true),
            employeesEnrolled: 86, workforceSize: workforce, enrolledPercent: 35,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000), hasLogo: savedLogo != nil)
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
        PartnerPeople(enrolled: 86, workforceSize: workforce, givenMinor: 940_000, matchedMinor: 470_000,
                      avgStreakDays: 42, volunteerMinutes: 6_300, teams: 7, suppressed: false)
    }

    func teams() async throws -> [TeamStanding] {
        [TeamStanding(id: "t1", name: "Engineering", activeGivers: 31, annualizedMinor: 1_200_000, avgStreakDays: 40, volunteerMinutes: 1_200)]
    }
    func users() async throws -> [PartnerUser] { userList }
    func inviteUser(email: String, name: String, role: PartnerRole) async throws {
        userList.append(PartnerUser(id: "u\(userList.count + 1)", email: email, name: name, role: role))
    }
    func removeUser(id: String) async throws { userList.removeAll { $0.id == id } }
    func saveProfile(organization: String, description: String) async throws {
        self.organization = organization
        about = description
    }
    func saveWorkforce(size: Int) async throws { workforce = size }
    func logo() async throws -> Data? { savedLogo }
    func saveLogo(png: Data?) async throws { savedLogo = png }
    func exports() async throws -> [PartnerExport] { [] }
    func report() async throws -> Data { Data("%PDF-1.4 preview".utf8) }
    func retainedReport(id: String) async throws -> Data { throw AccountError.notFound }
    func signOut() async throws {}
    func registerPushDevice(token: String, environment: PushEnvironment) async throws {}
    func unregisterPushDevice() async throws {}
}

/// Accepts any partner link, so the preview's partner sign-in journey runs with no backend.
actor PreviewPartnerSignIn: PartnerSignInService {
    func requestSignInLink(email: String) async throws {}
    func accept(token: String) async throws {}
}
#endif

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
    /// Set/change password; nil where there is no real account to change (previews).
    var passwords: (any PasswordSettingsService)?
    var management: (any AccountManagementService)?
    /// The real cancel-gift flow, offered when the server refuses deletion because a gift is still renewing.
    var giving: GivingKit?
    var onSignedOut: (() -> Void)?
    @State private var giftModel: GivingModel?
    @Environment(AnalyticsController.self) private var analytics: AnalyticsController?
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
        .sheet(isPresented: Binding(get: { giftModel != nil }, set: { if !$0 { giftModel = nil } })) {
            if let giftModel, let giving {
                GiftSheet(model: giftModel, stubComplete: giving.stubComplete, onClose: { self.giftModel = nil },
                          onSignedOut: { self.giftModel = nil; onSignedOut?() })
            }
        }
    }

    @ViewBuilder private func settingsBody(_ snapshot: AccountSettingsSnapshot) -> some View {
        Text(snapshot.profile.email).font(.headline).accessibilityIdentifier("settings-email")
        if let management {
            EmailChangeSection(current: snapshot.profile.email, service: management)
            ProfileDetailsSection(profile: snapshot.profile, service: management)
        } else {
            Text("ZIP: \(snapshot.profile.zipLabel)").font(.footnote)
        }

        // Notification toggles (§6.11) — payment-failure email is absent by design.
        NotificationPermissionRow()
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
        Toggle("Show me in my network", isOn: Binding(
            get: { snapshot.preferences.networkVisible },
            set: { newValue in Task { await model.toggle("network_visible", newValue) } }
        )).disabled(model.isBusy).accessibilityIdentifier("pref-network_visible")
        Toggle("I’d like to volunteer", isOn: Binding(
            get: { snapshot.preferences.volunteer },
            set: { newValue in Task { await model.toggle("volunteer", newValue) } }
        )).disabled(model.isBusy).accessibilityIdentifier("pref-volunteer")
        if let analytics {
            Toggle("Usage analytics", isOn: Binding(get: { analytics.choice == true }, set: { analytics.choose($0) }))
                .accessibilityIdentifier("analytics-toggle")
            Text("First-party only: a temporary journey ID measures signup, sharing and giving. No names, email addresses "
                 + "or payment details are sent.").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(snapshot.preferences.emailToggles, id: \.key) { toggle in
            Toggle(toggle.label, isOn: Binding(
                get: { toggle.value },
                set: { newValue in Task { await model.toggle(toggle.key, newValue) } }
            )).disabled(model.isBusy).accessibilityIdentifier("pref-\(toggle.key)")
        }

        if let passwords {
            PasswordSection(service: passwords, onSignedOut: { onSignedOut?() })
        }
        if let management {
            EmployerSection(service: management)
            SessionsSection(service: management, onSignedOut: { onSignedOut?() })
        }

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
                if model.deletionBlocked, let giving {
                    // The server refused because a monthly gift is still set to renew (or a checkout is open):
                    // offer the real cancel flow rather than a dead end, then the donor tries deleting again.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cancel your monthly gift, then delete your account again.").font(.footnote)
                        Button("Cancel my monthly gift") { giftModel = giving.makeModel() }
                            .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("delete-cancel-gift")
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("delete-blocked-block")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("delete-confirm-block")
        }
    }
}
/// Set or change the sign-in password, inline in Settings. Collapsed until asked for. The current
/// password is optional: right after a fresh sign-in the server accepts the recent authentication.
private struct PasswordSection: View {
    @State private var model: PasswordChangeModel
    @State private var expanded = false
    let onSignedOut: () -> Void

    init(service: any PasswordSettingsService, onSignedOut: @escaping () -> Void) {
        _model = State(initialValue: PasswordChangeModel(service: service))
        self.onSignedOut = onSignedOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !expanded {
                Button("Set or change password") { expanded = true }
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("password-start")
            } else {
                Text("Password").font(.headline)
                SecureField("Current password (if you have one)", text: $model.currentPassword)
                    .textFieldStyle(.roundedBorder).textContentType(.password).accessibilityIdentifier("password-current")
                SecureField("New password", text: $model.newPassword)
                    .textFieldStyle(.roundedBorder).textContentType(.newPassword).accessibilityIdentifier("password-new")
                SecureField("Confirm new password", text: $model.confirmPassword)
                    .textFieldStyle(.roundedBorder).textContentType(.newPassword).accessibilityIdentifier("password-confirm")
                Text(model.newPasswordHint ?? "Use 12 to 72 characters.").font(.footnote).foregroundStyle(.secondary)
                if model.confirmMismatch {
                    Text("The two passwords don’t match.").font(.footnote).foregroundStyle(Color.dad("fail"))
                }
                switch model.phase {
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("password-error")
                case .saved:
                    Text("Password saved.").font(.footnote).accessibilityIdentifier("password-saved")
                default: EmptyView()
                }
                Button("Save password") { Task { await model.save() } }
                    .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSave).accessibilityIdentifier("password-save")
                Button("Cancel") { model.edit(); expanded = false }.buttonStyle(DADButtonStyle(.secondary))
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("password-section")
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
    }
}

/// Sign-in method picker (PRD §5.1). Phone and email + password are always wired; Apple, Google and
/// passkeys light up only when their build configuration is present (`SignInCapabilities`) and are
/// otherwise visibly disabled with a plain-text reason. "Create an account" starts email signup (D-2).
private struct SignInMethods: View {
    let capabilities: SignInCapabilities
    let onSelect: (SignInMethod) -> Void
    let onCreateAccount: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            VStack(spacing: 12) {
                ForEach(SignInMethod.allCases) { method in
                    let available = capabilities.isAvailable(method)
                    Button(method.title) { onSelect(method) }
                        .buttonStyle(DADButtonStyle(method == .phone ? .primary : .secondary))
                        .disabled(!available)
                        .accessibilityHint(available ? "" : "Not available yet")
                }
            }
            if capabilities.hasUnavailableMethod {
                Text("Apple, Google and passkey sign-in aren’t available in this build yet.")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("methods-unavailable-note")
            }
            Divider()
            Text("New to DAD?").font(.headline)
            Button("Create an account", action: onCreateAccount)
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("create-account")
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("sign-in-methods")
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

/// New-donor signup (D-2): name, email, ZIP, city. The server emails a single-use sign-in link
/// (it never reveals whether the address exists); the link signs the donor in and lands in the donor
/// shell. A pasted link works when the email was opened on another device.
private struct SignupView: View {
    @State var model: SignupModel
    let notice: String?
    let onBack: () -> Void
    let onPasteLink: (String) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create your account").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if case .sent(let email) = model.phase {
                CheckEmailView(
                    message: "We sent a sign-in link to \(email). Open it on this device to finish creating your account. The link works once and expires in 15 minutes.",
                    notice: notice, onPasteLink: onPasteLink, onEdit: { model.edit() })
            } else {
                formBody
            }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("signup-back")
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("signup")
    }

    @ViewBuilder private var formBody: some View {
        TextField("Full name", text: $model.name)
            .textFieldStyle(.roundedBorder).textContentType(.name).textInputAutocapitalization(.words)
            .accessibilityLabel("Full name")
        TextField("Email", text: $model.email)
            .textFieldStyle(.roundedBorder).textContentType(.emailAddress).keyboardType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
        TextField("ZIP code", text: $model.zip)
            .textFieldStyle(.roundedBorder).textContentType(.postalCode).keyboardType(.numberPad)
            .accessibilityLabel("ZIP code")
        TextField("City", text: $model.city)
            .textFieldStyle(.roundedBorder).textContentType(.addressCity).textInputAutocapitalization(.words)
            .accessibilityLabel("City")
        if case .failed(let message) = model.phase {
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("signup-error")
        }
        Button("Create account") { Task { await model.submit() } }
            .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit)
        if model.phase == .submitting { ProgressView() }
    }
}

/// "Check your email" after a link was requested (signup or sign-in): the emailed link opens the app,
/// and a link opened on another device can be pasted here instead.
private struct CheckEmailView: View {
    let message: String
    let notice: String?
    let onPasteLink: (String) -> Bool
    let onEdit: () -> Void
    @State private var pasted = ""
    @State private var pasteFailed = false
    var body: some View {
        Text("Check your email").font(.headline).accessibilityIdentifier("signup-sent")
        Text(message)
        if let notice {
            Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("signup-link-error")
        }
        Text("Opened the email somewhere else? Paste the link here.").font(.footnote)
        TextField("Paste your sign-in link", text: $pasted)
            .textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Paste your sign-in link")
        if pasteFailed {
            Text("That doesn’t look like a DAD sign-in link.").font(.footnote).foregroundStyle(Color.dad("fail"))
                .accessibilityIdentifier("signup-paste-error")
        }
        Button("Continue") { pasteFailed = !onPasteLink(pasted) }
            .buttonStyle(DADButtonStyle(.primary)).disabled(pasted.isEmpty).accessibilityIdentifier("signup-continue")
        Button("Use a different email", action: onEdit).buttonStyle(DADButtonStyle(.secondary))
    }
}

/// An existing donor asks for a single-use sign-in link by email (`login`). The server never says
/// whether the address has an account, so the same "check your email" step follows either way.
private struct EmailLinkSignIn: View {
    @State var model: SignInLinkModel
    let notice: String?
    let onBack: () -> Void
    let onPasteLink: (String) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with an email link").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if case .sent(let email) = model.phase {
                CheckEmailView(
                    message: "If \(email) belongs to a DAD account, we sent it a sign-in link. Open it on this device to sign in. The link works once and expires in 15 minutes.",
                    notice: notice, onPasteLink: onPasteLink, onEdit: { model.edit() })
            } else {
                TextField("Email", text: $model.email)
                    .textFieldStyle(.roundedBorder).textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
                if case .failed(let message) = model.phase {
                    Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("email-link-error")
                }
                Button("Email me a link") { Task { await model.submit() } }
                    .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit).accessibilityIdentifier("email-link-submit")
                if model.phase == .submitting { ProgressView() }
            }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary))
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("email-link-sign-in")
    }
}

/// Email + password sign-in, bound to `PasswordSignInModel`. The password field is a secure entry
/// field that offers saved credentials; the model clears the secret as soon as it is sent.
private struct PasswordSignIn: View {
    @State var model: PasswordSignInModel
    let onBack: () -> Void
    let onSignedIn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with email & password").font(.title.bold()).accessibilityAddTraits(.isHeader)
            TextField("Email", text: $model.email)
                .textFieldStyle(.roundedBorder).textContentType(.username).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
            SecureField("Password", text: $model.password)
                .textFieldStyle(.roundedBorder).textContentType(.password).accessibilityLabel("Password")
            if case .failed(let message) = model.phase {
                Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("password-sign-in-error")
            }
            Button("Sign in") { Task { await model.submit() } }
                .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit).accessibilityIdentifier("password-sign-in-submit")
            if model.phase == .submitting { ProgressView() }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary))
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("password-sign-in")
        .onChange(of: model.phase) { _, phase in if case .signedIn = phase { onSignedIn() } }
    }
}

/// One in-flight Apple / Google / passkey attempt: the platform sheet runs on appear.
@MainActor private struct ExternalRun {
    let title: String
    let phase: () -> ExternalSignInPhase
    let start: () async -> Void
}

private struct ExternalSignInView: View {
    let run: ExternalRun
    let onBack: () -> Void
    let onSignedIn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(run.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            switch run.phase() {
            case .working: ProgressView()
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("external-sign-in-error")
                Button("Try again") { Task { await run.start() } }.buttonStyle(DADButtonStyle(.primary))
            case .idle:
                Button("Try again") { Task { await run.start() } }.buttonStyle(DADButtonStyle(.primary))
            case .signedIn:
                Text("You’re signed in.").font(.headline)
            }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary))
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("external-sign-in")
        .task { await run.start() }
        .onChange(of: run.phase()) { _, phase in if case .signedIn = phase { onSignedIn() } }
    }
}

/// Used when no API origin is configured (Release): sign-in fails clearly instead of inheriting a preview double.
private struct UnconfiguredSignIn: SignInService, SignupService, SignInLinkService, PasswordSignInService {
    func requestPhoneCode(phone: String) async throws -> String { throw AccountError.invalidConfiguration }
    func verifyPhone(handle: String, code: String) async throws -> Credentials { throw AccountError.invalidConfiguration }
    func requestSignup(_ form: SignupForm) async throws { throw AccountError.invalidConfiguration }
    func requestSignInLink(email: String) async throws { throw AccountError.invalidConfiguration }
    func signIn(email: String, password: String) async throws -> Credentials { throw AccountError.invalidConfiguration }
}

/// Every sign-in transport the unauthenticated stack can use, plus which optional methods are on.
private struct SignInKit {
    let phone: any SignInService
    let signup: any SignupService
    let link: any SignInLinkService
    let password: any PasswordSignInService
    let oidc: (any OIDCSignInService)?
    let passkey: (any PasskeySignInService)?
    let capabilities: SignInCapabilities
    var passkeyRelyingParty = ""

    static let unconfigured = SignInKit(phone: UnconfiguredSignIn(), signup: UnconfiguredSignIn(), link: UnconfiguredSignIn(),
                                        password: UnconfiguredSignIn(),
                                        oidc: nil, passkey: nil, capabilities: .none)
    #if DEBUG
    static let preview = SignInKit(phone: PreviewSignIn(), signup: PreviewSignIn(), link: PreviewSignIn(), password: PreviewSignIn(),
                                   oidc: nil, passkey: nil, capabilities: .none)
    #endif
}

/// The unauthenticated stack: role select → sign-in methods → the chosen method's flow. Verification
/// runs through `establish` so the session (not this view) owns the network await and its epoch guard.
private struct UnauthenticatedStack: View {
    let kit: SignInKit
    let establish: PhoneSignInModel.Establish
    let notice: String?
    var invitation: String?
    let onPasteLink: (String) -> Bool
    var partnerSignIn: (any PartnerSignInService)?
    var partnerToken: String?
    var onPartnerTokenConsumed: () -> Void = {}
    var onPartnerSignedIn: () -> Void = {}
    var publicOrigin: URL?
    let onSignedIn: () -> Void
    @State private var step: Step = .roleSelect
    @State private var external: ExternalRun?
    private enum Step: Equatable { case roleSelect, methods, phone, emailLink, password, signup, external, partner }

    var body: some View {
        content.onChange(of: partnerToken, initial: true) { _, token in if token != nil { step = .partner } }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .roleSelect:
            RoleSelect(notice: notice, invitation: invitation) { role in step = role == .donor ? .methods : .partner }
        case .methods:
            SignInMethods(capabilities: kit.capabilities, onSelect: select, onCreateAccount: { step = .signup })
        case .phone:
            PhoneSignIn(model: PhoneSignInModel(service: kit.phone, establish: establish), onSignedIn: onSignedIn)
        case .password:
            PasswordSignIn(model: PasswordSignInModel(service: kit.password, establish: establish),
                           onBack: { step = .methods }, onSignedIn: onSignedIn)
        case .emailLink:
            EmailLinkSignIn(model: SignInLinkModel(service: kit.link), notice: notice, onBack: { step = .methods }, onPasteLink: onPasteLink)
        case .signup:
            SignupView(model: SignupModel(service: kit.signup), notice: notice, onBack: { step = .methods }, onPasteLink: onPasteLink)
        case .external:
            if let external {
                ExternalSignInView(run: external, onBack: { step = .methods; self.external = nil }, onSignedIn: onSignedIn)
            }
        case .partner:
            if let partnerSignIn {
                PartnerSignInFlow(model: PartnerSignInModel(service: partnerSignIn), incomingToken: partnerToken,
                                  onTokenConsumed: onPartnerTokenConsumed, onBack: { step = .roleSelect }, onSignedIn: onPartnerSignedIn,
                                  applyURL: publicOrigin?.appending(path: "apply"))
            }
        }
    }

    private func select(_ method: SignInMethod) {
        switch method {
        case .phone: step = .phone
        case .emailLink: step = .emailLink
        case .password: step = .password
        case .apple, .google:
            guard let oidc = kit.oidc else { return }
            let provider: OIDCProvider = method == .apple ? .apple : .google
            let tokens: any IDTokenProvider = method == .apple ? AppleIDTokenProvider() : UnavailableIDTokenProvider()
            let model = OIDCSignInModel(provider: provider, tokens: tokens, service: oidc, establish: establish)
            external = ExternalRun(title: method.title, phase: { model.phase }, start: { await model.start() })
            step = .external
        case .passkey:
            guard let passkey = kit.passkey else { return }
            let model = PasskeySignInModel(authenticator: PlatformPasskeyAuthenticator(fallbackRelyingParty: kit.passkeyRelyingParty),
                                           service: passkey, establish: establish)
            external = ExternalRun(title: method.title, phase: { model.phase }, start: { await model.start() })
            step = .external
        }
    }
}

/// Settings presented from the donor shell: sign-out and deletion run against the real session, and
/// leaving the signed-in state dismisses the sheet so the root can route to sign-in.
private struct SettingsSheet: View {
    let service: any AccountSettingsService
    let passwords: (any PasswordSettingsService)?
    var management: (any AccountManagementService)?
    var giving: GivingKit?
    let onClose: () -> Void
    let onSignedOut: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button("Close", action: onClose).padding(.horizontal, 28).padding(.top, 20)
                    .accessibilityIdentifier("settings-close")
                AccountSettingsScreen(model: AccountSettingsModel(service: service), passwords: passwords, management: management,
                                      giving: giving, onSignedOut: onSignedOut)
            }
        }.modifier(AppBackground()).tint(tokenColor("brand-ink"))
    }
}

/// UIKit's push callbacks, surfaced to SwiftUI: the device token once APNs issues one, and the latest tapped
/// notification. Without the Push Notifications entitlement (it needs the signing team) APNs issues no token.
@MainActor @Observable
final class PushCenter {
    static let shared = PushCenter()
    var token: String?
    var tap: PushTap?
}

extension PushEnvironment {
    /// Development-signed (Debug) builds receive sandbox APNs tokens.
    static var ofThisBuild: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            // Already allowed (asked from Settings on an earlier launch): fetch this launch's token. Never prompts.
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if [.authorized, .provisional, .ephemeral].contains(status) { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.token = pushTokenHex(deviceToken)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let tap = PushTap(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PushCenter.shared.tap = tap }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main
struct DADApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate
    @State private var push = PushCenter.shared
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
            let preview = PreviewEvents()
            EventsScreen(model: EventsModel(service: preview), service: preview)
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
                     onSettings: model.makeSettings() == nil ? nil : { showSettings = true },
                     dashboard: model.dashboardService, giving: model.givingKit, events: model.eventsService,
                     engagement: model.engagementService, wallet: model.walletService,
                     destination: Binding(get: { model.destination }, set: { model.destination = $0 }),
                     onSignedOut: { Task { await model.load() } })
    }

    @ViewBuilder private var partnerRoot: some View {
        if let service = model.partnerService {
            PartnerPortal(model: PartnerModel(service: service), publicOrigin: model.publicOrigin, pushToken: push.token) {
                router.signedOut()
            }
        }
    }

    private var showsDonorShell: Bool {
        switch router.root {
        case .authenticated(.donor): return true
        case .restoring: return model.hasRestorableSession
        default: return false
        }
    }

    var body: some Scene {
        WindowGroup {
            ScrollView {
                Group {
                    if showsDonorShell {
                        // ONE branch for both "restoring with a stored session" and "signed in as donor":
                        // the restore -> signed-in transition must not change view identity, or the donor
                        // home is rebuilt a frame after it mounted, cancelling its in-flight dashboard
                        // read (result discarded) and starting a second one.
                        donorRoot
                    } else {
                    switch router.root {
                    case .authenticated(.donor):
                        donorRoot   // unreachable: handled by `showsDonorShell`
                    case .restoring:
                        // A session-less launch waits on a neutral progress view so it never flashes
                        // the signed-in screen (a restorable session is the donor shell above).
                        ProgressView().accessibilityIdentifier("restoring")
                    case .authenticated(.partner):
                        partnerRoot
                    case .unauthenticated:
                        UnauthenticatedStack(kit: model.kit, establish: model.establish(), notice: model.notice,
                                             invitation: model.invitation,
                                             onPasteLink: { model.openPastedLink($0) }, partnerSignIn: model.partnerSignIn,
                                             partnerToken: model.pendingPartnerToken,
                                             onPartnerTokenConsumed: { model.pendingPartnerToken = nil },
                                             onPartnerSignedIn: { router.selectRole(.partner); router.signedIn(as: .partner) },
                                             publicOrigin: model.publicOrigin) {
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
            }
            .modifier(AppBackground())
            .tint(tokenColor("brand-ink"))
            .environment(model.analytics)
            .task {
                model.analytics?.emit(.appOpened)
                #if DEBUG
                if launchFlag("--stub-push-tap-gifts") { push.tap = PushTap(category: "STREAK_AT_RISK", path: "/account/gifts") }
                // A preview screen is launched straight into its router state, before the profile
                // await, so the target renders immediately instead of dwelling in `.restoring`.
                if ["--preview-giving", "--preview-engagement", "--preview-events", "--preview-settings"].contains(where: launchFlag) {
                    router.signedIn(as: .donor)
                    return
                }
                if ["--preview-partner", "--preview-partner-viewer"].contains(where: launchFlag) {
                    router.signedIn(as: .partner)
                    return
                }
                #endif
                await model.load()
                // A session-backed shell is the donor journey — the donor landing owns every
                // account sub-state (loading / ready / unavailable / signed-out) and its own
                // recovery, so stay on it. Only a genuinely session-less app goes to role-select.
                // A session with nothing stored (or one the server revoked) is signed out: go to sign-in.
                // Without a donor session, a partner session still within its 12 hours reopens the portal.
                if model.state == .signedOut || !model.hasSession {
                    if await model.hasPartnerSession() { router.signedIn(as: .partner) } else { router.restoredSignedOut() }
                } else { router.signedIn(as: .donor) }
                #if DEBUG
                if launchFlag("--stub-open-invite"), let url = URL(string: "https://stub.invalid/r/ALEX42") {
                    _ = model.receive(url, role: router.currentRole)
                }
                #endif
            }
            .task(id: push.tap) {
                guard let tap = push.tap else { return }
                push.tap = nil
                model.openNotification(tap)
            }
            .task(id: PushRegistrationKey(token: push.token, ready: model.isReady)) { await model.registerPush(push.token) }
            .onChange(of: model.destination) { _, destination in
                if destination == .profile, model.makeSettings() != nil { model.destination = nil; showSettings = true }
                if destination == .dashboard { model.destination = nil }
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
                    SettingsSheet(service: service, passwords: model.passwordSettings, management: model.management, giving: model.givingKit, onClose: { showSettings = false },
                                  onSignedOut: { showSettings = false; Task { await model.load() } })
                    .environment(model.analytics)
                }
            }
            .onOpenURL { if let url = model.receive($0, role: router.currentRole) { web = WebDestination(url: url) } }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
                if let url = $0.webpageURL, let fallback = model.receive(url, role: router.currentRole) { web = WebDestination(url: fallback) }
            }
            .sheet(item: $web) { WebFallback(url: $0.url) }
        }
    }
}
