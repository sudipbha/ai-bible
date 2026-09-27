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

    func testUndecodableFileIsQuarantinedWithItsBytes() throws {
        let store = TestBooks.temporaryStore()
        let original = Data("not json".utf8)
        try original.write(to: store.url)

        guard case .quarantined(let backup) = store.load() else { return XCTFail("Expected quarantine") }
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertTrue(backup.lastPathComponent.hasPrefix(FileStore.quarantinePrefix))
    }

    func testRepeatedQuarantinesNeverCollide() throws {
        let store = TestBooks.temporaryStore()
        var backups: [URL] = []
        for index in 0..<3 {
            try Data("broken \(index)".utf8).write(to: store.url)
            guard case .quarantined(let backup) = store.load() else { return XCTFail("Expected quarantine") }
            backups.append(backup)
        }
        XCTAssertEqual(Set(backups).count, 3)
        for (index, backup) in backups.enumerated() {
            XCTAssertEqual(try Data(contentsOf: backup), Data("broken \(index)".utf8))
        }
    }

    func testFailedQuarantineLeavesOriginalAndReportsBlocked() throws {
        var store = TestBooks.temporaryStore()
        store.moveItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        try Data("not json".utf8).write(to: store.url)

        XCTAssertEqual(store.load(), .blocked(.couldNotPreserve))
        XCTAssertEqual(try Data(contentsOf: store.url), Data("not json".utf8))
    }

    func testReadFailureIsBlockedAndUntouched() throws {
        var store = TestBooks.temporaryStore()
        store.readData = { _ in throw CocoaError(.fileReadNoPermission) }
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: store.url)

        XCTAssertEqual(store.load(), .blocked(.unreadable))
        XCTAssertEqual(try Data(contentsOf: store.url), Data(#"{"schemaVersion":1}"#.utf8))
    }

    func testNewerVersionFileIsBlockedNotQuarantined() throws {
        let store = TestBooks.temporaryStore()
        let future = Data(#"{"schemaVersion":99,"somethingNew":[1,2,3]}"#.utf8)
        try future.write(to: store.url)

        XCTAssertEqual(store.load(), .blocked(.newerVersion(99)))
        XCTAssertEqual(try Data(contentsOf: store.url), future)
        XCTAssertEqual(try store.userDataFiles(), [store.url])
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

    // MARK: Finding 1 — original data is never overwritten when it can't be preserved

    @MainActor
    func testUnpreservableFileSurvivesStartupEditsAndFlush() async throws {
        var store = TestBooks.temporaryStore()
        store.moveItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let original = Data("reader notes in an unreadable file".utf8)
        try original.write(to: store.url)

        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        XCTAssertTrue(model.savingPaused)
        XCTAssertNotNil(model.storageNotice)

        model.newFilter()
        model.toggleBookmark(blockID: "c1.p1")
        model.updatePosition(blockID: "c1.p2")
        try await Task.sleep(for: .milliseconds(600))   // past the scheduled-save delay
        model.flush()

        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertEqual(try store.userDataFiles(), [store.url])
    }

    @MainActor
    func testNewerVersionFileIsNotOverwritten() async throws {
        let store = TestBooks.temporaryStore()
        let future = Data(#"{"schemaVersion":2,"filters":[]}"#.utf8)
        try future.write(to: store.url)

        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        XCTAssertTrue(model.savingPaused)
        model.newFilter()
        model.flush()
        XCTAssertEqual(try Data(contentsOf: store.url), future)
    }

    @MainActor
    func testSuccessfulQuarantineStartsFreshAndKeepsBackup() throws {
        let store = TestBooks.temporaryStore()
        let original = Data("not json".utf8)
        try original.write(to: store.url)

        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        XCTAssertFalse(model.savingPaused)
        XCTAssertTrue(model.storageNotice?.contains(FileStore.quarantinePrefix) ?? false)

        model.newFilter()
        model.flush()

        guard case .loaded(let saved) = store.load() else { return XCTFail("Expected new saved data") }
        XCTAssertEqual(saved.filters.count, 1)
        let backups = try store.userDataFiles().filter { $0 != store.url }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
    }

    @MainActor
    func testDeleteAfterBlockedStartRemovesOriginalAndResumesSaving() throws {
        var store = TestBooks.temporaryStore()
        store.moveItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        try Data("not json".utf8).write(to: store.url)
        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        XCTAssertTrue(model.savingPaused)

        XCTAssertTrue(model.deleteAllUserData())

        XCTAssertFalse(model.savingPaused)
        guard case .loaded(let saved) = store.load() else { return XCTFail("Expected a fresh saved file") }
        XCTAssertTrue(saved.filters.isEmpty)
    }

    // MARK: Finding 5 — Delete My Data covers recovery copies, nothing else, and not the purchase

    @MainActor
    func testDeleteRemovesMainAndRecoveryCopiesButNotSiblingsOrPurchase() async throws {
        let store = TestBooks.temporaryStore()
        let directory = store.url.deletingLastPathComponent()
        var data = UserData()
        var filter = FilterRecord()
        filter.toolName = "Fixture Tool A"
        data.filters = [filter]
        try store.save(data)
        let quarantine = directory.appendingPathComponent("\(FileStore.quarantinePrefix)1700000000-OLD.json")
        try Data(#"{"filters":"old reader notes"}"#.utf8).write(to: quarantine)
        let sibling = directory.appendingPathComponent("unrelated-notes.txt")
        try Data("not ours".utf8).write(to: sibling)

        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = AppModel(book: TestBooks.small(), store: store, provider: provider)
        await model.entitlements.start()
        XCTAssertEqual(model.filters.count, 1)

        XCTAssertTrue(model.deleteAllUserData())

        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("not ours".utf8))
        XCTAssertTrue(model.filters.isEmpty)
        XCTAssertTrue(model.bookmarks.isEmpty)
        XCTAssertNil(model.storageNotice)
        XCTAssertEqual(model.access, .full)

        // The rewritten main file holds no records but keeps the cached purchase state.
        guard case .loaded(let saved) = store.load() else { return XCTFail("Expected a saved file") }
        XCTAssertTrue(saved.filters.isEmpty)
        XCTAssertEqual(saved.entitlement.access, .full)
        XCTAssertEqual(try store.userDataFiles(), [store.url])
    }

    // A directory that can't be listed must never be reported as "everything deleted",
    // and must never let the app overwrite saved bytes it couldn't account for.

    @MainActor
    func testListingFailureDuringDeleteKeepsAllBytesAndReportsFailure() async throws {
        var store = TestBooks.temporaryStore()
        var data = UserData()
        var filter = FilterRecord()
        filter.toolName = "Fixture Tool A"
        data.filters = [filter]
        try store.save(data)
        let primaryBytes = try Data(contentsOf: store.url)
        let quarantine = store.url.deletingLastPathComponent()
            .appendingPathComponent("\(FileStore.quarantinePrefix)1700000000-OLD.json")
        let quarantineBytes = Data(#"{"filters":"old reader notes"}"#.utf8)
        try quarantineBytes.write(to: quarantine)
        store.listDirectory = { _ in throw CocoaError(.fileReadNoPermission) }

        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        XCTAssertFalse(model.savingPaused, "Loading doesn't list the directory, so the start is normal")
        XCTAssertEqual(model.filters.count, 1)

        XCTAssertFalse(model.deleteAllUserData())
        XCTAssertTrue(model.savingPaused)
        XCTAssertTrue(model.storageNotice?.contains("may not have been deleted") ?? false)

        // Later edits, the scheduled save and a flush must not touch either file.
        model.newFilter()
        model.updatePosition(blockID: "c1.p2")
        try await Task.sleep(for: .milliseconds(600))
        model.flush()
        XCTAssertEqual(try Data(contentsOf: store.url), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: quarantine), quarantineBytes)
    }

    @MainActor
    func testListingFailureKeepsBlockedOriginalProtected() throws {
        var store = TestBooks.temporaryStore()
        store.moveItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        store.listDirectory = { _ in throw CocoaError(.fileReadNoPermission) }
        let original = Data("not json".utf8)
        try original.write(to: store.url)

        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())
        XCTAssertTrue(model.savingPaused)

        XCTAssertFalse(model.deleteAllUserData())
        XCTAssertTrue(model.savingPaused)
        model.flush()
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }

    @MainActor
    func testDeleteSucceedsOnRetryOnceListingWorks() throws {
        let store = TestBooks.temporaryStore()
        var failing = store
        failing.listDirectory = { _ in throw CocoaError(.fileReadNoPermission) }
        try store.save(UserData())
        let quarantine = store.url.deletingLastPathComponent()
            .appendingPathComponent("\(FileStore.quarantinePrefix)1700000000-OLD.json")
        try Data("old".utf8).write(to: quarantine)

        XCTAssertThrowsError(try failing.deleteAllUserDataFiles())
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path), "Nothing is removed when listing fails")

        XCTAssertEqual(try store.deleteAllUserDataFiles(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    @MainActor
    func testDeleteFailureIsReportedTruthfully() throws {
        var store = TestBooks.temporaryStore()
        let quarantine = store.url.deletingLastPathComponent()
            .appendingPathComponent("\(FileStore.quarantinePrefix)1700000000-OLD.json")
        try Data("old".utf8).write(to: quarantine)
        store.removeItem = { _ in throw CocoaError(.fileWriteNoPermission) }
        let model = AppModel(book: TestBooks.small(), store: store, provider: FakePurchaseProvider())

        XCTAssertFalse(model.deleteAllUserData())
        XCTAssertTrue(model.storageNotice?.contains(quarantine.lastPathComponent) ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }
}
