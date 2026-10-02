import XCTest
@testable import AIBible

final class IDMigrationTests: XCTestCase {
    private func anchor(_ blockID: String, chapter: String = "c1", quote: String = "", version: String = "v1") -> ReadingAnchor {
        ReadingAnchor(chapterID: chapter, blockID: blockID, quote: quote, contentVersion: version)
    }

    func testExactIDWins() {
        let book = TestBooks.small()
        XCTAssertEqual(AnchorResolver.resolve(anchor("c1.p2"), in: book), .exact(blockID: "c1.p2"))
    }

    func testExplicitMapIsFollowedIncludingChains() {
        let book = TestBooks.small(version: "v2", idMap: ["old.a": "old.b", "old.b": "c1.p2"])
        XCTAssertEqual(AnchorResolver.resolve(anchor("old.a"), in: book), .mapped(blockID: "c1.p2"))
    }

    func testMapCycleFallsThroughToQuote() {
        let book = TestBooks.small(version: "v2", idMap: ["x": "y", "y": "x"])
        let saved = anchor("x", quote: "A second paragraph about follow-up")
        XCTAssertEqual(AnchorResolver.resolve(saved, in: book), .quoteMatched(blockID: "c1.p2"))
    }

    func testQuoteMatchPrefersSameChapter() {
        // "quote request" text appears in both chapters; the saved chapter wins.
        let book = TestBooks.small()
        let saved = anchor("gone", chapter: "c2", quote: "quote request")
        XCTAssertEqual(AnchorResolver.resolve(saved, in: book), .quoteMatched(blockID: "c2.p1"))
    }

    func testChapterStartWhenNothingMatches() {
        let book = TestBooks.small()
        let saved = anchor("gone", chapter: "c2", quote: "text that no longer exists anywhere")
        let result = AnchorResolver.resolve(saved, in: book)
        XCTAssertEqual(result, .chapterStart(blockID: "c2.p1"))
        XCTAssertTrue(result.isApproximate)
    }

    func testBookStartWhenChapterIsGone() {
        let book = TestBooks.small()
        let saved = anchor("gone", chapter: "removed", quote: "short")
        XCTAssertEqual(AnchorResolver.resolve(saved, in: book), .bookStart(blockID: "c1.h1"))
    }

    func testMigrationKeepsEveryBookmarkAndFlagsApproximateOnes() {
        let book = TestBooks.small(version: "v2", idMap: ["old.p2": "c1.p2"])
        var data = UserData()
        data.lastPosition = anchor("old.p2", version: "v1")
        data.bookmarks = [
            Bookmark(anchor: anchor("old.p2", version: "v1")),
            Bookmark(anchor: anchor("vanished", chapter: "c2", quote: "nothing like this", version: "v1")),
        ]

        let migrated = AnchorMigration.migrate(data, to: book)

        XCTAssertEqual(migrated.lastPosition?.blockID, "c1.p2")
        XCTAssertEqual(migrated.lastPosition?.contentVersion, "v2")
        XCTAssertEqual(migrated.bookmarks.count, 2)
        XCTAssertEqual(migrated.bookmarks[0].anchor.blockID, "c1.p2")
        XCTAssertFalse(migrated.bookmarks[0].isApproximate)
        XCTAssertEqual(migrated.bookmarks[1].anchor.blockID, "c2.p1")
        XCTAssertTrue(migrated.bookmarks[1].isApproximate)
    }

    func testAnchorQuoteIsCapped() {
        let long = String(repeating: "word ", count: 100)
        let book = TestBooks.small(chapters: [
            Chapter(id: "c1", label: "1", title: "T", access: .free, blocks: [Block(id: "b", kind: .paragraph, text: long)])
        ])
        XCTAssertEqual(ReadingAnchor(blockID: "b", in: book)?.quote.count, ReadingAnchor.quoteLength)
    }
}
