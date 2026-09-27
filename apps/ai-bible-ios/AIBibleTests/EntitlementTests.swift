import XCTest
@testable import AIBible

final class EntitlementReducerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testVerifiedPurchaseUnlocks() {
        let state = EntitlementReducer.reduce(EntitlementState(), .purchased(.verified, at: date))
        XCTAssertEqual(state.access, .full)
        XCTAssertEqual(state.lastVerifiedAt, date)
    }

    func testUnverifiedPurchaseNeverUnlocks() {
        let state = EntitlementReducer.reduce(EntitlementState(), .purchased(.unverified, at: date))
        XCTAssertEqual(state.access, .sample)
    }

    func testCancelLeavesStateAlone() {
        let start = EntitlementState(access: .sample, awaitingApproval: true, lastVerifiedAt: nil)
        XCTAssertEqual(EntitlementReducer.reduce(start, .purchased(.cancelled, at: date)), start)
    }

    func testPendingIsRememberedAndClearedByApproval() {
        var state = EntitlementReducer.reduce(EntitlementState(), .purchased(.pending, at: date))
        XCTAssertTrue(state.awaitingApproval)
        XCTAssertEqual(state.access, .sample)

        // A relaunch reads no entitlement yet; the pending flag survives.
        state = EntitlementReducer.reduce(state, .refreshed(.none, at: date))
        XCTAssertTrue(state.awaitingApproval)

        state = EntitlementReducer.reduce(state, .transactionUpdate(.active, at: date))
        XCTAssertFalse(state.awaitingApproval)
        XCTAssertEqual(state.access, .full)
    }

    func testRevocationLocks() {
        let unlocked = EntitlementState(access: .full, awaitingApproval: false, lastVerifiedAt: date)
        XCTAssertEqual(EntitlementReducer.reduce(unlocked, .transactionUpdate(.revoked, at: date)).access, .sample)
        XCTAssertEqual(EntitlementReducer.reduce(unlocked, .refreshed(.revoked, at: date)).access, .sample)
    }

    func testAuthoritativeEmptyReadLocks() {
        let unlocked = EntitlementState(access: .full, awaitingApproval: false, lastVerifiedAt: date)
        XCTAssertEqual(EntitlementReducer.reduce(unlocked, .refreshed(.none, at: date)).access, .sample)
    }

    func testUnavailableReadKeepsCachedState() {
        let unlocked = EntitlementState(access: .full, awaitingApproval: false, lastVerifiedAt: date)
        XCTAssertEqual(EntitlementReducer.reduce(unlocked, .refreshUnavailable), unlocked)
    }

    func testStateSurvivesRelaunchEncoding() throws {
        let state = EntitlementState(access: .full, awaitingApproval: true, lastVerifiedAt: date)
        let decoded = try JSONDecoder().decode(EntitlementState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }
}

// Main-actor isolation is on each test method; Swift 6 rejects it on an XCTestCase subclass.
final class EntitlementModelTests: XCTestCase {
    @MainActor
    func testRelaunchReReadsEntitlement() async {
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()
        XCTAssertEqual(model.state.access, .full)
        XCTAssertEqual(model.displayPrice, "$4.99")
    }

    @MainActor
    func testOfflineLaunchUsesCachedVerifiedState() async {
        let provider = FakePurchaseProvider()
        provider.entitlementFails = true
        provider.price = nil
        let cached = EntitlementState(access: .full, awaitingApproval: false, lastVerifiedAt: Date())
        let model = EntitlementModel(provider: provider, cached: cached)
        await model.start()
        XCTAssertEqual(model.state.access, .full)
        XCTAssertNil(model.displayPrice)
    }

    @MainActor
    func testPendingThenApprovedAfterRestart() async {
        let provider = FakePurchaseProvider()
        provider.purchaseResult = .success(.pending)
        let first = EntitlementModel(provider: provider, cached: EntitlementState())
        await first.start()
        await first.buy()
        XCTAssertTrue(first.state.awaitingApproval)
        guard case .message = first.flow else { return XCTFail("Expected a waiting message") }

        // Restart: a new model from the persisted state.
        let relaunched = EntitlementModel(provider: provider, cached: first.state)
        await relaunched.start()
        XCTAssertTrue(relaunched.state.awaitingApproval)
        XCTAssertEqual(relaunched.state.access, .sample)

        provider.send(.active)
        await settle { relaunched.state.access == .full }
        XCTAssertEqual(relaunched.state.access, .full)
        XCTAssertFalse(relaunched.state.awaitingApproval)
    }

    @MainActor
    func testFailedPurchaseShowsMessageAndStaysLocked() async {
        let provider = FakePurchaseProvider()
        provider.purchaseResult = .failure(FakePurchaseProvider.Offline())
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.buy()
        XCTAssertEqual(model.state.access, .sample)
        guard case .message = model.flow else { return XCTFail("Expected an error message") }
    }

    @MainActor
    func testRestoreFindsEarlierPurchase() async {
        let provider = FakePurchaseProvider()
        provider.entitlementAfterRestore = .active
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.restore()
        XCTAssertEqual(provider.restoreCalls, 1)
        XCTAssertEqual(model.state.access, .full)
        XCTAssertEqual(model.flow, .idle)
    }

    @MainActor
    func testRestoreWithNothingToRestoreSaysSo() async {
        let provider = FakePurchaseProvider()
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.restore()
        XCTAssertEqual(model.state.access, .sample)
        guard case .message = model.flow else { return XCTFail("Expected a message") }
    }

    @MainActor
    func testRevocationArrivingWhileRunningLocks() async {
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()
        XCTAssertEqual(model.state.access, .full)

        provider.send(.revoked)
        await settle { model.state.access == .sample }
        XCTAssertEqual(model.state.access, .sample)
    }
}
