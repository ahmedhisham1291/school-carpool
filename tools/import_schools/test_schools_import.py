"""Tests for the schools import (F4). Run: python3 -m unittest discover -s tools/import_schools -v"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import import_schools  # noqa: E402
from schools_import import (  # noqa: E402
    Boundaries,
    RawEntry,
    clean,
    doc_id,
    find_duplicates,
    compare,
    governorate_code,
    is_contained,
    match_tokens,
    name_tags,
    nearest_town,
    normalize_text,
    read_csv,
    report_markdown,
    run,
    schools_json,
    token_similarity,
)

SAMPLE = Path(__file__).resolve().parents[2] / "data" / "schools" / "sample"


def entry(**kw) -> RawEntry:
    base = dict(
        source="osm", source_id="n1", kind="school", amenity="school", name="", name_ar="", name_en="",
        governorate_text="", city_text="", lat=30.0444, lng=31.2357, file="t.geojson",
    )
    base.update(kw)
    return RawEntry(**base)


class NormalizeTest(unittest.TestCase):
    # Same cases as functions/test/schools.test.ts and test/schools/schools_logic_test.dart.
    def test_arabic_forms(self):
        self.assertEqual(normalize_text("مَدْرَسَةُ"), "مدرسه")
        self.assertEqual(normalize_text("أحمد إبراهيم آمال ٱلنور"), "احمد ابراهيم امال النور")
        self.assertEqual(normalize_text("مستشفى"), "مستشفي")
        self.assertEqual(normalize_text("مدرســـة"), "مدرسه")
        self.assertEqual(normalize_text("الدوليّة"), "الدوليه")

    def test_latin_digits_and_punctuation(self):
        self.assertEqual(normalize_text("  St. Mark's   College "), "st mark s college")
        self.assertEqual(normalize_text("مدرسة ٦ أكتوبر"), "مدرسه 6 اكتوبر")
        self.assertEqual(normalize_text("Lycée"), "lycée")

    def test_same_key_for_spelling_variants(self):
        self.assertEqual(normalize_text("مدرسة النيل الدولية"), normalize_text("مدرسه النيل الدوليه"))
        self.assertEqual(normalize_text("كلية فيكتوريا"), normalize_text("كليه فيكتوريا"))


class MatchTest(unittest.TestCase):
    def test_generic_words_dropped(self):
        self.assertEqual(match_tokens("مدرسة النيل الدولية"), ("نيل", "دوليه"))
        # Stage and gender words are compared separately (name_tags).
        self.assertEqual(match_tokens("مدرسة النصر الابتدائية بنات"), ("نصر",))
        self.assertEqual(name_tags("مدرسة النصر الابتدائية بنات"), (frozenset({"primary"}), frozenset({"girls"})))
        self.assertEqual(name_tags("Nasr Secondary School for Boys"), (frozenset({"secondary"}), frozenset({"boys"})))
        # Person names are marked: no spelling slip in them.
        self.assertEqual(match_tokens("مدرسة الشهيد أحمد زويل"), ("شهيد", "~احمد", "~زويل"))
        self.assertEqual(match_tokens("Nile Intl School"), ("nile", "international"))
        self.assertEqual(match_tokens("مدرسة"), ())
        self.assertEqual(match_tokens("School"), ())

    def test_similarity(self):
        self.assertEqual(token_similarity(("victoria", "college"), ("victoria", "collage")), 1.0)
        # Containment is not a match: a third of the words.
        self.assertAlmostEqual(token_similarity(("alsson",), ("alsson", "british", "american")), 1 / 3)
        self.assertTrue(is_contained(("alsson",), ("alsson", "british", "american")))
        self.assertFalse(is_contained(("alsson", "x"), ("alsson", "british")))
        self.assertEqual(token_similarity(("بورسعيد", "تجريبيه"), ("بورسعيد", "بالزمالك")), 0.5)
        self.assertEqual(token_similarity((), ("x",)), 0.0)
        self.assertLess(token_similarity(("nile",), ("pyramids",)), 0.5)

    def test_spelling_slip_only_in_long_words_and_never_in_names(self):
        self.assertEqual(token_similarity(("فكتوريا",), ("فيكتوريا",)), 1.0)  # 7 and 8 letters
        self.assertEqual(token_similarity(("nile",), ("nila",)), 0.0)  # too short for a slip
        self.assertEqual(token_similarity(match_tokens("مدرسة الشهيد أحمد"), match_tokens("مدرسة الشهيد محمد")), 0.5)
        self.assertLess(token_similarity(match_tokens("مدرسة الشهيد محمد علي"), match_tokens("مدرسة الشهيد محمود علي")), 1.0)
        self.assertLess(token_similarity(match_tokens("Ibrahim School"), match_tokens("Ibraheem School")), 1.0)


class PlacesTest(unittest.TestCase):
    def test_governorate_names(self):
        self.assertEqual(governorate_code("محافظة الجيزة"), "giza")
        self.assertEqual(governorate_code("الاسكندريه"), "alexandria")
        self.assertEqual(governorate_code("Giza Governorate"), "giza")
        self.assertEqual(governorate_code("kafr_el_sheikh"), "kafr_el_sheikh")
        self.assertEqual(governorate_code("Port Said"), "port_said")
        self.assertIsNone(governorate_code("Atlantis"))
        self.assertIsNone(governorate_code(""))

    def test_nearest_town(self):
        self.assertEqual(nearest_town(29.97, 30.94)[0], "giza")  # 6th of October
        self.assertEqual(nearest_town(30.03, 31.47)[0], "cairo")  # New Cairo
        self.assertEqual(nearest_town(31.22, 29.95)[0], "alexandria")
        self.assertEqual(nearest_town(30.23, 31.48)[0], "qalyubia")  # Obour

    def test_boundaries_win_over_nearest_town(self):
        square = [[[31.0, 30.0], [31.1, 30.0], [31.1, 30.1], [31.0, 30.1], [31.0, 30.0]]]
        b = Boundaries(shapes=[("qalyubia", [square])])
        self.assertEqual(b.governorate_at(30.05, 31.05), "qalyubia")
        self.assertIsNone(b.governorate_at(30.2, 31.05))
        schools, _ = clean([entry(name="Nile School", lat=30.05, lng=31.05)], b)
        self.assertEqual((schools[0].governorate, schools[0].governorate_method), ("qalyubia", "boundary"))

    def test_doc_ids_are_stable_and_safe(self):
        self.assertEqual(doc_id("osm", "n123"), "osm-n123")
        self.assertEqual(doc_id("list_moe", "A/7 b"), "list_moe-A-7-b")
        long_id = doc_id("list_" + "x" * 80, "1")
        self.assertLessEqual(len(long_id), 64)
        self.assertEqual(long_id, doc_id("list_" + "x" * 80, "1"))


class CleanTest(unittest.TestCase):
    def test_drops_with_reasons(self):
        entries = [
            entry(source_id="n1", name=""),
            entry(source_id="n2", name="مدرسة"),
            entry(source_id="n3", kind=None, amenity="university", name="Cairo University"),
            entry(source_id="n4", kind=None, amenity="driving_school", name="مدرسة قيادة"),
            entry(source_id="n5", name="Far School", lat=33.9, lng=35.5),
            entry(source="list_moe", source_id="1", name_ar="مدرسة بلا مكان", lat=None, lng=None),
            entry(source_id="n6", name="Nile School"),
            entry(source_id="n6", name="Nile School"),
        ]
        schools, dropped = clean(entries, Boundaries())
        self.assertEqual([s.id for s in schools], ["osm-n6"])
        self.assertEqual(
            [d.reason for d in dropped],
            ["no_name", "generic_name", "not_school_university", "not_school_courses", "outside_egypt",
             "no_location_or_governorate", "repeated_source_id"],
        )

    def test_names_city_and_governorate(self):
        schools, _ = clean([entry(name="مدرســة النيل", name_en="Nile School", lat=29.9602, lng=31.2569)], Boundaries())
        s = schools[0]
        self.assertEqual((s.name_ar, s.name_en), ("مدرسة النيل", "Nile School"))
        self.assertEqual((s.governorate, s.governorate_method, s.city, s.city_ar), ("cairo", "nearest", "Maadi", "المعادي"))
        # One language only: the other name falls back to it.
        s2 = clean([entry(source_id="n2", name="Nile School")], Boundaries())[0][0]
        self.assertEqual((s2.name_ar, s2.name_en), ("Nile School", "Nile School"))

    def test_list_without_pin_keeps_given_governorate(self):
        schools, _ = clean([entry(source="list_moe", name_ar="مدرسة النيل", governorate_text="القاهرة", lat=None, lng=None)], Boundaries())
        self.assertEqual((schools[0].governorate, schools[0].governorate_method, schools[0].lat), ("cairo", "given", None))


class DuplicatesTest(unittest.TestCase):
    def test_merges_similar_names_within_300_m_only(self):
        entries = [
            entry(source_id="n1", name="مدرسة النيل الدولية", name_en="Nile International School", lat=30.0, lng=31.2),
            entry(source_id="w2", name="مدرسه النيل الدوليه", lat=30.0015, lng=31.2),  # about 170 m
            entry(source_id="n3", name="مدرسة النيل الدولية", lat=30.0055, lng=31.2),  # about 610 m (445 m from w2): report only
            entry(source_id="n4", name="مدرسة الأهرام", lat=30.0005, lng=31.2),  # near, other name
        ]
        schools, _ = clean(entries, Boundaries())
        merged, groups, likely = find_duplicates(schools)
        self.assertEqual(sorted(s.id for s in merged), ["osm-n1", "osm-n3", "osm-n4"])
        self.assertEqual(groups[0][0].id, "osm-n1")
        kept = next(s for s in merged if s.id == "osm-n1")
        self.assertEqual(kept.source_keys, ["osm:n1", "osm:w2"])
        self.assertEqual(kept.name_en, "Nile International School")
        self.assertTrue(any({p.a.id, p.b.id} == {"osm-n1", "osm-n3"} for p in likely))

    def test_list_entry_without_pin_merges_by_name_and_governorate(self):
        entries = [
            entry(source_id="n1", name="مدرسة الأورمان", name_en="Orman School", lat=30.03, lng=31.212),
            entry(source="list_moe", source_id="7", name_ar="مدرسه الاورمان", governorate_text="الجيزة", lat=None, lng=None),
            entry(source="list_moe", source_id="8", name_ar="مدرسه الاورمان", governorate_text="أسوان", lat=None, lng=None),
        ]
        merged, _, _ = find_duplicates(clean(entries, Boundaries())[0])
        ids = sorted(s.id for s in merged)
        self.assertEqual(ids, ["list_moe-7", "list_moe-8"])
        kept = next(s for s in merged if s.id == "list_moe-7")
        self.assertEqual((kept.lat, kept.name_en), (30.03, "Orman School"))


class SameSchoolOrNotTest(unittest.TestCase):
    """Cases from the Prompt 4B review: these must never be merged."""

    def school(self, name: str, sid: str, lat: float = 30.0, lng: float = 31.2, kind: str = "school"):
        return clean([entry(source_id=sid, name=name, kind=kind, lat=lat, lng=lng)], Boundaries())[0][0]

    def verdict(self, a: str, b: str) -> str:
        return compare(self.school(a, "n1"), self.school(b, "n2"))[0]

    def test_different_stage_or_gender_never_merges(self):
        self.assertEqual(self.verdict("مدرسة النصر الابتدائية", "مدرسة النصر الإعدادية"), "different")
        self.assertEqual(self.verdict("Nasr Primary School", "Nasr Secondary School"), "different")
        self.assertEqual(self.verdict("مدرسة سعد زغلول الابتدائية", "مدرسة سعد زغلول الثانوية بنات"), "different")
        self.assertEqual(self.verdict("مدرسة النصر بنين", "مدرسة النصر بنات"), "different")
        self.assertEqual(self.verdict("Nasr Boys School", "Nasr Girls School"), "different")
        kg = self.school("Nasr", "n3", kind="kindergarten")
        self.assertEqual(compare(kg, self.school("Nasr", "n4"))[0], "different")

    def test_only_one_side_says_the_stage_is_reported(self):
        self.assertEqual(self.verdict("مدرسة النصر", "مدرسة النصر الابتدائية"), "report")
        self.assertEqual(self.verdict("مدرسة النصر", "مدرسة النصر بنات"), "report")

    def test_different_people_are_reported_not_merged(self):
        self.assertEqual(self.verdict("مدرسة الشهيد أحمد", "مدرسة الشهيد محمد"), "report")
        self.assertEqual(self.verdict("مدرسة الشهيد محمد علي", "مدرسة الشهيد محمود علي"), "report")

    def test_one_name_inside_the_other_is_reported(self):
        self.assertEqual(self.verdict("El Alsson School", "El Alsson British and American International School"), "report")

    def test_same_name_merges(self):
        self.assertEqual(self.verdict("مدرسة النصر الابتدائية", "مدرسه النصر الابتدائيه"), "merge")
        self.assertEqual(self.verdict("Victoria College", "Victoria Collage"), "merge")

    def test_merge_pipeline_keeps_stages_apart(self):
        entries = [
            entry(source_id="n1", name="مدرسة النصر الابتدائية", lat=30.0, lng=31.2),
            entry(source_id="n2", name="مدرسة النصر الإعدادية", lat=30.0005, lng=31.2),
            entry(source_id="n3", name="مدرسة النصر الثانوية بنات", lat=30.001, lng=31.2),
            entry(source_id="n4", name="مدرسة النصر", lat=30.0007, lng=31.2),
        ]
        merged, groups, likely = find_duplicates(clean(entries, Boundaries())[0])
        self.assertEqual(len(merged), 4)
        self.assertEqual(groups, [])
        # The one without a stage is listed against each one with a stage.
        self.assertEqual(sorted(p.b.id if p.a.id == "osm-n4" else p.a.id for p in likely), ["osm-n1", "osm-n2", "osm-n3"])

    def test_no_chains(self):
        # A~B and B~C (one slip each) but A and C differ by two letters.
        entries = [
            entry(source_id="n1", name="Montessoriana School", lat=30.0, lng=31.2),
            entry(source_id="n2", name="Montessorian School", lat=30.0005, lng=31.2),
            entry(source_id="n3", name="Montessoria School", lat=30.001, lng=31.2),
        ]
        schools = clean(entries, Boundaries())[0]
        self.assertEqual(compare(schools[0], schools[2])[0], "different")
        merged, groups, likely = find_duplicates(schools)
        for group in groups:
            ids = {s.id for s in group}
            self.assertFalse({"osm-n1", "osm-n3"} <= ids, "n1 and n3 must not end up in one group")
        self.assertGreaterEqual(len(merged), 2)


class ReadersTest(unittest.TestCase):
    def test_list_csv_with_arabic_headers(self):
        data = "كود المدرسة,اسم المدرسة,المحافظة,الإدارة,خط العرض,خط الطول,ملاحظات\nA1,مدرسة النيل,القاهرة,المعادي,٢٩٫٩٦,31.25,x\n".encode()
        entries, ignored = read_csv(data, "moe.csv", "moe")
        self.assertEqual(ignored, ["ملاحظات"])
        e = entries[0]
        self.assertEqual((e.source, e.source_id, e.name_ar, e.governorate_text, e.city_text, e.lat, e.lng), ("list_moe", "A1", "مدرسة النيل", "القاهرة", "المعادي", 29.96, 31.25))

    def test_excel_exports_bom_utf16_cp1256_and_semicolons(self):
        text = "اسم المدرسة;المحافظة;الإدارة\nمدرسة النيل;القاهرة;المعادي\n"
        for data in (
            b"\xef\xbb\xbf" + text.encode("utf-8"),
            text.encode("utf-16"),
            text.encode("cp1256"),
            text.replace(";", ",").encode("utf-8"),
            text.replace(";", "\t").encode("utf-8"),
        ):
            entries, _ = read_csv(data, "moe.csv", "moe")
            self.assertEqual([(e.name_ar, e.governorate_text, e.city_text) for e in entries], [("مدرسة النيل", "القاهرة", "المعادي")])

    def test_unreadable_file_is_reported_not_a_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "bad.csv").write_bytes(bytes([0x81, 0x8D, 0x8F, 0x90, 0x9D]) * 10 + b"\x00\xff")
            (folder / "bad.geojson").write_text("{not json", encoding="utf-8")
            (folder / "ok.csv").write_text("name_ar,governorate\nمدرسة النيل,القاهرة\n", encoding="utf-8")
            result = run(folder)
        self.assertEqual(len(result.schools), 1)
        self.assertTrue(any("bad.geojson" in p for p in result.problems))

    def test_list_ids_do_not_shift_when_rows_move(self):
        a = "name_ar,governorate,city\nمدرسة النيل,القاهرة,المعادي\nمدرسة الأهرام,الجيزة,الهرم\n"
        b = "name_ar,governorate,city\nمدرسة جديدة,الجيزة,الدقي\nمدرسة الأهرام,الجيزة,الهرم\nمدرسة النيل,القاهرة,المعادي\n"
        ids_a = {e.name_ar: e.source_id for e in read_csv(a.encode(), "moe.csv", "moe")[0]}
        ids_b = {e.name_ar: e.source_id for e in read_csv(b.encode(), "moe.csv", "moe")[0]}
        self.assertEqual(ids_a["مدرسة النيل"], ids_b["مدرسة النيل"])
        self.assertEqual(ids_a["مدرسة الأهرام"], ids_b["مدرسة الأهرام"])
        self.assertNotEqual(ids_a["مدرسة النيل"], ids_a["مدرسة الأهرام"])

    def test_osm_types_keep_their_prefix(self):
        for osm_type, expected in (("node", "n5"), ("nodes", "n5"), ("ways_poly", "w5"), ("way", "w5"), ("relation", "r5"), ("", "5")):
            e = read_csv(f"osm_id,osm_type,name,amenity\n5,{osm_type},Nile School,school\n".encode(), "x.csv", "x")[0][0]
            self.assertEqual(e.source_id, expected, osm_type)

    def test_osm_csv_and_zip(self):
        csv_text = "osm_id,osm_type,name,name:en,amenity,geometry\n42,node,مدرسة النيل,Nile School,school,POINT (31.25 29.96)\n"
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr("hotosm_egy_education_facilities_points_csv.csv", csv_text)
            (folder / "export.zip").write_bytes(buffer.getvalue())
            result = run(folder)
        self.assertEqual([s.id for s in result.schools], ["osm-n42"])
        self.assertEqual((result.schools[0].lat, result.schools[0].lng), (29.96, 31.25))


class SampleRunTest(unittest.TestCase):
    def test_sample_report_and_idempotent_output(self):
        result = run(SAMPLE)
        self.assertEqual(len(result.files), 3)
        self.assertGreaterEqual(len(result.schools), 38)
        govs = {s.governorate for s in result.schools}
        self.assertEqual(govs, {"cairo", "giza", "alexandria"})
        reasons = {d.reason for d in result.dropped}
        self.assertTrue({"no_name", "generic_name", "not_school_university", "outside_egypt"} <= reasons)
        self.assertEqual(len(result.merged_groups), 4)
        self.assertEqual(len(result.likely), 3)
        report = report_markdown(result, "T")
        for heading in ("## Schools per governorate", "## Dropped, and why", "## Likely duplicates to check"):
            self.assertIn(heading, report)
        # Same input, same output (IDs included): a second import changes nothing.
        again = run(SAMPLE)
        self.assertEqual(json.dumps(schools_json(result, "T")), json.dumps(schools_json(again, "T")))
        ids = [s.id for s in result.schools]
        self.assertEqual(len(ids), len(set(ids)))

    def test_cli_writes_both_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = import_schools.main(["--input", str(SAMPLE), "--out", tmp, "--generated-at", "T"])
            self.assertEqual(code, 0)
            data = json.loads((Path(tmp) / "schools.json").read_text(encoding="utf-8"))
            self.assertEqual(data["format"], "school-carpool-schools/1")
            first = data["schools"][0]
            self.assertEqual(
                sorted(first),
                sorted(["id", "source", "sourceId", "sourceKeys", "nameAr", "nameEn", "kind", "governorate",
                        "governorateMethod", "city", "cityAr", "location"]),
            )
            self.assertTrue((Path(tmp) / "report.md").exists())


if __name__ == "__main__":
    unittest.main()
