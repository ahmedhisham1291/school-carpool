/**
 * After a restore from a backup or PITR (docs/restore-test.md): deleted
 * accounts must not come back. For every closedAccounts/{uid} in the LIVE
 * database it schedules every deletion step again (immediate steps, and the
 * purge steps for accounts already purged); the next retentionDaily (03:10
 * Cairo) runs them. Every step is idempotent, so running this when nothing
 * came back changes nothing. Prints counts only.
 *
 * Also run it ONCE after deploying the 16 Nov 2026 retention change: an
 * account closed under the older rule (photos kept 1 year) has no evidence
 * date; this makes the next retentionDaily delete its photos, face
 * reference, case records, routes and chat messages.
 *
 *   GCLOUD_PROJECT=<project> npm --prefix functions run deletions:reapply
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { evidenceSteps, immediateSteps, purgeSteps } from "../src/privacy/account_deletion";
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
    // The immediate steps include the chat step (the parent's messages).
    // The evidence (photos, case records, routes) again unless a safety
    // hold is still running; purged accounts: the 1-year steps too.
    const evidenceAt = d.get("evidenceAt");
    const held = d.get("hold") === true && evidenceAt && evidenceAt.toMillis() > Date.now();
    const failed = [...immediateSteps(), ...(held ? [] : evidenceSteps()), ...(purged ? purgeSteps() : [])];
    await d.ref.update({ failed, failedCount: failed.length, reappliedAt: new Date() });
    scheduled += 1;
  }
  console.log("deletions:reapply", { accounts: scheduled });
}

void main();
