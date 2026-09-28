# AI Bible — native iOS reader (prototype source)

Status as of 28 September 2026: **prototype. Not signed, not submitted, not tested on a real iPhone.**
- Latest hosted-Mac result: GitHub Actions run 36411494769 on commit `0d6d942` (macos-26 arm64 image
  20260907.0351.1, Xcode 26.6 build 17F113, one ephemeral iPhone SE (3rd generation) simulator on iOS 26.2).
  - Build passed. **126 unique tests: 126 passed, 0 failed, 0 skipped** (119 hosted, 7 UI).
  - Both synthetic PNG covers read back byte-identical to their sources before the tests.
  - The run uploaded 13 screenshots of the synthetic app (artifact `aibible-screenshots`, kept 7 days).
- Earlier runs on this branch failed intermittently in two UI journeys: Delete My Data in the Filter journey
  (run 36372328824) and resuming at a manually scrolled place (run 36374747429). Both passed in later runs;
  neither cause was proven, so treat them as watch items rather than fixed.
- These are simulator results with **synthetic fixture content only**. The full private book has been
  converted locally but has **never been loaded or rendered by the app**, and nothing has run on a physical
  iPhone, with VoiceOver, or against the App Store sandbox.
- Nothing here guarantees App Store approval.

## What it is

The owner-approved v1 scope:

- An offline native reader: contents, in-chapter headings, resume where you left off, bookmarks,
  local search that ignores case and accents, light/sepia/dark themes, serif or sans text, and Dynamic Type.
- Saved, offline tools:
  - **Five-Question Filter** (free), which records answers per task and tool and does not score them.
  - **Rollout tracker** (full unlock).
  - **Whole-job cost worksheet** (full unlock).
  - Every record can be shared as plain text.
- Free: Chapter 1 and the Filter. Paid: one non-consumable "Full Book and Tools" unlock of about $5.
  **Price tier, currency and base storefront are undecided.** The price shown in `StoreKit/Products.storekit`
  is for local testing only.
- No login, backend, sync, analytics, ads, tracking or AI features. Data stays on the device.

## Content: fixtures only in public builds

`AIBible/Resources/Fixtures/book.fixture.json` is **synthetic text**. It contains no book, sample-chapter or
website text, and its Filter questions and rollout steps are placeholders. Public builds, CI and every test
use synthetic content only.

**Real content path (built, never run on the real book):**
- `converter/` holds a generic, local EPUB → `BookBundle` converter with authored, registry-backed block
  IDs, strict structure checks and synthetic tests. See `converter/README.md`.
- The block schema now also has ordered lists with a start number, multi-paragraph quotes, dividers and
  card groups with varied fields and fill-in blanks. Older editions decode unchanged.
- A private build is made locally with `converter/stage-private-build.sh`. It defines
  `AIBIBLE_PRIVATE_BOOK`, loads `book.private.json`, and refuses a missing or fixture edition. There is
  no fallback to the fixture.
- The EPUB, the registry, the converted book, the report and the cover stay outside Git.
- **Front matter (converted editions):** a compact "Cover and title page" row at the top of Contents
  opens the cover (described by its alt text) and the title page. Contents then lists the source's own
  entries, in order and indented by depth; each opens the cover, the title page, a chapter or a
  heading, and paid targets go through the normal unlock gate. The public fixture has no front matter,
  so its plain chapter list is unchanged. A Debug-only UI-test option selects a second synthetic
  fixture (`presentation.fixture.json`) to exercise this. None of it has been compiled or run yet.
- The private staging build copies only the reviewed book JSON and its declared cover, both checked by
  SHA-256; the app refuses an edition whose cover is missing or different.
- An edition that fails `BookLoader.problems(in:)` isn't opened. While content is unavailable,
  saved places and records are kept exactly as they were and nothing is written.

**Still needed before real content ships:**
1. An approved, pinned edition. The development pin is a checksum only; it doesn't show equivalence with
   the current Gumroad or final release.
2. Confirmed redistribution rights for the text, cover and any quoted material (Guideline 5.2).
3. Root review of this converter, then a local conversion by the coordinator, then a human proofread
   against the source.
4. `BookLoader.problems(in:)` returning nothing for the converted edition.

The app reports `isFixture` in Settings. Tests fail if a public build selects anything but the fixture
or packages converted content.

## Cost worksheet formula

Time and money are separate:

- Manual = tasks × manual minutes per task
- First trial = tasks × whole-job minutes per task + one-time setup minutes
- Later = tasks × whole-job minutes per task

Whole-job minutes already include preparing, checking, correcting and approving the work. The monthly
price is shown exactly as entered and is never converted into time. Freed time is labelled "time, not cash".

Fictional test vector: 20 × 12 = 240, 20 × 8 + 90 = 250, later 160, and a hypothetical $20 a month kept separate.

## Layout

```
project.yml                  XcodeGen spec (source of truth; the .xcodeproj is generated, not committed)
StoreKit/Products.storekit   Local StoreKit test configuration (placeholder product ID)
AIBible/App                  App entry, root tabs, AppModel, AppConfig placeholders
AIBible/Content              Content model, loader and validation, anchor/ID migration
AIBible/Reader               Reader, block rendering (tables become cards at large sizes), contents, search
AIBible/Tools                Tool records, cost worksheet, export, tool screens
AIBible/Store                StoreKit 2 provider, entitlement state machine, unlock sheet
AIBible/Persistence          Local JSON store (atomic writes, unreadable files kept aside), bookmarks
AIBible/Settings             Reading preferences, restore, data deletion, privacy summary
AIBible/Resources            Fixture JSON, PrivacyInfo.xcprivacy
AIBibleTests                 Unit tests and hosted local-StoreKit tests (see below)
AIBibleUITests               UI tests (6 passed in run 36358639807; PresentationJourneyUITests added since, never run)
converter                    Local EPUB converter, synthetic tests, private staging build (never run on the book)
ci                           Hosted-Mac test script and workflow template
accessibility-checklist.md   Manual device checks (not yet run)
```

## Purchases

- StoreKit 2 behind a `PurchaseProvider` protocol. Only `.verified` transactions unlock anything.
- On launch the app starts from the cached state, which keeps offline launches fast. It then listens to
  `Transaction.updates` and re-reads `Transaction.currentEntitlements`.
- Pending purchases, including Ask to Buy, show a waiting message. The pending flag survives a relaunch,
  and the updates listener unlocks the app once the purchase is approved.
- Restore Purchases calls `AppStore.sync()` and appears both on the unlock sheet and in Settings.
- A refund or revocation locks paid chapters again. **Saved tool records and bookmarks are kept** and stay
  readable and shareable; only editing the paid tools needs the unlock.
- Gumroad or other purchases do not unlock the app (Guideline 3.1.1: no license keys or codes).

## Unit tests

The first 72 passed in run 36337255552, and all 81 hosted tests except Ask to Buy passed in run
36358639807. The classes added after that (`ConvertedContentTests`, `ContentPackagingTests`,
`ContentLoadErrorTests`, `PresentationTests` and `PrivateContentScanTests`) have never run.

| File | Covers |
|---|---|
| `CostWorksheetTests` | The fictional vector, money kept separate, no savings wording, clamping |
| `IDMigrationTests` | Exact ID → `idMap` chain (with cycle guard) → quote match (same chapter first) → chapter start → book start; bookmarks are never dropped |
| `EntitlementTests` | Reducer for every state; model with a fake store: relaunch, offline cache, pending across restart, failure, restore found / not found, live revocation |
| `LocalStoreTests` | Round-trip, missing file; undecodable file quarantined byte-for-byte under a collision-safe name; failed quarantine, read failure and newer-format files are left untouched and saving pauses (original bytes survive edits and flush); revocation keeps saved work; Delete My Data removes the main file and recovery copies but not unrelated files or the purchase, and reports failures |
| `ReaderGateTests` | An open paid reader route locks after live revocation, an authoritative empty refresh, or a launch check that finds no purchase; an offline launch keeps cached access; bookmarks are kept |
| `ContentAndSearchTests` | Bundled fixture validates, only Chapter 1 is free, fixture `idMap`, validation catches bad structure, accent/case search, locked matches counted but not shown |
| `ConvertedContentTests` (new) | The converter's synthetic sample decodes and validates; list start 4/5; list numbers within `Int` range (limits, overflow, zero and negative starts); cards keep their own fields and blank labels; quotes, notes and dividers stay distinct; escaped marks and URLs read exactly; Foundation keeps strong/emphasis/code styling; search, source anchors, tool wording; malformed new shapes are rejected; a selected edition that fails its checks isn't loaded; older editions still decode |
| `ContentPackagingTests` (new) | Public builds select the fixture; no converted or private files in the app bundle; an edition of the wrong kind fails to load |
| `PresentationTests` (new) | Converted cover, title page and contents decode and validate; the cover is loaded only if its size and SHA-256 match; title-page text, order, roles and styles; every contents entry's destination; paid targets use the normal gate; bad entries are rejected; the synthetic presentation fixture is valid |
| `PrivateContentScanTests` (new) | The bundle scan flags each private output and ignores synthetic files |
| `ContentLoadErrorTests` (new) | With content unavailable, saved position, bookmarks and records aren't migrated or rewritten, even after an entitlement change and a flush |

Cost-worksheet edge cases (in `CostWorksheetTests`):
- Negative, NaN, infinite and over-limit entries show validation messages instead of results; they are never turned into zero.
- Formatting and export never convert out-of-range values to `Int`.
- An invalid record saves and reopens with its validation intact.

Price loading (in `EntitlementTests`):
- A price unavailable at launch recovers without a relaunch, through the sheet appearing, Try Again, returning to the foreground, or Restore.
- Loading the price never starts a purchase.

## Native journey tests

These were written after run 36337255552: 9 hosted tests and 6 UI tests. In run 36358639807 all of
them passed except `testAskToBuyIsPendingUntilApproved` (see Status).

**Local StoreKit tests:** `AIBibleTests/StoreKitIntegrationTests` drives the real `StoreKitPurchaseProvider` through `SKTestSession` against the synthetic `StoreKit/Products.storekit`. It covers:
- loading the price
- a purchase, and the purchase being found again after a reinstall
- a refund
- Ask to Buy approval
- a failed transaction

**UI tests:** `AIBibleUITests` exercises the rendered app:
- reading, search, bookmarks and resuming after a relaunch
- a passage opened from Search without scrolling being where the app reopens (synthetic chapter 1 has
  filler blocks, so the chapter start and that passage can't both be on screen). The relaunch helper
  waits 1.5 seconds before quitting, so this does not show that a position survives an immediate kill.
- Filter records: create, edit, persist, delete, and Delete My Data
- a local StoreKit unlock, then Rollout and Cost records persisting across a relaunch
- live revocation locking an open paid chapter
- a failed purchase staying locked

**How the tests are isolated:**
- UI tests keep their data in `<tmp>/AIBibleUITests/<name>`, through a Debug-only launch hook (`AIBible/App/UITestSupport.swift`).
- Release builds don't contain the hook.
- The hook never grants access, and it can't reach the real saved-data folder.

**What these tests aren't:** local StoreKit testing isn't the App Store sandbox, TestFlight, or a real purchase.

## Hosted-Mac route (active on this branch's draft pull request)

`.github/workflows/ios-app-tests.yml` (a copy of `ci/ios-app-tests.yml.example`) runs `ci/run-tests.sh` on a
standard GitHub-hosted `macos-26` runner for pull requests that touch `apps/ai-bible-ios/**`. The script
checks the pinned Xcode build and simulator, generates the project, checks its wiring and bundled resources,
and runs the scheme's whole test action. Its only upload is the UI tests' named screenshots of the synthetic
app (`aibible-screenshots`, 7 days). The workflow file exists only on this branch, not on `main`.
See `ci/README.md` for details.

## Build route on your own Mac

```sh
brew install xcodegen            # or another XcodeGen install
cd apps/ai-bible-ios
xcodegen generate
xcodebuild test -project AIBible.xcodeproj -scheme AIBible \
  -destination 'platform=iOS Simulator,name=<an installed iPhone simulator>'
```

- Use a current Xcode that meets App Store Connect's upload requirement; check
  https://developer.apple.com/news/upcoming-requirements/ on the day.
- Things to check the first time you build:
  - `storeKitConfiguration` in `project.yml`.
  - The test host settings.
  - The privacy manifest landing in the app bundle.
  - Any Swift 6 concurrency diagnostics.
- The Simulator and local StoreKit testing are **not** real-iPhone testing. The performance targets and
  accessibility checks in the plan need the oldest supported iPhone and a current one.

## Open gates before any TestFlight or submission

- **Owner decisions:** price tier, base storefront, Family Sharing, and whether to enroll as an individual
  or an organisation.
- **Replace placeholders:**
  - Bundle IDs.
  - `DEVELOPMENT_TEAM`.
  - `AppConfig.fullBookProductID` (to match the App Store Connect product).
  - `AppConfig.privacyPolicyURL` and `supportURL` (both required).
- **Real content:** the local conversion is done, but the private build must still be made and checked on a Mac
  (`converter/stage-private-build.sh`): loading, rendering, cover, contents, tools and a proofread. The
  release edition must also be reconciled with the pinned EPUB.
- **Purchases:** local StoreKit tests (including Ask to Buy) pass in the simulator; the App Store sandbox and
  TestFlight have not been tried.
- **Privacy manifest:** check the reason codes against Apple's current documentation (UserDefaults `CA92.1`
  is declared).
- **Deferred in this prototype:**
  - PDF export (text export exists).
  - Rollout review-date notifications (the date is stored and exported, but no notification is sent).
  - A "use in tracker" action on printed checklists.
  - Highlights.
  - A prebuilt SQLite FTS search index, if the in-memory scan misses targets on real content.
- **Evidence still to collect:** device performance measurements, manual accessibility passes, sandbox and
  TestFlight purchase states, a network capture showing no app traffic, and App Review notes.
