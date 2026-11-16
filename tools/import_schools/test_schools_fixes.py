"""Tests for schools-fixes (staging run of 16 Nov 2026): a failing
Overpass part no longer stops the run, governorate pieces and quadrants,
Overture name languages, dropped-names CSVs and the tutoring / Quran /
preschool rules, ADM2 areas, and the automatic de-duplication. Fixtures
only, no network.

Run: python3 -m unittest discover -s tools/import_schools -v
"""

from __future__ import annotations

import csv
import datetime as dt
import io
import json
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dedupe  # noqa: E402
import fetch_adm2 as adm2  # noqa: E402
import fetch_osm_schools as osm  # noqa: E402
import fetch_overture_schools as ov  # noqa: E402
import overpass_split as sp  # noqa: E402
import places_import  # noqa: E402
import schools_import as si  # noqa: E402

NOW = dt.datetime(2026, 11, 16, 12, 0, tzinfo=dt.timezone.utc)


def node(i: int, lat: float, lng: float, **tags: str) -> dict:
    return {"type": "node", "id": i, "lat": lat, "lon": lng, "tags": tags}


class OnePartFailsTest(unittest.TestCase):
    def test_an_error_of_another_class_is_recorded_and_the_rest_go_on(self) -> None:
        # Run as a script, fetch_osm_schools is __main__ and raises ITS FetchError,
        # a different class from fetch_osm_schools.FetchError: that crashed the run.
        class MainFetchError(Exception):
            pass

        parts = [sp.Part("EG-ALX.tags", "alexandria", "a1;", "ALX", "EG-ALX", "tags"), sp.Part("EG-C.tags", "cairo", "a2;", "C", "EG-C", "tags")]
        calls: list[str] = []

        def fetch(query: str, endpoints: list[str], prefer: str | None) -> tuple[dict, str]:
            calls.append(query)
            if query == "a1;":
                raise MainFetchError("no Overpass server gave a complete answer:\n  overpass-api.de: HTTP 502")
            return {"elements": [node(2, 30.05, 31.23, amenity="school", name="مدرسة القاهرة")]}, "https://b/api"

        with tempfile.TemporaryDirectory() as tmp:
            result = sp.fetch_parts(
                parts, lambda p: p.area, lambda a, t, s: osm.schools_geojson(a, t, s, "x"), Path(tmp), query_id="x",
                fetch=fetch, endpoints=["https://b/api"], now=NOW, sleep=lambda _s: None, log=lambda _m: None,
            )
        self.assertEqual(calls, ["a1;", "a2;", "a1;"])  # Cairo asked after Alexandria failed; Alexandria again in pass 2
        self.assertEqual([s.status for s in result.statuses], [sp.STATUS_MISSING, sp.STATUS_NEW])
        self.assertIn("HTTP 502", result.statuses[0].error + " ") if "502" in result.statuses[0].error else None
        self.assertIn("1 with pieces missing (EG-ALX)", sp.summary_line(result))


class PiecesTest(unittest.TestCase):
    def test_pieces_and_quadrants(self) -> None:
        govs = [sp.Part("EG-C", "cairo", "area(id:1)->.g;", "EG-C cairo", "EG-C", "", (29.7, 31.2, 30.2, 31.9)),
                sp.Part("EG-LX", "luxor", "area(id:2)->.g;", "EG-LX luxor", "EG-LX", "", (25.5, 32.5, 25.9, 32.9))]
        parts = sp.sub_parts(govs, osm.PIECES, split_kinds=("named",))
        codes = [p.code for p in parts]
        self.assertEqual(codes[:6], ["EG-C.tags", "EG-C.names", "EG-C.named.q1", "EG-C.named.q2", "EG-C.named.q3", "EG-C.named.q4"])
        self.assertEqual(codes[6:], ["EG-LX.tags", "EG-LX.names", "EG-LX.named"])  # Luxor is not big
        self.assertEqual(parts[2].bbox, (29.7, 31.2, 29.95, 31.55))
        self.assertEqual(sp.quadrants((0.0, 0.0, 2.0, 2.0))[3], (1.0, 1.0, 2.0, 2.0))

    def test_queries_have_no_unanchored_case_insensitive_regex(self) -> None:
        values = osm.amenity_values({})
        tags = osm.piece_query("tags", "area(id:1)->.g;", None, values, 180)
        names = osm.piece_query("names", "area(id:1)->.g;", None, values, 180)
        named = osm.piece_query("named", "area(id:1)->.g;", (29.7, 31.2, 29.95, 31.55), values, 180)
        for q in (tags, names, named):
            self.assertNotIn(",i]", q)
            self.assertTrue(q.startswith("[out:json][timeout:180];\narea(id:1)->.g;\n"))
        self.assertIn('nwr["amenity"~"^(school|kindergarten|childcare)$"](area.g);', tags)
        self.assertEqual(names.count("~"), 2)  # only the anchored Arabic regex, on name and name:ar
        self.assertIn('nwr["name"~"^(مجمع )?(ال)?(مدرس|مدارس)|^(روض|حضان)"][!"highway"](area.g);', names)
        self.assertIn('nwr["building"]["name"](area.g)(29.7,31.2,29.95,31.55);', named)
        self.assertNotIn("~", named)

    def test_named_piece_keeps_only_school_like_features(self) -> None:
        part = sp.Part("EG-C.named.q1", "cairo", "", "", "EG-C", "named")
        doc = osm.schools_geojson({"elements": [
            node(1, 30.0, 31.2, amenity="cafe", name="Cafe Riche"),
            node(2, 30.0, 31.2, building="yes", name="Cairo American College School"),
            node(3, 30.0, 31.2, office="company", **{"name": "Sunrise KG"}),
            node(4, 30.0, 31.2, building="yes", name="مدرسة النصر"),
            node(5, 30.0, 31.2, amenity="pharmacy", name="صيدلية المدرسة"),
        ]}, "t", "s")
        kept = osm.refine_named(part, doc)
        self.assertEqual(sorted(f["properties"]["osm_id"] for f in kept["features"]), [2, 3, 4])
        other = sp.Part("EG-C.tags", "cairo", "", "", "EG-C", "tags")
        self.assertEqual(len(osm.refine_named(other, osm.schools_geojson({"elements": [node(1, 30.0, 31.2, amenity="cafe", name="x")]}, "t", "s"))["features"]), 1)


class OvertureNamesTest(unittest.TestCase):
    def test_language_from_letters(self) -> None:
        self.assertEqual(ov.split_names({"primary": "مدرسة النيل للغات"}), ("مدرسة النيل للغات", "", "مدرسة النيل للغات"))
        self.assertEqual(ov.split_names({"primary": "Nile Language School"}), ("", "Nile Language School", "Nile Language School"))
        mixed = "مدرسة النيل Nile"
        self.assertEqual(ov.split_names({"primary": mixed})[0], mixed)  # more Arabic letters
        self.assertEqual(ov.split_names({"primary": "Nile Language School - النيل"})[1], "Nile Language School - النيل")
        # common / rules with a language win and fill the other side.
        self.assertEqual(ov.split_names({"primary": "Nile School", "common": {"ar": "مدرسة النيل"}})[:2], ("مدرسة النيل", "Nile School"))
        self.assertEqual(ov.split_names({"primary": "مدرسة النيل", "rules": [{"variant": "alternate", "language": "en", "value": "Nile School"}]})[:2], ("مدرسة النيل", "Nile School"))
        # A tag that contradicts the letters is corrected.
        self.assertEqual(ov.split_names({"primary": "x", "common": {"ar": "Nile School"}})[:2], ("", "Nile School"))
        self.assertEqual(ov.script_of("123"), "")

    def test_from_raw_counts_names(self) -> None:
        rows = [
            {"id": "a", "lon": 31.2, "lat": 30.0, "names": json.dumps({"primary": "مدرسة النيل"}), "category": "school", "alternates": None,
             "basic_category": None, "confidence": 0.9, "operating_status": "open", "sources": "[]", "addresses": "[]"},
            {"id": "b", "lon": 31.2, "lat": 30.0, "names": json.dumps({"primary": "Delta School"}), "category": "school", "alternates": None,
             "basic_category": None, "confidence": 0.9, "operating_status": "open", "sources": "[]", "addresses": "[]"},
        ]
        doc, stats = ov.to_geojson(rows, 0.5, "t", "r")
        self.assertEqual(stats["kept"]["with an Arabic name"], 1)
        self.assertEqual(stats["kept"]["with an English name"], 1)
        self.assertEqual(doc["features"][0]["properties"]["name:ar"], "مدرسة النيل")
        self.assertIn("with an Arabic name 1, with an English name 1", ov.report_text("t", "r", 0.5, stats))


class OvertureRulesTest(unittest.TestCase):
    def test_tutoring_quran_and_preschools(self) -> None:
        c = si.classify_overture
        self.assertEqual(c("school", ("سنتر الأوائل",)), (None, "not_school_tutoring"))
        self.assertEqual(c("school", ("مركز دروس النجاح",)), (None, "not_school_tutoring"))
        self.assertEqual(c("high_school", ("IELTS Academy",)), (None, "not_school_tutoring"))
        self.assertEqual(c("religious_school", ("دار تحفيظ القرآن الكريم",)), (None, "not_school_quran"))
        self.assertEqual(c("religious_school", ("كتاب الشيخ محمد",)), (None, "not_school_quran"))
        self.assertEqual(c("religious_school", ("معهد أزهري إعدادي",)), ("school", "azhar"))
        self.assertEqual(c("preschool", ("Kids Academy",)), ("kindergarten", "overture"))
        self.assertEqual(c("day_care_preschool", ("Baby Club",)), ("kindergarten", "overture"))
        self.assertEqual(c("child_care_and_day_care", ("Little Kids Center",)), ("kindergarten", "overture"))
        self.assertEqual(c("preschool", ("Smart Academy",)), (None, "not_school_courses"))
        self.assertEqual(c("preschool", ("حضانة الأمل",)), ("kindergarten", "overture"))
        self.assertEqual(c("private_school", ("Future Language School",)), ("school", "overture"))
        self.assertEqual(c("school", ("Elite Center",)), (None, "not_school_courses"))
        # OSM amenity=school is still kept as tagged.
        self.assertEqual(si.classify_tags({"amenity": "school", "name": "مدرسة تحفيظ"}, ("مدرسة تحفيظ",))[0], "school")


class DroppedCsvTest(unittest.TestCase):
    def test_one_file_per_reason(self) -> None:
        rows = [
            {"id": "x1", "lon": 31.24, "lat": 30.05, "names": json.dumps({"primary": "سنتر الأوائل"}), "category": "school", "alternates": None,
             "basic_category": None, "confidence": 0.77, "operating_status": "open", "sources": "[]", "addresses": "[]"},
            {"id": "x2", "lon": 31.21, "lat": 30.01, "names": json.dumps({"primary": "دار تحفيظ القرآن"}), "category": "religious_school",
             "alternates": None, "basic_category": None, "confidence": 0.6, "operating_status": "open", "sources": "[]", "addresses": "[]"},
        ]
        doc, _ = ov.to_geojson(rows, 0.5, "t", "r")
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "overture").mkdir()
            osm.write_json_atomic(folder / "overture" / ov.OUT_FILE, doc)
            result = si.run(folder)
            files = si.write_dropped_csvs(result, folder / "out")
            self.assertEqual(sorted(r for r, _, _ in files), ["not_school_quran", "not_school_tutoring"])
            text = (folder / "out" / "dropped_not_school_tutoring.csv").read_text(encoding="utf-8-sig")
        row = next(csv.DictReader(io.StringIO(text)))
        self.assertEqual((row["name"], row["source"], row["source_id"], row["category"], row["governorate"], row["confidence"]),
                         ("سنتر الأوائل", "overture", "x1", "school", "cairo", "0.77"))
        self.assertNotIn("lat", row)
        self.assertIn("Tutoring centres", si.dropped_by_source_lines(result)[0])


def shapefile_zip(polys: list[tuple[str, str, str, list[list[float]]]]) -> bytes:
    """A tiny polygon shapefile (ADM2_PCODE, ADM2_EN, ADM2_AR) zipped like COD-AB."""
    records = b""
    for i, (_pc, _en, _ar, ring) in enumerate(polys, start=1):
        cw = ring if sum(ring[k][0] * ring[k + 1][1] - ring[k + 1][0] * ring[k][1] for k in range(len(ring) - 1)) < 0 else ring[::-1]
        content = struct.pack("<i", 5) + struct.pack("<4d", 0, 0, 0, 0) + struct.pack("<ii", 1, len(cw)) + struct.pack("<i", 0)
        content += b"".join(struct.pack("<dd", x, y) for x, y in cw)
        records += struct.pack(">ii", i, len(content) // 2) + content
    shp = struct.pack(">i", 9994) + b"\0" * 20 + struct.pack(">i", (100 + len(records)) // 2) + struct.pack("<ii", 1000, 5) + b"\0" * 64 + records
    fields = [("ADM2_PCODE", 10), ("ADM2_EN", 30), ("ADM2_AR", 60)]
    header_len = 32 + 32 * len(fields) + 1
    record_len = 1 + sum(n for _, n in fields)
    dbf = struct.pack("<BBBBIHH", 3, 126, 11, 16, len(polys), header_len, record_len) + b"\0" * 20
    for name, n in fields:
        dbf += name.encode().ljust(11, b"\0") + b"C" + b"\0" * 4 + bytes([n, 0]) + b"\0" * 14
    dbf += b"\r"
    for pc, en, ar, _ring in polys:
        dbf += b" " + pc.encode().ljust(10) + en.encode().ljust(30) + ar.encode("utf-8").ljust(60)
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as z:
        z.writestr("egy_admbnda_adm2_capmas_20170421.shp", shp)
        z.writestr("egy_admbnda_adm2_capmas_20170421.dbf", dbf)
        z.writestr("egy_admbnda_adm2_capmas_20170421.cpg", "UTF-8")
        z.writestr("egy_admbnda_adm2_capmas_20170421.prj", 'GEOGCS["GCS_WGS_1984"]')
        z.writestr("egy_admbnda_adm1_capmas_20170421.shp", b"")
    return buffer.getvalue()


def square(lng0: float, lat0: float, lng1: float, lat1: float) -> list[list[float]]:
    return [[lng0, lat0], [lng1, lat0], [lng1, lat1], [lng0, lat1], [lng0, lat0]]


class Adm2Test(unittest.TestCase):
    def test_shapefile_to_areas_and_districts(self) -> None:
        data = shapefile_zip([
            ("EG0119", "Qism El-Maadi", "قسم المعادي", square(31.24, 29.94, 31.32, 30.0)),
            ("EG0141", "New Cairo 1", "القاهرة الجديدة 1", square(31.40, 29.98, 31.55, 30.08)),
        ])
        feats = adm2.features_from_bytes("egy_adm_capmas_20170421_shp.zip", data)
        self.assertEqual([f["properties"]["ADM2_AR"] for f in feats], ["قسم المعادي", "القاهرة الجديدة 1"])
        collection, facts = adm2.to_collection(feats, "OCHA COD-AB (fixture)", "CC BY-IGO", "2026-11-16T12:00:00Z")
        self.assertEqual(facts["fields"], {"name:en": "ADM2_EN", "name:ar": "ADM2_AR", "id": "ADM2_PCODE"})
        self.assertEqual([f["properties"]["id"] for f in collection["features"]], ["cod-EG0119", "cod-EG0141"])
        lines = adm2.new_city_lines(collection)
        self.assertIn('New Cairo, Fifth Settlement / القاهرة الجديدة، التجمع: area "New Cairo 1"', lines[2])
        self.assertIn("in no ADM2 unit", lines[0])  # Sheikh Zayed: not in the fixture
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            osm.write_json_atomic(folder / places_import.ADM2_FILE, collection)
            osm.write_json_atomic(folder / "egypt_place_points_osm.geojson", {"type": "FeatureCollection", "features": [
                {"type": "Feature", "properties": {"place": "neighbourhood", "name": "دجلة", "osm_id": 7, "osm_type": "node"},
                 "geometry": {"type": "Point", "coordinates": [31.29, 29.96]}},
                {"type": "Feature", "properties": {"place": "neighbourhood", "name": "التجمع الخامس", "osm_id": 8, "osm_type": "node"},
                 "geometry": {"type": "Point", "coordinates": [31.47, 30.02]}},
            ]})
            shapes, points = places_import.load(folder)
            areas, note = places_import.load_adm2(folder)
        schools = [
            si.School("osm-n1", "osm", "n1", ["osm:n1"], "مدرسة دجلة", "Degla School", "school", "cairo", "nearest", "", "", 29.961, 31.291),
            si.School("osm-n2", "osm", "n2", ["osm:n2"], "مدرسة التجمع", "Tagamoa School", "school", "cairo", "nearest", "", "", 30.021, 31.471),
            si.School("osm-n3", "osm", "n3", ["osm:n3"], "مدرسة بعيدة", "Far School", "school", "cairo", "nearest", "", "", 30.5, 31.0),
        ]
        places = places_import.build(shapes, points, schools, None, areas, note)
        places_import.assign(places, schools)
        self.assertEqual(places.area_source, "adm2")
        self.assertEqual([s.place_area_id for s in schools], ["cod-EG0119", "cod-EG0141", ""])
        self.assertEqual([s.place_district_id for s in schools], ["osm-n7", "osm-n8", ""])
        out = places_import.to_json(places, "T")
        self.assertEqual({a["level"] for a in out["areas"]}, {places_import.ADM2_LEVEL})
        self.assertIn("Areas: ADM2 units (2, holding 67% of the schools; OCHA COD-AB (fixture); licence CC BY-IGO)",
                      " ".join(places_import.summary_lines(places, schools)))

    def test_cod_ab_2024_fields_and_member_names(self) -> None:
        # OCHA's newer COD-AB files: lower-case fields, the language of each
        # name in lang / lang1, members named egy_admin2.* (validator B3).
        feats = [{"type": "Feature", "properties": {"adm2_pcode": "EG0119", "adm2_name": "Maadi", "adm2_name1": "المعادي",
                                                    "lang": "en", "lang1": "ar", "adm1_name": "Cairo"},
                  "geometry": {"type": "Polygon", "coordinates": [square(31.24, 29.94, 31.32, 30.0)]}}]
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as z:
            z.writestr("egy_admin1.geojson", json.dumps({"type": "FeatureCollection", "features": []}))
            z.writestr("egy_admin2.geojson", json.dumps({"type": "FeatureCollection", "features": feats}))
            z.writestr("egy_admin20_notes.geojson", "{}")
        got = adm2.features_from_bytes("egy_admin_boundaries.geojson.zip", buffer.getvalue())
        collection, facts = adm2.to_collection(got, "x", "y", "T")
        p0 = collection["features"][0]["properties"]
        self.assertEqual((p0["id"], p0["name:ar"], p0["name:en"], p0["adm1"]), ("cod-EG0119", "المعادي", "Maadi", "cairo"))
        self.assertTrue(facts["arabic"])

    def test_nested_areas_smallest_wins(self) -> None:
        # A city's qism inside its markaz (outer rings only): the qism wins (validator B4).
        markaz = places_import.Shape("cod-M", 7, "مركز دمنهور", "Markaz Damanhour", [square(30.3, 30.9, 30.6, 31.2)])
        qism = places_import.Shape("cod-Q", 7, "قسم دمنهور", "Qism Damanhour", [square(30.45, 31.02, 30.5, 31.06)])
        places = places_import.Places([markaz, qism], [], [], [], [], {}, {})
        for a in places.areas:
            a.governorate = "beheira"
        s = si.School("osm-n1", "osm", "n1", ["osm:n1"], "مدرسة", "School", "school", "beheira", "given", "", "", 31.04, 30.47)
        t = si.School("osm-n2", "osm", "n2", ["osm:n2"], "مدرسة", "School", "school", "beheira", "given", "", "", 30.95, 30.35)
        places_import.assign(places, [s, t])
        self.assertEqual((s.place_area_id, t.place_area_id), ("cod-Q", "cod-M"))

    def test_geojson_and_main_with_a_file(self) -> None:
        feats = [{"type": "Feature", "properties": {"ADM2_PCODE": f"EG{i:04d}", "ADM2_EN": f"Unit {i}", "ADM2_AR": f"وحدة {i}"},
                  "geometry": {"type": "Polygon", "coordinates": [square(30 + i * 0.01, 30, 30.005 + i * 0.01, 30.005)]}} for i in range(adm2.EXPECTED_MIN)]
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "egy_adm2.geojson"
            src.write_text(json.dumps({"type": "FeatureCollection", "features": feats}), encoding="utf-8")
            self.assertEqual(adm2.main(["--out", str(Path(tmp) / "places"), "--file", str(src), "--no-geoboundaries"]), 0)
            report = (Path(tmp) / "places" / adm2.REPORT_FILE).read_text(encoding="utf-8")
        self.assertIn(f"- Units written: {adm2.EXPECTED_MIN}", report)
        self.assertIn("## New cities", report)


def school(sid: str, ar: str, en: str, lat: float, lng: float, kind: str = "school", source: str = "osm", conf: float | None = None) -> si.School:
    e = si.RawEntry(source, sid, kind, "school", "", ar, en, "", "", lat, lng, "f", confidence=conf)
    return si.clean([e], si.Boundaries())[0][0]


def run_dedupe(*schools: si.School) -> tuple[list[si.School], list[si.MergeLink], list[si.LikelyDuplicate]]:
    links: list[si.MergeLink] = []
    merged, _, likely = si.find_duplicates(list(schools), links)
    return merged, links, likely


class DedupeRulesTest(unittest.TestCase):
    def test_each_rule(self) -> None:
        cases = [
            ("same_name_500m", school("n1", "مدرسة النيل للغات", "", 30.0, 31.2), school("x2", "مدرسه النيل", "", 30.004, 31.2, source="overture", conf=0.7)),
            ("similar_300m", school("n1", "", "Green Valley Experimental", 30.0, 31.2), school("x2", "", "Green Valley Experimentel", 30.002, 31.2, source="overture", conf=0.7)),
            ("cross_script_300m", school("n1", "مدرسة الرواد", "", 30.0, 31.2), school("x2", "", "El Rowad School", 30.002, 31.2, source="overture", conf=0.7)),
            ("contained_100m", school("n1", "", "Manarat Al Farouk", 30.0, 31.2), school("x2", "", "Manarat Al Farouk Maadi", 30.0005, 31.2, source="overture", conf=0.7)),
            ("contained_300m", school("n1", "", "El Alsson School", 30.0, 31.2), school("x2", "", "El Alsson British American School", 30.002, 31.2, source="overture", conf=0.7)),
            ("kg_section_300m", school("n1", "مدرسة الفجر", "", 30.0, 31.2), school("x2", "روضة الفجر", "", 30.001, 31.2, kind="kindergarten", source="overture", conf=0.7)),
            ("same_name_2km", school("n1", "", "Futures School", 30.0, 31.2), school("x2", "", "Futures School", 30.012, 31.2, source="overture", conf=0.7)),
        ]
        for rule, a, b in cases:
            merged, links, likely = run_dedupe(a, b)
            self.assertEqual(len(merged), 1, rule)
            self.assertEqual([l.rule for l in links], [rule])
            self.assertEqual(merged[0].id, "osm-n1", rule)  # OSM survives Overture
            self.assertEqual(merged[0].merged_from, ["overture-x2"])
        kg = run_dedupe(cases[5][1], cases[5][2])[0][0]
        self.assertEqual(kg.kind, "school")

    def test_chain_branches_and_far_pins_stay_apart(self) -> None:
        a = school("n1", "", "Manarat Al Farouk New Cairo", 30.0, 31.2)
        b = school("n2", "", "Manarat Al Farouk Maadi", 30.009, 31.2)  # 1 km
        c = school("n3", "", "Manarat Al Farouk Maadi", 30.03, 31.2)  # 3.3 km from b: same name too far
        d = school("n4", "", "Manarat Al Farouk", 30.0, 31.2024)  # 230 m from a, extra words are places
        merged, links, likely = run_dedupe(a, b, c, d)
        self.assertEqual(len(merged), 4)
        self.assertEqual(links, [])
        self.assertTrue(any(p.keep == "branches" for p in likely))

    def test_stages_genders_and_people(self) -> None:
        merged, links, likely = run_dedupe(
            school("n1", "مدرسة النصر الابتدائية", "", 30.0, 31.2),
            school("n2", "مدرسة النصر الإعدادية", "", 30.0005, 31.2),
            school("n3", "مدرسة الشهيد أحمد", "", 30.002, 31.21),
            school("n4", "مدرسة الشهيد محمد", "", 30.0021, 31.21),
        )
        self.assertEqual(len(merged), 4)
        # Different stages are known to be different schools, and two martyrs'
        # names share only one word in two: neither is listed as "to check".
        self.assertEqual(likely, [])

    def test_overture_duplicates_and_survivor_fields(self) -> None:
        # Three Facebook pages of one school; the most confident wins; names combine.
        a = school("x1", "", "Delta Modern School", 30.0, 31.2, source="overture", conf=0.6)
        b = school("x2", "مدرسة دلتا مودرن", "", 30.0004, 31.2002, source="overture", conf=0.9)
        c = school("x3", "", "Delta Modern School", 30.0003, 31.2001, source="overture", conf=0.7)
        merged, links, _ = run_dedupe(a, b, c)
        self.assertEqual(len(merged), 1)
        s = merged[0]
        self.assertEqual(s.id, "overture-x2")
        self.assertEqual((s.name_ar, s.name_en), ("مدرسة دلتا مودرن", "Delta Modern School"))
        self.assertEqual(s.merged_from, ["overture-x1", "overture-x3"])
        self.assertEqual(sorted(l.rule for l in links), ["cross_script_300m", "same_name_500m"])

    def test_merged_csv_and_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "osm").mkdir()
            osm.write_json_atomic(folder / "osm" / osm.SCHOOLS_FILE, osm.schools_geojson({"elements": [
                node(1, 30.0, 31.2, amenity="school", name="مدرسة النيل"),
                node(2, 30.003, 31.2, amenity="school", name="مدرسه النيل"),
            ]}, "t", "x"))
            result = si.run(folder)
            members = {m.id: m for g in result.merged_groups for m in g}
            self.assertEqual(si.write_merged_csv(result, members, folder / "merged.csv"), 1)
            row = next(csv.DictReader(io.StringIO((folder / "merged.csv").read_text(encoding="utf-8-sig"))))
        self.assertEqual((row["kept_id"], row["merged_id"], row["rule"]), ("osm-n1", "osm-n2", "same_name_500m"))
        self.assertEqual(si.schools_json(result, "T")["schools"][0]["mergedFrom"], ["osm-n2"])
        self.assertIn("Auto-merged duplicates: 1 (same name within 500 m 1)", si.dedupe_lines(result)[0])

    def test_common_names_need_the_same_site(self) -> None:
        # "النور" in three places of Egypt: a generic name. Two different
        # schools 400 m or 1.5 km apart stay apart; two pins of one school
        # 100 m apart still merge. (Validator B1.)
        far = [school(f"f{k}", "مدرسة النور", "", 27.0 + k, 31.0) for k in range(2)]
        a = school("n1", "مدرسة النور", "", 30.0, 31.2)
        b = school("n2", "مدرسة النور", "", 30.0036, 31.2)  # 400 m
        c = school("n3", "مدرسة النور", "", 30.0135, 31.2)  # 1.5 km
        d = school("x4", "", "Al Nour School", 30.0009, 31.2, source="overture", conf=0.8)  # 100 m from a
        kg = school("x5", "حضانة النور", "", 30.0018, 31.2, kind="kindergarten", source="overture", conf=0.8)  # 200 m
        merged, links, likely = run_dedupe(*far, a, b, c, d, kg)
        self.assertEqual([(l.kept_id, l.merged_id) for l in links], [("osm-n1", "overture-x4")])
        self.assertEqual(len(merged), 6)
        self.assertTrue(any(p.keep == "common_name" for p in likely))
        # The same five without the far ones: a rare name, the usual rules.
        merged, links, _ = run_dedupe(a, b, c, d, kg)
        self.assertEqual(len(merged), 1)

    def test_common_name_counts_places_not_entries(self) -> None:
        # One school listed three times at one site is not a "common" name.
        same_site = [school(f"x{k}", "", "Futures School", 30.0 + k * 0.0001, 31.2, source="overture", conf=0.5) for k in range(3)]
        other = school("n9", "", "Futures School", 30.012, 31.2)  # 1.3 km
        merged, links, _ = run_dedupe(*same_site, other)
        self.assertEqual(len(merged), 1)

    def test_separate_decision(self) -> None:
        a = school("n1", "", "Futures School", 30.0, 31.2)
        b = school("n2", "", "Futures School", 30.001, 31.2)
        links: list[si.MergeLink] = []
        merged, _, likely = si.find_duplicates([a, b], links, [("osm:n2", "osm:n1")])
        self.assertEqual(len(merged), 2)
        self.assertEqual(links, [])

    def test_transliteration(self) -> None:
        self.assertEqual(dedupe.skeleton("رواد"), dedupe.skeleton("rowad"))
        self.assertEqual(dedupe.skeleton("نيل"), dedupe.skeleton("nile"))
        self.assertEqual(dedupe.skeleton("فاروق"), dedupe.skeleton("farouk"))
        self.assertNotEqual(dedupe.skeleton("نصر"), dedupe.skeleton("nile"))


class ReviewDecisionsTest(unittest.TestCase):
    def make(self, folder: Path) -> None:
        (folder / "osm").mkdir()
        osm.write_json_atomic(folder / "osm" / osm.SCHOOLS_FILE, osm.schools_geojson({"elements": [
            node(1, 30.05, 31.24, amenity="school", name="مدرسة النيل"),
            node(2, 30.06, 31.25, amenity="school", name="مدرسة الأمل"),
            node(3, 30.07, 31.26, amenity="school", name="مدرسة"),  # generic name: dropped by the rules
            node(4, 30.08, 31.27, amenity="school", name="مدرسة الفجر"),
            node(5, 30.09, 31.28, amenity="school", name="مدرسة النور"),
        ]}, "t", "x"))
        (folder / "review").mkdir()
        (folder / "review" / "decisions.csv").write_text(
            "source,source_id,action,value,reason\n"
            "osm,n1,rename_en,Nile Experimental School,English name from the school's site\n"
            "osm,node/2,drop,,closed in 2024\n"
            "osm,n3,keep,,real school: Madrasa (its name)\n"
            "osm,n3,rename_ar,مدرسة الشروق,\n"
            "osm,n4,set_kind,kindergarten,KG only\n"
            "osm,n5,merge_into,osm:n4,same school, two pins\n"
            "overture,zzz,drop,,not in this run\n"
            "osm,n9,explode,,bad action\n",
            encoding="utf-8",
        )

    def test_actions_counts_and_unmatched(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            self.make(folder)
            decisions, problems = si.load_decisions(folder / "review" / "decisions.csv")
            result = si.run(folder, decisions)
            out = folder / "out"
            si.write_review_input(result, out / "review_input.csv")
            rows = list(csv.DictReader(io.StringIO((out / "review_input.csv").read_text(encoding="utf-8-sig"))))
        self.assertEqual(len(problems), 1)
        by_id = {s.id: s for s in result.schools}
        self.assertEqual(by_id["osm-n1"].name_en, "Nile Experimental School")
        self.assertNotIn("osm-n2", by_id)
        self.assertEqual(by_id["osm-n3"].name_ar, "مدرسة الشروق")
        self.assertEqual(by_id["osm-n4"].kind, "kindergarten")  # the reviewer's kind wins, also after n5 merged into it
        self.assertNotIn("osm-n5", by_id)
        self.assertEqual(by_id["osm-n4"].merged_from, ["osm-n5"])
        self.assertEqual(result.review.applied, {"drop": 1, "keep": 1, "merge_into": 1, "rename_ar": 1, "rename_en": 1, "set_kind": 1})
        self.assertEqual([d.key for d in result.review.unmatched], ["overture:zzz"])
        self.assertIn("not matched in this run: 1", si.review_lines(result)[0])
        self.assertEqual({d.source_key: d.reason for d in result.dropped}["osm:n2"], "review_drop")
        row = {r["source_id"]: r for r in rows}
        self.assertEqual(set(row), {"n1", "n2", "n3", "n4", "n5"})
        self.assertEqual((row["n2"]["drop_reason"], row["n2"]["group_id"]), ("review_drop", ""))
        self.assertEqual((row["n5"]["group_id"], row["n1"]["lat"], row["n1"]["lon"]), ("osm-n4", "30.050", "31.240"))
        self.assertEqual(list(rows[0]), list(si.REVIEW_INPUT_COLUMNS))

    def test_separate_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "osm").mkdir()
            osm.write_json_atomic(folder / "osm" / osm.SCHOOLS_FILE, osm.schools_geojson({"elements": [
                node(1, 30.0, 31.2, amenity="school", name="Futures School"),
                node(2, 30.001, 31.2, amenity="school", name="Futures School"),
            ]}, "t", "x"))
            path = folder / "decisions.csv"
            path.write_text("source,source_id,action,value,reason\nosm,node/2,separate,osm:node/1,two schools\nosm,n1,separate,,no value\n", encoding="utf-8")
            decisions, problems = si.load_decisions(path)
            self.assertEqual(len(problems), 1)
            self.assertEqual((decisions[0].key, decisions[0].value), ("osm:n2", "osm:n1"))
            self.assertEqual(len(si.run(folder).schools), 1)
            result = si.run(folder, decisions)
        self.assertEqual(sorted(s.id for s in result.schools), ["osm-n1", "osm-n2"])
        self.assertEqual(result.review.applied, {"separate": 1})

    def test_repo_file_has_the_header(self) -> None:
        path = Path(__file__).resolve().parents[2] / "data" / "schools" / "review" / "decisions.csv"
        self.assertEqual(path.read_text(encoding="utf-8").splitlines()[0], ",".join(si.DECISION_COLUMNS))


class NameScriptTest(unittest.TestCase):
    def test_repair_and_normalise(self) -> None:
        import name_clean as nc

        mojibake = "مدرسة النيل".encode("utf-8").decode("cp1252", errors="replace")
        self.assertTrue(mojibake.startswith("\u00d9"))
        self.assertEqual(nc.fix_text(mojibake), "مدرسة النيل")
        double = "مدرسة".encode("utf-8").decode("latin-1").encode("utf-8").decode("cp1252", errors="replace")
        self.assertEqual(nc.fix_text(double), "مدرسة")
        self.assertEqual(nc.fix_text("\ufee3\ufeaa\ufead\ufeb3\ufe94"), "مدرسة")  # presentation forms
        self.assertEqual(nc.fix_text("\U0001d40d\U0001d422\U0001d425\U0001d41e School \U0001f3eb"), "Nile School")  # fancy letters, emoji
        self.assertEqual(nc.fix_text("\uff2e\uff49\uff4c\uff45"), "Nile")  # fullwidth
        self.assertEqual(nc.fix_text("\u200fمدرسة\u200e النيل\u200b"), "مدرسة النيل")
        self.assertEqual(nc.fix_text("Ã©cole"), "école")
        self.assertEqual(nc.fix_text("Nile School"), "Nile School")

    def test_script_check(self) -> None:
        import name_clean as nc

        for bad in ("Школа №5", "北京学校", "विद्यालय", "Σχολείο"):
            self.assertEqual(nc.script_check(bad), "", bad)
        self.assertEqual(nc.script_check("École Française du Caire"), "École Française du Caire")
        self.assertEqual(nc.script_check("Nile International School Ж"), "Nile International School")
        self.assertEqual(nc.script_check("مدرسة النيل 2"), "مدرسة النيل 2")

    def test_importer_drops_and_repairs(self) -> None:
        mojibake = "مدرسة الأمل".encode("utf-8").decode("cp1252", errors="replace")
        rows = [
            {"id": "a", "lon": 31.24, "lat": 30.05, "names": json.dumps({"primary": "Школа Нил"}), "category": "school", "alternates": None,
             "basic_category": None, "confidence": 0.9, "operating_status": "open", "sources": "[]", "addresses": "[]"},
            {"id": "b", "lon": 31.25, "lat": 30.06, "names": json.dumps({"primary": mojibake}), "category": "school", "alternates": None,
             "basic_category": None, "confidence": 0.9, "operating_status": "open", "sources": "[]", "addresses": "[]"},
        ]
        doc, _ = ov.to_geojson(rows, 0.5, "t", "r")
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "overture").mkdir()
            osm.write_json_atomic(folder / "overture" / ov.OUT_FILE, doc)
            result = si.run(folder)
        self.assertEqual({d.source_key: d.reason for d in result.dropped}, {"overture:a": "name_script"})
        self.assertEqual(result.schools[0].name_ar, "مدرسة الأمل")
        self.assertEqual(doc["features"][1]["properties"]["name:ar"], "مدرسة الأمل")  # repaired already by the Overture converter
        osm_entry = si._osm_entry({"amenity": "school", "name": mojibake}, 30.0, 31.2, "f", 0)
        self.assertEqual((osm_entry.name, osm_entry.name_fix), ("مدرسة الأمل", "mojibake"))
        self.assertIn("Name not in Arabic or English", si.DROP_REASONS["name_script"])
        self.assertIn({"key": "overture:a", "reason": "name_script"}, si.schools_json(result, "T")["dropped"])


if __name__ == "__main__":
    unittest.main()
