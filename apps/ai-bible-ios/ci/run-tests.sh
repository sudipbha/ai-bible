#!/usr/bin/env bash
# Builds and runs the AIBible unit tests on a macOS machine with Xcode.
# Synthetic fixtures only. No signing, no secrets, no caches. The only files kept are the UI tests'
# named screenshots (AIBIBLE-SHOT), copied to $AIBIBLE_SCREENSHOT_DIR when that is set.
#
# Run from anywhere:  bash apps/ai-bible-ios/ci/run-tests.sh
# Requires DEVELOPER_DIR to point at the intended Xcode (it is never guessed).
#
# Optional pins (the workflow sets all three):
#   AIBIBLE_EXPECT_XCODE_BUILD  fail unless `xcodebuild -version` reports this build (e.g. 17F113)
#   AIBIBLE_SIM_DEVICE_TYPE     simulator device type identifier   } both or neither: create one
#   AIBIBLE_SIM_RUNTIME         simulator runtime identifier       } ephemeral simulator, no fallback
# Without the simulator pins, the newest installed iPhone simulator is used (local runs).
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
XCODEGEN_BYTES="4278764"
MIN_IOS_RUNTIME="17.0"   # matches deploymentTarget in project.yml

fail() { echo "::error::$*" >&2; exit 1; }
section() { echo; echo "=== $* ==="; }

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aibible-ci.XXXXXX")"
EPHEMERAL_DEVICE=""
cleanup() {
  if [[ -n "$EPHEMERAL_DEVICE" ]]; then xcrun simctl delete "$EPHEMERAL_DEVICE" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

section "Host and Xcode"
[[ "$(uname -s)" == "Darwin" ]] || fail "This script needs macOS."
echo "Architecture: $(uname -m)"
sw_vers
[[ -n "${DEVELOPER_DIR:-}" ]] || fail "DEVELOPER_DIR is not set; refusing to use the machine's default Xcode."
[[ -d "$DEVELOPER_DIR" ]] || fail "Xcode not found at DEVELOPER_DIR=$DEVELOPER_DIR"
export DEVELOPER_DIR
echo "DEVELOPER_DIR=$DEVELOPER_DIR"
xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
if [[ -n "${AIBIBLE_EXPECT_XCODE_BUILD:-}" ]]; then
  xcode_build="$(xcodebuild -version | awk '/^Build version/ {print $3}')"
  [[ "$xcode_build" == "$AIBIBLE_EXPECT_XCODE_BUILD" ]] \
    || fail "Xcode build is $xcode_build, expected $AIBIBLE_EXPECT_XCODE_BUILD"
fi

section "XcodeGen ${XCODEGEN_VERSION} (pinned archive, checksum-verified)"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o "$WORK/xcodegen.zip" "$XCODEGEN_URL"
actual_bytes="$(stat -f %z "$WORK/xcodegen.zip")"
[[ "$actual_bytes" == "$XCODEGEN_BYTES" ]] || fail "xcodegen.zip is $actual_bytes bytes, expected $XCODEGEN_BYTES"
echo "${XCODEGEN_SHA256}  $WORK/xcodegen.zip" | shasum -a 256 -c -
# Keep the distribution layout: bin/xcodegen finds share/xcodegen/SettingPresets relative to itself.
unzip -q "$WORK/xcodegen.zip" -d "$WORK"
XCODEGEN="$WORK/xcodegen/bin/xcodegen"
[[ -x "$XCODEGEN" ]] || fail "xcodegen binary missing at $XCODEGEN"
[[ -d "$WORK/xcodegen/share/xcodegen/SettingPresets" ]] || fail "SettingPresets missing next to the binary"
file "$XCODEGEN"
archs="$(lipo -archs "$XCODEGEN")"
echo "xcodegen architectures: $archs"
[[ " $archs " == *" $(uname -m) "* ]] || fail "xcodegen has no $(uname -m) slice ($archs)"
"$XCODEGEN" --version

section "Generate project"
cd "$APP_DIR"
"$XCODEGEN" generate --spec project.yml
PROJECT="$APP_DIR/AIBible.xcodeproj"
SCHEME_FILE="$PROJECT/xcshareddata/xcschemes/AIBible.xcscheme"
xcodebuild -list -project "$PROJECT"

section "Check wiring"
[[ -f "$SCHEME_FILE" ]] || fail "Shared scheme not generated at $SCHEME_FILE"
grep -q 'StoreKitConfigurationFileReference' "$SCHEME_FILE" || fail "Scheme has no StoreKit configuration reference"
grep -q 'Products.storekit' "$SCHEME_FILE" || fail "Scheme does not point at StoreKit/Products.storekit"
grep -q 'BlueprintName = "AIBibleTests"' "$SCHEME_FILE" || fail "Scheme test action does not include AIBibleTests"
test_settings="$(xcodebuild -project "$PROJECT" -target AIBibleTests -sdk iphonesimulator -showBuildSettings)"
echo "$test_settings" | grep -E '^\s*(TEST_HOST|BUNDLE_LOADER|IPHONEOS_DEPLOYMENT_TARGET) = '
echo "$test_settings" | grep -Eq '^\s*TEST_HOST = .*/AIBible\.app/AIBible$' || fail "TEST_HOST does not point at AIBible.app"

if [[ -n "${AIBIBLE_SIM_DEVICE_TYPE:-}" || -n "${AIBIBLE_SIM_RUNTIME:-}" ]]; then
section "Create the pinned simulator (no runtime download, no fallback)"
[[ -n "${AIBIBLE_SIM_DEVICE_TYPE:-}" && -n "${AIBIBLE_SIM_RUNTIME:-}" ]] \
  || fail "Set both AIBIBLE_SIM_DEVICE_TYPE and AIBIBLE_SIM_RUNTIME, or neither"
xcrun simctl list devicetypes -j > "$WORK/devicetypes.json"
xcrun simctl list runtimes -j > "$WORK/runtimes.json"
/usr/bin/python3 "$APP_DIR/ci/simulator_preflight.py" --device-type "$AIBIBLE_SIM_DEVICE_TYPE" \
  --runtime "$AIBIBLE_SIM_RUNTIME" --devicetypes-json "$WORK/devicetypes.json" --runtimes-json "$WORK/runtimes.json" \
  || fail "Pinned simulator unavailable: $AIBIBLE_SIM_DEVICE_TYPE on $AIBIBLE_SIM_RUNTIME (not substituting another)"
EPHEMERAL_DEVICE="$(xcrun simctl create "AIBible CI $(date +%s)" "$AIBIBLE_SIM_DEVICE_TYPE" "$AIBIBLE_SIM_RUNTIME")" \
  || fail "simctl could not create $AIBIBLE_SIM_DEVICE_TYPE on $AIBIBLE_SIM_RUNTIME"
DEVICE_ID="$EPHEMERAL_DEVICE"
echo "Created ephemeral simulator $DEVICE_ID"
else
section "Pick an installed iPhone simulator (no runtime download)"
DEVICE_ID="$(xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json, re, sys
minimum = tuple(int(p) for p in sys.argv[1].split("."))
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    if version < minimum:
        continue
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"], "%d.%d" % version)
if best is None:
    sys.exit(1)
print(best[1])
print("Selected %s, iOS %s" % (best[2], best[3]), file=sys.stderr)
' "$MIN_IOS_RUNTIME")" || fail "No available iPhone simulator with iOS >= $MIN_IOS_RUNTIME for this Xcode"
fi
DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
xcodebuild -project "$PROJECT" -scheme AIBible -showdestinations | grep -F "$DEVICE_ID" \
  || fail "Selected simulator $DEVICE_ID is not a valid destination for the AIBible scheme"

section "Build for testing"
DERIVED="$WORK/DerivedData"
xcodebuild build-for-testing \
  -project "$PROJECT" -scheme AIBible -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO

section "Check bundled resources"
APP_BUNDLE="$(find "$DERIVED/Build/Products" -maxdepth 2 -type d -name 'AIBible.app' | head -n 1)"
[[ -n "$APP_BUNDLE" ]] || fail "AIBible.app not found in build products"
for resource in book.fixture.json PrivacyInfo.xcprivacy; do
  [[ -f "$APP_BUNDLE/$resource" ]] || fail "$resource missing from $APP_BUNDLE"
  echo "Found $resource"
done
[[ ! -e "$APP_BUNDLE/Products.storekit" ]] || fail "Products.storekit must not ship inside the app"
# Public builds package only the synthetic fixture: no converted or private book content.
bash "$APP_DIR/ci/check-no-private-content.sh" "$APP_BUNDLE" || fail "private or converted content found in the app bundle"
plutil -lint "$APP_BUNDLE/PrivacyInfo.xcprivacy"
# Synthetic PNG covers must be copied byte-for-byte (their SHA-256 is checked by the app).
bash "$APP_DIR/ci/check-resource-bytes.sh" \
  "$APP_DIR/AIBible/Resources/Fixtures/presentation-fixture-cover.png" "$APP_BUNDLE/presentation-fixture-cover.png" \
  "$APP_DIR/AIBibleTests/ConverterSample/synthetic-sample-cover.png" \
  "$APP_BUNDLE/PlugIns/AIBibleTests.xctest/synthetic-sample-cover.png" \
  || fail "a bundled synthetic PNG differs from its source (PNG processing?)"

section "Run unit tests"
set +e
xcodebuild test-without-building \
  -project "$PROJECT" -scheme AIBible -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$WORK/Tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO
status=$?
set -e
echo "xcodebuild test exit status: $status"

# Copy the UI tests' named screenshots out of the result bundle for people to look at. This never
# changes the test result: any problem here is only a warning.
if [[ -n "${AIBIBLE_SCREENSHOT_DIR:-}" ]]; then
  section "Export screenshots"
  if xcrun xcresulttool export attachments --path "$WORK/Tests.xcresult" --output-path "$WORK/attachments" >/dev/null; then
    python3 - "$WORK/attachments" "$AIBIBLE_SCREENSHOT_DIR" <<'PY' || echo "::warning::screenshots could not be copied"
import json, os, re, shutil, sys
source, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
found = []
def walk(node):
    if isinstance(node, dict):
        name, file = node.get("suggestedHumanReadableName", ""), node.get("exportedFileName")
        if file and "AIBIBLE-SHOT" in name:
            found.append((name, file))
        for value in node.values(): walk(value)
    elif isinstance(node, list):
        for value in node: walk(value)
walk(json.load(open(os.path.join(source, "manifest.json"))))
for name, file in sorted(found):
    stem = os.path.splitext(name.split("AIBIBLE-SHOT", 1)[1])[0]
    stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", stem)   # xcresulttool's index and UUID suffix
    label = re.sub(r"[^A-Za-z0-9 ._-]+", "", stem).strip()
    shutil.copy(os.path.join(source, file), os.path.join(target, label[:80] + os.path.splitext(file)[1]))
print(f"{len(found)} screenshot(s) copied")
PY
  else
    echo "::warning::xcresulttool could not export attachments"
  fi
fi
exit "$status"
