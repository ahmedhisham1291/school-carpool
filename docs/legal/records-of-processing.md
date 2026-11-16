# Record of processing activities (controller)

Law No. 151 of 2020 and Decree 816/2025: the controller keeps an electronic
register of its processing, available to the PDPC (the PDPC checklist lists
15 elements for a controller). This is the working draft. **Not legal
advice; the DPO and the lawyer finalise it.** Source of the retention
periods: `functions/src/privacy/retention.ts` and docs/DECISIONS.md. Keep this
file and `DATA_TYPES` in step.

**Controller:** `<legal name of the operating entity>` (owner action 1).
**DPO:** `<name, PDPC code, email>` (owner action 3).
**Hosting:** Google Cloud / Firebase, `europe-west1` (Belgium); backups in
the same project. **Last reviewed:** 16 Nov 2026.

| # | Activity | Data subjects | Data | Sensitive? | Purpose | Legal basis | Recipients / processors (country) | Retention | Security |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Sign-in and account | Parents | Mobile, email, name, parent ID, sign-in codes (hashed), devices, sign-in history | No | Account, security | Contract; consent (terms, privacy) | Google Firebase (EU); Meta WhatsApp (US/EU) for codes | Account: until deletion. Sign-in list in the app: 180 days, deleted with the account. **Legal sign-in log (`signInLog`, Law 175/2018 Art. 2, R2): uid, keyed phone hash, encrypted number and IP, time, device hash, platform, app version; 180 days from each sign-in, kept after deletion, disclosed only on a judicial order (audited super-admin callable)** | Custom tokens, App Check, rate limits, no phone in logs |
| 2 | Identity check | Parents | National ID images, keyed hash of ID number, expiry, selfies, face reference | **Yes (biometric)** | Verify real parents, child safety, fraud | Explicit consent (`id`, `face`); PDPC sensitive-data licence | Google Cloud Storage (EU, KMS); Valify (Egypt) when contracted | While open; deleted with the account (30-day safety hold only with an open case) | Private bucket, KMS, admin reason log |
| 3 | Children | Children (minors) via the parent | First name, age, grade, school, school ID photo | **Yes (children)** | Organise and protect school runs | Guardian declaration + explicit consent (`childData`); for 15-18 also the child's agreement declared by the guardian (`teenAgreement`, R4); licence | Google (EU) | Until removed / account deleted | Rules: owner and carpool members only (first names) |
| 4 | Carpools and schedule | Parents | Memberships, rules, driving days, swaps, volunteer acknowledgement | No | Organise turns | Contract | Google (EU) | Until deletion; closed carpool 1 year | Server-written only |
| 5 | Live run | Driver, children on the run | Precise car location, stops, times | **Children's location = children's data** | Safety of the run, arrival alerts | Consent (driver location sharing; guardian consent) | Google (EU); Google Routes (global) | Live points 24 h; route archive 90 days after the run (R11; deleted with the driver's account); DPIA: `docs/legal/dpia-live-location.md` | Members of that run only; archive admins only |
| 6 | Home and pickup | Parents | Home pin (exact for owner, rounded ~500 m for others), pickup points | No | Matching, pickups | Consent / contract | Google Maps Places (global) | Until deletion | Rounding; exact points members only |
| 7 | Chat | Parents | Messages, photos, first names | No (may contain anything) | Coordination | Contract | Stream (until replaced; US/EU) or Firestore (EU) | Chat life + 1 year; own messages deleted with the account | Members only; reports, removal |
| 8 | Reports and moderation | Parents | Report text, message copies, decisions | No | Safety, conduct | Legitimate interest / legal duty | Google (EU) | Copies 1 year after handling | Admins only, audit log |
| 9 | Emergency contact and handover adults | Third parties named by the parent | Name, mobile | No | Emergency alert, safe handover | Parent's declaration that the contact agreed + the contact's own confirmation on a link (R6); legitimate interest (child safety, Law 151 Art. 6(4)) until they answer; "stop" ends every message | Meta WhatsApp | Until deleted by the parent | Not shown to others |
| 10 | Notifications | Parents | Push tokens, alert history | No | Alerts | Contract; WhatsApp opt-in | Firebase Messaging / APNs (US); Meta | 60 days | — |
| 11 | Privacy requests | Parents | Request kind, dates, outcome | No | Prove the answer (6 working days) | Legal duty | Google (EU) | 3 years | Admin audit log |
| 12 | Consents | Parents | Type, version, accepted / withdrawn time; for sensitive consents (R3) the signature: method (Face ID / passcode or a fresh sign-in), keyed hash of the typed name, SHA-256 of the text, device key, platform, app version (the typed name itself only on the user record, deleted with the account) | No | Proof of consent | Legal duty | Google (EU) | 3 years after closure (R1, owner 16 Nov 2026; answers 1.6) | Append-only |
| 13 | Analytics (opt-in) | Parents who say yes | Screens, features, app instance ID, coarse IP location | No | Improve the app | Consent | Google Analytics (US/EU) | 60 days (GA setting) | No user ID, no names, no places |
| 14 | Error reports | Parents | Scrubbed errors, opaque account ID | No | Fix faults | Legitimate interest | Sentry (US/EU, check project region) | 90 days | Scrubbers (`functions/src/scrub.ts`, `lib/observability`) |
| 15 | School list | — (public data) | Public school names | No | Search | — | Algolia (US/EU); Vertex AI (EU, names only) | — | No user data sent |
| 16 | Admin audit log | Admins | Actions, reasons, IPs | No | Accountability | Legal duty | Google (EU) | 2 years | Append-only |
| 17 | Breach register | Admins (and, in summary, parents affected) | Incident facts, counts, admin notes (no personal data), notice times | No | Law 151 Art. 7 / Decree Art. 5 register | Legal duty | Google (EU) | 5 years after the incident is closed (R7; `retainUntilMs`) | Admin callables only; rules deny all clients; audit log |
| — | Wallet, Settle up, contributions | — | — | — | **Switched off (no money in the app, 16 Nov 2026)** | — | — | — | — |

**Not processed:** advertising IDs, contacts / address book, financial data,
health data, data of children as users (children do not use the app).

**To complete (DPO):** the processor agreement and the region of each
processor (checklist and status table: `docs/legal/processor-checklist.md`, R10) (Meta, Algolia, Sentry, email provider, Valify); the PDPC licence
numbers; the transfer-impact note per destination country.
