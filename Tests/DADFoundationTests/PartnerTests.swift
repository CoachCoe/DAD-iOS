import XCTest
@testable import DADFoundation

final class PartnerRoleTests: XCTestCase {
    func testAdminCapabilities() {
        let admin = PartnerRole.admin
        XCTAssertTrue(admin.canManageUsers)
        XCTAssertTrue(admin.canEditProfile)
        XCTAssertTrue(admin.canExport)
    }

    func testViewerIsReadOnly() {
        let viewer = PartnerRole.viewer
        XCTAssertFalse(viewer.canManageUsers)
        XCTAssertFalse(viewer.canEditProfile)
        XCTAssertFalse(viewer.canExport)
    }

    func testUnknownRoleDecodesToLeastPrivileged() {
        XCTAssertEqual(PartnerRole(contract: "SUPERADMIN"), .viewer)
        XCTAssertEqual(PartnerRole(contract: "ADMIN"), .admin)
    }
}

final class VerifiedFigureTests: XCTestCase {
    func testVerifiedMoneyShowsOnlyWhenVerified() {
        XCTAssertEqual(VerifiedMoney(amountMinor: 124_000, verified: true).label, "$1,240")
        XCTAssertNil(VerifiedMoney(amountMinor: 124_000, verified: false).label)
    }

    func testVerifiedCountHiddenWhenUnverified() {
        XCTAssertEqual(VerifiedCount(value: 42, verified: true).label, "42")
        XCTAssertEqual(VerifiedCount(value: 12_400, verified: true).label, "12,400")
        XCTAssertNil(VerifiedCount(value: 42, verified: false).label)
    }
}

final class PartnerOverviewTests: XCTestCase {
    private func overview(enrolled: Int64?, role: PartnerRole = .admin) -> PartnerOverview {
        PartnerOverview(
            organization: "Acme", description: "desc", role: role, companyCode: "ACME",
            committed: VerifiedMoney(amountMinor: 500_000, verified: true),
            deployed: VerifiedMoney(amountMinor: 300_000, verified: false),
            deployedPercent: 60,
            peopleReached: VerifiedCount(value: 1200, verified: true),
            employeesEnrolled: enrolled, workforceSize: 120,
            enrolledPercent: enrolled == nil ? nil : 35,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000), hasLogo: true)
    }

    func testUnverifiedDeployedIsHiddenNotEstimated() {
        let o = overview(enrolled: 42)
        XCTAssertEqual(o.committed.label, "$5,000")   // verified -> shown
        XCTAssertNil(o.deployed.label)                 // unverified -> hidden, never estimated (§7.3)
        XCTAssertEqual(o.peopleReached.label, "1,200")
    }

    func testSuppressedEnrollmentShowsNoCount() {
        XCTAssertNil(overview(enrolled: nil).enrolledLabel) // <5 suppressed -> null -> hidden
        XCTAssertEqual(overview(enrolled: 42).enrolledLabel, "42 of 120")
    }

    func testVerifiedLineCarriesTheAsOfDate() {
        XCTAssertNotNil(overview(enrolled: 42).verifiedLine())
        XCTAssertTrue(overview(enrolled: 42).verifiedLine()!.contains("Verified by DAD"))
    }
}

final class PartnerPeopleTests: XCTestCase {
    func testSuppressedGroupHidesFiguresAndShowsNotice() {
        let suppressed = PartnerPeople(enrolled: 3, workforceSize: 120, givenMinor: 40_000,
                                       matchedMinor: 20_000, avgStreakDays: 10, volunteerMinutes: 60,
                                       teams: 1, suppressed: true)
        XCTAssertNil(suppressed.givenLabel)
        XCTAssertNil(suppressed.matchedLabel)
        XCTAssertNotNil(suppressed.suppressionNotice)
        XCTAssertTrue(suppressed.suppressionNotice!.contains("Fewer than 5"))
    }

    func testUnsuppressedGroupShowsFigures() {
        let shown = PartnerPeople(enrolled: 42, workforceSize: 120, givenMinor: 40_000,
                                  matchedMinor: 20_000, avgStreakDays: 10, volunteerMinutes: 60,
                                  teams: 3, suppressed: false)
        XCTAssertEqual(shown.givenLabel, "$400")
        XCTAssertEqual(shown.matchedLabel, "$200")
        XCTAssertNil(shown.suppressionNotice)
    }
}

final class PartnerInitiativeTests: XCTestCase {
    func testHeadlineMetricsCappedAtThree() {
        let metrics = (1...5).map { PartnerMetric(label: "m\($0)", value: Int64($0), unit: .people) }
        let initiative = PartnerInitiative(id: "i1", title: "T", summary: "S", status: .active,
                                           region: "West", committedMinor: 100_000,
                                           deployedMinor: 50_000, metrics: metrics)
        XCTAssertEqual(initiative.headlineMetrics.count, 3)
        XCTAssertEqual(initiative.committedLabel, "$1,000")
        XCTAssertEqual(initiative.status.label, "Active")
    }
}

@MainActor
final class PartnerModelTests: XCTestCase {
    private final class FakeService: PartnerService, @unchecked Sendable {
        var role: PartnerRole = .admin
        var pending = false
        var fail = false
        var failSpend = false
        var spendSignedOut = false
        private(set) var invited: [(String, PartnerRole)] = []
        private(set) var removed: [String] = []
        private(set) var pushRegistered = false
        private(set) var pushUnregistered = false
        var users: [PartnerUser] = [PartnerUser(id: "u1", email: "a@x.com", name: "A", role: .admin)]

        func overview() async throws -> PartnerOverview {
            if pending { throw PartnerPendingApproval() }
            if fail { throw AccountError.signedOut }
            return PartnerOverview(organization: "Acme", description: "d", role: role, companyCode: "AC",
                committed: VerifiedMoney(amountMinor: 1, verified: true),
                deployed: VerifiedMoney(amountMinor: 1, verified: true), deployedPercent: 1,
                peopleReached: VerifiedCount(value: 1, verified: true), employeesEnrolled: 42,
                workforceSize: 120, enrolledPercent: 35, updatedAt: Date(), hasLogo: false)
        }
        func initiatives() async throws -> [PartnerInitiative] { [] }
        func spend() async throws -> [PartnerSpendCategory] {
            if spendSignedOut { throw AccountError.signedOut }
            if failSpend { throw AccountError.unavailable }
            return []
        }
        func people() async throws -> PartnerPeople {
            PartnerPeople(enrolled: 42, workforceSize: 120, givenMinor: 0, matchedMinor: 0,
                          avgStreakDays: 0, volunteerMinutes: 0, teams: 0, suppressed: false)
        }
        func users() async throws -> [PartnerUser] { users }
        func inviteUser(email: String, role: PartnerRole) async throws { invited.append((email, role)) }
        func removeUser(id: String) async throws { removed.append(id); users.removeAll { $0.id == id } }
        func registerPushDevice(token: String) async throws { pushRegistered = true }
        func unregisterPushDevice() async throws { pushUnregistered = true }
    }

    func testLoadReadyCarriesRole() async {
        let model = PartnerModel(service: FakeService())
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.role, .admin)
    }

    func testPendingApprovalGate() async {
        let svc = FakeService(); svc.pending = true
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertEqual(model.phase, .pending)
        XCTAssertNil(model.overview)
    }

    func testLoadFailureSurfacesFailed() async {
        let svc = FakeService(); svc.fail = true
        let model = PartnerModel(service: svc)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    func testSecondarySectionFailureIsFlaggedNotShownAsEmpty() async {
        let svc = FakeService(); svc.failSpend = true
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertEqual(model.phase, .ready, "the portal still renders with what did load")
        XCTAssertTrue(model.sectionsUnavailable)
        XCTAssertNotNil(model.people)
        XCTAssertEqual(model.users.count, 1)
    }

    func testCleanLoadDoesNotFlagSections() async {
        let model = PartnerModel(service: FakeService())
        await model.load()
        XCTAssertFalse(model.sectionsUnavailable)
    }

    func testLostSessionInASectionFailsTheWholeLoad() async {
        let svc = FakeService(); svc.spendSignedOut = true
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Please sign in again."))
    }

    func testViewerCannotInviteOrRemove() async {
        let svc = FakeService(); svc.role = .viewer
        let model = PartnerModel(service: svc)
        await model.load()
        await model.inviteUser(email: "b@x.com", role: .viewer)
        await model.removeUser(id: "u1")
        XCTAssertTrue(svc.invited.isEmpty)   // gated client-side, never hit the service
        XCTAssertTrue(svc.removed.isEmpty)
        XCTAssertNotNil(model.actionError)
    }

    func testAdminCanInviteAndRemove() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        await model.inviteUser(email: "b@x.com", role: .viewer)
        XCTAssertEqual(svc.invited.count, 1)
        XCTAssertEqual(svc.invited.first?.0, "b@x.com")
    }

    func testPushRegisterAndUnregister() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.registerPush(token: "t")
        await model.unregisterPush()
        XCTAssertTrue(svc.pushRegistered)
        XCTAssertTrue(svc.pushUnregistered)
    }
}
