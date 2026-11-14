import * as logger from "firebase-functions/logger";
import { adminDb } from "../admin";
import { noteActivity, type AbuseKind } from "./abuse";
import { FirestoreAbuseStore } from "./firestore_store";

/**
 * Best-effort scraping count for the callables that open profiles, send
 * chat requests, search areas or look up parent IDs (spec section 7).
 * Never blocks or fails the parent's call; the alert goes to the admins'
 * security alerts. Logs the kind and count only.
 */
export async function noteAbuse(uid: string, kind: AbuseKind, key: string): Promise<void> {
  const alert = await noteActivity(new FirestoreAbuseStore(adminDb()), uid, kind, key, Date.now(), (error) => {
    logger.warn("abuse count failed", { message: error instanceof Error ? error.message : "unknown" });
  });
  if (alert) logger.warn("scraping alert", { kind: alert.kind, count: alert.count });
}
