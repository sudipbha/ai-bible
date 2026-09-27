# AI Bible — native iOS reader (prototype source)

Status as of 27 September 2026: **source only. Not compiled, not tested, not signed, not submitted.**
It was written in a Linux environment with no Swift toolchain or Xcode. Every build and test step
below is for someone to run on a Mac. Nothing here guarantees App Store approval.

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

## Content: fixtures only

`AIBible/Resources/Fixtures/book.fixture.json` is **synthetic text**. It contains no book, sample-chapter or
website text, and its Filter questions and rollout steps are placeholders. Real content needs all of these first:

1. An approved, pinned edition (a source revision plus a checksum).
2. Confirmed redistribution rights for the text, cover and any quoted material (Guideline 5.2).
3. A conversion step, not built yet, that produces this JSON format. Block IDs must be authored editorial
   IDs that stay stable across editions, and renamed blocks must be listed in `idMap`.
4. `BookLoader.problems(in:)` returning nothing, followed by a human proofread against the source.

The app reports `isFixture` in Settings, and a test fails if a non-fixture bundle is swapped in
before that test is deliberately updated.

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
AIBibleTests                 Unit tests (see below)
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

## Tests (written, not run)

| File | Covers |
|---|---|
| `CostWorksheetTests` | The fictional vector, money kept separate, no savings wording, clamping |
| `IDMigrationTests` | Exact ID → `idMap` chain (with cycle guard) → quote match (same chapter first) → chapter start → book start; bookmarks are never dropped |
| `EntitlementTests` | Reducer for every state; model with a fake store: relaunch, offline cache, pending across restart, failure, restore found / not found, live revocation |
| `LocalStoreTests` | Round-trip, missing file; undecodable file quarantined byte-for-byte under a collision-safe name; failed quarantine, read failure and newer-format files are left untouched and saving pauses (original bytes survive edits and flush); revocation keeps saved work; Delete My Data removes the main file and recovery copies but not unrelated files or the purchase, and reports failures |
| `ReaderGateTests` | An open paid reader route locks after live revocation, an authoritative empty refresh, or a launch check that finds no purchase; an offline launch keeps cached access; bookmarks are kept |
| `ContentAndSearchTests` | Bundled fixture validates, only Chapter 1 is free, fixture `idMap`, validation catches bad structure, accent/case search, locked matches counted but not shown |

Cost-worksheet edge cases (in `CostWorksheetTests`):
- Negative, NaN, infinite and over-limit entries show validation messages instead of results; they are never turned into zero.
- Formatting and export never convert out-of-range values to `Int`.
- An invalid record saves and reopens with its validation intact.

Price loading (in `EntitlementTests`):
- A price unavailable at launch recovers without a relaunch, through the sheet appearing, Try Again, returning to the foreground, or Restore.
- Loading the price never starts a purchase.

No UI tests yet.

## Hosted-Mac route (inactive)

`ci/run-tests.sh` and `ci/ios-app-tests.yml.example` generate the project, check its wiring and resources, and run the unit tests on a GitHub-hosted macOS runner. Nothing is under `.github/workflows/`, so nothing runs. See `ci/README.md` for what they check and for the activation proposal.

## Build route on a Mac (inert here; no CI configured)

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
  - The app icon (none is included yet).
- **Real content:** the conversion pipeline, the validation report and a proofread (see above).
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
