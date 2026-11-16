"""Tests for City -> Area -> District (fetch_osm_places.py, places_import.py).
Fixtures only, no network.

Run: python3 -m unittest discover -s tools/import_schools -v
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fetch_osm_places as fp  # noqa: E402
import import_schools  # noqa: E402
import places_import as pi  # noqa: E402
from schools_import import School  # noqa: E402

SAMPLE = Path(__file__).resolve().parents[2] / "data" / "schools" / "sample"


def square(lat: float, lng: float, half: float) -> list[list[float]]:
    return [[lng - half, lat - half], [lng + half, lat - half], [lng + half, lat + half], [lng - half, lat + half], [lng - half, lat - half]]


def shape(osm: int, level: int, ar: str, en: str, lat: float, lng: float, half: float) -> pi.Shape:
    return pi.Shape(f"osm-r{osm}", level, ar, en, [square(lat, lng, half)])


def school(sid: str, lat: float | None, lng: float | None, gov: str = "cairo", city: str = "", city_ar: str = "") -> School:
    return School(
        id=sid, source="osm", source_id=sid, source_keys=[f"osm:{sid}"], name_ar="مدرسة", name_en="School",
        kind="school", governorate=gov, governorate_method="nearest", city=city, city_ar=city_ar, lat=lat, lng=lng,
    )


class FetchConversionTest(unittest.TestCase):
    def test_queries(self) -> None:
        self.assertIn('rel["boundary"="administrative"]["admin_level"~"^(5|6|7|8|9|10)$"](area.eg);', fp.ADMIN_QUERY)
        self.assertTrue(fp.ADMIN_QUERY.endswith("out geom;\n"))
        self.assertIn('nwr["place"~"^(suburb|quarter|neighbourhood)$"]["name"](area.eg);', fp.PLACES_QUERY)
        self.assertTrue(fp.PLACES_QUERY.endswith("out center;\n"))

    def test_simplify_keeps_a_closed_ring(self) -> None:
        # A square with 400 points along its edges simplifies to its corners.
        ring = []
        for i in range(100):
            ring.append([31 + i / 100, 30.0])
        for i in range(100):
            ring.append([32.0, 30 + i / 100])
        for i in range(100):
            ring.append([32 - i / 100, 31.0])
        for i in range(100):
            ring.append([31.0, 31 - i / 100])
        ring.append(ring[0])
        out = fp.simplify_ring(ring)
        self.assertEqual(out[0], out[-1])
        self.assertLessEqual(len(out), 6)
        self.assertGreaterEqual(len(out), 4)

    def test_admin_and_points(self) -> None:
        answer = {"elements": [
            {"type": "relation", "id": 5, "tags": {"admin_level": "7", "name": "المعادي", "name:en": "Maadi", "boundary": "administrative"},
             "members": [{"type": "way", "role": "outer", "geometry": [{"lat": p[1], "lon": p[0]} for p in square(29.96, 31.25, 0.02)]}]},
            {"type": "relation", "id": 6, "tags": {"admin_level": "4", "name": "x"}, "members": []},
            {"type": "relation", "id": 7, "tags": {"admin_level": "8"}, "members": []},  # no name
            {"type": "relation", "id": 8, "tags": {"admin_level": "8", "name": "gap"},
             "members": [{"type": "way", "role": "outer", "geometry": [{"lat": 30.0, "lon": 31.0}, {"lat": 30.1, "lon": 31.1}]}]},
        ]}
        doc, per_level, problems = fp.admin_geojson(answer, "2026-11-16T00:00:00Z", "x")
        self.assertEqual(per_level, {7: 1})
        self.assertEqual(len(problems), 1)
        props = doc["features"][0]["properties"]
        self.assertEqual((props["admin_level"], props["name:en"], props["osm_id"]), (7, "Maadi", 5))
        pts, kinds = fp.points_geojson({"elements": [
            {"type": "node", "id": 1, "lat": 29.958, "lon": 31.27, "tags": {"place": "neighbourhood", "name": "دجلة"}},
            {"type": "way", "id": 2, "center": {"lat": 30.0, "lon": 31.0}, "tags": {"place": "suburb", "name": "x"}},
            {"type": "node", "id": 3, "lat": 30.0, "lon": 31.0, "tags": {"place": "city", "name": "Cairo"}},
        ]}, "t", "x")
        self.assertEqual(kinds, {"neighbourhood": 1, "suburb": 1})
        self.assertEqual(pts["features"][0]["geometry"]["coordinates"], [31.27, 29.958])


class MeasureTest(unittest.TestCase):
    def test_level_order_prefers_the_finest_good_level(self) -> None:
        self.assertEqual(pi.level_order((5, 6, 7), {5: 0.9, 6: 0.8, 7: 0.2}, 0.5), [6, 5, 7])
        self.assertEqual(pi.level_order((5, 6, 7), {5: 0.9, 7: 0.6}, 0.5), [7, 5])
        # Nothing reaches the threshold: the best covered first.
        self.assertEqual(pi.level_order((8, 9, 10), {8: 0.1, 10: 0.2}, 0.3), [10, 8])
        self.assertEqual(pi.level_order((8, 9, 10), {}, 0.3), [])

    def test_coverage_is_measured_on_schools(self) -> None:
        shapes = [shape(1, 6, "أ", "A", 30.0, 31.0, 0.1), shape(2, 7, "ب", "B", 30.0, 31.0, 0.01)]
        cover = pi.coverage(shapes, [(30.0, 31.0), (30.05, 31.05), (35.0, 35.0), (30.0, 31.005)])
        self.assertEqual(cover, {6: 0.75, 7: 0.5})


class BuildAndAssignTest(unittest.TestCase):
    def setUp(self) -> None:
        # Level 7 covers Maadi only; level 6 covers a large Giza block; level 9
        # is one district in Maadi. Two named places, one outside any district.
        self.shapes = [
            shape(1, 7, "المعادي", "Maadi", 29.96, 31.25, 0.02),
            shape(2, 7, "نصر", "Nasr City", 30.06, 31.33, 0.02),
            shape(3, 6, "مركز الجيزة", "Giza Markaz", 30.0, 31.0, 0.1),
            shape(4, 6, "big Cairo", "big Cairo", 30.0, 31.3, 0.2),  # overlaps the level 7 areas: not chosen there
            shape(5, 9, "دجلة", "Degla", 29.955, 31.265, 0.004),
        ]
        self.points = [
            pi.PlacePoint("osm-n10", "neighbourhood", "سرايات", "Sarayat", 29.965, 31.245),
            pi.PlacePoint("osm-n11", "neighbourhood", "دجلة", "Degla", 29.956, 31.266),  # inside the polygon: skipped
            pi.PlacePoint("osm-n12", "suburb", "بعيد", "Far", 25.0, 33.0),  # in no area
        ]
        self.schools = [
            school("a", 29.955, 31.265),  # Maadi, Degla polygon
            school("b", 29.966, 31.246),  # Maadi, near Sarayat
            school("c", 30.06, 31.33),  # Nasr City
            school("d", 30.0, 31.0, gov="giza"),  # Giza markaz (fallback level 6)
            school("e", 30.0, 31.0, gov="cairo"),  # in a Giza area but the school says Cairo: no area
            school("f", None, None, city_ar="قسم المعادي"),  # list entry without a pin: by name
            school("g", 29.979, 31.231),  # Maadi, no district near
        ]

    def test_build_assign_json(self) -> None:
        places = pi.build(self.shapes, self.points, self.schools, None)
        self.assertEqual(places.area_order, [7, 6])
        area_ids = sorted(a.id for a in places.areas)
        self.assertEqual(area_ids, ["osm-r1", "osm-r2", "osm-r3", "osm-r4"])
        govs = {a.id: a.governorate for a in places.areas}
        self.assertEqual(govs["osm-r1"], "cairo")
        self.assertEqual(govs["osm-r3"], "giza")
        self.assertEqual([d.id for d in places.districts], ["osm-r5"])
        self.assertEqual([p.id for p, _ in places.point_districts], ["osm-n10"])
        pi.assign(places, self.schools)
        got = {s.id: (s.place_area_id, s.place_district_id) for s in self.schools}
        self.assertEqual(got["a"], ("osm-r1", "osm-r5"))
        self.assertEqual(got["b"], ("osm-r1", "osm-n10"))
        self.assertEqual(got["c"], ("osm-r2", ""))
        self.assertEqual(got["d"], ("osm-r3", ""))
        self.assertEqual(got["e"], ("", ""))
        self.assertEqual(got["f"], ("osm-r1", ""))
        self.assertEqual(got["g"], ("osm-r1", ""))
        self.assertEqual(places.no_area, 1)
        self.assertEqual(places.school_counts["osm-r1"], 4)
        doc = pi.to_json(places, "t")
        self.assertEqual(doc["format"], "school-carpool-places/1")
        maadi = next(a for a in doc["areas"] if a["id"] == "osm-r1")
        self.assertEqual(maadi["rings"][0][0], [29.94, 31.23])  # [lat, lng]
        self.assertEqual(maadi["schoolCount"], 4)
        self.assertEqual({d["source"] for d in doc["districts"]}, {"osm-boundary", "osm-place"})
        self.assertEqual(next(d for d in doc["districts"] if d["id"] == "osm-n10")["areaId"], "osm-r1")
        self.assertNotIn("rings", next(d for d in doc["districts"] if d["id"] == "osm-n10"))
        school_json = next(s for s in self.schools if s.id == "a").to_json()
        self.assertEqual(school_json["placeAreaId"], "osm-r1")
        self.assertEqual(school_json["placeAreaNameEn"], "Maadi")
        self.assertEqual(school_json["placeDistrictId"], "osm-r5")
        self.assertNotIn("placeAreaId", next(s for s in self.schools if s.id == "e").to_json())

    def test_area_by_name(self) -> None:
        areas = [shape(1, 7, "قسم المعادي", "Maadi District", 0, 0, 1), shape(2, 7, "مدينة نصر", "Nasr City", 0, 0, 1)]
        self.assertEqual(pi.area_by_name(areas, "المعادي").id, "osm-r1")
        self.assertEqual(pi.area_by_name(areas, "", "nasr").id, "osm-r2")
        self.assertIsNone(pi.area_by_name(areas, "الزمالك"))
        self.assertIsNone(pi.area_by_name(areas, ""))


class SampleRunTest(unittest.TestCase):
    def test_the_sample_gets_places(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code = import_schools.main(["--input", str(SAMPLE), "--out", tmp, "--generated-at", "2026-11-16T00:00:00Z"])
            self.assertEqual(code, 0)
            places = json.loads((Path(tmp) / "places.json").read_text(encoding="utf-8"))
            schools = json.loads((Path(tmp) / "schools.json").read_text(encoding="utf-8"))["schools"]
            report = (Path(tmp) / "report.md").read_text(encoding="utf-8")
        self.assertEqual(places["levels"]["area"], [7])
        self.assertEqual(len(places["areas"]), 10)
        self.assertTrue(any(s.get("placeAreaId") for s in schools))
        self.assertIn("## Places (City -> Area -> District)", report)
        self.assertIn("Schools per city: Cairo / القاهرة", report)


if __name__ == "__main__":
    unittest.main()
