"""Tests for ai_review.py with a fake model and an in-memory cache: batching,
what is sent (no positions), answer validation, cache, threshold, cost cap,
Vertex request/answer shapes, Firestore cache shapes, and the importer
applying the AI's decisions after the manual ones. No network.

Run: python3 -m unittest discover -s tools/import_schools -v
"""

from __future__ import annotations

import csv
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ai_review as ai  # noqa: E402
import fetch_osm_schools as osm  # noqa: E402
import schools_import as si  # noqa: E402

COLUMNS = si.REVIEW_INPUT_COLUMNS


def row(source: str, sid: str, ar: str, en: str, lat: float | None, lng: float | None, gid: str, *, drop: str = "", kind: str = "school",
        gov: str = "cairo", cat: str = "") -> dict[str, str]:
    return {
        "source": source, "source_id": sid, "name_ar": ar, "name_en": en, "raw_names": f"{ar} | | {en}", "kind": kind, "category": cat,
        "confidence": "", "governorate": gov, "lat": "" if lat is None else f"{lat:.3f}", "lon": "" if lng is None else f"{lng:.3f}",
        "drop_reason": drop, "group_id": gid,
    }


ROWS = [
    row("osm", "n1", "مدرسة النيل", "Nile School", 30.050, 31.240, "osm-n1"),
    row("overture", "x1", "مدرسة النيل", "Nile School", 30.051, 31.241, "osm-n1", cat="high_school"),  # merged into osm-n1
    row("osm", "n2", "سنتر الأوائل للدروس", "Awael Center", 30.052, 31.242, "osm-n2"),
    row("osm", "n3", "NILE SCHOOL OFFICIAL PAGE", "NILE SCHOOL OFFICIAL PAGE", 30.053, 31.243, "osm-n3"),
    row("osm", "n4", "روضة الزهور", "Zohour KG", 31.200, 29.900, "osm-n4", gov="alexandria"),
    row("osm", "n5", "Dropped", "Dropped", 30.0, 31.2, "", drop="no_name"),
]


def write_input(folder: Path, rows: list[dict[str, str]] = ROWS) -> Path:
    path = folder / "review_input.csv"
    buffer = io.StringIO()
    w = csv.DictWriter(buffer, fieldnames=COLUMNS)
    w.writeheader()
    w.writerows(rows)
    path.write_text("﻿" + buffer.getvalue(), encoding="utf-8")
    return path


class FakeModel:
    """Answers from a table id -> result; records what was sent."""

    def __init__(self, answers: dict[str, dict], tokens: tuple[int, int] = (1000, 200)) -> None:
        self.answers = answers
        self.payloads: list[dict] = []
        self.tokens = tokens

    def __call__(self, payload: str) -> tuple[object, int, int]:
        doc = json.loads(payload)
        self.payloads.append(doc)
        results = [{"id": s["id"], **self.answers.get(s["id"], {"verdict": "ok", "reason": "real school", "confidence": 0.95})} for s in doc["schools"]]
        return {"results": results}, *self.tokens


ANSWERS = {
    "osm-n2": {"verdict": "drop", "reason": "tutoring centre", "confidence": 0.97},
    "osm-n3": {"verdict": "rename", "new_name_en": "Nile School", "new_name_ar": "", "reason": "remove official page", "confidence": 0.9},
    "osm-n4": {"verdict": "kind", "kind": "kindergarten", "reason": "a KG", "confidence": 0.6},  # below 0.8: kept as is
}


class InputTest(unittest.TestCase):
    def test_entities_neighbours_and_payload(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ents = ai.read_entities(write_input(Path(tmp)))
        self.assertEqual([e.id for e in ents], ["osm-n1", "osm-n2", "osm-n3", "osm-n4"])
        nile = ents[0]
        self.assertEqual((nile.key, nile.keys, nile.category), ("osm:n1", ["osm:n1", "overture:x1"], "high_school"))
        ai.add_neighbours(ents)
        self.assertEqual(nile.near, ["osm-n2", "osm-n3"])  # Alexandria is far
        self.assertEqual(ents[3].near, [])
        by_id = {e.id: e for e in ents}
        payload = ai.batch_payload(ents[:2], by_id)
        self.assertNotIn("lat", payload)
        self.assertNotIn("30.05", payload)
        self.assertEqual(json.loads(payload)["schools"][0]["near"][0], {"id": "osm-n2", "ar": "سنتر الأوائل للدروس", "en": "Awael Center"})

    def test_batches_by_governorate(self) -> None:
        ents = [ai.Entity(f"s{i}", f"osm:n{i}", [], "a", "a", "school", "", "giza" if i % 2 else "cairo") for i in range(5)]
        got = ai.batches(ents, 2)
        self.assertEqual([[e.id for e in b] for b in got], [["s0", "s2"], ["s4", "s1"], ["s3"]])


class ValidateTest(unittest.TestCase):
    def test_answers_that_are_not_usable(self) -> None:
        ids = {"a", "b", "c", "d", "e", "f"}
        names = {i: ("مدرسة النيل", "Nile School") for i in ids}
        allowed = {i: ids - {i} for i in ids}
        raw = {"results": [
            {"id": "a", "verdict": "explode", "reason": "x", "confidence": 0.9},
            {"id": "b", "verdict": "merge_with", "merge_with": "zzz", "reason": "x", "confidence": 0.9},
            {"id": "c", "verdict": "rename", "new_name_en": "Cairo American College", "reason": "x", "confidence": 0.9},  # invented
            {"id": "d", "verdict": "rename", "new_name_en": "Nile Schol", "new_name_ar": "مدرسه النيل", "reason": "x", "confidence": 0.9},
            {"id": "e", "verdict": "kind", "kind": "university", "reason": "x", "confidence": 0.9},
            {"id": "zz", "verdict": "drop", "reason": "not in the batch", "confidence": 0.9},
            {"id": "a", "verdict": "drop", "reason": "second answer", "confidence": 0.9},
        ]}
        got = {v.id: v for v in ai.validate(raw, ids, allowed, names)}
        self.assertEqual(got["a"].problem, "bad verdict or confidence")
        self.assertIn("merge_with", got["b"].problem)
        self.assertIn("rename", got["c"].problem)
        self.assertEqual((got["d"].verdict, got["d"].new_name_en, got["d"].new_name_ar), ("rename", "Nile Schol", "مدرسه النيل"))
        self.assertIn("kind", got["e"].problem)
        self.assertEqual(got["f"].problem, "missing")
        self.assertEqual(ai.validate("not json", {"a"}, {}, {"a": ("", "")})[0].problem, "missing")


class ReviewRunTest(unittest.TestCase):
    def run_review(self, cache: ai.MemoryCache, model: FakeModel, **kw) -> ai.Outcome:
        with tempfile.TemporaryDirectory() as tmp:
            ents = ai.read_entities(write_input(Path(tmp), kw.pop("rows", ROWS)))
        ai.add_neighbours(ents)
        self.ents = ents
        return ai.review(ents, model, cache, "gemini-3.8-flash", now="2026-11-16T12:00:00Z", log=lambda _m: None, **kw)

    def test_threshold_decisions_and_csv(self) -> None:
        out = self.run_review(ai.MemoryCache(), FakeModel(ANSWERS))
        rows, counts = ai.decisions_rows(self.ents, out.verdicts, 0.8)
        self.assertEqual(counts["dropped"], 1)
        self.assertEqual(counts["renamed"], 1)
        self.assertEqual(counts["low-confidence kept"], 1)
        self.assertEqual(counts["ok"], 1)
        self.assertEqual([(r["source"], r["source_id"], r["action"], r["value"]) for r in rows],
                         [("osm", "n2", "drop", ""), ("osm", "n3", "rename_en", "Nile School")])
        review_rows = {r["id"]: r for r in ai.review_rows(self.ents, out.verdicts, 0.8)}
        self.assertEqual((review_rows["osm-n4"]["verdict"], review_rows["osm-n4"]["applied"]), ("kind", "no"))
        line = ai.summary_line(counts, out, out.usage.cost(0.825, 4.125), "gemini-vertex", "gemini-3.8-flash")
        self.assertIn("dropped 1, renamed 1", line)
        self.assertIn("low-confidence kept 1", line)

    def test_a_merged_school_is_dropped_with_all_its_entries(self) -> None:
        out = self.run_review(ai.MemoryCache(), FakeModel({"osm-n1": {"verdict": "drop", "reason": "x", "confidence": 0.9}}))
        rows, _ = ai.decisions_rows(self.ents, out.verdicts, 0.8)
        self.assertEqual(sorted(f"{r['source']}:{r['source_id']}" for r in rows), ["osm:n1", "overture:x1"])

    def test_merge_across_batches_through_neighbours(self) -> None:
        model = FakeModel({"osm-n3": {"verdict": "merge_with", "merge_with": "osm-n1", "reason": "same school", "confidence": 0.9}})
        out = self.run_review(ai.MemoryCache(), model, batch_size=1)
        self.assertEqual(out.usage.calls, 4)
        rows, counts = ai.decisions_rows(self.ents, out.verdicts, 0.8)
        self.assertEqual(rows, [{"source": "osm", "source_id": "n3", "action": "merge_into", "value": "osm:n1", "reason": "AI: same school"}])
        self.assertEqual(counts["merged"], 1)

    def test_cache_sends_only_new_or_changed(self) -> None:
        cache = ai.MemoryCache()
        first = self.run_review(cache, FakeModel(ANSWERS))
        self.assertEqual((first.sent, first.cached), (4, 0))
        again_model = FakeModel(ANSWERS)
        again = self.run_review(cache, again_model)
        self.assertEqual((again.sent, again.cached, again.usage.calls), (0, 4, 0))
        self.assertTrue(again.verdicts["osm-n2"].cached)
        self.assertEqual(again.verdicts["osm-n2"].verdict, "drop")
        # Alexandria's KG renamed upstream: only it is sent again (it has no neighbours).
        rows = [dict(r) for r in ROWS]
        rows[4]["name_en"] = "Zohour Kindergarten"
        third_model = FakeModel(ANSWERS)
        third = self.run_review(cache, third_model, rows=rows)
        self.assertEqual(third.sent, 1)
        self.assertEqual([s["id"] for s in third_model.payloads[0]["schools"]], ["osm-n4"])

    def test_cost_cap(self) -> None:
        out = self.run_review(ai.MemoryCache(), FakeModel({}), batch_size=1, max_calls=2)
        self.assertTrue(out.stopped)
        self.assertEqual((out.usage.calls, out.sent, out.skipped), (2, 2, 2))
        self.assertEqual(out.usage.input_tokens, 2000)
        self.assertAlmostEqual(out.usage.cost(1.0, 10.0), 0.002 + 0.004)


class VertexTest(unittest.TestCase):
    def test_endpoints(self) -> None:
        self.assertEqual(ai.endpoint("gemini-vertex", "p", "eu", "gemini-3.8-flash"),
                         "https://aiplatform.eu.rep.googleapis.com/v1/projects/p/locations/eu/publishers/google/models/gemini-3.8-flash:generateContent")
        self.assertEqual(ai.endpoint("claude-vertex", "p", "global", "claude-haiku-5-5"),
                         "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/anthropic/models/claude-haiku-5-5:rawPredict")
        self.assertEqual(ai.host_for("europe-west1"), "https://europe-west1-aiplatform.googleapis.com")
        body = ai.request_body("gemini-vertex", "{}")
        self.assertEqual(body["generationConfig"]["responseMimeType"], "application/json")
        self.assertEqual(ai.request_body("claude-vertex", "{}")["anthropic_version"], "vertex-2023-10-16")

    def test_gemini_404_falls_back_to_global_and_answers_parse(self) -> None:
        urls: list[str] = []

        def post(url: str, body: dict, headers: dict) -> dict:
            urls.append(url)
            self.assertEqual(headers["Authorization"], "Bearer t")
            if "/locations/eu/" in url:
                raise urllib.error.HTTPError(url, 404, "not found", {}, None)  # type: ignore[arg-type]
            return {"candidates": [{"content": {"parts": [{"text": "thinking", "thought": True}, {"text": '{"results": []}'}]}}],
                    "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5, "thoughtsTokenCount": 7}}

        model = ai.vertex_model("gemini-vertex", "p", "eu", "gemini-3.8-flash", "t", post=post, log=lambda _m: None)
        self.assertEqual(model("{}"), ({"results": []}, 10, 12))
        self.assertIn("/locations/global/", urls[-1])

    def test_claude_answer_and_a_refusal(self) -> None:
        answer = {"content": [{"type": "text", "text": '```json\n{"results": [{"id": "a"}]}\n```'}], "usage": {"input_tokens": 3, "output_tokens": 4}}
        self.assertEqual(ai.parse_answer("claude-vertex", answer), ({"results": [{"id": "a"}]}, 3, 4))

        def post(url: str, body: dict, headers: dict) -> dict:
            raise urllib.error.HTTPError(url, 403, "denied", {}, None)  # type: ignore[arg-type]

        model = ai.vertex_model("claude-vertex", "p", "global", "claude-haiku-5-5", "t", post=post)
        with self.assertRaises(ai.ReviewUnavailable):
            model("{}")


class FirestoreCacheTest(unittest.TestCase):
    def test_load_pages_and_save_shape(self) -> None:
        pages = [
            {"documents": [{"name": "projects/p/databases/(default)/documents/schoolReview/osm-n1",
                            "fields": {"hash": {"stringValue": "h1"}, "result": {"stringValue": "{}"}}}], "nextPageToken": "t2"},
            {"documents": [{"name": "projects/p/databases/(default)/documents/schoolReview/osm-n2", "fields": {"hash": {"stringValue": "h2"}}}]},
        ]
        got_urls: list[str] = []
        posts: list[dict] = []

        def get(url: str, headers: dict) -> dict:
            got_urls.append(url)
            return pages[len(got_urls) - 1]

        cache = ai.FirestoreCache("p", "t", post=lambda url, body, headers: posts.append({"url": url, **body}) or {}, get=get)
        self.assertEqual(cache.load(), {"osm-n1": {"hash": "h1", "result": "{}"}, "osm-n2": {"hash": "h2"}})
        self.assertIn("pageToken=t2", got_urls[1])
        cache.save({"osm-n1": {"hash": "h", "result": "{}", "model": "m", "reviewedAt": "2026-11-16T12:00:00Z"}})
        self.assertTrue(posts[0]["url"].endswith("/documents:batchWrite"))
        self.assertEqual(posts[0]["writes"][0]["update"]["name"], "projects/p/databases/(default)/documents/schoolReview/osm-n1")


class MainTest(unittest.TestCase):
    def test_unavailable_model_is_a_todo_not_a_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            write_input(folder)
            (folder / ai.OUT_DECISIONS).write_text("stale", encoding="utf-8")
            os.environ["SCHOOLS_AI_TOKEN"] = "t"

            def denied(url: str, body: dict, headers: dict) -> dict:
                raise urllib.error.HTTPError(url, 403, "denied", {}, None)  # type: ignore[arg-type]

            saved_post, saved_load = ai.http_post, ai.FirestoreCache.load
            ai.http_post = denied
            ai.FirestoreCache.load = lambda self: {}  # type: ignore[method-assign]
            try:
                code = ai.main(["--input", str(folder / "review_input.csv"), "--out", str(folder), "--project", "p"])
            finally:
                ai.http_post, ai.FirestoreCache.load = saved_post, saved_load  # type: ignore[method-assign]
                del os.environ["SCHOOLS_AI_TOKEN"]
            self.assertEqual(code, 3)
            self.assertFalse((folder / ai.OUT_DECISIONS).exists())


class ImporterAppliesAiTest(unittest.TestCase):
    def test_manual_wins_and_ai_drop_reason(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "osm").mkdir()
            osm.write_json_atomic(folder / "osm" / osm.SCHOOLS_FILE, osm.schools_geojson({"elements": [
                {"type": "node", "id": 1, "lat": 30.05, "lon": 31.24, "tags": {"amenity": "school", "name": "مدرسة النيل"}},
                {"type": "node", "id": 2, "lat": 30.06, "lon": 31.25, "tags": {"amenity": "school", "name": "مدرسة الأمل"}},
            ]}, "t", "x"))
            (folder / "review").mkdir()  # not the input folder's top level (owner lists are read there)
            manual = folder / "review" / "manual.csv"
            manual.write_text("source,source_id,action,value,reason\nosm,n2,keep,,real school\n", encoding="utf-8")
            aifile = folder / "review" / "ai.csv"
            aifile.write_text("source,source_id,action,value,reason\nosm,n1,drop,,AI: x\nosm,n2,drop,,AI: y\n", encoding="utf-8")
            decisions = si.combine_decisions(si.load_decisions(manual)[0], si.load_decisions(aifile, origin="ai")[0])
            result = si.run(folder, decisions)
        self.assertEqual([s.id for s in result.schools], ["osm-n2"])
        self.assertEqual({d.source_key: d.reason for d in result.dropped}, {"osm:n1": "ai_drop"})
        self.assertEqual(result.review.ai_applied, {"drop": 1})
        self.assertIn("AI decisions applied: drop 1", "\n".join(si.review_lines(result)))


if __name__ == "__main__":
    unittest.main()
