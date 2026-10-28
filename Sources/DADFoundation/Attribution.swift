import Foundation

/// Where a new donor came from, captured BEFORE sign-up and carried across an app
/// install/cold-launch so it can be attached at account creation (PRD D-3 deferred
/// attribution, D-4 company code). iOS has no native install-referrer, so the capture
/// strategy is a deep link / pasteboard bridge surfaced on the landing screen; this type
/// is the persisted payload, independent of how it arrived.
public struct Attribution: Codable, Sendable, Equatable {
    /// An invite code from a sharing link (person-to-person referral).
    public var inviteCode: String?
    /// An in-real-life code (printed/QR at an event), distinct from an online invite.
    public var irlCode: String?
    /// An employer/company code (D-4) — joins the donor to a workforce team.
    public var companyCode: String?
    /// The raw source path/campaign tag, kept for the analytics `attribution_captured` event.
    public var source: String?

    public init(inviteCode: String? = nil, irlCode: String? = nil, companyCode: String? = nil, source: String? = nil) {
        self.inviteCode = Attribution.sanitized(inviteCode)
        self.irlCode = Attribution.sanitized(irlCode)
        self.companyCode = Attribution.sanitized(companyCode)
        self.source = Attribution.sanitized(source)
    }

    /// True when nothing worth persisting was captured.
    public var isEmpty: Bool {
        inviteCode == nil && irlCode == nil && companyCode == nil && source == nil
    }

    /// Codes are short alphanumerics; reject anything that is not, so a crafted deep link
    /// cannot stuff arbitrary data through the attribution channel into sign-up.
    static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(trimmed.count),
              trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return trimmed
    }
}

/// Persists the captured attribution across launches. A protocol so tests drive an
/// in-memory store and the app uses `UserDefaults` (survives a cold launch; not the
/// Keychain, because this is non-secret marketing attribution, not a credential).
public protocol AttributionStore: Sendable {
    func load() -> Attribution?
    func save(_ attribution: Attribution)
    func clear()
}

public struct DefaultsAttributionStore: AttributionStore {
    // UserDefaults is thread-safe per Apple's docs but predates Sendable; the annotation
    // records that the unchecked capture is deliberate, not an oversight.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "org.dad.attribution") {
        self.defaults = defaults
        self.key = key
    }
    public func load() -> Attribution? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Attribution.self, from: data)
    }
    public func save(_ attribution: Attribution) {
        guard !attribution.isEmpty, let data = try? JSONEncoder().encode(attribution) else { return }
        defaults.set(data, forKey: key)
    }
    public func clear() { defaults.removeObject(forKey: key) }
}

/// Captures attribution from an incoming source and MERGES it with whatever was already
/// stored, so an invite captured on first touch is not lost when a later company code
/// arrives. First writer wins per field (the earliest touch is the truest attribution);
/// a new field only fills a slot that was empty.
public struct AttributionCapture: Sendable {
    private let store: any AttributionStore
    public init(store: any AttributionStore) { self.store = store }

    @discardableResult
    public func capture(_ incoming: Attribution) -> Attribution {
        let existing = store.load() ?? Attribution()
        let merged = Attribution(
            inviteCode: existing.inviteCode ?? incoming.inviteCode,
            irlCode: existing.irlCode ?? incoming.irlCode,
            companyCode: existing.companyCode ?? incoming.companyCode,
            source: existing.source ?? incoming.source
        )
        // Nothing worth keeping — do not write an empty record (holds for any store).
        if !merged.isEmpty { store.save(merged) }
        return merged
    }

    public func current() -> Attribution? { store.load() }

    /// Called once attribution has been attached to a created account.
    public func consume() { store.clear() }
}
