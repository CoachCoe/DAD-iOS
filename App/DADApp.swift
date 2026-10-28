import SwiftUI
import DADFoundation
import SafariServices
import CryptoKit

private func tokenColor(_ name: String) -> Color {
    guard let token = DADTokens.color[name], token.count == 7, let value = UInt32(token.dropFirst(), radix: 16) else { return .primary }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}

private struct AppBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.background(tokenColor(scheme == .dark ? "ink-deep" : "paper")) }
}

private final class PreviewStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials? = Credentials(access: "preview", refresh: "preview-refresh", expiresAt: .distantFuture)
    func load() throws -> Credentials? { lock.withLock { value } }
    func save(_ credentials: Credentials) throws { lock.withLock { value = credentials } }
    func clear() throws { lock.withLock { value = nil } }
}

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

@MainActor @Observable
private final class AccountModel {
    enum State { case loading, ready(AccountProfile), unavailable, signedOut }
    var state = State.loading
    private let session: AccountSession?
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
    init() {
        let apiOrigin = Bundle.main.object(forInfoDictionaryKey: "DADAPIOrigin") as? String ?? ""
        preview = apiOrigin.isEmpty
        router = (Bundle.main.object(forInfoDictionaryKey: "DADPublicOrigin") as? String)
            .flatMap(URL.init(string:)).flatMap { try? LinkRouter(publicOrigin: $0) }
        // A session-less launch (no stored credentials) lands on role-select + the auth shell;
        // the preview normally starts signed-in, so this path is opt-in for the auth journey/UITest.
        if ProcessInfo.processInfo.arguments.contains("--preview-signed-out") {
            session = nil
            state = .signedOut
            return
        }
        do {
            if apiOrigin.isEmpty {
                session = try AccountSession(api: PreviewAPI(failFirst: ProcessInfo.processInfo.arguments.contains("--preview-unavailable")), store: PreviewStore())
            } else {
                guard let origin = URL(string: apiOrigin) else { throw AccountError.invalidConfiguration }
                session = try AccountSession(api: WireAPI(origin: origin), store: KeychainStore(service: "org.dad.foundation.preview"))
            }
        } catch { session = nil; state = .unavailable }
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
                } catch { state = .unavailable }
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
    let onSelect: (AppRole) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("DAD").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Good things start together.").font(.title).accessibilityAddTraits(.isHeader)
            VStack(spacing: 12) {
                Button("I’m a donor") { onSelect(.donor) }.buttonStyle(DADButtonStyle(.primary))
                Button("I’m a partner") { onSelect(.partner) }.buttonStyle(DADButtonStyle(.secondary))
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityIdentifier("role-select")
    }
}

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

/// Set / change your recurring gift (G-1/G-2/G-7). A $1–$30/day stepper with the monthly
/// equivalent (×30) shown derived, the streak bar, and a cancel path (G-8/G-9) with the
/// ends-streak confirmation copy. Bound to `GivingModel`.
private struct GiftScreen: View {
    @State var model: GivingModel
    @State private var confirmingCancel = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set your gift").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            DADCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.selection.dailyLabel).font(.system(size: 44, weight: .bold))
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
                Button("Cancel gift") { confirmingCancel = true }
                    .buttonStyle(DADButtonStyle(.secondary))
            }
            if model.recurring.isEnding {
                Text("Your gift won’t renew — it stays active until the period ends.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("gift-ending")
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityIdentifier("gift-screen")
        .task { await model.load() }
        .confirmationDialog("Cancel your gift?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel gift", role: .destructive) { Task { await model.cancel() } }
            Button("Keep giving", role: .cancel) {}
        } message: {
            if case let .active(_, _, periodEnd) = model.recurring {
                Text(CancelCopy.confirmation(periodEnd: periodEnd))
            }
        }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with your phone").font(.title.bold()).accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .enterPhone, .requestingCode, .failed:
                TextField("Phone number", text: $model.phone)
                    .textContentType(.telephoneNumber)
                    .accessibilityLabel("Phone number")
                if case .failed(let message) = model.phase {
                    Text(message).font(.footnote).foregroundStyle(Color.dad("fail"))
                }
                Button("Send code") { Task { await model.requestCode() } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!model.canRequestCode)
            case .enterCode, .verifying:
                TextField("Verification code", text: $model.code)
                    .textContentType(.oneTimeCode)
                    .accessibilityLabel("Verification code")
                Button("Verify") { Task { await model.verify() } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!model.canVerify)
            case .signedIn:
                Text("You’re signed in.").font(.headline)
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityIdentifier("phone-sign-in")
    }
}

/// The unauthenticated stack: role select → sign-in methods → the chosen method's flow.
private struct UnauthenticatedStack: View {
    let selectedRole: AppRole?
    // @Sendable so this can be captured by PhoneSignInModel's @Sendable onEstablish closure
    // under Swift 6 strict concurrency; the view hierarchy is @MainActor so the hop is safe.
    let onSignedIn: @Sendable (AppRole) async -> Void
    @State private var step: Step = .roleSelect
    private enum Step: Equatable { case roleSelect, methods(AppRole), phone(AppRole) }
    var body: some View {
        switch step {
        case .roleSelect:
            RoleSelect { role in step = .methods(role) }
        case .methods(let role):
            SignInMethods { step = .phone(role) }
        case .phone(let role):
            PhoneSignIn(model: PhoneSignInModel(service: PreviewSignIn()) { _ in await onSignedIn(role) })
        }
    }
}

@main
struct DADApp: App {
    @State private var model = AccountModel()
    @State private var router = RoleRouter()
    @State private var web: WebDestination?
    var body: some Scene {
        WindowGroup {
            ScrollView {
                Group {
                    switch router.root {
                    case .authenticated(.donor):
                        if ProcessInfo.processInfo.arguments.contains("--preview-giving") {
                            GiftScreen(model: GivingModel(service: PreviewGiving()))
                        } else {
                            DonorLanding(state: model.state, preview: model.preview) { Task { await model.load() } }
                        }
                    case .restoring:
                        // During restore, show the donor landing only when a session exists
                        // (its loading state covers the wait); a session-less launch waits on a
                        // neutral progress view so it never flashes the signed-in screen.
                        if model.hasSession {
                            DonorLanding(state: model.state, preview: model.preview) { Task { await model.load() } }
                        } else {
                            ProgressView().accessibilityIdentifier("restoring")
                        }
                    case .authenticated(.partner):
                        PartnerLanding()
                    case .unauthenticated(let selectedRole):
                        UnauthenticatedStack(selectedRole: selectedRole) { role in
                            await MainActor.run {
                                router.selectRole(role)
                                router.signedIn(as: role)
                            }
                        }
                    }
                }
            }
            .modifier(AppBackground())
            .tint(tokenColor("brand-ink"))
            .task {
                // The giving preview exercises the signed-in GiftScreen directly: route to the
                // donor shell up front (deterministically, before the profile await) so the
                // switch shows GiftScreen immediately instead of dwelling in `.restoring` /
                // DonorLanding during PreviewAPI's load delay.
                if ProcessInfo.processInfo.arguments.contains("--preview-giving") {
                    router.signedIn(as: .donor)
                    return
                }
                await model.load()
                // A session-backed shell is the donor journey — the donor landing owns every
                // account sub-state (loading / ready / unavailable / signed-out) and its own
                // recovery, so stay on it. Only a genuinely session-less app goes to role-select.
                if model.hasSession { router.signedIn(as: .donor) } else { router.restoredSignedOut() }
            }
            .onOpenURL { if let url = model.receive($0) { web = WebDestination(url: url) } }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
                if let url = $0.webpageURL, let fallback = model.receive(url) { web = WebDestination(url: fallback) }
            }
            .sheet(item: $web) { WebFallback(url: $0.url) }
        }
    }
}
