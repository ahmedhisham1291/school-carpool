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
 *       Settings, then every active school sent again (read 500 at a time,
 *       sent 1,000 per call) and
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
import { getFirestore } from "firebase-admin/firestore";
import { SCHOOLS } from "../src/admin_panel/store";
import { AlgoliaRestClient } from "../src/schools/algolia";
import { SEARCH_RECORD_FIELDS, planIndexSync, recordWarning } from "../src/schools/catalog";
import { forEachPage } from "../src/schools/paged";

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
const PAGE = 500;
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

/**
 * Reads the schools 500 at a time (only the fields the index needs) and
 * sends each page to Algolia before reading the next: no single Firestore
 * answer is large (one query for 7,000+ schools hit the 300 s deadline,
 * 16 Nov 2026), and a stopped run has sent what it read (run it again:
 * the same records are sent again, nothing is doubled).
 */
async function sync(clearFirst: boolean): Promise<void> {
  const projectId = process.env.SCHOOLS_PROJECT ?? "";
  if (!projectId) refuse("set SCHOOLS_PROJECT to the Firebase project to read");
  initializeApp({ projectId });
  const db = getFirestore();
  await withRetry("settings", () => client.setSettings());
  if (clearFirst) await withRetry("clear", () => client.clear());
  let indexed = 0;
  let removed = 0;
  let read = 0;
  await forEachPage(
    db,
    SCHOOLS,
    async (docs) => {
      read += docs.length;
      const { records, remove } = planIndexSync(docs.map((doc) => ({ id: doc.id, data: doc.data() })));
      for (let i = 0; i < records.length; i += BATCH) {
        await withRetry(`records ${indexed + i + 1}+`, () => client.saveMany(records.slice(i, i + BATCH)));
      }
      if (!clearFirst) {
        for (let i = 0; i < remove.length; i += BATCH) {
          await withRetry(`removals ${removed + i + 1}+`, () => client.removeMany(remove.slice(i, i + BATCH)));
        }
      }
      indexed += records.length;
      removed += remove.length;
      if ((read / PAGE) % 5 === 0) console.log(`  read ${read}, sent ${indexed}`);
    },
    { pageSize: PAGE, select: SEARCH_RECORD_FIELDS },
  );
  // Machine-readable lines for tool/cloud_setup.sh.
  console.log(`algolia_schools: indexed ${indexed}, not in search ${removed}, index ${indexName}`);
  const warning = recordWarning(indexed, Number(process.env.ALGOLIA_RECORD_WARN ?? "8000") || 8000);
  if (warning) console.log(`algolia_schools: warning: ${warning}`);
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
