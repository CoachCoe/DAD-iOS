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
    init() {
        let apiOrigin = Bundle.main.object(forInfoDictionaryKey: "DADAPIOrigin") as? String ?? ""
        preview = apiOrigin.isEmpty
        router = (Bundle.main.object(forInfoDictionaryKey: "DADPublicOrigin") as? String)
            .flatMap(URL.init(string:)).flatMap { try? LinkRouter(publicOrigin: $0) }
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

@main
struct DADApp: App {
    @State private var model = AccountModel()
    @State private var web: WebDestination?
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("DAD").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Good things start together.").font(.title).accessibilityAddTraits(.isHeader)
                    Group {
                        switch model.state {
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
                                Button("Try again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
                            }
                        case .signedOut:
                            Text("You’re signed out. Use your DAD sign-in link to continue.")
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("account-state")
                    if model.preview { Text("Preview · Sample account").font(.footnote).foregroundStyle(.secondary) }
                }.frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
            .modifier(AppBackground())
            .tint(tokenColor("brand-ink"))
            .task { await model.load() }
            .onOpenURL { if let url = model.receive($0) { web = WebDestination(url: url) } }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
                if let url = $0.webpageURL, let fallback = model.receive(url) { web = WebDestination(url: fallback) }
            }
            .sheet(item: $web) { WebFallback(url: $0.url) }
        }
    }
}
