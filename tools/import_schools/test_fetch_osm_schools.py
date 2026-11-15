"""Tests for the OpenStreetMap download (F4): Overpass answer -> GeoJSON the
importer reads, boundary stitching, server fallback. No network.

Run: python3 -m unittest discover -s tools/import_schools -v
"""

from __future__ import annotations

import datetime as dt
import io
import json
import math
import random
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fetch_osm_schools as f  # noqa: E402
from schools_import import Boundaries, _IndexedRing, _osm_source_id, run  # noqa: E402

# A small Overpass answer in the shape of `[out:json]` + `out center;`
# (positions near real places, names invented).
SCHOOLS_ANSWER = {
    "version": 0.6,
    "generator": "Overpass API (fixture)",
    "osm3s": {"timestamp_osm_base": "2026-11-15T10:00:00Z", "copyright": "OpenStreetMap contributors (fixture)"},
    "elements": [
        {"type": "node", "id": 11, "lat": 30.0566, "lon": 31.3301,
         "tags": {"amenity": "school", "name": "مدرسة النيل التجريبية", "name:en": "Nile Experimental School"}},
        {"type": "way", "id": 22, "center": {"lat": 31.2001, "lon": 29.9187}, "nodes": [1, 2, 3, 1],
         "tags": {"amenity": "kindergarten", "name": "روضة الزهور", "id": "999"}},
        {"type": "relation", "id": 33, "center": {"lat": 29.9870, "lon": 31.2118},
         "tags": {"amenity": "school", "name:en": "Giza Language School", "type": "multipolygon"}},
        {"type": "way", "id": 44, "tags": {"amenity": "school", "name": "No centre"}},
        {"type": "node", "id": "bad", "lat": 30.0, "lon": 31.0, "tags": {"amenity": "school", "name": "Bad id"}},
        {"type": "node", "id": 55, "lat": 30.07, "lon": 31.28, "tags": {"amenity": "school"}},
    ],
}


def square(lng0: float, lat0: float, lng1: float, lat1: float) -> list[list[float]]:
    return [[lng0, lat0], [lng1, lat0], [lng1, lat1], [lng0, lat1], [lng0, lat0]]


def way_member(points: list[list[float]], role: str = "outer") -> dict:
    return {"type": "way", "ref": 1, "role": role, "geometry": [{"lat": p[1], "lon": p[0]} for p in points]}


class SchoolsConversionTest(unittest.TestCase):
    def test_points_tags_and_ids(self) -> None:
        doc = f.schools_geojson(SCHOOLS_ANSWER, "2026-11-15T10:00:00Z", "https://overpass.example/api/interpreter")
        self.assertEqual(doc["type"], "FeatureCollection")
        self.assertEqual(doc["fetched_at"], "2026-11-15T10:00:00Z")
        self.assertIn("ODbL", doc["license"])
        by_id = {(x["properties"]["osm_type"], x["properties"]["osm_id"]): x for x in doc["features"]}
        # The way without a centre and the element with a bad id are left out.
        self.assertEqual(sorted(by_id), [("node", 11), ("node", 55), ("relation", 33), ("way", 22)])
        node = by_id[("node", 11)]
        self.assertEqual(node["geometry"], {"type": "Point", "coordinates": [31.3301, 30.0566]})
        self.assertEqual(node["properties"]["name:en"], "Nile Experimental School")
        self.assertEqual(node["properties"]["@id"], "node/11")
        self.assertEqual(by_id[("way", 22)]["geometry"]["coordinates"], [29.9187, 31.2001])
        self.assertEqual(by_id[("relation", 33)]["properties"]["amenity"], "school")

    def test_counts(self) -> None:
        doc = f.schools_geojson(SCHOOLS_ANSWER, "2026-11-15T10:00:00Z", "x")
        c = f.counts(doc, SCHOOLS_ANSWER)
        self.assertEqual(c["elements"], 6)
        self.assertEqual(c["features"], 4)
        self.assertEqual(c["no_position"], 2)
        self.assertEqual(c["amenity:kindergarten"], 1)
        self.assertEqual(c["no_name"], 1)

    def test_source_ids_match_the_hdx_export(self) -> None:
        doc = f.schools_geojson(SCHOOLS_ANSWER, "2026-11-15T10:00:00Z", "x")
        props = {x["properties"]["osm_id"]: x["properties"] for x in doc["features"]}
        self.assertEqual(_osm_source_id(props[11], "fallback"), "n11")
        # A stray "id" tag on the way does not change its ID.
        self.assertEqual(_osm_source_id(props[22], "fallback"), "w22")
        self.assertEqual(_osm_source_id(props[33], "fallback"), "r33")
        # The HDX export names the same way "ways_poly" with osm_id: same ID.
        self.assertEqual(_osm_source_id({"osm_id": 22, "osm_type": "ways_poly"}, "fallback"), "w22")

    def test_the_importer_reads_the_download(self) -> None:
        doc = f.schools_geojson(SCHOOLS_ANSWER, "2026-11-15T10:00:00Z", "x")
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            f.write_json_atomic(folder / "osm" / f.SCHOOLS_FILE, doc)
            (folder / "osm" / f.REPORT_FILE).write_text("# report\n", encoding="utf-8")
            # An HDX copy of one of the same schools next to it.
            hdx = {"type": "FeatureCollection", "features": [{
                "type": "Feature",
                "properties": {"osm_id": 11, "osm_type": "nodes", "amenity": "school", "name": "مدرسة النيل التجريبية"},
                "geometry": {"type": "Point", "coordinates": [31.3301, 30.0566]},
            }]}
            (folder / "hotosm_points.geojson").write_text(json.dumps(hdx), encoding="utf-8")
            result = run(folder)
        self.assertEqual(result.files, [f"osm/{f.SCHOOLS_FILE}", "hotosm_points.geojson"])
        ids = sorted(s.id for s in result.schools)
        self.assertEqual(ids, ["osm-n11", "osm-r33", "osm-w22"])
        kinds = {s.id: s.kind for s in result.schools}
        self.assertEqual(kinds["osm-w22"], "kindergarten")
        reasons = sorted(d.reason for d in result.dropped)
        self.assertEqual(reasons, ["no_name", "repeated_source_id"])


class BoundariesTest(unittest.TestCase):
    def test_stitch_pieces_in_any_order_and_direction(self) -> None:
        a = [[0.0, 0.0], [1.0, 0.0]]
        b = [[1.0, 1.0], [1.0, 0.0]]  # reversed
        c = [[1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]
        rings = f.stitch_rings([a, c, b])
        self.assertIsNotNone(rings)
        assert rings is not None
        self.assertEqual(len(rings), 1)
        ring = rings[0]
        self.assertEqual(ring[0], ring[-1])
        self.assertEqual(len(ring), 5)

    def test_a_gap_is_refused(self) -> None:
        self.assertIsNone(f.stitch_rings([[[0.0, 0.0], [1.0, 0.0]], [[1.0, 1.0], [0.0, 1.0]]]))

    def answer(self) -> dict:
        cairo_outer = square(31.0, 29.8, 31.6, 30.3)
        left, right = cairo_outer[:3], cairo_outer[2:]  # two pieces
        return {"elements": [
            {"type": "relation", "id": 1, "tags": {"ISO3166-2": "EG-C", "name": "محافظة القاهرة", "name:en": "Cairo Governorate"},
             "members": [way_member(left), way_member(right), way_member(square(31.2, 30.0, 31.3, 30.1), "inner"),
                         {"type": "node", "ref": 9, "role": "admin_centre", "lat": 30.04, "lon": 31.23}]},
            # Name says Giza, but the ISO code wins (EG-GZ).
            {"type": "relation", "id": 2, "tags": {"ISO3166-2": "EG-GZ", "name": "unknown name"},
             "members": [way_member(square(30.5, 29.0, 31.0, 30.3))]},
            {"type": "relation", "id": 3, "tags": {"ISO3166-2": "EG-ALX", "name:en": "Alexandria"},
             "members": [way_member([[29.5, 31.0], [30.2, 31.0]])]},  # broken: not closed
        ]}

    def test_relations_to_multipolygons_and_back_through_the_importer(self) -> None:
        doc, problems = f.boundaries_geojson(self.answer(), "2026-11-15T10:00:00Z", "x")
        self.assertEqual([x["properties"]["ISO3166-2"] for x in doc["features"]], ["EG-C", "EG-GZ"])
        self.assertEqual(len(problems), 1)
        self.assertIn("EG-ALX", problems[0])
        cairo = doc["features"][0]["geometry"]
        self.assertEqual(cairo["type"], "MultiPolygon")
        self.assertEqual(len(cairo["coordinates"]), 1)
        self.assertEqual(len(cairo["coordinates"][0]), 2)  # outer + hole
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / f.BOUNDARIES_FILE
            f.write_json_atomic(path, doc)
            load_problems: list[str] = []
            b = Boundaries.load([path], load_problems)
        self.assertEqual(load_problems, [])
        self.assertEqual(b.governorate_at(30.05, 31.45), "cairo")
        self.assertIsNone(b.governorate_at(30.05, 31.25))  # in the hole
        self.assertEqual(b.governorate_at(29.5, 30.7), "giza")
        self.assertIsNone(b.governorate_at(25.0, 33.0))

    def test_indexed_ring_agrees_with_plain_ray_casting(self) -> None:
        rnd = random.Random(7)
        ring = []
        for i in range(400):  # a star-shaped ring with many points
            angle = 2 * math.pi * i / 400
            radius = 1 + 0.4 * rnd.random()
            ring.append([31 + radius * math.cos(angle), 30 + radius * math.sin(angle)])
        ring.append(ring[0])
        indexed = _IndexedRing(ring)
        for _ in range(3000):
            lat, lng = 30 + rnd.uniform(-1.6, 1.6), 31 + rnd.uniform(-1.6, 1.6)
            self.assertEqual(indexed.contains(lat, lng), f._ring_contains(ring, lng, lat), (lat, lng))


class OverpassTest(unittest.TestCase):
    def test_falls_back_to_the_next_server(self) -> None:
        calls: list[str] = []
        waits: list[float] = []

        def post(url: str, body: bytes, timeout: float) -> bytes:
            calls.append(url)
            self.assertIn(b"data=", body)
            if "first" in url:
                raise urllib.error.HTTPError(url, 429, "Too Many Requests", {}, io.BytesIO(b""))  # type: ignore[arg-type]
            if "second" in url:
                return json.dumps({"elements": [], "remark": "runtime error: Query timed out in \"query\" at line 3"}).encode()
            return json.dumps(SCHOOLS_ANSWER).encode()

        answer, used = f.overpass(
            "q", ["https://first/api", "https://second/api", "https://third/api"], post=post, sleep=waits.append, log=lambda _: None
        )
        self.assertEqual(used, "https://third/api")
        self.assertEqual(len(answer["elements"]), 6)
        self.assertEqual(calls, ["https://first/api"] * 2 + ["https://second/api"] * 2 + ["https://third/api"])
        self.assertEqual(waits[0], 30.0)  # the usage policy's pause after 429

    def test_clear_error_when_every_server_fails(self) -> None:
        def post(url: str, body: bytes, timeout: float) -> bytes:
            raise urllib.error.URLError("no route")

        with self.assertRaises(f.FetchError) as ctx:
            f.overpass("q", ["https://a/api", "https://b/api"], post=post, sleep=lambda _: None, log=lambda _: None)
        self.assertIn("a: network error", str(ctx.exception))
        self.assertIn("b: network error", str(ctx.exception))
        self.assertIn("run the same command again", str(ctx.exception))

    def test_not_json_is_retried(self) -> None:
        with self.assertRaises(f._Retryable):
            f.check_answer(b"<html>busy</html>")

    def test_query_text(self) -> None:
        # The forms checked against the OpenStreetMap wiki (Overpass QL page).
        self.assertIn('area["ISO3166-1"="EG"][admin_level=2]->.eg;', f.SCHOOLS_QUERY)
        self.assertIn('nwr["amenity"~"^(school|kindergarten)$"](area.eg);', f.SCHOOLS_QUERY)
        # "out center;" keeps node coordinates ("out tags" would drop them).
        self.assertIn("\nout center;", f.SCHOOLS_QUERY)
        self.assertNotIn("out center tags", f.SCHOOLS_QUERY)
        self.assertTrue(f.SCHOOLS_QUERY.startswith("[out:json][timeout:900];"))
        self.assertIn("out geom;", f.BOUNDARIES_QUERY)


class FreshnessTest(unittest.TestCase):
    def test_a_recent_download_is_kept(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            recent = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
            f.write_json_atomic(out / f.SCHOOLS_FILE, f.schools_geojson(SCHOOLS_ANSWER, recent, "x"))
            self.assertIsNotNone(f.fetched_at_of(out / f.SCHOOLS_FILE))
            # No network: main returns before asking any server.
            code = f.main(["--out", str(out), "--boundaries-out", str(out / "b"), "--max-age-days", "7",
                           "--endpoint", "https://invalid.invalid/api"])
            self.assertEqual(code, 0)
            self.assertFalse((out / "b").exists())

    def test_missing_or_broken_file_has_no_date(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(f.fetched_at_of(Path(tmp) / "none.geojson"))
            (Path(tmp) / "x.geojson").write_text("{}", encoding="utf-8")
            self.assertIsNone(f.fetched_at_of(Path(tmp) / "x.geojson"))


if __name__ == "__main__":
    unittest.main()
