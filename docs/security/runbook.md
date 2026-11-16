# Security runbook

What to do, in order, when something goes wrong. The roles, the 72-hour
clock and the general incident steps are in SECURITY.md section 3. The
legal notification steps under Egypt's Personal Data Protection Law (Law
151 of 2020: report to the Personal Data Protection Center, telling the
people affected, the breach register) are in
[docs/legal/breach-runbook.md](../legal/breach-runbook.md) from the legal
review; follow that file for every notification and its wording, **per
legal review**. This file covers the technical side.

Console links use `<project>` for the project ID (`school-carpool-prod`,
`...-staging`, `...-dev`).

## 0. First 15 minutes (any incident)

1. Write down the time you learned of it and who told you.
2. Open an incident note (private folder): what is known, which data types
   may be affected, which accounts.
3. Preserve evidence before changing anything:
   - Admin panel > Audit log: export the window (or
     `gcloud firestore export gs://<backup-bucket>/incident-<date> --collection-ids=auditLog,securityAlerts,reports --project <project>`).
   - Cloud Logging: <https://console.cloud.google.com/logs/query?project=<project>>,
     save the query results for the window (Functions, Identity Platform,
     Data Access audit logs).
   - Sentry: the issue links.
4. Decide containment (below) with the owner. Do not delete data that is
   evidence; suspend instead.
5. Start the legal clock: see docs/legal/breach-runbook.md.

## 1. Parent account takeover (SIM swap, stolen phone, WhatsApp hijack)

Signs: "New phone signed in" the parent did not make, a failed or
mismatched new-phone selfie (report in the admin queue), the parent calls.

1. Admin panel > Users > the parent > **Suspend** (reason code). This
   revokes refresh tokens, sets `sessionsValidAfter` (every phone loses
   access at once in rules and callables), stops any live run they drive
   and closes chat.
2. If a new-phone check is open: **do not clear it** (`adminClearDeviceCheck`)
   until the parent is confirmed by a call on a known number or in person.
3. Ask the parent to recover their WhatsApp/SIM with the carrier first
   (the code channel is the account key).
4. Check the audit log and the parent's sign-ins (Users > the parent >
   Phones) for what the attacker opened: children, carpools, trips, chat.
5. Tell the other parents of the carpools involved if the attacker could
   have seen live runs or exact pickup points (legal file decides wording).
6. When the parent is back in control: unsuspend; the next sign-in from
   their phone is a new phone again and asks for a fresh selfie.

## 2. Admin account compromise

Signs: an admin sign-in alert at an odd time or place (owner-actions,
alert 1), audit entries the admin did not make, photo views without a
case.

1. A super admin: Admin panel > Admins > the admin > **Disable**. This
   revokes their tokens; `revokedAt` stops every call and rule read at once.
2. Firebase console > Authentication > the admin's account > Disable
   (belt and braces), and reset their TOTP: remove the enrolled factor
   (Users > the account > Multi-factor).
3. Export the audit log for that admin's uid since their last good sign-in.
   Every photo, route and user view carries a reason code; list the
   parents whose data was opened.
4. If the compromised account was a **super admin**: check Admin panel >
   Settings (feature switches) and Admins for changes; check IAM
   (<https://console.cloud.google.com/iam-admin/iam?project=<project>>)
   for new members.
5. Rotate anything the admin could have seen that is a secret (none of
   the server secrets are shown in the panel; the one-time admin setup
   links expire).
6. Re-enroll: new password through the admin script's one-time link, new
   TOTP.

## 3. Data breach (data left our control)

1. Contain the path: if a rule is the cause, deploy the fixed rules first
   (`firebase deploy --only firestore:rules,storage --project <alias>`,
   with its emulator tests); if a function is the cause, disable it
   (Cloud Run > the service > Edit > Max instances 0, or
   `firebase functions:delete <name> --project <alias>`); if a key or
   secret is the cause, rotate it (section 5).
2. Measure: which collections or files, which parents and children, which
   time window. Data Access audit logs (owner-actions, item 6) show who
   read what in Firestore and Storage.
3. Notify per [docs/legal/breach-runbook.md](../legal/breach-runbook.md),
   which holds the legal timeline and wording (Law 151 of 2020 and its
   Executive Regulations): the Personal Data Protection Center within
   **72 hours** of becoming aware, and the parents affected within
   **3 working days** of notifying the Center. There is no risk
   threshold: every breach of personal data is notified. **Per legal
   review.**
4. Recover: restore from PITR or the daily backup if data was changed
   (docs/restore-test.md).
5. Review within 2 weeks: add a test that would have caught it.

## 4. Suspected predator or child-safety report

1. Admin panel > Reports: open the report, then the user (reason code
   `safety`). **Suspend** at once if there is any doubt (step-up sign-in
   required; takes a minute).
2. Their runs are released to the group; live tracking of their trips
   stops; chat closes.
3. Keep the evidence: photos and selfies are kept up to 30 days after
   account closure only while a report or safety case is open (CLAUDE.md
   PRIVACY), so leave the report open.
4. Ban (adds the national-ID hash to the ban list) when confirmed.
5. Police and legal: per legal review.

## 5. Key and secret rotation

All server secrets are in Secret Manager. Rotate with
`firebase functions:secrets:set <NAME> --project <alias>` and redeploy the
functions that use it (`firebase deploy --only functions --project <alias>`);
then destroy the old version
(<https://console.cloud.google.com/security/secret-manager?project=<project>>).

| Secret | When | How | Side effects |
| --- | --- | --- | --- |
| `OTP_HMAC_KEY` | Suspected leak; yearly | New random 64-byte value | Pending codes (5 min) stop matching; per-number limits and "known device" marks reset (parents on known phones lose the daily-cap exemption for a while). No data loss |
| `NATIONAL_ID_HMAC_KEY` | **Only** on a proven leak | Needs re-hashing: the ban list and duplicate-ID check depend on it. Plan with the developer: compute new hashes from the decided cases still kept, then switch | Without re-hashing, banned IDs could sign up again |
| `WHATSAPP_ACCESS_TOKEN` | Leak; when Meta expires it | Meta Business > System users > Generate token (WhatsApp permissions only) | Codes fail until redeployed |
| `STREAM_API_SECRET` | Leak (until the Stream chat is removed) | Stream dashboard > App > Regenerate secret, then set and deploy | All chat tokens die (parents reconnect); webhook signatures change at once |
| `ALGOLIA_WRITE_KEY`, `ALGOLIA_SEARCH_KEY` | Leak; yearly | `python3 tool/algolia_keys.py` (makes keys limited to the index) | Secured keys already given out expire within 1 hour |
| `MAPS_SERVER_KEY` | Leak | APIs & Services > Credentials > the server key > Regenerate (keep the API restrictions) | None for parents |
| iOS Maps key, Firebase web/iOS API keys | Not secrets (shipped in the app); restrict them instead (owner-actions 9) | | |
| KMS key for the photo bucket | Yearly, automatic (`tool/setup_kms.sh`) | Old versions stay for decryption | None |
| App Store Connect API key, Codemagic tokens | Leak; when a person leaves | App Store Connect > Users and Access > Integrations > revoke and create; update the Codemagic integration | Builds fail until updated |
| GitHub tokens / deploy keys | Leak; when a person leaves | GitHub > Settings > Developer settings / repo Deploy keys | |

After every rotation: one sign-in on staging (code arrives, sign-in
works), one admin panel call, Sentry quiet for 15 minutes.

## 6. Admin offboarding (same day)

1. Admin panel > Admins > **Disable** (tokens revoked at once).
2. Firebase console > Authentication > the account > Disable; remove the
   TOTP factor.
3. Remove them from: Google Cloud IAM and Firebase project members (all
   three projects), GitHub (repo collaborators, organization), Codemagic
   team, App Store Connect, Sentry, Algolia, Stream, Meta Business, the
   domain registrar and email provider.
4. Rotate any secret they could read (section 5): anyone with Secret
   Manager access or Cloud Shell on the project could read them.
5. Export their audit entries for the last 90 days into the incident
   folder (a record of what they opened).
6. Write the date and what was removed in the private admin register.

## 7. Turning a money feature on (for the record)

Money is OFF (owner decision 16 Nov 2026). If the owner ever decides
otherwise: a super admin signs in fresh (step-up), Admin panel > Settings >
the switch; the audit log records it. Before that: the wallet needs the
licensed partner contract and its own review; Settle up needs the lawyer's
confirmation recorded in docs/DECISIONS.md.
