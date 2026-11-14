# Workstream E: locked package versions, Meta WhatsApp guide, private-repo plan

Branch `improve-e-docs` (from main, 14 Nov 2026). Decision: docs/DECISIONS.md
"Improvements, revised", items 2 and 7. The coordinator said "go".

## Plan

| # | Task | Files |
| --- | --- | --- |
| 1 | Lock package versions: a manual-only CI job writes the lock files; every other install uses them when they exist | `.github/workflows/checks.yml`, `tool/bootstrap.sh`, `codemagic.yaml`, `docs/WORKFLOW.md`, `README.md`, `SETUP.md` 3.10 and 7 |
| 2 | Owner guide for Meta business verification and WhatsApp | `docs/meta-whatsapp-setup.md` (new), links from `SETUP.md` 11.5 and 18.4, `docs/open-items.md` A4 |
| 3 | Going private before launch: prices, minutes per run, checklist | `docs/launch-private-repo.md` (new), links from `docs/open-items.md` and `docs/COSTS.md` |
| 4 | Deploy warning "ENFORCE_APP_CHECK.value() invoked during function deployment": fix only if clean | `functions/src` (read only unless a clean fix exists) |

No data model change, no new screen, no new dependency, no new paid service.

## Open questions at the start

1. Which lock files: `pubspec.lock`, `packages/run_recovery/pubspec.lock`
   (our local plugin gets its own `pub get` in bootstrap),
   `functions/package-lock.json`, `tests/rules/package-lock.json` (CI
   installs all four).
2. Codemagic builds with `flutter: stable` (whatever is newest) while CI pins
   3.50.0. A lock file made on 3.50.0 can be refused by a newer Flutter (the
   SDK pins some packages itself), so Codemagic needs the same pin.
3. The code has two WhatsApp templates that SETUP.md does not list
   (`cp_child_not_coming`, `cp_new_device`), and open-items A4 names the code
   template `cp_code` while the code uses `login_code`.

## What was built (14 Nov 2026)

### Task 1: locked package versions
- `.github/workflows/checks.yml`: new manual-only job **locks**
  (`workflow_dispatch` inputs `update_locks` and `upgrade_packages`, both
  default false; `permissions: contents: write` on that job only). It
  refuses `main` and tags, runs `flutter pub get` at the root and in
  `packages/run_recovery`, `npm install --package-lock-only` in `functions`
  and `tests/rules`, commits the four lock files to the dispatched branch
  as `github-actions[bot]` and pushes. With `upgrade_packages=true` it
  deletes the lock files first (newest versions the manifests allow).
  The three existing jobs carry `if: !inputs.update_locks`, so a lock run
  runs nothing else; on a push the input is empty and they run as before.
- Normal jobs: `npm ci` when a `package-lock.json` exists, else
  `npm install` with a warning. The Gradle cache key now includes
  `pubspec.lock`; the npm cache key already hashed `package*.json`.
- `tool/bootstrap.sh`: `flutter pub get --enforce-lockfile` when
  `pubspec.lock` is tracked by git (root and `packages/run_recovery`),
  plus a check that the tracked lock was not rewritten (`flutter create`
  runs its own pub get first and must keep doing so: it writes the Podfile
  that `patch_native.py` patches). Plain `pub get` with a warning until
  the first lock commit, or with `UPDATE_LOCK=1`.
- `codemagic.yaml`: `flutter: 3.50.0` instead of `stable`, equal to
  `FLUTTER_VERSION` in checks.yml. **Reason:** the Flutter SDK pins some
  packages itself, so a lock made with 3.50.0 would be refused by a newer
  "stable" on Codemagic and the iPhone build would stop. Both numbers must
  now change together (comment in both files, docs/WORKFLOW.md).
- `tool/cloud_setup.sh` already used `npm ci` when the lock exists
  (verified, unchanged); its admin-panel build goes through bootstrap.sh
  with the CI Flutter version, so it gets the Dart lock too.
- `.gitignore` does not ignore any lock file (verified, unchanged).
- Docs: `docs/WORKFLOW.md` "Package versions (locked)", README, SETUP 3.10
  and 7, open-items D16.

Validation: YAML of checks.yml and codemagic.yaml parsed with PyYAML;
`bash -n tool/bootstrap.sh`; `python3 -m unittest discover -s tool` (9
tests pass). **The locks job and the enforce-lockfile path are written,
not run here** (no Flutter, no registry, and workflows are started only by
the coordinator).

Command for the coordinator (after pushing this branch):

    gh workflow run checks.yml --ref improve-e-docs -f update_locks=true

then `git pull`, review the four lock files, and one check run:

    gh workflow run checks.yml --ref improve-e-docs -f full=true

(`full=true` on purpose: the Android and web builds are where a lock
problem would show.)

### Task 2: docs/meta-whatsapp-setup.md
Owner guide: do-this-first box, portfolio, business verification, app,
number and display name, payment method, `login_code`, alert templates,
system-user token, where each value goes, limits, Egypt prices, what could
not be confirmed, sources with the date. The template tables are generated
from `functions/src/notifications/catalog.ts` and `texts.ts` and checked
against SETUP.md 18.4, 20.3, 22.3, 23.4.

Findings while doing it:
- `cp_child_not_coming` is in the code (group tripAlerts, WhatsApp on by
  default) but was missing from SETUP.md 20.3: added there and to the guide.
- docs/open-items.md A4 called the code template `cp_code`; the code and
  `.env` files use `login_code`: corrected.
- Three wallet templates (`cp_wallet_received`, `cp_wallet_failed`,
  `cp_wallet_updated`) have English bodies in SETUP.md 18.4 that differ
  from texts.ts, and no Arabic template wording. Not changed (wallet is
  off for the pilot); the guide tells the owner not to create wallet
  templates yet. **Open item for whoever turns the wallet on.**
- `cp_emergency_contact` starts (English) and ends (both languages) with a
  variable; Meta's review page lists "cannot start or end with a
  parameter" as a rejection reason. It also goes to a person who never
  opted in to our messages, while Meta requires opt-in before templates.
  **Open question for the owner/lawyer and the developer**; not changed.
- Pricing facts that affect COSTS.md: per delivered message; utility
  templates are charged even inside the 24-hour window since 1 Oct 2026.
  Egypt rates (USD 0.0036 authentication and utility, 0.0644 marketing)
  come from third-party copies of Meta's rate card, **not confirmed on
  Meta's own file** (the CSV/PDF could not be opened here).
- Meta's Business Help Centre pages (verification steps, documents,
  display name) refuse automated reading; those parts are marked as
  unconfirmed in the guide.

### Task 3: docs/launch-private-repo.md
Prices read on GitHub's pages (Free 2,000 minutes, Linux 2-core USD 0.006
a minute, budgets with "Stop usage when budget limit is reached"), minutes
per run measured from this repository's runs of 14 Nov (main: 14 to 18
billed minutes; branch: about 6), the choices, what else changes (branch
protection, Cloud Shell clone, Codemagic access), checklist and switch
steps. Linked from open-items (new A16) and COSTS.md.

### Task 4: "params.ENFORCE_APP_CHECK.value() invoked during function deployment"
**Left as it is; there is no clean fix on our side.** Our code already does
what the warning recommends: every callable passes the param itself
(`{ enforceAppCheck: ENFORCE_APP_CHECK }`), never `.value()`, at module
load. The call comes from inside firebase-functions: `onCall` in
`src/v2/providers/https.ts` does

    let enforceAppCheck = opts.enforceAppCheck ?? options.getGlobalOptions().enforceAppCheck;
    if (enforceAppCheck instanceof Expression) { enforceAppCheck = enforceAppCheck.value(); }

(read in the library's repository, master of 6 Nov 2026), because App
Check enforcement is decided inside the request handler the library builds
when the module loads, not in the deployed function's settings. So the
library resolves the param at load time and prints its own warning during
deploy. At runtime the module loads with the `.env.<alias>` values, so
enforcement is right; the warning is noise.
Ways to silence it, all rejected: a plain boolean from `process.env`
(bypasses the params system: no deploy-time check that the value is set),
or checking `request.app` ourselves in every handler (duplicates library
security code in every callable and changes how invalid tokens are
answered). Revisit when firebase-functions changes this. No functions
code was touched, so the functions tests were not re-run.

### Also
- docs/COSTS.md: WhatsApp and GitHub Actions rows, sign-in paragraph.
- Stream: every remaining "Stream" text (COSTS.md chat rows, open-items
  A8, C1, D11, SETUP 19) belongs to the chat rewrite on branch B and is
  still true on `main`; nothing changed.

## Not done / for others
- The lock files themselves (coordinator runs the job).
- `docs/owner-cloud-shell.md` and `tool/cloud_setup.sh` clone instructions
  must change on the day the repository goes private (launch-private-repo.md
  section 5).
- AGENTS.md / CLAUDE.md still say "Flutter, stable channel" (true: 3.50.0
  is on stable) and "compiled/tested on Codemagic"; not edited (rules
  files are the owner's).

## What the owner does
1. Today: docs/meta-whatsapp-setup.md, the box at the top (portfolio,
   documents, Start verification).
2. Nothing for the lock files (coordinator).
3. Before public launch: docs/launch-private-repo.md sections 6 and 7.
4. Two answers wanted: the lawyer on WhatsApp to the emergency contact
   without that person's own opt-in; and whether to accept Codemagic
   building with a fixed Flutter version (needed for locked versions).

No new screen in this workstream, so no screenshots and no iPhone test
steps.
