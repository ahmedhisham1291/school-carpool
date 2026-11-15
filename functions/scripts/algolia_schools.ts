/**
 * Algolia set-up and repair for the schools index (F4). Admin machine or
 * Cloud Shell only; keys come from the environment, never from the
 * repository, and are never printed.
 *
 *   ALGOLIA_APP_ID=... ALGOLIA_WRITE_KEY=... ALGOLIA_INDEX=schools_staging \
 *     npm --prefix functions run schools:algolia -- settings
 *       Applies the index settings (Arabic and English, typo tolerance,
 *       governorate filter, only names and places retrieved).
 *
 *   SCHOOLS_PROJECT=<project-id> ALGOLIA_APP_ID=... ALGOLIA_WRITE_KEY=... ALGOLIA_INDEX=... \
 *     npm --prefix functions run schools:algolia -- sync
 *       Settings, then every active school sent again (1,000 per call) and
 *       every other school (merged, awaiting review, hidden sample) removed.
 *       Never empties the index first, so search keeps working during the
 *       run. Works with the dashboard's Write API key. Used by
 *       tool/cloud_setup.sh step 12.
 *
 *   ... ALGOLIA_ADMIN_KEY=... npm --prefix functions run schools:algolia -- reindex
 *       Clears the index, then as "sync". Needs a key allowed to clear an
 *       index (the Admin API key); for a drifted index with records whose
 *       documents no longer exist.
 *
 * Either ALGOLIA_WRITE_KEY or ALGOLIA_ADMIN_KEY is accepted. The functions
 * use the write key (ALGOLIA_WRITE_KEY secret) and the app a secured
 * search key (getSchoolSearchKey).
 *
 * Cost: one Firestore read per school per run; Algolia counts records
 * (free plan: 50,000) and search requests, not these indexing calls.
 */
import { initializeApp } from "firebase-admin/app";
import { FieldPath, getFirestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import { SCHOOLS } from "../src/admin_panel/store";
import { AlgoliaRestClient } from "../src/schools/algolia";
import { planIndexSync } from "../src/schools/catalog";

function refuse(reason: string): never {
  console.error(`algolia_schools: refusing to run: ${reason}`);
  process.exit(1);
}

const command = process.argv[2];
const appId = process.env.ALGOLIA_APP_ID ?? "";
const apiKey = process.env.ALGOLIA_ADMIN_KEY || process.env.ALGOLIA_WRITE_KEY || "";
const indexName = process.env.ALGOLIA_INDEX ?? "";
if (!appId || !apiKey || !indexName) refuse("set ALGOLIA_APP_ID, ALGOLIA_WRITE_KEY (or ALGOLIA_ADMIN_KEY) and ALGOLIA_INDEX");
if (apiKey === "unused") refuse("the Algolia key is the placeholder 'unused'; set up Algolia first (docs/algolia-setup.md)");
const client = new AlgoliaRestClient(appId, apiKey, indexName);

const BATCH = 1000;
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));

async function withRetry(label: string, call: () => Promise<void>): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try {
      await call();
      return;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      // 400/403: a wrong key or a key without the right; trying again cannot help.
      if (attempt >= 4 || /failed with 40[0-3]/.test(message)) throw error;
      console.log(`  ${label}: ${message}; trying again in ${attempt * 5} s`);
      await sleep(attempt * 5000);
    }
  }
}

async function readSchools(): Promise<Array<{ id: string; data: Record<string, unknown> }>> {
  const projectId = process.env.SCHOOLS_PROJECT ?? "";
  if (!projectId) refuse("set SCHOOLS_PROJECT to the Firebase project to read");
  initializeApp({ projectId });
  const db = getFirestore();
  const out: Array<{ id: string; data: Record<string, unknown> }> = [];
  let last: QueryDocumentSnapshot | undefined;
  for (;;) {
    let query = db.collection(SCHOOLS).orderBy(FieldPath.documentId()).limit(5000);
    if (last) query = query.startAfter(last);
    const page = await query.get();
    for (const doc of page.docs) out.push({ id: doc.id, data: doc.data() });
    if (page.docs.length < 5000) break;
    last = page.docs[page.docs.length - 1];
  }
  return out;
}

async function sync(clearFirst: boolean): Promise<void> {
  await withRetry("settings", () => client.setSettings());
  const { records, remove } = planIndexSync(await readSchools());
  if (clearFirst) await withRetry("clear", () => client.clear());
  for (let i = 0; i < records.length; i += BATCH) {
    await withRetry(`records ${i + 1}+`, () => client.saveMany(records.slice(i, i + BATCH)));
    const done = Math.min(i + BATCH, records.length);
    if (done === records.length || (i / BATCH) % 5 === 0) console.log(`  sent ${done} of ${records.length}`);
  }
  if (!clearFirst) {
    for (let i = 0; i < remove.length; i += BATCH) {
      await withRetry(`removals ${i + 1}+`, () => client.removeMany(remove.slice(i, i + BATCH)));
    }
  }
  // One machine-readable line for tool/cloud_setup.sh.
  console.log(`algolia_schools: indexed ${records.length}, not in search ${remove.length}, index ${indexName}`);
}

async function main(): Promise<void> {
  if (command === "settings") {
    await withRetry("settings", () => client.setSettings());
    console.log(`algolia_schools: settings applied to ${indexName}`);
  } else if (command === "sync") {
    await sync(false);
  } else if (command === "reindex") {
    await sync(true);
  } else {
    refuse('give "settings", "sync" or "reindex"');
  }
}

main().catch((error) => {
  console.error("algolia_schools failed:", error instanceof Error ? error.message : error);
  console.error("  403 means the key lacks a right (use the Write API key); run the same command again otherwise.");
  process.exit(1);
});
