import Foundation

/// One packaged edition of the book, decoded from a bundled JSON file.
///
/// Block and chapter IDs are authored editorial IDs (for example `ch03.filter.q1`).
/// They must stay stable across editions; when one has to change, the old ID is
/// listed in `idMap` so saved positions and bookmarks can follow it.
struct BookBundle: Codable, Sendable, Equatable {
    var contentVersion: String
    /// True for synthetic test content. Builds with real book text set this to false.
    var isFixture: Bool
    var title: String
    var chapters: [Chapter]
    /// Old block ID → replacement block ID, for anchors saved against earlier editions.
    var idMap: [String: String]?
    var tools: ToolContent

    func chapter(_ id: String) -> Chapter? {
        chapters.first { $0.id == id }
    }

    func chapterIndex(_ id: String) -> Int? {
        chapters.firstIndex { $0.id == id }
    }

    func locate(blockID: String) -> (chapter: Chapter, block: Block)? {
        for chapter in chapters {
            if let block = chapter.blocks.first(where: { $0.id == blockID }) {
                return (chapter, block)
            }
        }
        return nil
    }
}

struct Chapter: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Access: String, Codable, Sendable {
        case free
        case paid
    }

    var id: String
    /// Short label such as "Chapter 1" or "Appendix A".
    var label: String
    var title: String
    var access: Access
    var blocks: [Block]

    var headings: [Block] {
        blocks.filter { $0.kind == .heading }
    }
}

struct Block: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case heading
        case paragraph
        case list
        case checklist
        case table
        case note
    }

    var id: String
    var kind: Kind
    /// Heading level (2 or 3). Level 1 is the chapter title.
    var level: Int?
    /// Inline Markdown: emphasis, strong, inline code and links only.
    var text: String?
    var items: [String]?
    var table: TableData?
}

struct TableData: Codable, Sendable, Equatable, Hashable {
    var caption: String?
    var header: [String]
    var rows: [[String]]

    func cell(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
        return rows[row][column]
    }
}

/// Text for the saved tools. It ships with the content so the real wording comes
/// from the approved book edition, not from app code.
struct ToolContent: Codable, Sendable, Equatable {
    var filterQuestions: [ToolPrompt]
    var rolloutItems: [ToolPrompt]
    var filterChapterID: String?
    var rolloutChapterID: String?
    var costChapterID: String?
}

struct ToolPrompt: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var text: String
}

enum InlineText {
    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    static func plain(_ markdown: String) -> String {
        String(attributed(markdown).characters)
    }
}

extension Block {
    /// Plain text used for search, quote anchors and copying.
    var plainText: String {
        var parts: [String] = []
        if let text { parts.append(InlineText.plain(text)) }
        if let items { parts.append(contentsOf: items.map(InlineText.plain)) }
        if let table {
            if let caption = table.caption { parts.append(InlineText.plain(caption)) }
            parts.append(contentsOf: table.header.map(InlineText.plain))
            parts.append(contentsOf: table.rows.flatMap { $0.map(InlineText.plain) })
        }
        return parts.joined(separator: " ")
    }
}
