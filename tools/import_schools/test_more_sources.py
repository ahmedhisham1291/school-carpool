"""Tests for the wider school sources (schools-more): the broad Overpass
query, what counts as a school (classify_tags), names from other tags, and
the Wikidata download. Fixtures only, no network.

Run: python3 -m unittest discover -s tools/import_schools -v
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fetch_osm_schools as osm  # noqa: E402
import fetch_wikidata_schools as wd  # noqa: E402
from schools_import import classify_tags, name_says_school, recover_name, run, summary_text  # noqa: E402


class BroadQueryTest(unittest.TestCase):
    def test_clauses(self) -> None:
        q = osm.schools_query()
        self.assertTrue(q.startswith(f"[out:json][timeout:{osm.QUERY_TIMEOUT_S}];\n"))
        self.assertIn('area["ISO3166-1"="EG"][admin_level=2]->.eg;', q)
        for clause in (
            'nwr["amenity"~"^(school|kindergarten)$"](area.eg);',
            'nwr["education"~"^(school|kindergarten)$"](area.eg);',
            'nwr["building"~"^(school|kindergarten)$"]["name"](area.eg);',
            'nwr["building"~"^(school|kindergarten)$"]["name:ar"](area.eg);',
            'nwr["school"]["name:en"](area.eg);',
            'nwr["isced:level"]["name"](area.eg);',
            'nwr["name"~"^(مجمع )?(ال)?(مدرس|مدارس)|^(روض|حضان)"][!"highway"](area.eg);',
            'nwr["name:en"~"school|kindergarten",i][!"highway"](area.eg);',
            'nwr["name"~"(^|[^A-Za-z])KG([^A-Za-z]|$)"][!"highway"](area.eg);',
        ):
            self.assertIn(clause, q)
        # One union, one output with node coordinates and way/relation centres.
        self.assertEqual(q.count("(\n"), 1)
        self.assertTrue(q.endswith(");\nout center;\n"))
        self.assertEqual(sum(q.count(f'nwr["{k}"~') for k in osm.NAME_KEYS), 9)  # 3 name regexes x 3 name keys

    def test_a_download_by_another_query_is_not_reused(self) -> None:
        import datetime as dt

        recent = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            old = osm.schools_geojson({"elements": []}, recent, "x")
            del old["query"]  # the first version wrote no query id
            osm.write_json_atomic(out / osm.SCHOOLS_FILE, old)
            self.assertEqual(osm.query_of(out / osm.SCHOOLS_FILE), "")
            calls: list[str] = []
            original = osm.overpass

            def failing(*args, **kwargs):
                calls.append("asked")
                raise osm.FetchError("offline in tests")

            osm.overpass = failing
            try:
                code = osm.main(["--out", str(out), "--boundaries-out", str(out / "b"), "--max-age-days", "7"])
            finally:
                osm.overpass = original
            self.assertEqual(code, 1)  # it tried to download again (broad, then narrow)
            self.assertEqual(calls, ["asked", "asked"])
            osm.write_json_atomic(out / osm.SCHOOLS_FILE, osm.schools_geojson({"elements": []}, recent, "x"))
            self.assertEqual(osm.query_of(out / osm.SCHOOLS_FILE), osm.QUERY_ID)

    def test_narrow_fallback_is_the_original_query(self) -> None:
        q = osm.schools_query(broad=False)
        self.assertIn('nwr["amenity"~"^(school|kindergarten)$"](area.eg);', q)
        self.assertNotIn("education", q)


def cls(tags: dict, *names: str) -> tuple[str | None, str]:
    return classify_tags(tags, names or (tags.get("name", ""),))


class ClassifyTest(unittest.TestCase):
    def test_amenity_rules_unchanged(self) -> None:
        self.assertEqual(cls({"amenity": "school", "name": "Cairo American College"}), ("school", "amenity"))
        self.assertEqual(cls({"amenity": "kindergarten"}, ""), ("kindergarten", "amenity"))
        self.assertEqual(cls({"amenity": "university", "name": "مدرسة"})[1], "not_school_university")
        self.assertEqual(cls({"amenity": "driving_school", "name": "مدرسة قيادة"})[1], "not_school_courses")
        self.assertEqual(cls({"amenity": "childcare", "name": "حضانة النور"})[1], "not_school_childcare")

    def test_education_key(self) -> None:
        self.assertEqual(cls({"education": "school", "name": "مدرسة النيل"}), ("school", "education"))
        self.assertEqual(cls({"education": "kindergarten", "name": "Happy Kids"}), ("kindergarten", "education"))
        self.assertEqual(cls({"education": "language_school", "name": "Berlitz"})[1], "not_school_courses")
        self.assertEqual(cls({"education": "university", "name": "Cairo University"})[1], "not_school_university")

    def test_building_school_and_isced(self) -> None:
        self.assertEqual(cls({"building": "school", "name": "مدرسة الزهور"}), ("school", "building"))
        self.assertEqual(cls({"building": "kindergarten", "name": "Little Stars"}), ("kindergarten", "building"))
        self.assertEqual(cls({"building": "school", "name": "مبنى ب"})[1], "building_part")
        self.assertEqual(cls({"building": "school", "name": "كلية التربية"})[1], "not_school_university")
        self.assertEqual(cls({"isced:level": "1;2", "name": "Nile Academy School"})[1], "not_school_courses")
        self.assertEqual(cls({"isced:level": "1;2", "name": "Nile Integrated"}), ("school", "isced"))
        self.assertEqual(cls({"isced:level": "0", "name": "Little Hands"}), ("kindergarten", "isced"))
        self.assertEqual(cls({"isced:level": "6", "name": "Some Institute"})[1], "not_school_university")
        self.assertEqual(cls({"school": "primary", "name": "El Salam"}), ("school", "school_tag"))
        self.assertEqual(cls({"school": "kindergarten", "name": "El Salam"}), ("kindergarten", "school_tag"))

    def test_name_only(self) -> None:
        self.assertEqual(cls({"name": "مدرسة النصر الابتدائية"}), ("school", "name"))
        self.assertEqual(cls({"name": "المدرسة الألمانية"}), ("school", "name"))
        self.assertEqual(cls({"name": "مجمع مدارس الشروق"}), ("school", "name"))
        self.assertEqual(cls({"name": "روضة الأطفال السعيدة"}), ("kindergarten", "name"))
        self.assertEqual(cls({"name": "حضانة النور"}), ("kindergarten", "name"))
        self.assertEqual(cls({"name": "Modern English School"}), ("school", "name"))
        self.assertEqual(cls({"name": "Sunshine KG"}), ("kindergarten", "name"))
        self.assertEqual(cls({"name": "Nile Language Schools"}), ("school", "name"))  # Egyptian "language schools" are schools
        # Not school names.
        self.assertEqual(cls({"name": "الروضة"})[1], "not_school_other")  # a place name
        self.assertEqual(cls({"name": "روضة"})[1], "not_school_other")
        self.assertEqual(cls({"name": "Rice 5 KG"})[1], "not_school_other")
        self.assertEqual(cls({"name": "مركز مدرسة اللغات"})[1], "not_school_other")  # does not start with مدرسة
        self.assertEqual(cls({"name": "مدرسة تعليم قيادة السيارات"})[1], "not_school_courses")
        self.assertEqual(cls({"name": "Cairo Music School"})[1], "not_school_courses")
        self.assertEqual(cls({"name": "Ballet School of Cairo"})[1], "not_school_courses")
        self.assertEqual(cls({"name": "مدرسة التمريض"})[1], "not_school_courses")

    def test_named_like_a_school_but_something_else(self) -> None:
        for tags in (
            {"highway": "residential", "name": "شارع المدرسة"},
            {"highway": "bus_stop", "name": "مدرسة النصر"},
            {"historic": "monument", "name": "مدرسة السلطان حسن"},
            {"amenity": "place_of_worship", "name": "مدرسة ومسجد السلطان"},
            {"shop": "stationery", "name": "School Supplies"},
            {"leisure": "pitch", "name": "ملعب مدرسة النيل"},
            {"place": "neighbourhood", "name": "روضة المنيل"},
            {"landuse": "residential", "name": "مدارس الشروق"},
        ):
            self.assertEqual(cls(tags)[1], "not_school_feature", tags)
        # landuse=education is fine.
        self.assertEqual(cls({"landuse": "education", "name": "مدرسة النيل"}), ("school", "name"))

    def test_name_says_school(self) -> None:
        self.assertEqual(name_says_school("مدرســة النور"), "school")
        self.assertEqual(name_says_school("مدرسه النور"), "school")
        self.assertIsNone(name_says_school("مدرسة"))  # the word alone: handled as generic later
        self.assertIsNone(name_says_school(""))


class RecoverNameTest(unittest.TestCase):
    def test_other_tags(self) -> None:
        self.assertEqual(recover_name({"official_name": "مدرسة النيل الرسمية"}), ("مدرسة النيل الرسمية", "official_name"))
        self.assertEqual(recover_name({"alt_name": "Nile School;NS"}), ("Nile School", "alt_name"))
        self.assertEqual(recover_name({"operator": "مدارس الشروق الخاصة"}), ("مدارس الشروق الخاصة", "operator"))
        # The ministry is the operator of thousands of schools: not a name.
        self.assertEqual(recover_name({"operator": "وزارة التربية والتعليم"}), ("", ""))
        self.assertEqual(recover_name({"operator": "مديرية التربية والتعليم بالجيزة"}), ("", ""))
        self.assertEqual(recover_name({"amenity": "school"}), ("", ""))

    def test_through_the_importer(self) -> None:
        doc = {"type": "FeatureCollection", "features": [
            {"type": "Feature", "properties": {"osm_id": 1, "osm_type": "node", "amenity": "school", "official_name": "مدرسة الأمل"},
             "geometry": {"type": "Point", "coordinates": [31.25, 30.05]}},
            {"type": "Feature", "properties": {"osm_id": 2, "osm_type": "node", "amenity": "school", "operator": "وزارة التربية والتعليم"},
             "geometry": {"type": "Point", "coordinates": [31.26, 30.06]}},
        ]}
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "osm").mkdir()
            (Path(tmp) / "osm" / "x.geojson").write_text(json.dumps(doc), encoding="utf-8")
            result = run(Path(tmp))
        self.assertEqual([s.name_ar for s in result.schools], ["مدرسة الأمل"])
        self.assertEqual([d.reason for d in result.dropped], ["no_name"])
        self.assertEqual(result.names_recovered, {"official_name": 1})
        self.assertIn("Names recovered from other tags: official_name 1", summary_text(result))


def binding(qid: str, coord: str, ar: str = "", en: str = "", root: str = "Q3914", type_label: str = "school") -> dict:
    b = {
        "item": {"type": "uri", "value": f"http://www.wikidata.org/entity/{qid}"},
        "coord": {"type": "literal", "value": coord, "datatype": "http://www.opengis.net/ont/geosparql#wktLiteral"},
        "root": {"type": "uri", "value": f"http://www.wikidata.org/entity/{root}"},
        "typeLabel": {"type": "literal", "value": type_label, "xml:lang": "en"},
    }
    if ar:
        b["labelAr"] = {"type": "literal", "value": ar, "xml:lang": "ar"}
    if en:
        b["labelEn"] = {"type": "literal", "value": en, "xml:lang": "en"}
    return b


# A SPARQL JSON answer in the shape the query service returns (values invented).
WIKIDATA_ANSWER = {
    "head": {"vars": ["item", "coord", "labelAr", "labelEn", "root", "typeLabel"]},
    "results": {"bindings": [
        binding("Q100", "Point(31.2357 30.0444)", ar="مدرسة النيل الدولية", en="Nile International School", type_label="international school"),
        binding("Q100", "Point(31.2357 30.0444)", ar="مدرسة النيل الدولية", en="Nile International School", type_label="private school"),
        binding("Q200", "Point(29.9187 31.2001)", en="Little Stars Kindergarten", root="Q126807", type_label="kindergarten"),
        binding("Q300", "Point(31.2560 30.0320)", ar="مدرسة السلطان حسن", type_label="madrasa"),
        binding("Q400", "Point(31.2000 30.0300)", en="Cairo Conservatoire", type_label="music school"),
        binding("Q500", "not a point", en="Broken"),
        binding("Q600", "Point(31.3 30.1)", type_label="school"),  # no label
        {"item": {"type": "uri", "value": "http://example.org/x"}},
    ]},
}


class WikidataTest(unittest.TestCase):
    def test_sparql_text(self) -> None:
        q = wd.SPARQL
        self.assertIn("?item wdt:P17 wd:Q79 .", q)
        self.assertIn("?item wdt:P625 ?coord .", q)
        self.assertIn("VALUES ?root { wd:Q3914 wd:Q126807 }", q)
        self.assertIn("?type wdt:P279* ?root .", q)
        self.assertIn("FILTER NOT EXISTS { ?item wdt:P576 ?dissolved . }", q)
        self.assertIn('FILTER(LANG(?labelAr) = "ar")', q)
        # Country before the class walk, with the optimizer off.
        self.assertLess(q.index("wdt:P17"), q.index("wdt:P279*"))
        self.assertIn('hint:Query hint:optimizer "None"', q)

    def test_point(self) -> None:
        self.assertEqual(wd.parse_point("Point(31.2357 30.0444)"), (30.0444, 31.2357))
        self.assertIsNone(wd.parse_point("Point(200 95)"))
        self.assertIsNone(wd.parse_point(""))

    def test_converter(self) -> None:
        doc = wd.schools_geojson(WIKIDATA_ANSWER, "2026-11-16T10:00:00Z")
        self.assertIn("CC0", doc["license"])
        by_id = {f["properties"]["@id"]: f for f in doc["features"]}
        self.assertEqual(sorted(by_id, key=lambda q: int(q[1:])), ["Q100", "Q200", "Q300", "Q400", "Q600"])
        nile = by_id["Q100"]["properties"]
        self.assertEqual(nile["@source"], "wikidata")
        self.assertEqual(nile["amenity"], "school")
        self.assertEqual(nile["name:ar"], "مدرسة النيل الدولية")
        self.assertEqual(nile["wikidata:classes"], "international school; private school")
        self.assertEqual(by_id["Q100"]["geometry"]["coordinates"], [31.2357, 30.0444])
        self.assertEqual(by_id["Q200"]["properties"]["amenity"], "kindergarten")
        self.assertEqual(by_id["Q300"]["properties"], {**by_id["Q300"]["properties"], "historic": "yes"})
        self.assertEqual(by_id["Q400"]["properties"]["amenity"], "training")

    def test_the_importer_keeps_schools_and_drops_the_rest(self) -> None:
        doc = wd.schools_geojson(WIKIDATA_ANSWER, "2026-11-16T10:00:00Z")
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "wikidata").mkdir()
            (Path(tmp) / "wikidata" / wd.SCHOOLS_FILE).write_text(json.dumps(doc), encoding="utf-8")
            result = run(Path(tmp))
        self.assertEqual(sorted(s.id for s in result.schools), ["wikidata-Q100", "wikidata-Q200"])
        kinds = {s.id: s.kind for s in result.schools}
        self.assertEqual(kinds["wikidata-Q200"], "kindergarten")
        reasons = {d.source_key: d.reason for d in result.dropped}
        self.assertEqual(reasons["wikidata:Q300"], "not_school_feature")
        self.assertEqual(reasons["wikidata:Q400"], "not_school_courses")
        self.assertEqual(reasons["wikidata:Q600"], "no_name")
        self.assertIn("wikidata 5 / 3 / 2 / 2", summary_text(result))

    def test_an_osm_school_linked_to_the_item_takes_its_names(self) -> None:
        osm_doc = {"type": "FeatureCollection", "features": [
            {"type": "Feature",
             "properties": {"osm_id": 7, "osm_type": "way", "amenity": "school", "name": "Nile International School", "wikidata": "Q100"},
             "geometry": {"type": "Point", "coordinates": [31.236, 30.0445]}},
        ]}
        doc = wd.schools_geojson(WIKIDATA_ANSWER, "2026-11-16T10:00:00Z")
        with tempfile.TemporaryDirectory() as tmp:
            for sub, d in (("osm", osm_doc), ("wikidata", doc)):
                (Path(tmp) / sub).mkdir()
                (Path(tmp) / sub / "x.geojson").write_text(json.dumps(d), encoding="utf-8")
            result = run(Path(tmp))
        nile = next(s for s in result.schools if s.id == "osm-w7")
        self.assertEqual(nile.name_ar, "مدرسة النيل الدولية")  # from the Wikidata label
        self.assertEqual(nile.source_keys, ["osm:w7", "wikidata:Q100"])
        self.assertIn("wikidata:Q100", {d.source_key for d in result.dropped if d.reason == "wikidata_linked"})
        self.assertNotIn("wikidata-Q100", {s.id for s in result.schools})

    def test_retry_and_user_agent(self) -> None:
        import io
        import os
        import urllib.error

        seen: list[dict] = []
        waits: list[float] = []

        def post(url: str, body: bytes, headers: dict, timeout: float) -> bytes:
            seen.append(headers)
            self.assertEqual(url, "https://query.wikidata.org/sparql")
            self.assertIn(b"format=json", body)
            if len(seen) == 1:
                raise urllib.error.HTTPError(url, 429, "Too Many", {"Retry-After": "7"}, io.BytesIO(b""))  # type: ignore[arg-type]
            return json.dumps(WIKIDATA_ANSWER).encode()

        os.environ.pop("WIKIDATA_CONTACT", None)
        answer = wd.run_query(post=post, sleep=waits.append, log=lambda _: None)
        self.assertEqual(len(answer["results"]["bindings"]), 8)
        self.assertEqual(waits, [7.0])
        self.assertIn("SchoolCarpoolSchoolsImport/1.0", seen[0]["User-Agent"])
        self.assertEqual(seen[0]["Accept"], "application/sparql-results+json")
        os.environ["WIKIDATA_CONTACT"] = "https://example.org/contact"
        try:
            self.assertIn("https://example.org/contact", wd.user_agent())
        finally:
            os.environ.pop("WIKIDATA_CONTACT", None)

    def test_refused_is_not_retried(self) -> None:
        import io
        import urllib.error

        calls = []

        def post(url: str, body: bytes, headers: dict, timeout: float) -> bytes:
            calls.append(1)
            raise urllib.error.HTTPError(url, 403, "Forbidden", {}, io.BytesIO(b""))  # type: ignore[arg-type]

        with self.assertRaises(wd.FetchError) as ctx:
            wd.run_query(post=post, sleep=lambda _: None, log=lambda _: None)
        self.assertEqual(len(calls), 1)
        self.assertIn("WIKIDATA_CONTACT", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
