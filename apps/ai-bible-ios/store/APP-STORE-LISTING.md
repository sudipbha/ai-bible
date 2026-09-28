# App Store listing (draft for the owner to approve)

Everything here is a draft. Names in **[brackets]** are owner decisions. Check each field's current
character limit in App Store Connect when entering it.

## Name and subtitle
- **Name:** AI Bible for Small Business
- **Subtitle:** Decide which AI tools to keep

## Category
- Primary: **Business**. Secondary: **Productivity**. Books is deliberately not used: the app is a
  decision tool built on the book's method (see `REVIEW-NOTES.md`).

## Promotional text
Evaluate any AI tool the way the book teaches: five questions, the real whole-job cost, a trial with a
review date, then keep it or drop it. Everything stays on your iPhone.

## Description
AI Bible for Small Business helps owners and small teams decide which AI tools are worth keeping.

EVALUATE EACH TOOL IN THREE STEPS
- Five-Question Filter: check a tool against the task you want help with, and save your answers.
- Whole-job cost: compare doing the task by hand with the whole job using the tool, including setup,
  checking and rework. Time and money are kept separate, so time is never passed off as cash.
- Trial with a review date: follow the rollout checklist, get a reminder on the review date, then
  record whether you keep the tool or drop it, and why.

SEE ALL YOUR DECISIONS IN ONE PLACE
- Every tool you're considering, trialling, keeping or dropping, with its history and next review.
- Share any decision as a one-page summary with a partner or accountant.

THE BOOK BEHIND THE METHOD
- Every step links to the chapter that explains it.
- Read offline with search, bookmarks, adjustable text and light, sepia and dark themes.
- Chapter 1 and the Five-Question Filter are free. The full book and all tools are one in-app purchase.

PRIVATE BY DESIGN
- No account, no tracking, no analytics. Your records stay on your iPhone and in your own backups.

## Keywords (comma-separated, no spaces after commas)
ai tools,small business,chatgpt,automation,software cost,productivity,decision,trial,checklist,owner

## In-app purchase
- Reference name: Full Book and Tools. Type: non-consumable.
- **[Price tier and base storefront]**: not decided. The $4.99 in `StoreKit/Products.storekit` is for
  local testing only.
- Display name: Full Book and Tools. Description: All chapters, plus the cost worksheet and trial tracker.
- **[Family Sharing on/off]**.
- Product ID must match `AppConfig.fullBookProductID` (currently a placeholder).

## Age rating
Answer "None" to every content question (no violence, mature themes, gambling, user-generated content,
unrestricted web access). Expected result: 4+. Confirm in App Store Connect.

## App Privacy ("nutrition label")
- **Data Not Collected.** The app has no analytics, no server, and no third-party SDKs. Purchases are
  handled by Apple; Apple's own data isn't the developer's to declare.

## URLs (required; must be live before submission)
- Privacy policy URL: **[host `PRIVACY-POLICY.md` on the owner's site]**
- Support URL: **[host `SUPPORT.md` on the owner's site]**
- Marketing URL (optional): the book's website.

## Screenshots
See `SCREENSHOTS.md`.
