# Review: branch schools-sources (validator, 16 Nov 2026)

Base main f8bcd60, reviewed head 60a0c95, plus the validator commit below.

**Verdict: PASS** (no security or privacy blocker; one time-cap gap fixed
by the validator, one defensive merge-order fix).

## Checked

1. **App Check workaround (functions/src/config.ts).** Read firebase-functions
   v7.4.0 (the version in functions/package-lock.json) source:
   `onCall` resolves an `enforceAppCheck` Expression with `.value()` at
   definition time (src/v2/providers/https.ts L441-444), `.value()` logs
   the three warnings only when `FUNCTIONS_CONTROL_API === "true"`
   (src/params/types.ts L48), and `enforceAppCheck` is not part of the
   endpoint manifest (v2/options.ts optionsToEndpoint), so passing `true`
   during discovery changes nothing deployed. `defineBoolean` still
   registers the param, so the CLI still resolves and injects
   ENFORCE_APP_CHECK at runtime. firebase-tools sets FUNCTIONS_CONTROL_API
   only in the discovery child process (src/deploy/functions/runtimes/node/index.ts
   spawnFunctionsProcess); the emulator runtime and Cloud Run do not.
   The workaround can only ever substitute `true` (enforce), never `false`:
   a misfire fails closed. .env.staging/.env.prod keep ENFORCE_APP_CHECK=true.
   Correct; not reverted.
2. **Overture.** Checked against OvertureMaps/schema (main, 13 Nov 2026) and
   OvertureMaps/docs: `taxonomy.primary/hierarchy/alternates` replaced
   `categories` in schema 2.0.0 (2 Sep 2026); `names.primary`,
   `names.common` (map lang -> name), `confidence`, `operating_status`,
   `basic_category`, `bbox.xmin/ymin` all exist. Every category key used is
   in static/taxonomy/2026-09-23.0/taxonomy.csv (school and its 12 children,
   day_care_preschool and child_care_and_day_care under family_service,
   college_university). The bbox filter is the docs' own DuckDB pattern;
   STAC `catalog.json` `.latest` is the documented release discovery, with a
   fallback. Attribution text matches docs/_generated_attribution.mdx
   (Places). Overture never becomes the main entry (rank order + new test).
   Privacy: the query selects id, bbox point, names, taxonomy, basic_category,
   confidence, operating_status, sources, addresses; no phones, emails,
   websites, socials or brand. Only public business data.
3. **Per-governorate fetch.** Area = 3600000000 + relation id from the
   governorates download, else `area["ISO3166-2"=..]["admin_level"="4"]`;
   dedupe by osm_type/osm_id/geometry type; recent parts reused only with
   the same query id; failed parts fall back to their older file; two
   passes only, no loops; budget checked before every request.
4. **Rules.** Probed 37 names: amenity=school always kept (Victoria College,
   Cairo American College), Azhar institutes kept under any tag, Al-Azhar
   University and its faculties dropped, language schools kept unless the
   name says centre/institute, nursing secondary schools kept, nurseries
   kept as kindergartens, universities dropped with the switch off.
5. **Step 12.** duckdb install failure returns 3 -> to-do line, import goes
   on; Overture failure -> to-do line; caches make it idempotent;
   categories.json excluded from inputs; nothing secret printed.
6. **Tests.** Python 95/95 here (after the fix); bash -n ok; CI run
   43771692510 on 60a0c95 green (Functions 802 pass incl. appCheckOption,
   Python tool tests, Flutter).

## Blockers

None open.

- B1 (fixed): the national safety-net query ran `overpass(rounds=2)` with the
  540 s timeout inside a fetch_parts second pass, and got a 60 s minimum
  budget even when --max-minutes was used up: up to about an hour past the
  75-minute cap. Now one round per pass (fetch_parts' pass 2 is the retry).

## Notes (not blocking)

- N1 (fixed, defensive): a pinless non-Overture entry could have ranked
  after an Overture place; Overture is now ranked last right after owner
  lists (test_overture_is_never_the_main_entry). Wikidata items all have
  P625 today, so this was latent.
- N2: on a first split run, parts that fail with no older per-part file make
  the merged file smaller than the old all-Egypt file (the narrow national
  net limits the loss; the loader never deletes, so Firestore keeps them).
- N3: the older-file fallback for a failed part does not check its query id
  (a file made before a categories change can be used; it is dated in the report).
- N4: places parts accept an empty answer (min_features 0); if the
  boundaries file were missing and the ISO3166-2 area lookup failed, a
  governorate would be stored empty as "downloaded" for 7 days.
- N5: Overture name rules drop "كلية ..." even under a school category
  (e.g. Victoria College's Arabic name); OSM has such schools as
  amenity=school, so they stay in the list through OSM.
- N6: Azhar-institute names win over any non-street tag (a mosque named
  after an institute could be kept as a school); false add, visible in review.
- N7: `pip install --user duckdb` can be refused on PEP 668 systems; that
  path only gives the to-do line (acceptable).
- N8: Overture data joined with OSM may make the catalog an ODbL derivative
  (Overture docs note); our catalog already carries the OSM attribution.
- N9: fetch report "Without a position" is always 0 for the split download
  (counts() gets features, not elements); cosmetic.
