"""Tests for the schools-sources work: the per-governorate Overpass split,
Overture Maps Places, the categories switch, the conservative drop rules
and why_missing.py. Fixtures only, no network.

Run: python3 -m unittest discover -s tools/import_schools -v
"""

from __future__ import annotations

import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fetch_osm_places as fp  # noqa: E402
import fetch_osm_schools as osm  # noqa: E402
import fetch_overture_schools as ov  # noqa: E402
import overpass_split as sp  # noqa: E402
import schools_import as si  # noqa: E402
import why_missing as wm  # noqa: E402

NOW = dt.datetime(2026, 11, 16, 12, 0, tzinfo=dt.timezone.utc)


def answer_for(*elements: dict) -> dict:
    return {"elements": list(elements)}


def node(i: int, lat: float, lng: float, **tags: str) -> dict:
    return {"type": "node", "id": i, "lat": lat, "lon": lng, "tags": tags}


class QuerySplitterTest(unittest.TestCase):
    def test_parts_use_relation_ids_when_known(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            b = Path(tmp) / "gov.geojson"
            b.write_text(json.dumps({"features": [{"properties": {"ISO3166-2": "EG-C", "osm_id": 5466227}}]}), encoding="utf-8")
            parts = sp.governorate_areas(b)
        self.assertEqual(len(parts), 27)
        cairo = next(p for p in parts if p.code == "EG-C")
        self.assertEqual(cairo.area, "area(id:3605466227)->.g;")
        giza = next(p for p in parts if p.code == "EG-GZ")
        self.assertEqual(giza.area, 'area["ISO3166-2"="EG-GZ"]["admin_level"="4"]->.g;')
        self.assertEqual(sp.governorate_areas(None)[0].code, "EG-ALX")

    def test_school_query_per_governorate(self) -> None:
        q = osm.schools_query(sp.PART_TIMEOUT_S, True, "area(id:3605466227)->.g;", "g", osm.amenity_values({}))
        self.assertTrue(q.startswith("[out:json][timeout:180];\narea(id:3605466227)->.g;\n"))
        self.assertIn('nwr["amenity"~"^(school|kindergarten|childcare)$"](area.g);', q)
        self.assertNotIn("area.eg", q)
        self.assertTrue(q.endswith(");\nout center;\n"))
        self.assertLessEqual(sp.PART_TIMEOUT_S, 180)

    def test_categories_change_the_query_and_its_id(self) -> None:
        self.assertEqual(osm.amenity_values({"nursery": False}), ("school", "kindergarten"))
        self.assertEqual(osm.amenity_values({"university": True}), ("school", "kindergarten", "childcare", "university", "college"))
        self.assertEqual(osm.query_id_for("split-1", ("school", "kindergarten")), "split-1")
        self.assertEqual(osm.query_id_for("split-1", ("school", "kindergarten", "childcare")), "split-1+childcare")

    def test_places_query_per_governorate(self) -> None:
        q = fp.part_query('area["ISO3166-2"="EG-C"]["admin_level"="4"]->.g;')
        self.assertIn('rel["boundary"="administrative"]["admin_level"~"^(5|6|7|8|9|10)$"](area.g);\nout geom;', q)
        self.assertIn('nwr["place"~"^(suburb|quarter|neighbourhood)$"]["name:ar"](area.g);', q)
        self.assertTrue(q.endswith("out center;\n"))


def convert(answer: dict, stamp: str, server: str) -> dict:
    return osm.schools_geojson(answer, stamp, server, "broad-3")


class PartialSuccessTest(unittest.TestCase):
    PARTS = [sp.Part("EG-ALX", "alexandria", "a1;", "ALX"), sp.Part("EG-C", "cairo", "a2;", "C"), sp.Part("EG-GZ", "giza", "a3;", "GZ")]

    def run_parts(self, folder: Path, answers: dict[str, list], **kwargs) -> tuple[sp.SplitResult, list[str], list[float]]:
        asked: list[str] = []
        waits: list[float] = []

        def fetch(query: str, endpoints: list[str], prefer: str | None) -> tuple[dict, str]:
            asked.append(query)
            outcome = answers[query].pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome, "https://b/api"

        result = sp.fetch_parts(
            self.PARTS, lambda p: p.area, convert, folder, query_id="broad-3", fetch=fetch, endpoints=["https://a/api", "https://b/api"],
            now=NOW, sleep=waits.append, log=lambda _: None, **kwargs,
        )
        return result, asked, waits

    def test_second_pass_older_file_and_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            # An older Giza file from last week.
            old = convert(answer_for(node(9, 30.0, 31.2, amenity="school", name="مدرسة الجيزة")), "2026-11-09T08:00:00Z", "https://a/api")
            old["query"] = "broad-3"
            osm.write_json_atomic(sp.part_path(folder, "EG-GZ"), old)
            busy = osm.FetchError("no Overpass server gave a complete answer")
            result, asked, waits = self.run_parts(
                folder,
                {
                    "a1;": [answer_for(node(1, 31.2, 29.9, amenity="school", name="مدرسة الإسكندرية"))],
                    # Cairo: busy, then fine in the second pass; a school on
                    # the border is also in Giza's answer.
                    "a2;": [busy, answer_for(node(2, 30.05, 31.23, amenity="school", name="مدرسة القاهرة"), node(3, 30.0, 31.21, amenity="school", name="مدرسة الحدود"))],
                    "a3;": [busy, busy],
                },
            )
            self.assertEqual(asked, ["a1;", "a2;", "a3;", "a2;", "a3;"])
            self.assertEqual(waits, [sp.SECOND_PASS_PAUSE_S])
            status = {s.code: s for s in result.statuses}
            self.assertEqual(status["EG-ALX"].status, sp.STATUS_NEW)
            self.assertEqual(status["EG-C"].status, sp.STATUS_NEW)
            self.assertEqual(status["EG-GZ"].status, sp.STATUS_OLD)
            self.assertEqual(status["EG-GZ"].fetched_at, "2026-11-09T08:00:00Z")
            self.assertFalse(result.complete)
            self.assertEqual(result.last_server, "https://b/api")
            merged = sp.merge_features(result.collections.values())
            self.assertEqual(sorted(f["properties"]["osm_id"] for f in merged), [1, 2, 3, 9])
            lines = sp.status_lines(result)
            self.assertIn("- EG-GZ giza: download failed, older file used 2026-11-09, 1 features (no Overpass server gave a complete answer)", lines)
            self.assertIn("1 partly from older files (oldest 2026-11-09), 0 with pieces missing", sp.summary_line(result))
            # Each new part is on disk with its own date.
            self.assertEqual(json.loads(sp.part_path(folder, "EG-C").read_text())["fetched_at"], "2026-11-16T12:00:00Z")

    def test_recent_parts_are_not_asked_again_and_duplicates_merge(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            for code, i in (("EG-ALX", 1), ("EG-C", 2)):
                doc = convert(answer_for(node(i, 30.0, 31.0, amenity="school", name="مدرسة"), node(7, 30.0, 31.0, amenity="school", name="مدرسة الحدود")), "2026-11-15T08:00:00Z", "x")
                doc["query"] = "broad-3"
                osm.write_json_atomic(sp.part_path(folder, code), doc)
            result, asked, _ = self.run_parts(folder, {"a3;": [osm.FetchError("x"), osm.FetchError("x")]}, max_age_days=7)
            self.assertEqual(asked, ["a3;", "a3;"])
            self.assertEqual([s.status for s in result.statuses], [sp.STATUS_RECENT, sp.STATUS_RECENT, sp.STATUS_MISSING])
            self.assertEqual(result.usable, 2)
            self.assertIn("download failed, NO data", sp.status_lines(result)[2])
            self.assertEqual(len(sp.merge_features(result.collections.values())), 3)  # node 7 once

    def test_an_empty_answer_is_a_failure_and_the_budget_stops_requests(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            clock = iter([0.0, 0.0] + [10_000.0] * 10)
            result, asked, waits = self.run_parts(
                Path(tmp), {"a1;": [answer_for()], "a2;": []}, budget_s=100, clock=lambda: next(clock)
            )
            self.assertEqual(asked, ["a1;"])  # Cairo and Giza: no time left, no second pass
            self.assertEqual(waits, [])
            self.assertEqual([s.status for s in result.statuses], [sp.STATUS_MISSING, sp.STATUS_SKIPPED, sp.STATUS_SKIPPED])
            self.assertIn("NO data", sp.status_lines(result)[1])

    def test_places_part_keeps_polygons_and_points_apart(self) -> None:
        square = [[31.0, 30.0], [31.1, 30.0], [31.1, 30.1], [31.0, 30.1], [31.0, 30.0]]
        rel = {
            "type": "relation", "id": 40, "tags": {"boundary": "administrative", "admin_level": "8", "name": "حي", "place": "suburb"},
            "members": [{"type": "way", "role": "outer", "geometry": [{"lat": p[1], "lon": p[0]} for p in square]}],
            "center": {"lat": 30.05, "lon": 31.05},
        }
        part = fp.part_geojson(answer_for(rel, node(41, 30.05, 31.05, place="neighbourhood", name="حارة")), "t", "s")
        merged = sp.merge_features([part, part])
        admin, points, per_level, per_kind = fp.split_merged(merged, "t", "s", fp.QUERY_ID)
        self.assertEqual(per_level, {8: 1})
        # The relation is both a boundary (polygon) and a named suburb (its centre).
        self.assertEqual(per_kind, {"neighbourhood": 1, "suburb": 1})
        self.assertEqual(len(admin["features"]), 1)
        self.assertEqual(admin["query"], "split-1")


OVERTURE_ROWS = [
    {"id": "08f1", "lon": 31.2357, "lat": 30.0444, "names": json.dumps({"primary": "Nile Language School", "common": {"ar": "مدرسة النيل للغات", "en": "Nile Language School"}}),
     "category": "private_school", "alternates": None, "basic_category": "place_of_learning", "confidence": 0.91, "operating_status": "open",
     "sources": json.dumps([{"dataset": "meta", "record_id": "1"}, {"dataset": "Microsoft", "record_id": "2"}]), "addresses": json.dumps([{"locality": "Cairo", "country": "EG"}])},
    # MAP written as a list of {key, value}; matched through an alternate category.
    {"id": "08f2", "lon": 31.21, "lat": 29.99, "names": {"primary": "حضانة الأمل", "common": [{"key": "ar", "value": "حضانة الأمل"}]},
     "category": "community_center", "alternates": json.dumps(["day_care_preschool"]), "basic_category": None, "confidence": 0.55, "operating_status": None,
     "sources": json.dumps([{"dataset": "meta"}]), "addresses": None},
    {"id": "08f3", "lon": 31.3, "lat": 30.1, "names": json.dumps({"primary": "Old School"}), "category": "school", "alternates": None,
     "basic_category": None, "confidence": 0.0, "operating_status": "permanently_closed", "sources": "[]", "addresses": "[]"},
    {"id": "08f4", "lon": 31.3, "lat": 30.1, "names": json.dumps({"primary": "Maybe School"}), "category": "school", "alternates": None,
     "basic_category": None, "confidence": 0.3, "operating_status": "open", "sources": "[]", "addresses": "[]"},
    # Aqaba, Jordan: inside Egypt's box.
    {"id": "08f5", "lon": 35.0, "lat": 29.53, "names": json.dumps({"primary": "Aqaba School"}), "category": "school", "alternates": None,
     "basic_category": None, "confidence": 0.9, "operating_status": "open", "sources": "[]", "addresses": json.dumps([{"country": "JO"}])},
    {"id": "08f6", "lon": 31.24, "lat": 30.05, "names": json.dumps({"primary": "Cairo University"}), "category": "college_university", "alternates": None,
     "basic_category": None, "confidence": 0.95, "operating_status": "open", "sources": "[]", "addresses": "[]"},
    {"id": "08f7", "lon": 31.25, "lat": 30.06, "names": json.dumps({"primary": "English Courses Center"}), "category": "high_school", "alternates": None,
     "basic_category": None, "confidence": 0.9, "operating_status": "open", "sources": "[]", "addresses": "[]"},
]


class OvertureTest(unittest.TestCase):
    def test_sql(self) -> None:
        sql = ov.overture_sql("2026-10-21.0", ov.categories_for({}))
        self.assertIn("read_parquet('s3://overturemaps-us-west-2/release/2026-10-21.0/theme=places/type=place/*', hive_partitioning = 1)", sql)
        self.assertIn("bbox.xmin BETWEEN 24.6 AND 37.1", sql)
        self.assertIn("taxonomy.primary IN (", sql)
        self.assertIn("'kindergarten'", sql)
        self.assertIn("'child_care_and_day_care'", sql)
        self.assertNotIn("college_university", sql)
        self.assertIn("college_university", ov.overture_sql("r", ov.categories_for({"university": True})))
        self.assertNotIn("categories.primary", sql)  # removed from the schema in Sept 2026

    def test_latest_release(self) -> None:
        self.assertEqual(ov.latest_release(lambda _url: b'{"latest": "2026-11-18.0"}'), "2026-11-18.0")
        self.assertEqual(ov.latest_release(lambda _url: b"not json"), ov.FALLBACK_RELEASE)

    def test_converter(self) -> None:
        doc, stats = ov.to_geojson(OVERTURE_ROWS, 0.5, "2026-11-16T12:00:00Z", "2026-10-21.0")
        by_id = {f["properties"]["@id"]: f for f in doc["features"]}
        self.assertEqual(sorted(by_id), ["08f1", "08f2", "08f6", "08f7"])
        p = by_id["08f1"]["properties"]
        self.assertEqual((p["@source"], p["name:ar"], p["name:en"], p["overture:category"]), ("overture", "مدرسة النيل للغات", "Nile Language School", "private_school"))
        self.assertEqual(p["overture:datasets"], "Microsoft;meta")
        self.assertEqual(p["addr:city"], "Cairo")
        self.assertEqual(by_id["08f1"]["geometry"]["coordinates"], [31.2357, 30.0444])
        self.assertEqual(by_id["08f2"]["properties"]["overture:category"], "day_care_preschool")
        self.assertEqual(by_id["08f2"]["properties"]["name:ar"], "حضانة الأمل")
        self.assertEqual(stats["skipped"], {"permanently closed": 1, "confidence below 0.5": 1, "address in another country": 1})
        self.assertEqual(stats["band"]["0.9+"], 4)
        self.assertEqual(stats["dataset"], {"meta": 2, "Microsoft": 1})
        self.assertIn("CDLA Permissive 2.0", doc["license"])
        self.assertIn("overturemaps.org", ov.report_text("t", "r", 0.5, stats))

    def test_through_the_importer_with_dedupe(self) -> None:
        doc, _ = ov.to_geojson(OVERTURE_ROWS, 0.5, "2026-11-16T12:00:00Z", "2026-10-21.0")
        # The jordanian row would also be stopped by the importer if it came without a country.
        self.assertTrue(si.beyond_border(29.53, 35.0))
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "overture").mkdir()
            (folder / "overture" / "raw").mkdir()
            (folder / "overture" / "raw" / "egypt_places_raw.json").write_text("{}", encoding="utf-8")  # not read
            osm.write_json_atomic(folder / "overture" / ov.OUT_FILE, doc)
            (folder / "osm").mkdir()
            osm.write_json_atomic(
                folder / "osm" / osm.SCHOOLS_FILE,
                osm.schools_geojson(answer_for(node(11, 30.0446, 31.2359, amenity="school", name="مدرسة النيل للغات")), "t", "x"),
            )
            result = si.run(folder)
        keys = {k: s.id for s in result.schools for k in s.source_keys}
        # Same name 25 m apart: the Overture place joins the OSM school, which stays the main entry.
        self.assertEqual(keys["overture:08f1"], "osm-n11")
        self.assertEqual(keys["overture:08f2"], "overture-08f2")
        self.assertEqual(next(s for s in result.schools if s.id == "overture-08f2").kind, "kindergarten")
        reasons = {d.source_key: d.reason for d in result.dropped}
        self.assertEqual(reasons["overture:08f6"], "not_school_university")
        self.assertEqual(reasons["overture:08f7"], "not_school_courses")
        self.assertEqual(result.read_by_source["overture"], 4)
        self.assertIn("overture 4 / 2 / 1 / 2", si.summary_text(result))

    def test_overture_is_never_the_main_entry(self) -> None:
        def school(source: str, sid: str, lat: float | None) -> si.School:
            return si.School(
                f"{source}-{sid}", source, sid, [f"{source}:{sid}"], "مدرسة النيل", "", "school",
                "cairo", "given", "", "", lat, None if lat is None else 31.2,
            )

        merged = si._merge([school("overture", "08f9", 30.0), school("wikidata", "Q1", None)])
        self.assertEqual(merged.source, "wikidata")
        self.assertEqual(merged.lat, 30.0)  # the Overture pin is still used
        merged = si._merge([school("overture", "08f9", 30.0), school("osm", "w5", 30.0)])
        self.assertEqual(merged.id, "osm-w5")

    def test_main_without_duckdb_or_from_raw(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            raw = {"fetched_at": "2026-11-16T12:00:00Z", "query": ov.QUERY_ID + "+" + "+".join(ov.categories_for({})),
                   "release": "2026-10-21.0", "rows": OVERTURE_ROWS}
            osm.write_json_atomic(out / "raw" / ov.RAW_FILE, raw)
            cats = out / "categories.json"
            cats.write_text('{"categories": {"nursery": true, "university": false}}', encoding="utf-8")
            self.assertEqual(ov.main(["--out", str(out), "--from-raw", "--min-confidence", "0.8", "--categories", str(cats)]), 0)
            doc = json.loads((out / ov.OUT_FILE).read_text(encoding="utf-8"))
            self.assertEqual(sorted(f["properties"]["@id"] for f in doc["features"]), ["08f1", "08f6", "08f7"])
            original = ov.run_duckdb

            def missing(_sql: str) -> list[dict]:
                raise ov.DuckDBMissing("No module named 'duckdb'")

            ov.run_duckdb = missing
            try:
                self.assertEqual(ov.main(["--out", str(out / "new"), "--release", "2026-10-21.0", "--categories", str(cats)]), 3)
            finally:
                ov.run_duckdb = original


class CategoriesTest(unittest.TestCase):
    def tearDown(self) -> None:
        si.set_categories(None)

    def test_defaults_and_file(self) -> None:
        self.assertEqual(si.CATEGORIES, {"school": True, "kindergarten": True, "nursery": True, "university": False})
        repo_file = Path(__file__).resolve().parents[2] / "data" / "schools" / "categories.json"
        self.assertEqual(si.load_categories(repo_file)["university"], False)  # owner decision, 16 Nov 2026
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "c.json"
            f.write_text('{"categories": {"university": true, "school": false}}', encoding="utf-8")
            self.assertEqual(si.load_categories(f), {"school": True, "kindergarten": True, "nursery": True, "university": True})
            self.assertEqual(si.load_categories(Path(tmp) / "none.json")["university"], False)

    def test_university_switch(self) -> None:
        tags = {"amenity": "university", "name": "Cairo University"}
        self.assertEqual(si.classify_tags(tags, ("Cairo University",)), (None, "not_school_university"))
        si.set_categories({"university": True})
        self.assertEqual(si.classify_tags(tags, ("Cairo University",)), ("university", "amenity"))
        self.assertEqual(si.classify_tags({"amenity": "college", "name": "Higher Institute"}, ("Higher Institute",)), ("university", "amenity"))
        self.assertEqual(si.classify_overture("college_university", ("Cairo University",)), ("university", "overture"))
        self.assertEqual(si.classify_tags({"isced:level": "6", "name": "X"}, ("X",)), ("university", "isced"))


def cls(tags: dict) -> tuple[str | None, str]:
    return si.classify_tags(tags, (tags.get("name", ""),))


class ConservativeRulesTest(unittest.TestCase):
    def test_real_world_school_names_are_kept(self) -> None:
        for name in (
            "British International School", "American School of Alexandria", "Nile Language School",
            "Cairo English School", "STEM High School for Boys", "مدرسة المتفوقين في العلوم والتكنولوجيا STEM",
            "مدرسة النصر للغات", "Modern Academy School", "Little Stars Nursery",
        ):
            self.assertIsNotNone(cls({"name": name})[0], name)

    def test_azhar_institutes_are_schools(self) -> None:
        for name in ("معهد أزهري ابتدائي", "المعهد الأزهري الإعدادي بنين", "معهد فتيات الأزهر الثانوي", "Al-Azhar Institute for Girls"):
            self.assertEqual(cls({"name": name}), ("school", "azhar"), name)
        # However the mapper tagged it.
        self.assertEqual(cls({"amenity": "college", "name": "معهد أزهري ابتدائي"}), ("school", "azhar"))
        # Al-Azhar University and its faculties stay out; a street named after an institute too.
        self.assertIsNone(cls({"amenity": "college", "name": "كلية الهندسة جامعة الأزهر"})[0])
        self.assertIsNone(cls({"name": "جامعة الأزهر"})[0])
        self.assertEqual(cls({"highway": "residential", "name": "شارع المعهد الأزهري"})[1], "not_school_feature")
        # Azhar institutes have stage words: primary and secondary at one site are not merged.
        self.assertEqual(si.name_tags("المعهد الأزهري الابتدائي")[0], frozenset({"primary"}))

    def test_schools_mapped_with_another_education_tag(self) -> None:
        self.assertEqual(cls({"amenity": "language_school", "name": "مدرسة النصر للغات"}), ("school", "amenity_name"))
        self.assertEqual(cls({"amenity": "language_school", "name": "Berlitz Language Center"})[1], "not_school_courses")
        self.assertEqual(cls({"amenity": "language_school", "name": "Berlitz Language Institute School"})[1], "not_school_courses")
        self.assertEqual(cls({"amenity": "prep_school", "name": "Cairo English School"}), ("school", "amenity_name"))
        self.assertEqual(cls({"amenity": "college", "name": "Collège de la Salle"}), ("school", "amenity_name"))
        self.assertEqual(cls({"amenity": "driving_school", "name": "مدرسة القيادة"})[1], "not_school_courses")
        self.assertEqual(cls({"amenity": "college", "name": "Victoria College"})[1], "not_school_college")
        self.assertEqual(cls({"office": "educational_institution", "name": "International School"}), ("school", "name"))
        self.assertEqual(cls({"office": "government", "name": "مدرسة النيل"})[1], "not_school_feature")
        # Unchanged: a historic madrasa mosque and a school's pitch stay out.
        self.assertEqual(cls({"building": "yes", "religion": "muslim", "name": "مدرسة السلطان"})[1], "not_school_feature")
        self.assertEqual(cls({"leisure": "pitch", "name": "Nefertari International School"})[1], "not_school_feature")

    def test_neighbours_inside_the_box(self) -> None:
        for lat, lng in ((29.53, 35.0), (31.5, 34.45), (28.4, 36.5), (21.8, 31.5), (30.0, 24.9)):
            self.assertFalse(si.in_egypt(lat, lng), (lat, lng))
        for lat, lng in ((29.49, 34.89), (31.28, 34.23), (27.25, 33.81), (22.2, 36.6), (31.58, 25.15), (30.04, 31.24)):
            self.assertTrue(si.in_egypt(lat, lng), (lat, lng))


class WhyMissingTest(unittest.TestCase):
    def make(self, folder: Path) -> si.Result:
        (folder / "osm").mkdir()
        osm.write_json_atomic(
            folder / "osm" / osm.SCHOOLS_FILE,
            osm.schools_geojson(
                answer_for(
                    node(1, 30.04, 31.23, amenity="school", name="مدرسة النيل للغات", **{"name:en": "Nile Language School"}),
                    node(2, 30.0401, 31.2301, amenity="school", name="مدرسة  النيل  للغات"),  # same school, merged
                    node(3, 30.05, 31.24, amenity="university", name="جامعة عين شمس"),
                    node(4, 30.06, 31.25, amenity="school", name="مدرسة عبد الله النديم الإعدادية"),
                ),
                "t",
                "x",
            ),
        )
        return si.run(folder)

    def test_verdicts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = self.make(Path(tmp))
        lines, verdicts = wm.check(result, ["Nile Language School", "مدرسه النيل لغات", "جامعة عين شمس", "مدرسة عبدالله النديم", "El Alsson"], ["EG-SIN"])
        text = "\n".join(lines)
        self.assertIn("Nile Language School:\n  - OpenStreetMap n1", text)
        self.assertIn(": kept as osm-n1", text)
        self.assertIn(": merged into osm-n1", text)
        self.assertIn("dropped: University", text)
        self.assertIn("مدرسة عبدالله النديم:\n  - OpenStreetMap n4", text)  # spacing in "عبد الله"
        self.assertIn("El Alsson: not in any source", text)
        self.assertIn("no OpenStreetMap data for EG-SIN", text)
        self.assertEqual(verdicts, {"kept": 3, "dropped": 1, "not found": 1})
        self.assertEqual(wm.summary(verdicts, 5), "Names check: 5 names: 3 kept, 0 merged, 1 dropped, 1 not found (kept/merged = in the list)")

    def test_loose_matching(self) -> None:
        self.assertEqual(wm.score("مدرسة النيل للغات", "مدرسه النيل لغات"), 1.0)
        self.assertEqual(wm.score("المعهد الأزهري", "معهد ازهري"), 1.0)
        self.assertGreaterEqual(wm.score("Nile School", "Nile Language School"), 0.8)
        self.assertGreaterEqual(wm.score("عبدالله النديم", "عبد الله النديم"), 0.7)
        self.assertLess(wm.score("Nile School", "Delta School"), wm.MIN_SCORE)

    def test_cli_with_a_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            self.make(folder)
            names = folder / "check.txt"
            names.write_text("# names the owner expects\nNile Language School\nEl Alsson\n", encoding="utf-8")
            import contextlib
            import io

            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                code = wm.main(["--input", str(folder), "--file", str(names), "--summary-only"])
            out = buffer.getvalue()
        self.assertEqual(code, 0)
        self.assertNotIn("Nile Language School", out)  # in the list: not shown in the summary
        self.assertIn("El Alsson: not in any source", out)
        self.assertTrue(out.strip().endswith("1 kept, 0 merged, 0 dropped, 1 not found (kept/merged = in the list)"))


if __name__ == "__main__":
    unittest.main()
