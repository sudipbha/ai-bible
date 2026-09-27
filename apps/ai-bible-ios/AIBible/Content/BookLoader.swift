import Foundation

enum BookLoader {
    enum LoadError: Error, Equatable {
        case missingResource(String)
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
        return problems
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
        case .list, .checklist:
            return (block.items?.isEmpty ?? true) ? ["List \(block.id) has no items"] : []
        case .table:
            guard let table = block.table else { return ["Table \(block.id) has no table data"] }
            if table.header.isEmpty { return ["Table \(block.id) has no header"] }
            return table.rows.enumerated()
                .filter { $0.element.count != table.header.count }
                .map { "Table \(block.id) row \($0.offset) has \($0.element.count) cells, header has \(table.header.count)" }
        }
    }
}
