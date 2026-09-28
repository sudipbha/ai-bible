# Submission checklist (owner steps, in order)

Status legend: DONE (in this repo, verified on the hosted Mac simulator), OWNER (needs you), MAC (needs a
Mac with Xcode), APPLE (needs the Apple Developer account).

## Done in the repo
- DONE — Native reader, Decisions (guided evaluations, status history, review reminders), Filter, cost
  worksheet, trial tracker, text export, search, bookmarks, themes, Dynamic Type.
- DONE — One non-consumable purchase with Restore; local StoreKit tests including Ask to Buy pass.
- DONE — Privacy manifest (no tracking, no collected data; UserDefaults reason CA92.1), no analytics.
- DONE — App icon (1024 px, no transparency).
- DONE — Store listing, review notes, privacy policy and support page drafts in `store/`.

## 1. Accounts and legal (OWNER, APPLE)
1. OWNER: decide individual or organisation enrolment (organisation needs a D-U-N-S number).
2. APPLE: enrol in the Apple Developer Program (US$99/year). Not authorised or done by this project.
3. APPLE: accept the Paid Apps Agreement; complete tax and banking in App Store Connect.
4. OWNER: optional but recommended — enrol in the App Store Small Business Program (15% commission).

## 2. Decisions (OWNER)
1. Price tier and base storefront (the $4.99 test price is not a decision). Family Sharing on or off.
2. Publisher/seller name, support email, and the two public web pages from `PRIVACY-POLICY.md` and
   `SUPPORT.md`.
3. Which book edition ships: reconcile the pinned development EPUB with the current storefront edition.

## 3. Identifiers in code (MAC, then commit)
In `project.yml` and `AIBible/App/AppModel.swift`:
- `PRODUCT_BUNDLE_IDENTIFIER` (app, tests, UI tests): replace `com.example.*` with your reverse-DNS IDs.
- `DEVELOPMENT_TEAM`: your team ID.
- `AppConfig.fullBookProductID`: the App Store Connect product ID; update `StoreKit/Products.storekit`
  to match so local tests keep passing.
- `AppConfig.privacyPolicyURL` and `AppConfig.supportURL`: the live URLs.

## 4. Real book build and proofread (MAC)
1. Run `converter/stage-private-build.sh` with the reviewed `book.private.json` and cover
   (see `converter/README.md`). It copies them into a build outside Git.
2. On the Simulator and a real iPhone, check: cover, contents, every chapter, tables and cards, the
   Filter questions and rollout steps, search, bookmarks, paid lock and unlock.
3. VoiceOver and the largest text size on the oldest supported iPhone.
4. Never commit or upload the private book files to GitHub or CI.

## 5. App Store Connect (APPLE)
1. Create the app record (name, bundle ID, SKU, primary language).
2. Create the in-app purchase (non-consumable) matching `fullBookProductID`; add its review screenshot.
3. Enter the listing from `APP-STORE-LISTING.md`, the App Privacy answers ("Data Not Collected"), age
   rating, URLs and `REVIEW-NOTES.md`.
4. Screenshots: see `SCREENSHOTS.md`. Take them from the real-book build, not the synthetic fixture.

## 6. Build, test, submit (MAC, APPLE)
1. Xcode → Product → Archive with the release edition; upload to App Store Connect.
2. TestFlight: install on real iPhones; buy, restore, Ask to Buy and refund in the sandbox.
3. Submit the app with the in-app purchase attached. If rejected under 4.2, reply in Resolution Center
   pointing to the Decisions workflow; the fallback is publishing the EPUB on Apple Books.
