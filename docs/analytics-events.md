# Usage analytics: events catalog

Owner decision (DECISIONS.md "Data retention and collection", 14 Nov 2026):
screens and features used are collected with Google Analytics for Firebase,
with **no names, phone numbers, IDs, message text or coordinates**. On by
default; the parent switches it off in Settings or on the privacy screen
(stored on the phone, recorded on the server as an "analytics" consent).
Crashes go to Sentry (scrubbed), not to Analytics.

Code: `lib/features/analytics/analytics.dart`. Every event goes through
`Analytics.track`, which keeps only the event's own parameter keys and only
values that are a short lowercase word, a bool (sent as 0 or 1) or a whole
number 0 to 1000. Anything else is dropped, so a mistake in a screen cannot
send personal data (`test/privacy/privacy_logic_test.dart`).

## Screens

`screen_view` with the route PATTERN, never the real path:
`carpools/:id/trip/:id/drive`, `profile/privacy/devices`. A segment that is
not a fixed word becomes `:x` (an invite code, a chat ID). Logged by a
listener on the go_router delegate (`routerProvider`), once per change.

## Events

| Event | When | Parameters (allowed values) |
| --- | --- | --- |
| `sign_in_done` | After a right WhatsApp code | `new_device` (0/1) |
| `verification_submitted` | Documents sent | `scope` (identity, children, driver) |
| `carpool_created` | A carpool is created | `kind` (school, activity) |
| `carpool_join_requested` | A join request is sent | none |
| `run_confirmed` | A driver confirms a run | `direction` (to-school, to-home) |
| `run_started` | A driver starts a run | `direction` |
| `run_ended` | A run ends | `direction`, `result` (done, ended) |
| `chat_opened` | A chat opens | `kind` (private, school, area, carpool) |
| `wallet_transfer` | A transfer finishes | `result` (done, failed, pending); never the amount |
| `rating_given` | A parent is rated | none (never the stars) |
| `privacy_export` | Data download | `result` (done) |
| `consent_changed` | A consent is given or withdrawn | `kind` (consent kind), `granted` (0/1) |
| `account_deleted` | Account deleted | none |
| `app_lock_changed` | App lock switched | `enabled` (0/1) |
| `device_signed_out` | A phone signed out from the list | `all` (0/1) |
| `always_location` | A driver answers the optional "Always" step (Prompt 13) | `granted` (0/1); never a location |

Prompt 12 sends `privacy_export`, `consent_changed`, `account_deleted`,
`app_lock_changed` and `device_signed_out`; the other events are in the
catalog for the features' screens to send when they are next touched (each
is one line: `ref.read(analyticsProvider).track(...)`).

## Never

No `setUserId`, no user properties, no advertising ID or IDFV
(`GOOGLE_ANALYTICS_ADID_COLLECTION_ENABLED`, `..._IDFV_...`,
`..._DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS`, `..._AD_USER_DATA` all false
in Info.plist, tool/patch_native.py). Collection is off in Info.plist until
the app reads the parent's choice at start.

## Retention

Google Analytics: set **Data retention** to 2 months (Admin > Data settings >
Data retention) in every Firebase project (SETUP.md 23.5), and keep "Google
signals" and data sharing off.
