"""Builds small synthetic EPUBs for the converter tests.

All text here is invented test wording. It is not taken from the book, its sample
chapter or its website. SENTINEL appears in every prose run so tests can prove
that diagnostics and reports never echo book text.
"""

import copy
import hashlib
import io
import zipfile

SENTINEL = "Zebrafog"

XHTML_OPEN = (
    '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head><title>t</title></head>'
)
XHTML_HEAD = XHTML_OPEN + "<body>"
XHTML_TAIL = "</body></html>"


def xhtml(content):
    """Wraps body content; content that brings its own <body ...> is used as the body."""
    if content.startswith("<body"):
        return XHTML_OPEN + content + "</html>"
    return XHTML_HEAD + content + XHTML_TAIL

def _png(width=2, height=3):
    """A tiny, valid, deterministic PNG so the app can actually decode the synthetic cover."""
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    rows = b"".join(b"\x00" + bytes([40, 90, 160] * width) for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


COVER_BYTES = _png()

NAV_POINTS = [  # (label, src, children); invented labels
    ("Cover", "cover.xhtml", []),
    ("Title", "title.xhtml", []),
    ("Copyright", "copyright.xhtml", []),
    ("Before", "front.xhtml", []),
    ("One", "ch1.xhtml", [("Styles", "ch1.xhtml#s2", [])]),
    ("Two", "ch2.xhtml#top", []),
    ("Appendix", "appendix.xhtml", []),
]


def toc_list(points):
    return "<ol>" + "".join(
        f'<li><a href="{src}">{label}</a>{toc_list(children) if children else ""}</li>' for label, src, children in points
    ) + "</ol>"


def printed_contents(points):
    return f"<section><h1>Contents</h1>{toc_list(points)}</section>"


DOCUMENTS = {
    "cover.xhtml": f'<body class="cover"><div class="cover"><img src="images/cover.png" alt="{SENTINEL} cover art"/></div></body>',
    "title.xhtml": (
        f'<section class="title-page" epub:type="titlepage"><h1>{SENTINEL} <em>Field</em> Notes</h1>'
        '<p class="author">Example <strong>Studio</strong> with <code>v2</code></p></section>'
    ),
    "contents.xhtml": printed_contents(NAV_POINTS),
    "copyright.xhtml": f"<p>Copyright {SENTINEL} fixture. All rights invented.</p>",
    "front.xhtml": f'<h1>Before {SENTINEL} starts</h1><p>A short invented preface.</p>',
    "ch1.xhtml": (
        f'<section epub:type="chapter" id="c1"><h1 id="t1">{SENTINEL} One</h1>'
        f"<p>Plain {SENTINEL} opening with <strong>strong</strong>, <em>emphasis</em>, "
        "<code>inline_code()</code> and tail text.</p>"
        '<h2 id="s2">Styles and marks</h2>'
        "<p>Literal marks * _ ` [x] &lt;tag&gt; &amp; ~ ! \\ stay as typed; see "
        "https://example.com/a_b*c?d=[1] now.</p>"
        "<ul><li>First <strong>bold</strong> item</li><li>Second <em>soft</em> item with <code>x</code></li></ul>"
        '<ol start="4"><li>Fourth step</li><li>Fifth step</li></ol>'
        "<ol><li>Default one</li><li>Default two</li></ol>"
        '<aside epub:type="footnote" class="source-notes"><p><strong>Source:</strong> invented study, '
        "<code>ref-9</code>, tail.</p></aside>"
        "<hr/>"
        "<h3>Minor heading</h3><p>After the divider.</p></section>"
    ),
    "ch2.xhtml": (
        f'<h1 id="top">{SENTINEL} Two</h1>'
        '<section class="table-cards" aria-label="Invented comparison">'
        '<p class="table-label">Group label</p>'
        '<section class="table-card" aria-label="Card A">'
        '<div class="table-field"><p class="table-label">Tool</p><h4 class="table-card-title">Alpha</h4></div>'
        '<div class="table-field"><p class="table-label">Use</p><div class="table-value">Drafting notes</div></div>'
        '<div class="table-field"><p class="table-label">Cost</p>'
        '<div class="table-value">About <strong>$5</strong> a month, billed yearly</div></div>'
        "</section>"
        '<section class="table-card" aria-label="Card B">'
        '<div class="table-field"><p class="table-label">Tool</p><h4 class="table-card-title">Beta</h4></div>'
        '<div class="table-field"><p class="table-label">Owner</p>'
        '<div class="table-value"><span class="blank-field" aria-label="Write the owner">________</span></div></div>'
        '<div class="table-field"><p class="table-label">Verdict</p><div class="table-value"><strong>Keep</strong></div></div>'
        '<div class="table-field"><p class="table-label">Review</p>'
        '<div class="table-value">Every <span class="blank-field" aria-label="Number of weeks">____</span> weeks</div></div>'
        "</section></section>"
        "<blockquote><p>Quoted one.</p><p>Quoted two.</p><p>Quoted <em>three</em>.</p><p>Quoted four.</p></blockquote>"
        f"<p>Closing {SENTINEL} paragraph.</p>"
    ),
    "appendix.xhtml": (
        f"<h1>{SENTINEL} Appendix</h1><h2>Worksheet</h2>"
        "<ol><li>Pick a task</li><li>Time it</li><li>Try the tool</li><li>Check the result</li><li>Decide</li></ol>"
        "<p>Repeated line.</p><p>Repeated line.</p>"
    ),
}

SPINE = ["cover.xhtml", "title.xhtml", "copyright.xhtml", "contents.xhtml", "front.xhtml",
         "ch1.xhtml", "ch2.xhtml", "appendix.xhtml"]



def ncx(points):
    counter = [0]

    def render(items):
        out = ""
        for label, src, children in items:
            counter[0] += 1
            out += (f'<navPoint id="n{counter[0]}" playOrder="{counter[0]}"><navLabel><text>{label}</text></navLabel>'
                    f'<content src="{src}"/>{render(children)}</navPoint>')
        return out

    return ('<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            f"<head/><docTitle><text>x</text></docTitle><navMap>{render(points)}</navMap></ncx>")


def nav_doc(points):
    return XHTML_HEAD + f'<nav epub:type="toc"><h1>Contents</h1>{toc_list(points)}</nav>' + XHTML_TAIL


def build(documents=None, spine=None, nav_points=None, extra_xhtml=None, include_nav=True, cover=True,
          nav_doc_points=None, cover_href="images/cover.png"):
    documents = copy.deepcopy(DOCUMENTS if documents is None else documents)
    spine = list(SPINE if spine is None else spine)
    nav_points = NAV_POINTS if nav_points is None else nav_points
    manifest, files = [], {}
    for index, href in enumerate(sorted(set(spine) | set(extra_xhtml or []))):
        manifest.append(f'<item id="x{index}" href="{href}" media-type="application/xhtml+xml"/>')
        files[f"OEBPS/{href}"] = xhtml(documents.get(href, "<p>extra</p>"))
    ids = {href: f"x{i}" for i, href in enumerate(sorted(set(spine) | set(extra_xhtml or [])))}
    manifest.append('<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
    files["OEBPS/toc.ncx"] = ncx(nav_points)
    if include_nav:
        manifest.append('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
        files["OEBPS/nav.xhtml"] = nav_doc(nav_points if nav_doc_points is None else nav_doc_points)
    if cover:
        manifest.append(f'<item id="cov" href="{cover_href}" media-type="image/png" properties="cover-image"/>')
        files[f"OEBPS/{cover_href}"] = COVER_BYTES
    manifest.append('<item id="css" href="style.css" media-type="text/css"/>')
    files["OEBPS/style.css"] = "p { margin: 0 }"
    spine_xml = "".join(f'<itemref idref="{ids[h]}"/>' for h in spine)
    files["OEBPS/content.opf"] = (
        '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
        f'<metadata/><manifest>{"".join(manifest)}</manifest><spine toc="ncx">{spine_xml}</spine></package>'
    )
    files["META-INF/container.xml"] = (
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        info = zipfile.ZipInfo("mimetype", date_time=(2026, 1, 1, 0, 0, 0))
        archive.writestr(info, "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            data = files[name] if isinstance(files[name], bytes) else files[name].encode("utf-8")
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)
    return buffer.getvalue()


def edition(epub_bytes, **overrides):
    config = {
        "format": "aibible-edition/1",
        "contentVersion": "synthetic-2026-09-28.1",
        "title": "Synthetic edition",
        "epubSHA256": hashlib.sha256(epub_bytes).hexdigest(),
        "coverSHA256": hashlib.sha256(COVER_BYTES).hexdigest(),
        "documents": {
            "cover.xhtml": {"role": "cover"},
            "title.xhtml": {"role": "titlePage"},
            "contents.xhtml": {"role": "printedContents"},
            "copyright.xhtml": {"role": "reading", "chapterID": "copyright", "label": "Copyright", "access": "free"},
            "front.xhtml": {"role": "reading", "chapterID": "front", "label": "Before you start", "access": "free"},
            "ch1.xhtml": {"role": "reading", "chapterID": "ch01", "label": "Chapter 1", "access": "free"},
            "ch2.xhtml": {"role": "reading", "chapterID": "ch02", "label": "Chapter 2", "access": "paid"},
            "appendix.xhtml": {"role": "reading", "chapterID": "appx", "label": "Appendices", "access": "paid"},
        },
    }
    config.update(overrides)
    return config


def tools(filter_block, rollout_block, **overrides):
    mapping = {
        "format": "aibible-tools/1",
        "filter": {"chapter": "appx", "freeToolUsesPaidChapterText": True,
                   "prompts": [{"id": f"filter.q{i + 1}", "block": filter_block, "item": i} for i in range(5)]},
        "rollout": {"chapter": "ch01", "items": [{"id": "rollout.s1", "block": rollout_block, "item": 0},
                                                 {"id": "rollout.s2", "block": rollout_block, "item": 1}]},
        "cost": {"chapter": "ch02"},
    }
    mapping.update(overrides)
    return mapping
