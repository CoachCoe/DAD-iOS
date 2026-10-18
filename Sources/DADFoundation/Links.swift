import Foundation

public enum AccountDestination: String, Sendable, Equatable {
    case dashboard = "/account/dashboard"
    case profile = "/account/profile"
    case paymentMethod = "/account/payment-method"
}

public enum LinkIntent: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case account(AccountDestination)
    case claim(token: String, next: AccountDestination?)
    case emailChange(token: String)
    case web(URL)
    public var description: String {
        switch self {
        case .account(let destination): "Account(\(destination.rawValue))"
        case .claim: "Claim([redacted])"
        case .emailChange: "EmailChange([redacted])"
        case .web: "WebLink([redacted])"
        }
    }
    public var debugDescription: String { description }
}

private struct LinkPolicy: Decodable, Sendable {
    let accountPaths: [String]
    let proofPaths: [String]
    let claimReturnPaths: [String]
    let notificationPaths: [String]
}

extension URL {
    /// An HTTPS origin with no credentials, path, query, or fragment.
    var isBareHTTPSOrigin: Bool {
        scheme == "https" && host != nil && user == nil && password == nil && query == nil && fragment == nil
            && (path.isEmpty || path == "/")
    }
}

public struct LinkRouter: Sendable {
    private let origin: URL
    private let policy: LinkPolicy
    public init(publicOrigin: URL) throws {
        guard publicOrigin.isBareHTTPSOrigin,
              let file = Bundle.module.url(forResource: "links", withExtension: "json") else { throw AccountError.invalidConfiguration }
        origin = publicOrigin
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        policy = try decoder.decode(LinkPolicy.self, from: Data(contentsOf: file))
    }
    public func route(_ url: URL) -> LinkIntent? {
        guard url.absoluteString.count <= 4096, url.scheme == origin.scheme, url.host == origin.host, (url.port ?? 443) == (origin.port ?? 443),
              url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c") else { return nil }
        if policy.proofPaths.contains(url.path) {
            guard url.query == nil, let fragment = parts.fragment,
                  let values = URLComponents(string: "?" + fragment)?.queryItems,
                  values.filter({ $0.name == "token" }).count == 1,
                  let token = values.first(where: { $0.name == "token" })?.value,
                  (32...128).contains(token.count), token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  values.allSatisfy({ $0.name == "token" || (url.path == "/account/claim" && $0.name == "next") }),
                  values.filter({ $0.name == "next" }).count <= 1 else { return nil }
            if url.path == "/account/email-change" { return .emailChange(token: token) }
            let next = values.first(where: { $0.name == "next" })?.value
            if let next, !policy.claimReturnPaths.contains(next) { return nil }
            return .claim(token: token, next: next.flatMap(AccountDestination.init(rawValue:)))
        }
        if policy.accountPaths.contains(url.path), url.query == nil, url.fragment == nil,
           let destination = AccountDestination(rawValue: url.path) { return .account(destination) }
        return .web(url)
    }
    public func notification(path: String) -> AccountDestination? {
        guard policy.notificationPaths.contains(path) else { return nil }
        return AccountDestination(rawValue: path)
    }
}

public struct NavigationGate: Sendable {
    public private(set) var pending: AccountDestination?
    public init() {}
    public mutating func receive(_ destination: AccountDestination, signedIn: Bool) -> AccountDestination? {
        if signedIn { return destination }
        pending = destination
        return nil
    }
    public mutating func signedIn() -> AccountDestination? {
        defer { pending = nil }
        return pending
    }
    public mutating func signedOut() { pending = nil }
}
