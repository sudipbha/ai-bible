import XCTest

/// The free Five-Question Filter through the rendered app: create, edit, persist across a
/// relaunch, delete one record, then Delete My Data. Every record here is created by the
/// test in its own temporary store.
final class FilterToolUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateEditPersistAndDeleteFilterChecks() throws {
        let store = "filter-journey"
        let app = XCUIApplication()
        app.launch(store: store, reset: true)

        app.openTab("Tools")
        app.element("tools.newFilter").waitToAppear().tap()
        app.type("UI test task", into: "filter.task")
        app.type("UI test tool", into: "filter.tool")
        app.element("filter.answer.fx.filter.q1").waitToAppear().tap()
        app.buttons["Yes"].firstMatch.waitToAppear().tap()
        // The chosen answer is shown on the question's picker row.
        app.element("filter.answer.fx.filter.q1").waitFor("value == 'Yes' OR label CONTAINS 'Yes'")
        // The summary follows all five question sections, below the first screen, so scroll
        // to it (bounded) and check the tally itself.
        app.scrollUntilHittable("filter.summary").waitFor("label BEGINSWITH 'Yes 1'")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let row = app.staticTexts["UI test tool · UI test task"]
        row.waitToAppear()

        // Persisted across a relaunch, answers included.
        app.relaunchKeepingData(store: store)
        app.openTab("Tools")
        row.waitToAppear().tap()
        XCTAssertEqual(app.element("filter.task").waitToAppear().value as? String, "UI test task")
        app.scrollUntilHittable("filter.summary").waitFor("label BEGINSWITH 'Yes 1'")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Swipe-to-delete removes only this record, and the deletion persists.
        row.waitToAppear().swipeLeft()
        app.buttons["Delete"].firstMatch.waitToAppear().tap()
        row.waitToDisappear()
        app.relaunchKeepingData(store: store)
        app.openTab("Tools")
        app.element("tools.newFilter").waitToAppear()
        XCTAssertFalse(row.exists)

        // Delete My Data clears a newly created record from this test store.
        app.element("tools.newFilter").tap()
        app.type("Second tool", into: "filter.tool")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let second = app.staticTexts["Second tool"].waitToAppear()
        app.openTab("Settings")
        // The Delete My Data row is below the first screen of the Settings list and isn't
        // created until scrolled to (run 36352200784), so scroll to it (bounded) first.
        app.scrollUntilHittable("settings.deleteData").tap()
        // The dialog's destructive action, labelled exactly "Delete My Data" (the Settings row reads
        // "Delete My Data…"). It must be the only such button, on screen and hittable, before the tap.
        let confirmations = app.buttons.matching(
            NSPredicate(format: "label == 'Delete My Data' AND identifier != 'settings.deleteData'"))
        let confirm = confirmations.firstMatch
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: confirm)
        if !confirm.waitForExistence(timeout: 10) || XCTWaiter.wait(for: [hittable], timeout: 10) != .completed
            || confirmations.count != 1 {
            logDeletion(app, "Delete My Data confirmation not shown as one hittable button")
            XCTFail("Delete My Data confirmation not shown as one hittable button")
        }
        confirm.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: confirm)
        if XCTWaiter.wait(for: [dismissed], timeout: 10) != .completed {
            logDeletion(app, "Delete My Data confirmation still shown after the tap")
            XCTFail("Delete My Data confirmation still shown after the tap")
        }
        // Before any relaunch: no storage notice or saving-paused warning, and the record is gone
        // from the live list.
        if Self.storageNotices(in: app).firstMatch.exists {
            logDeletion(app, "Storage notice after Delete My Data")
            XCTFail("Storage notice after Delete My Data")
        }
        app.openTab("Tools")
        app.element("tools.newFilter").waitToAppear()
        if second.exists {
            logDeletion(app, "Second tool still listed after Delete My Data, before relaunch")
            XCTFail("Second tool still listed after Delete My Data, before relaunch")
        }
        app.relaunchKeepingData(store: store)
        app.openTab("Tools")
        app.element("tools.newFilter").waitToAppear()
        if second.exists {
            logDeletion(app, "Second tool reappeared after relaunch (it was gone before relaunch)")
        }
        XCTAssertFalse(second.exists)
    }

    /// Settings texts that report a deletion or save problem: the deletion notices ("… Try Delete My
    /// Data again."), the save-failure notice, and the saving-paused warning.
    @MainActor
    private static func storageNotices(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                             "Try Delete My Data again", "Couldn't save your latest changes",
                                             "Saving is paused"))
    }

    /// Bounded diagnostics for the Delete My Data step: the screen summary, the buttons whose label
    /// mentions Delete, and any storage, save-failure or saving-paused notice. Test records only;
    /// no user data exists in this store.
    @MainActor
    private func logDeletion(_ app: XCUIApplication, _ reason: String) {
        app.logDiagnostics(reason, focus: ["settings.deleteData", "tools.newFilter"])
        var lines: [String] = []
        let deletes = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete'")).allElementsBoundByIndex
        lines.append("buttons labelled Delete: \(deletes.count)")
        for button in deletes.prefix(6) {
            lines.append("  '\(button.label.prefix(60))' id '\(button.identifier)' frame \(button.frame) hittable \(button.isHittable)")
        }
        let notices = Self.storageNotices(in: app).allElementsBoundByIndex
        lines.append("storage notices: \(notices.count)")
        for notice in notices.prefix(3) { lines.append("  '\(notice.label.prefix(200))'") }
        for line in lines { XCTContext.runActivity(named: "AIBIBLE-DIAG " + line) { _ in } }
    }
}
