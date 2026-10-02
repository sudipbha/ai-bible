#!/usr/bin/env bash
# Local-only staging build of the app with a reviewed PRIVATE book bundle.
#
# Prepared for the owner's Mac. It is never run in CI and must not be pointed at a
# Git working tree: the private bundle and every build product stay in --work.
#
#   DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer \
#   bash apps/ai-bible-ios/converter/stage-private-build.sh \
#     --book <converted book.private.json> --expect-sha256 <its SHA-256> \
#     [--cover <converted cover file> --expect-cover-sha256 <its SHA-256>] \
#     --work <new folder outside Git> --xcodegen <path to xcodegen> \
#     ( --destination 'platform=iOS Simulator,id=<simulator UDID>'      # unsigned Debug build
#     | --release-archive --team <Apple team ID> [--bundle-id <id>] )  # signed Release archive
#
# --release-archive makes a signed Release archive at <work>/AIBible.xcarchive (automatic signing
# with --team; Xcode must be signed in to that team). It never uploads or submits it.
# Only the declared, reviewed files are copied: the book JSON and, when the book declares one,
# its cover image under the resource name the book records. Anything missing, extra or with a
# different SHA-256 or size stops the script before anything is staged.
# The app sources come from the committed HEAD (git archive), not from loose files in the
# checkout, so nothing untracked is swept in. The build defines AIBIBLE_PRIVATE_BOOK, which
# makes the app load book.private.json and refuse anything else (no fallback to the fixture).
# The synthetic sample books are removed from the staged sources, so the build can't bundle or
# select them. After building, ci/verify-private-app.sh checks the app: the reviewed book and cover
# are bundled byte-for-byte, no synthetic content is present, and the executable carries the
# private edition marker. The Debug mode builds only; the archive mode signs but never uploads.
set -euo pipefail

fail() { echo "stage-private-build: $*" >&2; exit 1; }

BOOK="" EXPECT="" WORK="" XCODEGEN="" DESTINATION="" COVER="" EXPECT_COVER="" ARCHIVE=0 TEAM="" BUNDLE_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --book) BOOK="${2:-}"; shift 2 ;;
    --expect-sha256) EXPECT="${2:-}"; shift 2 ;;
    --cover) COVER="${2:-}"; shift 2 ;;
    --expect-cover-sha256) EXPECT_COVER="${2:-}"; shift 2 ;;
    --work) WORK="${2:-}"; shift 2 ;;
    --xcodegen) XCODEGEN="${2:-}"; shift 2 ;;
    --destination) DESTINATION="${2:-}"; shift 2 ;;
    --release-archive) ARCHIVE=1; shift ;;
    --team) TEAM="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    *) fail "unknown argument $1" ;;
  esac
done
[[ -n "$BOOK" && -n "$EXPECT" && -n "$WORK" && -n "$XCODEGEN" ]] \
  || fail "--book, --expect-sha256, --work and --xcodegen are all required"
if [[ "$ARCHIVE" == 1 ]]; then
  [[ -z "$DESTINATION" ]] || fail "--destination is for the Debug build; --release-archive builds for any iOS device"
  [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail "--release-archive needs --team <10-character Apple team ID>"
  [[ -z "$BUNDLE_ID" || "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "--bundle-id must be a reverse-DNS identifier"
else
  [[ -n "$DESTINATION" ]] || fail "--destination is required (or use --release-archive)"
  [[ -z "$TEAM" && -z "$BUNDLE_ID" ]] || fail "--team and --bundle-id are only for --release-archive"
fi
[[ -f "$BOOK" ]] || fail "private book bundle not found"
[[ "$EXPECT" =~ ^[0-9a-f]{64}$ ]] || fail "--expect-sha256 must be 64 lowercase hex characters"
[[ ! -e "$WORK" ]] || fail "--work must not exist yet"

inside_git() {
  local dir
  dir="$(cd "$1" && pwd -P)"
  while [[ "$dir" != "/" ]]; do
    [[ -e "$dir/.git" ]] && return 0
    dir="$(dirname "$dir")"
  done
  return 1
}
WORK_PARENT="$(dirname "$WORK")"
[[ -d "$WORK_PARENT" ]] || fail "parent of --work does not exist"
if inside_git "$WORK_PARENT"; then fail "--work must be outside any Git working tree"; fi

# Hash from stdin so tools never escape or prefix the file name (as they do for Windows paths).
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1
}
actual="$(sha256_of "$BOOK")"
[[ "$actual" == "$EXPECT" ]] || fail "private book bundle SHA-256 does not match --expect-sha256"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to check the private book bundle"
declared="$(python3 - "$BOOK" <<'PY'
import json, re, sys
book = json.load(open(sys.argv[1], encoding="utf-8"))
assert book.get("isFixture") is False
assert len(book["tools"]["filterQuestions"]) == 5 and book["tools"]["rolloutItems"]
assert book["chapters"]
cover = (book.get("presentation") or {}).get("cover")
if cover is None:
    print("none")
else:
    assert re.fullmatch(r"[A-Za-z0-9._-]+", cover["resource"]) and not cover["resource"].startswith(".")
    assert re.fullmatch(r"[0-9a-f]{64}", cover["sha256"]) and cover["byteCount"] > 0
    print(cover["resource"], cover["sha256"], cover["byteCount"])
PY
)" || fail "private book bundle is not a complete, non-fixture edition"
if [[ "$declared" == "none" ]]; then
  [[ -z "$COVER" && -z "$EXPECT_COVER" ]] || fail "--cover given, but the book declares no cover"
else
  read -r COVER_RESOURCE COVER_SHA COVER_BYTES <<< "$declared"
  [[ -n "$COVER" && -n "$EXPECT_COVER" ]] || fail "the book declares a cover: --cover and --expect-cover-sha256 are required"
  [[ -f "$COVER" ]] || fail "cover file not found"
  [[ "$(sha256_of "$COVER")" == "$EXPECT_COVER" ]] || fail "cover SHA-256 does not match --expect-cover-sha256"
  [[ "$EXPECT_COVER" == "$COVER_SHA" ]] || fail "reviewed cover SHA-256 differs from the one the book declares"
  [[ "$(wc -c < "$COVER" | tr -d ' ')" == "$COVER_BYTES" ]] || fail "cover size differs from the one the book declares"
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "building needs macOS with Xcode"
[[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]] || fail "DEVELOPER_DIR must point at the intended Xcode"
[[ -x "$XCODEGEN" ]] || fail "xcodegen not executable at --xcodegen"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
mkdir -p "$WORK"
git -C "$REPO" archive --format=tar HEAD apps/ai-bible-ios | tar -x -C "$WORK"
echo "Sources: commit $(git -C "$REPO" rev-parse HEAD)"
APP="$WORK/apps/ai-bible-ios"
# The synthetic sample books must not be bundled (or selectable) in a private build.
rm -rf "$APP/AIBible/Resources/Fixtures"
mkdir -p "$APP/AIBible/Resources/Private"
cp "$BOOK" "$APP/AIBible/Resources/Private/book.private.json"
[[ "$declared" == "none" ]] || cp "$COVER" "$APP/AIBible/Resources/Private/$COVER_RESOURCE"

cd "$APP"
"$XCODEGEN" generate --spec project.yml --quiet
if [[ "$ARCHIVE" == 1 ]]; then
  CONFIGURATION=Release CONDITIONS='AIBIBLE_PRIVATE_BOOK'
  SIGNING=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic)
  [[ -z "$BUNDLE_ID" ]] || SIGNING+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
else
  CONFIGURATION=Debug CONDITIONS='DEBUG AIBIBLE_PRIVATE_BOOK'
  SIGNING=(CODE_SIGNING_ALLOWED=NO)
fi
# Record the settings Xcode will actually use for the app target and refuse anything unexpected.
settings="$(xcodebuild -showBuildSettings -project AIBible.xcodeproj -target AIBible -configuration "$CONFIGURATION" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" "${SIGNING[@]}" 2>/dev/null)"
active="$(sed -n 's/^ *SWIFT_ACTIVE_COMPILATION_CONDITIONS = //p' <<< "$settings" | head -n 1)"
echo "Build settings: configuration $CONFIGURATION; SWIFT_ACTIVE_COMPILATION_CONDITIONS = $active"
[[ " $active " == *" AIBIBLE_PRIVATE_BOOK "* ]] || fail "AIBIBLE_PRIVATE_BOOK is not active for the app target"
if [[ "$ARCHIVE" == 1 && " $active " == *" DEBUG "* ]]; then fail "the Release archive must not define DEBUG"; fi

if [[ "$ARCHIVE" == 1 ]]; then
  xcodebuild archive -project AIBible.xcodeproj -scheme AIBible -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$WORK/AIBible.xcarchive" \
    -derivedDataPath "$WORK/DerivedData" -allowProvisioningUpdates \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" "${SIGNING[@]}" -quiet
  BUILT="$WORK/AIBible.xcarchive/Products/Applications/AIBible.app"
else
  xcodebuild build -project AIBible.xcodeproj -scheme AIBible -configuration Debug \
    -destination "$DESTINATION" -derivedDataPath "$WORK/DerivedData" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" "${SIGNING[@]}" -quiet
  BUILT="$(find "$WORK/DerivedData/Build/Products" -maxdepth 2 -type d -name 'AIBible.app' | head -n 1)"
fi
[[ -n "$BUILT" && -d "$BUILT" ]] || fail "built AIBible.app not found"
if [[ "$declared" == "none" ]]; then
  bash "$APP/ci/verify-private-app.sh" "$BUILT" "$EXPECT" || fail "the built app failed the private-content checks"
else
  bash "$APP/ci/verify-private-app.sh" "$BUILT" "$EXPECT" "$COVER_RESOURCE" "$EXPECT_COVER" \
    || fail "the built app failed the private-content checks"
fi
if [[ "$ARCHIVE" == 1 ]]; then
  codesign --verify --deep --strict "$BUILT" || fail "the archived app's signature doesn't verify"
  echo "Signed Release archive (not uploaded or submitted): $WORK/AIBible.xcarchive"
else
  echo "Built (not installed or run): $BUILT"
fi
