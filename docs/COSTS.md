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
| Stream Chat | Build (free), later Maker | Free plan limits on monthly active users and concurrent connections (see Stream's pricing page); Maker is free for small companies that qualify | Stream Dashboard > Usage (monthly active users, connections) | 80 percent of the free plan's monthly active users or connections; see "Chat (Prompt 9)" |
| Algolia | Build (free) | 10,000 searches a month | Algolia dashboard > Usage | 8,000 searches in a month; the dev build uses the fake search and costs nothing |
| Google Maps Platform | Free monthly allowance per product (since March 2025) | Free calls per product per month (Maps SDK, Places, Routes); see "Maps (Prompt 5)" | Google Cloud > Quotas, with per-day caps set in SETUP.md section 15.4 | Any product reaches 80 percent of its free calls |
| WhatsApp Business | Pay per template message | Codes and critical alerts only by default (wallet messages too only if the parent switches them on); other notifications are push unless the parent switches WhatsApp on | Meta WhatsApp Manager > Insights | Budget set by the owner |
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
- **Per-parent limits:** the secured keys carry a hashed user token, so
  Algolia's limit of 100 searches an hour counts per parent (not per IP
  address), and each parent gets at most 6 keys a day: at most about 600
  requests a day for one account, so one abusive account needs many days
  (and a verified identity soon after sign-up) to use up the free month.
  Answers are cached on the phone for 10 minutes. The fake search is
  refused in prod.
- **Firestore:** the loader reads every school once per run (about 30,000
  reads, inside the free 50,000 a day; run it at most once a day) and
  writes only new or changed schools. The dev fake reads at most 200
  schools once per app start, on the emulators only.
- **Usage tracking:** Algolia dashboard > Usage (search requests).
- **Upgrade when:** 8,000 search requests in a month, or before the
  public launch if Algolia's terms rule out the Build plan for us.

## Maps (Prompt 5)

Google Maps Platform bills per product ("SKU"); since March 2025 each SKU
has its own free monthly calls (Essentials 10,000, Pro 5,000, Enterprise
1,000). Check Google's pricing page before relying on these numbers.

| What we call | SKU | Free a month | How we keep it low |
| --- | --- | --- | --- |
| The map on iPhone and Android (Maps SDK) | Mobile native dynamic maps | Listed at no charge for the mobile SDKs (check the pricing page) | Maps appear only on the home picker, the school map and the nearby map; no map on the Home tab |
| The map on the website (Stage 2) | Dynamic Maps (Essentials) | 10,000 loads | Not loaded until Stage 2; no key in web builds |
| Address search as you type | Autocomplete Requests (Essentials, via Places API New) | 10,000 | 3 letters, 400 ms pause, one session token per search, at most 60 searches per parent per hour (`MAP_PLACE_SEARCHES_PER_HOUR`) |
| The picked address | Place Details Essentials (fields `id`, `formattedAddress`, `location` only) | 10,000 | Cached in `placeCache` for 30 days (Firestore TTL deletes old entries); cache misses limited to 20 per parent per hour (`MAP_PLACE_DETAILS_PER_HOUR`); suspended accounts refused |
| "Use my location" | Free (the phone's GPS) | n/a | Nothing is sent to Google |
| Arrival times | Routes | n/a now | Prompt 13: only during a live run, at most once a minute per stop |

- **Dev and CI:** `PLACES_PROVIDER=fake` (a few fixed places) and no map
  key: no Google calls at all. The maps are drawn by a sketch.
- **Firestore:** setting a home is about 5 reads and 3 writes; a nearby
  search about 5 reads plus one read per parent found (at most 9 range
  queries of 50); settings about 5 reads and 2 writes. Searches are limited
  to 30 per parent per hour (`MAP_NEARBY_SEARCHES_PER_HOUR`) and home moves
  to 4 a day (`MAP_HOME_MOVES_PER_DAY`), which also stops anyone sweeping
  the map.
- **Cloud Functions:** each autocomplete keystroke batch is one call (2
  million free a month).
- **Usage tracking:** Google Cloud > APIs & Services > each API > Metrics,
  plus the per-day quota caps in SETUP.md section 15.4.
- **Upgrade when:** any SKU passes 8,000 calls in a month (raise the
  per-day caps knowingly, with the budget alert in place).

## Carpools (Prompt 6)

No new paid service. `url_launcher` (official Flutter plugin, free) opens
WhatsApp with the invite text; nothing is sent through the WhatsApp
Business Platform, so invite links cost nothing.

- **Firestore:** creating a carpool is about 8 reads and 3 writes; a search
  is about 5 reads plus one per carpool returned (at most 100 per query);
  a join request, an approval or a consent is one transaction of a few
  reads and 2 to 4 writes. The carpool screens listen to small documents
  (the carpool, the parent's memberships, members and consents of their
  own carpools only).
- **Limits per parent** (server settings, `functions/src/config.ts`):
  3 new carpools a day, 30 searches an hour, 10 join requests a day,
  20 invite links a day, 20 invite opens an hour, 5 "looking" posts a day,
  30 post lists an hour. They keep Firestore inside the free daily quota
  and stop anyone sweeping carpools or guessing invite codes.
- **Hosting (invite links site):** a few kilobytes per link opened, far
  inside the free 360 MB a day.
- **Expiry:** invite codes (14 days) and "looking" posts (60 days) carry an
  `expiresAt` field; a Firestore TTL policy deletes them (SETUP.md 16.4).
- **Upgrade when:** never on its own; it counts toward the Firebase row above.

## Schedule (Prompt 7)

No new paid service.

- **Cloud Scheduler:** one more job, `scheduleTick`, every 15 minutes
  (Africa/Cairo). With `purgeVerificationImagesDaily` that is 2 of the 3
  free jobs per billing account. About 2,900 runs a month, far inside the
  free 2 million Functions invocations; each run is two small collection
  group queries (planned or open runs past their cut-off, confirmed runs
  that started) and one transaction per run that changes. No warm
  instances: `minInstances` is `MIN_INSTANCES` (0).
- **Firestore:** planning a week is one transaction (members, consents,
  exceptions, the week's runs, the balance: about 20 reads; up to 14 run
  writes and one event). Confirm, swap, take, absent and exception changes
  are one transaction of a few reads and 1 to 3 writes plus an event. The
  week plan listens to at most 14 run documents.
- **Limits per parent** (server settings): 20 plans a day
  (`SCHEDULE_PLANS_PER_DAY`), 100 other schedule changes a day
  (`SCHEDULE_CHANGES_PER_DAY`).
- **Alert events** go to the notification outbox (`notificationEvents`
  since Prompt 8); they carry IDs only and expire after 30 days (TTL,
  SETUP.md 18.5). WhatsApp costs: see Notifications below.
- **Upgrade when:** never on its own; it counts toward the Firebase row above.

## Notifications (Prompt 8)

No new paid service. FCM (push, through APNs on the iPhone) is free.

- **WhatsApp:** one **utility** template message per WhatsApp notification,
  billed by Meta per message (Egypt rates in WhatsApp Manager). COST MODE
  default: only the two critical groups ("no driver", "child not
  confirmed") go to WhatsApp, and only to parents who agreed to WhatsApp at
  sign-up. Every other group is push only until the parent switches it on
  (Settings > Alert settings). Chat is never WhatsApp. In quiet hours
  (default 22:00 to 06:00 Cairo) non-critical WhatsApp messages are not
  sent at all. Rough worst case for a carpool of 5 families: one missed
  run a week = 5 messages a week. Track in WhatsApp Manager > Insights;
  the dispatcher logs one line per event with counts.
- **Cloud Functions:** `sendNotification` runs once per event (a schedule
  change, a join request, a reminder, a decision), a few reads and writes
  per recipient (account, settings, phones, record, two small
  transactions). `notificationTick` runs every 5 minutes: about 8,700 runs
  a month, three small collection group queries each (runs tomorrow, runs
  in the next hour, runs to confirm) plus the alarm query. Both are far
  inside the free 2 million invocations. No warm instances.
- **Cloud Scheduler:** `notificationTick` is the third job
  (`purgeVerificationImagesDaily`, `scheduleTick`, `notificationTick`): the
  3 free jobs per billing account are used up. Each further job costs
  USD 0.10 a month; with dev, staging and prod on one billing account it is
  already 9 jobs (about USD 0.60 a month).
- **Firestore:** one in-app record per recipient (expires after 60 days,
  TTL), one outbox event per notification (30 days). The Notifications tab
  listens to at most 50 records. Phones: one small document per phone.
- **Limits per parent:** 30 phone registrations and 100 settings changes a
  day (`NOTIFY_DEVICE_CHANGES_PER_DAY`, `NOTIFY_SETTINGS_CHANGES_PER_DAY`);
  signing out is never limited.
- **Upgrade when:** WhatsApp spend passes the owner's monthly budget: then
  keep critical only and ask parents to rely on push.

## Chat (Prompt 9)

- **Stream Chat:** Build (free) plan for the dev app and the prod app. The
  plan counts monthly active users (parents who connect) and concurrent
  connections. The app connects only while a chat screen is open or the
  app is in the foreground (the SDK disconnects in the background), and
  Stream's own push is off, so nothing else is billed by Stream. Move the
  prod app to **Maker** (free for small qualifying organizations; apply
  early) or the first paid plan when the dashboard shows 80 percent of a
  free limit. AI moderation for text and images may need Stream's
  moderation add-on: check its price before turning it on in prod (SETUP
  19.4); the blocked-terms lists cost nothing.
- **Cloud Functions:** `getChatToken` about once an hour per active parent;
  `chatWebhook` once per message (one Firestore read of the channel, two
  small queries, one outbox write); `sendNotification` then sends the push
  (FCM is free). Triggers on users, parentLocations and carpool members
  run only when those change. All far inside the free 2 million
  invocations.
- **Cloud Scheduler:** `chatRetentionDaily` is one more job (USD 0.10 a
  month per project once the 3 free jobs are used).
- **Firestore:** a channel registry document per chat, one small document
  per request, block, mute and setting; chat push records expire after 2
  days (TTL), requests 30 days after the last change.
- **Limits per parent** (server side): 10 new chat requests a day, 30
  tokens an hour, 20 reports a day, 100 blocks, mutes and settings changes
  a day, 10 "sync my chats" an hour.

## Wallet (Prompt 11B)

- **Wallet partner:** fake provider (test money in Firestore) until the
  contract; the partner's fees and limits are open questions. The app takes
  no fee and no commission; ask the partner for no fee on transfers between
  parents.
- **WhatsApp:** the five `cp_wallet_*` templates are **off by default**
  (COST MODE, owner decision pending): wallet messages are push and in-app
  only unless the parent switches the "Wallet" group on in Settings >
  Alerts. At most two per transfer (sender and receiver) when on.
- **Cloud Functions:** one call per wallet open (with one partner balance
  read), one per transfer (two Firestore transactions, the partner call,
  outbox events), one per history page. `minInstances` stays 0
  (`MIN_INSTANCES_WALLET`); raise it only if a cold start delays transfers
  in the pilot.
- **Cloud Scheduler:** `walletReconcile` every 5 minutes is one more job
  (USD 0.10 a month per project once the 3 free jobs are used). It reads
  only `walletPending` (usually empty).
- **Firestore:** per transfer two documents created once (`transfers`,
  `transferResults`), one pending entry (deleted when settled), one daily
  counter per parent and day; balances are a copy, read from the partner.
- **Limits per parent** (server settings `config/wallet`): 2,000 EGP per
  transfer, 5,000 EGP and 20 transfers a day, 20 parent ID lookups an hour,
  10 reports a day (SETUP.md 20.2).

## Open cost questions

1. (Decided) The checks moved from Codemagic Linux (billed) to GitHub
   Actions.
2. Cloud Storage outside the free US regions is billed from the first GB.
   The bucket region is part of the hosting decision with the lawyer.
3. Algolia's Build plan terms say it is "provided only for evaluation
   purposes" and not for production use. Before launch, either ask
   Algolia's non-profit programme (the app is free and non-profit) or
   budget the pay-as-you-go Grow plan. The fake search keeps dev free.
