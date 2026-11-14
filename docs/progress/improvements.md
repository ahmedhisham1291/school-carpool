# Improvements plan (owner request 14 Nov 2026, 17:17)

Decisions: docs/DECISIONS.md "Improvements". One branch, one builder and one
validator per workstream; one manual CI run per branch; merge to main.

| Workstream | Branch | Main files | Status |
| --- | --- | --- | --- |
| A. Pilot feature switches (wallet off) | improve-a-feature-switches | functions/src/config + features, lib/features/*, admin panel settings | started |
| B. Own chat on Firestore (replace Stream) | improve-b-firestore-chat | functions/src/chat, lib/features/chat, firestore.rules, tests | started |
| C. Crashlytics + Error Reporting (replace Sentry) | improve-c-crashlytics | lib/main_*.dart, lib/core/errors, functions/src/sentry.ts, pubspec | started |
| D. SMS backup for codes | improve-d-sms-backup | functions/src/auth, lib/features/auth, config, ARB | started |
| E. Xcode Cloud, private repo plan, Meta guide | improve-e-docs | ios ci_scripts docs, docs/*.md | started |

After all merge: update tool/cloud_setup.sh (secrets, settings), SETUP.md,
COSTS.md, app-store-privacy.md; redeploy staging; new TestFlight build.

## SMS provider candidates (owner to choose; fake until then)

Twilio (Verify or Messaging), Vonage, Infobip, or an Egyptian gateway
(for example Victory Link or Cequens). Choose on price per SMS to Egyptian
numbers, delivery rate, and Egyptian sender-ID registration.
