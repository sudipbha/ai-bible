import XCTest
@testable import AIBible

/// Finding 2. `ReaderView` renders only what `AppModel.readerGate(for:)` returns, and it
/// re-evaluates that on every render. These tests hold a paid reader route open (the same
/// `ReaderPosition` value the Read and Search tabs keep in their navigation paths) and
/// check what the view would show after access changes. Rendering the SwiftUI view itself
/// on a device or simulator is still pending.
final class ReaderGateTests: XCTestCase {
    private let openPaidRoute = ReaderPosition(chapterID: "c2", blockID: "c2.p1")

    @MainActor
    func testOpenPaidReaderLocksOnLiveRevocation() async {
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = AppModel(book: TestBooks.small(), store: TestBooks.temporaryStore(), provider: provider)
        await model.entitlements.start()
        model.toggleBookmark(blockID: "c2.p1")
        guard case .readable(let chapter) = model.readerGate(for: openPaidRoute) else {
            return XCTFail("Paid chapter should be readable while unlocked")
        }
        XCTAssertEqual(chapter.id, "c2")

        provider.send(.revoked)
        await settle { model.access == .sample }

        guard case .locked(let locked) = model.readerGate(for: openPaidRoute) else {
            return XCTFail("The open paid reader must lock after revocation")
        }
        XCTAssertEqual(locked.id, "c2")
        // The bookmark saved in that chapter is kept.
        XCTAssertEqual(model.bookmarks.map(\.anchor.blockID), ["c2.p1"])
        // Free chapters stay readable.
        XCTAssertEqual(model.readerGate(for: ReaderPosition(chapterID: "c1", blockID: nil)),
                       .readable(TestBooks.small().chapters[0]))
    }

    @MainActor
    func testOpenPaidReaderLocksOnAuthoritativeEmptyRefresh() async {
        let provider = FakePurchaseProvider()
        provider.entitlement = .active
        let model = AppModel(book: TestBooks.small(), store: TestBooks.temporaryStore(), provider: provider)
        await model.entitlements.start()
        guard case .readable = model.readerGate(for: openPaidRoute) else { return XCTFail("Expected readable") }

        provider.entitlement = .none
        await model.entitlements.refresh()

        guard case .locked = model.readerGate(for: openPaidRoute) else {
            return XCTFail("An authoritative empty read must lock the open paid reader")
        }
    }

    @MainActor
    func testRestoredRouteLocksWhenLaunchCheckFindsNoPurchase() async throws {
        // Cached state says full access (for example, from before a refund) and the
        // saved position is in a paid chapter.
        let store = TestBooks.temporaryStore()
        var data = UserData()
        data.entitlement = EntitlementState(access: .full, awaitingApproval: false, lastVerifiedAt: Date())
        data.lastPosition = ReadingAnchor(blockID: "c2.p1", in: TestBooks.small())
        try store.save(data)

        let provider = FakePurchaseProvider()
        provider.entitlement = .none
        let model = AppModel(book: TestBooks.small(), store: store, provider: provider)
        // Before the launch check the cached state is trusted, so a route to c2 may already be open.
        guard case .readable = model.readerGate(for: openPaidRoute) else { return XCTFail("Expected cached access") }

        await model.entitlements.start()

        guard case .locked = model.readerGate(for: openPaidRoute) else {
            return XCTFail("The already-open route must lock once the launch check finds no purchase")
        }
        XCTAssertEqual(model.startPosition().chapterID, "c1")
    }

    @MainActor
    func testOfflineLaunchKeepsCachedAccess() async {
        let store = TestBooks.temporaryStore()
        var data = UserData()
        data.entitlement = EntitlementState(access: .full, awaitingApproval: false, lastVerifiedAt: Date())
        try? store.save(data)
        let provider = FakePurchaseProvider()
        provider.entitlementFails = true
        let model = AppModel(book: TestBooks.small(), store: store, provider: provider)
        await model.entitlements.start()
        guard case .readable = model.readerGate(for: openPaidRoute) else {
            return XCTFail("An unavailable check must not lock a verified cached purchase")
        }
    }

    @MainActor
    func testMissingChapter() {
        let model = AppModel(book: TestBooks.small(), store: nil, provider: FakePurchaseProvider())
        XCTAssertEqual(model.readerGate(for: ReaderPosition(chapterID: "gone", blockID: nil)), .missing)
    }
}
