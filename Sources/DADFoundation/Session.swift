import Foundation

public enum AccountError: Error, Sendable, Equatable {
    case signedOut
    case unavailable
    case invalidConfiguration
    case invalidResponse
    case secureStorage(Int32)
}

public struct Credentials: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let access: String
    public let refresh: String
    public let expiresAt: Date
    public var description: String { "Credentials([redacted])" }
    public var debugDescription: String { description }
    public init(access: String, refresh: String, expiresAt: Date) {
        self.access = access; self.refresh = refresh; self.expiresAt = expiresAt
    }
}

public struct AccountProfile: Sendable, Equatable {
    public let email: String
    public let publicName: String?
    public init(email: String, publicName: String?) { self.email = email; self.publicName = publicName }
}

public protocol AccountAPI: Sendable {
    func profile(access: String) async throws -> AccountProfile
    func refresh(token: String) async throws -> Credentials
    func claim(token: String) async throws -> Credentials
    func logout(access: String) async throws
}

public protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func clear() throws
}

public actor AccountSession {
    private let api: any AccountAPI
    private let store: any CredentialStore
    private var credentials: Credentials?
    private var epoch = 0
    private var flight: (id: UUID, task: Task<Credentials, Error>)?

    public init(api: any AccountAPI, store: any CredentialStore) throws {
        self.api = api; self.store = store; self.credentials = try store.load()
    }

    public func claim(token: String) async throws {
        let before = epoch
        let result = try await api.claim(token: token)
        guard before == epoch else { throw AccountError.signedOut }
        try store.save(result)
        credentials = result
        epoch += 1
        flight = nil
    }

    public func profile() async throws -> AccountProfile {
        try Task.checkCancellation()
        let before = epoch
        let current = try await usableCredentials()
        do {
            let result = try await api.profile(access: current.access)
            guard before == epoch else { throw AccountError.signedOut }
            try Task.checkCancellation()
            return result
        } catch AccountError.signedOut {
            guard before == epoch else { throw AccountError.signedOut }
            let next = try await usableCredentials(forceFor: current.access)
            do { return try await checkedProfile(next, epoch: before) }
            catch AccountError.signedOut {
                if before == epoch { try clearLocal() }
                throw AccountError.signedOut
            }
        }
    }

    private func checkedProfile(_ value: Credentials, epoch before: Int) async throws -> AccountProfile {
        let result = try await api.profile(access: value.access)
        guard before == epoch else { throw AccountError.signedOut }
        try Task.checkCancellation()
        return result
    }

    private func usableCredentials(forceFor access: String? = nil) async throws -> Credentials {
        guard let current = credentials else { throw AccountError.signedOut }
        if flight == nil, current.expiresAt.timeIntervalSinceNow > 30, access != current.access { return current }
        let before = epoch
        let pending: (id: UUID, task: Task<Credentials, Error>)
        if let active = flight { pending = active }
        else {
            let api = self.api
            pending = (UUID(), Task { try await api.refresh(token: current.refresh) })
            flight = pending
        }
        do {
            let refreshed = try await pending.task.value
            guard before == epoch else { throw AccountError.signedOut }
            if flight?.id == pending.id {
                do { try store.save(refreshed) }
                catch { try clearLocal(); throw error }
                credentials = refreshed
                flight = nil
            }
            guard let latest = credentials else { throw AccountError.signedOut }
            try Task.checkCancellation()
            return latest
        } catch {
            if before == epoch, flight?.id == pending.id {
                flight = nil
                if error as? AccountError == .signedOut { try clearLocal() }
            }
            throw error
        }
    }

    private func clearLocal() throws {
        epoch += 1
        credentials = nil
        flight = nil
        try store.clear()
    }

    // Keep a refresh already in progress so remote logout can use its new access token.
    public func logout() async throws {
        let old = credentials
        let pending = flight?.task
        try clearLocal()
        var access = old?.access
        if let pending {
            do { access = try await pending.value.access }
            catch { if access == nil { throw error } }
        }
        if let access { try await api.logout(access: access) }
    }
}
