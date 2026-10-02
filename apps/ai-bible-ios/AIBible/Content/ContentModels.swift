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
    /// Converted editions only: source document path, optionally with `#fragment`, → block ID.
    /// Lets source navigation targets be resolved; nothing follows arbitrary links yet.
    var sourceAnchors: [String: String]?
    /// Converted editions only: the source's cover, title page and original contents.
    /// Missing for the synthetic fixture and older editions, which keep the plain chapter list.
    var presentation: BookPresentation?

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
        /// A source note (an aside), shown distinctly from quotations.
        case note
        /// A quotation of one or more paragraphs.
        case quote
        /// A thematic break between passages.
        case divider
        /// A group of cards whose fields vary from card to card.
        case cards
    }

    var id: String
    var kind: Kind
    /// Heading level (2 or 3). Level 1 is the chapter title.
    var level: Int?
    /// Inline Markdown: emphasis, strong, inline code and links only.
    var text: String?
    var items: [String]?
    var table: TableData?
    /// Lists only. Missing means unordered, as in editions made before ordered lists existed.
    var ordered: Bool?
    /// Ordered lists only: the first item's number when it isn't 1.
    var start: Int?
    /// Quotes only, one entry per source paragraph.
    var paragraphs: [String]?
    var cards: CardGroup?
}

extension Block {
    var isOrderedList: Bool { kind == .list && ordered == true }

    /// The number shown before an ordered list item, or nil if it doesn't fit in an `Int`
    /// (only possible for malformed data; `BookLoader.problems(in:)` rejects such lists).
    func listNumber(at index: Int) -> Int? {
        let (number, overflow) = (start ?? 1).addingReportingOverflow(index)
        return overflow ? nil : number
    }
}

/// How a converted edition presents its front matter natively.
struct BookPresentation: Codable, Sendable, Equatable {
    var cover: CoverImage?
    var titlePage: TitlePage?
    /// The source's own contents, in source order, each entry mapped to a native destination.
    var contents: [ContentsEntry]?
}

struct CoverImage: Codable, Sendable, Equatable {
    /// File name packaged next to the book JSON, for example `cover.private.jpg`.
    var resource: String
    var alt: String
    /// Lowercase hex SHA-256 of the file; checked before the edition is accepted.
    var sha256: String
    var byteCount: Int
}

struct TitlePage: Codable, Sendable, Equatable {
    /// In source order.
    var elements: [TitlePageElement]
}

struct TitlePageElement: Codable, Sendable, Equatable, Hashable {
    enum Role: String, Codable, Sendable {
        case title
        case subtitle
        case author
        case paragraph
    }

    var role: Role
    /// Inline Markdown, as in blocks.
    var text: String
}

struct ContentsEntry: Codable, Sendable, Equatable, Hashable {
    /// The source label, as plain text.
    var label: String
    /// 1 for top-level entries; each entry is at most one level deeper than the one before.
    var depth: Int
    var target: ContentsTarget
}

struct ContentsTarget: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case cover
        case titlePage
        case chapter
        case block
    }

    var kind: Kind
    var chapterID: String?
    var blockID: String?
}

/// A group of cards, each keeping its own fields in source order. Cards are not
/// forced into shared columns: one card can have fields another doesn't.
struct CardGroup: Codable, Sendable, Equatable, Hashable {
    /// Inline Markdown label shown above the cards.
    var label: String?
    var accessibilityLabel: String?
    var cards: [Card]
}

struct Card: Codable, Sendable, Equatable, Hashable {
    var accessibilityLabel: String?
    var fields: [CardField]

    /// The card's title field, if it has one.
    var title: String? { fields.first { $0.title != nil }?.title }
}

/// A label with either a title (the card's name) or a value.
struct CardField: Codable, Sendable, Equatable, Hashable {
    var label: String
    var title: String?
    var value: [CardValuePart]?
}

/// A run of inline Markdown or a blank to fill in. Exactly one is set.
struct CardValuePart: Codable, Sendable, Equatable, Hashable {
    var text: String?
    var blank: BlankField?
}

/// A printed fill-in blank. `text` is what the page shows (for example underscores);
/// `accessibilityLabel` says what belongs there.
struct BlankField: Codable, Sendable, Equatable, Hashable {
    var text: String
    var accessibilityLabel: String
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
        let protected = BareURLText.protect(markdown)
        guard var result = try? AttributedString(markdown: protected.markdown, options: options) else {
            return AttributedString(markdown)
        }
        BareURLText.restore(protected.urls, in: &result)
        return result
    }

    static func plain(_ markdown: String) -> String {
        String(attributed(markdown).characters)
    }
}

/// Foundation's Markdown parser keeps a bare URL's characters literally, so the backslash escapes
/// the converter writes inside one (before `_`, `*`, `[` and so on) would be shown. Before parsing,
/// each bare `http(s)://` run that contains such an escape is swapped for a private-use placeholder;
/// after parsing, the placeholder becomes the URL's literal text, with those escapes removed, keeping
/// the surrounding styles and adding a link. Runs without escapes are left to Foundation unchanged.
/// Nothing else changes: code spans, explicit link destinations, whole `<…>` autolinks (including any
/// URL nested inside one) and text outside URLs are parsed exactly as before, and the stored Markdown
/// is untouched.
enum BareURLText {
    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"
    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
    /// Unescaped characters that are Markdown syntax end a bare URL run.
    private static let stoppers = Set("*_`[]<>~\\\"")
    /// Trailing characters left out of the link, as in GitHub-style autolinks (still shown as text).
    private static let trailing = Set(".,:;!?")

    static func protect(_ markdown: String) -> (markdown: String, urls: [String]) {
        let chars = Array(markdown)
        if chars.contains(open) || chars.contains(close) { return (markdown, []) }
        var out = ""
        var urls: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(c)
                out.append(chars[i + 1])
                i += 2
            } else if c == "`" {
                let end = codeSpanEnd(chars, from: i)
                out.append(contentsOf: chars[i..<end])
                i = end
            } else if c == "<", let end = angleAutolinkEnd(chars, from: i) {
                out.append(contentsOf: chars[i..<end])
                i = end
            } else if c == "]", i + 1 < chars.count, chars[i + 1] == "(" {
                let end = destinationEnd(chars, from: i + 2)
                out.append(contentsOf: chars[i..<end])
                i = end
            } else if startsBareURL(chars, at: i) {
                var literal = ""
                var escaped = false
                var j = i
                while j < chars.count {
                    let d = chars[j]
                    if d == "\\", j + 1 < chars.count, asciiPunctuation.contains(chars[j + 1]),
                       chars[j + 1] != "<", chars[j + 1] != ">" {
                        literal.append(chars[j + 1])
                        escaped = true
                        j += 2
                    } else if d.isWhitespace || stoppers.contains(d) {
                        break
                    } else {
                        literal.append(d)
                        j += 1
                    }
                }
                guard escaped else {
                    // Nothing to repair: Foundation handles this URL exactly as it always has.
                    out.append(contentsOf: chars[i..<j])
                    i = j
                    continue
                }
                out.append(open)
                out.append(contentsOf: String(urls.count))
                out.append(close)
                urls.append(literal)
                i = j
            } else {
                out.append(c)
                i += 1
            }
        }
        return (out, urls)
    }

    static func restore(_ urls: [String], in text: inout AttributedString) {
        for (index, literal) in urls.enumerated().reversed() {
            guard let range = text.range(of: "\(open)\(index)\(close)") else { continue }
            let attributes = text[range].runs.first?.attributes ?? AttributeContainer()
            var replacement = AttributedString(literal, attributes: attributes)
            var target = literal
            // As in GitHub-style autolinks: trailing punctuation and an unmatched closing ")" stay text only.
            while let last = target.last, trailing.contains(last)
                    || (last == ")" && target.filter({ $0 == ")" }).count > target.filter({ $0 == "(" }).count) {
                target.removeLast()
            }
            if attributes.link == nil, !target.isEmpty, let url = URL(string: target) {
                let end = replacement.index(replacement.startIndex, offsetByCharacters: target.count)
                replacement[replacement.startIndex..<end].link = url
            }
            text.replaceSubrange(range, with: replacement)
        }
    }

    private static func startsBareURL(_ chars: [Character], at i: Int) -> Bool {
        if i > 0 {
            let previous = chars[i - 1]
            if previous.isLetter || previous.isNumber || previous == "<" { return false }
        }
        for scheme in ["https://", "http://"] where i + scheme.count <= chars.count {
            if String(chars[i..<(i + scheme.count)]).lowercased() == scheme { return true }
        }
        return false
    }

    /// End (exclusive) of a CommonMark autolink `<scheme:…>` starting at `i`, or nil if there isn't one.
    /// Scheme: a letter then 1–31 letters, digits, `+`, `.` or `-`; then `:` and no spaces, `<` or `>`.
    private static func angleAutolinkEnd(_ chars: [Character], from i: Int) -> Int? {
        var j = i + 1
        guard j < chars.count, chars[j].isASCII, chars[j].isLetter else { return nil }
        let schemeStart = j
        while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || "+.-".contains(chars[j]) {
            j += 1
        }
        guard (2...32).contains(j - schemeStart), j < chars.count, chars[j] == ":" else { return nil }
        j += 1
        while j < chars.count {
            let d = chars[j]
            if d == ">" { return j + 1 }
            if d == "<" || d.isWhitespace || d.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true { return nil }
            j += 1
        }
        return nil
    }

    /// End (exclusive) of a code span opened by a backtick run at `i`, or of the run itself if unclosed.
    private static func codeSpanEnd(_ chars: [Character], from i: Int) -> Int {
        var n = 0
        while i + n < chars.count, chars[i + n] == "`" { n += 1 }
        var j = i + n
        while j < chars.count {
            guard chars[j] == "`" else { j += 1; continue }
            var m = 0
            while j + m < chars.count, chars[j + m] == "`" { m += 1 }
            if m == n { return j + m }
            j += m
        }
        return i + n
    }

    /// End (exclusive) of an explicit link destination starting after "](", including its ")".
    private static func destinationEnd(_ chars: [Character], from start: Int) -> Int {
        var j = start
        if j < chars.count, chars[j] == "<" {
            while j < chars.count, chars[j] != ">" { j += 1 }
        }
        var depth = 1
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "(" { depth += 1 }
            if chars[j] == ")" {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return chars.count
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
        if let paragraphs { parts.append(contentsOf: paragraphs.map(InlineText.plain)) }
        if let cards {
            if let label = cards.label { parts.append(InlineText.plain(label)) }
            for card in cards.cards {
                for field in card.fields {
                    parts.append(InlineText.plain(field.label))
                    if let title = field.title { parts.append(InlineText.plain(title)) }
                    if let value = field.value { parts.append(CardValuePart.plainText(value)) }
                }
            }
        }
        return parts.joined(separator: " ")
    }
}

extension CardValuePart {
    /// The value as printed, with blanks shown as their printed text.
    static func plainText(_ parts: [CardValuePart]) -> String {
        parts.map { part in
            if let text = part.text { return InlineText.plain(text) }
            return part.blank?.text ?? ""
        }.joined()
    }

    /// The value as spoken, with each blank replaced by what belongs there.
    static func spokenText(_ parts: [CardValuePart]) -> String {
        parts.map { part in
            if let text = part.text { return InlineText.plain(text) }
            return part.blank.map { "(\($0.accessibilityLabel))" } ?? ""
        }.joined()
    }
}
