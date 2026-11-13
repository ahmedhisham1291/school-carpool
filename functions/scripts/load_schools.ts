/**
 * Loads build/schools/schools.json (made by tools/import_schools) into
 * Firestore schools/{id}. Safe to run again: schools are matched by ID and
 * by every source key, unchanged schools are not written, and schools an
 * admin edited or merged are left alone (functions/src/schools/catalog.ts).
 * Nothing is deleted.
 *
 *   Emulators:  npm --prefix functions run schools:load:emulator
 *   Cloud:      SCHOOLS_PROJECT=<project-id> npm --prefix functions run schools:load:cloud -- --yes
 *               (gcloud auth application-default login first; see SETUP.md)
 *
 * Options: --file <path> (default ../build/schools/schools.json), --dry-run.
 * With search on Algolia, syncSchoolToSearch indexes each written school.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { initializeApp } from "firebase-admin/app";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { SCHOOLS } from "../src/admin_panel/store";
import { parseImportedSchool, planImport, type ImportedSchool } from "../src/schools/catalog";
import { importedFields, newImportedDoc, readExistingSchools } from "../src/schools/store";

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
} else {
  if (!process.env.FIRESTORE_EMULATOR_HOST) refuse("FIRESTORE_EMULATOR_HOST is not set (or set SCHOOLS_PROJECT)");
  if (!emulatorProject.startsWith("demo-")) refuse(`project "${emulatorProject}" is not a demo- project`);
}

const file = resolve(option("--file") ?? "../build/schools/schools.json");

async function main(): Promise<void> {
  let doc: { format?: unknown; schools?: unknown };
  try {
    doc = JSON.parse(readFileSync(file, "utf-8"));
  } catch {
    refuse(`cannot read ${file}; run python3 tools/import_schools/import_schools.py first`);
  }
  if (doc.format !== "school-carpool-schools/1" || !Array.isArray(doc.schools)) refuse(`${file} is not a schools.json`);

  const incoming: ImportedSchool[] = [];
  const bad: string[] = [];
  for (const raw of doc.schools as unknown[]) {
    try {
      incoming.push(parseImportedSchool(raw));
    } catch (error) {
      bad.push(error instanceof Error ? error.message : String(error));
    }
  }

  initializeApp({ projectId });
  const db = getFirestore();
  const existing = await readExistingSchools(db);
  const plan = planImport(incoming, existing);

  console.log(`load_schools: ${projectId}, ${file}`);
  console.log(`  in file: ${incoming.length} usable, ${bad.length} refused`);
  console.log(`  new: ${plan.creates.length}, changed: ${plan.updates.length}, unchanged: ${plan.unchanged}`);
  const skipped = new Map<string, number>();
  for (const s of plan.skipped) skipped.set(s.reason, (skipped.get(s.reason) ?? 0) + 1);
  for (const [reason, count] of skipped) console.log(`  left alone (${reason}): ${count}`);
  console.log(`  imported earlier, not in this file (kept): ${plan.notInInput.length}`);
  for (const message of bad.slice(0, 20)) console.log(`  refused: ${message}`);
  if (flag("--dry-run")) {
    console.log("  dry run: nothing written");
    return;
  }

  const importedAt = Timestamp.now();
  const writes: Array<(batch: ReturnType<typeof db.batch>) => void> = [
    ...plan.creates.map((s) => (batch: ReturnType<typeof db.batch>) => {
      batch.create(db.collection(SCHOOLS).doc(s.id), newImportedDoc(s, importedAt));
    }),
    ...plan.updates.map((u) => (batch: ReturnType<typeof db.batch>) => {
      batch.update(db.collection(SCHOOLS).doc(u.id), importedFields(u.school, importedAt));
    }),
  ];
  for (let i = 0; i < writes.length; i += 400) {
    const batch = db.batch();
    for (const write of writes.slice(i, i + 400)) write(batch);
    await batch.commit();
    console.log(`  written ${Math.min(i + 400, writes.length)} of ${writes.length}`);
  }
  console.log("load_schools: done");
}

main().catch((error) => {
  console.error("load_schools failed:", error instanceof Error ? error.message : error);
  process.exit(1);
});
