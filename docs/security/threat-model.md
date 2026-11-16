# Threat model

Security review of 16 Nov 2026 (branch `security`). Scope: the iPhone app,
the admin panel (Flutter web on Firebase Hosting), the links site, Cloud
Functions, Firestore and Storage rules, the cloud setup script, CI/CD and
the public repository. Method: STRIDE per entry point, plus abuse cases by
actor. It extends SECURITY.md (MASVS checklist, outside services, incident
plan); the incident steps are in [runbook.md](runbook.md) and the console
work only the owner can do is in [owner-actions.md](owner-actions.md).

Status words: **fixed** (changed on this branch, with tests), **done**
(was already in place; checked in this review), **open** (not done; plan
given), **owner** (console or account work, see owner-actions.md),
**accepted** (a known risk we keep, with the reason).

## 1. Assets

| Asset | Where | Worst case if lost |
| --- | --- | --- |
| Children's first names, grades, schools, which car they ride in and when | `children`, `carpools/*/members`, `schedule`, `trips` | A stranger learns where a named child is at a given time |
| Live location of a driver with children | `trips/{id}` (`last`), `trips/*/points` (12 h TTL), `eta` | Real-time tracking of a car full of children |
| Exact home pins and pickup points | `homes`, `carpools/*/pickupPoints`, `tripStops` | Home address of a family with children |
| National ID numbers, ID / selfie / licence / school-ID images, face references | `nationalIds` (HMAC only), private KMS bucket (`verification/`, `faceRefs/`, `selfieArchive/`, `driverPhotos/`) | Identity theft; images of children's school IDs |
| Phone numbers, emails, emergency contacts, handover adults | Auth, `users`, `emergencyContacts`, `handoverAdults` | Harassment, SIM-swap targeting |
| Chat messages | Stream (main) / Firestore (chat-review-safe) | Private family conversations |
| Admin powers | `admin`/`superAdmin` claims, `admins/{uid}`, admin callables | Everything above, plus banning parents and turning features on |
| Money features (wallet, Settle up) | Code present, **off** (owner decision 16 Nov 2026) | Fraud once on; today: nothing, if they stay off |
| Secrets | Secret Manager (OTP/NID HMAC keys, WhatsApp, Stream, Algolia, Maps server key) | Forged sign-ins (OTP key), de-hashing national IDs, paid-API abuse |
| Audit log | `auditLog` (Firestore) | Hiding an insider's tracks |
| Build and release chain | GitHub (public), GitHub Actions, Codemagic, App Store Connect | A backdoored app on every parent's phone |

## 2. Actors

| Actor | Capabilities | Main goals |
| --- | --- | --- |
| Curious parent | Verified account, member of one carpool | See more than they should (other families, exact homes) |
| Malicious parent / predator posing as a parent | Passes the ID check with their own or a stolen ID; joins carpools; chats | Locate and approach children; learn routines; groom through chat |
| Stolen phone (unlocked or with a live session) | The app signed in | Read the family's data; follow a live run |
| SIM swap / WhatsApp takeover | Receives the parent's WhatsApp codes | Sign in as the parent on a new phone |
| Compromised admin | Admin password + TOTP (phished) or a hijacked browser session | Bulk-read IDs and photos; ban parents; turn features on |
| Insider (developer, owner's helper) | Console / Admin SDK / CI access | Quiet reads of everything; edit the audit log |
| Scraper / bot | Many accounts, scripts against the API | Harvest parents, schools, homes; burn WhatsApp and Maps budget |
| Anyone with the repo (public) | Reads all code, history, CI config | Find secrets, logic bugs, CI weaknesses |

## 3. Entry points and STRIDE

### 3.1 Callables (about 150) and the two HTTP functions

| Threat | Control | Status |
| --- | --- | --- |
| S: calls without the app | App Check enforced on every callable (`ENFORCE_APP_CHECK`, true in every `.env`); `requestCode` consumes limited-use tokens (replay) | done |
| S: forged identity | Firebase ID tokens; parents only via custom token after a WhatsApp code; blocking functions refuse password/email-link/SMS/anonymous for parents and refuse client sign-ups | done |
| T/E: client writes protected fields | Rules let the app write only `users.language` and `notifications.readAt`; everything else is Cloud Functions | done (abuse tests: `tests/rules/security_review.test.ts`) |
| E: IDOR on child, trip, carpool, address, chat | Each flow checks the caller against the resource (`child.ownerUid`, approved membership, `viewerUids`, carpool admin role); sampled `getHandoverAdults`, `decideJoinRequest`, `getTrustSummary`, `uploadPoints`, `reportTrackingLost`, admin user/photo lookups | done (sampled; full per-callable review: open, recommended for the external pen test) |
| E: suspended or banned parent keeps reading | Suspension and verification bans only revoked refresh tokens: the current ID token (with `verified`) kept rules access to live runs, members, exact pickup points and children for up to an hour. Now `sessionsValidAfter` is written too, and the rules refuse suspended or banned records | **fixed** (`2473f3e`) |
| E: SIM-swap session gets child data | New phone -> other phones signed out (`sessionsValidAfter`), `newDeviceCheck` closes child/carpool/trip/chat data in rules and callables until a fresh selfie matches | done |
| I: error messages leak data | Errors carry a fixed `details.reason`; unexpected errors become `internal`; logs carry error types only | done |
| D: abuse of paid APIs (WhatsApp codes, Places, Routes) | Per-number, per-device, per-IP caps; App Check replay protection; Maps quotas; `maxInstances` 10; budget alert | done; no global WhatsApp circuit breaker: **open** (owner: Meta spending limit, see owner-actions) |
| D: regex backtracking in the scrubbers | Long text cut to 4,000 characters before scrubbing (50,000 digits took 6 s) | **fixed** (`ed50cfd`) |
| T: SSRF | Every outbound URL is a fixed Google/Meta/Stream/Algolia host; user values only `encodeURIComponent`-ed into the path | done (no user-controlled URL anywhere) |
| T: injection in Algolia | The app gets a secured key restricted to the schools index, 1 hour, user token; no filter string is built from input on the server | done |
| T: prototype pollution | Inputs are read field by field (`record(data).x`), never merged into objects; no deep-merge helper | done |
| S: `chatWebhook` | HMAC-SHA256 `X-Signature` checked with `timingSafeEqual` before parsing; event ID = message ID (idempotent) | done (goes away with chat-review-safe) |
| S: `tripLocation` (no App Check: native uploader) | 256-bit per-trip bearer token stored as a hash, dies when tracking stops; account re-checked once a minute; 410 after the run | accepted (design) |
| S/T: `emergencyContactReply` (`/ec/<token>`, no App Check: the contact is not an app user) | 256-bit single-purpose token per contact (new number = new token, deleted with the contact); GET only shows the page, only a POST from its buttons confirms or stops (previews, scanners, prefetch cannot answer); per-address and per-instance limit in memory, `maxInstances` 5; page shows only the parent's first name; CSP `form-action 'self'`, no framing, no referrer | accepted (design, R6 review) |
| E: fake providers in a real project | Fakes refuse `prod`; **a missing `APP_ENV` was treated as dev** (fake ID check would auto-approve). Now a cloud project without `APP_ENV` counts as prod | **fixed** (`4b03447`) |
| E: money features turned on by accident | All wallet and Settle up callables are gated (`featureGatedCall`) and refuse with `feature-off`; **Settle up defaulted to on** when `config/features` was missing. Now every money feature defaults off; only a super admin (step-up, audit log) turns one on | **fixed** (`dd4cb88`) |
| R: who did what | Audit log for admin actions, review sign-ins, phone changes, feature switches | done; immutability against the Admin SDK: **owner** (Data Access audit logs + locked log bucket) |
| CORS on HTTP functions | Callables use the Firebase protocol; the two `onRequest` functions are called by Stream and the native uploader only (no browser); no CORS headers are sent, so browsers cannot read responses cross-origin | done |

### 3.2 Sign-in (WhatsApp code)

| Threat | Control | Status |
| --- | --- | --- |
| Brute force | 6 digits (`crypto.randomInt`), HMAC-stored, 5 minutes, single use, 5 tries per code, 5 codes per number per hour, 10 wrong codes lock number+device for 1 h, 30 wrong codes a day close the number (except on known devices). Worst case about 30 guesses a day per number (3 in 100,000) | done |
| Stranger locks the parent out | Daily cap skips known devices (Prompt 12). **The hourly send cap and 60 s cooldown were per number**, so a stranger could spend them and block the parent's own phone. Now counted per number+device on a known device | **fixed** (`17c60df`) |
| Stranger replaces the parent's pending code | A stranger's request replaces the stored code (the new code is sent to the parent's WhatsApp, so the parent can still use the latest) | accepted (low; per-device codes would remove it) |
| Enumeration | `requestCode` answers the same for new and existing numbers; accounts are created only after a correct code | done |
| Replay | Codes single use; App Check limited-use token on `requestCode` | done |
| SIM swap / WhatsApp takeover | See 3.1 (new-phone check with face match, fails closed; email + push to the old phone) | done |
| Custom-token claims | `createCustomToken(uid)` with no developer claims; `verified`/`admin` set only by functions/scripts | done |
| Session revocation | Phone sign-out, new phone, suspension and account deletion revoke refresh tokens and set `sessionsValidAfter` (checked in rules and callables) | done; a phone-number change does not sign the other phones out: **open** (low) |
| Demo reviewer access as a backdoor | Off by default; HMAC-hashed phone and code in `config/reviewAccess` (closed); at most 30 days; at most 2 phones; demo accounts permanently marked and confined to the demo school; every sign-in audited; all limits apply | done (validated in docs/reviews/apple-review.md) |

### 3.3 Firestore and Storage rules

| Threat | Control | Status |
| --- | --- | --- |
| Default open path | Final `match /{document=**}` denies; every collection has an explicit rule and a test | done (every collection named in `firestore.rules` appears in `tests/rules`) |
| Collection-group leaks | No `{path=**}` rule exists, so collection-group queries on any subcollection are refused | done; abuse tests added (`3320392`) |
| Exact location / phone / ID exposure | `homes`, `pickupPoints` (approved members of that carpool only), `tripStops`, `parentLocations`, `nationalIds`, `verifications`: closed or owner-only; others get rounded points through `searchNearbyParents` | done |
| Live location history | Points readable only while `status == 'active'`; deleted within 12-24 h; `last` cleared when tracking stops | done |
| List sweeps | List rules require the query to be constrained to the caller (`ownerUid`, `uid`, `viewerUids`, `parties`) and cap `limit` on shared collections | done |
| Size and type of uploads | Fixed names, JPEG only, under 3 MB, own folder; no client reads at all | done |
| Write rate | The app writes nothing but `language` and `readAt` (once); uploads are bounded by fixed names | done |
| Admin second factor | `isAdmin()` required any second factor; **SMS would have counted** | **fixed**: TOTP only (`4822636`) |

### 3.4 Admin panel

| Threat | Control | Status |
| --- | --- | --- |
| Password-only admin | Admin callables and rules require the TOTP factor (now TOTP only), 8-hour session, 15-minute idle (server and panel), record not disabled/revoked | done / **fixed** (TOTP only) |
| Hijacked long session | **Step-up**: photos, route archives, clearing a new-phone check, moderation, admin accounts and feature switches need a sign-in < 30 minutes old (`reauth-required`) | **fixed** (`4822636`) |
| Role separation | Admin accounts and feature switches: super admin only (claim + step-up) | done |
| Over-broad data views | Photos and routes only through callables with a fixed reason code, logged first; thumbnails by default; 5-minute signed links; watermark | done |
| Password reset abuse | `blockSignInEmails` refuses password-reset and email-link emails except the admin script's 2-minute one-time link | done |
| Clickjacking, XSS, sniffing | `frame-ancestors 'none'`, X-Frame-Options, nosniff, no-referrer; now also HSTS, COOP, wider Permissions-Policy, `base-uri`/`object-src`/`form-action`; full CSP in report-only first | **fixed** (`d509d8d`); enforcing the full CSP: **owner** (check console on staging) |
| Bots against the panel | App Check with reCAPTCHA Enterprise on web; without the site key the panel's calls are refused (fails closed) | done |
| Secrets in the web build | Only public identifiers (Firebase web config, reCAPTCHA site key, Sentry DSN) | done |
| Brute force of admin passwords | Identity Platform lockout + TOTP | done; password policy: **owner** |

### 3.5 Hosting, deep links, push

| Threat | Control | Status |
| --- | --- | --- |
| Invite links | `/c/<code>` opens a screen that checks the code on the server; opens are rate limited (20 an hour); codes are random | done |
| Universal-link hijack | apple-app-site-association served from our links site only | done |
| Push contents | No child names, addresses, message text or amounts on the lock screen | done |

### 3.6 CI/CD and the public repository

| Threat | Control | Status |
| --- | --- | --- |
| Secrets in the repo or history | Scanned all 572 commits (Google, GitHub, Slack, AWS, Stripe, Meta, Sentry DSN, private-key patterns): only the Firebase web API keys of staging (public identifiers by design) | done; restrict those keys: **owner** |
| Untrusted PR code with a write token | No `pull_request_target`/`workflow_run`; read-only default token; only the manual lock job can push, never to main | done; test added (`9572fed`) |
| Moved action tags | Every action pinned to a 40-character SHA | done; test added |
| Token readable by install scripts | `persist-credentials: false` on every checkout except the lock job | **fixed** (`9572fed`) |
| Vulnerable dependencies | Lock files committed; `npm audit` in CI (report); Dependabot config | **fixed**; Dependabot alerts/security updates on: **owner** |
| Unpinned CLI | `npx firebase-tools@15` (major only) | open (low; pin a full version when the lock job next runs) |
| Codemagic | iOS builds by hand or on a tag; secrets in environment groups | done; 2-step on Codemagic and Apple: **owner** |
| Branch protection, secret scanning, push protection | GitHub settings | **owner** |

### 3.7 Cloud setup and operations

| Threat | Control | Status |
| --- | --- | --- |
| Functions' service account too strong | Runs as the default compute account; **Token Creator was granted project-wide** (could mint tokens for any service account) | **fixed**: on itself only (`92e70c6`); a dedicated least-privilege runtime account instead of the default (which may hold Editor): **open** (high, plan in owner-actions) |
| Public buckets | No public access; Storage rules deny reads; CORS only for the admin site, GET | done; public access prevention on the buckets: **owner** |
| App Check on Firestore and Storage | Registered by the script; enforcement is a console switch | **owner** (CLAUDE.md requires it in staging and prod) |
| Budget runaway | Budget alert USD 20 (5/25/100 %), `maxInstances` 10, Maps quotas | done |
| Monitoring of security events | Sentry for errors; `securityAlerts` for scraping and retention failures | log-based alerts for admin sign-ins, rule-denial spikes, mass reads and WhatsApp volume: **owner** |
| Backups | Daily backup and PITR in prod | done / **owner** (switch on per project) |
| Dev emulators bound to 0.0.0.0 | Needed for the iPhone to reach them on the LAN; fake data only | accepted |

### 3.8 Mobile app

| Item | Status |
| --- | --- |
| Tokens in the Keychain (Firebase Auth); nothing personal in shared_preferences | done |
| Sentry: `sendDefaultPii` off, no screenshots or view hierarchy, `beforeSend` scrubber | done (scrubber length cap **fixed**) |
| Screenshot/recording blocked on ID screens; app-lock cover in the switcher | done |
| ATS on; no WebView; deep links validated on the server | done |
| Clipboard: only parent ID, invite link and public text are copyable | done |
| Jailbreak/root detection, certificate pinning, obfuscation | accepted (every decision is on the server; App Attest proves the app) |
| Pilot default of Settle up in the app (`FeatureSwitches.pilot`) still on when `config/features` is missing | open (UI only, the server refuses); owner: set the switch off once so the document exists |

## 4. Abuse cases

1. **Predator posing as a parent** joins a carpool to learn a child's
   route. Controls: ID check + face match, national-ID ban list, carpool
   admin approves each member, exact pickup points only to approved
   members, live location only to parents of children on that run and only
   while it runs, chat requests limited and blockable, reports go to
   admins, scraping alerts. Residual: an approved member does see the
   carpool's children's first names and the run's live position; that is
   the feature. Carpool admins must know whom they approve. Once an admin
   suspends them, access ends at once (**fixed**: it used to last up to an
   hour).
2. **Stolen unlocked phone**: optional app lock (biometric); the parent
   signs the phone out from another phone (revocation applies at once in
   rules and callables). Residual: without the app lock, until signed out.
3. **SIM swap**: new phone -> old phones out, email + push, child data
   closed until a selfie matches the face reference (fails closed).
4. **Stranger blocks a parent's sign-in** by requesting codes for their
   number: **fixed** for the parent's own phone.
5. **Phished admin password + TOTP**: 15-minute idle, 8-hour session,
   step-up for photos/routes/moderation/roles/switches, reason-coded
   audit trail, scraping-style rate limits on user search. Residual: within
   30 minutes of a phished sign-in the attacker can open photos one parent
   at a time (logged). Alert on admin sign-ins (owner-actions).
6. **Insider with console access**: can read everything with the Admin
   SDK. Controls: few owners, 2-step on Google accounts, Data Access audit
   logs to a locked bucket (owner-actions), KMS key for photos (its use is
   logged).
7. **Scraper with many accounts**: each account needs a WhatsApp number
   and App Check; searches are rate limited per account; map points are
   rounded and offset; security alerts on bulk views.
8. **Turning money on**: only a super admin, after a fresh sign-in, with
   an audit entry; every money callable refuses while off; defaults off.
9. **Malicious pull request** to the public repo: no workflow runs on PRs
   (push to main and manual only), no secrets in Actions, Codemagic builds
   by hand.

## 5. What this review did not cover

- Every one of the ~150 callables line by line (sampled the highest-risk
  ones above); the external penetration test in SECURITY.md stays open,
  and from then on it repeats **every year** (R13, Decree 1699/2020 Art. 2).
- The Firestore chat on branch chat-review-safe (reviewed there).
- Running the rules tests and Flutter tests (no emulator or Flutter SDK in
  this workspace; CI runs them).
