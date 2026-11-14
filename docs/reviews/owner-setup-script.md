# Review: branch owner-setup-script (tool/cloud_setup.sh and friends)

Reviewed head e196d9c (8 commits on main 24f5e4d). Independent reviewer, 14 Nov 2026.

## Verdict: PASS (after three reviewer fixes, committed on this branch)

All three blockers below were small and clearly correct, so the reviewer fixed
them in separate commits (c11fe81, 94a6646, 569c640). With those commits the
branch is safe for the owner to run against `school-carpool-staging`.
The first real run is still the true test: many REST calls could not be
exercised from here (see "Unverifiable").

## Checks run here

- `bash -n` on tool/cloud_setup.sh, tool/setup_retention.sh: clean.
- shellcheck 0.10.0 (default severity) on cloud_setup.sh, setup_retention.sh,
  setup_kms.sh: clean. `-o all` only gives style/info notes (SC2292, SC2310,
  SC2312). The script handles the errexit-in-`if` case on purpose (`run_step`).
- functions: `npm run build` fails with 156 TypeScript errors on BOTH main and this
  branch. The cause is the stub node_modules (firebase-admin types are `any`, no
  `sharp`). None of the errors is in scripts/admins.ts. tsc still writes its
  output, and `node --test lib/test/*.test.js` gives 632/632 passing on this branch.
  Because firebase-admin is stubbed, `passwordLink` is not really type-checked.
  A read-through against the firebase-admin 13/14 API (getUserByEmail,
  customClaims, phoneNumber, generatePasswordResetLink) finds nothing wrong.
- gcloud 570 `--help` (offline) confirms these flags: `services api-keys create
  --api-target=service=... (repeatable) --allowed-bundle-ids`, `api-keys
  get-key-string`, `recaptcha keys create --web --domains --integration-type=score`,
  `billing budgets create --budget-amount --threshold-rule=percent= --filter-projects=projects/{project_id}`,
  `storage service-agent [--authorize-cmek]`, `firestore fields ttls update/list`,
  `firestore indexes fields describe`.
- All 79 functions params are either in functions/.env.staging or have a
  default, so a non-interactive deploy will not stop to prompt for a value.
  PUSH_PROVIDER=fcm is accepted by functions/src/notifications/push.ts.
- codemagic.yaml parses; ios-staging triggering = tag `v*` only (+ manual).
- Google Analytics: the script does not depend on it being on or off. The web
  config's measurementId and the plist analytics keys are simply ignored.
  apps:create is not interactive about Analytics, and the budget and auth
  settings are unaffected. The owner guide now says either setting is fine.

## Blockers (all FIXED by the reviewer)

1. tool/setup_retention.sh:38 used `gcloud firestore fields describe`, which does
   not exist (`gcloud firestore fields` has only the `ttls` group; confirmed with
   gcloud 570 help). The `|| true` hid the error, so the check never worked and
   every rerun issued all 22 TTL updates again. The commit that claimed to make
   reruns safe did nothing. FIX (c11fe81): `gcloud firestore indexes fields
   describe FIELD --collection-group=G --format='value(ttlConfig.state)'`.
2. tool/cloud_setup.sh:331 `secret_has_value` filtered with `state=ENABLED`. The
   Secret Manager filtering docs use `state:ENABLED`, and gcloud documents `=`
   as behaving differently from API to API. If the filter ever matched nothing,
   a rerun would add a NEW random version to OTP_HMAC_KEY and
   NATIONAL_ID_HMAC_KEY. That cannot be undone: every stored national-ID hash
   would stop matching, so duplicate detection breaks. FIX (94a6646): use
   `state:ENABLED`, and give a random secret a value only when it has no
   version at all. Otherwise the script prints a to-do and leaves the secret alone.
3. docs/owner-cloud-shell.md, "Run it again safely": `git pull` stops with "local
   changes would be overwritten" once the developer commits
   lib/firebase/firebase_options_staging.dart. The script rewrites that file
   in the clone on every run. A non-developer owner would be stuck there.
   FIX (569c640): the rerun command is `git checkout -- . && git pull && bash ...`.
   The same commit also says that Analytics on or off is fine.

## Non-blocking

1. cloud_setup.sh:572 `fb deploy ... --force`. On a rerun this deletes any
   Firestore index or function that exists in the project but not in the repo,
   with no prompt. For staging that is acceptable, because the repo is the
   source of truth. It is still worth one line in the owner guide.
2. cloud_setup.sh:283 grants roles/iam.serviceAccountTokenCreator to the compute
   SA at **project** level, so it can mint tokens for every SA in the project.
   signBlob/custom tokens only need it on the SA itself:
   `gcloud iam service-accounts add-iam-policy-binding $SA --member=serviceAccount:$SA --role=roles/iam.serviceAccountTokenCreator`.
   This follows SETUP 11.2 as written; tighten both together.
3. cloud_setup.sh:699 `--budget-amount=20USD` fails if the billing account's
   currency is not USD (for example EGP). It then falls back to a console to-do,
   which is fine. The amount could instead be read from
   `gcloud billing accounts describe --format='value(currencyCode)'`.
4. cloud_setup.sh:695-696 `budgets list | grep -Fxq` in `if` with pipefail. If
   gcloud were still writing when grep exits (SIGPIPE), the pipeline counts as
   failed and a duplicate budget would be created. This is negligible at this
   output size; `grep -Fx ... >/dev/null` avoids it entirely.
5. cloud_setup.sh:652 builds the admin panel with an empty RECAPTCHA_SITE_KEY if
   the reCAPTCHA key could not be made. It only prints a to-do, so the panel
   would break once App Check is enforced. Consider skipping the admin build
   in that case.
6. cloud_setup.sh:570 `npm install` without a lockfile, so every run can resolve
   newer ^ versions than CI uses. Commit functions/package-lock.json when a
   machine with npm access is available.
7. The guide's `git clone https://github.com/...` assumes the repository is
   public. If it is private, Cloud Shell asks for a GitHub username and token,
   and the guide does not explain that.
8. CLAUDE.md COST MODE still says "build iOS only on push to main or a tag",
   but this branch moves ios-staging to tag/manual only (owner decision 14 Nov,
   noted in codemagic.yaml). The owner should update CLAUDE.md. The reviewer
   did not edit it.
9. If an HMAC secret exists with only disabled versions, the script now prints
   a to-do and then dies at the deploy with a generic message. That is
   acceptable, but an early `die` naming the secret would be clearer.

## Unverifiable here (check on the first real run)

The script falls back to a printed console step for most of these.
- The field names are confirmed from the Google API client reference
  (googleapis.github.io identitytoolkit_v2): Identity Toolkit admin v2
  `projects/{id}/config` has `subtype`, `signIn.email.{enabled,passwordRequired}`,
  `client.permissions.{disabledUserSignup,disabledUserDeletion}`,
  `smsRegionConfig.allowlistOnly.allowedRegions`, `authorizedDomains`, and
  `mfa.providerConfigs[].totpProviderConfig`. `identityPlatform:initializeAuth`
  exists and is "available only to billing-enabled projects". Not checked
  against a live project: whether GET returns `"allowlistOnly": {}` after the
  PATCH, and what initializeAuth does on a project already on plain Firebase
  Auth. In both cases the script either retries harmlessly or dies with a
  console instruction.
- App Check v1 `projects/{number}/apps/{app}/recaptchaEnterpriseConfig` PATCH
  with `siteKey` is confirmed (the docs' example mask is `site_key`;
  camelCase `siteKey` in the query is normally accepted). Not confirmed:
  that PATCHing `appAttestConfig` with only `tokenTtl` registers the app the
  way the console's "Save" does.
- Not confirmed live: `firebase login --no-localhost` and `apps:create IOS ...
  --bundle-id` in firebase-tools 15 (v15.34 exists; its README confirms the
  CLI falls back to Application Default Credentials). Also not confirmed:
  that Cloud Shell's metadata ADC gives firebase-admin a quota project for
  `generatePasswordResetLink`. GOOGLE_CLOUD_QUOTA_PROJECT is exported for
  this, but it was not tested.
- The Maps per-day quota caps are a console step, as designed.
- The Flutter web build on Cloud Shell (disk space, time) has not been tried.

## Safety summary

- The script refuses project ids containing "prod", accepts only the staging
  env, and refuses if the id differs from .firebaserc.
- Secrets are never printed. Existing secret values are kept, except the
  `unused` placeholder for MAPS_SERVER_KEY.
- Key strings stay in a temporary folder that is removed on exit. Only the
  labelled iOS Maps key and the one-time admin link are printed.
- Files written into the clone hold no secrets: .firebaserc, .env.staging
  (INVITE_LINK_BASE) and the Firebase options file (public client config).
- Nothing deletes data. Changes to lifecycle, CORS and default CMEK follow the
  documented SETUP 23 plan.
