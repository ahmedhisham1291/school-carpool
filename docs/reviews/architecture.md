# Review: branch `architecture`

Reviewed: f64541c..a5cb6fc (9 commits), plus fix 1 commit.
Verdict: **PASS** after fixing B1. CI full run 43885394606 green
(analyze, 452 Flutter tests incl. layering and callable_error tests,
screenshots, 897 Functions tests, rules 6 + 539, web/admin/Android compile).
The first full run (43885098055, a5cb6fc) failed on flutter analyze (B1).

## Claim: no behaviour change

### Cloud Functions callables (14 modules)
- Options untouched: no `onCall`/`opts`/`signInOptions` line changed; `config.ts`
  (ENFORCE_APP_CHECK = appCheckOption(param), the FUNCTIONS_CONTROL_API
  deploy-time workaround) is not in the diff. `consumeAppCheckToken`,
  minInstances, timeoutSeconds, secrets, region and gates (gatedCall,
  sessionCall, realParentCall, featureGatedCall, requireAdminCaller) unchanged.
- Exports unchanged: `index.ts` and `firebase.json` not in the diff; the only
  removed exports are the three dead ones below; `carpools.run`/`caller` stay
  exported with the same signature.
- `runCallable` vs each old `run`, checked one by one: HttpsError passes
  through first; mapped domain errors are not logged (same as before); others
  are logged by name with message only, sent to Sentry, answered `internal
  "Something went wrong."`, or `unavailable` with reason
  `settle-up-unavailable` / `wallet-unavailable` as before.
- Error details identical: `retryAfter` modules (carpools, maps, places/MapError)
  had `retryAfterMs = 0` defaults, so `?? 0` changes nothing; `details` modules
  (places/AddressError, settle_up, wallet, privacy/AdminError) spread as before;
  `none` modules (features/AdminError, trips, schools, privacy/DeviceError) send
  only `{ reason }` as before. notifications keeps its own mapper verbatim;
  privacy's DeletionError still goes through `fail()`.
- classesMapper modules (admin_panel, auth, trust, verification): each
  `toHttpsError` returns an HttpsError unchanged and `internal` for anything
  else, so routing through the mapper only for the listed classes is equivalent.
- `requireUid`/`callerOf`: same message and code; `verified === true` claim.
  Wallet's old `token.verified` vs `token?.verified`: equal when uid exists.
- Constants: OPEN_TO_UNVERIFIED, POINT_KEEP_MS (12 h), DEVICE_STALE_DAYS (180)
  already existed on main with the same values.

### Dead code
`weekDates`, `reportContextPurgeAt`, `IMAGE_RETENTION_MS`,
`PlaceholderTabScreen`: no reference anywhere in the repository outside docs
(git grep over functions, lib, test, tool, tools, scripts, rules, admin).
`REPORT_CONTEXT_DAYS` is still used by the retention table.

### App
- Collection constants: every replaced literal equals the constant's value
  (all 27 names are identical to their strings; `Docs.features` = 'features').
- AppFailure: only `implements` and `@override` added; no message changed.
- callableReason: same reading of `details.reason`, typed String?.
- New lints: no violations (analyze clean in CI).
- Layering test exceptions: 2 Firebase imports in screens, chat (rewritten on
  chat-review-safe), 6 admin geography imports, 1 design component: each
  has a written reason and is a ratchet. Justified.

## Blockers

- **B1 (fixed)** `lib/features/places/address_repository.dart`: the migration
  removed `final Object? details = error.details;` but the `pin-outside-area`
  branch still reads `details` (undefined_identifier, analyze failed, app did
  not compile). Restored the local. Same-shape files (settle_up, wallet,
  admin, auth, verification, maps) keep their `details` local.

## Notes

- N1: `retention.ts` and `schedule/cairo.ts` keep a double blank line where
  code was removed (cosmetic).
- N2: `callableReason` returns null for a non-String reason, where the old code
  kept the Object; `demo_refusal.dart` would then fall back to `error.message`.
  The server always sends a string reason, so no visible change.
- N3: `trust_models.dart` `reason is String &&` is now a null check; could read
  `reason != null`.
- N4: the progress record's "checked with an equivalent script" did not catch
  B1; Dart changes need the CI run before "no behaviour change" is claimed.
- N5 (pre-existing): the screenshot job runs with `--update-goldens`, so it
  regenerates rather than compares; it cannot detect a rendering change.
- N6: `chat/callables.ts` still has its own `run` (deliberate, ADR-006).
