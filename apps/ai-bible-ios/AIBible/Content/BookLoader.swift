import CryptoKit
import Foundation

enum BookLoader {
    enum LoadError: Error, Equatable {
        case missingResource(String)
        /// The packaged edition isn't the kind this build selected (synthetic fixture or private edition).
        case wrongContentKind(resource: String, expectedFixture: Bool)
        /// The edition decoded but failed `problems(in:)`. Only the count is kept, never book text.
        case invalidContent(problemCount: Int)
        /// The cover file's size or SHA-256 differs from the edition's record.
        case coverMismatch
    }

    /// A selected edition with its verified cover image, if it has one.
    struct SelectedEdition {
        var book: BookBundle
        var coverImage: Data?
    }

    static func decode(_ data: Data) throws -> BookBundle {
        try JSONDecoder().decode(BookBundle.self, from: data)
    }

    static func loadBundled(named name: String, in bundle: Bundle = .main) throws -> BookBundle {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw LoadError.missingResource(name)
        }
        return try decode(Data(contentsOf: url))
    }

    /// Loads the edition this build selected, checks it is the expected kind and that it
    /// passes `problems(in:)`. There is no fallback: a missing, mismatched or structurally
    /// invalid edition is an error.
    static func loadSelected(named name: String, expectFixture: Bool, in bundle: Bundle = .main) throws -> BookBundle {
        try loadSelectedEdition(named: name, expectFixture: expectFixture, in: bundle).book
    }

    /// As `loadSelected`, and also loads the cover image the edition declares, checking its
    /// size and SHA-256. A missing or different cover fails the whole edition.
    static func loadSelectedEdition(named name: String, expectFixture: Bool, in bundle: Bundle = .main) throws -> SelectedEdition {
        let book = try loadBundled(named: name, in: bundle)
        guard book.isFixture == expectFixture else {
            throw LoadError.wrongContentKind(resource: name, expectedFixture: expectFixture)
        }
        let found = problems(in: book)
        guard found.isEmpty else { throw LoadError.invalidContent(problemCount: found.count) }
        return SelectedEdition(book: book, coverImage: try loadCover(for: book, in: bundle))
    }

    static func loadCover(for book: BookBundle, in bundle: Bundle) throws -> Data? {
        guard let cover = book.presentation?.cover else { return nil }
        let file = cover.resource as NSString
        let fileExtension = file.pathExtension
        guard let url = bundle.url(forResource: file.deletingPathExtension,
                                   withExtension: fileExtension.isEmpty ? nil : fileExtension) else {
            throw LoadError.missingResource(cover.resource)
        }
        let data = try Data(contentsOf: url)
        guard data.count == cover.byteCount, sha256Hex(data) == cover.sha256 else { throw LoadError.coverMismatch }
        return data
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Structural checks run by tests against every bundled edition. An empty
    /// result means the bundle is well formed; it says nothing about editorial accuracy.
    static func problems(in book: BookBundle) -> [String] {
        var problems: [String] = []
        var chapterIDs = Set<String>()
        var blockIDs = Set<String>()

        if book.chapters.isEmpty { problems.append("Book has no chapters") }

        for chapter in book.chapters {
            if !chapterIDs.insert(chapter.id).inserted {
                problems.append("Duplicate chapter ID \(chapter.id)")
            }
            if chapter.blocks.isEmpty {
                problems.append("Chapter \(chapter.id) has no blocks")
            }
            for block in chapter.blocks {
                if !blockIDs.insert(block.id).inserted {
                    problems.append("Duplicate block ID \(block.id)")
                }
                problems.append(contentsOf: blockProblems(block))
            }
        }

        for (old, new) in book.idMap ?? [:] {
            if blockIDs.contains(old) {
                problems.append("idMap source \(old) still exists in this edition")
            }
            if !blockIDs.contains(new), book.idMap?[new] == nil {
                problems.append("idMap target \(new) for \(old) does not exist")
            }
        }

        if book.tools.filterQuestions.count != 5 {
            problems.append("Five-Question Filter needs exactly 5 questions, found \(book.tools.filterQuestions.count)")
        }
        if book.tools.rolloutItems.isEmpty {
            problems.append("Rollout tracker has no items")
        }
        let promptIDs = (book.tools.filterQuestions + book.tools.rolloutItems).map(\.id)
        if Set(promptIDs).count != promptIDs.count {
            problems.append("Duplicate tool prompt IDs")
        }
        for linked in [book.tools.filterChapterID, book.tools.rolloutChapterID, book.tools.costChapterID] {
            if let linked, !chapterIDs.contains(linked) {
                problems.append("Tool links to missing chapter \(linked)")
            }
        }
        for (source, target) in (book.sourceAnchors ?? [:]).sorted(by: { $0.key < $1.key }) where !blockIDs.contains(target) {
            problems.append("Source anchor \(source) points at missing block \(target)")
        }
        if let presentation = book.presentation {
            problems.append(contentsOf: presentationProblems(presentation, in: book))
        }
        return problems
    }

    private static func presentationProblems(_ presentation: BookPresentation, in book: BookBundle) -> [String] {
        var result: [String] = []
        if let cover = presentation.cover {
            if cover.resource.isEmpty || cover.resource.contains("/") { result.append("Cover resource name is invalid") }
            if cover.alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("Cover has no alt text") }
            let hex = Set("0123456789abcdef")
            if cover.sha256.count != 64 || !cover.sha256.allSatisfy(hex.contains) { result.append("Cover SHA-256 is invalid") }
            if cover.byteCount <= 0 { result.append("Cover size is invalid") }
        }
        if let titlePage = presentation.titlePage {
            if titlePage.elements.isEmpty { result.append("Title page has no elements") }
            for (index, element) in titlePage.elements.enumerated() where element.text.isEmpty {
                result.append("Title page element \(index) has no text")
            }
        }
        if let contents = presentation.contents {
            if contents.isEmpty { result.append("Contents has no entries") }
            var previousDepth = 0
            for (index, entry) in contents.enumerated() {
                let place = "Contents entry \(index)"
                if entry.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append("\(place) has no label") }
                if entry.depth < 1 || entry.depth > previousDepth + 1 { result.append("\(place) has depth \(entry.depth) after \(previousDepth)") }
                previousDepth = entry.depth
                if let problem = targetProblem(entry.target, presentation: presentation, book: book) {
                    result.append("\(place) \(problem)")
                }
            }
        }
        return result
    }

    private static func targetProblem(_ target: ContentsTarget, presentation: BookPresentation, book: BookBundle) -> String? {
        switch target.kind {
        case .cover:
            if presentation.cover == nil { return "points at a cover the edition doesn't have" }
            return target.chapterID == nil && target.blockID == nil ? nil : "cover target has chapter or block IDs"
        case .titlePage:
            if presentation.titlePage == nil { return "points at a title page the edition doesn't have" }
            return target.chapterID == nil && target.blockID == nil ? nil : "title-page target has chapter or block IDs"
        case .chapter:
            guard let chapterID = target.chapterID, book.chapter(chapterID) != nil else { return "points at a missing chapter" }
            return target.blockID == nil ? nil : "chapter target has a block ID"
        case .block:
            guard let chapterID = target.chapterID, let chapter = book.chapter(chapterID) else { return "points at a missing chapter" }
            guard let blockID = target.blockID, chapter.blocks.contains(where: { $0.id == blockID }) else {
                return "points at a block that isn't in its chapter"
            }
            return nil
        }
    }

    private static func blockProblems(_ block: Block) -> [String] {
        switch block.kind {
        case .heading:
            var result: [String] = []
            if block.text?.isEmpty ?? true { result.append("Heading \(block.id) has no text") }
            if ![2, 3].contains(block.level ?? 0) { result.append("Heading \(block.id) needs level 2 or 3") }
            return result
        case .paragraph, .note:
            return (block.text?.isEmpty ?? true) ? ["Block \(block.id) has no text"] : []
        case .list:
            var result: [String] = []
            if block.items?.isEmpty ?? true { result.append("List \(block.id) has no items") }
            if block.start != nil && block.ordered != true { result.append("List \(block.id) has a start number but isn't ordered") }
            if let start = block.start, let count = block.items?.count, count > 0,
               start.addingReportingOverflow(count - 1).overflow {
                result.append("List \(block.id) numbers run past the largest supported number")
            }
            return result
        case .checklist:
            var result: [String] = []
            if block.items?.isEmpty ?? true { result.append("List \(block.id) has no items") }
            if block.ordered != nil || block.start != nil { result.append("Checklist \(block.id) can't be numbered") }
            return result
        case .quote:
            let paragraphs = block.paragraphs ?? []
            if paragraphs.isEmpty { return ["Quote \(block.id) has no paragraphs"] }
            return paragraphs.contains(where: \.isEmpty) ? ["Quote \(block.id) has an empty paragraph"] : []
        case .divider:
            let hasContent = block.text != nil || block.items != nil || block.table != nil
                || block.paragraphs != nil || block.cards != nil
            return hasContent ? ["Divider \(block.id) has content"] : []
        case .cards:
            guard let group = block.cards else { return ["Cards \(block.id) have no card data"] }
            return cardProblems(group, blockID: block.id)
        case .table:
            guard let table = block.table else { return ["Table \(block.id) has no table data"] }
            if table.header.isEmpty { return ["Table \(block.id) has no header"] }
            return table.rows.enumerated()
                .filter { $0.element.count != table.header.count }
                .map { "Table \(block.id) row \($0.offset) has \($0.element.count) cells, header has \(table.header.count)" }
        }
    }

    private static func cardProblems(_ group: CardGroup, blockID: String) -> [String] {
        var result: [String] = []
        if group.cards.isEmpty { result.append("Cards \(blockID) have no cards") }
        for (cardIndex, card) in group.cards.enumerated() {
            let place = "Cards \(blockID) card \(cardIndex)"
            if card.fields.isEmpty { result.append("\(place) has no fields") }
            if card.fields.filter({ $0.title != nil }).count > 1 { result.append("\(place) has more than one title") }
            for (fieldIndex, field) in card.fields.enumerated() {
                let fieldPlace = "\(place) field \(fieldIndex)"
                if field.label.isEmpty { result.append("\(fieldPlace) has no label") }
                if (field.title == nil) == (field.value == nil) {
                    result.append("\(fieldPlace) needs either a title or a value")
                }
                if let value = field.value {
                    if value.isEmpty { result.append("\(fieldPlace) has an empty value") }
                    if value.contains(where: { ($0.text == nil) == ($0.blank == nil) }) {
                        result.append("\(fieldPlace) has a value part that isn't exactly text or a blank")
                    }
                    if value.compactMap(\.blank).contains(where: { $0.text.isEmpty || $0.accessibilityLabel.isEmpty }) {
                        result.append("\(fieldPlace) has a blank without printed text or an accessibility label")
                    }
                }
            }
        }
        return result
    }
}
