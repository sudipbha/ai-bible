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
        app.element("filter.summary").waitFor("label BEGINSWITH 'Yes 1'")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let row = app.staticTexts["UI test tool · UI test task"]
        row.waitToAppear()

        // Persisted across a relaunch, answers included.
        app.relaunchKeepingData(store: store)
        app.openTab("Tools")
        row.waitToAppear().tap()
        XCTAssertEqual(app.element("filter.task").waitToAppear().value as? String, "UI test task")
        app.element("filter.summary").waitFor("label BEGINSWITH 'Yes 1'")
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
        app.element("settings.deleteData").waitToAppear().tap()
        app.buttons["Delete My Data"].firstMatch.waitToAppear().tap()
        app.relaunchKeepingData(store: store)
        app.openTab("Tools")
        app.element("tools.newFilter").waitToAppear()
        XCTAssertFalse(second.exists)
    }
}
