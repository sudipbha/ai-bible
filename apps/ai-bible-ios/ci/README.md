# Hosted-Mac test route (inactive)

Nothing here runs by itself. `ios-app-tests.yml.example` isn't in `.github/workflows/`, so GitHub ignores it. None of this has run yet.

## What it does

The template and `run-tests.sh` together do the following.

**Runner:**
- Uses a standard `macos-15` arm64 runner with a 30-minute timeout.
- Grants only `contents: read`.
- Checks out code with `actions/checkout` pinned to commit `3d3c42e5…` (v7.0.1), with `persist-credentials: false`.
- Uses no secrets, signing, caches or uploaded artifacts, and synthetic fixtures only.

**Xcode:**
- Selects Xcode through `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`, and fails if it's missing.
- Logs `xcodebuild -version`, the simulator SDK and the macOS version.
- Never falls back to the image's default Xcode, which is 16.4.

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
- Lists the iPhone simulators already installed for the selected Xcode.
- Picks the newest one running iOS 17.0 or later, which is the deployment target.
- Confirms it's a valid destination for the scheme, and fails clearly if there's none.
- Downloads no runtimes.

**Build and test:**
- Runs `build-for-testing` with `CODE_SIGNING_ALLOWED=NO`.
- Checks that `book.fixture.json` and `PrivacyInfo.xcprivacy` are inside the built app and that `Products.storekit` isn't, and lints the privacy manifest.
- Runs `test-without-building` and exits with xcodebuild's own status.

On a Mac you can run the same script locally:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash apps/ai-bible-ios/ci/run-tests.sh
```

## Activation proposal (for root and owner review; not done)

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
- `Xcode_26.3` is still listed in the current macos-15 arm64 runner-image README: https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md
- The checkout commit still matches the v7.0.1 tag.
