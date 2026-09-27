import XCTest

/// Free reading journey through the rendered app: launch, read, gated navigation, search,
/// bookmark, and resume after a relaunch. Synthetic fixture content only.
final class ReaderJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReadSearchBookmarkAndResumeAfterRelaunch() throws {
        let store = "reader-journey"
        let app = XCUIApplication()
        app.launch(store: store, reset: true)

        // Launch opens straight into the free chapter, with no onboarding.
        app.element("reader.chapterTitle").waitToAppear()
        app.element("block.fx.ch01.p1").waitToAppear()

        // A paid chapter from Contents opens the unlock sheet, not the chapter.
        app.backToContents()
        app.element("contents.chapter.fx.ch02").tap()
        app.element("unlock.buy").waitToAppear()
        app.element("unlock.close").tap()
        app.element("unlock.buy").waitToDisappear()

        // Search finds free text ignoring accents, and counts paid matches without showing them.
        app.openTab("Search")
        let field = app.searchFields.firstMatch.waitToAppear()
        field.tap()
        field.typeText("Tool")
        app.element("search.lockedMatches").waitToAppear()
        XCTAssertFalse(app.element("search.result.fx.ch02.t1").exists, "Paid text must not be listed")
        field.buttons.firstMatch.tap()   // clear
        field.typeText("resume")
        app.element("search.result.fx.ch01.p4").waitToAppear().tap()

        // Bookmark the opened passage.
        app.element("block.fx.ch01.p4").waitToAppear()
        let bookmark = app.element("reader.bookmark").waitToAppear()
        bookmark.tap()
        bookmark.waitFor("label == 'Remove bookmark'")

        // Relaunch: the bookmark and a resume point were saved without any scrolling.
        app.relaunchKeepingData(store: store)
        app.element("block.fx.ch01.p4").waitToAppear()
        app.backToContents()
        app.element("contents.continue").waitToAppear()
        app.element("contents.bookmarks").tap()
        app.element("bookmark.fx.ch01.p4").waitToAppear().tap()
        app.element("block.fx.ch01.p4").waitToAppear()
    }

    /// Opening a passage from Search, with no scrolling at all, must still become the place
    /// the app reopens at. Synthetic chapter 1 has filler blocks (fx.ch01.f1–f12) so that
    /// fx.ch01.p4 sits well below the first screen and the chapter start is off screen when
    /// p4 is shown. No bookmark is made, so only the saved reading position can bring p4 back.
    @MainActor
    func testPassageOpenedWithoutScrollingIsWhereTheAppReopens() throws {
        let store = "reader-resume-no-scroll"
        let app = XCUIApplication()
        app.launch(store: store, reset: true)

        // Fresh store: the reader opens at the chapter start and p4 is not on screen,
        // which proves the fixture is tall enough on this device for the check below.
        let start = app.element("block.fx.ch01.p1")
        let passage = app.element("block.fx.ch01.p4")
        start.waitToAppear().waitFor("isHittable == true")
        XCTAssertFalse(passage.exists && passage.isHittable, "Fixture too short: p4 is already on screen at launch")

        // Open p4 from Search and don't scroll.
        app.openTab("Search")
        let field = app.searchFields.firstMatch.waitToAppear()
        field.tap()
        field.typeText("resume")
        app.element("search.result.fx.ch01.p4").waitToAppear().tap()
        passage.waitToAppear().waitFor("isHittable == true")

        // Relaunch without a reset. The Read tab reopens the reader at the saved position.
        app.relaunchKeepingData(store: store)
        passage.waitToAppear().waitFor("isHittable == true")
        XCTAssertFalse(start.exists && start.isHittable, "Reopened at the chapter start, not at the opened passage")
    }
}
