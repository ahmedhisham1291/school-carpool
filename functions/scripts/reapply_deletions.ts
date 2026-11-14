/**
 * After a restore from a backup or PITR (docs/restore-test.md): deleted
 * accounts must not come back. For every closedAccounts/{uid} in the LIVE
 * database it schedules every deletion step again (immediate steps, and the
 * purge steps for accounts already purged); the next retentionDaily (03:10
 * Cairo) runs them. Every step is idempotent, so running this when nothing
 * came back changes nothing. Prints counts only.
 *
 *   GCLOUD_PROJECT=<project> npm --prefix functions run deletions:reapply
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { immediateSteps, purgeSteps } from "../src/privacy/account_deletion";
import { CLOSED_ACCOUNTS } from "../src/privacy/firestore_store";

async function main(): Promise<void> {
  const projectId = process.env.GCLOUD_PROJECT ?? "";
  if (!projectId) {
    console.error("deletions:reapply: GCLOUD_PROJECT is not set");
    process.exit(1);
  }
  initializeApp({ projectId });
  const db = getFirestore();
  const snap = await db.collection(CLOSED_ACCOUNTS).get();
  let scheduled = 0;
  for (const d of snap.docs) {
    const purged = d.get("purged") === true;
    // Purged accounts: the purge steps too (photos, trips, consents, chat).
    const failed = purged ? [...immediateSteps(), ...purgeSteps()] : immediateSteps();
    await d.ref.update({ failed, failedCount: failed.length, reappliedAt: new Date() });
    scheduled += 1;
  }
  console.log("deletions:reapply", { accounts: scheduled });
}

void main();
