# Review: workstream E (locked package versions, Meta WhatsApp guide, private-repo plan)

Branch `improve-e-docs`, diff `main...HEAD`, reviewed 14 Nov 2026 at head
`3da9ad1` plus two reviewer doc commits (`d618d74`, `1da1ff3`).
Independent reviewer; nothing pushed, no workflow started.

## Verdict: PASS

No blockers. Seven non-blocking findings below; finding 1 is worth a small
follow-up soon.

## What was checked, and how

| # | Area | Result | How |
| --- | --- | --- | --- |
| 1 | `.github/workflows/checks.yml`, `locks` job | OK | Read the file. `contents: write` is on that job only (top level stays `contents: read`, `actions: write` as on `main`). Job condition is `workflow_dispatch` and `update_locks`; first step refuses `main` and tags. The only inputs are booleans, used in `if:` or passed through `env`; branch name goes through `env` and is quoted. No `${{ }}` of free text inside a `run:` block. `workflow_dispatch` needs write access to the repository, so no untrusted trigger. `flutter pub get` and `npm install --package-lock-only` run no package scripts while the write token is present |
| 2 | Normal jobs install the locked versions | OK | Logs of run 43611761567 (read with `gh run view --log`): both Flutter jobs print "locked versions (pubspec.lock)" for the root and `packages/run_recovery`; the backend job runs `npm ci` for `functions` and `tests/rules`. All three jobs green |
| 3 | `tool/bootstrap.sh` | OK | Restores the committed lock (`git checkout -- pubspec.lock`), runs `flutter pub get --enforce-lockfile`, then fails if `git diff` shows a change. `set -e` reaches the function and the subshell |
| 4 | Cache keys | OK | Gradle key hashes `pubspec.yaml`, `pubspec.lock`, `tool/patch_native.py`; npm key hashes `package*.json` (covers the lock files) |
| 5 | `codemagic.yaml` | OK | `flutter: 3.50.0`, equal to `FLUTTER_VERSION`; both iOS workflows go through `tool/bootstrap.sh`, so they use the lock. Not run (no iOS build was started) |
| 6 | `tool/cloud_setup.sh` | OK | Line 596: `npm ci` when the lock exists; the admin build goes through bootstrap with the CI Flutter version |
| 7 | Lock files | OK | Script over all four files. npm: lockfileVersion 3; 274 + 88 packages, every `resolved` on `https://registry.npmjs.org`, every one with a `sha512` integrity, no git, http, file or link entries; root sections equal to `package.json`; every direct version inside its range. pub: 201 + 6 hosted packages, all on `https://pub.dev` with a 64-hex sha256; 5 + 2 sdk; one path (`packages/run_recovery`, ours); no git source; every direct version inside its `pubspec.yaml` range; sdk constraints match. The lock commit `f439ad3` touches only the four lock files and is by `github-actions[bot]` |
| 8 | `docs/meta-whatsapp-setup.md` against the code | OK | Script: all 39 non-wallet templates in `catalog.ts` are in the guide; English and Arabic bodies equal `texts.ts` with `{when}` as `{{1}}`; the variable column matches `hasWhen`. Groups and defaults match `WHATSAPP_DEFAULTS`. `cp_emergency_contact` matches `trips/flow.ts` and SETUP.md 20.3. `login_code`, language codes, `v25.0`, secret name, 5-minute code, "fake sender refused in prod", "only Meta's error number is logged" all match `config.ts`, `.env.prod`, `otp_flow.ts`, `whatsapp/sender.ts` |
| 9 | Meta facts against Meta's pages | Confirmed | Fetched 14 Nov 2026: per-message pricing since 1 July 2025, charged on delivery; from 1 Oct 2026 utility messages in an open window are charged and service messages have 1,000 free per number per month; rate changes on 1 Jan, Apr, Jul, Oct with at least one month's notice for rate cards; volume tiers for utility and authentication only. Limits: 250 start, per portfolio, different people in a moving 24 hours, 2,000 after verification or 2,000 delivered messages in 30 days, then one level up within 6 hours at half the limit used in 7 days. Authentication-international: Egypt since 1 Feb 2025, more than 750,000 in 30 days, only for a business based in another country. 2-number cap, 250 / 6,000 templates, PIN, review up to 24 hours, the four rejection reasons, appeal in 24 hours |
| 10 | `docs/launch-private-repo.md` against GitHub's pages | Confirmed | Fetched 14 Nov 2026: Linux 1-core 0.002, 2-core 0.006, Windows 0.010, macOS 0.062; each job rounded up; included amount USD 12 Free, 18 Pro and Team, 300 Enterprise (2,000 / 3,000 / 50,000 minutes at the Linux rate); storage 500 MB / 1 GB / 2 GB / 50 GB; 0.25 and 0.07 per GB; cache 10 GB; no payment method means usage is blocked; self-hosted free; budget screens and the 75/90/100 percent alerts. Arithmetic in sections 1, 3 and 4 re-done: correct. Run times agree with run 43611761567 (2 + 5 + 11 = 18 billed minutes) |
| 11 | Unconfirmed items are labelled | OK | Egypt prices, verification documents and timing, display-name rules, token dialog wording, GitHub Pro price, default budget, free-plan feature list: each is marked unconfirmed in the text and listed in section 12 (Meta) or section 8 (GitHub). The third-party page (chatmaxima) does show 0.0036 / 0.0036 / 0.0644 / 0.0650 and "effective October 1, 2026"; still third party |
| 12 | Plain English, no secrets | OK | No token, key or ID value in either guide. The token goes only into Secret Manager through an interactive prompt; the guide says three times never to put it in a chat. Only the non-secret phone number ID and account ID may be sent to the developer |
| 13 | WORKFLOW, SETUP, COSTS, open-items, README against DECISIONS "Improvements, revised" | OK | Sentry row unchanged (stays); no Xcode Cloud or Crashlytics anywhere in the touched docs; SMS appears only as "we never send SMS" and "on hold, owner decision, item 6"; lock files (item 2) and private repository (item 7) as decided |

## Blockers

None.

## Non-blocking findings

1. **Unlocked fallbacks still exist now that the locks are committed.**
   `.github/workflows/checks.yml:164-169` and `:188-193` run `npm install`
   with a warning when the lock file is missing;
   `tool/cloud_setup.sh:596-600` does the same with no message at all, on
   the path that deploys functions; `tool/bootstrap.sh:96` and `:110-112`
   do a plain `pub get` with a warning when the lock is not tracked or git
   is not usable. Not reachable today (all four files are committed and CI
   used them), but a deleted lock file would give a green run with only a
   yellow note. Fix after merge: make a missing lock an error in CI and in
   `cloud_setup.sh`; in bootstrap keep only `UPDATE_LOCK=1` as the way
   out. Then update `docs/WORKFLOW.md:43-44`.
2. **`firebase-tools` is not locked.** `checks.yml:173, 181, 194` use
   `npx --yes firebase-tools@15` (newest 15.x each run). Already so on
   `main`; outside this change. Pin an exact version, or add it to
   `functions` devDependencies, when convenient.
3. **Lock job and checks share one concurrency group**
   (`checks.yml:50-52`, cancel-in-progress). Starting the checks on the
   same branch before the lock job has pushed cancels it. Wait for the
   lock job to end (WORKFLOW step 3 already implies it); a separate group
   for `locks` would remove the trap.
4. **iPhone native packages (CocoaPods) are not locked.** `ios/` is
   generated at build time, so there is no committed `Podfile.lock`. The
   Dart plugins are locked, which fixes most pod versions, but not all.
   Known limit; worth one line in `docs/WORKFLOW.md`.
5. **`docs/meta-whatsapp-setup.md:448`** uses `--project prod`, and
   `.firebaserc` still has `REPLACE-school-carpool-prod` for that name.
   The command fails until the prod project exists and the developer puts
   its ID in (open item A1). Add "after A1 is done" to step I.
6. **`docs/launch-private-repo.md:61-62`**: GitHub's page says the "Stop
   usage" tick is shown "if available" and that some budgets always stop
   at the limit. If the owner does not see the tick on a personal account,
   that is expected, not an error. One sentence would prevent confusion.
7. **Small wording.** `docs/WORKFLOW.md:60` says the lock job takes about
   2 minutes; measured 52 seconds. `SETUP.md:232-233` names two of the
   four lock files. `docs/meta-whatsapp-setup.md:481` says the limit
   counts people messaged "with templates"; Meta's page says messaged
   outside a customer service window (same thing for us: the app sends
   only templates). Meta's pricing page lists no Egypt rate change on
   1 Oct 2026 (the last were 1 Oct 2025 and 1 Jan 2026), so "rate card
   effective 1 October 2026" is the card's date, not a new Egypt price.

Already open and correctly reported by the builder, not repeated as
findings: `cp_emergency_contact` (starts or ends with a variable; contact
did not opt in), wallet template wording, and the
`ENFORCE_APP_CHECK.value()` deploy warning (no functions code changed).

## Reviewer commits (docs only)

- `d618d74` `docs/launch-private-repo.md`: the lock job's time was "not
  run yet; estimate about 3"; it has run (43611536413: 52 seconds, 1
  billed minute).
- `1da1ff3` `docs/open-items.md` D16: said the lock files were still to
  be made; they are committed on this branch.

## Could not be verified

- **Egypt prices on Meta's own rate card** (CSV/PDF download). Only the
  third-party copies were read. The guide labels them unconfirmed.
- **Meta Business Help Centre pages** (verification steps, documents,
  display name) and every Meta and GitHub screen label: not opened in a
  browser session. The guide labels the help-centre parts unconfirmed.
- **Codemagic with Flutter 3.50.0 and the lock**: no iOS build was
  started. The same bootstrap path is proven on Linux only.
- **`tool/cloud_setup.sh`**: read, not run.
- **The pinned action commit IDs** (`checkout`, `setup-node`,
  `flutter-action`) against their upstream tags: GitHub API access to
  those repositories is not available in this session. They are the same
  IDs the existing jobs on `main` already use.
- **The `locks` job's refusal on `main` or a tag**: read, not exercised
  (no workflow was started by the reviewer). Its normal path ran once
  (43611536413, success).
- **Tests**: none run here. The statement "CI green" rests on run
  43611761567 at `3da9ad1`, whose job results and logs were read. The two
  reviewer commits change docs only (ignored by CI paths).
- GitHub Pro price, default Actions budget, free-plan feature list for
  private repositories: not confirmed, and labelled so in the plan.
