# Hosted-Mac test route (active on the draft pull request branch)

`ios-app-tests.yml.example` has been copied unchanged to `.github/workflows/ios-app-tests.yml` on `claude/determined-mendel-zyd5vi` only; it is not on `main`. Its `pull_request` trigger runs this route for the draft pull request. The first run, GitHub Actions run 36337255552 on commit `3ee73c8`, passed the 72 unit tests on Xcode 26.3 with the iPhone SE (3rd generation) simulator on iOS 26.2. The native journey tests added after that run have not been compiled or run.

## What it does

The template and `run-tests.sh` together do the following.

**Runner:**
- Uses a standard `macos-26` arm64 runner (not a `-large` or `-xlarge` label) with a 30-minute timeout.
  **This toolchain change is prepared but has not run.** Earlier runs used `macos-15` with Xcode 26.3.
- Grants only `contents: read`.
- Checks out code with `actions/checkout` pinned to commit `3d3c42e5…` (v7.0.1), with `persist-credentials: false`.
- Uses no secrets, signing or caches, and synthetic fixtures only. Its one upload is `aibible-screenshots`:
  the UI tests' named screenshots (`showcase(...)`), kept for 7 days, so the app can be seen without a Mac.

**Xcode:**
- Selects Xcode through `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`, and fails if it's missing.
- Fails unless `xcodebuild -version` reports build `17F113` (`AIBIBLE_EXPECT_XCODE_BUILD`).
- Logs `xcodebuild -version`, the simulator SDK and the macOS version.
- These pins come from the official runner-images inventory for `macos-26` arm64 image 20260907.0351.1
  (macOS 26.6.2), read on 28 September 2026. The image can change before a run; the pins then fail
  the run rather than silently using something else.

**XcodeGen:**
- Downloads the official XcodeGen 2.46.0 `xcodegen.zip`.
- Checks its byte length (4,278,764) and SHA-256 (`4d9e34b6…6806`).
- Unzips it with the distribution layout intact, so `bin/xcodegen` finds `share/xcodegen/SettingPresets`.
- Checks the binary has a slice for the host architecture, then generates the project.
- Doesn't use Homebrew.

**Wiring checks, which prove more than parsing the YAML:**
- The shared scheme references `StoreKit/Products.storekit`.
- The test action includes `AIBibleTests`.
- `TEST_HOST` points at `AIBible.app`.

**Simulator:**
- With `AIBIBLE_SIM_DEVICE_TYPE` and `AIBIBLE_SIM_RUNTIME` set (the workflow sets iPhone SE (3rd
  generation) and iOS 26.2):
  - `ci/simulator_preflight.py` checks, from `simctl list -j`, that the device type is installed, the
    runtime is installed and available, and that the runtime lists the device type as supported;
  - it then creates one ephemeral simulator of exactly that pair and deletes it at exit;
  - if any check or the creation fails, the run fails. It never substitutes another device and never
    downloads a runtime.
- Run 36367022185 created that device on iOS 26.5, but local StoreKit test sessions failed there
  (`SKInternalErrorDomain Code=3`). Apple's developer forums report a known command-line `SKTestSession`
  issue on recent Xcode, and one reporter saw it work on iOS 26.2; that is evidence, not a proven fix.
  The next run therefore pins iOS 26.2, which is installed on the same image. The inventory lists
  iPhone SE (3rd generation) as **not pre-created** on iOS 26.2 either. That neither
  proves nor rules out support; only the preflight on the runner can tell. If it fails, a different
  exact device would need root approval, with its different screen geometry stated.
- Without those variables (local runs), picks the newest installed iPhone running iOS 17.0 or later.
- Confirms the simulator is a valid destination for the scheme.

**Build and test:**
- Runs `build-for-testing` with `CODE_SIGNING_ALLOWED=NO`.
- Compares both synthetic PNG covers in the built app and hosted-test bundle with their sources,
  byte for byte (`ci/check-resource-bytes.sh`); PNG compression and text stripping are off in `project.yml`.
- Checks that `book.fixture.json` and `PrivacyInfo.xcprivacy` are inside the built app and that
  `Products.storekit` isn't. `ci/check-no-private-content.sh` then fails the run if any converted or
  private file is in the bundle: `*.epub` (any case), other `book.*.json`, any `*.private.*` (such as the
  private book or cover), ID registries, conversion reports, `front-matter.json`, `cover.json`, or the
  `cover.jpg` / `cover.jpeg` / `cover.png` names earlier converter versions wrote (any letter case). It
  prints file names only. It also lints the privacy manifest.
- Runs `test-without-building` and exits with xcodebuild's own status.

On a Mac you can run the same script locally:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash apps/ai-bible-ios/ci/run-tests.sh
```

## Activation record

Steps 1–3 below were done with owner approval: the workflow copy, the push, the draft pull request and the review of run 36337255552. Step 4 has not happened.

Constraints:
- A `workflow_dispatch` workflow can be triggered by hand only once the workflow file is on the default branch (`main`). A template on this branch alone can't be run manually.
- A `pull_request` workflow runs from the file in the pull request itself, so it can run before anything reaches `main`.
- Standard hosted runners are free for public repositories under GitHub's published policy. This account's eligibility and settings haven't been checked, and no spending is authorized.

Proposed steps, each needing explicit owner approval at the time:
1. On `claude/determined-mendel-zyd5vi`, copy `ci/ios-app-tests.yml.example` to `.github/workflows/ios-app-tests.yml`. The contents stay the same.
2. Push the branch and open a **draft** pull request into `main`. The `pull_request` trigger (paths `apps/ai-bible-ios/**`) then runs the tests without changing `main`.
3. Review the run log: the Xcode version, the chosen simulator, the resource checks and the test results. Fix any failures on the branch.
4. Only if the owner later merges the pull request does `workflow_dispatch` become available on `main` for manual reruns.

Before step 1, confirm the following:
- `Xcode_26.6` (build 17F113) and the iOS 26.2 simulator runtime are still listed in the current macos-26 arm64
  runner-image README: https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md
- The checkout commit still matches the v7.0.1 tag.
