#!/usr/bin/env bash
# Compares source files with their copies in a built product, byte for byte.
# Prints each pair's size and SHA-256 and fails if any copy is missing or differs.
#
#   bash apps/ai-bible-ios/ci/check-resource-bytes.sh <source> <built copy> [<source> <built copy> ...]
set -euo pipefail

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1
}

[[ $# -gt 0 && $(( $# % 2 )) -eq 0 ]] || { echo "check-resource-bytes: expected source/copy pairs" >&2; exit 2; }
status=0
while [[ $# -gt 0 ]]; do
  source_file="$1" built_file="$2"
  shift 2
  if [[ ! -f "$source_file" ]]; then
    echo "check-resource-bytes: source missing: $(basename "$source_file")" >&2; status=1; continue
  fi
  if [[ ! -f "$built_file" ]]; then
    echo "check-resource-bytes: built copy missing: $(basename "$built_file")" >&2; status=1; continue
  fi
  source_sha="$(sha256_of "$source_file")" built_sha="$(sha256_of "$built_file")"
  source_bytes="$(wc -c < "$source_file" | tr -d ' ')" built_bytes="$(wc -c < "$built_file" | tr -d ' ')"
  echo "$(basename "$source_file"): source $source_bytes B $source_sha; built $built_bytes B $built_sha"
  if [[ "$source_sha" != "$built_sha" || "$source_bytes" != "$built_bytes" ]]; then
    echo "check-resource-bytes: $(basename "$built_file") differs from its source" >&2
    status=1
  fi
done
exit "$status"
