import Foundation

/// A saved place in the book. The quote lets the place be found again if an
/// edition drops or renames the block without listing it in `idMap`.
struct ReadingAnchor: Codable, Sendable, Equatable, Hashable {
    var chapterID: String
    var blockID: String
    var quote: String
    var contentVersion: String

    static let quoteLength = 80

    init(chapterID: String, blockID: String, quote: String, contentVersion: String) {
        self.chapterID = chapterID
        self.blockID = blockID
        self.quote = quote
        self.contentVersion = contentVersion
    }

    init?(blockID: String, in book: BookBundle) {
        guard let found = book.locate(blockID: blockID) else { return nil }
        self.init(
            chapterID: found.chapter.id,
            blockID: found.block.id,
            quote: String(found.block.plainText.prefix(Self.quoteLength)),
            contentVersion: book.contentVersion
        )
    }
}

/// How a saved anchor was found in the current edition, from most to least exact.
enum AnchorResolution: Equatable, Sendable {
    case exact(blockID: String)
    case mapped(blockID: String)
    case quoteMatched(blockID: String)
    case chapterStart(blockID: String)
    case bookStart(blockID: String)
    case unavailable

    var blockID: String? {
        switch self {
        case .exact(let id), .mapped(let id), .quoteMatched(let id), .chapterStart(let id), .bookStart(let id):
            return id
        case .unavailable:
            return nil
        }
    }

    /// True when the reader lands near, not on, the saved place.
    var isApproximate: Bool {
        switch self {
        case .exact, .mapped, .quoteMatched: return false
        case .chapterStart, .bookStart, .unavailable: return true
        }
    }
}

enum AnchorResolver {
    /// Order: exact ID → explicit `idMap` chain → quote match (same chapter first) → chapter start → book start.
    static func resolve(_ anchor: ReadingAnchor, in book: BookBundle) -> AnchorResolution {
        if book.locate(blockID: anchor.blockID) != nil {
            return .exact(blockID: anchor.blockID)
        }
        if let mapped = followMap(from: anchor.blockID, in: book) {
            return .mapped(blockID: mapped)
        }
        if let matched = quoteMatch(anchor, in: book) {
            return .quoteMatched(blockID: matched)
        }
        if let first = book.chapter(anchor.chapterID)?.blocks.first {
            return .chapterStart(blockID: first.id)
        }
        if let first = book.chapters.first?.blocks.first {
            return .bookStart(blockID: first.id)
        }
        return .unavailable
    }

    private static func followMap(from id: String, in book: BookBundle) -> String? {
        guard let map = book.idMap else { return nil }
        var current = id
        var visited: Set<String> = [id]
        while let next = map[current] {
            guard visited.insert(next).inserted else { return nil } // cycle
            if book.locate(blockID: next) != nil { return next }
            current = next
        }
        return nil
    }

    private static func quoteMatch(_ anchor: ReadingAnchor, in book: BookBundle) -> String? {
        let quote = anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard quote.count >= 12 else { return nil }
        var needles = [quote]
        if quote.count >= 40 { needles.append(String(quote.prefix(40))) }

        let sameChapterFirst = book.chapters.filter { $0.id == anchor.chapterID }
            + book.chapters.filter { $0.id != anchor.chapterID }
        for needle in needles {
            for chapter in sameChapterFirst {
                if let block = chapter.blocks.first(where: {
                    $0.plainText.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }) {
                    return block.id
                }
            }
        }
        return nil
    }
}
