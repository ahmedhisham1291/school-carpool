/**
 * Fills schools/{id}.adminSearchGrams (admin panel search, F14) on every
 * school that lacks it or has stale grams. Run once per project after the
 * deploy that adds adminSearchSchools; later writes keep the field right
 * (every writer sets it, and the syncSchoolAdminGrams trigger repairs the
 * rest). Safe to run again: unchanged schools are not written.
 *
 *   SCHOOLS_PROJECT=<project-id> npm --prefix functions run schools:admin-grams -- --yes
 *   SCHOOLS_PROJECT=<project-id> npm --prefix functions run schools:admin-grams -- --dry-run
 *   (emulator) FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 GCLOUD_PROJECT=demo-school-carpool \
 *     npm --prefix functions run schools:admin-grams
 *
 * Cost: one read per school, one write per school that changes (about
 * 20,000 to 30,000 of each the first time on a full list: inside one day's
 * free 50,000 reads; writes past the free 20,000 a day cost about USD 0.02).
 * Prints counts only, never names.
 */
import { initializeApp } from "firebase-admin/app";
import { FieldPath, getFirestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import { gramsToWrite } from "../src/admin_panel/school_search";
import { ADMIN_SEARCH_GRAMS } from "../src/admin_panel/school_search_store";
import { SCHOOLS } from "../src/admin_panel/store";

function refuse(reason: string): never {
  console.error(`school_admin_grams: refusing to run: ${reason}`);
  process.exit(1);
}

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const cloudProject = process.env.SCHOOLS_PROJECT ?? "";
const emulatorProject = process.env.GCLOUD_PROJECT ?? "";
if (cloudProject) {
  if (!args.includes("--yes") && !dryRun) refuse(`add --yes to write to the cloud project "${cloudProject}"`);
} else {
  if (!process.env.FIRESTORE_EMULATOR_HOST) refuse("FIRESTORE_EMULATOR_HOST is not set (or set SCHOOLS_PROJECT)");
  if (!emulatorProject.startsWith("demo-")) refuse(`project "${emulatorProject}" is not a demo- project`);
}

const PAGE = 2000;
/** Firestore allows 500 writes per batch; 400 leaves room. */
const BATCH = 400;

async function main(): Promise<void> {
  initializeApp({ projectId: cloudProject || emulatorProject });
  const db = getFirestore();
  let read = 0;
  let written = 0;
  let last: QueryDocumentSnapshot | undefined;
  for (;;) {
    let query = db.collection(SCHOOLS).orderBy(FieldPath.documentId()).limit(PAGE);
    if (last) query = query.startAfter(last);
    const page = await query.get();
    read += page.docs.length;
    const todo = page.docs
      .map((doc) => ({ doc, grams: gramsToWrite(doc.data()) }))
      .filter((t): t is { doc: QueryDocumentSnapshot; grams: string[] } => t.grams !== null);
    for (let i = 0; i < todo.length && !dryRun; i += BATCH) {
      const batch = db.batch();
      for (const t of todo.slice(i, i + BATCH)) batch.update(t.doc.ref, { [ADMIN_SEARCH_GRAMS]: t.grams });
      await batch.commit();
    }
    written += todo.length;
    if (page.docs.length < PAGE) break;
    last = page.docs[page.docs.length - 1];
  }
  // One machine-readable line.
  console.log(`school_admin_grams: read ${read}, ${dryRun ? "would write" : "wrote"} ${written}`);
}

main().catch((error) => {
  console.error("school_admin_grams failed:", error instanceof Error ? error.message : error);
  process.exit(1);
});
