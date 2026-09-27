import Foundation

struct SearchHit: Identifiable, Equatable, Sendable {
    var id: String { blockID }
    var chapterID: String
    var chapterLabel: String
    var chapterTitle: String
    var blockID: String
    var snippet: String
}

struct SearchResults: Equatable, Sendable {
    var hits: [SearchHit] = []
    /// Matches in chapters the reader has not unlocked. Counted, never shown.
    var lockedMatchCount = 0
}

/// Local, in-memory full-text search over the bundled edition. Every query term
/// must appear in a block; matching ignores case and accents.
///
/// A plain scan is fast enough for one book. If profiling on the oldest supported
/// device misses the search target, swap in a prebuilt SQLite FTS index.
struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        var chapterID: String
        var chapterLabel: String
        var chapterTitle: String
        var access: Chapter.Access
        var blockID: String
        var text: String
    }

    private let entries: [Entry]

    init(book: BookBundle) {
        entries = book.chapters.flatMap { chapter in
            chapter.blocks.map { block in
                Entry(
                    chapterID: chapter.id,
                    chapterLabel: chapter.label,
                    chapterTitle: chapter.title,
                    access: chapter.access,
                    blockID: block.id,
                    text: block.plainText
                )
            }
        }
    }

    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    func search(_ query: String, fullAccess: Bool, limit: Int = 100) -> SearchResults {
        let terms = Self.terms(in: query)
        guard !terms.isEmpty else { return SearchResults() }

        var results = SearchResults()
        for entry in entries {
            let matchesAll = terms.allSatisfy {
                entry.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            guard matchesAll else { continue }

            if entry.access == .paid && !fullAccess {
                results.lockedMatchCount += 1
            } else if results.hits.count < limit {
                results.hits.append(SearchHit(
                    chapterID: entry.chapterID,
                    chapterLabel: entry.chapterLabel,
                    chapterTitle: entry.chapterTitle,
                    blockID: entry.blockID,
                    snippet: Self.snippet(of: entry.text, around: terms[0])
                ))
            }
        }
        return results
    }

    static func snippet(of text: String, around term: String, before: Int = 60, after: Int = 120) -> String {
        guard let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(before + after))
        }
        let start = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }
}
