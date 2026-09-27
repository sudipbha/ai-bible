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
        await model.refreshPrice()
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

    // MARK: Finding 3 — price recovers after an offline launch, without relaunch or auto-purchase

    @MainActor
    func testPriceRecoversWithoutRelaunchAndNeverAutoPurchases() async {
        let provider = FakePurchaseProvider()
        provider.price = nil                              // offline at launch
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()
        XCTAssertEqual(model.priceState, .unavailable)
        XCTAssertFalse(model.canStartPurchase)

        await model.buy()                                 // a disabled Buy must do nothing
        XCTAssertEqual(provider.purchaseCalls, 0)

        await model.refreshPrice()                        // still offline: stays unavailable
        XCTAssertEqual(model.priceState, .unavailable)

        provider.price = "£4.99"                          // back online (any localized string)
        await model.refreshPrice()                        // sheet appears / Try Again / foreground
        XCTAssertEqual(model.priceState, .available("£4.99"))
        XCTAssertEqual(model.displayPrice, "£4.99")
        XCTAssertTrue(model.canStartPurchase)
        XCTAssertEqual(provider.purchaseCalls, 0, "Loading the price must never start a purchase")

        await model.buy()                                 // only an explicit Buy purchases
        XCTAssertEqual(provider.purchaseCalls, 1)
        XCTAssertEqual(model.state.access, .full)
    }

    @MainActor
    func testRefreshPriceIsSkippedOnceAvailable() async {
        let provider = FakePurchaseProvider()
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.refreshPrice()
        await model.refreshPrice()
        XCTAssertEqual(provider.priceCalls, 1)
    }

    @MainActor
    func testRestoreAlsoRetriesMissingPrice() async {
        let provider = FakePurchaseProvider()
        provider.price = nil
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()
        provider.price = "$4.99"
        await model.restore()
        XCTAssertEqual(model.displayPrice, "$4.99")
        XCTAssertEqual(provider.purchaseCalls, 0)
    }

    @MainActor
    func testBuyIsIgnoredWhenAlreadyUnlocked() async {
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()
        await model.buy()
        XCTAssertEqual(provider.purchaseCalls, 0)
    }

    @MainActor
    func testUpdatesListenerStopsWhenModelIsReleased() async {
        let provider = FakePurchaseProvider()
        var model: EntitlementModel? = EntitlementModel(provider: provider, cached: EntitlementState())
        await model?.start()
        weak var released = model
        model = nil
        XCTAssertNil(released, "Nothing else should keep the model alive")

        // Without cancellation the listener would keep iterating the stream forever.
        let deadline = ContinuousClock.now + .seconds(5)
        while !provider.updatesTerminated && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(provider.updatesTerminated, "The transaction-updates listener must stop when its model is released")
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
