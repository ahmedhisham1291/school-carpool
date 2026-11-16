# Security and privacy

Prompt 12 (spec section 7). Three parts: a checklist against the OWASP Mobile
Application Security Verification Standard (MASVS v2), every outside service
with the data it receives, and the incident plan with the 72-hour breach
report to Egypt's Personal Data Protection Center (PDPC).

Status words: **done** (in the code and tested, or set up by a SETUP.md
step), **open** (not done yet; the reason and the plan are given),
**owner** (needs the owner, the lawyer or a contract).

Security review (16 Nov 2026): the threat model with every finding and
its status is in [docs/security/threat-model.md](docs/security/threat-model.md),
the incident and key-rotation steps in
[docs/security/runbook.md](docs/security/runbook.md), and the console work
only the owner can do in
[docs/security/owner-actions.md](docs/security/owner-actions.md).

Before the pilot, the spec asks for a penetration test of the app, the
rules and the admin panel by an outside tester, using this checklist as the
starting point. That test is **open** (owner: choose and pay a tester).
**R13 (owner decision 16 Nov 2026): then once a year** (PM Decree
1699/2020 Art. 2: IT service providers run annual penetration tests;
answers.md 4.1), and after any big change (new money feature, new
processor of children's data, new admin power). Keep each report and the
fixes with the company records; plan in docs/legal/owner-actions.md.

## 1. MASVS checklist

### MASVS-STORAGE: data stored on the phone

| Item | Status | How |
| --- | --- | --- |
| STORAGE-1 Sensitive data is stored securely | done | Sign-in tokens are kept by Firebase Auth in the iPhone Keychain (Android Keystore). Nothing personal is kept in `shared_preferences` (language, theme, install ID, app-lock switch, analytics choice, queued run confirmations as IDs only). ID photos never touch the photo library (camera plugin, memory only); the temporary camera file is deleted at once. |
| STORAGE-1 Firestore and Stream offline caches | open | Firestore and Stream keep an offline cache (names of children, chats) in the app's sandbox, protected by iOS Data Protection while the phone is locked. Encrypting the caches themselves is not offered by either SDK; the app lock (below) covers the screen. Revisit if the penetration test asks. |
| STORAGE-2 No sensitive data leaks through logs, backups, keyboards, screenshots | done | `debugPrint` lines carry error types only. Document screens block screenshots and screen recording (`screen_protector`). Push notifications carry no child names, addresses or message text, and nothing about money amounts on the lock screen. With the app lock on, the app is covered as soon as it leaves the foreground (no data in the app switcher). |

### MASVS-CRYPTO

| Item | Status | How |
| --- | --- | --- |
| CRYPTO-1 Strong, current cryptography | done | TLS everywhere (Firebase, Stream, Google Maps, Sentry). National ID numbers, sign-in codes, phone numbers in limit records, device IDs and IPs are stored only as HMAC-SHA256 with keys in Secret Manager. |
| CRYPTO-2 Key management | done / owner | Server keys live in Secret Manager (OTP_HMAC_KEY, NATIONAL_ID_HMAC_KEY, STREAM_API_SECRET, WhatsApp, Valify, wallet partner). The private photo bucket is encrypted with our own Cloud KMS key (`tool/setup_kms.sh`, SETUP.md 23.2; the owner runs it per project, code cannot create keys). Key rotation is yearly and automatic. |

### MASVS-AUTH

| Item | Status | How |
| --- | --- | --- |
| AUTH-1 Secure authentication | done | WhatsApp one-time code (6 digits, hash only, 5 minutes, one use, capped per number, device and IP), then a Firebase custom token. App Check replay protection on `requestCode` (limited-use token consumed by the server). Blocking functions refuse every other sign-in method for parents. Admins: email, password and TOTP (an SMS second factor is refused), 8-hour sessions, 15-minute idle limit, a sign-in under 30 minutes old for photos, routes, moderation, admin accounts and feature switches. |
| AUTH-1 Lockout that strangers cannot abuse | done | Wrong codes lock one number on one device for an hour; the daily cap per number (`OTP_MAX_FAILURES_PER_DAY`) never closes a device where the number signed in before (Prompt 12), so rotating device IDs cannot lock the parent out of their own phone. |
| AUTH-2 Session management | done | Every sign-in is recorded (phone kind and time, keyed device hash). The parent sees phones and recent sign-ins and signs any phone out. Signing out revokes the refresh tokens AND writes `users/{uid}.sessionsValidAfter` (the revocation time): Firestore rules (`sessionValid()`) and every gated callable (`device_gate.ts`) refuse an ID token whose sign-in (`auth_time`) is older, so a signed-out phone loses access at once, not when its token expires (up to 1 hour). The asking phone gets a fresh token; a signed-out phone also signs itself out at its next start or resume. Stream tokens already issued stay valid until they expire (chat token callable is gated). |
| AUTH-2 New-phone risk (SIM swap, recycled numbers) | done | A sign-in from a new phone signs the other phones out (as above), emails the parent (mail outbox; SETUP 23.4 for the email extension), pushes "New phone signed in" (reaches the old phone) and sets `users/{uid}.newDeviceCheck`. Until a fresh selfie matches the face reference, the SERVER refuses: Firestore rules (`deviceChecked()`) close children, carpool members, join requests, pickup points, runs, swaps, balances, emergencies, trips with live points and arrival times, handover adults, homes, emergency contacts, notifications and chat records; every callable that reads or changes child, carpool, schedule, trip, location, chat, wallet, family-link or privacy data refuses with `device-check` (export and account deletion included). The face match is the project's KycProvider (Valify in prod) and FAILS CLOSED: an error or no answer keeps everything closed and files a report; an admin clears it with a logged reason (`adminClearDeviceCheck`). If the sign-in record itself fails, a verified parent is treated as on a new phone. Rules and function tests include the SIM-swap case. |
| AUTH-3 Step-up for sensitive actions | done | A fresh Face ID, fingerprint or passcode check before every transfer and withdrawal, and before deleting the account. Optional app lock for the whole app (Settings). |

### MASVS-NETWORK

| Item | Status | How |
| --- | --- | --- |
| NETWORK-1 Secure traffic | done | HTTPS only; App Transport Security on (local networking only for dev builds talking to the emulators). |
| NETWORK-2 Certificate pinning | open | Not done: Firebase and Stream rotate certificates, and pinning in a Flutter app breaks with every rotation. App Check proves the app instead. Revisit with the penetration tester. |

### MASVS-PLATFORM

| Item | Status | How |
| --- | --- | --- |
| PLATFORM-1 Safe use of IPC | done | Universal links only for `https://<links site>/c/<code>` invite links, which open a screen that checks the code on the server. |
| PLATFORM-2 Safe WebViews | done | No WebView in the app. The data export opens in the system browser through a 1-hour signed link. |
| PLATFORM-3 Safe user interface | done | Document screens block screenshots; the app lock covers the app in the switcher; confirmation before anything that cannot be undone. |

### MASVS-CODE

| Item | Status | How |
| --- | --- | --- |
| CODE-1 Up-to-date platform | done | iOS 15+; Flutter stable pinned in CI. |
| CODE-2 Update mechanism | open | No forced-update screen yet. The server refuses outdated consent versions, so old builds are told to update at sign-up. A minimum-version check comes with the first TestFlight release (Prompt 13). |
| CODE-3 No known vulnerable dependencies | done / owner | Lockfiles are committed from CI; `npm audit` of the functions' production packages runs in CI (report only) and `.github/dependabot.yml` covers npm, pub and Actions (security review). Owner: switch on Dependabot alerts and security updates in GitHub. |
| CODE-4 Input validated | done | Every callable validates its input on the server (types, lengths, patterns); Firestore and Storage rules deny by default with emulator tests for every collection and path. |

### MASVS-RESILIENCE

| Item | Status | How |
| --- | --- | --- |
| RESILIENCE-1 Platform integrity | done | App Check (App Attest with DeviceCheck fallback on iPhone, Play Integrity on Android) is enforced on Functions, Firestore and Storage in staging and prod. |
| RESILIENCE-2/3/4 Anti-tampering, anti-static analysis, anti-dynamic analysis | open | Not planned for the pilot (no obfuscation beyond release builds); every decision is made on the server, so a modified app gains nothing it could not get through the API with App Check. |

### MASVS-PRIVACY

| Item | Status | How |
| --- | --- | --- |
| PRIVACY-1 Minimised data | done | Other parents see first names, the school, an area of about 500 m and the Verified badge; exact pickup points only inside a carpool. Rounded coordinates on the server. Analytics have no user ID and no advertising identifiers (Info.plist keys off). |
| PRIVACY-2 No re-identification | done | Logs, Sentry and Algolia never receive phone numbers, ID numbers, coordinates, images or message text (scrubbers in the app and functions, with tests). Analytics accept only fixed event names and short fixed words (tests prove it). |
| PRIVACY-3 Transparency | done / owner | Privacy screen: every data type with what it holds, who sees it and how long it is kept; the privacy policy and consents changed version for the new retention (2026-11-14). The lawyer confirmed the data types and periods (DECISIONS.md, 14 Nov 2026); transfer records are kept 5 years (owner answer, 14 Nov 2026 13:29). |
| PRIVACY-4 User control | done | See, correct (screens, and ID details through an admin), download (one JSON file, including chat and the wallet history), delete the account, withdraw each consent; every request is logged in `privacyRequests` (3 years). |

### Server and admin panel

| Item | Status | How |
| --- | --- | --- |
| Rules deny by default | done | `firestore.rules`, `storage.rules`; emulator tests in `tests/rules` (Prompt 12 adds `privacy.test.ts`). |
| Admin access to photos and routes | done | Only through callables that need a fixed reason code and write the audit log first (`openVerificationCase` for decided cases, `adminOpenUserPhotos`, `adminOpenRouteArchive`); thumbnails by default, 5-minute links, reviewer watermark in the panel. |
| Scraping alerts | done | Opening many profiles, sending many chat requests, searching many areas or looking up many parent IDs in an hour raises a security alert for admins (`securityAlerts`). The admin panel screen for these alerts is open (the callables exist). |
| Retention enforced | done | `retentionDaily` (one job for every data type not deleted at once or by TTL), TTL policies and Cloud Storage lifecycle rules; failures are reported to Sentry and as a security alert. |
| Budget and quotas | done | Budget alerts, Maps quotas, `maxInstances` 10 on every function (COSTS.md). |

## 2. Outside services and the data they receive

| Service | Where | What it receives | What it never receives |
| --- | --- | --- | --- |
| Google Cloud / Firebase (Auth, Firestore, Storage, Functions, Messaging, App Check, Hosting) | europe-west1 (Belgium) | Everything the app stores (spec section 9); photos encrypted with our KMS key | n/a (our own processor) |
| Google Analytics for Firebase | Google (US/EU) | Screen route patterns ("carpools/:id/trip/:id"), fixed event names and small fixed words; app instance ID; no user ID, no advertising ID | Names, phone numbers, IDs, message text, coordinates |
| Stream Chat | Stream's chosen region (EU if available; hosting abroad confirmed by the lawyer) | Chat messages and photos, first names, parent IDs, language | Phone numbers, national IDs, children's details outside messages |
| Algolia | Algolia (EU region if available) | School names, areas and places | Anything about parents or children |
| Sentry | sentry.io (EU region if chosen) | Error reports with phone numbers, ID numbers, coordinates and message text removed; opaque account ID; feature area tag | Personal data (scrubbed in the app and functions) |
| WhatsApp Business Platform (Meta) | Meta | Phone numbers, sign-in codes, alert template texts (no child names or amounts) | Message text, photos |
| Google Maps Platform (Maps, Places, Routes) | Google | Map views, address searches typed by the parent, stop points of live runs for arrival times | Who the parent is |
| Valify (ID check, when contracted) | Valify | ID images and selfies for the check | n/a |
| Wallet partner (CBE-licensed, when contracted) | Partner | Wallet holder reference, amounts and transfer parties | Children's data, chats |
| Email (Trigger Email extension with an SMTP provider, when set up) | Provider chosen by the owner | The parent's confirmed email and the new-phone alert text | Phone numbers |
| Apple Push Notification service (through Firebase Cloud Messaging) | Apple / Google | Push tokens and short alert texts (STORAGE-2: no child names, addresses, message text or amounts) | Phone numbers, coordinates, message text |
| Codemagic, GitHub | US | Source code and build logs (fake data only) | Production data |

## 3. Incident plan

### Who does what

| Role | Person | Duty |
| --- | --- | --- |
| Incident lead (decides) | The owner | Declares an incident, decides containment, approves every message |
| Data protection officer | To be named and registered (Law 151 Executive Regulations) | Files the 72-hour report with the PDPC, keeps the incident record |
| Technical lead | The developer on duty | Investigates, contains, collects evidence, restores |
| Communications | The owner or a named deputy | Tells affected parents (WhatsApp template, email, in-app notice) |
| Lawyer | The owner's lawyer | Checks the report and the notices |

### Steps

1. **Detect** (any source: Sentry alert, security alert, retention failure,
   a parent's report, a vendor notice). Write down the time.
2. **Declare** within 1 hour: the incident lead opens an incident record
   (date, what is known, data types possibly affected, people possibly
   affected) in the private incident folder.
3. **Contain** at once:
   - suspend the affected accounts (admin panel), revoke sessions
     (`revokeRefreshTokens`, Stream `revokeTokens`), freeze wallets if money
     is at risk;
   - rotate exposed secrets in Secret Manager and redeploy;
   - if a key or a rule is the cause: deploy the fixed rules, disable the
     function (`firebase functions:delete` or set its param off);
   - preserve evidence: export the audit log, Cloud Logging and Sentry
     events for the window.
4. **Assess** within 24 hours: which data types (privacy screen list),
   how many parents and children, which outside services.
5. **Legal clock: follow [docs/legal/breach-runbook.md](docs/legal/breach-runbook.md)**
   (the legal timeline lives there, not here). In short: record the
   incident in the admin panel > Incidents at once (starts the clock); the
   DPO notifies the PDPC within 72 hours of awareness (immediately for
   national security, children's or face data); every affected parent is
   told within 3 working days of the PDPC notice (no "low risk" exception
   in Egyptian law); a crime is reported to the authorities (Law 175/2018
   Art. 35) and the evidence is preserved.
6. **Parents' notice:** templates in the legal runbook (Arabic and English).
7. **Recover**: restore from backup or PITR if data was damaged
   (`docs/restore-test.md`), check the retention job and rules, and confirm
   with the outside services involved.
8. **Review** within 2 weeks: cause, timeline, what to change; update this
   file and the tests.

### Contacts to keep current (owner)

PDPC filing channel, the lawyer, Google Cloud support, Stream, Sentry, Meta
(WhatsApp), Valify and the wallet partner security contacts.
