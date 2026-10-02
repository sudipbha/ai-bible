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

    /// Waits (bounded) until the cleared local environment has settled: no transactions and
    /// the real provider reporting no entitlement. Clearing is immediate on the session but the
    /// provider reads `Transaction.currentEntitlements`, so a purchase from the previous test
    /// could otherwise still be reported. Fails with the observed state if it never settles.
    @MainActor
    private func waitForCleanEnvironment(_ session: SKTestSession, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(session.allTransactions().isEmpty,
                      "\(session.allTransactions().count) local transaction(s) remain after clearing", file: file, line: line)
        var last: EntitlementSnapshot?
        let settled = await eventually {
            last = try? await provider.currentEntitlement()
            return last == EntitlementSnapshot.none
        }
        XCTAssertTrue(settled, "The provider still reports \(String(describing: last)) after clearing", file: file, line: line)
    }

    /// A model started in the settled clean environment, with the precondition every purchase
    /// test relies on checked explicitly: locked, price loaded and a purchase allowed. Without
    /// this, `buy()` returns silently when stale access is already full.
    @MainActor
    private func startedCleanModel(_ session: SKTestSession, file: StaticString = #filePath, line: UInt = #line) async -> EntitlementModel {
        await waitForCleanEnvironment(session, file: file, line: line)
        let model = EntitlementModel(provider: provider, cached: EntitlementState())
        await model.start()
        XCTAssertEqual(model.state.access, .sample, "Access before the purchase", file: file, line: line)
        XCTAssertTrue(model.canStartPurchase,
                      "A purchase can't start: price \(String(describing: model.displayPrice)), flow \(model.flow)",
                      file: file, line: line)
        return model
    }

    /// The local transaction for this app's product, waited for (bounded): delivery to the
    /// test session is asynchronous.
    @MainActor
    private func productTransaction(_ session: SKTestSession, file: StaticString = #filePath, line: UInt = #line) async throws -> SKTestTransaction {
        var found: SKTestTransaction?
        _ = await eventually {
            found = session.allTransactions().first { $0.productIdentifier == AppConfig.fullBookProductID }
            return found != nil
        }
        return try XCTUnwrap(found, "No local transaction for \(AppConfig.fullBookProductID); session has "
                             + "\(session.allTransactions().map(\.productIdentifier))", file: file, line: line)
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
        await waitForCleanEnvironment(session)
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
        let model = await startedCleanModel(session)
        await model.buy()
        XCTAssertEqual(model.state.access, .full)

        // Refund the transaction this purchase actually created.
        let transaction = try await productTransaction(session)
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
        let model = await startedCleanModel(session)

        await model.buy()
        XCTAssertTrue(model.state.awaitingApproval)
        XCTAssertEqual(model.state.access, .sample)

        let pending = try await productTransaction(session)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)

        let unlocked = await eventually { model.state.access == .full }
        XCTAssertTrue(unlocked, "Approval must arrive through Transaction.updates without another purchase")
        XCTAssertFalse(model.state.awaitingApproval)
    }

    @MainActor
    func testFailedTransactionStaysLockedWithMessage() async throws {
        let session = try makeSession()
        session.failTransactionsEnabled = true
        let model = await startedCleanModel(session)

        await model.buy()

        XCTAssertEqual(model.state.access, .sample)
        guard case .message = model.flow else { return XCTFail("Expected a failure message") }
        let entitlement = try await provider.currentEntitlement()
        XCTAssertEqual(entitlement, .none)
    }
}
