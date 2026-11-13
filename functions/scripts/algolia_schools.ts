/**
 * Algolia set-up and repair for the schools index (F4). Admin machine only;
 * keys come from the environment, never from the repository.
 *
 *   ALGOLIA_APP_ID=... ALGOLIA_ADMIN_KEY=... ALGOLIA_INDEX=schools_dev \
 *     npm --prefix functions run schools:algolia -- settings
 *       Applies the index settings (Arabic and English, typo tolerance,
 *       governorate filter, only names and places retrieved).
 *
 *   SCHOOLS_PROJECT=<project-id> ALGOLIA_APP_ID=... ALGOLIA_ADMIN_KEY=... ALGOLIA_INDEX=... \
 *     npm --prefix functions run schools:algolia -- reindex
 *       Clears the index and sends every active school again (1000 per
 *       call). Use after the first import or if the sync missed writes.
 *
 * The admin key is needed only here (settings and clear). The functions use
 * a write key limited to the index (ALGOLIA_WRITE_KEY) and the app a
 * secured search key (getSchoolSearchKey).
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { SCHOOLS } from "../src/admin_panel/store";
import { AlgoliaRestClient } from "../src/schools/algolia";
import { searchRecordFrom, type SchoolSearchRecord } from "../src/schools/catalog";

function refuse(reason: string): never {
  console.error(`algolia_schools: refusing to run: ${reason}`);
  process.exit(1);
}

const command = process.argv[2];
const appId = process.env.ALGOLIA_APP_ID ?? "";
const adminKey = process.env.ALGOLIA_ADMIN_KEY ?? "";
const indexName = process.env.ALGOLIA_INDEX ?? "";
if (!appId || !adminKey || !indexName) refuse("set ALGOLIA_APP_ID, ALGOLIA_ADMIN_KEY and ALGOLIA_INDEX");
const client = new AlgoliaRestClient(appId, adminKey, indexName);

async function reindex(): Promise<void> {
  const projectId = process.env.SCHOOLS_PROJECT ?? "";
  if (!projectId) refuse("set SCHOOLS_PROJECT to the Firebase project to read");
  initializeApp({ projectId });
  const snap = await getFirestore().collection(SCHOOLS).where("status", "==", "active").get();
  const records = snap.docs
    .map((doc) => searchRecordFrom(doc.id, doc.data()))
    .filter((r): r is SchoolSearchRecord => r !== null);
  await client.clear();
  for (let i = 0; i < records.length; i += 1000) {
    await client.saveMany(records.slice(i, i + 1000));
    console.log(`  sent ${Math.min(i + 1000, records.length)} of ${records.length}`);
  }
}

async function main(): Promise<void> {
  if (command === "settings") {
    await client.setSettings();
    console.log(`algolia_schools: settings applied to ${indexName}`);
  } else if (command === "reindex") {
    await client.setSettings();
    await reindex();
    console.log(`algolia_schools: ${indexName} reindexed`);
  } else {
    refuse('give "settings" or "reindex"');
  }
}

main().catch((error) => {
  console.error("algolia_schools failed:", error instanceof Error ? error.message : error);
  process.exit(1);
});
