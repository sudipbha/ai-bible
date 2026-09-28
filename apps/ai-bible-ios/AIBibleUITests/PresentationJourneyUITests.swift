import XCTest
import StoreKitTest

/// Cover, title page and source contents on a compact iPhone at a large accessibility text
/// size. Uses the synthetic presentation fixture, selected through the Debug-only launch hook;
/// the default fixture (and every other UI test) is unchanged.
final class PresentationJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCoverTitleAndSourceContentsNavigation() throws {
        let storeKit = try LocalStoreKit.cleanSession()
        let app = XCUIApplication()
        app.launchArguments = TestStore.arguments("presentation-journey", reset: true)
            + ["-AIBibleUITestBook", "presentation.fixture",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        let diagnose = ["contents.edition", "edition.cover", "edition.titlePage.0", "contents.entry.1",
                        "contents.entry.5", "contents.entry.6", "block.ch01.h0002"]

        // The compact edition entry opens the full cover, described by its alt text, then the title page.
        app.backToContents()
        app.scrollUntilHittable("contents.edition").tap()
        app.expectHittable("edition.cover", diagnose: diagnose)
        XCTAssertEqual(app.element("edition.cover").label, "Zebrafog cover art")
        XCTAssertTrue(app.element("edition.titlePage.0").waitForExistence(timeout: 10))
        app.backToContents()

        // The title-page entry opens the edition view at the title page.
        app.scrollUntilHittable("contents.entry.1").tap()
        app.expectHittable("edition.titlePage.0", diagnose: diagnose)
        XCTAssertEqual(app.element("edition.titlePage.0").label, "Zebrafog Field Notes")
        app.backToContents()

        // A nested heading entry opens its free chapter at that heading.
        app.scrollUntilHittable("contents.entry.5").tap()
        app.expectHittable("block.ch01.h0002", diagnose: diagnose)
        app.backToContents()

        // An entry in a paid chapter opens the unlock sheet, not the chapter.
        app.scrollUntilHittable("contents.entry.6").tap()
        app.element("unlock.buy").waitToAppear()
        app.element("unlock.close").tap()
        app.element("unlock.buy").waitToDisappear()
        XCTAssertTrue(storeKit.allTransactions().isEmpty, "nothing was bought")
    }
}
