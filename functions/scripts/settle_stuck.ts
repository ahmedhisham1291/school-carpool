/**
 * Records the partner's written answer for a "stuck" transfer (review
 * 11B, new item 2; SETUP.md 21.6). It never moves money: it only records
 * what the partner already did (or confirmed it will never do) for our
 * request ID, once, and closes the admin alert as "settledWithPartner".
 *
 *   GCLOUD_PROJECT=<project> npm --prefix functions run wallet:settle -- <transferId> done|failed <partnerRef|-> <superAdminUid>
 *
 * Run by a super admin with their own gcloud credentials. The action is
 * written to the admin audit log.
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { FirestoreListsStore } from "../src/admin_panel/store";
import { settleStuckTransfer } from "../src/wallet/flow";
import { FirestoreWalletStore } from "../src/wallet/firestore_store";

function refuse(reason: string): never {
  console.error(`wallet:settle: refusing to run: ${reason}`);
  process.exit(1);
}

async function main(): Promise<void> {
  const [transferId, status, partnerRef, actorUid] = process.argv.slice(2);
  if (!transferId || (status !== "done" && status !== "failed") || !partnerRef || !actorUid) {
    refuse("usage: <transferId> done|failed <partnerRef|-> <superAdminUid>");
  }
  const projectId = process.env.GCLOUD_PROJECT ?? "";
  if (!projectId) refuse("GCLOUD_PROJECT is not set");
  initializeApp({ projectId });
  const db = getFirestore();
  const admin = await db.collection("admins").doc(actorUid).get();
  if (!admin.exists || admin.get("role") !== "superAdmin" || admin.get("disabled") === true) refuse("the actor is not an active super admin");
  const lists = new FirestoreListsStore(db);
  const deps = {
    store: new FirestoreWalletStore(db),
    provider: null,
    now: () => Date.now(),
    log: (message: string, data?: Record<string, unknown>) => console.log(message, data ?? {}),
    audit: (entry: Parameters<FirestoreListsStore["audit"]>[0]) => lists.audit(entry),
  };
  // Logged first: a change is never unlogged.
  await lists.audit({ actorUid, action: "wallet.transfer.settle", target: `transfers/${transferId}`, reasonCode: status, ip: null, details: { source: "partner-confirmation" } });
  const result = await settleStuckTransfer(deps, transferId, { status, partnerRef: partnerRef === "-" ? null : partnerRef }, actorUid);
  console.log(`transfer ${transferId} recorded as ${result.status}`);
}

main().catch((error: unknown) => {
  console.error("wallet:settle failed:", error instanceof Error ? error.message : "unknown");
  process.exit(1);
});
