import XCTest
@testable import DADFoundation

final class AccountPreferencesTests: XCTestCase {
    private func prefs() -> AccountPreferences {
        AccountPreferences(
            version: 3, referralEmails: true, marketingEmails: false, pushReferralConverted: true,
            pushStreakAtRisk: true, pushStreakMilestone: true, pushStreakLapsed: true,
            pushBadgeEarned: true, pushEventNearby: false, pushEventReminder: true,
            pushEventPromoted: false, pushGiftProcessed: true, rankingsOptedOut: false,
            networkVisible: true, volunteer: true)
    }

    func testWithFlipsTheRightToggle() {
        XCTAssertTrue(prefs().with("marketing_emails", true).marketingEmails)
        XCTAssertFalse(prefs().with("push_event_reminder", false).pushEventReminder)
        XCTAssertEqual(prefs(), prefs().with("nonexistent", true)) // unknown key is a no-op
    }

    func testPushTogglesExcludePaymentFailure() {
        let keys = prefs().pushToggles.map(\.key)
        XCTAssertEqual(keys.count, 9)
        XCTAssertFalse(keys.contains { $0.contains("payment") })
        XCTAssertTrue(keys.contains("push_streak_at_risk"))
    }

    func testShowRankingInvertsOptedOut() {
        var p = prefs()
        XCTAssertTrue(p.showRanking)
        p = p.with("rankings_opted_out", true)
        XCTAssertFalse(p.showRanking)
    }
}

final class DeleteAccountGateTests: XCTestCase {
    func testRequiresExactWord() {
        XCTAssertFalse(DeleteAccountGate(typed: "delete").isConfirmed) // case-sensitive
        XCTAssertFalse(DeleteAccountGate(typed: "").isConfirmed)
        XCTAssertFalse(DeleteAccountGate(typed: "DELETE ").isConfirmed)
        XCTAssertTrue(DeleteAccountGate(typed: "DELETE").isConfirmed)
    }
}

@MainActor
final class AccountSettingsModelTests: XCTestCase {
    private final class FakeService: AccountSettingsService, @unchecked Sendable {
        var failLoad = false
        private(set) var deleted = false
        private(set) var didSignOut = false
        private var prefs = AccountPreferences(
            version: 3, referralEmails: true, marketingEmails: false, pushReferralConverted: true,
            pushStreakAtRisk: true, pushStreakMilestone: true, pushStreakLapsed: true,
            pushBadgeEarned: true, pushEventNearby: false, pushEventReminder: true,
            pushEventPromoted: false, pushGiftProcessed: true, rankingsOptedOut: false,
            networkVisible: true, volunteer: true)
        private func snap() -> AccountSettingsSnapshot {
            AccountSettingsSnapshot(
                profile: AccountProfileSummary(email: "d@x.com", accountRole: "DONOR", zip: "78701", city: "Austin", phone: nil),
                preferences: prefs)
        }
        func load() async throws -> AccountSettingsSnapshot {
            if failLoad { throw AccountError.signedOut }
            return snap()
        }
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
            return snap()
        }
        func deleteAccount() async throws { deleted = true }
        func signOut() async throws { didSignOut = true }
    }

    func testLoadReadySetsSnapshot() async {
        let model = AccountSettingsModel(service: FakeService())
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.snapshot?.profile.zip, "78701")
    }

    func testLoadFailureSurfacesFailed() async {
        let svc = FakeService(); svc.failLoad = true
        let model = AccountSettingsModel(service: svc)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    func testToggleSavesAndBumpsVersion() async {
        let model = AccountSettingsModel(service: FakeService())
        await model.load()
        XCTAssertEqual(model.snapshot?.preferences.version, 3)
        await model.toggle("marketing_emails", true)
        XCTAssertEqual(model.snapshot?.preferences.version, 4)
        XCTAssertTrue(model.snapshot!.preferences.marketingEmails)
    }

    func testDeleteRequiresConfirmThenWipes() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        // Unconfirmed: no-op with an error, nothing deleted.
        await model.deleteAccount(DeleteAccountGate(typed: "nope"))
        XCTAssertFalse(svc.deleted)
        XCTAssertFalse(model.signedOut)
        // Confirmed: deletes then wipes.
        await model.deleteAccount(DeleteAccountGate(typed: "DELETE"))
        XCTAssertTrue(svc.deleted)
        XCTAssertTrue(svc.didSignOut)
        XCTAssertTrue(model.signedOut)
    }

    func testSignOutWipes() async {
        let svc = FakeService()
        let model = AccountSettingsModel(service: svc)
        await model.load()
        await model.signOut()
        XCTAssertTrue(svc.didSignOut)
        XCTAssertTrue(model.signedOut)
    }
}
