import XCTest
import StoreKitTest

/// Free reading journey through the rendered app: launch, read, gated navigation, search,
/// bookmark, and resume after a relaunch. Synthetic fixture content only.
///
/// Each test starts with no local StoreKit transactions, so paid chapters are locked because
/// nothing was bought, not because of whichever test ran before.
final class ReaderJourneyUITests: XCTestCase {
    /// Identifiers whose every match is logged if a reader step fails.
    private let readerDiagnostics = ["block.fx.ch01.p4", "block.fx.ch01.p1", "reader.chapterTitle",
                                     "search.result.fx.ch01.p4"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReadSearchBookmarkAndResumeAfterRelaunch() throws {
        let store = "reader-journey"
        let storeKit = try LocalStoreKit.cleanSession()
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
        withExtendedLifetime(storeKit) {}
    }

    /// Opening a passage from Search, with no scrolling at all, must still become the place
    /// the app reopens at. Synthetic chapter 1 has filler blocks (fx.ch01.f1–f12) so that
    /// fx.ch01.p4 sits well below the first screen and the chapter start is off screen when
    /// p4 is shown. No bookmark is made, so only the saved reading position can bring p4 back.
    @MainActor
    func testPassageOpenedWithoutScrollingIsWhereTheAppReopens() throws {
        let store = "reader-resume-no-scroll"
        let storeKit = try LocalStoreKit.cleanSession()
        let app = XCUIApplication()
        app.launch(store: store, reset: true)

        // Fresh store: the reader opens at the chapter start and p4 is not on screen,
        // which proves the fixture is tall enough on this device for the check below.
        app.expectHittable("block.fx.ch01.p1", diagnose: readerDiagnostics)
        app.expectNotHittable("block.fx.ch01.p4", "Fixture too short: p4 is already on screen at launch",
                              diagnose: readerDiagnostics)

        // Open p4 from Search and don't scroll.
        app.openTab("Search")
        let field = app.searchFields.firstMatch.waitToAppear()
        field.tap()
        field.typeText("resume")
        app.element("search.result.fx.ch01.p4").waitToAppear().tap()
        // One bounded snapshot of the state straight after the Search navigation (navigation
        // bars, keyboard, every p4/p1 match with frame and hittability), whether or not the
        // next check passes. Run 36346633175 failed at the next line with no such detail.
        app.logDiagnostics("after opening p4 from Search", focus: readerDiagnostics)
        app.expectHittable("block.fx.ch01.p4", diagnose: readerDiagnostics)

        // Relaunch without a reset. The Read tab reopens the reader at the saved position.
        app.relaunchKeepingData(store: store)
        app.expectHittable("block.fx.ch01.p4", diagnose: readerDiagnostics)
        app.expectNotHittable("block.fx.ch01.p1", "Reopened at the chapter start, not at the opened passage",
                              diagnose: readerDiagnostics)
        withExtendedLifetime(storeKit) {}
    }

    /// A passage near the end of a chapter can't be scrolled to the top of the screen (the
    /// scroll view stops at the bottom), so the reader never reports it as the top block. Open
    /// such a passage (fx.ch01.f12, the last block) from Search, scroll back by hand to an
    /// earlier, distinct passage (fx.ch01.f2), and relaunch: the reader must reopen at the new
    /// place, not at the originally requested passage. Synthetic fixture content only.
    @MainActor
    func testManualScrollAfterOpeningNearBottomPassageIsWhereTheAppReopens() throws {
        let store = "reader-bottom-target"
        let storeKit = try LocalStoreKit.cleanSession()
        let app = XCUIApplication()
        app.launch(store: store, reset: true)
        let diagnose = ["block.fx.ch01.f12", "block.fx.ch01.f2", "block.fx.ch01.p4", "reader.chapterTitle"]

        // "final" occurs only in fx.ch01.f12.
        app.openTab("Search")
        let field = app.searchFields.firstMatch.waitToAppear()
        field.tap()
        field.typeText("final")
        app.element("search.result.fx.ch01.f12").waitToAppear().tap()
        app.expectHittable("block.fx.ch01.f12", diagnose: diagnose)

        // Scroll back by hand (bounded, slow drags) until the earlier passage is on screen and
        // the requested one is not.
        let earlier = app.element("block.fx.ch01.f2")
        let requested = app.element("block.fx.ch01.f12")
        var drags = 0
        while !(earlier.exists && earlier.isHittable && !(requested.exists && requested.isHittable)) && drags < 14 {
            app.dragContent(by: -200)
            drags += 1
        }
        app.expectHittable("block.fx.ch01.f2", diagnose: diagnose)
        app.expectNotHittable("block.fx.ch01.f12", "Still showing the requested passage after scrolling back", diagnose: diagnose)
        app.expectNotHittable("block.fx.ch01.p4", "Scrolled back too little to be a distinct place", diagnose: diagnose)

        // Relaunch without a reset: the new place is restored, not the original request.
        app.relaunchKeepingData(store: store)
        app.expectHittable("block.fx.ch01.f2", diagnose: diagnose)
        app.expectNotHittable("block.fx.ch01.f12", "Reopened at the originally requested passage, not the new place",
                              diagnose: diagnose)
        app.expectNotHittable("block.fx.ch01.p4", "Reopened near the requested passage, not the new place", diagnose: diagnose)
        withExtendedLifetime(storeKit) {}
    }
}
