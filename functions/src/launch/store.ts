import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";
import { AUDIT_LOG, auditDoc } from "../admin_panel/store";
import type { AuditEntry } from "../admin_panel/types";
import type { LaunchStore } from "./flow";
import { LAUNCH_DOC, launchFrom, type LaunchSettings } from "./model";

function millis(value: unknown): number | null {
  return value instanceof Timestamp ? value.toMillis() : null;
}

export class FirestoreLaunchStore implements LaunchStore {
  constructor(private readonly db: Firestore) {}

  async read(): Promise<LaunchSettings> {
    return launchFrom((await this.db.doc(LAUNCH_DOC).get()).data() ?? null, millis);
  }

  async write(pdpcLicensed: boolean, adminUid: string, nowMs: number, audit: AuditEntry): Promise<void> {
    const batch = this.db.batch();
    batch.set(this.db.doc(LAUNCH_DOC), { pdpcLicensed, updatedBy: adminUid, updatedAt: Timestamp.fromMillis(nowMs), serverUpdatedAt: FieldValue.serverTimestamp() }, { merge: true });
    batch.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await batch.commit();
  }
}
