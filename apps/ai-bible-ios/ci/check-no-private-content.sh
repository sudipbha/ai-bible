#!/usr/bin/env bash
# Fails if a folder (normally a built AIBible.app) holds converted or private book content.
# Public builds package only the synthetic fixture. Prints file names only, never contents.
#
#   bash apps/ai-bible-ios/ci/check-no-private-content.sh <folder>
set -euo pipefail

root="${1:-}"
[[ -n "$root" && -d "$root" ]] || { echo "check-no-private-content: folder not found" >&2; exit 2; }

hits="$(find "$root" -type f \( \
    -iname '*.epub' \
    -o \( -name 'book.*.json' ! -name 'book.fixture.json' \) \
    -o -name '*.private.*' \
    -o -name 'id-registry*.json' \
    -o -name 'conversion-report*.json' \
    -o -name 'front-matter.json' \
    -o -name 'cover.json' \
    -o -iname 'cover.jpg' -o -iname 'cover.jpeg' -o -iname 'cover.png' \
  \) -print | sed "s|^$root/||" | LC_ALL=C sort)"

if [[ -n "$hits" ]]; then
  echo "check-no-private-content: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') private or converted file(s):" >&2
  printf '  %s\n' "$hits" >&2
  exit 1
fi
echo "No private or converted content in $(basename "$root")"
