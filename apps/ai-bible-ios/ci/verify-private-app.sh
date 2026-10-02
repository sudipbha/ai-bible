#!/usr/bin/env bash
# Checks that a built AIBible.app (from a Debug staging build or a Release archive) carries the
# reviewed PRIVATE book, selects it, and contains no synthetic sample content.
#
#   bash ci/verify-private-app.sh <AIBible.app> <book SHA-256> [<cover resource> <cover SHA-256>]
#
# Fails (exit 1) if:
#   - book.private.json is missing or differs from the reviewed SHA-256;
#   - a declared cover is missing or differs;
#   - any synthetic content is bundled: a known fixture file, any *.fixture.json, or any JSON
#     file whose top-level "isFixture" is true;
#   - the executable lacks the private edition marker or contains the synthetic one. The marker
#     is compiled in by AppConfig (AIBIBLE_PRIVATE_BOOK) and logged at launch, so it is kept.
# Exit 2: bad arguments. Prints what it checked. Pure file checks: runs on macOS or Linux.
set -euo pipefail

PRIVATE_MARKER="AIBIBLE_EDITION=private-book"
SYNTHETIC_MARKER="AIBIBLE_EDITION=synthetic-fixture"

fail() { echo "verify-private-app: $*" >&2; exit 1; }
[[ $# -eq 2 || $# -eq 4 ]] || { echo "usage: $0 <AIBible.app> <book sha256> [<cover resource> <cover sha256>]" >&2; exit 2; }
APP="$1" BOOK_SHA="$2" COVER="${3:-}" COVER_SHA="${4:-}"
[[ -d "$APP" ]] || fail "app bundle not found: $APP"
[[ "$BOOK_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "book SHA-256 must be 64 lowercase hex characters" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1
}

[[ -f "$APP/book.private.json" ]] || fail "book.private.json missing from the app"
[[ "$(sha256_of "$APP/book.private.json")" == "$BOOK_SHA" ]] || fail "bundled book.private.json differs from the reviewed bundle"
echo "book.private.json: $BOOK_SHA"
if [[ -n "$COVER" ]]; then
  [[ "$COVER" =~ ^[A-Za-z0-9._-]+$ && "$COVER" != .* ]] || { echo "bad cover resource name" >&2; exit 2; }
  [[ -f "$APP/$COVER" && "$(sha256_of "$APP/$COVER")" == "$COVER_SHA" ]] || fail "bundled cover $COVER differs from the reviewed cover"
  echo "cover $COVER: $COVER_SHA"
fi

python3 - "$APP" "$PRIVATE_MARKER" "$SYNTHETIC_MARKER" <<'PY'
import json, os, plistlib, sys
app, private_marker, synthetic_marker = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
known = {"book.fixture.json", "presentation.fixture.json", "presentation-fixture-cover.png",
         "synthetic-sample-cover.png", "converter-sample.json"}
problems = []
for root, _, files in os.walk(app):
    for name in files:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, app)
        if name in known or name.endswith(".fixture.json"):
            problems.append(f"synthetic file bundled: {rel}")
        elif name.endswith(".json"):
            try:
                data = json.load(open(path, encoding="utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(data, dict) and data.get("isFixture") is True:
                problems.append(f"synthetic (isFixture) JSON bundled: {rel}")
info = os.path.join(app, "Info.plist")
try:
    executable = plistlib.load(open(info, "rb"))["CFBundleExecutable"]
except Exception as error:  # noqa: BLE001 - reported as a failure
    problems.append(f"can't read CFBundleExecutable from Info.plist: {error}")
    executable = None
if executable:
    binary = open(os.path.join(app, executable), "rb").read()
    if private_marker not in binary:
        problems.append("executable lacks the private edition marker (not built with AIBIBLE_PRIVATE_BOOK?)")
    if synthetic_marker in binary:
        problems.append("executable contains the synthetic edition marker (it would select the sample book)")
if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"no synthetic content; executable {executable} selects the private edition")
PY
