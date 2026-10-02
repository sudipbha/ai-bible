import XCTest
@testable import AIBible

/// Foundation parsing of the converter's inline Markdown around bare URLs (`BareURLText`).
/// These run the real `AttributedString(markdown:)` parser, not the converter's Python decoder.
final class InlineTextURLTests: XCTestCase {
    private func runs(_ text: AttributedString) -> [(String, AttributedString.Runs.Run)] {
        text.runs.map { (String(text[$0.range].characters), $0) }
    }

    func testBareURLPunctuationReadsLiterally() throws {
        let text = InlineText.attributed("see https://example.com/a\\_b\\*c?d=\\[1\\] now.")
        XCTAssertEqual(String(text.characters), "see https://example.com/a_b*c?d=[1] now.")
        let link = try XCTUnwrap(runs(text).first { $0.0 == "https://example.com/a_b*c?d=[1]" }?.1.link)
        XCTAssertEqual(link.host, "example.com")
        XCTAssertNil(runs(text).first { $0.0 == " now." }?.1.link, "trailing text is not part of the link")
    }

    func testTrueLiteralBackslashesStay() {
        XCTAssertEqual(InlineText.plain("path C:\\\\temp and https://x.org/a\\\\b end"),
                       "path C:\\temp and https://x.org/a\\b end")
        XCTAssertEqual(InlineText.plain("a \\\\ b"), "a \\ b")
    }

    func testURLInsideInlineCodeIsUnchanged() {
        let text = InlineText.attributed("run `https://x.org/a_b*c` now")
        XCTAssertEqual(String(text.characters), "run https://x.org/a_b*c now")
        let code = runs(text).first { $0.0 == "https://x.org/a_b*c" }?.1
        XCTAssertEqual(code?.inlinePresentationIntent?.contains(.code), true)
    }

    func testExplicitLinkKeepsItsLabelAndDestination() {
        let text = InlineText.attributed("See [the site](<https://example.org/x_y>).")
        XCTAssertEqual(String(text.characters), "See the site.")
        XCTAssertEqual(runs(text).first { $0.0 == "the site" }?.1.link?.absoluteString, "https://example.org/x_y")
        let fixtureStyle = InlineText.attributed("a link to [example.com](https://example.com/path)")
        XCTAssertEqual(String(fixtureStyle.characters), "a link to example.com")
        XCTAssertEqual(runs(fixtureStyle).first { $0.0 == "example.com" }?.1.link?.absoluteString, "https://example.com/path")
    }

    func testStylesAroundAndBesideURLs() {
        let text = InlineText.attributed("**https://x.org/a\\_b** then *see https://y.org/c\\*d* and `z`")
        XCTAssertEqual(String(text.characters), "https://x.org/a_b then see https://y.org/c*d and z")
        let all = runs(text)
        XCTAssertEqual(all.first { $0.0 == "https://x.org/a_b" }?.1.inlinePresentationIntent?.contains(.stronglyEmphasized), true)
        XCTAssertEqual(all.first { $0.0 == "https://y.org/c*d" }?.1.inlinePresentationIntent?.contains(.emphasized), true)
        XCTAssertEqual(all.first { $0.0 == "z" }?.1.inlinePresentationIntent?.contains(.code), true)
    }

    func testAngleAutolinksIncludingNestedURLsAreLeftToFoundation() throws {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for markdown in ["go <https://x.org/?next=https://y.org/a> now",
                         "go <https://x.org/a\\_b?next=https://y.org/c> now"] {
            let protected = BareURLText.protect(markdown)
            XCTAssertEqual(protected.markdown, markdown, "the whole <…> autolink is copied untouched")
            XCTAssertEqual(protected.urls, [])
            let direct = try AttributedString(markdown: markdown, options: options)
            let adapted = InlineText.attributed(markdown)
            XCTAssertEqual(adapted, direct)
            XCTAssertEqual(String(adapted.characters), String(direct.characters))
            XCTAssertEqual(adapted.runs.compactMap { $0.link }, direct.runs.compactMap { $0.link }, "same destination")
        }
    }

    func testNestedAndAdjacentStylesAroundURLs() {
        // Nested: strong and emphasis both apply to the URL.
        let nested = InlineText.attributed("***https://x.org/a\\_b*** and **see *https://y.org/c\\*d* now**")
        XCTAssertEqual(String(nested.characters), "https://x.org/a_b and see https://y.org/c*d now")
        let nestedRuns = runs(nested)
        for url in ["https://x.org/a_b", "https://y.org/c*d"] {
            let intent = nestedRuns.first { $0.0 == url }?.1.inlinePresentationIntent
            XCTAssertEqual(intent?.contains(.stronglyEmphasized), true, url)
            XCTAssertEqual(intent?.contains(.emphasized), true, url)
            XCTAssertNotNil(nestedRuns.first { $0.0 == url }?.1.link, url)
        }
        XCTAssertEqual(nestedRuns.first { $0.0 == " now" }?.1.inlinePresentationIntent?.contains(.stronglyEmphasized), true)
        XCTAssertNotEqual(nestedRuns.first { $0.0 == " now" }?.1.inlinePresentationIntent?.contains(.emphasized), true,
                          "emphasis ends after the inner URL")

        // Adjacent: styled text and code directly before a URL, with no space.
        let adjacent = InlineText.attributed("**bold**https://z.org/p\\_q `code`https://w.org/r\\*s")
        XCTAssertEqual(String(adjacent.characters), "boldhttps://z.org/p_q codehttps://w.org/r*s")
        let adjacentRuns = runs(adjacent)
        XCTAssertEqual(adjacentRuns.first { $0.0 == "bold" }?.1.inlinePresentationIntent?.contains(.stronglyEmphasized), true)
        XCTAssertEqual(adjacentRuns.first { $0.0 == "code" }?.1.inlinePresentationIntent?.contains(.code), true)
        for url in ["https://z.org/p_q", "https://w.org/r*s"] {
            let run = adjacentRuns.first { $0.0 == url }?.1
            XCTAssertNotNil(run?.link, url)
            XCTAssertNotEqual(run?.inlinePresentationIntent?.contains(.stronglyEmphasized), true, "\(url) isn't bold")
            XCTAssertNotEqual(run?.inlinePresentationIntent?.contains(.code), true, "\(url) isn't code")
        }
    }

    func testUnescapedBareURLsAreParsedExactlyAsFoundationDoes() throws {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for markdown in ["(https://example.com/a)", "see https://example.com/a.", "https://example.com/a, then more",
                         "ask https://example.com/path?x=1! now", "**https://example.com/b** and *https://example.com/c*"] {
            XCTAssertEqual(BareURLText.protect(markdown).urls, [], markdown)
            XCTAssertEqual(InlineText.attributed(markdown), try AttributedString(markdown: markdown, options: options), markdown)
        }
    }

    func testEscapedURLInParenthesesKeepsTheClosingParenOutOfTheLink() throws {
        let text = InlineText.attributed("(see https://x.org/a\\_b). And (https://x.org/p\\_(q)).")
        XCTAssertEqual(String(text.characters), "(see https://x.org/a_b). And (https://x.org/p_(q)).")
        let links = text.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://x.org/a_b", "https://x.org/p_(q)"], "balanced parens stay in the link")
        XCTAssertNil(runs(text).first { $0.0.hasPrefix(").") }?.1.link)
    }

    func testTextWithoutURLsIsParsedAsBefore() throws {
        let markdown = "Plain **strong**, *emphasis*, `code_x`, \\*literal\\* and [x](<https://e.org>)"
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        XCTAssertEqual(InlineText.attributed(markdown), try AttributedString(markdown: markdown, options: options))
    }
}
