# Review: schools-ai-review (AI name review, step 12)

Reviewed: f62666f, 9c6cf2c, d7d4114 (on schools-fixes 723aee2), then
origin/main 7e68df4 merged in (clean: main added no tool changes since
723aee2). Validator, 16 Nov 2026.

**Verdict: PASS after fixes** (B1-B5 fixed in this branch; N1-N7 open).

## 1. Vertex AI REST (checked on the docs, 16 Nov 2026)

- gemini-3.8-flash: model id `gemini-3.8-flash`, GA 2 Sep 2026; available
  in `global`, `us`, `eu`, `northamerica-northeast1`, `asia-northeast1`;
  structured output and thinking supported; thinking levels LOW, MEDIUM
  (default), HIGH (MINIMAL is a validation error). Code: OK.
- Multi-region host `https://aiplatform.eu.rep.googleapis.com/v1/projects/P/locations/eu/publishers/google/models/M:generateContent`
  (us likewise); global `aiplatform.googleapis.com`; regional
  `{region}-aiplatform.googleapis.com`. Code: OK.
- `generationConfig.responseMimeType` / `responseSchema` (OpenAPI types
  OBJECT/ARRAY/STRING/NUMBER) and `thinkingConfig.thinkingLevel: "LOW"`: OK.
- Claude on Vertex: `:rawPredict` under `publishers/anthropic`, body
  `anthropic_version: "vertex-2023-10-16"` (still accepted; `2026-10-21`
  also), no `model` in the body, `claude-haiku-5-5` is a valid id; same
  three host types (regional endpoints serve only Sonnet 4.6 and earlier,
  so a region for Haiku 5.5 404s and falls back to global). OK.

## Blockers (fixed)

- **B1 Gemini temperature 0.** Vertex's Gemini 3 guide strongly
  recommends the default temperature 1.0 (lower may loop or degrade).
  Fixed: no temperature in the Gemini body (Claude keeps 0).
- **B2 AI merges bypassed every duplicate guard.** `merge_into` from the
  AI went straight through `apply_merge_decisions`: primary + prep,
  boys + girls, a school + a kindergarten, two chain branches, two schools
  of a common name, a pair a reviewer marked `separate`, or two batch
  members 50 km apart (batch members are not distance-limited) could be
  merged. Fixed: `schools_import.ai_merge_blocked` checks every AI
  `merge_into` (manual `separate`, kind, stage, boys/girls, both pinned
  and <= 2 km, and `dedupe.judge` keeps stage / one_sided / people /
  branches / common_name with the run's common cores). Blocked merges are
  counted as `merge_into blocked (<why>)` in "AI decisions applied".
  A reviewer's own `merge_into` is not checked (unchanged).
- **B3 Rename check too weak.** Half the words sufficed, so
  "مدرسة النور" -> "Nour Al Islam School" (another school's name) passed,
  and stage words could be added or dropped. Fixed: every word of the new
  name must be a word of the old names (same word, one-letter slip in a
  long word, or same consonants across scripts, so transliteration still
  passes); no stage or boys/girls added, none dropped from the same-script
  name; the new name may not equal another batch member's or neighbour's
  name (that is a merge, not a rename).
- **B4 Prompt injection.** Names were already sent as JSON, ids and merge
  targets validated per batch, but the prompt did not say to ignore
  instructions in names, and nothing limited drops. Fixed: prompt says
  names are untrusted data and each entry is judged alone (PROMPT_VERSION
  names-2); a batch with >= 3 drops that are > 50 % of it is "suspicious":
  none of its changes are applied or cached, the summary and step 12 print
  a to-do.
- **B5 A run without the AI un-hid what the AI hid.** On any Vertex or
  token failure the script deleted ai_decisions.csv and step 12 loaded
  without it; the loader's `planUnhide` / `planUnmerge` then brought back
  every school an earlier run's AI had dropped or merged, and renames
  reverted. Fixed: a model failure part-way no longer aborts: cached and
  fresh verdicts are written (exit 0, "AI review: incomplete", to-do); if
  the token or the cache cannot be read (exit 3) the previous
  ai_decisions.csv is kept and step 12 applies it again. Non-JSON answers
  are retried and are non-fatal.

## Confirmed fine

- Drop of a survivor writes `drop` for every entry of its group: the
  survivor is hidden by `planDroppedHiding` (active only); entries an
  earlier import merged stay `merged` (not re-activated: `planUnmerge`
  needs the id in the incoming list, `planUnhide` needs a claimed key).
  Nothing is un-hidden. A manual decision on one member key wins over the
  AI drop for that entry (by design).
- Protected schools: `planDroppedHiding` skips adminEdited and source
  "parent" (test in functions/test/schools_fixes.test.ts); renames of
  adminEdited schools are left alone by `planImport`; merges into/out of
  edited schools follow `planAutoMerges` (edited kept). Parents' schools
  are not in review_input.csv, so they are never sent.
- Privacy: only id, names, kind, category, governorate and neighbours'
  names are sent; positions are used locally; no user data; the token is
  never printed (errors print the HTTP code only).
- Cache: key = sha256 of prompt version + model + the school's sent data +
  neighbours' sent data; a changed name, neighbour, model or prompt
  re-sends. "missing" and suspicious results are not cached. Idempotent:
  step 12 always reviews the pre-AI import, so hashes are stable.
- schoolReview: `allow read, write: if false`; deny_all rules test reads,
  writes and lists it; NOT_DELETED entry (not personal). Syntax checked.
- Cost: 200 calls cap, tokens and estimated USD in the summary, to-do on
  the cap.

## Open (N)

- N1 FirestoreCache.load reads the whole schoolReview collection every
  run (one read per school; ~50k reads per run at full size, inside the
  free 50k/day only once). Fine for now; later read only ids of this run.
- N2 Results with a non-"missing" problem (bad verdict) are cached and
  not asked again until the school or prompt changes.
- N3 SCHOOLS_AI=off loads without AI decisions, so earlier AI drops,
  merges and renames are undone (intended as "turn the AI off"; say so
  in SETUP if the owner wants otherwise).
- N4 Partial failure: a school whose hash changed since its cached verdict
  and was not reached this run loses its earlier AI decision until the
  next full run.
- N5 AI renames change the main entry's name before dedupe, so a renamed
  school may group differently on re-import than the AI saw.
- N6 Price constants are estimates (Gemini intro price, Haiku guess);
  overridable by env.
- N7 Vertex calls and the Firestore REST cache are tested with fakes only;
  rules and Functions tests run in CI.

## Tests

- Python: `python3 -m pytest -q tools/import_schools` 144 passed (run
  here; 8 new: rename safety, injection/body, suspicious batch, part-way
  failure, cached verdicts applied on failure, previous decisions kept,
  AI merge guards x5, separate beats AI merge, allowed AI and manual merges).
- `bash -n tool/cloud_setup.sh`: OK.
- Functions, rules (emulator), Flutter: CI checks.yml full=true (run id in
  the report).
