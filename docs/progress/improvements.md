# Improvements plan (owner request 14 Nov 2026, 17:17)

Decisions: docs/DECISIONS.md "Improvements". One branch, one builder and one
validator per workstream; one manual CI run per branch; merge to main.

| Workstream | Branch | Status |
| --- | --- | --- |
| A. Pilot feature switches (wallet off) + Settle up by InstaPay | improve-a-feature-switches | builder started 14 Nov 17:30 |
| B. Own chat on Firestore (replace Stream) | improve-b-firestore-chat | builder started 14 Nov 17:30; merge after the first TestFlight build |
| E. Locked package versions, Meta WhatsApp guide, private-repo plan | improve-e-docs | builder started 14 Nov 17:30 |
| C. Crashlytics | (dropped) | withdrawn, Sentry stays |
| D. SMS backup | (on hold) | waits for Meta |

After all merge: update tool/cloud_setup.sh (secrets, settings), SETUP.md,
COSTS.md, app-store-privacy.md; redeploy staging; new TestFlight build.

## SMS provider candidates (owner to choose; fake until then)

Twilio (Verify or Messaging), Vonage, Infobip, or an Egyptian gateway
(for example Victory Link or Cequens). Choose on price per SMS to Egyptian
numbers, delivery rate, and Egyptian sender-ID registration.
