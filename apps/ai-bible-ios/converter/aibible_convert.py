#!/usr/bin/env python3
"""Generic local EPUB -> BookBundle converter for the AI Bible reader.

Standard library only. It runs on the owner's machine against a privately held,
pinned EPUB. Nothing is uploaded, and nothing it prints contains book text:
diagnostics name files, element paths, tags, classes and counts only.

Subcommands
  inspect   Non-prose structure report of an EPUB (spine, navigation, census).
  convert   EPUB + edition config + ID registry (+ tool mapping) -> private output folder.

The output folder must be outside any Git working tree and must not exist yet.
See converter/README.md for the input formats and the ID rules.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import posixpath
import re
import sys
import unicodedata
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

XHTML = "http://www.w3.org/1999/xhtml"
OPS = "http://www.idpf.org/2007/ops"
OPF = "http://www.idpf.org/2007/opf"
NCX = "http://www.daisy.org/z3986/2005/ncx/"
CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container"

REGISTRY_FORMAT = "aibible-id-registry/2"
EDITION_FORMAT = "aibible-edition/1"
TOOLS_FORMAT = "aibible-tools/1"
REPORT_FORMAT = "aibible-conversion-report/1"

# The cover is always written and packaged as cover.private.<ext>, for these source formats only.
COVER_RESOURCE_STEM = "cover.private"
COVER_EXTENSIONS = {".jpg", ".jpeg", ".png"}
# Edition keys the converter no longer honours; rejected rather than silently ignored.
REMOVED_EDITION_KEYS = {"coverResourceName"}

MAX_ERRORS = 50
INT64_MIN = -(2 ** 63)
INT64_MAX = 2 ** 63 - 1
MAX_ENTRY_BYTES = 64 * 1024 * 1024
MAX_ENTRIES = 2000

ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
RAW_URL = re.compile(r"https?://[^\s<>\"]+")
KIND_PREFIX = {
    "heading": "h", "paragraph": "p", "list": "l", "quote": "q",
    "note": "n", "divider": "d", "cards": "c", "table": "t",
}
# Characters escaped in every text run so inline Markdown renders them literally.
MD_SPECIAL = set("\\`*_[]<>&~!")

DEFAULT_PROFILE = {
    "sourceNoteClasses": ["source-notes"],
    "cardGroupClass": "table-cards",
    "cardClass": "table-card",
    "fieldClass": "table-field",
    "labelClass": "table-label",
    "valueClass": "table-value",
    "cardTitleClass": "table-card-title",
    "blankFieldClass": "blank-field",
    "titlePageClass": "title-page",
    "authorClass": "author",
    # Wrapper elements whose classes carry no reading semantics (transparent).
    "transparentContainerClasses": [],
    "transparentSpanClasses": [],
}


class ConversionFailed(Exception):
    """Raised with bounded, non-prose diagnostics."""

    def __init__(self, diagnostics):
        self.diagnostics = list(diagnostics)[:MAX_ERRORS]
        super().__init__("\n".join(self.diagnostics))


class Diagnostics:
    def __init__(self):
        self.items = []

    def add(self, code, where, detail=""):
        if len(self.items) < MAX_ERRORS:
            self.items.append(f"{code}: {where}" + (f" ({detail})" if detail else ""))

    def raise_if_any(self):
        if self.items:
            raise ConversionFailed(self.items)


def local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def classes(el):
    return set((el.get("class") or "").split())


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def pretty_json(value):
    return json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------------------
# EPUB container

@dataclass
class ManifestItem:
    id: str
    href: str          # relative to the OPF folder, percent-decoded
    media_type: str
    properties: set


@dataclass
class Epub:
    sha256: str
    size: int
    zip: zipfile.ZipFile
    opf_dir: str
    manifest: dict      # id -> ManifestItem
    spine: list         # [(href, linear)]
    ncx_href: str | None
    nav_href: str | None
    cover_href: str | None

    def read(self, href):
        name = posixpath.join(self.opf_dir, href) if self.opf_dir else href
        info = self.zip.getinfo(name)
        if info.file_size > MAX_ENTRY_BYTES:
            raise ConversionFailed([f"entry-too-large: {href} ({info.file_size} bytes)"])
        return self.zip.read(name)

    def by_href(self):
        return {item.href: item for item in self.manifest.values()}

    def close(self):
        self.zip.close()


def parse_xml(data, where):
    try:
        return ET.fromstring(data)
    except ET.ParseError as error:
        line, column = error.position
        raise ConversionFailed([f"xml-parse-error: {where} (line {line}, column {column})"])


def open_epub(path):
    """Reads the EPUB fully into memory, so no handle on the input file outlives this call.
    The in-memory archive is closed here on any failure; callers close the returned Epub."""
    data = Path(path).read_bytes()
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        raise ConversionFailed([f"not-a-zip: {Path(path).name}"])
    try:
        return _read_package(archive, data)
    except BaseException:
        archive.close()
        raise


def _read_package(archive, data):
    names = archive.namelist()
    if len(names) > MAX_ENTRIES:
        raise ConversionFailed([f"too-many-entries: {len(names)}"])
    for name in names:
        if name.startswith("/") or ".." in name.split("/"):
            raise ConversionFailed([f"unsafe-entry-name: entry {names.index(name)}"])
    if "META-INF/container.xml" not in names:
        raise ConversionFailed(["missing: META-INF/container.xml"])
    container = parse_xml(archive.read("META-INF/container.xml"), "META-INF/container.xml")
    rootfile = container.find(f".//{{{CONTAINER}}}rootfile")
    if rootfile is None or not rootfile.get("full-path"):
        raise ConversionFailed(["missing: container rootfile"])
    opf_path = rootfile.get("full-path")
    opf_dir = posixpath.dirname(opf_path)
    opf = parse_xml(archive.read(opf_path), opf_path)

    manifest = {}
    for item in opf.iter(f"{{{OPF}}}item"):
        href = unquote(item.get("href", ""))
        manifest[item.get("id")] = ManifestItem(
            id=item.get("id"), href=href, media_type=item.get("media-type", ""),
            properties=set((item.get("properties") or "").split()),
        )
    spine_el = opf.find(f"{{{OPF}}}spine")
    if spine_el is None:
        raise ConversionFailed(["missing: OPF spine"])
    spine = []
    diagnostics = Diagnostics()
    for ref in spine_el.iter(f"{{{OPF}}}itemref"):
        item = manifest.get(ref.get("idref"))
        if item is None:
            diagnostics.add("spine-idref-missing", f"itemref {ref.get('idref')}")
            continue
        spine.append((item.href, ref.get("linear", "yes") != "no"))
    diagnostics.raise_if_any()

    ncx_href = None
    toc_id = spine_el.get("toc")
    if toc_id and toc_id in manifest:
        ncx_href = manifest[toc_id].href
    nav_href = next((i.href for i in manifest.values() if "nav" in i.properties), None)

    cover_href = next((i.href for i in manifest.values() if "cover-image" in i.properties), None)
    if cover_href is None:
        meta = next((m for m in opf.iter(f"{{{OPF}}}meta") if m.get("name") == "cover"), None)
        if meta is not None and meta.get("content") in manifest:
            cover_href = manifest[meta.get("content")].href

    for href in [h for h, _ in spine] + [h for h in (ncx_href, nav_href, cover_href) if h]:
        name = posixpath.join(opf_dir, href) if opf_dir else href
        if name not in names:
            diagnostics.add("manifest-file-missing", href)
    diagnostics.raise_if_any()
    return Epub(sha256_bytes(data), len(data), archive, opf_dir, manifest, spine, ncx_href, nav_href, cover_href)


def resolve_href(base_doc, href):
    """Resolves an href found in `base_doc` to (doc, fragment); doc is None for external links."""
    parts = urlsplit(href)
    if parts.scheme or parts.netloc:
        return None, None
    path = unquote(parts.path)
    doc = posixpath.normpath(posixpath.join(posixpath.dirname(base_doc), path)) if path else base_doc
    return doc, unquote(parts.fragment) or None


def element_ids(root):
    return {el.get("id") for el in root.iter() if el.get("id")}


# ---------------------------------------------------------------------------
# Navigation

def ncx_points(epub):
    if not epub.ncx_href:
        return []
    root = parse_xml(epub.read(epub.ncx_href), epub.ncx_href)
    nav_map = root.find(f"{{{NCX}}}navMap")
    points = []

    def walk(parent, depth):
        for point in parent.findall(f"{{{NCX}}}navPoint"):
            content = point.find(f"{{{NCX}}}content")
            label = point.find(f"{{{NCX}}}navLabel/{{{NCX}}}text")
            src = content.get("src") if content is not None else None
            doc, fragment = resolve_href(epub.ncx_href, src) if src else (None, None)
            points.append({
                "depth": depth, "doc": doc, "fragment": fragment,
                "label": collapse_ws(label.text or "").strip() if label is not None else "",
            })
            walk(point, depth + 1)

    if nav_map is not None:
        walk(nav_map, 1)
    return points


def nav_doc_links(epub):
    if not epub.nav_href:
        return []
    root = parse_xml(epub.read(epub.nav_href), epub.nav_href)
    links = []
    for nav in root.iter(f"{{{XHTML}}}nav"):
        if "toc" not in (nav.get(f"{{{OPS}}}type") or "").split():
            continue
        for a in nav.iter(f"{{{XHTML}}}a"):
            if a.get("href"):
                links.append(resolve_href(epub.nav_href, a.get("href")))
    return links


# ---------------------------------------------------------------------------
# Census (non-prose structure counts)

CENSUS_KEYS = [
    "h1", "h2", "h3", "h4", "h5", "h6", "p", "ol", "ul", "li", "olWithStart", "blockquote", "blockquoteP",
    "aside", "asideSourceNotes", "hr", "table", "pre", "img", "svg", "math", "audio", "video", "figure",
    "strong", "b", "em", "i", "code", "br", "aHref", "aInternal", "aExternal", "rawURLs",
    "cardGroups", "cards", "fields", "labels", "values", "cardTitles", "blankFields", "blankFieldsWithAria",
    "ariaLabels", "elementIDs", "maxListDepth",
]


def census(root, profile):
    counts = {key: 0 for key in CENSUS_KEYS}
    body = root.find(f"{{{XHTML}}}body")
    if body is None:
        return counts

    def list_depth(el, depth):
        name = local(el.tag)
        here = depth + 1 if name in ("ol", "ul") else depth
        counts["maxListDepth"] = max(counts["maxListDepth"], here)
        for child in el:
            list_depth(child, here)

    list_depth(body, 0)
    for el in body.iter():
        name = local(el.tag)
        cls = classes(el)
        if name in counts and name not in ("maxListDepth",):
            counts[name] += 1
        if name == "ol" and el.get("start") is not None:
            counts["olWithStart"] += 1
        if name == "aside" and cls & set(profile["sourceNoteClasses"]):
            counts["asideSourceNotes"] += 1
        if name == "a" and el.get("href"):
            counts["aHref"] += 1
            doc, _ = resolve_href("x.xhtml", el.get("href"))
            counts["aInternal" if doc is not None else "aExternal"] += 1
        if profile["cardGroupClass"] in cls:
            counts["cardGroups"] += 1
        if profile["cardClass"] in cls:
            counts["cards"] += 1
        if profile["fieldClass"] in cls:
            counts["fields"] += 1
        if profile["labelClass"] in cls:
            counts["labels"] += 1
        if profile["valueClass"] in cls:
            counts["values"] += 1
        if profile["cardTitleClass"] in cls:
            counts["cardTitles"] += 1
        if profile["blankFieldClass"] in cls:
            counts["blankFields"] += 1
            if el.get("aria-label"):
                counts["blankFieldsWithAria"] += 1
        if el.get("aria-label") is not None:
            counts["ariaLabels"] += 1
        if el.get("id"):
            counts["elementIDs"] += 1
        for text in (el.text, el.tail if el is not body else None):
            if text:
                counts["rawURLs"] += len(RAW_URL.findall(text))
    for quote in body.iter(f"{{{XHTML}}}blockquote"):
        counts["blockquoteP"] += sum(1 for child in quote if local(child.tag) == "p")
    return counts


def add_counts(total, counts):
    for key, value in counts.items():
        if key == "maxListDepth":
            total[key] = max(total.get(key, 0), value)
        else:
            total[key] = total.get(key, 0) + value


# ---------------------------------------------------------------------------
# Inline conversion

@dataclass
class Tok:
    kind: str            # text | open | close | code | blank | link_open | link_close
    value: str = ""      # text, delimiter, code text, url
    extra: str = ""      # blank accessibility label


def escape_md(text):
    return "".join("\\" + ch if ch in MD_SPECIAL else ch for ch in text)


def collapse_ws(text):
    return re.sub(r"[ \t\n\r\f]+", " ", text)


class InlineContext:
    def __init__(self, doc, path, profile, diagnostics, allow_blanks=False):
        self.doc = doc
        self.path = path
        self.profile = profile
        self.diagnostics = diagnostics
        self.allow_blanks = allow_blanks
        self.anchors = []
        self.counts = {"strong": 0, "em": 0, "code": 0, "blank": 0, "link": 0}

    def fail(self, code, el, detail=""):
        self.diagnostics.add(code, f"{self.doc} {self.path}/{local(el.tag)}", detail)


def inline_tokens(el, ctx, include_self_text=True):
    tokens = []
    if el.get("id"):
        ctx.anchors.append(el.get("id"))
    if include_self_text and el.text:
        tokens.append(Tok("text", el.text))
    for child in el:
        name = local(child.tag)
        cls = classes(child)
        if child.get("id"):
            ctx.anchors.append(child.get("id"))
        if name in ("strong", "b", "em", "i"):
            if cls:
                ctx.fail("unsupported-inline-class", child, f"class={' '.join(sorted(cls))}")
            delim = "**" if name in ("strong", "b") else "*"
            ctx.counts["strong" if delim == "**" else "em"] += 1
            inner = inline_tokens(child, ctx)
            tokens += [Tok("open", delim)] + inner + [Tok("close", delim)]
        elif name == "code":
            if len(child):
                ctx.fail("unsupported-code-children", child, f"{len(child)} child elements")
            ctx.counts["code"] += 1
            tokens.append(Tok("code", child.text or ""))
        elif name == "a":
            href = child.get("href")
            if href is None:
                tokens += inline_tokens(child, ctx)  # a pure fragment target
            else:
                doc, _ = resolve_href(ctx.doc, href)
                scheme = urlsplit(href).scheme.lower()
                if doc is not None or scheme not in ("http", "https", "mailto"):
                    ctx.fail("unsupported-internal-link", child, "reading-body links must be absolute http(s)/mailto")
                else:
                    ctx.counts["link"] += 1
                    tokens += [Tok("link_open")] + inline_tokens(child, ctx) + [Tok("link_close", href)]
        elif name == "span":
            if ctx.profile["blankFieldClass"] in cls:
                if not ctx.allow_blanks:
                    ctx.fail("blank-field-outside-card-value", child)
                elif len(child):
                    ctx.fail("unsupported-blank-field-children", child, f"{len(child)} child elements")
                elif not child.get("aria-label"):
                    ctx.fail("blank-field-without-aria-label", child)
                elif not (child.text or "").strip():
                    ctx.fail("empty-blank-field", child)
                else:
                    ctx.counts["blank"] += 1
                    tokens.append(Tok("blank", child.text or "", child.get("aria-label")))
            elif cls - set(ctx.profile["transparentSpanClasses"]):
                ctx.fail("unsupported-span-class", child, f"class={' '.join(sorted(cls))}")
            else:
                tokens += inline_tokens(child, ctx)
        else:
            ctx.fail("unsupported-inline-element", child)
        if child.tail:
            tokens.append(Tok("text", child.tail))
    return tokens


def normalize_tokens(tokens, ctx, el):
    """Collapses whitespace across the run, trims it, and moves spaces outside delimiters."""
    out = []
    last_space = True  # trims leading whitespace
    for tok in tokens:
        if tok.kind == "text":
            text = collapse_ws(tok.value)
            if last_space and text.startswith(" "):
                text = text[1:]
            if text:
                last_space = text.endswith(" ")
                out.append(Tok("text", text))
        elif tok.kind in ("code", "blank"):
            value = collapse_ws(tok.value)
            if tok.kind == "code":
                if "`" in value or value != value.strip() or not value:
                    ctx.fail("unsupported-code-content", el, "empty, backtick or edge whitespace")
            out.append(Tok(tok.kind, value, collapse_ws(tok.extra).strip()))
            last_space = False
        else:
            out.append(tok)
    # Trailing whitespace of the whole run.
    for i in range(len(out) - 1, -1, -1):
        if out[i].kind == "text":
            out[i] = Tok("text", out[i].value.rstrip())
            if out[i].value:
                break
        elif out[i].kind in ("code", "blank"):
            break
    out = [t for t in out if not (t.kind == "text" and not t.value)]

    changed = True
    while changed:
        changed = False
        for i, tok in enumerate(out):
            nxt = out[i + 1] if i + 1 < len(out) else None
            prev = out[i - 1] if i > 0 else None
            if tok.kind in ("open", "link_open") and nxt is not None and nxt.kind == "text" and nxt.value.startswith(" "):
                out[i + 1] = Tok("text", nxt.value[1:])
                out.insert(i, Tok("text", " "))
                changed = True
                break
            if tok.kind in ("close", "link_close") and prev is not None and prev.kind == "text" and prev.value.endswith(" "):
                out[i - 1] = Tok("text", prev.value[:-1])
                out.insert(i + 1, Tok("text", " "))
                changed = True
                break
        out = [t for t in out if not (t.kind == "text" and not t.value)]
        # Merge adjacent text tokens so spaces never double up.
        merged = []
        for tok in out:
            if merged and tok.kind == "text" and merged[-1].kind == "text":
                merged[-1] = Tok("text", collapse_ws(merged[-1].value + tok.value))
            else:
                merged.append(tok)
        out = merged
    # Leading/trailing single spaces pushed outside a delimiter at the edges.
    if out and out[0].kind == "text":
        out[0] = Tok("text", out[0].value.lstrip())
    if out and out[-1].kind == "text":
        out[-1] = Tok("text", out[-1].value.rstrip())
    out = [t for t in out if not (t.kind == "text" and not t.value)]

    for i, tok in enumerate(out):
        if tok.kind == "open" and i + 1 < len(out) and out[i + 1].kind == "close":
            ctx.fail("empty-emphasis", el)
    return out


def is_ws(ch):
    return ch is None or ch in " \t\n\r\f" or unicodedata.category(ch) == "Zs"


def is_punct(ch, include_symbols):
    if ch is None:
        return False
    if ch.isascii():
        return not ch.isalnum() and not ch.isspace() and ch.isprintable()
    category = unicodedata.category(ch)
    return category.startswith("P") or (include_symbols and category.startswith("S"))


def flanking_ok(markdown, start, length, role):
    """CommonMark delimiter-run rule for `*`, checked under both the older (P only)
    and newer (P and S) punctuation definitions, so either parser agrees."""
    before = markdown[start - 1] if start > 0 else None
    after = markdown[start + length] if start + length < len(markdown) else None
    for symbols in (False, True):
        if role == "open":
            ok = not is_ws(after) and (not is_punct(after, symbols) or is_ws(before) or is_punct(before, symbols))
        else:
            ok = not is_ws(before) and (not is_punct(before, symbols) or is_ws(after) or is_punct(after, symbols))
        if not ok:
            return False
    return True


def render_markdown(tokens, ctx, el):
    """Returns (markdown, parts). parts is a list of ("text", md) / ("blank", text, label)."""
    parts = []
    buf = []
    delims = []  # (start, length, role) in the current buffer
    link_stack = []

    def flush():
        markdown = "".join(buf)
        for start, length, role in delims:
            if not flanking_ok(markdown, start, length, role):
                ctx.fail("emphasis-boundary-not-representable", el, f"{role} delimiter at offset {start}")
        if markdown:
            parts.append(("text", markdown))
        buf.clear()
        delims.clear()

    def position():
        return sum(len(s) for s in buf)

    previous = None
    for tok in tokens:
        if tok.kind == "text":
            buf.append(escape_md(tok.value))
        elif tok.kind == "open":
            if previous is not None and previous.kind == "close":
                ctx.fail("adjacent-emphasis-runs", el)
            delims.append((position(), len(tok.value), "open"))
            buf.append(tok.value)
        elif tok.kind == "close":
            delims.append((position(), len(tok.value), "close"))
            buf.append(tok.value)
        elif tok.kind == "code":
            buf.append("`" + tok.value + "`")
        elif tok.kind == "link_open":
            link_stack.append(position())
            buf.append("[")
        elif tok.kind == "link_close":
            url = tok.value
            if any(ch in url for ch in "<> \n") or not link_stack:
                ctx.fail("unsupported-link-target", el, "url contains <, > or space")
            link_stack.pop() if link_stack else None
            buf.append("](<" + url + ">)")
        elif tok.kind == "blank":
            if delims and sum(1 for d in delims if d[2] == "open") != sum(1 for d in delims if d[2] == "close"):
                ctx.fail("blank-field-inside-emphasis", el)
            flush()
            parts.append(("blank", tok.value, tok.extra))
        previous = tok
    flush()
    markdown = "".join(p[1] for p in parts if p[0] == "text")
    return markdown, parts


def convert_inline(el, ctx, allow_blanks=False):
    ctx.allow_blanks = allow_blanks
    tokens = normalize_tokens(inline_tokens(el, ctx), ctx, el)
    markdown, parts = render_markdown(tokens, ctx, el)
    return markdown, parts


# A decoder for the exact Markdown subset this converter emits, used to prove
# that every block round-trips to the source's visible text.
class MalformedMarkdown(ValueError):
    pass


def decode_markdown(markdown):
    """Strict decoder: every special character must be escaped or structural."""
    out = []
    counts = {"strong": 0, "em": 0, "code": 0, "link": 0}
    stack = []
    links = 0
    i = 0
    while i < len(markdown):
        ch = markdown[i]
        if ch == "\\":
            if i + 1 >= len(markdown) or markdown[i + 1] not in MD_SPECIAL:
                raise MalformedMarkdown("bare backslash")
            out.append(markdown[i + 1])
            i += 2
        elif ch == "`":
            end = markdown.find("`", i + 1)
            if end < 0:
                raise MalformedMarkdown("unclosed code span")
            out.append(markdown[i + 1:end])
            counts["code"] += 1
            i = end + 1
        elif ch == "*":
            length = len(markdown[i:]) - len(markdown[i:].lstrip("*"))
            before = markdown[i - 1] if i > 0 else None
            after = markdown[i + length] if i + length < len(markdown) else None
            closes = not is_ws(before) and (not is_punct(before, False) or is_ws(after) or is_punct(after, False))
            opens = not is_ws(after) and (not is_punct(after, False) or is_ws(before) or is_punct(before, False))
            remaining = length
            if closes:
                while remaining and stack and stack[-1] <= remaining:
                    run = stack.pop()
                    counts["strong" if run == 2 else "em"] += 1
                    remaining -= run
            if remaining and opens:
                while remaining:
                    run = 2 if remaining >= 2 else 1
                    stack.append(run)
                    remaining -= run
            elif remaining:
                raise MalformedMarkdown("unescaped asterisk")
            i += length
        elif ch == "[":
            links += 1
            i += 1
        elif ch == "]":
            if not links or not markdown.startswith("](<", i):
                raise MalformedMarkdown("unescaped bracket")
            end = markdown.find(">)", i)
            if end < 0:
                raise MalformedMarkdown("unclosed link target")
            links -= 1
            counts["link"] += 1
            i = end + 2
        elif ch in MD_SPECIAL:
            raise MalformedMarkdown("unescaped special character")
        else:
            out.append(ch)
            i += 1
    if stack or links:
        raise MalformedMarkdown("unclosed emphasis or link")
    return "".join(out), counts


def source_plain(el, include_self_text=True):
    pieces = []

    def walk(node, own):
        if own and node.text:
            pieces.append(node.text)
        for child in node:
            walk(child, True)
            if child.tail:
                pieces.append(child.tail)

    walk(el, include_self_text)
    return collapse_ws("".join(pieces)).strip()


# ---------------------------------------------------------------------------
# Block conversion

BLOCK_UNSUPPORTED = {"pre", "img", "svg", "math", "audio", "video", "figure", "iframe", "object", "embed",
                     "dl", "details", "nav", "form", "input", "canvas", "h5", "h6", "br"}
CONTAINERS = {"div", "section", "article", "header", "footer", "main"}


@dataclass
class ConvertedBlock:
    block: dict
    anchors: list
    path: str
    verify: list = field(default_factory=list)  # [(source_plain, markdown_or_plain, kind)]


class DocConverter:
    def __init__(self, doc, root, profile, diagnostics):
        self.doc = doc
        self.root = root
        self.profile = profile
        self.diagnostics = diagnostics
        self.blocks = []
        self.title = None
        self.pending_anchors = []
        self.counts = {"strong": 0, "em": 0, "code": 0, "blank": 0, "link": 0}

    def fail(self, code, path, detail=""):
        self.diagnostics.add(code, f"{self.doc} {path}", detail)

    def ctx(self, path):
        return InlineContext(self.doc, path, self.profile, self.diagnostics)

    def take_counts(self, ctx):
        for key, value in ctx.counts.items():
            self.counts[key] += value

    def emit(self, block, anchors, path, verify):
        anchors = self.pending_anchors + anchors
        self.pending_anchors = []
        self.blocks.append(ConvertedBlock(block, anchors, path, verify))

    def inline_block(self, el, path, allow_blanks=False):
        ctx = self.ctx(path)
        markdown, parts = convert_inline(el, ctx, allow_blanks)
        self.take_counts(ctx)
        return markdown, parts, ctx.anchors

    def run(self):
        body = self.root.find(f"{{{XHTML}}}body")
        if body is None:
            self.fail("missing-body", "/")
            return
        if body.get("id"):
            self.pending_anchors.append(body.get("id"))
        self.container(body, "/body")
        if self.pending_anchors and self.blocks:
            self.blocks[-1].anchors.extend(self.pending_anchors)
            self.pending_anchors = []

    def container(self, el, path):
        if el.text and el.text.strip():
            self.fail("text-outside-block", path)
        counters = {}
        for child in el:
            name = local(child.tag)
            counters[name] = counters.get(name, 0) + 1
            child_path = f"{path}/{name}[{counters[name]}]"
            self.block(child, name, child_path)
            if child.tail and child.tail.strip():
                self.fail("text-outside-block", child_path, "tail text")

    def block(self, el, name, path):
        cls = classes(el)
        profile = self.profile
        if name == "h1":
            if self.title is not None or self.blocks:
                self.fail("unsupported-h1-position", path, "one h1 allowed, before any block")
                return
            if len(el):
                self.fail("unsupported-h1-markup", path, "chapter titles are plain text")
                return
            self.title = source_plain(el)
            if el.get("id"):
                self.pending_anchors.append(el.get("id"))
        elif name in ("h2", "h3"):
            if cls & {profile["cardTitleClass"], profile["labelClass"]}:
                self.fail("card-part-outside-card", path)
                return
            markdown, _, anchors = self.inline_block(el, path)
            self.emit({"kind": "heading", "level": int(name[1]), "text": markdown}, anchors, path,
                      [(source_plain(el), markdown)])
        elif name == "h4":
            self.fail("unsupported-h4-outside-card-field", path)
        elif name == "p":
            if profile["labelClass"] in cls or profile["cardTitleClass"] in cls:
                self.fail("card-part-outside-card", path)
                return
            markdown, _, anchors = self.inline_block(el, path)
            if not markdown:
                self.fail("empty-paragraph", path)
                return
            self.emit({"kind": "paragraph", "text": markdown}, anchors, path, [(source_plain(el), markdown)])
        elif name in ("ol", "ul"):
            self.list_block(el, name, path)
        elif name == "blockquote":
            self.quote_block(el, path)
        elif name == "aside":
            self.note_block(el, path)
        elif name == "hr":
            if len(el) or (el.text or "").strip():
                self.fail("unsupported-hr-content", path)
            anchors = [el.get("id")] if el.get("id") else []
            self.emit({"kind": "divider"}, anchors, path, [])
        elif name == "table":
            self.table_block(el, path)
        elif name == "section" and profile["cardGroupClass"] in cls:
            self.card_group(el, path)
        elif name in CONTAINERS:
            if cls & {profile["cardClass"], profile["fieldClass"], profile["valueClass"]}:
                self.fail("card-part-outside-card-group", path)
                return
            known = set(profile["transparentContainerClasses"])
            if el.get("aria-label") is not None:
                self.fail("unsupported-labelled-container", path, "aria-label outside card structures")
                return
            if cls - known and name in ("div",):
                self.fail("unsupported-container-class", path, f"class={' '.join(sorted(cls - known))}")
                return
            if el.get("id"):
                self.pending_anchors.append(el.get("id"))
            self.container(el, path)
        elif name in BLOCK_UNSUPPORTED:
            self.fail("unsupported-element", path)
        else:
            self.fail("unsupported-element", path)

    def list_block(self, el, name, path):
        items, verify, anchors = [], [], [el.get("id")] if el.get("id") else []
        for attr in ("type", "reversed"):
            if el.get(attr) is not None:
                self.fail("unsupported-list-attribute", path, attr)
        if el.text and el.text.strip():
            self.fail("text-outside-list-item", path)
        for index, li in enumerate(el):
            li_path = f"{path}/li[{index + 1}]"
            if local(li.tag) != "li":
                self.fail("unsupported-list-child", li_path.replace("li[", local(li.tag) + "["))
                continue
            if li.get("value") is not None:
                self.fail("unsupported-list-attribute", li_path, "value")
            if (li.tail or "").strip():
                self.fail("text-between-list-items", li_path)
            nested = [local(c.tag) for c in li if local(c.tag) in ("ol", "ul", "p", "div", "blockquote")]
            if nested:
                self.fail("unsupported-list-item-shape", li_path, f"block children: {','.join(nested)}")
                continue
            markdown, _, item_anchors = self.inline_block(li, li_path)
            if not markdown:
                self.fail("empty-list-item", li_path)
            anchors += item_anchors
            items.append(markdown)
            verify.append((source_plain(li), markdown))
        if not items:
            self.fail("empty-list", path)
            return
        block = {"kind": "list", "items": items, "ordered": name == "ol"}
        if name == "ol":
            start = el.get("start")
            if start is not None:
                try:
                    block["start"] = int(start.strip())
                except ValueError:
                    self.fail("invalid-list-start", path)
                    return
            first = block.get("start", 1)
            last = first + len(items) - 1
            if first < INT64_MIN or last > INT64_MAX:
                self.fail("list-number-out-of-range", path, "start and last item must fit a signed 64-bit Int")
                return
        self.emit(block, anchors, path, verify)

    def quote_block(self, el, path):
        if el.text and el.text.strip():
            self.fail("text-outside-quote-paragraph", path)
        paragraphs, verify, anchors = [], [], [el.get("id")] if el.get("id") else []
        for index, child in enumerate(el):
            child_path = f"{path}/{local(child.tag)}[{index + 1}]"
            if local(child.tag) != "p":
                self.fail("unsupported-quote-child", child_path)
                continue
            if child.tail and child.tail.strip():
                self.fail("text-outside-quote-paragraph", child_path)
            markdown, _, p_anchors = self.inline_block(child, child_path)
            anchors += p_anchors
            paragraphs.append(markdown)
            verify.append((source_plain(child), markdown))
        if not paragraphs:
            self.fail("empty-quote", path)
            return
        self.emit({"kind": "quote", "paragraphs": paragraphs}, anchors, path, verify)

    def note_block(self, el, path):
        if not classes(el) & set(self.profile["sourceNoteClasses"]):
            self.fail("unsupported-aside", path, "only source-note asides are supported")
            return
        children = list(el)
        if len(children) != 1 or local(children[0].tag) != "p" or (el.text or "").strip() \
                or (children[0].tail or "").strip():
            self.fail("unsupported-source-note-shape", path, f"{len(children)} children; exactly one p supported")
            return
        markdown, _, anchors = self.inline_block(children[0], f"{path}/p[1]")
        if el.get("id"):
            anchors = [el.get("id")] + anchors
        self.emit({"kind": "note", "text": markdown}, anchors, path, [(source_plain(children[0]), markdown)])

    def table_block(self, el, path):
        caption, header, rows, verify = None, None, [], []
        if (el.text or "").strip():
            self.fail("text-outside-table-cell", path)
        for child in el:
            name = local(child.tag)
            if (child.tail or "").strip() or (name in ("thead", "tbody") and (child.text or "").strip()):
                self.fail("text-outside-table-cell", f"{path}/{name}")
            if name == "caption":
                caption, _, _ = self.inline_block(child, f"{path}/caption")
            elif name in ("thead", "tbody"):
                for tr in child:
                    if local(tr.tag) != "tr" or (tr.text or "").strip() or (tr.tail or "").strip():
                        self.fail("unsupported-table-shape", f"{path}/{name}/{local(tr.tag)}", "rows must be tr with no loose text")
                        return
                    cells = []
                    for cell in tr:
                        if (cell.tail or "").strip():
                            self.fail("text-outside-table-cell", f"{path}/{name}/{local(cell.tag)}")
                        if local(cell.tag) not in ("th", "td") or cell.get("colspan") or cell.get("rowspan"):
                            self.fail("unsupported-table-shape", f"{path}/{name}")
                            return
                        md, _, _ = self.inline_block(cell, f"{path}/{name}/{local(cell.tag)}")
                        cells.append(md)
                        verify.append((source_plain(cell), md))
                    if name == "thead":
                        if header is not None:
                            self.fail("unsupported-table-shape", path, "more than one header row")
                            return
                        header = cells
                    else:
                        rows.append(cells)
            else:
                self.fail("unsupported-table-shape", f"{path}/{name}")
                return
        if not header or any(len(r) != len(header) for r in rows):
            self.fail("unsupported-table-shape", path, "needs one header row and equal row lengths")
            return
        table = {"header": header, "rows": rows}
        if caption:
            table["caption"] = caption
        self.emit({"kind": "table", "table": table}, [el.get("id")] if el.get("id") else [], path, verify)

    def card_group(self, el, path):
        p = self.profile
        group = {"cards": []}
        verify, anchors = [], [el.get("id")] if el.get("id") else []
        if el.get("aria-label") is not None:
            group["accessibilityLabel"] = collapse_ws(el.get("aria-label")).strip()
        if (el.text or "").strip():
            self.fail("text-outside-card", path)
        children = list(el)
        for index, child in enumerate(children):
            name = local(child.tag)
            child_path = f"{path}/{name}[{index + 1}]"
            cls = classes(child)
            if (child.tail or "").strip():
                self.fail("text-outside-card", child_path)
            if name == "p" and p["labelClass"] in cls and index == 0:
                md, _, a = self.inline_block(child, child_path)
                group["label"] = md
                anchors += a
                verify.append((source_plain(child), md))
            elif name == "section" and p["cardClass"] in cls:
                card = self.card(child, child_path, verify, anchors)
                if card is not None:
                    group["cards"].append(card)
            else:
                self.fail("unsupported-card-group-child", child_path, f"class={' '.join(sorted(cls)) or '-'}")
        if not group["cards"]:
            self.fail("empty-card-group", path)
            return
        self.emit({"kind": "cards", "cards": group}, anchors, path, verify)

    def card(self, el, path, verify, anchors):
        p = self.profile
        card = {"fields": []}
        if el.get("id"):
            anchors.append(el.get("id"))
        if el.get("aria-label") is not None:
            card["accessibilityLabel"] = collapse_ws(el.get("aria-label")).strip()
        if (el.text or "").strip():
            self.fail("text-outside-card-field", path)
        titles = 0
        for index, child in enumerate(el):
            child_path = f"{path}/{local(child.tag)}[{index + 1}]"
            if local(child.tag) != "div" or p["fieldClass"] not in classes(child):
                self.fail("unsupported-card-child", child_path, f"class={' '.join(sorted(classes(child))) or '-'}")
                continue
            if (child.tail or "").strip():
                self.fail("text-outside-card-field", child_path)
            field_value = self.card_field(child, child_path, verify, anchors)
            if field_value is not None:
                titles += 1 if "title" in field_value else 0
                card["fields"].append(field_value)
        if titles > 1:
            self.fail("unsupported-card-shape", path, f"{titles} title fields")
        if not card["fields"]:
            self.fail("empty-card", path)
            return None
        return card

    def card_field(self, el, path, verify, anchors):
        p = self.profile
        if el.get("id"):
            anchors.append(el.get("id"))
        children = list(el)
        shape = [(local(c.tag), classes(c)) for c in children]
        if (el.text or "").strip() or any((c.tail or "").strip() for c in children):
            self.fail("text-outside-card-field-part", path)
            return None
        if len(children) != 2 or shape[0][0] != "p" or p["labelClass"] not in shape[0][1]:
            self.fail("unsupported-card-field-shape", path,
                      "expected label p then title h4 or value div; found " +
                      ",".join(f"{n}.{'.'.join(sorted(c)) or '-'}" for n, c in shape))
            return None
        label_md, _, a = self.inline_block(children[0], f"{path}/p[1]")
        anchors += a
        verify.append((source_plain(children[0]), label_md))
        result = {"label": label_md}
        second, second_cls = shape[1]
        second_el = children[1]
        if second == "h4" and p["cardTitleClass"] in second_cls:
            md, _, a = self.inline_block(second_el, f"{path}/h4[1]")
            anchors += a
            result["title"] = md
            verify.append((source_plain(second_el), md))
        elif second == "div" and p["valueClass"] in second_cls:
            _, parts, a = self.inline_block(second_el, f"{path}/div[1]", allow_blanks=True)
            anchors += a
            value = []
            for part in parts:
                if part[0] == "text":
                    value.append({"text": part[1]})
                else:
                    value.append({"blank": {"text": part[1], "accessibilityLabel": part[2]}})
            if not value:
                self.fail("empty-card-value", f"{path}/div[1]")
                return None
            result["value"] = value
            verify.append((source_plain(second_el), value))
        else:
            self.fail("unsupported-card-field-shape", path, f"second child {second}")
            return None
        return result


def value_plain(value):
    out = []
    for part in value:
        if "text" in part:
            out.append(decode_markdown(part["text"])[0])
        else:
            out.append(part["blank"]["text"])
    return "".join(out)


def verify_block(converted, doc, diagnostics):
    for index, (expected, produced) in enumerate(converted.verify):
        try:
            actual = value_plain(produced) if isinstance(produced, list) else decode_markdown(produced)[0]
        except MalformedMarkdown as error:
            diagnostics.add("round-trip-mismatch", f"{doc} {converted.path}", f"part {index}; {error}")
            continue
        if actual != expected:
            diagnostics.add("round-trip-mismatch", f"{doc} {converted.path}", f"part {index}; lengths {len(expected)}/{len(actual)}")


# ---------------------------------------------------------------------------
# Output census (counted from the produced bundle, independently of the source)

def output_census(chapters):
    counts = {"headings2": 0, "headings3": 0, "paragraphs": 0, "orderedLists": 0, "unorderedLists": 0,
              "listItems": 0, "listsWithStart": 0, "quotes": 0, "quoteParagraphs": 0, "notes": 0,
              "dividers": 0, "tables": 0, "cardGroups": 0, "cards": 0, "fields": 0, "labels": 0,
              "values": 0, "cardTitles": 0, "blankFields": 0, "strong": 0, "em": 0, "code": 0, "links": 0,
              "rawURLs": 0}

    def text(md):
        plain, c = decode_markdown(md)
        for key in ("strong", "em", "code"):
            counts[key] += c[key]
        counts["links"] += c["link"]
        counts["rawURLs"] += len(RAW_URL.findall(plain))

    for chapter in chapters:
        for block in chapter["blocks"]:
            kind = block["kind"]
            if kind == "heading":
                counts[f"headings{block['level']}"] += 1
                text(block["text"])
            elif kind == "paragraph":
                counts["paragraphs"] += 1
                text(block["text"])
            elif kind == "list":
                counts["orderedLists" if block["ordered"] else "unorderedLists"] += 1
                counts["listItems"] += len(block["items"])
                counts["listsWithStart"] += 1 if "start" in block else 0
                for item in block["items"]:
                    text(item)
            elif kind == "quote":
                counts["quotes"] += 1
                counts["quoteParagraphs"] += len(block["paragraphs"])
                for paragraph in block["paragraphs"]:
                    text(paragraph)
            elif kind == "note":
                counts["notes"] += 1
                text(block["text"])
            elif kind == "divider":
                counts["dividers"] += 1
            elif kind == "table":
                counts["tables"] += 1
            elif kind == "cards":
                group = block["cards"]
                counts["cardGroups"] += 1
                if "label" in group:
                    counts["labels"] += 1
                    text(group["label"])
                for card in group["cards"]:
                    counts["cards"] += 1
                    for f in card["fields"]:
                        counts["fields"] += 1
                        counts["labels"] += 1
                        text(f["label"])
                        if "title" in f:
                            counts["cardTitles"] += 1
                            text(f["title"])
                        if "value" in f:
                            counts["values"] += 1
                            for part in f["value"]:
                                if "text" in part:
                                    text(part["text"])
                                else:
                                    counts["blankFields"] += 1
                                    counts["rawURLs"] += len(RAW_URL.findall(part["blank"]["text"]))
    return counts


def reconcile(source, output, diagnostics):
    pairs = [
        ("h2", "headings2"), ("h3", "headings3"), ("ol", "orderedLists"), ("ul", "unorderedLists"),
        ("li", "listItems"), ("olWithStart", "listsWithStart"), ("blockquote", "quotes"),
        ("blockquoteP", "quoteParagraphs"), ("asideSourceNotes", "notes"), ("hr", "dividers"),
        ("table", "tables"), ("cardGroups", "cardGroups"), ("cards", "cards"), ("fields", "fields"),
        ("labels", "labels"), ("values", "values"), ("cardTitles", "cardTitles"), ("h4", "cardTitles"),
        ("blankFields", "blankFields"), ("code", "code"), ("aExternal", "links"), ("rawURLs", "rawURLs"),
    ]
    for source_key, output_key in pairs:
        if source.get(source_key, 0) != output.get(output_key, 0):
            diagnostics.add("census-mismatch", f"{source_key}/{output_key}",
                            f"source {source.get(source_key, 0)}, output {output.get(output_key, 0)}")
    strong = source.get("strong", 0) + source.get("b", 0)
    em = source.get("em", 0) + source.get("i", 0)
    if strong != output["strong"]:
        diagnostics.add("census-mismatch", "strong+b/strong", f"source {strong}, output {output['strong']}")
    if em != output["em"]:
        diagnostics.add("census-mismatch", "em+i/em", f"source {em}, output {output['em']}")


# ---------------------------------------------------------------------------
# IDs

def fingerprint(block):
    content = {k: v for k, v in block.items() if k != "id"}
    return sha256_bytes(canonical_json(content).encode("utf-8"))


def empty_registry():
    return {"format": REGISTRY_FORMAT, "blocks": [], "documents": {}, "retired": [], "idMap": {},
            "nextOrdinal": {}, "chapters": {}}


def validate_registry(registry, diagnostics):
    if registry.get("format") != REGISTRY_FORMAT:
        diagnostics.add("registry-format", "registry", f"expected {REGISTRY_FORMAT}")
        return
    seen = set()
    for entry in registry.get("blocks", []):
        if not ID_PATTERN.match(entry.get("id", "")):
            diagnostics.add("registry-invalid-id", "registry", "block id syntax")
        if entry.get("id") in seen:
            diagnostics.add("registry-duplicate-id", entry.get("id", "?"))
        seen.add(entry.get("id"))
        if not re.fullmatch(r"[0-9a-f]{64}", entry.get("fingerprint", "")):
            diagnostics.add("registry-invalid-fingerprint", entry.get("id", "?"))
        if not isinstance(entry.get("sourceOccurrence"), int) or not isinstance(entry.get("source"), str) \
                or not isinstance(entry.get("anchors"), list):
            diagnostics.add("registry-incomplete-entry", entry.get("id", "?"), "source, sourceOccurrence and anchors required")
    for href, digest in registry.get("documents", {}).items():
        if not re.fullmatch(r"[0-9a-f]{64}", str(digest)):
            diagnostics.add("registry-invalid-document-digest", href)
    for retired in registry.get("retired", []):
        if retired in seen:
            diagnostics.add("registry-retired-still-active", retired)


def _describe(entries, limit=10):
    shown = ",".join(entries[:limit])
    return shown + (f",+{len(entries) - limit} more" if len(entries) > limit else "")


def assign_ids(new_blocks, registry, migration, chapter_of, document_digests, diagnostics):
    """new_blocks: dicts with chapter, source, block, fingerprint, sourceOccurrence and anchors.

    A block keeps its registry ID only on evidence that it is the same block:
      * its content fingerprint is unique among both the registry and this edition (it may move);
      * or, among identical blocks, it carries the same source anchor (element id) as the entry;
      * or, among identical blocks, its whole source document is byte-identical to the one
        recorded in the registry and it has the same position among identical blocks there.
    Equal counts or book-wide order are never treated as identity. Anything else needs an explicit
    `assign`, `migrations` or `retired` entry, or the conversion stops.
    """
    active = registry.get("blocks", [])
    by_id = {e["id"]: e for e in active}
    old_documents = registry.get("documents", {})
    historical = set(by_id) | set(registry.get("retired", [])) | set(registry.get("idMap", {}))
    assigned = {}   # index in new_blocks -> id
    used_ids = set()
    stats = {"matched": 0, "matchedByAnchor": 0, "matchedByUnchangedDocument": 0, "assigned": 0, "new": 0,
             "moved": 0, "migrated": 0, "retired": 0}

    key_of = {(b["source"], b["fingerprint"], b["sourceOccurrence"]): i for i, b in enumerate(new_blocks)}
    for entry in migration.get("assign", []):
        target = entry.get("block", {})
        key = (target.get("source"), target.get("fingerprint"), target.get("sourceOccurrence", 0))
        index = key_of.get(key)
        if entry.get("id") not in by_id:
            diagnostics.add("assign-unknown-id", entry.get("id", "?"), "id must be active in the registry")
        elif index is None:
            diagnostics.add("assign-target-missing", entry.get("id"), f"{key[0]} {str(key[1])[:12]} #{key[2]}")
        elif index in assigned or entry["id"] in used_ids:
            diagnostics.add("assign-conflict", entry.get("id"))
        else:
            assigned[index] = entry["id"]
            used_ids.add(entry["id"])
            stats["assigned"] += 1

    def take(index, entry, how):
        assigned[index] = entry["id"]
        used_ids.add(entry["id"])
        stats["matched"] += 1
        if how:
            stats[how] += 1
        if entry.get("chapter") != new_blocks[index]["chapter"]:
            stats["moved"] += 1

    old_by_fp, new_by_fp = {}, {}
    for entry in active:
        if entry["id"] not in used_ids:
            old_by_fp.setdefault(entry["fingerprint"], []).append(entry)
    for index, block in enumerate(new_blocks):
        if index not in assigned:
            new_by_fp.setdefault(block["fingerprint"], []).append(index)
    unresolved = set()
    for fp in sorted(set(old_by_fp) & set(new_by_fp)):
        olds, news = old_by_fp[fp], new_by_fp[fp]
        registry_total = sum(1 for e in active if e["fingerprint"] == fp)
        edition_total = sum(1 for b in new_blocks if b["fingerprint"] == fp)
        if registry_total == 1 and edition_total == 1 and len(olds) == 1 and len(news) == 1:
            take(news[0], olds[0], None)
            continue
        remaining_old = list(olds)
        remaining_new = []
        for index in news:
            block = new_blocks[index]
            anchored = [e for e in remaining_old if e["source"] == block["source"] and set(e["anchors"]) & set(block["anchors"])]
            if block["anchors"] and len(anchored) == 1:
                take(index, anchored[0], "matchedByAnchor")
                remaining_old.remove(anchored[0])
            else:
                remaining_new.append(index)
        still_new = []
        for index in remaining_new:
            block = new_blocks[index]
            source = block["source"]
            unchanged = old_documents.get(source) is not None and old_documents.get(source) == document_digests.get(source)
            same_place = [e for e in remaining_old if e["source"] == source and e["sourceOccurrence"] == block["sourceOccurrence"]]
            if unchanged and len(same_place) == 1:
                take(index, same_place[0], "matchedByUnchangedDocument")
                remaining_old.remove(same_place[0])
            else:
                still_new.append(index)
        if still_new and remaining_old:
            diagnostics.add(
                "ambiguous-identical-blocks", f"fingerprint {fp[:12]}",
                "registry " + _describe([f"{e['id']}@{e['source']}#{e['sourceOccurrence']}" for e in remaining_old]) +
                "; this edition " + _describe([f"{new_blocks[i]['source']}#{new_blocks[i]['sourceOccurrence']}" for i in still_new]) +
                "; add explicit assign, migrations or retired entries")
            unresolved.update(e["id"] for e in remaining_old)

    migrations = migration.get("migrations", {})
    retired_now = set(migration.get("retired", []))
    for entry in active:
        if entry["id"] in used_ids or entry["id"] in unresolved:
            continue
        if entry["id"] in migrations:
            stats["migrated"] += 1
        elif entry["id"] in retired_now:
            stats["retired"] += 1
        else:
            diagnostics.add("unmatched-registry-id", entry["id"],
                            f"chapter {entry.get('chapter')}; content changed or removed; "
                            "add assign, migrations or retired")
    for old_id in list(migrations) + list(retired_now):
        if old_id not in by_id:
            diagnostics.add("migration-unknown-id", old_id)
        elif old_id in used_ids:
            diagnostics.add("migration-of-active-id", old_id)

    next_ordinal = dict(registry.get("nextOrdinal", {}))
    ids = []
    for index, block in enumerate(new_blocks):
        if index in assigned:
            ids.append(assigned[index])
            continue
        chapter = block["chapter"]
        ordinal = next_ordinal.get(chapter, 1)
        while True:
            candidate = f"{chapter}.{KIND_PREFIX[block['block']['kind']]}{ordinal:04d}"
            ordinal += 1
            if candidate not in historical and candidate not in used_ids:
                break
        next_ordinal[chapter] = ordinal
        used_ids.add(candidate)
        ids.append(candidate)
        stats["new"] += 1

    final_ids = set(ids)
    id_map = dict(registry.get("idMap", {}))
    for old_id, new_id in migrations.items():
        if new_id not in final_ids:
            diagnostics.add("migration-target-missing", old_id, f"target {new_id}")
        id_map[old_id] = new_id

    new_registry = {
        "format": REGISTRY_FORMAT,
        "blocks": [
            {"id": ids[i], "chapter": b["chapter"], "source": b["source"], "fingerprint": b["fingerprint"],
             "sourceOccurrence": b["sourceOccurrence"], "anchors": b["anchors"]}
            for i, b in enumerate(new_blocks)
        ],
        # Digest of every reading document, the evidence for the unchanged-document rule next time.
        "documents": dict(sorted(document_digests.items())),
        "retired": sorted(set(registry.get("retired", [])) | retired_now | set(migrations)),
        "idMap": dict(sorted(id_map.items())),
        "nextOrdinal": dict(sorted(next_ordinal.items())),
        "chapters": dict(sorted(chapter_of.items())),
    }
    return ids, new_registry, stats


# ---------------------------------------------------------------------------
# Tools

def build_tools(mapping, chapters, diagnostics):
    if mapping.get("format") != TOOLS_FORMAT:
        diagnostics.add("tools-format", "tools", f"expected {TOOLS_FORMAT}")
        return None
    chapter_by_id = {c["id"]: c for c in chapters}
    block_index = {b["id"]: (c, b) for c in chapters for b in c["blocks"]}
    prompt_ids = set()

    def prompts(section, key):
        result = []
        spec = mapping.get(section, {})
        chapter_id = spec.get("chapter")
        if chapter_id not in chapter_by_id:
            diagnostics.add("tools-chapter-missing", section, f"chapter {chapter_id}")
        for index, entry in enumerate(spec.get(key, [])):
            where = f"{section}.{key}[{index}]"
            pid = entry.get("id", "")
            if not ID_PATTERN.match(pid):
                diagnostics.add("tools-invalid-id", where)
            if pid in prompt_ids:
                diagnostics.add("tools-duplicate-id", where, pid)
            prompt_ids.add(pid)
            located = block_index.get(entry.get("block"))
            if located is None:
                diagnostics.add("tools-block-missing", where, f"block {entry.get('block')}")
                continue
            chapter, block = located
            if chapter["id"] != chapter_id:
                diagnostics.add("tools-block-outside-chapter", where, f"block in {chapter['id']}")
            if "item" in entry:
                items = block.get("items") if block["kind"] == "list" else None
                if items is None or not (0 <= entry["item"] < len(items)):
                    diagnostics.add("tools-item-invalid", where)
                    continue
                text = items[entry["item"]]
            elif block["kind"] in {"paragraph", "heading"}:
                text = block["text"]
            else:
                diagnostics.add("tools-block-kind", where, f"{block['kind']} needs an item index")
                continue
            result.append({"id": pid, "text": text})
        return result, chapter_id

    filter_questions, filter_chapter = prompts("filter", "prompts")
    rollout_items, rollout_chapter = prompts("rollout", "items")
    if len(mapping.get("filter", {}).get("prompts", [])) != 5:
        diagnostics.add("tools-filter-count", "filter.prompts",
                        f"exactly 5 required, found {len(mapping.get('filter', {}).get('prompts', []))}")
    if not mapping.get("rollout", {}).get("items"):
        diagnostics.add("tools-rollout-empty", "rollout.items")
    cost_chapter = mapping.get("cost", {}).get("chapter")
    if cost_chapter not in chapter_by_id:
        diagnostics.add("tools-chapter-missing", "cost", f"chapter {cost_chapter}")
    # The Filter tool is free. Wording copied from a paid chapter must be acknowledged explicitly.
    chapter = chapter_by_id.get(filter_chapter)
    if chapter is not None and chapter["access"] == "paid" and not mapping["filter"].get("freeToolUsesPaidChapterText"):
        diagnostics.add("tools-access-boundary", "filter",
                        "free Filter copies text from a paid chapter; set freeToolUsesPaidChapterText to confirm")
    return {
        "filterQuestions": filter_questions, "rolloutItems": rollout_items,
        "filterChapterID": filter_chapter, "rolloutChapterID": rollout_chapter, "costChapterID": cost_chapter,
    }


# ---------------------------------------------------------------------------
# Edition config and whole-book conversion

ROLES = {"cover", "titlePage", "printedContents", "reading"}


def load_json(path, what):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ConversionFailed([f"missing-input: {what}"])
    except json.JSONDecodeError as error:
        raise ConversionFailed([f"invalid-json: {what} (line {error.lineno})"])


def inside_git_tree(path):
    current = Path(path).resolve()
    for parent in [current] + list(current.parents):
        if (parent / ".git").exists():
            return True
    return False


def convert(epub_path, edition, registry, migration, tools_mapping):
    if edition.get("format") != EDITION_FORMAT:
        raise ConversionFailed([f"edition-format: expected {EDITION_FORMAT}"])
    removed = sorted(REMOVED_EDITION_KEYS & set(edition))
    if removed:
        raise ConversionFailed([f"unsupported-edition-key: {', '.join(removed)}"])
    epub = open_epub(epub_path)
    try:
        return _convert(epub, edition, registry, migration, tools_mapping)
    finally:
        epub.close()


def squeeze(text):
    return re.sub(r"[ \t\n\r\f]+", "", text)


def block_text_pieces(block):
    """The visible text of a converted block, in source order."""
    kind = block["kind"]
    if kind in ("heading", "paragraph", "note"):
        return [decode_markdown(block["text"])[0]]
    if kind == "list":
        return [decode_markdown(item)[0] for item in block["items"]]
    if kind == "quote":
        return [decode_markdown(p)[0] for p in block["paragraphs"]]
    if kind == "table":
        table = block["table"]
        cells = ([table["caption"]] if "caption" in table else []) + table["header"] + [c for r in table["rows"] for c in r]
        return [decode_markdown(c)[0] for c in cells]
    if kind == "cards":
        group = block["cards"]
        pieces = [decode_markdown(group["label"])[0]] if "label" in group else []
        for card in group["cards"]:
            for f in card["fields"]:
                pieces.append(decode_markdown(f["label"])[0])
                if "title" in f:
                    pieces.append(decode_markdown(f["title"])[0])
                if "value" in f:
                    pieces.append(value_plain(f["value"]))
        return pieces
    return []


def verify_document_text(href, root, converter, diagnostics):
    """Every visible character of the body must reappear, in order, in the chapter title and
    blocks. Catches text that a shape-specific check might miss (for example between list items)."""
    body = root.find(f"{{{XHTML}}}body")
    source = squeeze("".join(body.itertext()))
    try:
        produced = squeeze((converter.title or "") + "".join(
            piece for converted in converter.blocks for piece in block_text_pieces(converted.block)))
    except MalformedMarkdown:
        return  # already reported per block as round-trip-mismatch
    if source != produced:
        offset = next((i for i, (a, b) in enumerate(zip(source, produced)) if a != b), min(len(source), len(produced)))
        diagnostics.add("document-text-mismatch", href,
                        f"source {len(source)} characters, output {len(produced)}, first difference at {offset}")


FRONT_MATTER_STATUS = {"cover": "presented-natively", "titlePage": "presented-natively",
                       "printedContents": "reconciled-to-native-contents"}


def omitted_document_record(href, role, root):
    """Accounts for a front-matter document without putting its text in the report."""
    body = root.find(f"{{{XHTML}}}body")
    text = collapse_ws("".join(body.itertext())).strip() if body is not None else ""
    images = sum(1 for _ in root.iter(f"{{{XHTML}}}img"))
    return ({"href": href, "role": role, "status": FRONT_MATTER_STATUS[role], "textCharacters": len(text),
             "textSHA256": sha256_bytes(text.encode("utf-8")), "images": images},
            {"role": role, "text": text})

# ---------------------------------------------------------------------------
# Front matter presented natively: cover, title page and the source's own contents

def convert_cover(href, root, epub, diagnostics):
    """Cover document: wrappers around exactly one img that is the manifest's cover image.
    Returns the alt text, or None after reporting a problem."""
    body = root.find(f"{{{XHTML}}}body")
    images = list(body.iter(f"{{{XHTML}}}img")) if body is not None else []
    if len(images) != 1:
        diagnostics.add("unsupported-cover-shape", href, f"{len(images)} images; exactly one supported")
        return None
    if squeeze("".join(body.itertext())):
        diagnostics.add("unsupported-cover-shape", href, "text beside the cover image")
        return None
    for el in body.iter():
        if el is not body and local(el.tag) not in ("div", "section", "figure", "img"):
            diagnostics.add("unsupported-cover-shape", href, f"element {local(el.tag)}")
            return None
    doc, _ = resolve_href(href, images[0].get("src", ""))
    if doc is None or doc != epub.cover_href:
        diagnostics.add("cover-image-mismatch", href, "img src is not the manifest cover image")
        return None
    alt = images[0].get("alt") or ""
    if not alt.strip():
        diagnostics.add("cover-alt-missing", href)
        return None
    return alt


TITLE_ROLES = {"h1": "title", "h2": "subtitle"}


def convert_title_page(href, root, profile, diagnostics):
    """Title page: body > section.title-page > h1 | h2 | p.author | p, in order, inline styles kept."""
    body = root.find(f"{{{XHTML}}}body")
    children = list(body) if body is not None else []
    if (body is None or (body.text or "").strip() or len(children) != 1 or local(children[0].tag) != "section"
            or profile["titlePageClass"] not in classes(children[0]) or (children[0].tail or "").strip()):
        diagnostics.add("unsupported-title-page-shape", href, "expected body > section." + profile["titlePageClass"])
        return None
    section = children[0]
    if (section.text or "").strip():
        diagnostics.add("unsupported-title-page-shape", href, "text outside title-page elements")
        return None
    elements, decoded = [], []
    for index, el in enumerate(section):
        name, cls = local(el.tag), classes(el)
        path = f"/body/section/{name}[{index + 1}]"
        if (el.tail or "").strip():
            diagnostics.add("unsupported-title-page-shape", href + " " + path, "tail text")
            return None
        if name in TITLE_ROLES and not cls:
            role = TITLE_ROLES[name]
        elif name == "p" and cls == {profile["authorClass"]}:
            role = "author"
        elif name == "p" and not cls:
            role = "paragraph"
        else:
            diagnostics.add("unsupported-title-page-element", href + " " + path,
                            f"class={' '.join(sorted(cls)) or '-'}")
            return None
        ctx = InlineContext(href, path, profile, diagnostics)
        markdown, _ = convert_inline(el, ctx)
        if not markdown:
            diagnostics.add("empty-title-page-element", href + " " + path)
            return None
        try:
            plain = decode_markdown(markdown)[0]
        except MalformedMarkdown as error:
            diagnostics.add("round-trip-mismatch", href + " " + path, str(error))
            return None
        if plain != source_plain(el):
            diagnostics.add("round-trip-mismatch", href + " " + path, "title-page text")
            return None
        elements.append({"role": role, "text": markdown})
        decoded.append(plain)
    if not elements:
        diagnostics.add("unsupported-title-page-shape", href, "no elements")
        return None
    if squeeze("".join(body.itertext())) != squeeze("".join(decoded)):
        diagnostics.add("document-text-mismatch", href, "title page")
        return None
    return {"elements": elements}


def toc_entries(ol, base_doc, depth, where, diagnostics, out):
    """Nested ol > li > a (text only) [+ ol], as in the EPUB nav document and printed contents."""
    if (ol.text or "").strip():
        diagnostics.add("unsupported-contents-shape", where, "text in list")
        return
    for index, li in enumerate(ol):
        place = f"{where} item {len(out) + 1}"
        children = list(li)
        if local(li.tag) != "li" or (li.text or "").strip() or (li.tail or "").strip() or not children \
                or local(children[0].tag) != "a" or any((c.tail or "").strip() for c in children):
            diagnostics.add("unsupported-contents-shape", place, "each item is one link, optionally followed by one list")
            return
        anchor = children[0]
        if len(anchor) or not anchor.get("href"):
            diagnostics.add("unsupported-contents-label", place, "labels must be plain-text links")
            return
        doc, fragment = resolve_href(base_doc, anchor.get("href"))
        out.append((collapse_ws(anchor.text or "").strip(), doc, fragment, depth))
        rest = children[1:]
        if len(rest) > 1 or (rest and local(rest[0].tag) != "ol"):
            diagnostics.add("unsupported-contents-shape", place, "only one nested list per item")
            return
        if rest:
            toc_entries(rest[0], base_doc, depth + 1, where, diagnostics, out)


def headed_list(container, href, where, diagnostics):
    """A container holding optional h1/h2 headings then exactly one ol."""
    kids = list(container)
    if (container.text or "").strip() or any((k.tail or "").strip() for k in kids):
        diagnostics.add("unsupported-contents-shape", where, "loose text")
        return None
    lists = [k for k in kids if local(k.tag) == "ol"]
    others = [k for k in kids if local(k.tag) not in ("ol", "h1", "h2")]
    if len(lists) != 1 or others or kids.index(lists[0]) != len(kids) - 1:
        diagnostics.add("unsupported-contents-shape", where, "expected headings then one ol")
        return None
    out = []
    toc_entries(lists[0], href, 1, where, diagnostics, out)
    return out


def nav_doc_entries(epub, diagnostics):
    root = parse_xml(epub.read(epub.nav_href), epub.nav_href)
    navs = [n for n in root.iter(f"{{{XHTML}}}nav") if "toc" in (n.get(f"{{{OPS}}}type") or "").split()]
    if len(navs) != 1:
        diagnostics.add("unsupported-contents-shape", epub.nav_href, f"{len(navs)} toc navs")
        return None
    return headed_list(navs[0], epub.nav_href, f"{epub.nav_href} nav", diagnostics)


def printed_contents_entries(href, root, diagnostics):
    body = root.find(f"{{{XHTML}}}body")
    kids = list(body) if body is not None else []
    if body is None or (body.text or "").strip() or len(kids) != 1 or local(kids[0].tag) != "section":
        diagnostics.add("unsupported-contents-shape", href, "expected body > section")
        return None
    if (kids[0].tail or "").strip():
        diagnostics.add("unsupported-contents-shape", href, "text after the contents section")
        return None
    return headed_list(kids[0], href, f"{href} section", diagnostics)


def reconcile_contents(sources, diagnostics):
    """All contents sources must list the same entries: label, target document, fragment, depth, order."""
    name, reference = sources[0]
    for other_name, entries in sources[1:]:
        if len(entries) != len(reference):
            diagnostics.add("contents-sources-disagree", f"{name} vs {other_name}",
                            f"{len(reference)} vs {len(entries)} entries")
            continue
        for index, (a, b) in enumerate(zip(reference, entries)):
            fields = [field for field, x, y in (("label", a[0], b[0]), ("target", a[1:3], b[1:3]), ("depth", a[3], b[3]))
                      if x != y]
            if fields:
                diagnostics.add("contents-sources-disagree", f"{name} vs {other_name}",
                                f"entry {index + 1}: {'/'.join(fields)} differ")
                break
    return reference


def native_contents(entries, documents, chapter_of, source_anchors, diagnostics):
    result = []
    for index, (label, doc, fragment, depth) in enumerate(entries):
        where = f"contents entry {index + 1}"
        role = documents.get(doc, {}).get("role")
        if not label:
            diagnostics.add("contents-label-missing", where)
        if role == "cover":
            target = {"kind": "cover"}
        elif role == "titlePage":
            target = {"kind": "titlePage"}
        elif role == "reading" and not fragment:
            target = {"kind": "chapter", "chapterID": chapter_of[doc]}
        elif role == "reading" and f"{doc}#{fragment}" in source_anchors:
            target = {"kind": "block", "chapterID": chapter_of[doc], "blockID": source_anchors[f"{doc}#{fragment}"]}
        else:
            diagnostics.add("contents-target-not-mapped", where, f"role {role or 'none'}")
            continue
        result.append({"label": label, "depth": depth, "target": target})
    return result



def _convert(epub, edition, registry, migration, tools_mapping):
    diagnostics = Diagnostics()
    if epub.sha256 != edition.get("epubSHA256"):
        raise ConversionFailed(["epub-pin-mismatch: input EPUB SHA-256 differs from edition.epubSHA256"])
    profile = dict(DEFAULT_PROFILE, **edition.get("profile", {}))
    documents = edition.get("documents", {})
    validate_registry(registry, diagnostics)
    diagnostics.raise_if_any()

    spine_hrefs = [href for href, _ in epub.spine]
    for href in spine_hrefs:
        role = documents.get(href, {}).get("role")
        if role not in ROLES:
            diagnostics.add("spine-document-unclassified", href, "every spine document needs a role")
    for href in documents:
        if href not in spine_hrefs:
            diagnostics.add("configured-document-not-in-spine", href)
    xhtml = [i.href for i in epub.manifest.values() if i.media_type == "application/xhtml+xml"]
    for href in xhtml:
        if href not in spine_hrefs and href != epub.nav_href:
            diagnostics.add("xhtml-outside-spine", href)
    diagnostics.raise_if_any()

    roots = {href: parse_xml(epub.read(href), href) for href in spine_hrefs}
    ids_by_doc = {href: element_ids(root) for href, root in roots.items()}

    # Navigation coverage
    points = ncx_points(epub)
    if not points and not epub.nav_href:
        diagnostics.add("navigation-missing", "no NCX or EPUB 3 nav document")
    reading = [h for h in spine_hrefs if documents[h]["role"] == "reading"]
    targeted = set()
    for index, point in enumerate(points):
        where = f"ncx navPoint {index + 1}"
        if point["doc"] not in roots:
            diagnostics.add("nav-target-outside-spine", where)
        elif point["fragment"] and point["fragment"] not in ids_by_doc[point["doc"]]:
            diagnostics.add("nav-fragment-missing", where)
        else:
            targeted.add(point["doc"])
        if point["doc"] in roots and documents[point["doc"]]["role"] == "printedContents":
            diagnostics.add("nav-points-at-printed-contents", where)
    nav_links = nav_doc_links(epub)
    for index, (doc, fragment) in enumerate(nav_links):
        if doc not in roots or (fragment and fragment not in ids_by_doc[doc]):
            diagnostics.add("nav-doc-link-unresolved", f"nav link {index + 1}")
        else:
            targeted.add(doc)
    for href in reading:
        if href not in targeted:
            diagnostics.add("reading-document-not-in-navigation", href)
    contents_links = {"internal": 0, "external": 0}
    for href in [h for h in spine_hrefs if documents[h]["role"] == "printedContents"]:
        for index, a in enumerate(roots[href].iter(f"{{{XHTML}}}a")):
            if not a.get("href"):
                continue
            doc, fragment = resolve_href(href, a.get("href"))
            if doc is None:
                contents_links["external"] += 1
                continue
            contents_links["internal"] += 1
            if doc not in roots or (fragment and fragment not in ids_by_doc[doc]):
                diagnostics.add("contents-link-unresolved", f"{href} link {index + 1}")
            elif documents[doc]["role"] != "reading" and documents[doc]["role"] != "cover" \
                    and documents[doc]["role"] != "titlePage":
                diagnostics.add("contents-link-to-omitted-document", f"{href} link {index + 1}")
    diagnostics.raise_if_any()

    # Reading documents -> chapters
    chapter_of = {}
    source_census = {}
    chapters, new_blocks, doc_blocks = [], [], []
    labels_by_doc = {}
    for point in points:
        if point["doc"] and point["depth"] == 1 and point["doc"] not in labels_by_doc:
            labels_by_doc[point["doc"]] = point["label"]
    for href in reading:
        config = documents[href]
        chapter_id = config.get("chapterID", "")
        if not ID_PATTERN.match(chapter_id) or "." in chapter_id:
            diagnostics.add("invalid-chapter-id", href, "lowercase letters, digits, - and _ only")
        if chapter_id in chapter_of.values():
            diagnostics.add("duplicate-chapter-id", href, chapter_id)
        if config.get("access") not in ("free", "paid"):
            diagnostics.add("chapter-access-missing", href)
        if not config.get("label"):
            diagnostics.add("chapter-label-missing", href)
        chapter_of[href] = chapter_id
        add_counts(source_census, census(roots[href], profile))
        converter = DocConverter(href, roots[href], profile, diagnostics)
        converter.run()
        title = converter.title if converter.title is not None else labels_by_doc.get(href)
        if not title:
            diagnostics.add("chapter-title-missing", href, "no h1 and no navigation label")
        if not converter.blocks:
            diagnostics.add("chapter-without-blocks", href)
        chapters.append({"id": chapter_id, "label": config.get("label", ""), "title": title or "",
                         "access": config.get("access"), "blocks": []})
        doc_blocks.append((href, converter))
    diagnostics.raise_if_any()
    for href, converter in doc_blocks:
        for converted in converter.blocks:
            verify_block(converted, href, diagnostics)
        verify_document_text(href, roots[href], converter, diagnostics)
    diagnostics.raise_if_any()

    document_digests = {href: sha256_bytes(epub.read(href)) for href in reading}
    for (href, converter), chapter in zip(doc_blocks, chapters):
        occurrences = {}
        for converted in converter.blocks:
            fp = fingerprint(converted.block)
            occurrence = occurrences.get(fp, 0)
            occurrences[fp] = occurrence + 1
            new_blocks.append({"chapter": chapter["id"], "source": href, "block": converted.block,
                               "fingerprint": fp, "sourceOccurrence": occurrence,
                               "anchors": sorted(set(converted.anchors))})
    ids, new_registry, id_stats = assign_ids(new_blocks, registry, migration, chapter_of, document_digests, diagnostics)
    diagnostics.raise_if_any()

    source_anchors = {}
    for b, block_id in zip(new_blocks, ids):
        for anchor in b["anchors"]:
            source_anchors.setdefault(f"{b['source']}#{anchor}", block_id)
    position = 0
    for chapter, (href, converter) in zip(chapters, doc_blocks):
        for converted in converter.blocks:
            block = dict(converted.block)
            chapter["blocks"].append(dict({"id": ids[position]}, **block))
            position += 1
        source_anchors[href] = chapter["blocks"][0]["id"]
    for index, point in enumerate(points):
        if point["doc"] in chapter_of:
            key = f"{point['doc']}#{point['fragment']}" if point["fragment"] else point["doc"]
            if key not in source_anchors:
                diagnostics.add("nav-target-not-mapped", f"ncx navPoint {index + 1}", "fragment is not inside a block")

    output_counts = output_census(chapters)
    reconcile(source_census, output_counts, diagnostics)
    expected = edition.get("expectedCensus", {})
    for key, value in sorted(expected.items()):
        if source_census.get(key) != value:
            diagnostics.add("expected-census-mismatch", key, f"expected {value}, found {source_census.get(key)}")
    for key in ("pre", "img", "svg", "math", "audio", "video", "figure", "br", "h5", "h6"):
        if source_census.get(key):
            diagnostics.add("unsupported-element-present", key, f"{source_census[key]} occurrences")

    tools = None
    if tools_mapping is not None:
        tools = build_tools(tools_mapping, chapters, diagnostics)
    diagnostics.raise_if_any()

    book = {
        "contentVersion": edition["contentVersion"],
        "isFixture": False,
        "title": edition["title"],
        "chapters": chapters,
        "idMap": new_registry["idMap"] or None,
        "sourceAnchors": dict(sorted(source_anchors.items())),
        "tools": tools or {"filterQuestions": [], "rolloutItems": []},
    }
    if book["idMap"] is None:
        del book["idMap"]

    # Front matter: cover, title page and the source contents, presented natively.
    presentation = {}
    cover_docs = [h for h in spine_hrefs if documents[h]["role"] == "cover"]
    title_docs = [h for h in spine_hrefs if documents[h]["role"] == "titlePage"]
    for role, found in (("cover", cover_docs), ("titlePage", title_docs)):
        if len(found) > 1:
            diagnostics.add("front-matter-role-repeated", role, f"{len(found)} documents")
    cover = None
    if cover_docs and not epub.cover_href:
        diagnostics.add("cover-image-missing", cover_docs[0], "no cover image in the manifest")
    if epub.cover_href and not cover_docs:
        diagnostics.add("cover-document-missing", epub.cover_href, "a cover image needs a document with role cover")
    if epub.cover_href and cover_docs:
        data = epub.read(epub.cover_href)
        cover = {"href": epub.cover_href, "bytes": len(data), "sha256": sha256_bytes(data), "data": data}
        if edition.get("coverSHA256") and edition["coverSHA256"] != cover["sha256"]:
            raise ConversionFailed(["cover-pin-mismatch: cover image SHA-256 differs from edition.coverSHA256"])
        alt = convert_cover(cover_docs[0], roots[cover_docs[0]], epub, diagnostics)
        if alt is not None:
            cover["alt"] = alt
            extension = posixpath.splitext(epub.cover_href)[1].lower()
            if extension not in COVER_EXTENSIONS:
                raise ConversionFailed([f"unsupported-cover-format: {extension or 'none'} (supported: .jpg, .jpeg, .png)"])
            cover["resource"] = COVER_RESOURCE_STEM + extension
            presentation["cover"] = {"resource": cover["resource"], "alt": alt, "sha256": cover["sha256"],
                                     "byteCount": cover["bytes"]}
    if title_docs:
        title_page = convert_title_page(title_docs[0], roots[title_docs[0]], profile, diagnostics)
        if title_page is not None:
            presentation["titlePage"] = title_page
    sources = []
    if points:
        sources.append(("ncx", [(p["label"], p["doc"], p["fragment"], p["depth"]) for p in points]))
    if epub.nav_href:
        entries = nav_doc_entries(epub, diagnostics)
        if entries is not None:
            sources.append(("nav", entries))
    for href in [h for h in spine_hrefs if documents[h]["role"] == "printedContents"]:
        entries = printed_contents_entries(href, roots[href], diagnostics)
        if entries is not None:
            sources.append((f"printed {href}", entries))
    diagnostics.raise_if_any()
    if sources:
        reference = reconcile_contents(sources, diagnostics)
        presentation["contents"] = native_contents(reference, documents, chapter_of, source_anchors, diagnostics)
    diagnostics.raise_if_any()
    book["presentation"] = presentation

    omitted = [omitted_document_record(h, documents[h]["role"], roots[h])
               for h in spine_hrefs if documents[h]["role"] != "reading"]
    front_matter = {record["href"]: private for record, private in omitted}
    report = {
        "format": REPORT_FORMAT,
        "epub": {"bytes": epub.size, "sha256": epub.sha256, "entries": len(epub.zip.namelist()),
                 "manifestItems": len(epub.manifest), "xhtml": len(xhtml), "spine": len(spine_hrefs)},
        "documents": [{"href": h, "role": documents[h]["role"], "chapterID": chapter_of.get(h)} for h in spine_hrefs],
        # Front-matter documents are not reading chapters. The cover and title page are presented
        # natively from book.presentation; the printed contents is reconciled with the NCX and nav
        # and presented as the native contents. The report holds counts and hashes only.
        "frontMatterDocuments": [record for record, _ in omitted],
        "presentation": {
            "cover": "cover" in presentation,
            "titlePageElements": len(presentation.get("titlePage", {}).get("elements", [])),
            "contentsEntries": len(presentation.get("contents", [])),
            "contentsByDepth": {str(d): sum(1 for e in presentation.get("contents", []) if e["depth"] == d)
                                for d in sorted({e["depth"] for e in presentation.get("contents", [])})},
            "contentsTargets": {k: sum(1 for e in presentation.get("contents", []) if e["target"]["kind"] == k)
                                for k in ("cover", "titlePage", "chapter", "block")},
            "contentsSources": [name.split(" ")[0] for name, _ in sources],
        },
        "navigation": {"ncxTopLevel": sum(1 for p in points if p["depth"] == 1), "ncxTotal": len(points),
                       "navDocLinks": len(nav_links), "printedContentsLinks": contents_links},
        "sourceCensus": dict(sorted(source_census.items())),
        "outputCensus": output_counts,
        "chapters": len(chapters),
        "blocks": len(new_blocks),
        "sourceAnchors": len(source_anchors),
        "ids": id_stats,
        "tools": None if tools is None else {"filterQuestions": len(tools["filterQuestions"]),
                                             "rolloutItems": len(tools["rolloutItems"])},
        "cover": None if cover is None else {k: cover[k] for k in ("href", "bytes", "sha256")},
        "bundleComplete": tools is not None,
    }
    # Private, never in the report: cover bytes and alt text, and the omitted documents' text.
    extras = {"cover": cover, "frontMatter": front_matter}
    return book, new_registry, report, extras


FIXED_OUTPUT_NAMES = {"book.private.json", "book.draft.json", "id-registry.json", "conversion-report.json",
                      "cover.json", "front-matter.json"}
COVER_OUTPUT_NAMES = {COVER_RESOURCE_STEM + extension for extension in COVER_EXTENSIONS}


def write_outputs(out_dir, book, registry, report, extras):
    out = Path(out_dir)
    name = "book.private.json" if report["bundleComplete"] else "book.draft.json"
    files = {name: pretty_json(book).encode("utf-8"),
             "id-registry.json": pretty_json(registry).encode("utf-8"),
             "conversion-report.json": pretty_json(report).encode("utf-8")}
    cover = (extras or {}).get("cover")
    if cover is not None:
        # Named as book.presentation.cover.resource, the name a private build packages it under.
        # Checked first: only cover.private.<jpg|jpeg|png>, so it can't be a path or another output.
        if cover.get("resource") not in COVER_OUTPUT_NAMES:
            raise ConversionFailed(["refused: unexpected cover output name"])
        files[cover["resource"]] = cover["data"]
        files["cover.json"] = pretty_json({"alt": cover["alt"], "sha256": cover["sha256"]}).encode("utf-8")
    if (extras or {}).get("frontMatter"):
        # The omitted documents' text, kept for the later native presentation work.
        files["front-matter.json"] = pretty_json(extras["frontMatter"]).encode("utf-8")
    # Every name is checked before anything is created: only the fixed output names and
    # cover.private.<jpg|jpeg|png> are allowed, so nothing can be written outside the folder.
    for filename in files:
        if filename not in FIXED_OUTPUT_NAMES | COVER_OUTPUT_NAMES:
            raise ConversionFailed(["refused: unexpected output file name"])
    if inside_git_tree(out.parent if not out.exists() else out):
        raise ConversionFailed(["refused: output folder is inside a Git working tree"])
    if out.exists():
        raise ConversionFailed(["refused: output folder already exists"])
    out.mkdir(parents=True)
    root = out.resolve()
    for filename, data in sorted(files.items()):
        target = (out / filename).resolve()
        if target.parent != root:
            raise ConversionFailed(["refused: output path escapes the output folder"])
        with open(target, "xb") as handle:  # never overwrite
            handle.write(data)
    return {filename: sha256_bytes(data) for filename, data in sorted(files.items())}


def inspect(epub_path, profile_overrides=None):
    profile = dict(DEFAULT_PROFILE, **(profile_overrides or {}))
    epub = open_epub(epub_path)
    try:
        return _inspect(epub, profile)
    finally:
        epub.close()


def _inspect(epub, profile):
    documents = []
    for href, linear in epub.spine:
        root = parse_xml(epub.read(href), href)
        documents.append({"href": href, "linear": linear, "census": census(root, profile)})
    points = ncx_points(epub)
    return {
        "epub": {"bytes": epub.size, "sha256": epub.sha256, "entries": len(epub.zip.namelist()),
                 "manifestItems": len(epub.manifest),
                 "xhtml": sum(1 for i in epub.manifest.values() if i.media_type == "application/xhtml+xml"),
                 "ncx": epub.ncx_href, "nav": epub.nav_href, "cover": epub.cover_href},
        "spine": documents,
        "navigation": {"ncxTopLevel": sum(1 for p in points if p["depth"] == 1), "ncxTotal": len(points),
                       "ncxTargets": [{"depth": p["depth"], "doc": p["doc"], "hasFragment": bool(p["fragment"])}
                                      for p in points]},
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_inspect = sub.add_parser("inspect", help="non-prose structure report")
    p_inspect.add_argument("--epub", required=True)
    p_convert = sub.add_parser("convert", help="convert a pinned EPUB")
    p_convert.add_argument("--epub", required=True)
    p_convert.add_argument("--edition", required=True)
    group = p_convert.add_mutually_exclusive_group(required=True)
    group.add_argument("--registry", help="existing private ID registry")
    group.add_argument("--new-registry", action="store_true", help="first edition: allocate every ID")
    p_convert.add_argument("--migration", help="explicit assign/migrations/retired decisions")
    p_convert.add_argument("--tools", help="tool mapping; without it only a draft bundle is written")
    p_convert.add_argument("--out", required=True, help="new folder outside any Git working tree")
    args = parser.parse_args(argv)
    try:
        if args.command == "inspect":
            # ASCII-escaped so a Windows console code page can't fail on non-ASCII file names.
            print(json.dumps(inspect(args.epub), sort_keys=True, indent=2, ensure_ascii=True))
            return 0
        if inside_git_tree(Path(args.out).parent):
            raise ConversionFailed(["refused: output folder is inside a Git working tree"])
        if not Path(args.epub).is_file():
            raise ConversionFailed(["missing-input: epub"])
        edition = load_json(args.edition, "edition")
        registry = empty_registry() if args.new_registry else load_json(args.registry, "registry")
        migration = load_json(args.migration, "migration") if args.migration else {}
        tools = load_json(args.tools, "tools") if args.tools else None
        book, new_registry, report, extras = convert(args.epub, edition, registry, migration, tools)
        hashes = write_outputs(args.out, book, new_registry, report, extras)
        print(json.dumps({"written": hashes, "ids": report["ids"], "blocks": report["blocks"],
                          "bundleComplete": report["bundleComplete"]}, sort_keys=True, indent=2, ensure_ascii=True))
        return 0
    except ConversionFailed as failure:
        for line in failure.diagnostics:
            print(line, file=sys.stderr)
        print(f"conversion failed: {len(failure.diagnostics)} diagnostic(s)", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
