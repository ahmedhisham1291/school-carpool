/**
 * Loads build/schools/schools.json (made by tools/import_schools) into
 * Firestore schools/{id}. Safe to run again, and to run again after it
 * stopped half way: schools are matched by ID and by every source key,
 * unchanged schools are not written, and schools an admin edited or merged
 * (and parents' schools) are left alone (functions/src/schools/catalog.ts).
 * Nothing is deleted.
 *
 *   Emulators:  npm --prefix functions run schools:load:emulator
 *   Cloud:      SCHOOLS_PROJECT=<project-id> npm --prefix functions run schools:load:cloud -- --yes
 *               (gcloud auth application-default login first; see SETUP.md)
 *
 * Options:
 *   --file <path>         default ../build/schools/schools.json
 *   --dry-run             counts only, nothing written
 *   --places <path>       places.json (City -> Area -> District) to load into
 *                         placeAreas / placeDistricts / placeIndex/areas
 *                         (default: places.json next to --file, if there)
 *   --hide-sample <path>  schools.json of the hand-written sample
 *                         (data/schools/sample): sample schools already in
 *                         the project are taken out of search (searchHidden),
 *                         kept as documents. Used once a real list is loaded.
 *
 * Cost (COSTS.md, "Schools list"): one read per school already in the
 * project, one write per new or changed school (about 20,000 to 30,000 the
 * first time with the OpenStreetMap list; Firestore's free tier is 20,000
 * writes a day, so a first load can cost a few US cents), none for
 * unchanged ones. With search on Algolia, syncSchoolToSearch indexes each
 * written school (one function call each, free tier 2 million a month).
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { initializeApp } from "firebase-admin/app";
import { FieldValue, Timestamp, getFirestore, type DocumentData, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import { SCHOOLS } from "../src/admin_panel/store";
import {
  parseDropped,
  parseImportedSchool,
  planAutoMerges,
  planDroppedHiding,
  planImport,
  planSampleHiding,
  planUnhide,
  planUnmerge,
  type MergedImport,
} from "../src/schools/catalog";
import { readAll } from "../src/schools/paged";
import { importedFields, newImportedDoc, readExistingSchools } from "../src/schools/store";
import {
  PLACE_AREAS,
  PLACE_DISTRICTS,
  PLACE_INDEX,
  PLACE_INDEX_AREAS,
  PLACE_INTERNAL,
  INTERNAL_FIELDS,
  buildIndex,
  countSchools,
  internalId,
  parsePlacesFile,
  planPlaces,
  ringsToDoc,
  type ImportedArea,
  type ImportedDistrict,
  type PlaceArea,
  type PlaceDistrict,
} from "../src/places/catalog";
import { areaFromDoc, districtFromDoc, geoPoint } from "../src/places/store";

function refuse(reason: string): never {
  console.error(`load_schools: refusing to run: ${reason}`);
  process.exit(1);
}

const args = process.argv.slice(2);
const flag = (name: string) => args.includes(name);
const option = (name: string): string | undefined => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};

const cloudProject = process.env.SCHOOLS_PROJECT ?? "";
const emulatorProject = process.env.GCLOUD_PROJECT ?? "";
const projectId = cloudProject || emulatorProject;
if (cloudProject) {
  if (!flag("--yes") && !flag("--dry-run")) refuse(`add --yes to write to the cloud project "${cloudProject}"`);
  if (/prod/.test(cloudProject) && option("--file")?.includes("sample")) refuse("never load the sample into prod");
} else {
  if (!process.env.FIRESTORE_EMULATOR_HOST) refuse("FIRESTORE_EMULATOR_HOST is not set (or set SCHOOLS_PROJECT)");
  if (!emulatorProject.startsWith("demo-")) refuse(`project "${emulatorProject}" is not a demo- project`);
}

const file = resolve(option("--file") ?? "../build/schools/schools.json");
const sampleFile = option("--hide-sample");
const placesFile = option("--places") ?? join(dirname(file), "places.json");

/** Firestore allows 500 writes per batch; 400 leaves room. */
const BATCH_SIZE = 400;

function readSchoolsFile(path: string): { usable: MergedImport[]; refused: string[]; dropped: Array<{ key: string; reason: string }> } {
  let doc: { format?: unknown; schools?: unknown; dropped?: unknown };
  try {
    doc = JSON.parse(readFileSync(path, "utf-8"));
  } catch {
    refuse(`cannot read ${path}; run python3 tools/import_schools/import_schools.py first`);
  }
  if (doc.format !== "school-carpool-schools/1" || !Array.isArray(doc.schools)) refuse(`${path} is not a schools.json`);
  const usable: MergedImport[] = [];
  const refused: string[] = [];
  for (const raw of doc.schools as unknown[]) {
    try {
      usable.push(parseImportedSchool(raw));
    } catch (error) {
      refused.push(error instanceof Error ? error.message : String(error));
    }
  }
  return { usable, refused, dropped: parseDropped(doc.dropped) };
}

const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));

/** Commits one batch, retrying a few times on a passing error (quota, network). */
async function commitWithRetry(commit: () => Promise<unknown>, label: string): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try {
      await commit();
      return;
    } catch (error) {
      if (attempt >= 4) throw error;
      const message = error instanceof Error ? error.message : String(error);
      console.log(`  ${label}: ${message.slice(0, 120)}; trying again in ${attempt * 5} s`);
      await sleep(attempt * 5000);
    }
  }
}

async function main(): Promise<void> {
  const { usable: incoming, refused: bad, dropped } = readSchoolsFile(file);
  const sampleKeys = sampleFile ? readSchoolsFile(resolve(sampleFile)).usable.flatMap((s) => s.sourceKeys) : [];

  initializeApp({ projectId });
  const db = getFirestore();
  const existingRead = await readExistingSchools(db);
  // Merged by an earlier import, a school of its own in this run: active
  // again (then updated like any other school).
  const unmerge = new Set(planUnmerge(existingRead, incoming));
  const existing = existingRead.map((s) => (unmerge.has(s.id) ? { ...s, status: "active", mergedInto: "", mergedBy: "" } : s));
  const plan = planImport(incoming, existing);
  const hide = sampleFile ? planSampleHiding(existing, sampleKeys, incoming) : [];
  // Duplicates the import merged (dedupe.py): their earlier documents are
  // hidden into the survivor (status "merged", never deleted).
  const merges = planAutoMerges(incoming, existing, plan);
  // Schools loaded earlier that the rules now drop (names not in Arabic or
  // English, tutoring centres, ...): out of the list, kept as documents.
  const mergedAway = new Set(merges.hide.map((m) => m.id));
  const nowDropped = planDroppedHiding(dropped, existing, incoming).filter((d) => !mergedAway.has(d.id));
  const unhide = planUnhide(existing, incoming);

  console.log(`load_schools: ${projectId}, ${file}`);
  console.log(`  already in the project: ${existing.length} (read once)`);
  console.log(`  in file: ${incoming.length} usable, ${bad.length} refused`);
  console.log(`  new: ${plan.creates.length}, changed: ${plan.updates.length}, unchanged: ${plan.unchanged}`);
  const skipped = new Map<string, number>();
  for (const s of plan.skipped) skipped.set(s.reason, (skipped.get(s.reason) ?? 0) + 1);
  for (const [reason, count] of skipped) console.log(`  left alone (${reason}): ${count}`);
  console.log(`  imported earlier, not in this file (kept): ${plan.notInInput.length}`);
  if (sampleFile) console.log(`  sample schools taken out of search (kept as documents): ${hide.length}`);
  console.log(`  duplicates merged by the import, hidden now (kept as documents): ${merges.hide.length}`);
  const droppedReasons = new Map<string, number>();
  for (const d of nowDropped) droppedReasons.set(d.reason, (droppedReasons.get(d.reason) ?? 0) + 1);
  console.log(`  loaded earlier, dropped by the rules now, taken out of the list (kept as documents): ${nowDropped.length}`
    + (nowDropped.length ? ` (${[...droppedReasons].map(([r, n]) => `${r} ${n}`).join(", ")})` : ""));
  if (unmerge.size) console.log(`  merged by an earlier import, a school of its own now, back in the list: ${unmerge.size}`);
  if (unhide.length) console.log(`  hidden earlier, kept by the rules now, back in the list: ${unhide.length}`);
  if (merges.cancelled.length) console.log(`  import writes skipped because an admin-edited school keeps the group: ${merges.cancelled.length}`);
  if (merges.editedKept.length) console.log(`  admin-edited schools left alone in a merged group: ${merges.editedKept.length}`);
  if (merges.parentLookalikes.length) {
    console.log(`  parents' schools that look like an imported one (not merged; check in the admin panel): ${merges.parentLookalikes.length}`);
    for (const l of merges.parentLookalikes.slice(0, 20)) console.log(`    ${l.id} ~ ${l.like}`);
  }
  for (const message of bad.slice(0, 20)) console.log(`  refused: ${message}`);
  if (flag("--dry-run")) {
    console.log("  dry run: nothing written");
    return;
  }

  const importedAt = Timestamp.now();
  type Batch = ReturnType<typeof db.batch>;
  const writes: Array<(batch: Batch) => void> = [
    ...plan.creates.map((s) => (batch: Batch) => {
      batch.create(db.collection(SCHOOLS).doc(s.id), newImportedDoc(s, importedAt));
    }),
    ...plan.updates.map((u) => (batch: Batch) => {
      batch.update(db.collection(SCHOOLS).doc(u.id), importedFields(u.school, importedAt));
    }),
    ...hide.map((id) => (batch: Batch) => {
      batch.update(db.collection(SCHOOLS).doc(id), { searchHidden: true, updatedAt: FieldValue.serverTimestamp() });
    }),
    ...[...unmerge].map((id) => (batch: Batch) => {
      batch.update(db.collection(SCHOOLS).doc(id), {
        status: "active",
        mergedInto: FieldValue.delete(),
        mergedBy: FieldValue.delete(),
        mergedAt: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }),
    ...unhide.map((id) => (batch: Batch) => {
      batch.update(db.collection(SCHOOLS).doc(id), { searchHidden: false, hiddenReason: FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
    }),
    ...nowDropped.map((d) => (batch: Batch) => {
      batch.update(db.collection(SCHOOLS).doc(d.id), { searchHidden: true, hiddenReason: d.reason, updatedAt: FieldValue.serverTimestamp() });
    }),
    ...merges.hide.map((m) => (batch: Batch) => {
      batch.update(db.collection(SCHOOLS).doc(m.id), {
        status: "merged",
        mergedInto: m.into,
        mergedBy: "import",
        mergedAt: importedAt,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }),
  ];
  const started = Date.now();
  for (let i = 0; i < writes.length; i += BATCH_SIZE) {
    const chunk = writes.slice(i, i + BATCH_SIZE);
    // A new batch per attempt: a committed batch cannot be committed again.
    await commitWithRetry(() => {
      const batch = db.batch();
      for (const write of chunk) write(batch);
      return batch.commit();
    }, `batch ${i / BATCH_SIZE + 1}`);
    const done = Math.min(i + BATCH_SIZE, writes.length);
    if (done === writes.length || (i / BATCH_SIZE) % 10 === 0) {
      console.log(`  written ${done} of ${writes.length} (${Math.round((Date.now() - started) / 1000)} s)`);
    }
  }
  console.log(`load_schools: done. created ${plan.creates.length}, updated ${plan.updates.length}, hidden ${hide.length + nowDropped.length}, merged ${merges.hide.length}`);

  // City -> Area -> District -------------------------------------------
  if (!existsSync(placesFile)) {
    console.log(`load_places: no ${placesFile}; schools have no area (run tools/import_schools/fetch_osm_places.py)`);
    return;
  }
  // The final area of every active school, for the counts.
  const final = new Map<string, { areaId: string | null; districtId: string | null }>();
  for (const e of existing) {
    if (e.status === "active" && e.searchHidden !== true) final.set(e.id, { areaId: e.placeAreaId || null, districtId: e.placeDistrictId ?? null });
  }
  for (const c of plan.creates) final.set(c.id, { areaId: c.placeAreaId || null, districtId: c.placeDistrictId ?? null });
  for (const u of plan.updates) final.set(u.id, { areaId: u.school.placeAreaId || null, districtId: u.school.placeDistrictId ?? null });
  for (const id of hide) final.delete(id);
  for (const m of merges.hide) final.delete(m.id);
  for (const d of nowDropped) final.delete(d.id);
  await loadPlaces(db, placesFile, countSchools([...final.values()]));
}

async function loadPlaces(
  db: ReturnType<typeof getFirestore>,
  path: string,
  counts: { areas: Map<string, number>; districts: Map<string, number> },
): Promise<void> {
  const places = parsePlacesFile(JSON.parse(readFileSync(path, "utf-8")));
  // Paged reads (thousands of districts; one answer must stay small).
  const [areaDocs, districtDocs, internalDocs] = await Promise.all([
    readAll(db, PLACE_AREAS),
    readAll(db, PLACE_DISTRICTS),
    readAll(db, PLACE_INTERNAL, { pageSize: 200 }),
  ]);
  const areaSnap = { docs: areaDocs };
  const districtSnap = { docs: districtDocs };
  const internalSnap = { docs: internalDocs };
  // Outlines, boxes, address counts and admin fields are in placeInternal
  // (server only, spec section 9); the app's documents hold names, centre,
  // school count and state.
  const internal = new Map<string, DocumentData>(internalSnap.docs.map((d: QueryDocumentSnapshot) => [d.id, d.data()]));
  const existingAreas: PlaceArea[] = areaSnap.docs.map((d: QueryDocumentSnapshot) =>
    areaFromDoc(d.id, d.data(), internal.get(internalId("area", d.id))),
  );
  const existingDistricts: PlaceDistrict[] = districtSnap.docs.map((d: QueryDocumentSnapshot) =>
    districtFromDoc(d.id, d.data(), internal.get(internalId("district", d.id))),
  );
  const areaPlan = planPlaces<ImportedArea, PlaceArea>(places.areas, existingAreas);
  const districtPlan = planPlaces<ImportedDistrict, PlaceDistrict>(
    places.districts,
    existingDistricts,
    (a, b) => a.areaId === b.areaId,
  );
  console.log(`load_places: ${path}`);
  console.log(`  areas: new ${areaPlan.creates.length}, changed ${areaPlan.updates.length}, unchanged ${areaPlan.unchanged}, admin-edited kept ${areaPlan.skipped}`);
  console.log(`  districts: new ${districtPlan.creates.length}, changed ${districtPlan.updates.length}, unchanged ${districtPlan.unchanged}, admin-edited kept ${districtPlan.skipped}`);
  // A district whose area is retired goes with it.
  const retiredAreas = new Set(areaPlan.retires);
  const districtRetires = [
    ...new Set([...districtPlan.retires, ...existingDistricts.filter((d) => retiredAreas.has(d.areaId) && d.active && !d.adminEdited).map((d) => d.id)]),
  ].filter((id) => !places.districts.some((d) => d.id === id));
  console.log(`  replaced by this file, set inactive (kept as documents): areas ${areaPlan.retires.length}, districts ${districtRetires.length}`);
  if (places.refused) console.log(`  refused entries: ${places.refused}`);
  if (flag("--dry-run")) return;

  type Batch = ReturnType<typeof db.batch>;
  const now = FieldValue.serverTimestamp();
  const areaFields = (a: ImportedArea) => ({ governorate: a.governorate, nameAr: a.nameAr, nameEn: a.nameEn, centre: geoPoint(a.centre), updatedAt: now });
  const areaInternal = (a: ImportedArea) => ({
    kind: "area", placeId: a.id, level: a.level, bbox: a.bbox, rings: ringsToDoc(a.rings), updatedAt: now,
  });
  const districtFields = (d: ImportedDistrict) => ({
    areaId: d.areaId, governorate: d.governorate, nameAr: d.nameAr, nameEn: d.nameEn, centre: geoPoint(d.centre), updatedAt: now,
  });
  const districtInternal = (d: ImportedDistrict) => ({
    kind: "district", placeId: d.id, areaId: d.areaId, source: d.source, bbox: d.bbox, rings: ringsToDoc(d.rings), updatedAt: now,
  });
  const internalRef = (kind: "area" | "district", id: string) => db.collection(PLACE_INTERNAL).doc(internalId(kind, id));

  // Places loaded before the split carry the internal fields on the app's
  // document: move them to placeInternal (once) and take them off.
  const legacy: Array<(b: Batch) => void> = [];
  for (const [kind, snap] of [["area", areaSnap], ["district", districtSnap]] as const) {
    for (const d of snap.docs) {
      const data = d.data();
      const moved = INTERNAL_FIELDS.filter((k) => data[k] !== undefined);
      if (moved.length === 0) continue;
      const have = internal.get(internalId(kind, d.id)) ?? {};
      const copy: DocumentData = { kind, placeId: d.id, ...(kind === "district" ? { areaId: data.areaId ?? null } : {}) };
      for (const k of moved) if (have[k] === undefined) copy[k] = data[k];
      const off: DocumentData = Object.fromEntries(moved.map((k) => [k, FieldValue.delete()]));
      legacy.push((b: Batch) => {
        b.set(internalRef(kind, d.id), copy, { merge: true });
        b.update(d.ref, off);
      });
    }
  }
  if (legacy.length) console.log(`  moved outlines and counts to the server-only documents: ${legacy.length}`);

  const writes: Array<(b: Batch) => void> = [
    ...legacy,
    ...areaPlan.creates.map((a) => (b: Batch) => {
      b.create(db.collection(PLACE_AREAS).doc(a.id), { ...areaFields(a), schoolCount: 0, active: true, mergedInto: null, createdAt: now });
      b.set(internalRef("area", a.id), { ...areaInternal(a), source: a.id.startsWith("cod-") ? "cod" : "osm", addressCount: 0, adminEdited: false });
    }),
    ...areaPlan.updates.map((a) => (b: Batch) => {
      b.update(db.collection(PLACE_AREAS).doc(a.id), areaFields(a));
      b.set(internalRef("area", a.id), areaInternal(a), { merge: true });
    }),
    ...districtPlan.creates.map((d) => (b: Batch) => {
      b.create(db.collection(PLACE_DISTRICTS).doc(d.id), { ...districtFields(d), schoolCount: 0, active: true, mergedInto: null, createdAt: now });
      b.set(internalRef("district", d.id), { ...districtInternal(d), addressCount: 0, adminEdited: false });
    }),
    ...districtPlan.updates.map((d) => (b: Batch) => {
      b.update(db.collection(PLACE_DISTRICTS).doc(d.id), districtFields(d));
      b.set(internalRef("district", d.id), districtInternal(d), { merge: true });
    }),
  ];
  for (const id of areaPlan.retires) writes.push((b: Batch) => b.update(db.collection(PLACE_AREAS).doc(id), { active: false, updatedAt: now }));
  for (const id of districtRetires) writes.push((b: Batch) => b.update(db.collection(PLACE_DISTRICTS).doc(id), { active: false, updatedAt: now }));
  // School counts: written only where they changed.
  const allAreaIds = new Set([...existingAreas.map((a) => a.id), ...places.areas.map((a) => a.id)]);
  const oldAreaCount = new Map(existingAreas.map((a) => [a.id, a.schoolCount]));
  for (const id of allAreaIds) {
    const n = counts.areas.get(id) ?? 0;
    if ((oldAreaCount.get(id) ?? 0) !== n) writes.push((b: Batch) => b.set(db.collection(PLACE_AREAS).doc(id), { schoolCount: n }, { merge: true }));
  }
  const allDistrictIds = new Set([...existingDistricts.map((d) => d.id), ...places.districts.map((d) => d.id)]);
  const oldDistrictCount = new Map(existingDistricts.map((d) => [d.id, d.schoolCount]));
  for (const id of allDistrictIds) {
    const n = counts.districts.get(id) ?? 0;
    if ((oldDistrictCount.get(id) ?? 0) !== n) writes.push((b: Batch) => b.set(db.collection(PLACE_DISTRICTS).doc(id), { schoolCount: n }, { merge: true }));
  }
  // Each place write is up to two operations (its document and its
  // placeInternal document): half a schools batch keeps under Firestore's 500.
  const PLACE_BATCH = BATCH_SIZE / 2;
  for (let i = 0; i < writes.length; i += PLACE_BATCH) {
    const chunk = writes.slice(i, i + PLACE_BATCH);
    await commitWithRetry(() => {
      const batch = db.batch();
      for (const write of chunk) write(batch);
      return batch.commit();
    }, `places batch ${i / PLACE_BATCH + 1}`);
  }
  // The index: every active area with a shape (the server's first read for a point).
  const byId = new Map<string, PlaceArea>(existingAreas.filter((a) => !retiredAreas.has(a.id)).map((a) => [a.id, a]));
  for (const a of places.areas) {
    const old = byId.get(a.id);
    if (!old || !(old.adminEdited || old.mergedInto)) {
      const base: PlaceArea = old ?? { ...a, source: a.id.startsWith("cod-") ? "cod" : "osm", schoolCount: 0, addressCount: 0, active: true, mergedInto: null, adminEdited: false };
      byId.set(a.id, { ...base, ...a });
    }
  }
  const index = buildIndex([...byId.values()]);
  await db.collection(PLACE_INDEX).doc(PLACE_INDEX_AREAS).set({ areas: index, updatedAt: now });
  console.log(`load_places: done. areas ${places.areas.length}, districts ${places.districts.length}, index ${index.length} areas, count changes ${writes.length - legacy.length - areaPlan.creates.length - areaPlan.updates.length - districtPlan.creates.length - districtPlan.updates.length}`);
}

main().catch((error) => {
  console.error("load_schools failed:", error instanceof Error ? error.message : error);
  console.error("  Run the same command again: what was written is kept and not written twice.");
  process.exit(1);
});
