# Prompt 8 follow-ups review

Branch `prompt-08-followups`, head `01f4b22`, based on `main` `7b793ba`.
Commits reviewed: `3b74681`, `c757178` and `01f4b22`. I reviewed
`git diff main...HEAD` (21 files) against the items in
docs/reviews/prompt-08-review.md.

## Verdict: PASS

## CI

Run 43556737731 on `01f4b22`: **all green**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators) | success |
| Web, admin panel and Android compile (staging) | success |

I ran no compiler or tests here myself. The progress note says the
Functions tests were run by the build agent (381 pass) and that the Dart
tests ran only in CI.

## Items from the Prompt 8 review

| # | Item | Status |
| --- | --- | --- |
| 1 | Old alarms ring again at every start | **Fixed.** `planAlarms` rings an alarm only within `kAlarmRingWindow` (2 h) of its alarm time. The IDs of alarms the phone rang or scheduled are kept on the phone (`alarms.rung`, at most 50, IDs only) and cleared at sign-out. An alarm is recorded when it is scheduled, so a phone that rings it at its time never rings it again when the app opens. The background handler records it too. Logic tests cover the window and the 50-ID cap. |
| 2 | WhatsApp switches do nothing without consent | **Fixed.** A new "WhatsApp messages" switch comes first. Turning it on asks the parent to confirm, then calls `setWhatsAppNotifications`. That callable is counted against the settings limit and runs one transaction: it adds a `whatsapp` consent record (source `settings`, the current version), or sets `withdrawnAt` on the open one, and sets `whatsappOptIn`. Without consent every group switch shows off and is locked. The Arabic and English strings match. Both server tests (accept, withdraw, limit) and widget tests were added. |
| 3 | A re-confirm reminder can be lost | **Fixed.** `reminderId` now includes `confirmByMs` for the confirm reminder and `startMs` for the drive reminders. A moved or re-asked run gets new reminders; the same time still gets only one. |
| 6 | Tick reads tomorrow's runs all day | **Fixed.** No query for tomorrow's runs before `REMINDER_EVENING_AT`. |
| 7 | Mark all read fails as a whole | **Fixed.** On `permission-denied` it marks the rows one by one, and `markRead` ignores rows that were already read. Other errors still become a `NotificationFailure`; the throw from the first catch clause is not swallowed by the `on Object` clause. |
| 8 | Settings screen keeps `_pending` | **Fixed.** `_pending` is used only while saving or until the stream moves past the value saved with it (`_base`). After that the stream wins, including a change made on another phone. |
| 10a | Side effect in `HomeShell.build` | **Fixed.** The router is handed over in a post-frame callback. |
| 4, 5, 9, 10b | Two sounds at the alarm time, the unsalted hash, the FID migration, `invalid-argument` | Left as they are, with reasons recorded in the progress note. I accept all four. |

## Blocking

None.

## Non-blocking

1. **The phone's list of rung alarms is shared by two isolates.**
   - The background handler writes `alarms.rung` through its own
     `SharedPreferences` instance. The running app's instance keeps its
     own copy in memory and does not see that write.
   - The app's next `rememberAlarm` rewrites the whole key and can drop the
     ID the background handler added.
   - The 2-hour ring window limits the damage to at most one extra ring,
     which the code comment already accepts.
   - To close it, call `prefs.reload()` before `rungAlarmIds` in
     `_sync`, or move to `SharedPreferencesAsync`.
2. **The consent switch keeps its own value.** `_optIn` stays set after a
   successful save until the screen closes, so a withdrawal made on another
   phone shows only after the screen is reopened. This is minor.
3. **Withdrawing WhatsApp consent asks for no confirmation.** That is
   acceptable because it can be undone, but a one-line snackbar would be
   clearer: "WhatsApp alerts stopped".
