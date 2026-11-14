import type { Firestore } from "firebase-admin/firestore";

/**
 * Guardian links (Prompt 11, F17): guardianLinks/{childId_guardianUid}.
 * Kept apart (no other imports) so the carpool and map stores can read a
 * parent's linked children without an import cycle.
 */
export const GUARDIAN_LINKS = "guardianLinks";

/** IDs of the children another parent linked to [uid] (active links only). */
export async function linkedChildIds(db: Firestore, uid: string): Promise<string[]> {
  // Index: guardianLinks guardianUid, status (firestore.indexes.json).
  const snap = await db.collection(GUARDIAN_LINKS).where("guardianUid", "==", uid).where("status", "==", "active").limit(20).get();
  const ids: string[] = [];
  for (const doc of snap.docs) {
    const id: unknown = doc.get("childId");
    if (typeof id === "string" && id.length > 0) ids.push(id);
  }
  return ids;
}
