import { Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import { AUDIT_LOG, auditDoc } from "../admin_panel/store";
import type { SignInLogEntry, SignInLogStore } from "./signin_log";

/**
 * signInLog/{id}: the Anti-Cybercrime sign-in log (signin_log.ts, R2).
 * Server-only: firestore.rules deny every client, admins included. Lines
 * expire by Firestore TTL on expiresAt (tool/setup_retention.sh) and are
 * NOT part of the account deletion (privacy/account_deletion.ts
 * NOT_DELETED) nor of the parent's data export (confidential under Law
 * 175/2018 Art. 2; the parent sees the same sign-ins without the IP under
 * Privacy > Phones).
 */
export const SIGN_IN_LOG = "signInLog";

function toDoc(e: SignInLogEntry): DocumentData {
  return {
    uid: e.uid,
    phoneKey: e.phoneKey,
    phoneEnc: e.phoneEnc,
    event: e.event,
    at: Timestamp.fromMillis(e.atMs),
    ipEnc: e.ipEnc,
    deviceKey: e.deviceKey,
    platform: e.platform,
    appVersion: e.appVersion,
    expiresAt: Timestamp.fromMillis(e.expiresAtMs),
  };
}

function millis(value: unknown): number {
  return value instanceof Timestamp ? value.toMillis() : 0;
}

function fromDoc(d: DocumentData): SignInLogEntry {
  const platform = d.platform === "android" || d.platform === "web" ? d.platform : "ios";
  return {
    uid: String(d.uid ?? ""),
    phoneKey: String(d.phoneKey ?? ""),
    phoneEnc: String(d.phoneEnc ?? ""),
    event: "signIn",
    atMs: millis(d.at),
    ipEnc: typeof d.ipEnc === "string" ? d.ipEnc : null,
    deviceKey: typeof d.deviceKey === "string" ? d.deviceKey : null,
    platform,
    appVersion: String(d.appVersion ?? "unknown"),
    expiresAtMs: millis(d.expiresAt),
  };
}

export class FirestoreSignInLogStore implements SignInLogStore {
  constructor(private readonly db: Firestore) {}

  async add(entry: SignInLogEntry): Promise<void> {
    await this.db.collection(SIGN_IN_LOG).doc().create(toDoc(entry));
  }

  async byUid(uid: string, limit: number): Promise<SignInLogEntry[]> {
    const snap = await this.db.collection(SIGN_IN_LOG).where("uid", "==", uid).limit(limit).get();
    return snap.docs.map((d) => fromDoc(d.data()));
  }

  async byPhoneKey(phoneKey: string, limit: number): Promise<SignInLogEntry[]> {
    const snap = await this.db.collection(SIGN_IN_LOG).where("phoneKey", "==", phoneKey).limit(limit).get();
    return snap.docs.map((d) => fromDoc(d.data()));
  }

  async audit(a: { actorUid: string; ip: string; orderRef: string; authority: string; orderDate: string; subject: "uid" | "phone"; target: string; count: number; atMs: number }): Promise<void> {
    await this.db
      .collection(AUDIT_LOG)
      .doc()
      .create({
        ...auditDoc({
          actorUid: a.actorUid,
          action: "signInLog.disclose",
          target: a.target,
          reasonCode: "judicialOrder",
          ip: a.ip,
          details: { orderRef: a.orderRef, authority: a.authority, orderDate: a.orderDate, subject: a.subject, count: a.count },
        }),
        disclosedAt: Timestamp.fromMillis(a.atMs),
      });
  }
}
