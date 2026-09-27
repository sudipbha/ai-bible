import XCTest
import StoreKitTest

/// The paid path through the rendered app, using Xcode's local StoreKit testing environment
/// (`SKTestSession` + the synthetic StoreKit/Products.storekit). This is local StoreKit
/// Testing in Xcode: no App Store sandbox, no account and no real transaction.
///
/// It needs the app process to use the same local StoreKit environment that the test's
/// `SKTestSession` controls. If the price never appears, that setup isn't in effect on the
/// runner, and the assertion message says so. This must not be read as an app defect
/// without checking that first.
final class PurchaseJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs even when the test failed part-way, so a simulated purchase made before the
    /// failure can't leave later tests unlocked. Synchronous and on no particular actor:
    /// `SKTestSession`'s initializer, `clearTransactions()` and `allTransactions()` are plain
    /// synchronous methods on a class with no actor annotation, so no actor hop or UI work is
    /// needed. The begin and end lines are receipts showing that clean-up ran and what was left;
    /// they use `NSLog` (thread-safe, no actor), whose runner output is expected in the xcodebuild log.
    override func tearDownWithError() throws {
        NSLog("AIBIBLE-DIAG teardown: clearing local StoreKit transactions")
        let remaining = try LocalStoreKit.clearAll()
        NSLog("AIBIBLE-DIAG teardown: done, %ld local transaction(s) remain", remaining)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeSession() throws -> SKTestSession {
        try LocalStoreKit.cleanSession()
    }

    @MainActor
    private func buyFromOpenSheet(_ app: XCUIApplication) {
        let buy = app.element("unlock.buy").waitToAppear()
        buy.waitFor("isEnabled == true", 20)   // enabled only once the local product's price has loaded
        buy.tap()
    }

    @MainActor
    func testUnlockEditPersistThenRevocationLocksTheOpenChapter() throws {
        let session = try makeSession()
        let store = "paid-journey"
        let app = XCUIApplication()
        app.launch(store: store, reset: true)

        // Paid tools are locked: the New button opens the unlock sheet. Buy there.
        app.openTab("Tools")
        app.element("tools.new.rollout").waitToAppear().tap()
        buyFromOpenSheet(app)
        app.element("unlock.buy").waitToDisappear(20)   // the sheet closes once unlocked
        XCTAssertEqual(session.allTransactions().count, 1)

        // Rollout tracker: name it and tick the first step.
        app.element("tools.new.rollout").tap()
        app.type("UI test rollout", into: "rollout.toolName")
        app.element("rollout.step.fx.rollout.s1").waitToAppear().tapSwitch()
        app.element("rollout.progress").waitFor("label BEGINSWITH 'Checklist: 1 of 6'")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Cost worksheet with the fictional vector: 20 × 12 = 240, 20 × 8 + 90 = 250, later 160.
        app.element("tools.new.cost").waitToAppear().tap()
        app.type("UI test sheet", into: "cost.title")
        app.replaceNumber("20", in: "cost.tasks")
        app.replaceNumber("12", in: "cost.manual")
        app.replaceNumber("8", in: "cost.wholeJob")
        app.replaceNumber("90", in: "cost.setup")
        // End editing through the normal back navigation (the title field may have been
        // scrolled off screen by now), then reopen the saved worksheet and check its results.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["UI test sheet"].waitToAppear().tap()
        app.expectText(containing: "Manual, 240 min (4 h)")
        app.expectText(containing: "First trial period, 250 min (4 h 10 min)")
        app.expectText(containing: "Later periods, 160 min (2 h 40 min)")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Both records persist across a relaunch, and the purchase is found again.
        app.relaunchKeepingData(store: store)
        app.openTab("Tools")
        app.staticTexts["UI test sheet"].waitToAppear()
        app.staticTexts["UI test rollout"].waitToAppear().tap()
        app.element("rollout.progress").waitFor("label BEGINSWITH 'Checklist: 1 of 6'")
        XCTAssertFalse(app.element("tools.readOnly").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Open a paid chapter, then revoke the purchase while it is on screen.
        app.openTab("Read")
        app.backToContents()
        app.element("contents.chapter.fx.ch02").tap()
        app.element("block.fx.ch02.p1").waitToAppear()
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        app.buttons["See what's included"].waitToAppear(20)
        app.element("block.fx.ch02.p1").waitToDisappear()

        // Saved work stays readable after revocation; editing is locked.
        app.openTab("Tools")
        app.staticTexts["UI test rollout"].waitToAppear().tap()
        app.element("tools.readOnly").waitToAppear()
        XCTAssertEqual(app.element("rollout.toolName").value as? String, "UI test rollout")
    }

    @MainActor
    func testFailedPurchaseShowsMessageAndStaysLocked() throws {
        let session = try makeSession()
        session.failTransactionsEnabled = true
        let app = XCUIApplication()
        app.launch(store: "paid-failure", reset: true)

        app.backToContents()
        app.element("contents.chapter.fx.ch02").tap()
        buyFromOpenSheet(app)
        app.element("unlock.message").waitToAppear().waitFor("label CONTAINS 'be completed'")
        app.element("unlock.buy").waitToAppear()
        app.element("unlock.close").tap()

        // Still locked: the paid chapter opens the unlock sheet again.
        app.element("contents.chapter.fx.ch02").tap()
        app.element("unlock.buy").waitToAppear()
    }
}
