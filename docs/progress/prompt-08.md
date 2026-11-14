# Prompt 8: Notifications by push and WhatsApp (F12, F23) — progress note

Branch: `prompt-08-notifications` (from `prompt-07-schedule`, which is under
review, on top of `main` with Prompts 1 to 6). Date: 14 Nov 2026. The
coordinator gave "go" on the owner's behalf.

**Status: code complete. Functions unit tests were run here (367 pass, 47
of them new). The Flutter code, the widget, logic, one-line and screenshot
tests, the rules tests and `tool/patch_native.py` on a real `flutter
create` project were written, not run here** (no Flutter SDK or npm
registry in this workspace; the native patch was tried on sample files).
Expect small analyzer fixes on the first CI run, most likely in the
`flutter_local_notifications` calls (`local_alarms.dart`, one file).

## Plan that was followed

1. Server: one outbox (`notificationEvents`) and ONE sender
   (`sendNotification`, a Firestore trigger) that writes the in-app record,
   sends the push and, when the group is on, the WhatsApp template.
2. Wire every producer to the outbox (they are found and changed):
   - Prompt 7 schedule flows (`CarpoolTx.addEvent`, `SCHEDULE_EVENTS` now
     points at the outbox): plan ready, no driver (take your own child,
     critical), swap requested/accepted/cancelled, run taken, driver
     unavailable, child absent/back, schedule changed;
   - Prompt 7 fixes: `time-changed` to the run's driver (critical by
     event when the run moved with no time left to confirm: time-sensitive
     push, alarm, WhatsApp under the "No driver" switch; otherwise a normal
     schedule notice);
   - Prompt 6 join flows: join requested (to the carpool's admins), join
     approved / declined (to the requester), written in the same
     transaction;
   - Prompt 3 verification decision: result to the parent, in the
     decision transaction (fixed ID `verification_{caseId}`);
   - Prompt 5 new parent nearby (F23): the event now goes to the outbox
     (fixed hashed ID, rounded point, no name); the sender re-checks the
     new parent is still verified and shown, then finds verified parents of
     the same school whose own radius reaches the point and who did not
     switch new-parent alerts off;
   - new producer `notificationTick` (every 5 minutes, Cairo): driver
     reminders the evening before (from 19:00) and one hour before, the
     missing-confirmation reminder (two hours before the confirm-by time),
     and the critical alarm.
3. Phones and settings callables, rules, rules tests, index, scripts.
4. App: Notifications tab, alert settings, unread dot, critical banner,
   push registration, the app's own alarm, sign-out cleanup.

## Data model

| Record | Holds | Who reads / writes |
| --- | --- | --- |
| `notificationEvents/{id}` | type, recipients (uids), carpool, run, date, direction, actor, child id, new-parent subject + schools + rounded point, `refEventId` (alarm), critical, status `pending`/`done`/`failed`, summary counts; TTL 30 days | Cloud Functions only |
| `users/{uid}/notifications/{eventId}` | type, critical, carpool, run, date, direction, route, createdAt, `readAt`, `alarmAt`, `alarmState`, delivery state per channel (`push`, `whatsapp`, `alarm`: state, attempts, reason); TTL 60 days | The parent reads (get, list ≤ 100); the app may only set `readAt` once, to the server time |
| `notificationSettings/{uid}` | WhatsApp on/off per group, quiet hours (on, from, to) | The parent reads; `updateNotificationSettings` writes |
| `pushTokens/{sha256(token)}` | owner uid, token, platform, updatedAt (≤ 10 per parent) | Cloud Functions only |
| `notificationLimits/{uid}` | daily counters | Cloud Functions only |

`scheduleEvents` and `newParentEvents` are no longer written; their rules
stay closed. Index: collection group `notifications` (alarmState, alarmAt).

## Rules the sender enforces

- **One sender.** Every push and WhatsApp notification goes through
  `dispatchEvent` (`functions/src/notifications/dispatch.ts`).
- **Idempotent.** The record ID is the event ID (created once). Each
  channel (push, WhatsApp, alarm) of each record is claimed in a
  transaction before sending; only a channel that failed is tried again,
  at most 3 times, by the trigger's retries (`retry: true`). A retried or
  duplicated event never sends twice; a crash mid-send loses that one
  message rather than doubling it. Events older than 6 hours are dropped.
  Reminders and alarms have fixed event IDs and are created with
  `create()`, so overlapping ticks make one each.
- **Privacy.** Push and WhatsApp text comes only from the catalogue
  (`texts.ts`): a generic sentence with at most the run's weekday, date and
  direction. No child or parent names, addresses or message text; push
  data holds only type, record ID, route, critical, alarm and alarm time.
  The new-parent record ID is a hash, so it does not reveal the new
  parent's uid. Logs carry types and counts; WhatsApp numbers are masked.
  The app writes its own text from the type; details load after opening.
- **Who gets it.** Never the actor; suspended, banned or missing accounts
  are skipped; unverified parents get only the verification result.
- **WhatsApp (COST MODE).** Only when the type has a template, the parent
  agreed to WhatsApp at sign-up (`whatsappOptIn`), has a number, and the
  group is on. Default on: "no driver" and "child not confirmed" only.
  Chat is push only.
- **Quiet hours** (default on, 22:00–06:00 Cairo): non-critical pushes are
  silent (iOS passive, no sound) and their WhatsApp is not sent. Critical
  alerts always sound and go to WhatsApp.
- **Critical alarm (spec section 11).** Critical records get
  `alarmAt` = now + 15 min. The push is time-sensitive with
  content-available and carries `alarmAt`; the app schedules its own local
  alarm then (also from the background handler), rings it when the time
  passed with the app open, shows the banner above the tabs, and cancels
  it when opened. The tick sends one louder "Reminder:" push for a record
  still unread at its alarm time. "Opened" means the in-app record was
  read (tapping the push or the row); WhatsApp read receipts would need
  Meta's webhook (not built).
- **Phones.** One document per token: a phone that signs in as another
  parent moves to that parent. A token refresh replaces the old one. Sign
  out removes it on the server and the phone (and the phone's alarms).
  Tokens FCM refuses for good are removed while sending.

## Screens and states

| Screen | Layout | Loading | Empty | Error | Offline |
| --- | --- | --- | --- | --- | --- |
| Notifications tab (`/notifications`, replaces the placeholder) | App bar: Mark all read (icon, off when nothing unread), Alert settings (icon). "New" then "Earlier"; a row per notification: group icon, one-line title, sentence with the run, time and an unread dot; tap opens its screen and marks it read | Skeleton rows | "No alerts yet" | Error view + retry | Offline view + retry |
| Alert settings (`/profile/notifications`, also from Profile) | Intro; "Also by WhatsApp": a switch per group (urgent groups first, subtitle "WhatsApp and phone alert" / "Phone alert only"); chat note; "Quiet hours" switch "22:00 to 06:00, except urgent alerts" | Skeleton rows | n/a (defaults) | Error view | Offline view |
| Tab shell | Dot on the Alerts tab while something is unread (screen reader: "3 unread"); the newest unopened critical alert pinned above the tabs with Open | — | — | — | — |

Unverified parents may open the Notifications tab (the verification
result). New design-system pieces `AppUnreadDot` and `AppAlertBanner` are in
the gallery under "Alerts".

## New packages (CLAUDE.md rule 3)

- `flutter_local_notifications ^19.4.0`: the app's own alarm for critical
  alerts (local notification with sound, iOS time-sensitive), the
  standard Flutter plugin, free. Java/Swift, so no `KOTLIN_FIX_PLUGINS`
  entry; Android needs core library desugaring and the plugin's
  receivers, added by `tool/patch_native.py`. AppDelegate sets the
  notification-center delegate (patch_native).
- `timezone ^0.10.0`: the plugin's time type; we schedule in UTC so no
  time-zone database is loaded.
- `firebase_messaging` was already in the stack and pubspec; now used.

## Decisions

1. **Outbox + one trigger** instead of a trigger per producer
   collection: one function sends everything; schedule and new-parent
   producers write to the same collection.
2. **Groups, not raw types, in Settings** (9 switches): swap types,
   reminders and so on belong together for a parent.
3. **Alarm delay 15 minutes** (`NOTIFY_ALARM_DELAY_MIN`).
4. **Evening reminder from 19:00** (`REMINDER_EVENING_AT`); missing
   confirmation reminder two hours before the cut-off (19:00 with the
   21:00 cut-off).
5. **A real push needs the deployed dev project**; on the emulators the
   push is logged (the app there has no FCM sender).
6. **Time-sensitive entitlement is opt-in** (`TIME_SENSITIVE_ALERTS=1`)
   because signing fails until the App IDs have the capability.

## How to test it on the iPhone (the "Done when" check)

1. Emulators and seed as in Prompts 6 and 7; dev app with
   `--dart-define=EMULATOR_HOST=<Mac IP>`; allow notifications when asked.
2. **Swap request in the Notifications tab:** as in Prompt 7 step 5 but
   the other way round: Hoda asks for a swap on one of her confirmed runs
   (`npm --prefix functions run carpool:emulator -- swap <id> <runId> --as seed-map-parent-1`).
   The Alerts tab shows a dot; open it: "Swap request — A member asked for
   a swap: Mon 16/11, to school." Tap it: the week plan opens and the dot
   goes.
3. **Emulator log shows the WhatsApp message:** let a run be missed
   (Prompt 7 step 8, then `... carpool:emulator -- tick --as any`). The
   functions emulator log shows `[fake push] no-driver (time-sensitive,
   sound)` and `[fake WhatsApp] template cp_no_driver (ar) to +20*****01
   ...`. The banner "No driver confirmed" appears above the tabs.
4. **Switching a type off stops its WhatsApp:** Profile > Alert settings >
   "No driver" off. Repeat step 3 with another run: the log shows the push
   but no WhatsApp line. (Switch "Swaps" on and repeat step 2 to see a
   `cp_swap_requested` WhatsApp line.)
5. **Alarm:** leave the "no driver" alert unopened; 15 minutes later the
   phone rings the alarm (app's own alarm), or run
   `... carpool:emulator -- remind --as any` after that time to see the
   "Reminder:" push in the log.
6. **A real reminder push on the iPhone:** SETUP.md 18.1, 18.2 and 18.6 for
   the dev project (APNs key uploaded, `PUSH_PROVIDER=fcm`, deploy), run
   the dev build without `EMULATOR_HOST`, sign in, then
   `GCLOUD_PROJECT=<dev id> npm --prefix functions run notify:cloud -- <your uid> drive-hour`.
   The iPhone shows "Run within the hour". Tapping it opens the app.
7. Sign out and run step 6 again: nothing arrives (token removed).
8. Check Arabic and dark mode.

## Tests

| Test | Status |
| --- | --- |
| `functions/test/notifications.test.ts` (45): catalogue, routes, one outbox; routing (actor, suspended, banned, unverified, verification result), no phone, dead tokens, stale events, unknown types; **idempotency** (same event twice, failed push retried without a second WhatsApp, attempts cap, crash mid-send); WhatsApp defaults, switching on/off, consent, phone, chat, language; quiet hours (Cairo, DST, midnight); **privacy: no names, addresses, child IDs or actor in any push or WhatsApp payload for every type, data keys fixed**, in-app record, `{when}` input, masked WhatsApp log, dispatcher logs; new parent (radius, notify off, unverified, other school, subject hidden); critical alarm (escalation once, read ones cancelled, no extra WhatsApp), FCM message shape; reminders (evening, hour, confirm, written once, Done-when push); phones and settings (move, refresh, limits, validation); senders | **Run here: pass** |
| `carpools.test.ts`, `verification_flow.test.ts`: join and verification events | **Run here: pass** |
| All Functions unit tests | **Run here: 367 pass** (Node 22, `tsc` against stand-in stubs; only the known Sentry stub gap) |
| `tests/rules/notifications.test.ts`, `deny_all.test.ts` paths | Written, not run here (CI); type-checked against a stub |
| `test/notifications/notification_logic_test.dart` | Written, not run here |
| `test/notifications/notification_screens_test.dart`: tab (sections, text, dots, tap, mark all, offline, empty, error, offline, banner, Arabic, settings link), settings (defaults, on, off, quiet, failure reverts, error, Profile row), NotificationCenter (registration, refresh, no permission, sign-out, push tap, bad route, alarms), **one line at 320 dp AR/EN x1/x2** | Written, not run here |
| `router_test.dart` updated (Notifications tab screen) | Written, not run here |
| Screenshots `notifications_tab`, `notifications_settings` (AR/EN, light/dark) | Written, not run here (CI artifact) |

## Learned from earlier reviews

- Every new collection has rules tests (other parents, admins, signed out,
  client time, extra fields, missing documents); Functions-only
  collections stay closed; older tests updated deliberately (router tab
  test, deny-all paths).
- Limits counted on the server, after input checks; sign-out never
  limited.
- Concurrency: claims and escalations are transactions.
- Analyzer habits as before; widget tests use tall views, explicit
  scrollables, one ProviderScope shape (`authOverrides` now includes the
  notification fakes and a fixed clock).

## Open questions for the owner

1. Alarm after **15 minutes** unopened. OK, or shorter for "no driver"?
2. Quiet hours **22:00–06:00** by default (critical alerts still sound).
   Should parents choose the times (the server already accepts them)?
3. "Opened" = read in the app. Do you want WhatsApp read receipts to count
   too (needs Meta's webhook)?
4. Should **verification results** go to WhatsApp by default? (Today push
   only; the parent may be waiting days.)

## Not done / known gaps

- `child-not-confirmed` has its type, text, template and settings; its
  producer comes with trips (F34).
- Chat notifications (Prompt 9) use `chat-message`; no producer yet.
- Android notification channels beyond the plugin's own, Android 13
  permission flow and web push (Stage 2 and 3).
- WhatsApp templates must be created and approved in Meta (SETUP 18.4).
- **FCM registration by Firebase Installation ID.** firebase_messaging 17
  deprecates `getToken`/`onTokenRefresh`/`deleteToken` in favour of
  `register()`/`onRegistered`/`unregister()`. Firebase says tokens and FIDs
  are both fully supported during the transition, and moving changes the
  server's send target from `token` to `fid` as well. The three calls keep
  the token API with `// ignore: deprecated_member_use`
  (`push_messaging.dart`). The Dart signatures of the new API could not be
  checked here (the changelog names only "add FID registration APIs"), so
  the move is one later change: app and `push.ts` together, with tests.
- Account deletion must delete `notificationSettings`, `pushTokens`,
  `notificationLimits` and `users/{uid}/notifications` (Prompt 12 list).
- Not verified here: `flutter analyze`, `flutter test`, the rules tests,
  the iOS build with the new plugin.
