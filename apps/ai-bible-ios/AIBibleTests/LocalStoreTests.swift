import XCTest
@testable import AIBible

final class LocalStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = TestBooks.temporaryStore()
        var data = UserData()
        var filter = FilterRecord()
        filter.toolName = "Fixture Tool A"
        filter.answers["q1"] = .yes
        data.filters = [filter]
        data.entitlement.access = .full
        try store.save(data)

        guard case .loaded(let loaded) = store.load() else { return XCTFail("Expected saved data") }
        XCTAssertEqual(loaded.filters.first?.toolName, "Fixture Tool A")
        XCTAssertEqual(loaded.filters.first?.answers["q1"], .yes)
        XCTAssertEqual(loaded.entitlement.access, .full)
    }

    func testMissingFileIsFresh() {
        XCTAssertEqual(TestBooks.temporaryStore().load(), .fresh)
    }

    func testUnreadableFileIsKeptAsideNotDeleted() throws {
        let store = TestBooks.temporaryStore()
        try Data("not json".utf8).write(to: store.url)

        guard case .recovered(let backup) = store.load() else { return XCTFail("Expected recovery") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testOlderFileWithMissingFieldsStillLoads() throws {
        let store = TestBooks.temporaryStore()
        try Data(#"{"schemaVersion":1,"bookmarks":[]}"#.utf8).write(to: store.url)
        guard case .loaded(let loaded) = store.load() else { return XCTFail("Expected tolerant decode") }
        XCTAssertTrue(loaded.filters.isEmpty)
        XCTAssertEqual(loaded.entitlement, EntitlementState())
    }
}

final class AppModelTests: XCTestCase {
    @MainActor
    func testRevocationKeepsSavedWorkReadableAndExportable() async {
        let store = TestBooks.temporaryStore()
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = AppModel(book: TestBooks.small(), store: store, provider: provider)
        await model.entitlements.start()
        XCTAssertEqual(model.access, .full)

        guard let rolloutID = model.newRollout(), let costID = model.newCostWorksheet() else {
            return XCTFail("Paid tools should be editable while unlocked")
        }
        var rollout = model.rollouts.first { $0.id == rolloutID }!
        rollout.toolName = "Fixture Tool A"
        rollout.done = ["s1"]
        model.update(rollout)
        var sheet = model.costs.first { $0.id == costID }!
        sheet.tasks = 20
        sheet.manualMinutesPerTask = 12
        model.update(sheet)
        model.toggleBookmark(blockID: "c2.p1")

        provider.send(.revoked)
        await settle { model.access == .sample }

        XCTAssertEqual(model.access, .sample)
        XCTAssertFalse(model.canRead(chapterID: "c2"))
        XCTAssertTrue(model.canRead(chapterID: "c1"))
        XCTAssertFalse(model.canEdit(.rollout))
        XCTAssertTrue(model.canEdit(.filter))
        XCTAssertNil(model.newRollout())

        // Saved work is untouched and still exportable.
        XCTAssertEqual(model.rollouts.count, 1)
        XCTAssertEqual(model.rollouts.first?.toolName, "Fixture Tool A")
        XCTAssertEqual(model.costs.first?.manualMinutes, 240)
        XCTAssertEqual(model.bookmarks.count, 1)
        XCTAssertTrue(ToolExport.text(model.rollouts[0], items: model.book.tools.rolloutItems).contains("[x] Step 1"))

        // Edits are refused while locked, and nothing is lost on relaunch.
        var blocked = model.rollouts[0]
        blocked.toolName = "Changed"
        model.update(blocked)
        XCTAssertEqual(model.rollouts.first?.toolName, "Fixture Tool A")

        model.flush()
        let relaunched = AppModel(book: TestBooks.small(), store: store, provider: provider)
        XCTAssertEqual(relaunched.rollouts.first?.toolName, "Fixture Tool A")
        XCTAssertEqual(relaunched.costs.count, 1)
        XCTAssertEqual(relaunched.access, .sample)
    }

    @MainActor
    func testStartPositionFallsBackToFreeChapterWhenLocked() {
        let store = TestBooks.temporaryStore()
        var data = UserData()
        data.lastPosition = ReadingAnchor(blockID: "c2.p2", in: TestBooks.small())
        try? store.save(data)

        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        XCTAssertEqual(model.startPosition(), ReaderPosition(chapterID: "c1", blockID: "c1.h1"))
    }

    @MainActor
    func testDeleteAllUserDataKeepsPurchase() async {
        let store = TestBooks.temporaryStore()
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = AppModel(book: TestBooks.small(), store: store, provider: provider)
        await model.entitlements.start()
        model.newFilter()
        model.toggleBookmark(blockID: "c1.p1")

        model.deleteAllUserData()

        XCTAssertTrue(model.filters.isEmpty)
        XCTAssertTrue(model.bookmarks.isEmpty)
        XCTAssertEqual(model.access, .full)
    }
}
