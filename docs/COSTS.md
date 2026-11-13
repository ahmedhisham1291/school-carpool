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
| Codemagic | Free personal | 500 macOS M2 minutes a month. **Linux has no free minutes** (about USD 0.045 a minute) | Codemagic > Billing | macOS minutes run out before the 25th of a month |
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
- CI: iOS builds only for pushes to `main`, version tags and manual starts.
- Dev runs on the local emulators (`demo-` project): zero cloud cost.

## Open cost questions

1. Codemagic Linux minutes are not free. Keep the `checks` workflow on Linux
   (about USD 0.50 to 0.70 a run), move it to the free macOS minutes, or run
   the checks somewhere with free Linux minutes. See
   docs/progress/prompt-01.md.
2. Cloud Storage outside the free US regions is billed from the first GB.
   The bucket region is part of the hosting decision with the lawyer.
