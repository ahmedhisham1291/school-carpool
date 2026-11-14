# Owner setup script (staging, Cloud Shell)

Branch `owner-setup-script`. `tool/cloud_setup.sh` + `docs/owner-cloud-shell.md`.

## Checked here

- `bash -n` and shellcheck 0.10.0: clean (`tool/cloud_setup.sh`, `tool/setup_retention.sh`).
- A full run against stubbed `gcloud`, `curl`, `npx`, `npm` and `flutter`
  (exit 0, every step reached, the Dart options file generated correctly,
  `.firebaserc` and `functions/.env.staging` left unchanged on rerun).
- **Not run against a real Google Cloud project** (none reachable here).
  `functions/scripts/admins.ts` `password-link`: written, not compiled here.

## Open questions / to confirm on the first real run

- REST shapes used without a live check: Identity Toolkit admin v2 `config`
  (`subtype`, `signIn.email`, `client.permissions`, `smsRegionConfig.allowlistOnly`,
  `authorizedDomains`), `identityPlatform:initializeAuth`, App Check
  `appAttestConfig` / `recaptchaEnterpriseConfig` PATCH, Firebase Management
  `iosApps.teamId`. Each falls back to a printed console step on failure.
- `gcloud recaptcha keys create --web --integration-type=score` flag spelling.
- Firebase CLI in Cloud Shell signs in with Cloud Shell's credentials; if not,
  the script runs `firebase login --no-localhost` (flag not verified on v15).
- Maps per-day caps are a console step (quota ids not verifiable).
- `functions/` has no `package-lock.json`, so the script uses `npm install`.
- The admin panel's Flutter web build on Cloud Shell (Flutter 3.50.0 clone,
  about 3.5 GB) is untested; it falls back to `/tmp` when the home disk is
  short.
- `PUSH_PROVIDER` is missing from `functions/.env.dev` and `.env.prod` too
  (default `fake`; prod refuses it). Staging fixed here; dev/prod left for
  their own setup.
