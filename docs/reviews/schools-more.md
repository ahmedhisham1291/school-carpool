# Review: branch schools-more (more real schools, F4)

Reviewer: validator agent, 16 Nov 2026.
Scope: `git diff main...HEAD` for 3e97f4f, 619d7cf and cc2c6b8:
tools/import_schools (broad Overpass query, keep/drop rules, name
recovery, Wikidata SPARQL and converter, merge with the `wikidata=Q` tag),
tool/cloud_setup.sh step 12, and the docs. The coordinator added two small
changes to this review (C1, C2 below).

## Verdict: PASS (after two blocker fixes on this branch)

Both blockers were small, so I fixed them on the branch (commit 2373050).
No blocker is open.

## Blockers (fixed)

- **B1. Real Egyptian schools were dropped, and main had kept some of them**
  (`schools_import.classify_tags` / `name_says_not_school`).
  - `مركز` was a "courses/centre" word. In Egyptian school names it is
    usually the district (markaz): "مدرسة كفر الشيخ الإعدادية بمركز دسوق"
    and "مدرسة الشهيد ... مركز طوخ" were dropped as `not_school_courses`.
    "X Academy School" was dropped the same way.
  - A named `building=school` that also had a `religion=*` tag was dropped
    as `not_school_feature`. That hits church and Azhar schools.
  - Main kept every named `building=school`, so both cases were a
    regression.
  - Fix: center, centre, academy, اكاديمية, مركز and سنتر now drop a name
    only when the name does not itself read like a school's. The strong
    words still always drop: driving, music, training, nursing, dance,
    courses, and the same words in Arabic. `religion` alone no longer
    drops a named school building. The tests are updated.
- **B2. Wikidata's "language school" class was dropped**
  (`fetch_wikidata_schools.NOT_SCHOOL_CLASSES`). The brief, and the OSM
  rules, keep Egyptian language schools, because they are ordinary
  schools. Wikidata items of that class went to `amenity=training`, which
  is dropped. Fix: "language school" is out of the drop pattern, and there
  is a test. Commit 2373050. SETUP.md 14.1 and the progress note are
  updated.

## Coordinator changes made during the review

- **C1. Wikidata contact** (commit 1e337e3). Step 12 now passes
  `WIKIDATA_CONTACT="${WIKIDATA_CONTACT:-${ADMIN_EMAIL}}"` to the
  Wikidata fetch only. The contact goes only into the User-Agent header.
  The fetcher never prints the User-Agent, and the script prints nothing
  new. No address is in the repository. Docs: the script header, SETUP.md
  14.1 and the progress note.
- **C2. Algolia step 6 reasons** (commit c608ff5). Before, the to-do always
  said "the two keys must differ". The new `tool/algolia_keys.py decide`
  gets only 0/1 flags, exit codes and the checker's verdict messages,
  never a key. It names each reason it finds:
  - the write key is empty;
  - the search key is empty;
  - the same key was pasted twice;
  - the write key was refused, with the checker's message;
  - the search key was refused, with the checker's message.

  A search key that could not be checked (exit 2) is now stored with a
  to-do warning, as the write key already was. The warning says the app's
  first search is the check, and asks the owner to confirm in the
  dashboard that the key has only the search right. That last part
  matters: an unchecked key could carry extra rights, which the app's
  one-hour keys would inherit. Empty keys are no longer sent to Algolia.
  The new tests cover each path (`tool/test_algolia_keys.py`, 18 pass). I
  also ran a stubbed harness of the real step-6 block on six pairs: good,
  search unchecked, write key twice, search key twice, empty write, bad
  write. Each gave the right line, and no key appeared in the output.

## Checked and OK

- **Overpass QL**, checked against the OSM wiki page "Overpass API/Overpass
  QL":
  - `,i` on value regexes, `[!"highway"]` (since 0.7.53), and quoted keys
    with a colon (`"name:ar"`, `"isced:level"`);
  - the union in `( ... );` and `out center;` (centres for ways and
    relations, coordinates for nodes);
  - `area["ISO3166-1"="EG"][admin_level=2]->.eg` with `(area.eg)`;
  - `[timeout:540]`, inside the 10-minute policy and asserted by a test.

  The wiki says the regex engine is POSIX `regex.h`, and that "Multibyte
  Unicode characters and Unicode character escapes are unsupported". The
  Arabic patterns use only literal byte sequences, alternation and `?` on
  whole groups. They use no `.` on an Arabic letter, no bracket class with
  Arabic, and no `\u` escapes, so they match byte-wise as intended. The
  narrow amenity-only query remains the fallback.
- **SPARQL**:
  - `P31/P279*` with `VALUES ?root {Q3914 Q126807}`, `P17 wd:Q79` and
    `P625`;
  - `FILTER NOT EXISTS { ?item wdt:P576 ... }`;
  - the `ar` and `en` labels through `rdfs:label` with `LANG()` filters,
    which needs no label service;
  - `hint:Query hint:optimizer "None"`, which Phabricator T150950 confirms
    is the WDQS form for turning off the join-order optimizer.

  I could not reach the WDQS manual or the Wikimedia User-Agent policy
  page from here (allowlist).
- **False positives dropped.** I probed `classify_tags` with streets,
  stationery and book shops, `amenity=university`, `building=university`
  named كلية, driving and music schools, Sultan Hassan (both
  `historic=*` and `place_of_worship`), building parts ("مبنى ب", "Block
  A"), pitches, `landuse=residential`, bus platforms, "5 KG rice" and
  "مدرس خصوصي". All were dropped. Language schools, in Arabic and English,
  مجمع مدارس, روضة, KG and isced-tagged schools are kept.
- **Sample import: no regression.** It still keeps 42. `schools.json` is
  byte-for-byte the same list as main's output. Only the summary wording
  is new.
- **Idempotent and safe on failure:**
  - the Overpass and Wikidata fetchers write atomically (`.part` then
    rename);
  - if a server fails or returns too few results, the earlier file is
    kept;
  - Wikidata failing gives a to-do, and the import goes on;
  - the loader never deletes, and Algolia `sync` does not clear the index,
    so nothing in Firestore or search is wiped;
  - the cache records its query id (`broad-2`), so the narrow download
    already on staging is replaced on the next run;
  - `SKIP_SCHOOLS_FETCH=1` skips both fetches;
  - `data/schools/wikidata/` is git-ignored by `data/schools/.gitignore`.
- **Secrets and personal data.** The branch diff has no keys, no emails
  and no tokens. The fetch reports hold counts only, and the import report
  shows only public school names.

## Non-blocking notes

- **N1.** If the broad query fails on every server, the narrow fallback
  overwrites an older broad download. The local file then has fewer
  schools until the next run. Firestore and Algolia are unaffected, since
  nothing is deleted. A possible refinement: keep an existing broad file
  rather than replace it with a narrow one.
- **N2.** The Wikidata cache has no query id, unlike OSM. A future SPARQL
  or class-map change will reuse a download for up to 7 days. Add a
  `"query"` field the same way.
- **N3.** On Wikidata, any class label that matches
  `historic|heritage|monument|military|\bcollege\b` drops the whole item.
  An active school that is also typed "historic building", or a K-12
  school typed "college", would be dropped. The report lists these drops;
  check them after the first real run.
- **N4.** `حضانة` (nursery or daycare) names are kept as kindergartens.
  `amenity=childcare` is still dropped. This is a product question
  (ages 0 to 4), not a bug.
- **N5.** Nursing secondary schools ("مدرسة التمريض ...") are dropped as
  courses. In Egypt some are secondary schools, so this is an owner call.
- **N6.** `query_of` reads the first 4 KB of the download. That is safe
  because `write_json_atomic` writes the header keys before `features`. If
  that order changes, the cache simply refetches.
- **N7.** The broad name-regex clauses scan all named objects in Egypt.
  Their runtime on the public servers is unknown. The narrow fallback and
  the endpoint failover cover the risk.

## Tests

| Check | Status |
|---|---|
| `python3 -m unittest discover -s tools/import_schools` | run here, 64 pass (new assertions added to existing tests) |
| `python3 -m unittest discover -s tool` | run here, 18 pass |
| Functions unit tests (`tsc` with the known 162 lines of stub type noise, then `node --test lib/test/*.test.js`) | run here, 765 pass. `npm test` itself stops at the `tsc` exit code, as on main |
| `bash -n tool/cloud_setup.sh` and shellcheck 0.10.0 | clean |
| Sample import | 42 kept, identical to main |
| Real Overpass broad query, real Wikidata SPARQL, real Algolia key check | written, not run here (no internet to those hosts) |
