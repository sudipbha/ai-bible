import XCTest
@testable import AIBible

final class ContentFixtureTests: XCTestCase {
    func testBundledFixtureIsWellFormed() throws {
        let book = try BookLoader.loadBundled(named: AppConfig.bundledBookResource)
        XCTAssertEqual(BookLoader.problems(in: book), [])
        XCTAssertTrue(book.isFixture, "Only synthetic fixtures may ship until an edition is approved")
    }

    func testOnlyFirstChapterIsFree() throws {
        let book = try BookLoader.loadBundled(named: AppConfig.bundledBookResource)
        XCTAssertEqual(book.chapters.first?.access, .free)
        XCTAssertTrue(book.chapters.dropFirst().allSatisfy { $0.access == .paid })
    }

    func testFixtureIdMapResolves() throws {
        let book = try BookLoader.loadBundled(named: AppConfig.bundledBookResource)
        let saved = ReadingAnchor(chapterID: "fx.ch02", blockID: "fx.ch02.p-renamed-old", quote: "", contentVersion: "older")
        XCTAssertEqual(AnchorResolver.resolve(saved, in: book), .mapped(blockID: "fx.ch02.p1"))
    }

    func testValidationCatchesStructuralProblems() {
        var book = TestBooks.small()
        book.chapters[0].blocks.append(Block(id: "c1.p1", kind: .paragraph, text: "Duplicate ID"))
        book.chapters[1].blocks.append(Block(id: "t", kind: .table, table: TableData(header: ["A", "B"], rows: [["only one"]])))
        book.tools.filterQuestions.removeLast()

        let problems = BookLoader.problems(in: book)
        XCTAssertTrue(problems.contains("Duplicate block ID c1.p1"))
        XCTAssertTrue(problems.contains { $0.hasPrefix("Table t row 0") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("Five-Question Filter needs exactly 5") })
    }

    func testInlineMarkdownPlainText() {
        XCTAssertEqual(InlineText.plain("*a* **b** [c](https://example.com)"), "a b c")
    }
}

final class SearchTests: XCTestCase {
    private let index = SearchIndex(book: TestBooks.small())

    func testIgnoresCaseAndAccents() {
        let results = index.search("CAFE", fullAccess: true)
        XCTAssertEqual(results.hits.map(\.blockID), ["c1.p1", "c2.p2"])
    }

    func testAllTermsMustMatch() {
        XCTAssertEqual(index.search("quote noon", fullAccess: true).hits.map(\.blockID), ["c1.p1"])
    }

    func testLockedMatchesAreCountedNotShown() {
        let results = index.search("quote", fullAccess: false)
        XCTAssertEqual(results.hits.map(\.blockID), ["c1.p1"])
        XCTAssertEqual(results.lockedMatchCount, 1)
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertEqual(index.search("   ", fullAccess: true), SearchResults())
    }

    func testSnippetAddsEllipsesAroundLongText() {
        let text = String(repeating: "a ", count: 100) + "needle" + String(repeating: " b", count: 100)
        let snippet = SearchIndex.snippet(of: text, around: "needle", before: 10, after: 10)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("needle"))
    }
}
