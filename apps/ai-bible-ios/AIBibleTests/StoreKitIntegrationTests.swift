import XCTest
import StoreKitTest
@testable import AIBible

/// Real StoreKit 2 calls through the production `StoreKitPurchaseProvider`, run against
/// Xcode's local StoreKit testing environment (`SKTestSession` + StoreKit/Products.storekit,
/// bundled into this test target only).
///
/// This is StoreKit Testing in Xcode: local, synthetic and free. It is not the App Store
/// sandbox, not TestFlight, and not a real transaction. The product ID is the placeholder
/// from AppConfig; no registered App Store Connect product is involved.
final class StoreKitIntegrationTests: XCTestCase {
    private let provider = StoreKitPurchaseProvider(productID: AppConfig.fullBookProductID)

    @MainActor
    private func makeSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    /// Polls a StoreKit-driven condition; transaction delivery is asynchronous.
    @MainActor
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    @MainActor
    func testLocalProductLoadsALocalizedPrice() async throws {
        _ = try makeSession()
        let price = await provider.displayPrice()
        XCTAssertNotNil(price, "The synthetic product from Products.storekit should load locally")
        XCTAssertFalse(price?.isEmpty ?? true)
    }

    @MainActor
    func testPurchaseGrantsVerifiedEntitlementFoundAgainAfterReinstall() async throws {
        let session = try makeSession()
        let before = try await provider.currentEntitlement()
        XCTAssertEqual(before, .none)

        let outcome = try await provider.purchase()
        XCTAssertEqual(outcome, .verified)
        let after = try await provider.currentEntitlement()
        XCTAssertEqual(after, .active)
        XCTAssertEqual(session.allTransactions().count, 1)

        // A reinstall starts with no cached state; the launch check must find the purchase.
        let reinstalled = EntitlementModel(provider: provider, cached: EntitlementState())
        await reinstalled.start()
        XCTAssertEqual(reinstalled.state.access, .full)
    }

    @MainActor
    func testRefundLocksPaidContentAgain() async throws {
        let session = try makeSession()
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()
        await model.buy()
        XCTAssertEqual(model.state.access, .full)

        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)

        let locked = await eventually {
            await model.refresh()
            return model.state.access == .sample
        }
        XCTAssertTrue(locked, "A refunded purchase must lock paid content")
    }

    @MainActor
    func testAskToBuyIsPendingUntilApproved() async throws {
        let session = try makeSession()
        session.askToBuyEnabled = true
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()

        await model.buy()
        XCTAssertTrue(model.state.awaitingApproval)
        XCTAssertEqual(model.state.access, .sample)

        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)

        let unlocked = await eventually { model.state.access == .full }
        XCTAssertTrue(unlocked, "Approval must arrive through Transaction.updates without another purchase")
        XCTAssertFalse(model.state.awaitingApproval)
    }

    @MainActor
    func testFailedTransactionStaysLockedWithMessage() async throws {
        let session = try makeSession()
        session.failTransactionsEnabled = true
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()

        await model.buy()

        XCTAssertEqual(model.state.access, .sample)
        guard case .message = model.flow else { return XCTFail("Expected a failure message") }
        let entitlement = try await provider.currentEntitlement()
        XCTAssertEqual(entitlement, .none)
    }
}
