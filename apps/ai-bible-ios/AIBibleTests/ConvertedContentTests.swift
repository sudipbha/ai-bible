import XCTest
@testable import AIBible

/// Decodes `ConverterSample/converter-sample.json`, the converter's output for its synthetic
/// test EPUB (converter/tests). All of its text is invented.
final class ConvertedContentTests: XCTestCase {
    private func sample() throws -> BookBundle {
        let url = try XCTUnwrap(
            Bundle(for: ConvertedContentTests.self).url(forResource: "converter-sample", withExtension: "json"),
            "converter-sample.json must be in the test bundle"
        )
        return try BookLoader.decode(Data(contentsOf: url))
    }

    private func chapter(_ id: String) throws -> Chapter {
        try XCTUnwrap(try sample().chapter(id))
    }

    func testConverterOutputDecodesAndValidates() throws {
        let book = try sample()
        XCTAssertEqual(BookLoader.problems(in: book), [])
        XCTAssertFalse(book.isFixture, "converted editions are never marked as fixtures")
        XCTAssertEqual(book.chapters.map(\.id), ["copyright", "front", "ch01", "ch02", "appx"])
    }

    func testOrderedListKeepsItsStartNumber() throws {
        let lists = try chapter("ch01").blocks.filter { $0.kind == .list }
        XCTAssertEqual(lists.map(\.isOrderedList), [false, true, true])
        XCTAssertEqual([lists[1].listNumber(at: 0), lists[1].listNumber(at: 1)], [4, 5])
        XCTAssertEqual(lists[2].listNumber(at: 0), 1)
    }

    func testCardsKeepEachCardsOwnFields() throws {
        let group = try XCTUnwrap(try chapter("ch02").blocks.first?.cards)
        XCTAssertEqual(group.label, "Group label")
        XCTAssertEqual(group.cards.map { $0.fields.map(\.label) }, [["Tool", "Use", "Cost"], ["Tool", "Owner", "Verdict", "Review"]])
        XCTAssertEqual(group.cards.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(group.cards.map(\.accessibilityLabel), ["Card A", "Card B"])
        let review = try XCTUnwrap(group.cards[1].fields[3].value)
        XCTAssertEqual(CardValuePart.plainText(review), "Every ____ weeks")
        XCTAssertEqual(CardValuePart.spokenText(review), "Every (Number of weeks) weeks")
    }

    func testQuotesNotesAndDividersStayDistinct() throws {
        let quote = try XCTUnwrap(try chapter("ch02").blocks.first { $0.kind == .quote })
        XCTAssertEqual(quote.paragraphs?.count, 4)
        XCTAssertEqual(InlineText.plain(quote.paragraphs?[2] ?? ""), "Quoted three.")
        let kinds = try chapter("ch01").blocks.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .note }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .divider }.count, 1)
    }

    func testEscapedMarksAndRawURLsReadExactly() throws {
        let paragraph = try chapter("ch01").blocks[2]
        XCTAssertEqual(
            paragraph.plainText,
            "Literal marks * _ ` [x] <tag> & ~ ! \\ stay as typed; see https://example.com/a_b*c?d=[1] now."
        )
        XCTAssertTrue(try chapter("ch01").blocks[0].plainText.hasSuffix("and tail text."))
    }

    func testSearchReachesCardValuesAndQuotes() throws {
        let index = SearchIndex(book: try sample())
        XCTAssertEqual(index.search("drafting", fullAccess: true).hits.map(\.blockID), ["ch02.c0001"])
        XCTAssertEqual(index.search("quoted four", fullAccess: true).hits.map(\.blockID), ["ch02.q0002"])
    }

    func testSourceAnchorsPointAtBlocks() throws {
        let book = try sample()
        XCTAssertEqual(book.sourceAnchors?["ch1.xhtml#s2"], "ch01.h0002")
        XCTAssertEqual(book.sourceAnchors?["ch2.xhtml"], "ch02.c0001")
        var broken = book
        broken.sourceAnchors?["ch1.xhtml#gone"] = "ch01.p9999"
        XCTAssertTrue(BookLoader.problems(in: broken).contains("Source anchor ch1.xhtml#gone points at missing block ch01.p9999"))
    }

    func testToolWordingComesFromTheConvertedText() throws {
        let tools = try sample().tools
        XCTAssertEqual(tools.filterQuestions.map(\.text), ["Pick a task", "Time it", "Try the tool", "Check the result", "Decide"])
        XCTAssertEqual(tools.rolloutItems.map(\.id), ["rollout.s1", "rollout.s2"])
        XCTAssertEqual(tools.costChapterID, "ch02")
    }

    func testValidationRejectsMalformedNewShapes() {
        let field = CardField(label: "L", title: "T", value: [CardValuePart(text: "v")])
        let emptyBlank = CardField(label: "L", value: [CardValuePart(blank: BlankField(text: "___", accessibilityLabel: ""))])
        let twoTitles = Card(fields: [CardField(label: "A", title: "One"), CardField(label: "B", title: "Two")])
        let chapter = Chapter(id: "c9", label: "C9", title: "Shapes", access: .paid, blocks: [
            Block(id: "c9.l1", kind: .list, items: ["a"], ordered: false, start: 4),
            Block(id: "c9.d1", kind: .divider, text: "not empty"),
            Block(id: "c9.q1", kind: .quote, paragraphs: []),
            Block(id: "c9.c1", kind: .cards, cards: CardGroup(cards: [Card(fields: [field, emptyBlank]), twoTitles])),
        ])
        let problems = BookLoader.problems(in: TestBooks.small(chapters: TestBooks.small().chapters + [chapter]))
        XCTAssertTrue(problems.contains("List c9.l1 has a start number but isn't ordered"))
        XCTAssertTrue(problems.contains("Divider c9.d1 has content"))
        XCTAssertTrue(problems.contains("Quote c9.q1 has no paragraphs"))
        XCTAssertTrue(problems.contains("Cards c9.c1 card 0 field 0 needs either a title or a value"))
        XCTAssertTrue(problems.contains("Cards c9.c1 card 0 field 1 has a blank without printed text or an accessibility label"))
        XCTAssertTrue(problems.contains("Cards c9.c1 card 1 has more than one title"))
    }

    func testFoundationKeepsConvertedInlineStyles() throws {
        // The converter's Markdown, parsed by Foundation as the reader does (not the Python decoder).
        let attributed = InlineText.attributed(try chapter("ch01").blocks[0].text ?? "")
        func intent(of fragment: String) -> InlinePresentationIntent? {
            attributed.runs.first { String(attributed[$0.range].characters) == fragment }?.inlinePresentationIntent
        }
        XCTAssertEqual(String(attributed.characters), "Plain Zebrafog opening with strong, emphasis, inline_code() and tail text.")
        XCTAssertEqual(intent(of: "strong")?.contains(.stronglyEmphasized), true)
        XCTAssertEqual(intent(of: "emphasis")?.contains(.emphasized), true)
        XCTAssertEqual(intent(of: "inline_code()")?.contains(.code), true)
        XCTAssertNil(intent(of: " and tail text."), "tail text stays plain")
    }

    func testListNumbersStayWithinIntRange() throws {
        func list(start: Int, count: Int) -> Block {
            Block(id: "n.l", kind: .list, items: Array(repeating: "x", count: count), ordered: true, start: start)
        }
        func problems(_ block: Block) -> [String] {
            let chapter = Chapter(id: "n", label: "N", title: "Numbers", access: .paid, blocks: [block])
            return BookLoader.problems(in: TestBooks.small(chapters: TestBooks.small().chapters + [chapter]))
        }
        let overflow = "List n.l numbers run past the largest supported number"
        XCTAssertFalse(problems(list(start: .max, count: 1)).contains(overflow))
        XCTAssertEqual(list(start: .max, count: 1).listNumber(at: 0), Int.max)
        XCTAssertTrue(problems(list(start: .max, count: 2)).contains(overflow))
        XCTAssertNil(list(start: .max, count: 2).listNumber(at: 1))
        XCTAssertFalse(problems(list(start: .min, count: 2)).contains(overflow))
        XCTAssertEqual(list(start: -3, count: 2).listNumber(at: 1), -2)
        XCTAssertEqual(list(start: 0, count: 1).listNumber(at: 0), 0)
        // Numbers outside Int don't decode at all.
        for start in ["9223372036854775808", "-9223372036854775809"] {
            let json = #"{"id":"n.l","kind":"list","items":["x"],"ordered":true,"start":\#(start)}"#
            XCTAssertThrowsError(try JSONDecoder().decode(Block.self, from: Data(json.utf8)))
        }
    }

    func testSelectedEditionThatFailsItsChecksIsRejected() throws {
        let bundle = Bundle(for: ConvertedContentTests.self)
        XCTAssertThrowsError(try BookLoader.loadSelected(named: "malformed-selected", expectFixture: false, in: bundle)) { error in
            guard case .invalidContent(let count)? = error as? BookLoader.LoadError else {
                return XCTFail("expected invalidContent, got \(error)")
            }
            XCTAssertGreaterThanOrEqual(count, 4, "overflowing list, empty quote, no Filter questions, no rollout items")
        }
        XCTAssertNoThrow(try BookLoader.loadSelected(named: "converter-sample", expectFixture: false, in: bundle))
        XCTAssertNoThrow(try BookLoader.loadSelected(named: "book.fixture", expectFixture: true))
    }

    func testEditionsWithoutTheNewFieldsStillDecode() throws {
        let book = try BookLoader.loadBundled(named: AppConfig.bundledBookResource)
        XCTAssertNil(book.sourceAnchors)
        let list = try XCTUnwrap(book.chapters.flatMap(\.blocks).first { $0.kind == .list })
        XCTAssertNil(list.ordered)
        XCTAssertFalse(list.isOrderedList, "lists from older editions stay bulleted")
    }
}

/// Public builds and CI must only ever package the synthetic fixture.
final class ContentPackagingTests: XCTestCase {
    func testPublicBuildSelectsTheSyntheticFixture() {
        XCTAssertEqual(AppConfig.bundledBookResource, "book.fixture")
        XCTAssertTrue(AppConfig.expectsFixtureContent)
    }

    func testAppBundleContainsNoPrivateContent() throws {
        XCTAssertEqual(PrivateContentScan.offendingFiles(in: Bundle.main.bundleURL), [],
                       "private or converted content found in the app bundle")
        // Every bundled book is a synthetic fixture.
        for name in ["book.fixture", "presentation.fixture"] {
            XCTAssertTrue(try BookLoader.loadBundled(named: name).isFixture, name)
        }
        let books = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .map(\.lastPathComponent).filter { $0.hasSuffix(".fixture.json") || $0.hasPrefix("book.") }.sorted()
        XCTAssertEqual(books, ["book.fixture.json", "presentation.fixture.json"])
    }

    func testSelectedEditionMustBeTheExpectedKind() {
        XCTAssertThrowsError(try BookLoader.loadSelected(named: "book.fixture", expectFixture: false)) { error in
            XCTAssertEqual(error as? BookLoader.LoadError, .wrongContentKind(resource: "book.fixture", expectedFixture: false))
        }
        XCTAssertThrowsError(try BookLoader.loadSelected(named: "book.private", expectFixture: false)) { error in
            XCTAssertEqual(error as? BookLoader.LoadError, .missingResource("book.private"))
        }
        XCTAssertNoThrow(try BookLoader.loadSelected(named: "book.fixture", expectFixture: true))
    }
}

/// When the selected content can't be loaded, saved places and records must survive untouched.
final class ContentLoadErrorTests: XCTestCase {
    @MainActor
    func testLoadErrorStateNeverRewritesSavedData() async throws {
        let store = TestBooks.temporaryStore()
        let book = TestBooks.small()
        let seeding = AppModel(book: book, store: store, provider: FakePurchaseProvider())
        seeding.updatePosition(blockID: "c1.p2")
        seeding.toggleBookmark(blockID: "c1.p1")
        let filterID = seeding.newFilter()
        seeding.flush()
        let seeded = try Data(contentsOf: store.url)

        let provider = FakePurchaseProvider()
        let placeholder = BookBundle(
            contentVersion: "missing", isFixture: true, title: "AI Bible", chapters: [], idMap: nil,
            tools: ToolContent(filterQuestions: [], rolloutItems: [])
        )
        let failed = AppModel(book: placeholder, loadError: "The book content couldn't be loaded.", store: store, provider: provider)
        XCTAssertEqual(failed.lastPosition?.blockID, "c1.p2", "not migrated against the placeholder")
        await failed.entitlements.start()
        provider.send(.active)
        await settle { failed.access == .full }
        XCTAssertEqual(failed.access, .full)
        failed.flush()
        XCTAssertFalse(failed.deleteAllUserData())
        XCTAssertEqual(try Data(contentsOf: store.url), seeded, "the saved file is byte-for-byte unchanged")

        let reopened = AppModel(book: book, store: store, provider: FakePurchaseProvider())
        XCTAssertEqual(reopened.lastPosition?.blockID, "c1.p2")
        XCTAssertEqual(reopened.bookmarks.map(\.anchor.blockID), ["c1.p1"])
        XCTAssertEqual(reopened.filters.map(\.id), [filterID])
    }
}
