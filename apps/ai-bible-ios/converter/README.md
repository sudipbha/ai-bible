# EPUB converter (local, private input)

`aibible_convert.py` turns a pinned EPUB into the app's `BookBundle` JSON. It uses only the Python
standard library (Python 3.9 or later) and runs on the owner's machine.
Its tests have run here only on Linux with Python 3.11. It is written to run on Windows and macOS as well,
but the Windows fixes in this version have not been rerun on Windows. **Nothing here has been run against the real book.**
The tests use invented EPUBs built in `tests/synthetic_epub.py`.

```
python3 -m unittest discover -s apps/ai-bible-ios/converter/tests   # synthetic tests
```

## What stays private

The EPUB, the edition config, the ID registry, the tool mapping, the migration decisions, and
everything the converter writes (book JSON, report, cover) are private.
- The converter refuses to write inside any Git working tree, and it refuses an output folder that
  already exists.
- `.gitignore` also lists the private file names, as a second guard.
- Diagnostics and the report never contain book text. They name files, element paths, tags,
  classes, IDs, fingerprints and counts only.
- Public builds and CI package only `book.fixture.json`. `ci/run-tests.sh` and
  `ContentPackagingTests` fail if any converted or private file is in the app bundle.

## Inputs

| Input | Purpose |
|---|---|
| `--epub` | The EPUB. Its SHA-256 must equal `epubSHA256` in the edition config. |
| `--edition` | Spine roles, chapter IDs, labels and access, class profile, pins, expected census. See `templates/edition.template.json`. |
| `--registry` or `--new-registry` | The private ID registry. `--new-registry` is only for the very first conversion; a missing registry is never treated as a new one. |
| `--migration` (optional) | Explicit `assign`, `migrations` and `retired` decisions. See "IDs" below. |
| `--tools` (optional) | Which converted blocks supply the five Filter prompts and the rollout items. Without it the output is `book.draft.json`, which the app refuses to load, because it has no tools. |
| `--out` | A new folder outside Git. It receives `book.private.json` (or `book.draft.json`), `id-registry.json`, `conversion-report.json`, the cover image (always `cover.private.jpg`, `.jpeg` or `.png`; other cover formats fail), `cover.json` and `front-matter.json`. Every output name is checked against that fixed list before the folder is created, and no file is overwritten. |

`inspect --epub <file>` prints a non-prose structure report: spine file names, per-document tag and
class counts, and navigation targets. Use it to fill in the edition config.

## Document roles

Every spine document needs a role:
- `cover`, `titlePage` and `printedContents` are front matter. They are not chapters; the app presents
  them natively from `book.presentation`:
  - **Cover:** the document must be wrappers (`div`, `section`, `figure`) around exactly one `img`, whose
    `src` is the manifest's cover image, with non-empty `alt` and no text. The image bytes are written
    unchanged as `cover.private.<ext>`; the book records that name, the alt text, size and SHA-256.
    The name can't be configured (an edition's `coverResourceName` is rejected).
  - **Title page:** `body > section.title-page`, whose children are `h1` (title), `h2` (subtitle),
    `p.author` (author) or a plain `p` (paragraph), in source order. Inline strong, emphasis and code
    are kept as Markdown, checked by round trip and a whole-page text check.
  - **Contents:** the NCX, the EPUB 3 nav `toc` and the printed contents (`body > section` with headings
    then one nested `ol > li > a`, and no text after the section) must list exactly the same entries: plain-text label, target and
    depth, in the same order. Each entry is mapped natively: cover, title page, a chapter (no
    fragment) or the block holding the fragment. An unmapped target fails.

  The report gives each front-matter document's status (`presented-natively` or
  `reconciled-to-native-contents`), counts and hashes, never labels or text. `front-matter.json` still
  records each document's whitespace-collapsed text for accounting; the app doesn't use it.
- `reading` documents become chapters, in spine order.

The converter fails in any of these cases:
- a spine document has no role;
- a configured document isn't in the spine;
- an XHTML file is neither in the spine nor the EPUB 3 nav document;
- an NCX or nav target doesn't resolve;
- a reading document has no navigation entry;
- navigation points at the printed contents;
- a printed-contents link doesn't resolve.

## What is converted

| Source | Output |
|---|---|
| `h1` (at most one, first, plain text) | chapter title. A document without `h1` uses its NCX label. |
| `h2`, `h3` | heading, level 2 or 3 |
| `p` | paragraph |
| `ul`, `ol` (with `start`) | list, with `ordered` and `start` |
| `blockquote` whose children are all `p` | quote, one entry per paragraph |
| `aside` with a source-note class and exactly one `p` | note (shown as "Source note", distinct from quotes) |
| `hr` | divider |
| `section.table-cards` | cards block (see below) |
| simple `table` (one header row, equal rows) | the existing table block |
| `strong`/`b`, `em`/`i`, `code`, external `a` | inline Markdown, with every literal special character escaped |
| wrapper `section`, `article`, `header`, `footer`, `main`, and class-less `div` | transparent |

**Card groups:**
- `section.table-cards` has an optional leading `p.table-label` (the group label), then `section.table-card` children.
- Each card holds `div.table-field` children in order.
- A field is a `p.table-label` followed by either an `h4.table-card-title` (the card's title) or a `div.table-value`.
- A value keeps its inline text, its emphasis and its `span.blank-field` blanks. Each blank keeps its printed text and its `aria-label`.
- Section `aria-label`s are kept as accessibility labels.
- Cards are never merged into shared columns.

**Unsupported shapes fail with a bounded diagnostic; nothing is dropped.** These include:
- nested lists, block content inside `li`, `ol type`/`reversed`, `li value`;
- `h4` outside a card field, `h5`, `h6`, a second or late `h1`, and markup inside `h1`;
- `pre`, `img`, `figure`, `svg`, `math`, `audio`, `video`, `dl`, `br`;
- inline elements other than those listed above, classed `span`s or `div`s not in the profile, and
  wrappers with an `aria-label`;
- `aside`s that aren't source notes, and notes with more than one paragraph;
- any other card, field or value shape; blanks without an `aria-label`, or outside a card value;
- internal links inside reading text, and text outside blocks;
- inline code containing a backtick;
- emphasis boundaries that Markdown can't express, such as `a<strong>"b"</strong>c`;
- an XML error (reported by line and column).

**Checks after conversion:**
- Every block is decoded back to plain text and compared with the source's visible text, which
  covers order, punctuation, URLs and tails.
- Each reading document's whole visible body text, with whitespace removed, must equal its chapter
  title plus all of its blocks' text, in order. Any text a shape check missed, such as text between
  list items, fails as `document-text-mismatch`.
- Source and output structure counts are reconciled: lists, items, ordered starts, quotes and their
  paragraphs, notes, dividers, card groups, cards, fields, labels, values, titles, blanks, strong,
  em, code and raw URLs.
- `expectedCensus` in the edition config is asserted against the source.

## IDs

A block's content fingerprint is the SHA-256 of its canonical JSON, without the ID. For every block
the registry records its ID, fingerprint, source document, position among identical blocks in that
document (`sourceOccurrence`) and source anchors (element `id`s). It also records the SHA-256 of
every reading document.

A block keeps its ID only on evidence that it is the same block:
- **Unique content:** its fingerprint occurs once in the registry and once in this edition. It keeps
  its ID wherever it moved.
- **Identical blocks with an anchor:** it has the same source anchor as a registry entry.
- **Identical blocks in an unchanged document:** its whole source document is byte-identical to the
  registered one, and its position among identical blocks is the same.

Equal counts or book-wide order are **not** identity. Identical blocks without an anchor in a
changed document stop the conversion with `ambiguous-identical-blocks`, which lists the registry IDs
and the candidate positions, until an explicit `assign` resolves them.

Other rules:
- **New content:** it gets the next unused ID in its chapter, for example `ch03.p0042`. IDs are
  never reused, including retired ones.
- **Changed or removed content:** conversion fails, naming the IDs, until each one is resolved
  explicitly in the migration file:
  - `assign` keeps the ID for a specific new block, given by source, fingerprint and `sourceOccurrence`;
  - `migrations` sends the old ID to a new block (written to the bundle's `idMap`, which the app follows);
  - `retired` lets saved places fall back to the quote match or chapter start.
- **Authored IDs:** registry entries can be renamed by hand, for example `appx.filter.worksheet`.
- **No positional or fuzzy matching.** Re-running with the same inputs gives byte-identical output.

Source anchors map `file.xhtml` and `file.xhtml#fragment` to block IDs. The app validates them but
does not yet follow internal links.

## Tools

The mapping names blocks (and list items) by ID. The converter copies their Markdown exactly, so
nobody retypes book wording. It checks:
- exactly five Filter prompts;
- unique, well-formed prompt IDs;
- each referenced block exists in the named chapter, and each item index is valid;
- the cost chapter exists.

The Filter is free. If its wording comes from a paid chapter, the mapping must say so with
`freeToolUsesPaidChapterText: true`.

## Private staging build (prepared, not run)

`stage-private-build.sh` builds the app on a Mac with a reviewed `book.private.json`:
1. It verifies the file's SHA-256 and checks it is a complete, non-fixture edition.
2. It exports the committed sources with `git archive` into a new folder outside Git.
3. If the book declares a cover, it requires `--cover` and `--expect-cover-sha256`. The file's SHA-256
   must equal both that value and the book's record, and its size must match. A cover given for a book
   that declares none is refused.
4. It copies only the book JSON and that cover (under the resource name the book records) and builds
   with `AIBIBLE_PRIVATE_BOOK` defined. That build loads `book.private`, checks the cover's size and
   SHA-256, and shows an error, not the fixture, if anything is missing, invalid or different.

It doesn't test, install, sign or upload anything. `front-matter.json`, the report and the registry are
never packaged.

The script is POSIX bash, and building needs macOS and Xcode:
- Its refusal checks (missing inputs, SHA-256 mismatch, fixture input, cover missing, different or
  undeclared, work folder inside a Git tree) are tested wherever bash exists.
- Where bash is absent, the Python tests report that test class as skipped, not passed.
- The SHA-256 is read from standard input, so Windows-style paths don't break it.
