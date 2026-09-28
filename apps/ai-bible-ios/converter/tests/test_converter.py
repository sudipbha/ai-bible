"""Synthetic-only tests for the EPUB converter. Run: python3 -m unittest discover -s converter/tests"""

import copy
import hashlib
import io
import json
import os
import posixpath
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import aibible_convert as conv  # noqa: E402
import synthetic_epub as syn  # noqa: E402


def zipfile_open(path):
    import zipfile
    return zipfile.ZipFile(path)


def temporary_git_repo(parent):
    """A throwaway Git working tree under `parent`. Uses `git init` with an empty, isolated global
    config when Git is installed; otherwise creates the same `.git` marker the guards look for.
    The user's own repositories and configuration are never touched."""
    repo = Path(parent) / "repo"
    repo.mkdir()
    git = shutil.which("git")
    if git:
        config = Path(parent) / "isolated-gitconfig"
        config.write_text("", encoding="utf-8")
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config))
        subprocess.run([git, "init", "-q", str(repo)], check=True, env=env, capture_output=True)
    else:
        (repo / ".git").mkdir()
    assert conv.inside_git_tree(repo)
    return repo


class Workspace:
    """A temporary folder outside any Git working tree."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name)
        assert not conv.inside_git_tree(self.path)

    def epub(self, data, name="book.epub"):
        path = self.path / name
        path.write_bytes(data)
        return str(path)

    def close(self):
        self.tmp.cleanup()


def convert(documents=None, edition_overrides=None, registry=None, migration=None, tools=None, **build):
    data = syn.build(documents=documents, **build)
    ws = Workspace()
    try:
        edition = syn.edition(data, **(edition_overrides or {}))
        return conv.convert(ws.epub(data), edition, registry or conv.empty_registry(), migration or {}, tools)
    finally:
        ws.close()


def changed(doc, old, new):
    documents = copy.deepcopy(syn.DOCUMENTS)
    assert old in documents[doc], old
    documents[doc] = documents[doc].replace(old, new)
    return documents


def blocks(book, chapter_id):
    return next(c for c in book["chapters"] if c["id"] == chapter_id)["blocks"]


def ids_of(book):
    return [b["id"] for c in book["chapters"] for b in c["blocks"]]


class FailureAssertions(unittest.TestCase):
    def assertFails(self, code, **kwargs):
        with self.assertRaises(conv.ConversionFailed) as caught:
            convert(**kwargs)
        diagnostics = caught.exception.diagnostics
        self.assertTrue(any(d.startswith(code) for d in diagnostics), f"{code} not in {diagnostics}")
        self.assertLessEqual(len(diagnostics), conv.MAX_ERRORS)
        for line in diagnostics:
            self.assertNotIn(syn.SENTINEL, line, "diagnostics must not echo book text")
        return diagnostics


class StructureTests(FailureAssertions):
    @classmethod
    def setUpClass(cls):
        cls.book, cls.registry, cls.report, cls.extras = convert()
        cls.cover = cls.extras["cover"]

    def test_reading_sections_and_native_front_matter(self):
        self.assertEqual([c["id"] for c in self.book["chapters"]], ["copyright", "front", "ch01", "ch02", "appx"])
        self.assertEqual([(d["role"], d["status"]) for d in self.report["frontMatterDocuments"]],
                         [("cover", "presented-natively"), ("titlePage", "presented-natively"),
                          ("printedContents", "reconciled-to-native-contents")])
        self.assertFalse(self.book["isFixture"])
        self.assertEqual(self.book["chapters"][0]["title"], "Copyright", "no h1: title comes from the NCX label")
        self.assertEqual(self.book["chapters"][2]["title"], f"{syn.SENTINEL} One")
        self.assertEqual([c["access"] for c in self.book["chapters"]], ["free", "free", "free", "paid", "paid"])

    def test_ordered_start_and_unordered_lists(self):
        lists = [b for b in blocks(self.book, "ch01") if b["kind"] == "list"]
        self.assertEqual([(b["ordered"], b.get("start"), len(b["items"])) for b in lists],
                         [(False, None, 2), (True, 4, 2), (True, None, 2)])

    def test_inline_styles_are_preserved_in_order(self):
        first = blocks(self.book, "ch01")[0]["text"]
        self.assertEqual(first, f"Plain {syn.SENTINEL} opening with **strong**, *emphasis*, `inline_code()` and tail text.")
        self.assertEqual(blocks(self.book, "ch01")[3]["items"], ["First **bold** item", "Second *soft* item with `x`"])

    def test_literal_marks_and_raw_urls_round_trip_exactly(self):
        text = blocks(self.book, "ch01")[2]["text"]
        plain, counts = conv.decode_markdown(text)
        self.assertEqual(plain, "Literal marks * _ ` [x] <tag> & ~ ! \\ stay as typed; see https://example.com/a_b*c?d=[1] now.")
        self.assertEqual(counts, {"strong": 0, "em": 0, "code": 0, "link": 0})
        self.assertEqual(self.report["outputCensus"]["rawURLs"], 1)

    def test_source_note_is_distinct_from_quote(self):
        kinds = [b["kind"] for b in blocks(self.book, "ch01")] + [b["kind"] for b in blocks(self.book, "ch02")]
        self.assertIn("note", kinds)
        self.assertIn("quote", kinds)
        note = next(b for b in blocks(self.book, "ch01") if b["kind"] == "note")
        self.assertEqual(note["text"], "**Source:** invented study, `ref-9`, tail.")
        quote = next(b for b in blocks(self.book, "ch02") if b["kind"] == "quote")
        self.assertEqual(quote["paragraphs"], ["Quoted one.", "Quoted two.", "Quoted *three*.", "Quoted four."])

    def test_divider_and_heading_levels(self):
        ch1 = blocks(self.book, "ch01")
        self.assertIn({"kind": "divider"}, [{k: v for k, v in b.items() if k != "id"} for b in ch1])
        self.assertEqual([(b["level"], b["text"]) for b in ch1 if b["kind"] == "heading"],
                         [(2, "Styles and marks"), (3, "Minor heading")])

    def test_cards_keep_boundaries_order_and_varied_fields(self):
        group = blocks(self.book, "ch02")[0]["cards"]
        self.assertEqual(group["label"], "Group label")
        self.assertEqual(group["accessibilityLabel"], "Invented comparison")
        self.assertEqual([c["accessibilityLabel"] for c in group["cards"]], ["Card A", "Card B"])
        self.assertEqual([[f["label"] for f in c["fields"]] for c in group["cards"]],
                         [["Tool", "Use", "Cost"], ["Tool", "Owner", "Verdict", "Review"]])
        self.assertEqual([c["fields"][0].get("title") for c in group["cards"]], ["Alpha", "Beta"])
        card_b = group["cards"][1]["fields"]
        self.assertEqual(card_b[1]["value"], [{"blank": {"text": "________", "accessibilityLabel": "Write the owner"}}])
        self.assertEqual(card_b[2]["value"], [{"text": "**Keep**"}])
        self.assertEqual(card_b[3]["value"], [{"text": "Every "},
                                              {"blank": {"text": "____", "accessibilityLabel": "Number of weeks"}},
                                              {"text": " weeks"}])
        self.assertEqual(group["cards"][0]["fields"][2]["value"], [{"text": "About **$5** a month, billed yearly"}])
        self.assertNotIn("table", [b["kind"] for b in blocks(self.book, "ch02")], "cards never become a uniform table")

    def test_source_and_output_census_reconcile(self):
        source, output = self.report["sourceCensus"], self.report["outputCensus"]
        self.assertEqual((source["ol"], source["ul"], source["li"]), (3, 1, 11))
        self.assertEqual((output["orderedLists"], output["unorderedLists"], output["listItems"]), (3, 1, 11))
        self.assertEqual((source["cardGroups"], source["cards"], source["fields"], source["labels"],
                          source["values"], source["cardTitles"], source["blankFields"]), (1, 2, 7, 8, 5, 2, 2))
        self.assertEqual(source["blankFieldsWithAria"], 2)
        self.assertEqual((source["strong"], source["em"], source["code"]), (5, 3, 3))
        self.assertEqual((output["strong"], output["em"], output["code"]), (5, 3, 3))

    def test_navigation_and_source_anchors(self):
        anchors = self.book["sourceAnchors"]
        self.assertEqual(anchors["ch1.xhtml#s2"], "ch01.h0002")
        self.assertEqual(anchors["ch2.xhtml#top"], blocks(self.book, "ch02")[0]["id"])
        self.assertEqual(anchors["ch1.xhtml"], "ch01.p0001")
        self.assertEqual(self.report["navigation"]["ncxTopLevel"], 7)
        self.assertEqual(self.report["navigation"]["ncxTotal"], 8)
        self.assertEqual(self.report["navigation"]["printedContentsLinks"], {"internal": 8, "external": 0})

    def test_cover_is_pinned_and_described(self):
        self.assertEqual(self.cover["sha256"], hashlib.sha256(syn.COVER_BYTES).hexdigest())
        self.assertEqual(self.cover["alt"], f"{syn.SENTINEL} cover art")

    def test_report_contains_no_prose(self):
        text = json.dumps(self.report)
        self.assertNotIn(syn.SENTINEL, text)
        for phrase in ("Quoted", "Drafting", "invented", "Repeated"):
            self.assertNotIn(phrase, text)

    def test_expected_census_is_enforced(self):
        self.assertFails("expected-census-mismatch", edition_overrides={"expectedCensus": {"ol": 27}})
        convert(edition_overrides={"expectedCensus": {"ol": 3, "li": 11, "blankFields": 2}})


class UnsupportedShapeTests(FailureAssertions):
    def test_nested_list(self):
        self.assertFails("unsupported-list-item-shape",
                         documents=changed("ch1.xhtml", "<li>Fourth step</li>", "<li>Fourth<ul><li>n</li></ul></li>"))

    def test_paragraph_inside_list_item(self):
        self.assertFails("unsupported-list-item-shape",
                         documents=changed("ch1.xhtml", "<li>Fourth step</li>", "<li><p>Fourth step</p></li>"))

    def test_list_type_and_reversed(self):
        self.assertFails("unsupported-list-attribute", documents=changed("ch1.xhtml", '<ol start="4">', '<ol start="4" type="a">'))
        self.assertFails("unsupported-list-attribute", documents=changed("ch1.xhtml", '<ol start="4">', '<ol start="4" reversed="reversed">'))

    def test_block_elements_without_support(self):
        for markup in ("<pre>code</pre>", '<img src="x.png" alt="a"/>', "<figure><p>f</p></figure>",
                       '<svg xmlns="http://www.w3.org/2000/svg"/>', "<h5>deep</h5>", "<dl><dt>a</dt></dl>"):
            with self.subTest(markup=markup):
                self.assertFails("unsupported-element", documents=changed("ch1.xhtml", "<hr/>", markup + "<hr/>"))

    def test_inline_elements_without_support(self):
        for markup in ("<sup>1</sup>", "<br/>", "<u>u</u>", '<span class="smallcaps">s</span>'):
            with self.subTest(markup=markup):
                self.assertFails("unsupported-", documents=changed("ch1.xhtml", "and tail text", "and " + markup + " text"))

    def test_internal_link_in_reading_body(self):
        self.assertFails("unsupported-internal-link",
                         documents=changed("ch1.xhtml", "<p>After the divider.</p>", '<p>See <a href="ch2.xhtml#top">two</a>.</p>'))

    def test_external_link_is_preserved(self):
        book, _, report, _ = convert(documents=changed(
            "ch1.xhtml", "<p>After the divider.</p>", '<p>See <a href="https://example.org/x_y">the site</a>.</p>'))
        self.assertEqual(blocks(book, "ch01")[-1]["text"], "See [the site](<https://example.org/x_y>).")
        self.assertEqual(report["outputCensus"]["links"], 1)

    def test_second_h1_and_h4_outside_card(self):
        self.assertFails("unsupported-h1-position", documents=changed("ch1.xhtml", "<hr/>", "<h1>Again</h1><hr/>"))
        self.assertFails("unsupported-h4-outside-card-field", documents=changed("ch1.xhtml", "<hr/>", "<h4>Loose</h4><hr/>"))
        self.assertFails("unsupported-h1-markup", documents=changed("ch1.xhtml", f"{syn.SENTINEL} One</h1>", f"<em>{syn.SENTINEL}</em> One</h1>"))

    def test_note_and_aside_shapes(self):
        self.assertFails("unsupported-source-note-shape",
                         documents=changed("ch1.xhtml", "tail.</p></aside>", "tail.</p><p>Second</p></aside>"))
        self.assertFails("unsupported-aside", documents=changed("ch1.xhtml", 'class="source-notes"', 'class="sidebar"'))
        self.assertFails("unsupported-quote-child",
                         documents=changed("ch2.xhtml", "<blockquote><p>Quoted one.</p>", "<blockquote><div>Quoted one.</div>"))

    def test_card_shapes(self):
        self.assertFails("unsupported-card-field-shape", documents=changed(
            "ch2.xhtml", '<h4 class="table-card-title">Alpha</h4>', '<p class="table-label">Extra</p><h4 class="table-card-title">Alpha</h4>'))
        self.assertFails("unsupported-card-child", documents=changed(
            "ch2.xhtml", '<section class="table-card" aria-label="Card A">', '<section class="table-card" aria-label="Card A"><p>stray</p>'))
        self.assertFails("unsupported-card-group-child", documents=changed(
            "ch2.xhtml", '<p class="table-label">Group label</p>', '<p class="table-label">Group label</p><p>stray</p>'))
        self.assertFails("card-part-outside-card", documents=changed(
            "ch1.xhtml", "<p>After the divider.</p>", '<p class="table-label">Loose label</p>'))

    def test_blank_field_rules(self):
        self.assertFails("blank-field-without-aria-label",
                         documents=changed("ch2.xhtml", ' aria-label="Write the owner"', ""))
        self.assertFails("blank-field-outside-card-value", documents=changed(
            "ch1.xhtml", "<p>After the divider.</p>", '<p>Name <span class="blank-field" aria-label="n">___</span></p>'))
        self.assertFails("empty-blank-field", documents=changed("ch2.xhtml", ">________</span>", "></span>"))

    def test_emphasis_that_markdown_cannot_represent(self):
        self.assertFails("emphasis-boundary-not-representable", documents=changed(
            "ch1.xhtml", "<p>After the divider.</p>", '<p>A<strong>"quoted"</strong>b</p>'))
        self.assertFails("adjacent-emphasis-runs", documents=changed(
            "ch1.xhtml", "<p>After the divider.</p>", "<p><em>a</em><strong>b</strong></p>"))

    def test_code_that_markdown_cannot_represent(self):
        self.assertFails("unsupported-code-content", documents=changed("ch1.xhtml", "<code>x</code>", "<code>a`b</code>"))

    def test_text_outside_blocks(self):
        self.assertFails("text-outside-block", documents=changed("ch1.xhtml", "<hr/>", "loose words<hr/>"))

    def test_uniform_html_table_still_supported(self):
        book, _, _, _ = convert(documents=changed("ch1.xhtml", "<hr/>",
                                "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table><hr/>"))
        table = next(b for b in blocks(book, "ch01") if b["kind"] == "table")["table"]
        self.assertEqual(table, {"header": ["A", "B"], "rows": [["1", "2"]]})
        self.assertFails("unsupported-table-shape", documents=changed("ch1.xhtml", "<hr/>",
                         '<table><tbody><tr><td colspan="2">1</td></tr></tbody></table><hr/>'))

    def test_xml_errors_are_positional_only(self):
        self.assertFails("xml-parse-error", documents=changed("ch1.xhtml", "<hr/>", f"<p>{syn.SENTINEL} &nbsp; x</p><hr/>"))


class NavigationTests(FailureAssertions):
    def test_reading_document_missing_from_navigation(self):
        points = [p for p in syn.NAV_POINTS if p[1] != "front.xhtml"]
        self.assertFails("reading-document-not-in-navigation", nav_points=points)

    def test_nav_fragment_missing(self):
        points = [p if p[0] != "Two" else ("Two", "ch2.xhtml#nowhere", []) for p in syn.NAV_POINTS]
        self.assertFails("nav-fragment-missing", nav_points=points)

    def test_nav_pointing_at_printed_contents(self):
        self.assertFails("nav-points-at-printed-contents", nav_points=syn.NAV_POINTS + [("C", "contents.xhtml", [])])

    def test_printed_contents_link_unresolved(self):
        self.assertFails("contents-link-unresolved", documents=changed("contents.xhtml", "ch1.xhtml#s2", "ch1.xhtml#gone"))

    def test_unclassified_spine_document(self):
        documents = dict(syn.DOCUMENTS, **{"extra.xhtml": "<p>Extra</p>"})
        self.assertFails("spine-document-unclassified", documents=documents, spine=syn.SPINE + ["extra.xhtml"])

    def test_xhtml_outside_spine(self):
        self.assertFails("xhtml-outside-spine", extra_xhtml=["orphan.xhtml"])

    def test_configured_document_missing_from_spine(self):
        spine = [h for h in syn.SPINE if h != "front.xhtml"]
        self.assertFails("configured-document-not-in-spine", spine=spine, extra_xhtml=["front.xhtml"])


class PinAndInputTests(FailureAssertions):
    def test_epub_pin(self):
        self.assertFails("epub-pin-mismatch", edition_overrides={"epubSHA256": "0" * 64})

    def test_cover_pin(self):
        self.assertFails("cover-pin-mismatch", edition_overrides={"coverSHA256": "1" * 64})

    def test_chapter_config_required(self):
        data = syn.build()
        edition = syn.edition(data)
        del edition["documents"]["ch2.xhtml"]["access"]
        ws = Workspace()
        try:
            with self.assertRaises(conv.ConversionFailed) as caught:
                conv.convert(ws.epub(data), edition, conv.empty_registry(), {}, None)
        finally:
            ws.close()
        self.assertTrue(any(d.startswith("chapter-access-missing") for d in caught.exception.diagnostics))

    def test_cli_missing_inputs_fail_clearly(self):
        ws = Workspace()
        try:
            err = io.StringIO()
            with redirect_stderr(err), redirect_stdout(io.StringIO()):
                status = conv.main(["convert", "--epub", str(ws.path / "absent.epub"), "--edition", "e.json",
                                    "--new-registry", "--out", str(ws.path / "out")])
            self.assertEqual(status, 2)
            self.assertIn("missing-input: epub", err.getvalue())
            data = syn.build()
            epub = ws.epub(data)
            err = io.StringIO()
            with redirect_stderr(err), redirect_stdout(io.StringIO()):
                status = conv.main(["convert", "--epub", epub, "--edition", str(ws.path / "none.json"),
                                    "--registry", str(ws.path / "none-registry.json"), "--out", str(ws.path / "out")])
            self.assertEqual(status, 2)
            self.assertIn("missing-input: edition", err.getvalue())
            self.assertFalse((ws.path / "out").exists())
        finally:
            ws.close()

    def test_registry_is_never_implicitly_created(self):
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            conv.main(["convert", "--epub", "a", "--edition", "b", "--out", "c"])


class OutputBoundaryTests(unittest.TestCase):
    def test_refuses_output_inside_git_working_tree(self):
        ws = Workspace()
        try:
            repo = temporary_git_repo(ws.path)
            for target in (repo / "out", repo / "nested" / "deeper" / "out"):
                with self.assertRaises(conv.ConversionFailed) as caught:
                    conv.write_outputs(target, {}, {}, {"bundleComplete": False}, None)
                self.assertIn("inside a Git working tree", caught.exception.diagnostics[0])
                self.assertFalse(target.exists())
            err = io.StringIO()
            data = syn.build()
            with redirect_stderr(err), redirect_stdout(io.StringIO()):
                status = conv.main(["convert", "--epub", ws.epub(data), "--edition", "x.json", "--new-registry",
                                    "--out", str(repo / "cli-out")])
            self.assertEqual(status, 2)
            self.assertIn("inside a Git working tree", err.getvalue())
            self.assertFalse((repo / "cli-out").exists())
        finally:
            ws.close()

    def test_refuses_existing_output_and_names_draft_vs_complete(self):
        book, registry, report, extras = convert()
        ws = Workspace()
        try:
            hashes = conv.write_outputs(ws.path / "draft", book, registry, report, extras)
            self.assertEqual(sorted(hashes), ["book.draft.json", "conversion-report.json", "cover.json",
                                              "cover.private.png", "front-matter.json", "id-registry.json"])
            self.assertEqual((ws.path / "draft" / "cover.private.png").read_bytes(), syn.COVER_BYTES)
            front = json.loads((ws.path / "draft" / "front-matter.json").read_text(encoding="utf-8"))
            self.assertEqual(sorted(front), ["contents.xhtml", "cover.xhtml", "title.xhtml"])
            self.assertIn(f"{syn.SENTINEL} Field Notes", front["title.xhtml"]["text"])
            with self.assertRaises(conv.ConversionFailed):
                conv.write_outputs(ws.path / "draft", book, registry, report, extras)
        finally:
            ws.close()

    def test_repeat_conversion_is_byte_identical(self):
        ws = Workspace()
        try:
            outputs = []
            for name in ("a", "b"):
                book, registry, report, extras = convert()
                outputs.append(conv.write_outputs(ws.path / name, book, registry, report, extras))
            self.assertEqual(outputs[0], outputs[1])
        finally:
            ws.close()


class IdentifierTests(FailureAssertions):
    @classmethod
    def setUpClass(cls):
        cls.book, cls.registry, _, _ = convert()

    def reconvert(self, documents=None, migration=None, **kwargs):
        return convert(documents=documents, registry=copy.deepcopy(self.registry), migration=migration, **kwargs)

    def test_ids_are_well_formed_and_unique(self):
        ids = ids_of(self.book)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all(conv.ID_PATTERN.match(i) for i in ids))

    def test_reconversion_with_registry_keeps_every_id(self):
        book, registry, report, _ = self.reconvert()
        self.assertEqual(ids_of(book), ids_of(self.book))
        self.assertEqual(report["ids"]["new"], 0)
        self.assertEqual(registry, self.registry)

    def test_insertion_keeps_existing_ids_and_allocates_a_new_one(self):
        documents = changed("ch1.xhtml", "<hr/>", "<p>Inserted invented paragraph.</p><hr/>")
        book, registry, report, _ = self.reconvert(documents)
        old = ids_of(self.book)
        new = ids_of(book)
        self.assertEqual([i for i in new if i in old], old)
        added = [i for i in new if i not in old]
        self.assertEqual(added, ["ch01.p0011"], "new IDs continue the chapter's ordinal, never reuse positions")
        self.assertEqual(report["ids"], {"matched": len(old), "matchedByAnchor": 0, "matchedByUnchangedDocument": 2,
                                         "assigned": 0, "new": 1, "moved": 0, "migrated": 0, "retired": 0})

    def test_reorder_moves_ids_with_their_content(self):
        documents = changed("ch1.xhtml", "<h3>Minor heading</h3><p>After the divider.</p>",
                            "<p>After the divider.</p><h3>Minor heading</h3>")
        book, _, _, _ = self.reconvert(documents)
        ch1 = blocks(book, "ch01")
        self.assertEqual([(b["id"], b["kind"]) for b in ch1[-2:]], [("ch01.p0010", "paragraph"), ("ch01.h0009", "heading")])

    def test_changed_text_needs_an_explicit_decision(self):
        documents = changed("ch1.xhtml", "<p>After the divider.</p>", "<p>After the divider, revised.</p>")
        diagnostics = self.assertFails("unmatched-registry-id", documents=documents, registry=copy.deepcopy(self.registry))
        self.assertTrue(any("ch01.p0010" in d for d in diagnostics))

        # Keep the same ID for the revised block, explicitly.
        fp = conv.fingerprint({"kind": "paragraph", "text": "After the divider, revised."})
        assign = {"assign": [{"id": "ch01.p0010", "block": {"source": "ch1.xhtml", "fingerprint": fp, "sourceOccurrence": 0}}]}
        book, _, report, _ = self.reconvert(documents, assign)
        self.assertEqual(blocks(book, "ch01")[-1]["id"], "ch01.p0010")
        self.assertEqual(report["ids"]["assigned"], 1)

        # Or give it a new ID and send old anchors there through idMap.
        book, registry, _, _ = self.reconvert(documents, {"migrations": {"ch01.p0010": "ch01.p0011"}})
        self.assertEqual(blocks(book, "ch01")[-1]["id"], "ch01.p0011")
        self.assertEqual(book["idMap"], {"ch01.p0010": "ch01.p0011"})
        self.assertIn("ch01.p0010", registry["retired"])

        # Or retire it; readers then fall back to the quote match or chapter start at run time.
        book, registry, report, _ = self.reconvert(documents, {"retired": ["ch01.p0010"]})
        self.assertNotIn("idMap", book)
        self.assertEqual(report["ids"]["retired"], 1)
        self.assertIn("ch01.p0010", registry["retired"])

    def test_retired_ids_are_never_reused(self):
        documents = changed("ch1.xhtml", "<p>After the divider.</p>", "<p>Replacement text.</p>")
        _, registry, _, _ = self.reconvert(documents, {"retired": ["ch01.p0010"]})
        registry["nextOrdinal"]["ch01"] = 10  # even if the counter were wound back
        book, _, _, _ = convert(documents=changed("ch1.xhtml", "<p>After the divider.</p>", "<p>Replacement text.</p><p>More.</p>"),
                                registry=registry)
        self.assertNotIn("ch01.p0010", ids_of(book))

    def test_identical_blocks_with_changed_count_are_ambiguous(self):
        documents = changed("appendix.xhtml", "<p>Repeated line.</p><p>Repeated line.</p>",
                            "<p>Repeated line.</p><p>Other.</p><p>Repeated line.</p><p>Repeated line.</p>")
        diagnostics = self.assertFails("ambiguous-identical-blocks", documents=documents, registry=copy.deepcopy(self.registry))
        self.assertTrue(any("appx.p0003" in d and "appx.p0004" in d for d in diagnostics))

        fp = conv.fingerprint({"kind": "paragraph", "text": "Repeated line."})
        migration = {"assign": [
            {"id": "appx.p0003", "block": {"source": "appendix.xhtml", "fingerprint": fp, "sourceOccurrence": 0}},
            {"id": "appx.p0004", "block": {"source": "appendix.xhtml", "fingerprint": fp, "sourceOccurrence": 2}},
        ]}
        book, _, _, _ = self.reconvert(documents, migration)
        self.assertEqual([b["id"] for b in blocks(book, "appx")[2:]], ["appx.p0003", "appx.p0005", "appx.p0006", "appx.p0004"])

    def test_same_count_of_identical_blocks_keeps_order(self):
        book, _, _, _ = self.reconvert()
        self.assertEqual([b["id"] for b in blocks(book, "appx")[2:]], ["appx.p0003", "appx.p0004"])

    # Two documents each hold an identical divider (same fingerprint, same count).
    def two_dividers(self, ch1_extra="", ch2_extra="", hr1="<hr/>", hr2="<hr/>"):
        documents = copy.deepcopy(syn.DOCUMENTS)
        documents["ch1.xhtml"] = documents["ch1.xhtml"].replace("<hr/>", hr1) + ch1_extra
        documents["ch2.xhtml"] = documents["ch2.xhtml"] + hr2 + ch2_extra
        return documents

    def divider_ids(self, book):
        return {c["id"]: [b["id"] for b in c["blocks"] if b["kind"] == "divider"] for c in book["chapters"]
                if c["id"] in ("ch01", "ch02")}

    def swapped_spine(self):
        spine = list(syn.SPINE)
        a, b = spine.index("ch1.xhtml"), spine.index("ch2.xhtml")
        spine[a], spine[b] = spine[b], spine[a]
        return spine

    def test_identical_blocks_in_two_documents_keep_their_ids_after_reorder(self):
        book, registry, _, _ = convert(documents=self.two_dividers())
        before = self.divider_ids(book)
        self.assertEqual(len(before["ch01"]) + len(before["ch02"]), 2)
        book, _, report, _ = convert(documents=self.two_dividers(), registry=registry, spine=self.swapped_spine())
        self.assertEqual(self.divider_ids(book), before, "each divider keeps the ID of its own unchanged document")
        self.assertEqual(report["ids"]["moved"], 0)
        self.assertEqual(report["ids"]["new"], 0)
        # The two dividers, plus the appendix's two identical lines.
        self.assertEqual(report["ids"]["matchedByUnchangedDocument"], 4)

    def test_identical_blocks_in_changed_documents_need_evidence(self):
        _, registry, _, _ = convert(documents=self.two_dividers())
        changed_docs = self.two_dividers(ch1_extra="", ch2_extra="<p>New closing words.</p>")
        changed_docs["ch1.xhtml"] = changed_docs["ch1.xhtml"].replace("<p>After the divider.</p>", "<p>After the divider.</p><p>Added.</p>")
        diagnostics = self.assertFails("ambiguous-identical-blocks", documents=changed_docs,
                                       registry=copy.deepcopy(registry), spine=self.swapped_spine())
        joined = " ".join(diagnostics)
        self.assertIn("ch1.xhtml#0", joined)
        self.assertIn("ch2.xhtml#0", joined)

    def test_anchored_identical_blocks_follow_their_anchor(self):
        anchored = dict(hr1='<hr id="break-one"/>', hr2='<hr id="break-two"/>')
        book, registry, _, _ = convert(documents=self.two_dividers(**anchored))
        before = self.divider_ids(book)
        changed_docs = self.two_dividers(ch2_extra="<p>New closing words.</p>", **anchored)
        book, _, report, _ = convert(documents=changed_docs, registry=registry, spine=self.swapped_spine())
        self.assertEqual(self.divider_ids(book), before)
        self.assertEqual(report["ids"]["matchedByAnchor"], 2)

    def test_changed_document_with_same_count_of_duplicates_is_ambiguous(self):
        # Equal counts are not identity: the appendix changed, so its two identical lines can't be told apart.
        documents = changed("appendix.xhtml", "<h2>Worksheet</h2>", "<h2>Worksheet</h2><p>Inserted note.</p>")
        diagnostics = self.assertFails("ambiguous-identical-blocks", documents=documents, registry=copy.deepcopy(self.registry))
        self.assertTrue(any("appx.p0003@appendix.xhtml#0" in d and "appx.p0004@appendix.xhtml#1" in d for d in diagnostics))
        fp = conv.fingerprint({"kind": "paragraph", "text": "Repeated line."})
        migration = {"assign": [
            {"id": "appx.p0003", "block": {"source": "appendix.xhtml", "fingerprint": fp, "sourceOccurrence": 0}},
            {"id": "appx.p0004", "block": {"source": "appendix.xhtml", "fingerprint": fp, "sourceOccurrence": 1}},
        ]}
        book, _, report, _ = self.reconvert(documents, migration)
        self.assertEqual([b["id"] for b in blocks(book, "appx")[-2:]], ["appx.p0003", "appx.p0004"])
        self.assertEqual(report["ids"]["assigned"], 2)

    def test_unique_block_may_move_between_documents(self):
        documents = changed("ch1.xhtml", "<p>After the divider.</p>", "")
        documents["ch2.xhtml"] = documents["ch2.xhtml"] + "<p>After the divider.</p>"
        book, _, report, _ = self.reconvert(documents)
        self.assertEqual(blocks(book, "ch02")[-1]["id"], "ch01.p0010")
        self.assertEqual(report["ids"]["moved"], 1)

    def test_registry_records_document_digests_and_anchors(self):
        self.assertEqual(sorted(self.registry["documents"]),
                         ["appendix.xhtml", "ch1.xhtml", "ch2.xhtml", "copyright.xhtml", "front.xhtml"])
        heading = next(e for e in self.registry["blocks"] if e["id"] == "ch01.h0002")
        self.assertEqual((heading["source"], heading["sourceOccurrence"], heading["anchors"]), ("ch1.xhtml", 0, ["s2"]))
        incomplete = copy.deepcopy(self.registry)
        del incomplete["blocks"][0]["sourceOccurrence"]
        self.assertFails("registry-incomplete-entry", registry=incomplete)

    def test_bad_migration_inputs(self):
        self.assertFails("migration-unknown-id", registry=copy.deepcopy(self.registry), migration={"retired": ["nope.p0001"]})
        self.assertFails("migration-of-active-id", registry=copy.deepcopy(self.registry), migration={"retired": ["ch01.p0001"]})
        self.assertFails("assign-unknown-id", registry=copy.deepcopy(self.registry),
                         migration={"assign": [{"id": "ghost", "block": {"source": "ch1.xhtml", "fingerprint": "0" * 64}}]})

    def test_registry_is_validated(self):
        registry = copy.deepcopy(self.registry)
        registry["blocks"][1]["id"] = registry["blocks"][0]["id"]
        self.assertFails("registry-duplicate-id", registry=registry)
        self.assertFails("registry-format", registry={"format": "other"})

    def test_seeded_authored_ids_are_kept(self):
        registry = copy.deepcopy(self.registry)
        entry = next(e for e in registry["blocks"] if e["id"] == "appx.l0002")
        entry["id"] = "appx.filter.worksheet"
        book, _, _, _ = convert(registry=registry)
        self.assertIn("appx.filter.worksheet", ids_of(book))
        self.assertNotIn("appx.l0002", ids_of(book))


class ToolMappingTests(FailureAssertions):
    FILTER, ROLLOUT = "appx.l0002", "ch01.l0005"

    def test_heading_prompts_keep_source_text_without_an_item_index(self):
        headings = [{"id": f"appx.h{i}", "kind": "heading", "level": 2,
                     "text": f"Question {i}: Sample **prompt**?"} for i in range(1, 6)]
        chapters = [{"id": "appx", "access": "paid", "blocks": headings},
                    {"id": "ch01", "access": "free", "blocks": [
                        {"id": self.ROLLOUT, "kind": "list", "items": ["Plan", "Review"]}]},
                    {"id": "ch02", "access": "paid", "blocks": []}]
        mapping = syn.tools(self.FILTER, self.ROLLOUT)
        mapping["filter"]["prompts"] = [
            {"id": f"filter.q{i}", "block": block["id"]} for i, block in enumerate(headings, 1)]
        diagnostics = conv.Diagnostics()
        result = conv.build_tools(mapping, chapters, diagnostics)
        diagnostics.raise_if_any()
        self.assertEqual([q["text"] for q in result["filterQuestions"]],
                         [b["text"] for b in headings])
        mapping["filter"]["prompts"][0]["item"] = 0
        diagnostics = conv.Diagnostics()
        conv.build_tools(mapping, chapters, diagnostics)
        self.assertTrue(any("tools-item-invalid" in d for d in diagnostics.items))

    def test_tools_copy_exact_source_wording(self):
        book, _, report, _ = convert(tools=syn.tools(self.FILTER, self.ROLLOUT))
        self.assertEqual([q["text"] for q in book["tools"]["filterQuestions"]],
                         ["Pick a task", "Time it", "Try the tool", "Check the result", "Decide"])
        self.assertEqual([q["id"] for q in book["tools"]["rolloutItems"]], ["rollout.s1", "rollout.s2"])
        self.assertEqual((book["tools"]["filterChapterID"], book["tools"]["rolloutChapterID"], book["tools"]["costChapterID"]),
                         ("appx", "ch01", "ch02"))
        self.assertTrue(report["bundleComplete"])

    def test_exactly_five_filter_prompts(self):
        mapping = syn.tools(self.FILTER, self.ROLLOUT)
        mapping["filter"]["prompts"] = mapping["filter"]["prompts"][:4]
        self.assertFails("tools-filter-count", tools=mapping)

    def test_unique_prompt_ids_and_valid_references(self):
        mapping = syn.tools(self.FILTER, self.ROLLOUT)
        mapping["rollout"]["items"][1]["id"] = "rollout.s1"
        self.assertFails("tools-duplicate-id", tools=mapping)
        mapping = syn.tools(self.FILTER, self.ROLLOUT)
        mapping["rollout"]["items"][1]["item"] = 9
        self.assertFails("tools-item-invalid", tools=mapping)
        self.assertFails("tools-block-missing", tools=syn.tools("appx.l9999", self.ROLLOUT))
        self.assertFails("tools-block-outside-chapter", tools=syn.tools(self.FILTER, "appx.l0002"))

    def test_free_filter_from_paid_chapter_must_be_acknowledged(self):
        mapping = syn.tools(self.FILTER, self.ROLLOUT)
        mapping["filter"]["freeToolUsesPaidChapterText"] = False
        self.assertFails("tools-access-boundary", tools=mapping)

    def test_missing_cost_chapter(self):
        mapping = syn.tools(self.FILTER, self.ROLLOUT)
        mapping["cost"]["chapter"] = "nowhere"
        self.assertFails("tools-chapter-missing", tools=mapping)


class EpubLifetimeTests(FailureAssertions):
    """The input EPUB must be free to rename or delete as soon as the converter returns or fails
    (on Windows an open handle blocks both)."""

    def open_handles(self, path):
        fd_dir = Path("/proc/self/fd")
        if not fd_dir.is_dir():
            return 0  # no descriptor listing on this platform; the rename/remove checks still apply
        target = str(Path(path).resolve())
        count = 0
        for fd in fd_dir.iterdir():
            try:
                count += os.readlink(fd) == target
            except OSError:
                pass
        return count

    def assert_released(self, path):
        self.assertEqual(self.open_handles(path), 0)
        moved = Path(path).with_name("renamed.epub")
        os.replace(path, moved)
        os.remove(moved)
        self.assertFalse(moved.exists())

    def run_case(self, data, edition=None, registry=None, expect_failure=None, action="convert"):
        ws = Workspace()
        try:
            path = ws.epub(data)
            if action == "inspect":
                conv.inspect(path)
            elif expect_failure:
                with self.assertRaises(conv.ConversionFailed) as caught:
                    conv.convert(path, edition, registry or conv.empty_registry(), {}, None)
                self.assertTrue(any(d.startswith(expect_failure) for d in caught.exception.diagnostics),
                                caught.exception.diagnostics)
            else:
                conv.convert(path, edition, registry or conv.empty_registry(), {}, None)
            self.assert_released(path)
        finally:
            ws.close()

    def test_released_after_success_and_inspect(self):
        data = syn.build()
        self.run_case(data, syn.edition(data))
        self.run_case(data, action="inspect")

    def test_released_after_failures(self):
        data = syn.build()
        self.run_case(data, syn.edition(data, epubSHA256="0" * 64), expect_failure="epub-pin-mismatch")
        broken = syn.build(documents=changed("ch1.xhtml", "<hr/>", "<pre>x</pre><hr/>"))
        self.run_case(broken, syn.edition(broken), expect_failure="unsupported-element")
        self.run_case(data, syn.edition(data), registry={"format": "old"}, expect_failure="registry-format")

    def test_released_when_the_package_itself_is_invalid(self):
        buffer = io.BytesIO()
        import zipfile
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("mimetype", "application/epub+zip")
        data = buffer.getvalue()
        self.run_case(data, syn.edition(data), expect_failure="missing: META-INF/container.xml")
        self.run_case(b"not a zip", syn.edition(b"not a zip"), expect_failure="not-a-zip")


class TextFidelityTests(FailureAssertions):
    def test_text_between_list_items_fails(self):
        diagnostics = self.assertFails("text-between-list-items", documents=changed(
            "ch1.xhtml", "<li>Fourth step</li><li>Fifth step</li>",
            "<li>Fourth step</li>TEXT_MUST_NOT_DISAPPEAR<li>Fifth step</li>"))
        self.assertTrue(all("TEXT_MUST_NOT_DISAPPEAR" not in d for d in diagnostics))

    def test_loose_text_in_tables_fails(self):
        table = "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td>{loose}<td>2</td></tr></tbody></table>"
        self.assertFails("text-outside-table-cell", documents=changed("ch1.xhtml", "<hr/>", table.format(loose="stray") + "<hr/>"))
        loose_row = "<table><thead><tr><th>A</th></tr></thead><tbody>stray<tr><td>1</td></tr></tbody></table>"
        self.assertFails("text-outside-table-cell", documents=changed("ch1.xhtml", "<hr/>", loose_row + "<hr/>"))

    def test_whole_document_check_catches_any_dropped_text(self):
        data = syn.build()
        ws = Workspace()
        try:
            with zipfile_open(ws.epub(data)) as archive:
                root = conv.parse_xml(archive.read("OEBPS/ch1.xhtml"), "ch1.xhtml")
        finally:
            ws.close()
        diagnostics = conv.Diagnostics()
        converter = conv.DocConverter("ch1.xhtml", root, conv.DEFAULT_PROFILE, diagnostics)
        converter.run()
        conv.verify_document_text("ch1.xhtml", root, converter, diagnostics)
        self.assertEqual(diagnostics.items, [])
        del converter.blocks[4]  # simulate a shape whose text was silently dropped
        conv.verify_document_text("ch1.xhtml", root, converter, diagnostics)
        self.assertEqual(len(diagnostics.items), 1)
        self.assertTrue(diagnostics.items[0].startswith("document-text-mismatch: ch1.xhtml"))
        self.assertNotIn("Fourth", diagnostics.items[0])


class ListNumberRangeTests(FailureAssertions):
    def start(self, value, items=1):
        lis = "".join(f"<li>Item {i}</li>" for i in range(items))
        return changed("ch1.xhtml", '<ol start="4"><li>Fourth step</li><li>Fifth step</li></ol>', f'<ol start="{value}">{lis}</ol>')

    def list_block(self, book):
        return [b for b in blocks(book, "ch01") if b["kind"] == "list"][1]

    def test_signed_64_bit_limits(self):
        top = 2 ** 63 - 1
        book, _, _, _ = convert(documents=self.start(top, 1))
        self.assertEqual(self.list_block(book)["start"], top)
        self.assertFails("list-number-out-of-range", documents=self.start(top, 2))
        self.assertFails("list-number-out-of-range", documents=self.start(top + 1, 1))
        bottom = -(2 ** 63)
        book, _, _, _ = convert(documents=self.start(bottom, 2))
        self.assertEqual(self.list_block(book)["start"], bottom)
        self.assertFails("list-number-out-of-range", documents=self.start(bottom - 1, 1))

    def test_zero_and_negative_starts_are_kept(self):
        for value in (0, -2):
            book, _, _, _ = convert(documents=self.start(value, 2))
            self.assertEqual(self.list_block(book)["start"], value)
        self.assertFails("invalid-list-start", documents=self.start("four", 1))


class PresentationTests(FailureAssertions):
    """Cover, title page and the source's own contents, presented natively."""

    @classmethod
    def setUpClass(cls):
        cls.book, _, cls.report, cls.extras = convert()
        cls.presentation = cls.book["presentation"]

    def test_cover_bytes_alt_and_hash(self):
        cover = self.presentation["cover"]
        self.assertEqual(cover, {"resource": "cover.private.png", "alt": f"{syn.SENTINEL} cover art",
                                 "sha256": hashlib.sha256(syn.COVER_BYTES).hexdigest(), "byteCount": len(syn.COVER_BYTES)})
        self.assertEqual(self.extras["cover"]["data"], syn.COVER_BYTES)

    def test_title_page_keeps_exact_text_order_roles_and_styles(self):
        self.assertEqual(self.presentation["titlePage"]["elements"], [
            {"role": "title", "text": f"{syn.SENTINEL} *Field* Notes"},
            {"role": "author", "text": "Example **Studio** with `v2`"},
        ])

    def test_contents_follow_source_order_depth_and_targets(self):
        entries = [(e["label"], e["depth"], e["target"]) for e in self.presentation["contents"]]
        self.assertEqual(entries, [
            ("Cover", 1, {"kind": "cover"}),
            ("Title", 1, {"kind": "titlePage"}),
            ("Copyright", 1, {"kind": "chapter", "chapterID": "copyright"}),
            ("Before", 1, {"kind": "chapter", "chapterID": "front"}),
            ("One", 1, {"kind": "chapter", "chapterID": "ch01"}),
            ("Styles", 2, {"kind": "block", "chapterID": "ch01", "blockID": "ch01.h0002"}),
            ("Two", 1, {"kind": "block", "chapterID": "ch02", "blockID": "ch02.c0001"}),
            ("Appendix", 1, {"kind": "chapter", "chapterID": "appx"}),
        ])
        # Every reading section is still a chapter, and no front-matter text was added to them.
        self.assertEqual(len(self.book["chapters"]), 5)
        self.assertNotIn("Contents", json.dumps(self.book["chapters"]))

    def test_report_counts_without_prose(self):
        self.assertEqual(self.report["presentation"], {
            "cover": True, "titlePageElements": 2, "contentsEntries": 8, "contentsByDepth": {"1": 7, "2": 1},
            "contentsTargets": {"cover": 1, "titlePage": 1, "chapter": 4, "block": 2},
            "contentsSources": ["ncx", "nav", "printed"]})
        text = json.dumps(self.report)
        for phrase in (syn.SENTINEL, "Field Notes", "Studio", "Styles", "Appendix", "cover art"):
            self.assertNotIn(phrase, text)

    def test_cover_shape_failures(self):
        cover = syn.DOCUMENTS["cover.xhtml"]
        self.assertFails("unsupported-cover-shape", documents=dict(syn.DOCUMENTS, **{
            "cover.xhtml": cover.replace("</div>", '<img src="images/cover.png" alt="x"/></div>')}))
        self.assertFails("unsupported-cover-shape", documents=dict(syn.DOCUMENTS, **{
            "cover.xhtml": cover.replace("</div>", "<p>Words</p></div>")}))
        self.assertFails("cover-image-mismatch", documents=dict(syn.DOCUMENTS, **{
            "cover.xhtml": cover.replace("images/cover.png", "images/other.png")}))
        self.assertFails("cover-alt-missing", documents=dict(syn.DOCUMENTS, **{
            "cover.xhtml": cover.replace(f'alt="{syn.SENTINEL} cover art"', 'alt=" "')}))

    def test_title_page_failures(self):
        self.assertFails("unsupported-title-page-element", documents=changed(
            "title.xhtml", '<p class="author">', '<ul><li>x</li></ul><p class="author">'))
        self.assertFails("unsupported-title-page-element", documents=changed(
            "title.xhtml", '<p class="author">', '<p class="subtitle">'))
        self.assertFails("unsupported-title-page-shape", documents=changed(
            "title.xhtml", "</h1>", "</h1>loose words"))
        self.assertFails("unsupported-title-page-shape", documents=changed(
            "title.xhtml", '<section class="title-page" epub:type="titlepage">', '<section class="other">'))
        self.assertFails("unsupported-inline-element", documents=changed("title.xhtml", "<em>Field</em>", "<sup>Field</sup>"))

    def test_contents_sources_must_agree(self):
        self.assertFails("contents-sources-disagree", documents=changed("contents.xhtml", ">Styles<", ">Stylez<"))
        self.assertFails("contents-sources-disagree", documents=changed(
            "contents.xhtml", '<li><a href="ch2.xhtml#top">Two</a></li>', ""))
        self.assertFails("contents-sources-disagree", documents=changed(
            "contents.xhtml", 'href="appendix.xhtml"', 'href="ch2.xhtml"'))
        # Depth: the nested entry moved to the top level in the nav document only.
        flattened = [p for p in syn.NAV_POINTS if p[0] != "One"] + [("One", "ch1.xhtml", []), ("Styles", "ch1.xhtml#s2", [])]
        self.assertFails("contents-sources-disagree", nav_doc_points=flattened)

    def test_contents_shapes_that_are_not_supported(self):
        self.assertFails("unsupported-contents-label", documents=changed("contents.xhtml", ">Styles<", "><em>Styles</em><"))
        self.assertFails("unsupported-contents-shape", documents=changed(
            "contents.xhtml", "<h1>Contents</h1>", "<h1>Contents</h1><p>intro</p>"))

    def test_presentation_without_cover_or_title_page(self):
        spine = [h for h in syn.SPINE if h not in ("cover.xhtml", "title.xhtml")]
        points = [p for p in syn.NAV_POINTS if p[1] not in ("cover.xhtml", "title.xhtml")]
        documents = dict(syn.DOCUMENTS, **{"contents.xhtml": syn.printed_contents(points)})
        data = syn.build(documents=documents, spine=spine, nav_points=points, cover=False)
        edition = syn.edition(data)
        for href in ("cover.xhtml", "title.xhtml"):
            del edition["documents"][href]
        ws = Workspace()
        try:
            book, _, report, extras = conv.convert(ws.epub(data), edition, conv.empty_registry(), {}, None)
        finally:
            ws.close()
        self.assertEqual(sorted(book["presentation"]), ["contents"])
        self.assertIsNone(extras["cover"])
        self.assertEqual(report["presentation"]["contentsTargets"], {"cover": 0, "titlePage": 0, "chapter": 4, "block": 2})


class OutputPathSafetyTests(FailureAssertions):
    """No output can land outside, or overwrite anything in, the chosen output folder."""

    def snapshot(self, folder):
        return {str(p.relative_to(folder)): p.read_bytes() for p in folder.rglob("*") if p.is_file()}

    def test_cover_resource_name_is_fixed(self):
        book, _, _, extras = convert()
        self.assertEqual(book["presentation"]["cover"]["resource"], "cover.private.png")
        self.assertEqual(extras["cover"]["resource"], "cover.private.png")
        diagnostics = self.assertFails("unsupported-edition-key", edition_overrides={"coverResourceName": "../escaped-cover"})
        self.assertEqual(diagnostics, ["unsupported-edition-key: coverResourceName"])

    def test_unsupported_cover_format_fails(self):
        documents = dict(syn.DOCUMENTS, **{"cover.xhtml": syn.DOCUMENTS["cover.xhtml"].replace("images/cover.png", "images/cover.gif")})
        self.assertFails("unsupported-cover-format", documents=documents, cover_href="images/cover.gif")
        documents = dict(syn.DOCUMENTS, **{"cover.xhtml": syn.DOCUMENTS["cover.xhtml"].replace("images/cover.png", "images/cover.jpeg")})
        book, _, _, _ = convert(documents=documents, cover_href="images/cover.jpeg")
        self.assertEqual(book["presentation"]["cover"]["resource"], "cover.private.jpeg")

    def test_tampered_output_names_write_nothing_anywhere(self):
        book, registry, report, extras = convert()
        ws = Workspace()
        try:
            (ws.path / "existing.png").write_bytes(b"keep")
            (ws.path / "sub").mkdir()
            before = self.snapshot(ws.path)
            for name in ("../escaped-cover.png", str(ws.path / "absolute-cover.png"), "..\\escaped-cover.png",
                         "C:\\escaped-cover.png", "sub/cover.private.png", "existing.png", "book.private.json",
                         "id-registry.json", "cover.private.gif", ".", ""):
                with self.subTest(name=name):
                    tampered = dict(extras, cover=dict(extras["cover"], resource=name))
                    with self.assertRaises(conv.ConversionFailed):
                        conv.write_outputs(ws.path / "out", book, registry, report, tampered)
                    self.assertFalse((ws.path / "out").exists(), "the output folder isn't even created")
                    self.assertEqual(self.snapshot(ws.path), before, "nothing outside was written or overwritten")
                    self.assertFalse((ws.path.parent / "escaped-cover.png").exists())
        finally:
            ws.close()

    def test_printed_contents_tail_text_fails(self):
        diagnostics = self.assertFails("unsupported-contents-shape", documents=changed(
            "contents.xhtml", "</section>", "</section>Unsupported synthetic tail text."))
        self.assertTrue(any("text after the contents section" in d for d in diagnostics))
        self.assertTrue(all("Unsupported synthetic" not in d for d in diagnostics))


class PrivateOutputGuardTests(unittest.TestCase):
    """The public boundary: private outputs are ignored by Git and detected in app bundles."""

    APP = HERE.parent.parent
    GUARD = APP / "ci" / "check-no-private-content.sh"
    PRIVATE_NAMES = ["book.private.json", "book.draft.json", "id-registry.json", "conversion-report.json",
                     "front-matter.json", "cover.json", "cover.private.jpg", "cover.private.jpeg", "cover.private.png",
                     "source.epub", "Book.EPUB",
                     # Legacy candidate02 cover outputs.
                     "cover.jpg", "cover.jpeg", "cover.png"]

    def test_converter_outputs_are_all_covered(self):
        book, registry, report, extras = convert()
        ws = Workspace()
        try:
            written = conv.write_outputs(ws.path / "out", book, registry, report, extras)
        finally:
            ws.close()
        for name in written:
            self.assertTrue(name in self.PRIVATE_NAMES or name.replace("draft", "private") in self.PRIVATE_NAMES, name)

    @unittest.skipUnless(shutil.which("git"), "git is needed to evaluate .gitignore")
    def test_gitignore_ignores_every_private_output(self):
        ws = Workspace()
        try:
            repo = temporary_git_repo(ws.path)
            shutil.copy(self.APP / ".gitignore", repo / ".gitignore")
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(ws.path / "isolated-gitconfig"))
            for relative in self.PRIVATE_NAMES + ["AIBible/Resources/Private/anything.json", "sub/dir/front-matter.json"]:
                result = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", relative], env=env)
                self.assertEqual(result.returncode, 0, f"{relative} is not ignored")
            for public in ("AIBible/Resources/Fixtures/book.fixture.json", "AIBibleTests/ConverterSample/converter-sample.json",
                           "AIBible/Resources/Fixtures/presentation.fixture.json",
                           "AIBible/Resources/Fixtures/presentation-fixture-cover.png",
                           "AIBibleTests/ConverterSample/synthetic-sample-cover.png", "converter/templates/edition.template.json"):
                result = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", public], env=env)
                self.assertEqual(result.returncode, 1, f"{public} must stay tracked")
        finally:
            ws.close()

    @unittest.skipUnless(shutil.which("bash"), "the packaging guard is a POSIX bash script; bash is not installed")
    def test_bundle_guard_flags_each_private_file(self):
        ws = Workspace()
        try:
            app = ws.path / "AIBible.app"
            (app / "PlugIns" / "AIBibleTests.xctest").mkdir(parents=True)
            for name in ("book.fixture.json", "presentation.fixture.json", "presentation-fixture-cover.png",
                         "PrivacyInfo.xcprivacy"):
                (app / name).write_text("{}", encoding="utf-8")
            for name in ("converter-sample.json", "malformed-selected.json", "synthetic-sample-cover.png"):
                (app / "PlugIns" / "AIBibleTests.xctest" / name).write_text("{}", encoding="utf-8")
            clean = subprocess.run(["bash", self.GUARD.as_posix(), app.as_posix()], capture_output=True, text=True)
            self.assertEqual(clean.returncode, 0, clean.stderr)
            # The bundle guard also matches legacy cover names in any letter case.
            for name in self.PRIVATE_NAMES + ["COVER.PNG", "Cover.Jpeg"]:
                with self.subTest(name=name):
                    offending = app / "nested" / name
                    offending.parent.mkdir(exist_ok=True)
                    offending.write_text("private", encoding="utf-8")
                    result = subprocess.run(["bash", self.GUARD.as_posix(), app.as_posix()], capture_output=True, text=True)
                    offending.unlink()
                    self.assertEqual(result.returncode, 1, name)
                    self.assertIn(name, result.stderr)
                    self.assertNotIn("private\n", result.stderr, "file contents are never printed")
        finally:
            ws.close()


class RoundTripGuardTests(FailureAssertions):
    def test_escaping_fault_is_caught_by_round_trip(self):
        original = conv.escape_md
        conv.escape_md = lambda text: text
        try:
            self.assertFails("round-trip-mismatch")
        finally:
            conv.escape_md = original

    def test_dropped_text_is_caught_by_round_trip(self):
        original = conv.escape_md
        conv.escape_md = lambda text: original(text.replace("Fifth", ""))
        try:
            self.assertFails("round-trip-mismatch")
        finally:
            conv.escape_md = original


SAMPLE_DIR = HERE.parent.parent / "AIBibleTests" / "ConverterSample"
# A resource name the public packaging guard doesn't treat as private, since test bundles are
# embedded in hosted-test app builds.
SAMPLE_COVER_NAME = "synthetic-sample-cover"


def renamed_cover(result, stem):
    """Test fixtures only: after conversion, give the synthetic cover a public test-resource name
    in memory. The converter itself always writes cover.private.<ext>."""
    book, registry, report, extras = result
    resource = stem + posixpath.splitext(book["presentation"]["cover"]["resource"])[1]
    book["presentation"]["cover"]["resource"] = resource
    extras["cover"]["resource"] = resource
    return book, registry, report, extras


def swift_sample():
    return renamed_cover(convert(tools=syn.tools("appx.l0002", "ch01.l0005")), SAMPLE_COVER_NAME)


FIXTURE_DIR = HERE.parent.parent / "AIBible" / "Resources" / "Fixtures"
PRESENTATION_FIXTURE_COVER = "presentation-fixture-cover"


def presentation_fixture():
    """The synthetic edition a Debug-only UI test selects (presentation.fixture.json): the
    converter's own output for the synthetic EPUB, marked as a fixture."""
    book, _, _, extras = renamed_cover(convert(tools=syn.tools("appx.l0002", "ch01.l0005"), edition_overrides={
        "contentVersion": "fixture-presentation-2026-09-28.1",
        "title": "AI Bible presentation (test fixture)"}), PRESENTATION_FIXTURE_COVER)
    book["isFixture"] = True
    return book, extras["cover"]["data"]


class SwiftSampleTests(unittest.TestCase):
    def test_committed_presentation_fixture_matches_the_converter(self):
        book, cover = presentation_fixture()
        self.assertEqual((FIXTURE_DIR / "presentation.fixture.json").read_text(encoding="utf-8"), conv.pretty_json(book))
        self.assertEqual((FIXTURE_DIR / (PRESENTATION_FIXTURE_COVER + ".png")).read_bytes(), cover)

    def test_committed_swift_sample_matches_the_converter(self):
        """AIBibleTests/ConverterSample holds this converter's output for the synthetic EPUB: the book
        JSON and its cover. The Swift tests decode them, so they must not drift from the converter."""
        book, _, _, extras = swift_sample()
        self.assertEqual((SAMPLE_DIR / "converter-sample.json").read_text(encoding="utf-8"), conv.pretty_json(book))
        cover = book["presentation"]["cover"]
        self.assertEqual(cover["resource"], SAMPLE_COVER_NAME + ".png")
        self.assertEqual((SAMPLE_DIR / cover["resource"]).read_bytes(), extras["cover"]["data"])


@unittest.skipUnless(shutil.which("bash"), "the private staging script is a POSIX bash script; bash is not installed")
class StagingScriptTests(unittest.TestCase):
    """Checks the private staging script's refusals. Every case stops before any build.
    The build itself needs macOS and Xcode and is never exercised here."""

    SCRIPT = HERE.parent / "stage-private-build.sh"
    SAMPLE = HERE.parent.parent / "AIBibleTests" / "ConverterSample" / "converter-sample.json"
    SAMPLE_COVER = HERE.parent.parent / "AIBibleTests" / "ConverterSample" / "synthetic-sample-cover.png"

    def run_script(self, *args, env_extra=None):
        env = dict(os.environ, **(env_extra or {}))
        result = subprocess.run(["bash", self.SCRIPT.as_posix(), *args], capture_output=True, text=True,
                                env=env, timeout=60)
        return result.returncode, result.stderr

    def base_args(self, work, sha=None, book=None, cover="sample", cover_sha=None):
        book = Path(book or self.SAMPLE)
        sha = sha or hashlib.sha256(book.read_bytes()).hexdigest() if book.exists() else sha or "0" * 64
        args = ["--book", book.as_posix(), "--expect-sha256", sha, "--work", Path(work).as_posix(),
                "--xcodegen", "/nonexistent/xcodegen", "--destination", "platform=iOS Simulator,id=none"]
        if cover == "sample":
            cover = self.SAMPLE_COVER
        if cover is not None:
            cover = Path(cover)
            cover_sha = cover_sha or (hashlib.sha256(cover.read_bytes()).hexdigest() if cover.exists() else "0" * 64)
            args += ["--cover", cover.as_posix(), "--expect-cover-sha256", cover_sha]
        return args

    def test_refusals(self):
        ws = Workspace()
        try:
            work = ws.path / "stage"
            status, err = self.run_script("--book", self.SAMPLE.as_posix())
            self.assertNotEqual(status, 0)
            self.assertIn("are all required", err)
            status, err = self.run_script(*self.base_args(work, book=ws.path / "absent.json"))
            self.assertIn("not found", err)
            status, err = self.run_script(*self.base_args(work, sha="0" * 64))
            self.assertIn("does not match", err)
            fixture = HERE.parent.parent / "AIBible" / "Resources" / "Fixtures" / "book.fixture.json"
            status, err = self.run_script(*self.base_args(work, book=fixture, cover=None))
            self.assertIn("not a complete, non-fixture edition", err)
            # A valid private-shaped bundle still stops before building here (no macOS, or no xcodegen).
            status, err = self.run_script(*self.base_args(work), env_extra={"DEVELOPER_DIR": "/nonexistent"})
            self.assertNotEqual(status, 0)
            self.assertTrue(any(m in err for m in ("needs macOS", "DEVELOPER_DIR", "xcodegen not executable")), err)
            self.assertFalse(work.exists(), "nothing is staged when a check fails")
        finally:
            ws.close()

    def test_cover_must_be_the_declared_reviewed_file(self):
        ws = Workspace()
        try:
            work = ws.path / "stage"
            status, err = self.run_script(*self.base_args(work, cover=None))
            self.assertIn("--cover and --expect-cover-sha256 are required", err)
            status, err = self.run_script(*self.base_args(work, cover=ws.path / "absent.png"))
            self.assertIn("cover file not found", err)
            status, err = self.run_script(*self.base_args(work, cover_sha="1" * 64))
            self.assertIn("cover SHA-256 does not match", err)
            other = ws.path / "other.png"
            other.write_bytes(b"not the declared cover")
            status, err = self.run_script(*self.base_args(work, cover=other))
            self.assertIn("differs from the one the book declares", err)
            # A book without a cover must not be given one.
            no_cover = json.loads(self.SAMPLE.read_text(encoding="utf-8"))
            del no_cover["presentation"]["cover"]
            no_cover["presentation"]["contents"] = [e for e in no_cover["presentation"]["contents"]
                                                    if e["target"]["kind"] != "cover"]
            book = ws.path / "no-cover.json"
            book.write_text(json.dumps(no_cover), encoding="utf-8")
            status, err = self.run_script(*self.base_args(work, book=book))
            self.assertIn("book declares no cover", err)
            self.assertFalse(work.exists())
        finally:
            ws.close()

    def test_refuses_work_folder_inside_a_git_working_tree(self):
        ws = Workspace()
        try:
            repo = temporary_git_repo(ws.path)
            status, err = self.run_script(*self.base_args(repo / "stage"))
            self.assertNotEqual(status, 0)
            self.assertIn("outside any Git working tree", err)
            self.assertFalse((repo / "stage").exists())
        finally:
            ws.close()


class TemplateTests(unittest.TestCase):
    def test_edition_template_matches_the_structural_evidence(self):
        template = json.loads((HERE.parent / "templates" / "edition.template.json").read_text(encoding="utf-8"))
        roles = [d["role"] for d in template["documents"].values()]
        self.assertEqual(roles.count("reading"), 17)
        self.assertEqual(sorted(r for r in roles if r != "reading"), ["cover", "printedContents", "titlePage"])
        chapters = [d for d in template["documents"].values() if d.get("chapterID", "").startswith("ch")]
        self.assertEqual(len(chapters), 14)
        self.assertEqual([d["chapterID"] for d in chapters if d["access"] == "free"], ["ch01"])
        self.assertEqual(template["expectedCensus"]["ol"], 27)
        # The template is not a usable config until its placeholders are replaced.
        data = syn.build()
        ws = Workspace()
        try:
            with self.assertRaises(conv.ConversionFailed):
                conv.convert(ws.epub(data), template, conv.empty_registry(), {}, None)
        finally:
            ws.close()


class InlineMarkdownTests(unittest.TestCase):
    def test_escape_round_trip(self):
        for text in ("a*b_c", "[x](y)", "<b>&amp;", "back\\slash", "~~", "!["):
            with self.subTest(text=text):
                self.assertEqual(conv.decode_markdown(conv.escape_md(text))[0], text)

    def test_strict_decoder_rejects_unescaped_specials(self):
        for markdown in ("a*b", "a_b", "`open", "[x]", "a\\b", "**open"):
            with self.subTest(markdown=markdown):
                with self.assertRaises(conv.MalformedMarkdown):
                    conv.decode_markdown(markdown)

    def test_nested_emphasis_counts(self):
        self.assertEqual(conv.decode_markdown("***both*** and *a **b** c*"),
                         ("both and a b c", {"strong": 2, "em": 2, "code": 0, "link": 0}))


if __name__ == "__main__":
    unittest.main()
