import Foundation

public enum PermissionState: Sendable { case notRequested, allowed, denied, unavailable }
public enum WalletKind: Sendable { case apple }

public protocol CameraPermission: Sendable {
    func status() async -> PermissionState
    func request() async -> PermissionState
}
public protocol PushRegistration: Sendable {
    func register(token: Data) async throws
    func unregister() async throws
}
public protocol WalletIssuance: Sendable {
    func pass(kind: WalletKind) async throws -> Data
}
