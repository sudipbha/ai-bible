import XCTest
import UIKit
@testable import AIBible

/// Native cover, title page and source contents, using the converter's synthetic sample
/// (`ConverterSample/converter-sample.json` and `synthetic-sample-cover.png`). All text is invented.
final class PresentationTests: XCTestCase {
    private var testBundle: Bundle { Bundle(for: PresentationTests.self) }

    private func sample() throws -> BookBundle {
        try BookLoader.loadSelected(named: "converter-sample", expectFixture: false, in: testBundle)
    }

    func testPresentationDecodesAndValidates() throws {
        let book = try sample()
        let presentation = try XCTUnwrap(book.presentation)
        XCTAssertEqual(BookLoader.problems(in: book), [])
        XCTAssertEqual(presentation.cover?.resource, "synthetic-sample-cover.png")
        XCTAssertEqual(presentation.cover?.alt, "Zebrafog cover art")
        XCTAssertEqual(presentation.titlePage?.elements.count, 2)
        XCTAssertEqual(presentation.contents?.map(\.depth), [1, 1, 1, 1, 1, 2, 1, 1])
        XCTAssertEqual(book.chapters.count, 5, "front matter adds no chapters")
    }

    func testOlderEditionsHaveNoPresentationAndKeepTheChapterList() throws {
        let fixture = try BookLoader.loadBundled(named: "book.fixture")
        XCTAssertNil(fixture.presentation)
        XCTAssertNil(try BookLoader.loadCover(for: fixture, in: .main))
    }

    func testSelectedEditionLoadsItsVerifiedCover() throws {
        let edition = try BookLoader.loadSelectedEdition(named: "converter-sample", expectFixture: false, in: testBundle)
        let cover = try XCTUnwrap(edition.book.presentation?.cover)
        let data = try XCTUnwrap(edition.coverImage)
        XCTAssertEqual(data.count, cover.byteCount)
        XCTAssertEqual(BookLoader.sha256Hex(data), cover.sha256)
        XCTAssertNotNil(UIImage(data: data), "the synthetic cover is a real PNG")
    }

    func testMissingOrDifferentCoverRejectsTheEdition() throws {
        var book = try sample()
        book.presentation?.cover?.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try BookLoader.loadCover(for: book, in: testBundle)) { error in
            XCTAssertEqual(error as? BookLoader.LoadError, .coverMismatch)
        }
        book = try sample()
        book.presentation?.cover?.byteCount += 1
        XCTAssertThrowsError(try BookLoader.loadCover(for: book, in: testBundle)) { error in
            XCTAssertEqual(error as? BookLoader.LoadError, .coverMismatch)
        }
        book = try sample()
        book.presentation?.cover?.resource = "absent-cover.png"
        XCTAssertThrowsError(try BookLoader.loadCover(for: book, in: testBundle)) { error in
            XCTAssertEqual(error as? BookLoader.LoadError, .missingResource("absent-cover.png"))
        }
    }

    func testTitlePageKeepsTextOrderRolesAndStyles() throws {
        let elements = try XCTUnwrap(try sample().presentation?.titlePage?.elements)
        XCTAssertEqual(elements.map(\.role), [.title, .author])
        XCTAssertEqual(elements.map { InlineText.plain($0.text) }, ["Zebrafog Field Notes", "Example Studio with v2"])
        func intent(_ element: TitlePageElement, _ fragment: String) -> InlinePresentationIntent? {
            let attributed = InlineText.attributed(element.text)
            return attributed.runs.first { String(attributed[$0.range].characters) == fragment }?.inlinePresentationIntent
        }
        XCTAssertEqual(intent(elements[0], "Field")?.contains(.emphasized), true)
        XCTAssertEqual(intent(elements[1], "Studio")?.contains(.stronglyEmphasized), true)
        XCTAssertEqual(intent(elements[1], "v2")?.contains(.code), true)
    }

    @MainActor
    func testEveryContentsEntryHasTheRightDestination() throws {
        let book = try sample()
        let model = AppModel(book: book, store: nil, provider: FakePurchaseProvider())
        let destinations = try XCTUnwrap(book.presentation?.contents).map { model.destination(for: $0.target) }
        XCTAssertEqual(destinations, [
            .edition(.cover),
            .edition(.titlePage),
            .reader(ReaderPosition(chapterID: "copyright", blockID: nil)),
            .reader(ReaderPosition(chapterID: "front", blockID: nil)),
            .reader(ReaderPosition(chapterID: "ch01", blockID: nil)),
            .reader(ReaderPosition(chapterID: "ch01", blockID: "ch01.h0002")),
            .reader(ReaderPosition(chapterID: "ch02", blockID: "ch02.c0001")),
            .reader(ReaderPosition(chapterID: "appx", blockID: nil)),
        ])
        XCTAssertNil(model.destination(for: ContentsTarget(kind: .block, chapterID: "ch01", blockID: "ch02.c0001")))
        XCTAssertNil(model.destination(for: ContentsTarget(kind: .chapter, chapterID: "nowhere")))
    }

    @MainActor
    func testPaidContentsTargetsUseTheNormalAccessGate() async throws {
        let book = try sample()
        let provider = FakePurchaseProvider()
        let model = AppModel(book: book, store: nil, provider: provider)
        await model.entitlements.start()
        let paid = ReaderPosition(chapterID: "ch02", blockID: "ch02.c0001")
        XCTAssertEqual(model.destination(for: ContentsTarget(kind: .block, chapterID: "ch02", blockID: "ch02.c0001")), .reader(paid))
        XCTAssertFalse(model.canRead(chapterID: "ch02"))
        guard case .locked = model.readerGate(for: paid) else { return XCTFail("paid target must be locked before purchase") }
        guard case .readable = model.readerGate(for: ReaderPosition(chapterID: "ch01", blockID: "ch01.h0002")) else {
            return XCTFail("free heading target must be readable")
        }
        provider.send(.active)
        await settle { model.access == .full }
        guard case .readable = model.readerGate(for: paid) else { return XCTFail("paid target opens after unlock") }
    }

    func testPresentationValidationRejectsBadEntries() throws {
        var book = try sample()
        var contents = try XCTUnwrap(book.presentation?.contents)
        contents[0].depth = 2
        contents[2].target = ContentsTarget(kind: .chapter, chapterID: "nowhere")
        contents[5].target = ContentsTarget(kind: .block, chapterID: "ch01", blockID: "ch02.c0001")
        contents[3].label = " "
        book.presentation?.contents = contents
        book.presentation?.cover?.alt = ""
        book.presentation?.cover?.sha256 = "XYZ"
        book.presentation?.titlePage?.elements[1].text = ""
        let problems = BookLoader.problems(in: book)
        for expected in [
            "Contents entry 0 has depth 2 after 0",
            "Contents entry 2 points at a missing chapter",
            "Contents entry 5 points at a block that isn't in its chapter",
            "Contents entry 3 has no label",
            "Cover has no alt text",
            "Cover SHA-256 is invalid",
            "Title page element 1 has no text",
        ] {
            XCTAssertTrue(problems.contains(expected), "missing: \(expected)")
        }
        var noCover = try sample()
        noCover.presentation?.cover = nil
        XCTAssertTrue(BookLoader.problems(in: noCover).contains("Contents entry 0 points at a cover the edition doesn't have"))
    }

    func testPresentationFixtureForUITestsIsSyntheticAndValid() throws {
        let edition = try BookLoader.loadSelectedEdition(named: "presentation.fixture", expectFixture: true)
        XCTAssertTrue(edition.book.isFixture)
        XCTAssertNotNil(edition.coverImage)
        XCTAssertEqual(UITestSupport.bookResource(arguments: ["-AIBibleUITestBook", "presentation.fixture"]), "presentation.fixture")
        XCTAssertNil(UITestSupport.bookResource(arguments: ["-AIBibleUITestBook", "book.private"]), "only listed synthetic fixtures")
    }
}

/// The private-content scan used for app bundles, checked against a folder of offending files.
final class PrivateContentScanTests: XCTestCase {
    func testScanFlagsEachPrivateOutputAndIgnoresSyntheticFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("PlugIns"), withIntermediateDirectories: true)
        for name in ["book.fixture.json", "presentation.fixture.json", "presentation-fixture-cover.png",
                     "PlugIns/converter-sample.json", "PlugIns/synthetic-sample-cover.png"] {
            try Data("{}".utf8).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(PrivateContentScan.offendingFiles(in: root), [])
        let privateNames = ["book.private.json", "book.draft.json", "id-registry.json", "conversion-report.json",
                            "front-matter.json", "cover.json", "cover.private.jpg", "source.epub", "Book.EPUB",
                            // Cover names written by earlier converter versions, in any letter case.
                            "cover.jpg", "cover.jpeg", "cover.png", "COVER.PNG"]
        for name in privateNames {
            let url = root.appendingPathComponent("PlugIns").appendingPathComponent(name)
            try Data("private".utf8).write(to: url)
            XCTAssertEqual(PrivateContentScan.offendingFiles(in: root), ["/PlugIns/\(name)"], name)
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Mirrors ci/check-no-private-content.sh.
enum PrivateContentScan {
    static func offendingFiles(in root: URL) -> [String] {
        // Resolve symlinks (the simulator's /var is /private/var) so relative paths are stable.
        let base = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let privateNames: Set = ["front-matter.json", "cover.json", "cover.jpg", "cover.jpeg", "cover.png"]
        var offending: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isPrivate = url.pathExtension.lowercased() == "epub"
                || (name.hasPrefix("book.") && name.hasSuffix(".json") && name != "book.fixture.json")
                || name.contains(".private.")
                || (name.hasPrefix("id-registry") && name.hasSuffix(".json"))
                || (name.hasPrefix("conversion-report") && name.hasSuffix(".json"))
                || privateNames.contains(name.lowercased())
            if isPrivate {
                offending.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
            }
        }
        return offending.sorted()
    }
}
