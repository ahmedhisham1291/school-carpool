# Prompt 8 review: Notifications by push and WhatsApp (F12, F23)

Branch `prompt-08-notifications`, head `42ac708` (includes `main` with
Prompts 1 to 7). I reviewed `git diff origin/main...HEAD` (66 files) against
CLAUDE.md, docs/spec.md (F12, F23, section 7 "On the phone", section 11
critical alerts), docs/build-prompts.md "Prompt 8" and its "Done when",
DECISIONS.md, DESIGN.md, WORKFLOW.md, docs/progress/prompt-08.md and the
Prompt 7 review's note on the re-confirm notice.

## Verdict: PASS

No blocking items. There are non-blocking items below; fix 1 to 3 before
the pilot.

## CI

Run 43554390831 on `42ac708`: **all green**.

| Job | Result |
| --- | --- |
| Cloud Functions tests and rules tests (emulators) | success |
| Flutter analyze, tests and screenshots | success |
| Web, admin panel and Android compile (staging) | success (bootstrap with `patch_native.py`, web, admin, Android APK) |

I ran no compiler or tests here (no Flutter SDK in this workspace). I could
not download the screenshots artifact either, because the proxy refused the
artifact storage host. So the design check below comes from the code and
the widget and one-line tests, not from the images. The owner should look
at `notifications_tab_*` and `notifications_settings_*` in the CI artifact.

## What I checked

- **One sender.** The only send path is `sendNotification`
  (`onDocumentCreated` on `notificationEvents`, `retry: true`) →
  `dispatchEvent`. The Prompt 7 `SCHEDULE_EVENTS` constant now points at
  the outbox (`schedule/store.ts:31`). The Prompt 5 new-parent event
  (`maps/store.ts`) and the Prompt 3 verification decision
  (`verification/store.ts`, in the decision transaction) write to the
  outbox too.
- **Every producer is wired.** I searched every `event(`/`runEvent(`
  call. These all reach the outbox:
  - schedule events: `plan-ready`, `no-driver` (release, retime and tick),
    `swap-requested`, `driver-unavailable`, `swap-cancelled`,
    `swap-accepted`, `run-taken`, `child-absent`, `child-back`,
    `schedule-changed` (twice) and `time-changed` (`schedule/flow.ts:524`,
    critical when `notice === "moved"`);
  - join events: `join-requested` to the admins, read before any write in
    the transaction, plus `join-approved` and `join-declined`;
  - the verification result, `new-parent`, and the tick's reminders and
    alarms.

  Every type has a catalogue entry, a text and a route. The test "every
  schedule event kind the flows write is a notification type" pins this.
- **Idempotency.**
  - The in-app record is created once with `create()`, keyed by the event
    ID.
  - Each channel (push, WhatsApp, alarm) is claimed per recipient in a
    transaction, at most 3 attempts. Concurrent or retried triggers cannot
    send twice. A crash mid-send loses that one message rather than
    doubling it, which is documented.
  - Events older than 6 hours are marked failed.
  - Reminders and alarms have fixed IDs and are created with `create()`.
    The escalation is one transaction (record state and alarm event
    together).
  - Tests cover: the same event twice, a failed push retried without a
    second WhatsApp, the attempts cap, and a claimed-but-unfinished
    channel.
- **Privacy.**
  - Push and WhatsApp text comes only from `texts.ts`.
  - `{when}` accepts only a checked `YYYY-MM-DD` date and a known direction.
  - Push data has a fixed key set.
  - The new-parent record ID is a hash, not the uid.
  - The fake WhatsApp log masks the number.
  - The tests are real. They dispatch every type to two languages with a
    `childId` and an `actorUid` in the event, check that no forbidden word
    or ID appears in any push or WhatsApp payload, and check the exact
    data keys, the masked logs and the in-app record.
- **COST MODE.** WhatsApp defaults: only `noDriver` and
  `childNotConfirmed` are on. A critical `time-changed` follows `noDriver`.
  Chat has no template (push only). WhatsApp also needs the sign-up opt-in
  and a phone number. Sign-in codes stay in the sign-in functions.
  SETUP 18.4 lists all 20 templates. `minInstances` is the `MIN_INSTANCES`
  config, 0 by default.
- **Quiet hours.** Default 22:00–06:00 Cairo, using `cairoOffsetMinutes`.
  Tests cover summer time, the window across midnight and the off switch.
  Non-critical alerts become a silent passive push with no WhatsApp.
  Critical alerts always sound and go to WhatsApp.
- **Critical alarm timing.**
  - `alarmAt` is the record time plus 15 minutes (configurable, 5 to 120).
  - The tick runs every 5 minutes, so the server's louder "Reminder:" push
    goes out 15 to 20 minutes after the alert, once, and only if the record
    is still unread.
  - The app's own local alarm is scheduled from the content-available push
    (background handler) or from the list, and is cancelled when the alert
    is opened.
  - The banner stays above the tabs until the alert is opened.
- **FCM tokens.**
  - Tokens are stored one document per token, keyed by the token's SHA-256.
  - A phone that signs in as another parent moves to that parent.
  - A token refresh replaces the old token (the previous token is kept on
    the phone).
  - Each parent has at most 10 phones; the oldest goes first.
  - Sign-out unregisters the token on the server, deletes it with FCM and
    cancels the local alarms. This is best effort with 5-second timeouts,
    and is not rate-limited.
  - Tokens FCM refuses for good are deleted while sending.
- **Deprecated `getToken`/`onTokenRefresh`/`deleteToken` with
  `// ignore: deprecated_member_use`.** Acceptable, not blocking.
  - firebase_messaging 17.0.0 only "add[s] FID registration APIs"
    ([changelog](https://pub.dev/packages/firebase_messaging/changelog)).
    The deprecation message points to `unregister()`
    ([flutterfire#18482](https://github.com/firebase/flutterfire/pull/18482)).
  - The token path keeps working until you migrate. In FID mode Firebase no
    longer returns an FCM token at all
    ([Customer.io FID migration note](https://docs.customer.io/integrations/sdk/flutter/whats-new/fid-migration/)).
  - So the move to FIDs must change the app and the server's send target
    together. Deferring it as one tracked change is right. Keep it on the
    Stage 2 list (item 9).
- **notificationTick cost.**
  - It runs every 5 minutes (about 8,700 runs a month) with
    `minInstances` 0, `retryCount` 1 and a 120 s timeout.
  - It makes 4 bounded queries (500 each) with matching composite indexes:
    `schedule` on (status, startAt) and (status, confirmBy), and
    `notifications` on (alarmState, alarmAt).
  - The third Cloud Scheduler job is noted in COSTS.md.
- **Rules.**
  - `users/{uid}/notifications`: get for the owner only; list for the
    owner with a limit of 100 or less. An update may set only `readAt`,
    only once, and only to `request.time`. Create and delete are denied.
  - `notificationSettings/{uid}`: get for the owner only.
  - The outbox, `pushTokens` and `notificationLimits` are closed.
  - The rules tests cover other parents, admins, signed-out users,
    collection-group reads, client time, extra fields and the batch "mark
    all read". The deny-all paths were updated.
- **iOS.**
  - The time-sensitive entitlement is added only when
    `TIME_SENSITIVE_ALERTS=1` (SETUP 18.3). Without it, signing cannot
    break; alerts still sound but Focus can hold them.
  - `aps-environment` and `remote-notification` were already present.
  - AppDelegate sets the notification-center delegate.
- **Android (`patch_native.py`).** Adds core library desugaring
  (`desugar_jdk_libs:2.1.4`), the plugin's two receivers and
  `RECEIVE_BOOT_COMPLETED`. All three are idempotent through markers. The
  Android CI build passed with them.
- **Packages.** `flutter_local_notifications ^19.4.0` and
  `timezone ^0.10.0` resolved in CI. Both are justified in the progress
  note under rule 3. Scheduling in `tz.UTC` needs no time-zone database.
- **Design.**
  - Titles use `OneLineText`, with one-line tests at 320 dp for AR and EN
    at text scale 1x and 2x.
  - Both screens have skeleton, empty, error and offline states.
  - Layouts use directional insets and tokens only.
  - New components go in the gallery first: `AppUnreadDot` and
    `AppAlertBanner`.
  - The tab dot has a screen-reader label.
  - Arabic and right-to-left are tested.
- **ARB.** 1,112 keys in both files, no missing keys. The Arabic plural for
  `notifUnreadCount` has all its forms.
- **Done when.**
  - **Reminder push on the iPhone:** `notify:cloud -- <uid> drive-hour`
    against the deployed dev project (SETUP 18.6). The owner has to check
    this on the device.
  - **Swap request in the Notifications tab:** covered by widget tests and
    the flow.
  - **WhatsApp line in the emulator log:** comes from the fake sender, as
    `cp_no_driver` by default. Under COST MODE, `cp_swap_requested`
    appears only after the parent switches "Swaps" on, and test step 4
    says so.
  - **Switching a type off stops its WhatsApp:** unit-tested.

## Blocking

None.

## Non-blocking

1. **The app's alarm rings again on every app start for old unread
   critical alerts.** `planAlarms` (`lib/features/notifications/notification_logic.dart:42-43`)
   rings every unread critical alert whose `alarmAt` has passed, unless it
   rang "in this run of the app". `_rung` is in memory only
   (`notification_center.dart:31`). So a "no driver" alert left unread
   from last week sounds each time the app is opened, for up to 60 days
   (TTL). An alarm that the background handler already delivered on time
   also sounds a second time when the parent next opens the app.
   **Fix:** ring only when `alarmAt` is recent (for example within 2 hours,
   or before the run's end). Keep the rung IDs in `SettingsStore`. Add a
   logic test for "old unread alert does not ring at start".
2. **WhatsApp switches do nothing for parents who declined WhatsApp at
   sign-up.** `wantsWhatsApp` needs `whatsappOptIn` (`model.ts:238`), but
   the settings screen (`notification_settings_screen.dart:79`) shows
   "WhatsApp and phone alert" for any parent and lets them switch groups
   on. There is no way to give consent later.
   **Fix:** expose the opt-in in the settings stream (or the account).
   Without it, show one line, "You chose no WhatsApp at sign-up", and
   either disable the switches or add a consent step that records a
   `whatsapp` consent through Functions.
3. **A re-confirm reminder can be lost (Prompt 7 note).** A re-asked driver
   gets a non-critical `time-changed`. The tick's `confirm-reminder` then
   covers the new deadline. But `reminderId` is
   `type_carpool_run_driver` (`tick.ts:70-72`). If that driver already got
   a `confirm-reminder` for the run before the time moved, the second one
   is never created. The `drive-hour` and `drive-evening` reminders after a
   re-time have the same problem.
   **Fix:** add `confirmByMs` (for `confirm-reminder`) or `startMs` (for
   the drive reminders) to the ID. Add a test.
4. **Two sounds at the alarm time.** The local alarm (at `alarmAt`) and the
   server's "Reminder:" push (tick, 0 to 5 minutes later) both sound on a
   phone where the app ran. That is acceptable for spec section 11, but
   consider skipping the server alarm push for a phone that confirmed it
   scheduled the local alarm, or accept it and tell the owner.
5. **The new-parent record ID is an unsalted hash of the uid**
   (`producers.ts:26`). A parent who knows other parents' uids (carpool
   members) can compute `sha256("new-parent:"+uid)` and tell who the new
   parent is. The impact is low, because the push names no one, but use an
   HMAC with a Functions secret, or a random ID created once.
6. **The tick reads tomorrow's confirmed runs every 5 minutes, all day**
   (`tick.ts:123`), even before 19:00, when the result is thrown away.
   After 19:00 it re-tries `create()` for every run on every tick until
   midnight. That is small now. Gate the "tomorrow" query on Cairo time ≥
   `REMINDER_EVENING_AT`, and consider a per-day marker so the re-tries
   stop.
7. **"Mark all read" fails as a whole if one row was read in the
   meantime.** One update in the batch is denied by the read-once rule
   (`notification_repository.dart:80-89`). Commit in chunks, or ignore
   `permission-denied` and mark the rest one by one.
8. **The settings screen keeps `_pending` after a successful save**
   (`notification_settings_screen.dart:38,68`). A change made on another
   phone is hidden until the screen is reopened. Clear `_pending` on
   success, or when the stream catches up.
9. **FID migration.** Track replacing `getToken`, `onTokenRefresh` and
   `deleteToken` with `register()`, `onRegistered` and `unregister()`, and
   replacing the server's `token` target with `fid`, as one change. Do it
   before the deprecated APIs are removed (watch the firebase_messaging
   changelog).
10. **Code hygiene.**
    - `HomeShell.build` assigns `router` on the provider object
      (`home_shell.dart:62`). This is a side effect in `build`; move it to
      a post-frame callback or a listener.
    - `DEAD_TOKEN` (`push.ts:18`) misses `messaging/invalid-argument` for
      malformed tokens. That is harmless, because a malformed token never
      gets in past the callable's check.
11. **Still open, as the progress note says:**
    - account deletion must also clear `notificationSettings`,
      `pushTokens`, `notificationLimits` and `users/{uid}/notifications`
      (Prompt 12);
    - `child-not-confirmed` has no producer until F34;
    - Android channels beyond the plugin's own (`general` and `quiet`
      currently fall back to FCM's default channel) wait for Stage 3;
    - the WhatsApp templates must be approved in Meta.
12. **Owner questions** in the progress note: the alarm delay, choosing
    quiet-hours times, WhatsApp read receipts, and WhatsApp for
    verification results. They need answers, but none blocks this merge.
