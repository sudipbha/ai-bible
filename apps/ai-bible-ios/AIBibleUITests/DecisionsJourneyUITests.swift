import XCTest

/// AI tool decisions through the rendered app: a fresh install still opens in the reader;
/// the Decisions tab onboards the first evaluation, links its Filter step, lists it, and the
/// app opens on Decisions after a relaunch. Synthetic fixture content and test records only.
final class DecisionsJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstEvaluationIsGuidedListedAndOpensTheAppNextTime() throws {
        let store = "decisions-journey"
        let app = XCUIApplication()
        app.launch(store: store, reset: true)

        // No decisions yet: the app opens in the reader, as before.
        app.element("reader.chapterTitle").waitToAppear()

        app.openTab("Decisions")
        let start = app.element("decisions.start").waitToAppear()
        app.showcase("40 Decisions, first run")
        start.tap()

        app.type("UI test AI tool\n", into: "evaluation.tool")
        app.type("UI test task\n", into: "evaluation.task")
        XCTAssertEqual(app.element("evaluation.tool").value as? String, "UI test AI tool")
        app.element("evaluation.step.filter").waitToAppear()
        app.showcase("41 Evaluating one tool")

        // Step 1 opens this tool's own Filter check, already named.
        app.scrollUntilHittable("evaluation.step.filter").tap()
        XCTAssertEqual(app.element("filter.tool").waitToAppear().value as? String, "UI test AI tool")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.element("evaluation.step.filter").waitToAppear()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let row = app.staticTexts["UI test AI tool"]
        row.waitToAppear()
        app.element("decisions.new").waitToAppear()
        app.showcase("42 My AI tool decisions")

        // With a decision saved, the app opens on Decisions.
        app.relaunchKeepingData(store: store)
        app.element("decisions.list").waitToAppear()
        row.waitToAppear()
    }
}
