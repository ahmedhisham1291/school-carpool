# Running costs: free tier first

Owner decision (13 Nov 2026, CLAUDE.md "COST MODE"): every service starts on
its free plan and is upgraded only when usage reaches that plan's limit. The
code must never depend on a paid-only feature being switched on.

Limits below are the public free allowances as understood in November 2026.
**Check each pricing page before relying on a number**; vendors change them.

## Summary

| Service | Plan now | Free limit (main ones) | How we watch usage | Upgrade when |
| --- | --- | --- | --- | --- |
| Firebase (3 projects) | Blaze (pay as you go, needed for Cloud Functions) inside the no-cost quotas | Firestore: 50,000 reads, 20,000 writes, 20,000 deletes per day and 1 GiB stored, per project. Cloud Functions: 2 million calls, 400,000 GB-seconds and 200,000 CPU-seconds per month. Cloud Storage: 5 GB stored (free only in some US regions; elsewhere billed per GB). Hosting: 10 GB stored, 360 MB a day transfer. Cloud Messaging and App Check (App Attest/DeviceCheck) are free | Budget alert on each project (SETUP.md step 4) at USD 1, 5 and 20; Firebase console > Usage and billing; Firestore "Usage" tab | Any project passes 80 percent of a daily Firestore quota for a week, or the monthly bill passes USD 10 |
| Firebase Auth | Identity Platform, free tier | 50,000 monthly active users for email and custom-token sign-in (we never use SMS) | Identity Platform > Usage | Over 40,000 monthly active users |
| Cloud Functions warm instances | `MIN_INSTANCES=0` (none) in `functions/.env.*` | A warm instance is billed all the time, so none by default | Cloud Monitoring latency of sign-in and alerts | Cold start delays sign-in or a critical alert by more than about 3 seconds in the pilot: set `MIN_INSTANCES=1` for those functions only |
| Firestore point-in-time recovery | Off | PITR is billed as extra storage | n/a | Before the pilot opens to real families (owner decision); SETUP.md step 5 explains how |
| Firestore daily backups | On in prod only | Billed per GB stored in backups | Firestore > Disaster recovery | Never removed from prod |
| Sentry | Developer (free) | 5,000 errors a month, 1 user; no tracing, no replay | Sentry > Stats; spike protection on | Errors are dropped for quota two months in a row, or a second person needs access |
| Codemagic | Free personal, iOS builds only | 500 macOS M2 minutes a month (Linux has no free minutes, so no Linux jobs run there) | Codemagic > Billing | macOS minutes run out before the 25th of a month |
| GitHub Actions | Free | Public repositories: free. Private: a monthly allowance of free Linux minutes (2,000 on the free plan in Nov 2026; check GitHub's billing page) | GitHub > Settings > Billing > Usage | A private repository uses 80 percent of the allowance |
| Stream Chat | Build (free), later Maker | See Stream's pricing page; Maker is free for small companies that qualify | Stream dashboard | Prompt 9 onward, when the free plan's user or message limit is reached |
| Algolia | Build (free) | 10,000 searches a month | Algolia dashboard > Usage | 8,000 searches in a month; the dev build uses the fake search and costs nothing |
| Google Maps Platform | Free monthly allowance per product (since March 2025) | Free calls per product per month (Maps SDK, Places, Routes) | Google Cloud > Quotas, with per-day caps set in SETUP.md | Any product reaches 80 percent of its free calls |
| WhatsApp Business | Pay per template message | Codes and critical alerts only by default; other notifications are push unless the parent switches WhatsApp on | Meta WhatsApp Manager > Insights | Budget set by the owner |
| Valify, wallet partner | Fake providers | Nothing is called until the pilot | n/a | Contract signed |
| flutter_background_geolocation | No license | Debug builds and iOS need none | n/a | Before the first Android release build |

## Rules the code follows

- Cloud Functions: `minInstances` comes from the `MIN_INSTANCES` parameter
  (default 0) and every function has `maxInstances` 10, so a bug cannot scale
  the bill.
- Sentry: errors only. No performance tracing, no profiling, no session
  replay, no screenshots. `SENTRY_SAMPLE_RATE` lowers the share of errors
  sent if the monthly quota gets tight.
- CI: checks on GitHub Actions (Linux); iOS builds on Codemagic only for
  pushes to `main`, version tags and manual starts.
- Dev runs on the local emulators (`demo-` project): zero cloud cost.

## Sign-in (Prompt 2)

- One WhatsApp **authentication** template message per code. Meta bills
  authentication messages per message at the Egypt rate (check Meta's
  pricing page; it changes). Codes are capped at 5 per number, 10 per
  device and 60 per IP address per hour, and a number is locked for an hour
  after 10 wrong codes, so abuse cannot run up the bill.
- Dev and staging use the fake sender: no WhatsApp cost at all.
- Each code request is about 3 Firestore reads and 4 writes; each check
  about 2 reads and 2 writes, plus the new account's 2 writes. Old sign-in
  records are deleted by a free TTL policy (SETUP.md section 11.4).
- Email confirmation links are sent by Firebase Authentication at no cost.
- `requestCode` and `verifyCode` read `MIN_INSTANCES_SIGNIN` (0 now). Set it
  to 1 in `functions/.env.prod` only if cold starts make sign-in slow.

## Verification (Prompt 3)

- Images are compressed on the phone (about 200 to 500 KB each, 5 to 9 per
  parent) and deleted within 7 days of the decision, so stored volume
  stays at a few hundred MB even with thousands of parents.
- The deletion job is one Cloud Scheduler job (3 free per billing account)
  running once a day, minInstances 0. It lists the `verification/` prefix
  once per run (one Class A operation per 1,000 files).
- Soft delete is turned off on the bucket (SETUP.md 12.6), so deleted
  images are not kept (or billed) for 7 more days.
- The fake ID check costs nothing. Valify is paid per check: it is off
  (`KYC_PROVIDER=fake`, `VALIFY_ENABLED=false`) until the contract.
- Admin image links are V4 signed URLs: no extra service, but the
  functions' service account needs "Service Account Token Creator" on
  itself (already required for custom tokens, SETUP.md section 11).

## Admin panel (Prompt 4)

- **Two-step sign-in (TOTP):** part of Identity Platform; only SMS
  messages are charged per message, and we send none. Admin accounts count
  as monthly active users in the free 50,000.
- **Hosting:** one more Hosting site per project (the panel's web build,
  a few MB); inside the free 10 GB stored and 360 MB a day transfer.
- **Functions:** 14 small callables, `minInstances` 0; a handful of calls
  per review. Signed image links are created per case opening.
- **Firestore:** user search reads at most about 25 documents per search
  and is capped at 30 searches per admin per 10 minutes
  (`ADMIN_SEARCH_LIMIT`). The audit log grows by one small document per
  admin action or view; set a retention period with the lawyer (open
  question).
- **App Check on the web:** reCAPTCHA Enterprise has a free monthly
  allowance (check the current number on Google's pricing page); admins
  make few calls.
- **Upgrade when:** never needed for the panel alone at pilot size.

## Schools list (Prompt 4B)

- **Algolia Build (free) plan:** 10,000 search requests and 10,000
  recommend requests a month, up to 1 million records, one application.
  Egypt's OpenStreetMap export has a few tens of thousands of schools, far
  below the record limit. The plan's terms say it is for evaluation and
  not for production use (see open question 3).
- **Searches:** the picker waits 300 ms after the last key press and needs
  2 letters, so one school search is usually 2 to 4 requests. At about 3
  searches per parent (registration and children), 10,000 requests cover
  roughly 1,000 parents a month. Dev and CI use the fake search: zero.
- **Index writes:** `syncSchoolToSearch` writes only when a school's
  indexed fields change, so loading the same file again costs nothing.
  The first import sends every school once.
- **Search key:** one `getSchoolSearchKey` call per app session per hour.
- **Firestore:** the loader reads every school once per run (about 30,000
  reads, inside the free 50,000 a day; run it at most once a day) and
  writes only new or changed schools. The dev fake reads at most 200
  schools once per app start, on the emulators only.
- **Usage tracking:** Algolia dashboard > Usage (search requests).
- **Upgrade when:** 8,000 search requests in a month, or before the
  public launch if Algolia's terms rule out the Build plan for us.

## Open cost questions

1. (Decided) The checks moved from Codemagic Linux (billed) to GitHub
   Actions.
2. Cloud Storage outside the free US regions is billed from the first GB.
   The bucket region is part of the hosting decision with the lawyer.
3. Algolia's Build plan terms say it is "provided only for evaluation
   purposes" and not for production use. Before launch, either ask
   Algolia's non-profit programme (the app is free and non-profit) or
   budget the pay-as-you-go Grow plan. The fake search keeps dev free.
