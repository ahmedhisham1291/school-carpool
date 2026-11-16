# Architecture review and clean-up (branch `architecture`)

Owner request: check the structure, files and data types, make the code and
architecture clean and easy to change, and fix what we can. Constraint from
the coordinator: other branches are in flight (review-risks merged,
legal-egypt, chat-review-safe, security), so no mass renames or moves, no
reformatting, no renamed callables, collections, fields or ARB keys.

Result: `docs/architecture/overview.md` (as-is architecture, conventions,
checklists), `docs/architecture/decisions.md` (ADR log), and the commits below.

## Survey (measured)

| Area | Finding |
| --- | --- |
| Size | 24 feature folders, 36 000 lines in `lib/features`, 9 000 in `lib/admin`; 18 Functions domains, 187 exports in `index.ts`. 30 files over 600 lines; the largest: `tools/import_schools/schools_import.py` 2 184, `functions/src/privacy/firestore_store.ts` 1 103, `trips/flow.ts` 1 045, `gallery_screen.dart` 1 041, `carpools/flow.ts` 1 030. |
| Duplication (functions) | 15 copies of the callable error wrapper `run()` and 13 copies of `requireUid`/`caller`, with small differences; 8 copies of `record(data)` (two behaviours). |
| Duplication (app) | 12 copies of "read `details.reason` from a callable error"; 17 failure classes with the same shape and no common type. |
| Layering (app) | Clean: of 35 files importing Firebase data packages in `lib/features`, 33 are repositories/models/session; 2 exceptions (`devices_screen.dart`, the dev-only button in `settings_section.dart`). 6 parent-app files import `lib/admin` (Egypt geography); 1 design component imports a feature. |
| Layering (functions) | Clean: no `flow.ts`/`model.ts` imports Firebase. |
| Typing | Functions: `strict`, no `any`. App: `strict-casts/inference/raw-types` on; `dynamic` only at the Firestore boundary; maps do not reach widgets (one request payload). No typed-model work needed. |
| Magic strings | Functions: 82 collection literals, 62 of them in `privacy/firestore_store.ts`; per-store constants elsewhere (14 names defined twice). App: 32 collection literals across 14 repositories. Magic numbers duplicating named constants: live-point TTL (12 h), device TTL (180 days), "open to unverified" types. |
| Dead code | 1 unused Dart file (`placeholder_tab_screen.dart`); 3 unused Functions exports (`weekDates`, `reportContextPurgeAt`, stale `IMAGE_RETENTION_MS`); 11 unused ARB keys. |
| Error handling | Consistent contract (`details.reason`), implemented by copy-paste on both sides (see duplication). |
| Tests | 881 Functions tests, 192 Python tests passing at the start. Callables/stores are glue tested through flows; no gaps found in core logic. |
| Circular imports | None found between Functions domains that tsc or the flows' design would flag; `schedule/release.ts` already exists to break the carpool/schedule cycle. |

## Commits

1. `e30df70` Functions: `common/callable.ts` (`runCallable`, `reasonErrorMapper`,
   `classesMapper`, `requireUid`, `callerOf`) replaces the wrappers in 14
   modules; `test/architecture.test.ts` and `test/callable.test.ts`.
2. `dfdd0d7` Functions: named constants instead of repeated magic values; dead code removed.
3. `84ee871` App: `AppFailure` + `callableReason`; 13 failure types migrated; dead placeholder screen removed.
4. `da0beb9` App: `Collections`/`Docs` constants in 13 repositories; `test/architecture/layering_test.dart`.
5. `dcb74ed` Architecture test: app collection names must have a rule.
6. `92ea6f0` Functions: `noUnusedParameters`, `noImplicitOverride`.
7. `d7dbd47` Lints: `avoid_catches_without_on_clauses`, `avoid_void_async`, `prefer_void_to_null`.
8. Docs (this file, `docs/architecture/`).

No behaviour change in any commit.

## Deliberately left (ADR-006)

- Splitting the large files: all are in areas other branches are changing now.
- Moving Egypt geography out of `lib/admin`; migrating `chat/` (its rewrite is
  on chat-review-safe); the privacy store's 62 literals (security branch).
  Ratchet tests stop each from growing.
- Unused ARB keys: removing them touches both ARB files that legal-egypt is
  rewording.
- Shared `record(data)` input helper: two behaviours (lenient and throwing)
  in 8 modules; merging them is a behaviour review, not a refactor.
- `noUncheckedIndexedAccess` (409 errors).

## Tests

| Suite | Result |
| --- | --- |
| Functions `node --test` (incl. new architecture and callable tests) | **Run here: 897 pass, 0 fail.** `tsc` prints only the workspace's known type-stub errors (165 lines, same as before). |
| Python `tools/import_schools`, `tool/` | **Run here: pass** (144 + 48) |
| Flutter analyze, `test/architecture/layering_test.dart`, `test/core/callable_error_test.dart`, all widget/golden tests | Written, not run here (no Flutter SDK). The layering rules were checked against the tree with an equivalent script. |
| Rules tests (`tests/rules`) | Not run here (no emulator); no rules changed. |

## Open questions

- After chat-review-safe merges: move `chat/callables.ts` to `runCallable` and
  `chat_repository.dart` to `Collections`, then drop both from the allow lists.
