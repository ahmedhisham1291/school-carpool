# Architecture decisions (ADR log)

Short records of structural decisions. Product and owner decisions stay in
`docs/DECISIONS.md`. Add a new entry at the end; never rewrite an old one
(supersede it instead).

## ADR-001: Feature folders, flat, with fixed file roles (recorded 16 Nov 2026)

**Context.** The app grew prompt by prompt into 24 feature folders.
**Decision.** Keep one flat folder per feature with fixed file roles
(`_models`, `_repository`, `_logic`, `_labels`, screens). No `data/`,
`domain/`, `presentation/` sub-folders.
**Why.** The roles are already consistent across features; moving 300 files
to sub-folders would break every in-flight branch for no behaviour gain. The
layering is enforced by tests instead (`test/architecture/layering_test.dart`).

## ADR-002: Repository interface + Firebase implementation + Riverpod provider (recorded 16 Nov 2026)

**Decision.** Each feature exposes `abstract interface class XRepository`,
implemented by `FirebaseXRepository`, provided by `xRepositoryProvider`.
Screens read providers only; tests override the provider with fakes.
**Why.** Widget and golden tests run without Firebase; Firebase code stays in
one file per feature.

## ADR-003: Server flows are pure; stores are the only Firestore code (recorded 16 Nov 2026)

**Decision.** In Cloud Functions, `flow.ts` and `model.ts` import nothing from
Firebase; they take `XDeps` (store interface, clock, limits, providers).
`FirestoreXStore` implements the store. Tested by
`functions/test/architecture.test.ts`.
**Why.** About 900 flow tests run in seconds against in-memory stores.

## ADR-004: One callable wrapper and one error contract (16 Nov 2026)

**Context.** 15 modules had their own copy of `run()` (error mapping, logging,
Sentry) and 13 had their own `requireUid`/`caller`, with small differences.
**Decision.** `functions/src/common/callable.ts`: `runCallable` with
`reasonErrorMapper` / `classesMapper`, `requireUid`, `callerOf`. A refusal
travels as `HttpsError(code, reason, { reason, ...extras })`; the app reads it
with `callableReason` and maps it to its feature failure, which implements
`AppFailure` (`lib/core/app_failure.dart`). The answers (code, message, details) are the
same as before the change.
**Why.** One place for logging rules (never request data), Sentry and
fallbacks; a new module cannot forget them. The architecture test refuses new
hand-written wrappers.
**Not done.** `chat/callables.ts` (being rewritten on chat-review-safe).

## ADR-005: Collection names as constants, checked against the rules (16 Nov 2026)

**Decision.** App: `Collections` in `lib/firebase/collections.dart`.
Functions: the owning store's constant. Tests: no new `.collection("literal")`
(a counted budget for the old literals in the privacy module), every app
collection has a `match` in `firestore.rules`, every top-level rule names a
collection the code uses.
**Why.** A typo in a collection name fails silently at runtime (empty reads,
denied writes); now it fails a test.
**Not done.** Field names stay literals: they are many, local to one model or
store, and covered by the flow and rules tests.

## ADR-006: Large files and cross-folder moves wait for quiet branches (16 Nov 2026)

**Context.** Several files are over 800 lines (privacy store, trips and
carpool flows, gallery, admin schools screens), and the parent app imports
Egypt geography from `lib/admin`.
**Decision.** Do not split or move them while review-risks, legal-egypt,
chat-review-safe and security are in flight; ratchet tests stop the problems
from growing. Split by sub-domain (for example `privacy/firestore_store.ts`
into deletion, devices, requests and retention stores) when the privacy and
security work has merged; move geography to `lib/core/geo/` with
re-exports from `admin_models.dart`.
**Why.** A split now would conflict with almost every open branch for no
behaviour change.

## ADR-007: Compiler and lint strictness grows only with zero violations (16 Nov 2026)

**Decision.** Turn a TypeScript flag or Dart lint on only when the code
already passes it (checked by compiler or by search), in its own commit.
Added: `noUnusedParameters`, `noImplicitOverride`;
`avoid_catches_without_on_clauses`, `avoid_void_async`, `prefer_void_to_null`.
Measured and left off: `noUncheckedIndexedAccess` (409 errors).
