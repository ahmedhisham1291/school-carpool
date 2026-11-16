import { anonymiseSettleUp, planRetention } from "../settle_up/model";
import { readReviewDemoState } from "../auth/review_access";
import { SETTLE_ADDRESSES, SETTLE_UPS, settleFromDoc, settleToDoc } from "../settle_up/store";
import type { Bucket } from "../verification/store";
import { FieldPath, FieldValue, Timestamp, type DocumentData, type Firestore, type Query, type QueryDocumentSnapshot, type QuerySnapshot } from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import type { ChatServer } from "../chat/server";
import { outboxDoc } from "../notifications/outbox";
import type { OutboxEvent } from "../notifications/model";
import type { AbuseCounter, AbuseKind, AbuseStore, SecurityAlert } from "./abuse";
import { alertFor } from "./abuse";
import { DELETED_ID, anonymiseBalance, anonymiseCarpool, anonymiseRun, anonymiseSwap, anonymiseTrip } from "./anonymise";
import { keepForClosedParent, participantsOf, planTripRetention, type AccountState } from "./trip_retention";
import {
  CLOSING_REASON,
  nextWorkAt,
  pathFor,
  type AccountFacts,
  type ClosedAccount,
  type DeletionRunner,
  type EvidenceStep,
  type FlowStep,
  type PurgeStep,
  type Target,
  type WalletLock,
} from "./account_deletion";
import type { DeviceAccount, DeviceRecord, DeviceStore, Platform, SignInPlan, SignOutReason } from "./devices";
import type { ExportSource } from "./export";
import { PLACE_INTERNAL, internalId } from "../places/catalog";
import type { RetentionReport, RetentionStore } from "./jobs";
import { responseDueAt, type ConsentRow, type PrivacyRequest } from "./requests";
import { ABUSE_COUNTER_DAYS, DAY_MS, DEVICE_STALE_DAYS, LOGIN_HISTORY_DAYS, type DataTypeId } from "./retention";

/**
 * Firestore and Storage side of Prompt 12. Every collection here is closed
 * to the app by firestore.rules (deny by default): the app reaches them
 * only through the privacy callables. Logs carry counts and codes only.
 *
 * - closedAccounts/{uid}: deletion report and purge date (no name or phone)
 * - privacyRequests/{id}: every privacy request (3 years, TTL expiresAt)
 * - users/{uid}/devices/{key}, users/{uid}/logins/{id}: phones and sign-ins
 * - abuseCounters/{uid_kind_hour}: scraping counters (TTL expiresAt, 2 days)
 * - securityAlerts/{id}: scraping and retention-failure alerts for admins
 * - routeArchives/{tripId}: one archived route's record (file in Storage)
 * - retentionRuns/{date}: what the daily job did (counts only)
 * - mail/{id}: security emails (Trigger Email extension format)
 */

export const CLOSED_ACCOUNTS = "closedAccounts";
export const PRIVACY_REQUESTS = "privacyRequests";
export const ABUSE_COUNTERS = "abuseCounters";
export const SECURITY_ALERTS = "securityAlerts";
export const ROUTE_ARCHIVES = "routeArchives";
export const RETENTION_RUNS = "retentionRuns";
export const MAIL = "mail";
const DEVICES = "devices";
const LOGINS = "logins";
const REPORTS = "reports";
const NOTIFICATION_EVENTS = "notificationEvents";
const BATCH = 400;
/** Pages of settle-up records one account deletion may walk (400 each). */
const SETTLE_UP_ANONYMISE_MAX_PAGES = 50;

const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);

export function millis(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

/** Firestore values as plain JSON (Timestamps as ISO text, GeoPoints as { lat, lng }). */
export function plain(value: unknown, depth = 0): unknown {
  if (depth > 10 || value === undefined) return null;
  if (value === null || typeof value !== "object") return value;
  const t = value as { toDate?: () => Date; latitude?: unknown; longitude?: unknown };
  if (typeof t.toDate === "function") return t.toDate().toISOString();
  if (typeof t.latitude === "number" && typeof t.longitude === "number") return { lat: t.latitude, lng: t.longitude };
  if (Array.isArray(value)) return value.map((v) => plain(v, depth + 1));
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = plain(v, depth + 1);
  return out;
}

function pick(d: DocumentData | undefined, keys: readonly string[]): Record<string, unknown> | null {
  if (!d) return null;
  const out: Record<string, unknown> = {};
  for (const k of keys) if (d[k] !== undefined) out[k] = plain(d[k]);
  return out;
}

/** Deletes every document of [query] in batches; returns how many. */
export async function deleteQuery(db: Firestore, query: Query, max = 5_000): Promise<number> {
  let deleted = 0;
  while (deleted < max) {
    const snap = await query.limit(BATCH).get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const d of snap.docs) batch.delete(d.ref);
    await batch.commit();
    deleted += snap.size;
    if (snap.size < BATCH) break;
  }
  return deleted;
}

// --------------------------------------------------------------------------
// Devices
// --------------------------------------------------------------------------

function deviceFromDoc(key: string, d: DocumentData): DeviceRecord {
  return {
    key,
    platform: (["ios", "android", "web"].includes(text(d.platform)) ? d.platform : "ios") as Platform,
    firstSignInAtMs: millis(d.firstSignInAt),
    lastSignInAtMs: millis(d.lastSignInAt),
    lastSeenAtMs: millis(d.lastSeenAt),
    signedOutAtMs: d.signedOutAt ? millis(d.signedOutAt) : null,
    signOutReason: d.signOutReason === "user" || d.signOutReason === "newDevice" || d.signOutReason === "deleted" ? d.signOutReason : null,
  };
}

function deviceToDoc(d: DeviceRecord): DocumentData {
  return {
    platform: d.platform,
    firstSignInAt: ts(d.firstSignInAtMs),
    lastSignInAt: ts(d.lastSignInAtMs),
    lastSeenAt: ts(d.lastSeenAtMs),
    signedOutAt: d.signedOutAtMs === null ? null : ts(d.signedOutAtMs),
    signOutReason: d.signOutReason,
    // Firestore TTL: a phone not seen for 180 days drops off the list.
    expiresAt: ts(d.lastSeenAtMs + DEVICE_STALE_DAYS * DAY_MS),
  };
}

export class FirestoreDeviceStore implements DeviceStore {
  constructor(
    private readonly db: Firestore,
    private readonly bucket: Bucket,
  ) {}

  private user(uid: string) {
    return this.db.collection(USERS).doc(uid);
  }

  async account(uid: string): Promise<DeviceAccount | null> {
    const snap = await this.user(uid).get();
    if (!snap.exists) return null;
    const [hasFaceRef] = await this.bucket.file(`faceRefs/${uid}/selfie.jpg`).exists();
    return {
      status: text(snap.get("status")),
      email: snap.get("emailVerified") === true && text(snap.get("email")) ? text(snap.get("email")) : null,
      language: snap.get("language") === "en" ? "en" : "ar",
      hasFaceRef,
      // Only a demo parent listed in the open review access (reviewDemoState).
      reviewDemo: (await readReviewDemoState(this.db, uid, snap.data(), Date.now())) === "open",
    };
  }

  async devices(uid: string): Promise<DeviceRecord[]> {
    const snap = await this.user(uid).collection(DEVICES).limit(50).get();
    return snap.docs.map((d) => deviceFromDoc(d.id, d.data()));
  }

  async logins(uid: string): Promise<Array<{ atMs: number; platform: string; newDevice: boolean; deviceKey: string }>> {
    const snap = await this.user(uid).collection(LOGINS).orderBy("at", "desc").limit(20).get();
    return snap.docs.map((d) => ({ atMs: millis(d.get("at")), platform: text(d.get("platform")), newDevice: d.get("newDevice") === true, deviceKey: text(d.get("deviceKey")) }));
  }

  async saveSignIn(uid: string, plan: SignInPlan, check: { required: boolean; sinceMs: number } | null, notice: OutboxEvent | null): Promise<void> {
    const batch = this.db.batch();
    const devices = this.user(uid).collection(DEVICES);
    batch.set(devices.doc(plan.device.key), deviceToDoc(plan.device));
    batch.set(this.user(uid).collection(LOGINS).doc(plan.login.id), {
      deviceKey: plan.login.deviceKey,
      platform: plan.login.platform,
      at: ts(plan.login.atMs),
      newDevice: plan.login.newDevice,
      expiresAt: ts(plan.login.atMs + LOGIN_HISTORY_DAYS * DAY_MS),
    });
    for (const key of plan.signOut) {
      batch.update(devices.doc(key), { signedOutAt: ts(plan.device.lastSignInAtMs), signOutReason: "newDevice" });
    }
    if (check) batch.update(this.user(uid), { newDeviceCheck: { required: check.required, since: ts(check.sinceMs) } });
    if (notice) batch.set(this.db.collection(NOTIFICATION_EVENTS).doc(notice.id), outboxDoc(notice));
    await batch.commit();
  }

  async touch(uid: string, key: string, platform: Platform, nowMs: number, create: boolean): Promise<void> {
    const ref = this.user(uid).collection(DEVICES).doc(key);
    if (create) {
      await ref.set(deviceToDoc({ key, platform, firstSignInAtMs: nowMs, lastSignInAtMs: nowMs, lastSeenAtMs: nowMs, signedOutAtMs: null, signOutReason: null }));
    } else {
      await ref.update({ lastSeenAt: ts(nowMs), platform, expiresAt: ts(nowMs + DEVICE_STALE_DAYS * DAY_MS) });
    }
  }

  async markSignedOut(uid: string, keys: string[], reason: SignOutReason, nowMs: number): Promise<void> {
    if (keys.length === 0) return;
    const batch = this.db.batch();
    for (const key of keys) batch.update(this.user(uid).collection(DEVICES).doc(key), { signedOutAt: ts(nowMs), signOutReason: reason });
    await batch.commit();
  }

  async setDeviceCheck(uid: string, check: { required: boolean; sinceMs: number } | null): Promise<void> {
    await this.user(uid).update({ newDeviceCheck: check ? { required: check.required, since: ts(check.sinceMs) } : null });
  }

  async deviceCheck(uid: string): Promise<{ required: boolean; sinceMs: number } | null> {
    const c = (await this.user(uid).get()).get("newDeviceCheck") as { required?: unknown; since?: unknown } | null | undefined;
    return c && c.required === true ? { required: true, sinceMs: millis(c.since) } : null;
  }

  async addReport(uid: string, reason: "new-device-mismatch" | "new-device-unchecked", urgent: boolean, nowMs: number): Promise<void> {
    // The admin panel's reports queue (Prompt 4); "system" as the reporter.
    await this.db.collection(REPORTS).doc().create({ reporterId: "system", targetType: "user", targetId: uid, reason, urgent, kind: "device", status: "open", createdAt: ts(nowMs) });
  }
}

// --------------------------------------------------------------------------
// Mail (security emails)
// --------------------------------------------------------------------------

const NEW_DEVICE_MAIL = {
  ar: {
    subject: "تسجيل دخول من هاتف جديد",
    text: "دخل أحدهم إلى حسابك في تطبيق مشاركة التوصيل المدرسي من هاتف جديد، فأخرجنا الهواتف الأخرى. إن كنت أنت فلا تفعل شيئًا. إن لم تكن أنت فتواصل معنا فورًا بالرد على هذه الرسالة.",
  },
  en: {
    subject: "New phone signed in",
    text: "Someone signed in to your School Carpool account on a new phone, so we signed out your other phones. If it was you, there is nothing to do. If it wasn't, reply to this email at once.",
  },
} as const;

/**
 * Writes mail/{id} in the format of Firebase's "Trigger Email from
 * Firestore" extension (SETUP.md 23.4). Without the extension the message
 * waits in the collection (TTL 30 days); nothing else depends on it.
 */
export class FirestoreMailOutbox {
  constructor(private readonly db: Firestore) {}

  async sendNewDeviceEmail(uid: string, to: string, language: "ar" | "en", platform: Platform, atMs: number): Promise<void> {
    const m = NEW_DEVICE_MAIL[language];
    await this.db.collection(MAIL).doc().create({
      uid,
      to,
      message: { subject: m.subject, text: `${m.text}\n\n${platform} · ${new Date(atMs).toISOString().slice(0, 16).replace("T", " ")} UTC` },
      expiresAt: ts(atMs + 30 * DAY_MS),
    });
  }
}

// --------------------------------------------------------------------------
// Scraping alerts
// --------------------------------------------------------------------------

export class FirestoreAbuseStore implements AbuseStore {
  constructor(private readonly db: Firestore) {}

  count(uid: string, kind: AbuseKind, nowMs: number, count: (c: AbuseCounter | null) => { next: AbuseCounter; alert: boolean }): Promise<SecurityAlert | null> {
    const hour = Math.floor(nowMs / 3_600_000) * 3_600_000;
    const ref = this.db.collection(ABUSE_COUNTERS).doc(`${uid}_${kind}_${hour}`);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const current: AbuseCounter | null = snap.exists
        ? { hourStartMs: Number(snap.get("hourStartMs")) || hour, count: Number(snap.get("count")) || 0, keys: (snap.get("keys") as string[] | undefined) ?? [], alerted: snap.get("alerted") === true }
        : null;
      const r = count(current);
      tx.set(ref, { uid, kind, ...r.next, expiresAt: ts(hour + ABUSE_COUNTER_DAYS * DAY_MS) });
      if (!r.alert) return null;
      const alert = alertFor(uid, kind, r.next, nowMs);
      tx.set(this.db.collection(SECURITY_ALERTS).doc(alert.id), { uid, kind, count: alert.count, hourStart: ts(alert.hourStartMs), status: "open", createdAt: ts(nowMs), handledAt: null, handledBy: null, outcome: null });
      return alert;
    });
  }
}

// --------------------------------------------------------------------------
// Account deletion
// --------------------------------------------------------------------------

export interface DeletionHooks {
  /** Live runs the parent drives stop (trips/flow.ts endDriverTrips). */
  stopTrips(uid: string, nowMs: number): Promise<void>;
  /** Every carpool membership ends (carpools/flow.ts removeFromCarpool). */
  removeFromCarpool(uid: string, carpoolId: string): Promise<void>;
  /** A linked parent's carpools lose the deleted parent's child (trust/carpools.ts). */
  removeLinkedChild(guardianUid: string, childId: string): Promise<void>;
  chat: ChatServer;
  /** Wallet balance at the partner (piastres), or null when the wallet is off. */
  walletBalance(walletRef: string): Promise<number | null>;
  /** Freezes or unfreezes the wallet at the partner (no-op when the wallet is off). Throws on failure. */
  walletFreeze(walletRef: string, frozen: boolean): Promise<void>;
  revokeSessions(uid: string): Promise<void>;
  deleteAuthUser(uid: string): Promise<void>;
}

export class FirestoreDeletionRunner implements DeletionRunner {
  constructor(
    private readonly db: Firestore,
    private readonly bucket: Bucket,
    private readonly hooks: DeletionHooks,
  ) {}

  async facts(uid: string): Promise<AccountFacts> {
    const user = await this.db.collection(USERS).doc(uid).get();
    const driving = await this.db.collection("trips").where("driverUid", "==", uid).where("status", "==", "active").limit(1).get();
    return {
      openCase: await this.openCase(uid),
      exists: user.exists,
      drivingNow: !driving.empty,
      parentId: text(user.get("parentId")),
      banned: user.get("banned") === true,
    };
  }

  /**
   * Safety hold: an open report about the parent (reported as a user, or
   * the author of a reported message or chat) or an open rating flag.
   * Single-field queries, filtered here (no extra index).
   */
  private async openCase(uid: string): Promise<boolean> {
    const queries = [
      this.db.collection(REPORTS).where("targetId", "==", uid).limit(100),
      this.db.collection(REPORTS).where("subjectUid", "==", uid).limit(100),
      this.db.collection("ratingFlags").where("rateeUid", "==", uid).limit(100),
    ];
    for (const q of queries) {
      const snap = await q.get();
      if (snap.docs.some((d: QueryDocumentSnapshot) => d.get("status") === "open")) return true;
    }
    return false;
  }

  async lockWallet(uid: string, nowMs: number): Promise<WalletLock | null> {
    const ref = this.db.collection("wallets").doc(uid);
    // In a transaction: startTransfer reads both wallets in its own
    // transaction, so a transfer either committed before this (and is in
    // walletPending) or sees the wallet frozen and is refused.
    const locked = await this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists || snap.get("status") === "closed") return null;
      const lock: WalletLock = {
        status: text(snap.get("status")) || "active",
        frozenReason: text(snap.get("frozenReason")) || null,
        frozenAtMs: snap.get("frozenAt") ? millis(snap.get("frozenAt")) : null,
        frozenBy: text(snap.get("frozenBy")) || null,
      };
      tx.update(ref, { status: "frozen", frozenReason: CLOSING_REASON, frozenAt: ts(nowMs), frozenBy: "deletion", closingAt: ts(nowMs), updatedAt: ts(nowMs) });
      return { lock, walletRef: text(snap.get("walletRef")) };
    });
    if (!locked) return null;
    try {
      if (locked.lock.status === "active") await this.hooks.walletFreeze(locked.walletRef, true);
    } catch (error) {
      await this.restoreWallet(uid, locked.lock, nowMs);
      throw error;
    }
    return locked.lock;
  }

  async walletFacts(uid: string, nowMs: number): Promise<{ balance: number; pending: number }> {
    const wallet = await this.db.collection("wallets").doc(uid).get();
    // Outgoing and incoming entries (parties), and entries written before
    // parties was stored (uid: outgoing only).
    const both = await this.db.collection("walletPending").where("parties", "array-contains", uid).limit(1).get();
    const out = await this.db.collection("walletPending").where("uid", "==", uid).limit(1).get();
    // Transfers of the last 30 days without an outcome, either direction
    // (covers a pending entry written before parties was stored).
    const recent = await this.db
      .collection("transfers")
      .where("parties", "array-contains", uid)
      .where("createdAt", ">=", ts(nowMs - 30 * DAY_MS))
      .orderBy("createdAt", "desc")
      .limit(100)
      .get();
    let open = 0;
    if (!recent.empty) {
      const results = await this.db.getAll(...recent.docs.map((d) => this.db.collection("transferResults").doc(d.id)));
      open = results.filter((r) => !r.exists).length;
    }
    const balance = await this.hooks.walletBalance(text(wallet.get("walletRef")));
    // The partner cannot be asked: use our copy (never 0 by guess).
    const known = balance ?? (typeof wallet.get("balanceCopy") === "number" ? (wallet.get("balanceCopy") as number) : 1);
    return { balance: known, pending: both.size + out.size + open };
  }

  async unlockWallet(uid: string, lock: WalletLock, nowMs: number): Promise<void> {
    const ref = this.db.collection("wallets").doc(uid);
    if (lock.status === "active") await this.hooks.walletFreeze(text((await ref.get()).get("walletRef")), false);
    await this.restoreWallet(uid, lock, nowMs);
  }

  private async restoreWallet(uid: string, lock: WalletLock, nowMs: number): Promise<void> {
    await this.db
      .collection("wallets")
      .doc(uid)
      .update({
        status: lock.status,
        frozenReason: lock.frozenReason,
        frozenAt: lock.frozenAtMs === null ? null : ts(lock.frozenAtMs),
        frozenBy: lock.frozenBy,
        closingAt: FieldValue.delete(),
        updatedAt: ts(nowMs),
      });
  }

  async saveClosed(c: ClosedAccount): Promise<void> {
    await this.db.collection(CLOSED_ACCOUNTS).doc(c.uid).set({
      // The parent ID is dropped once the purge is done (the reservation stays in parentIds).
      parentId: c.purgedAtMs === null ? c.parentId : null,
      closedAt: ts(c.closedAtMs),
      // The next date the daily job has work here (closedAccountsToWork):
      // the evidence date, then the 1-year date of the kept records.
      purgeAt: ts(nextWorkAt(c) ?? c.purgeAtMs),
      recordsPurgeAt: ts(c.purgeAtMs),
      hold: c.hold,
      evidenceAt: ts(c.evidenceAtMs),
      evidenceDoneAt: c.evidenceDoneAtMs === null ? null : ts(c.evidenceDoneAtMs),
      banned: c.banned,
      failed: c.failed,
      failedCount: c.failed.length,
      purged: c.purgedAtMs !== null,
      purgedAt: c.purgedAtMs === null ? null : ts(c.purgedAtMs),
    });
  }

  async closed(uid: string): Promise<ClosedAccount | null> {
    const snap = await this.db.collection(CLOSED_ACCOUNTS).doc(uid).get();
    return snap.exists ? closedFromDoc(uid, snap.data() ?? {}) : null;
  }

  async runFlowStep(uid: string, step: FlowStep, nowMs: number): Promise<void> {
    switch (step) {
      case "trips":
        return this.hooks.stopTrips(uid, nowMs);
      case "carpools": {
        const snap = await this.db.collection("memberships").where("uid", "==", uid).limit(200).get();
        for (const d of snap.docs) {
          const status = text(d.get("status"));
          if (status === "approved" || status === "requested") await this.hooks.removeFromCarpool(uid, text(d.get("carpoolId")));
        }
        return;
      }
      case "anonymise":
        return this.anonymise(uid, nowMs);
      case "chat": {
        await this.hooks.chat.revokeTokens(uid, nowMs + 1000);
        await this.hooks.chat.deactivateUser(uid);
        // Private chats end now (frozen; what the OTHER parent wrote is
        // deleted 1 year later). Group chats drop the parent through the
        // chat sync when the record goes.
        const snap = await this.db.collection("chatChannels").where("members", "array-contains", uid).limit(500).get();
        for (const d of snap.docs) {
          if (d.get("kind") !== "private") continue;
          const [type, id] = d.id.split(":");
          await this.hooks.chat.setFrozen(type, id, true);
          await d.ref.update({ frozen: true, endedAt: ts(nowMs), updatedAt: ts(nowMs) });
        }
        // Owner decision 16 Nov 2026 (guideline 5.1.1(v)): the chat user
        // and EVERY message the parent wrote (private and group chats) are
        // hard-deleted now, not a year later. Reports keep their own copy.
        await this.hooks.chat.deleteUser(uid);
        return;
      }
      case "trust": {
        const links = await this.db.collection("guardianLinks").where("ownerUid", "==", uid).limit(100).get();
        for (const l of links.docs) {
          if (l.get("status") === "active") await this.hooks.removeLinkedChild(text(l.get("guardianUid")), text(l.get("childId")));
        }
        // Vouches by the deleted parent leave other parents' summaries.
        const vouched = await this.db.collection("trustSummaries").where("voucherUids", "array-contains", uid).limit(500).get();
        for (const s of vouched.docs) await s.ref.update({ voucherUids: FieldValue.arrayRemove(uid) });
        return;
      }
      case "identity": {
        // The claim on the ID number goes; a ban (bannedIds) stays.
        await deleteQuery(this.db, this.db.collection("nationalIds").where("uid", "==", uid));
        return;
      }
      case "wallet": {
        const ref = this.db.collection("wallets").doc(uid);
        if ((await ref.get()).exists) await ref.update({ status: "closed", closedAt: ts(nowMs), updatedAt: ts(nowMs) });
        return;
      }
      case "places": {
        // F46: the address leaves its area's and district's address counts
        // (placeInternal). The address is taken off the home in the same
        // transaction, so a retried step never counts it twice; the home
        // itself goes with the records step.
        const home = this.db.collection("homes").doc(uid);
        await this.db.runTransaction(async (tx) => {
          const snap = await tx.get(home);
          const address = snap.exists ? (snap.get("address") as DocumentData | null | undefined) : null;
          if (!address || typeof address.placeAreaId !== "string" || !address.placeAreaId) return;
          const counts: Array<[string, string]> = [["area", address.placeAreaId]];
          if (typeof address.placeDistrictId === "string" && address.placeDistrictId) counts.push(["district", address.placeDistrictId]);
          for (const [kind, id] of counts) {
            tx.set(
              this.db.collection(PLACE_INTERNAL).doc(internalId(kind as "area" | "district", id)),
              { kind, placeId: id, addressCount: FieldValue.increment(-1) },
              { merge: true },
            );
          }
          tx.update(home, { address: null });
        });
        return;
      }
      case "records":
        return;
      case "auth":
        await this.hooks.revokeSessions(uid);
        await this.hooks.deleteAuthUser(uid);
        return;
    }
  }

  /** See anonymise.ts. Every page is read until empty (idempotent: a retry finds nothing left). */
  private async anonymise(uid: string, nowMs: number): Promise<void> {
    const apply = async (docs: QueryDocumentSnapshot[], fn: (d: DocumentData, uid: string) => DocumentData | null) => {
      for (const d of docs) {
        const change = fn(d.data(), uid);
        if (change) await d.ref.update(change);
      }
    };
    // Trips the parent's children rode in (other drivers' records) and trips the parent drove.
    // Owner rule (13:29): the trip stays until this parent's closure + 1 year too.
    const tripChange = (d: DocumentData, u: string) => keepForClosedParent(d, anonymiseTrip(d, u), nowMs);
    await apply((await this.db.collection("trips").where("viewerUids", "array-contains", uid).limit(2_000).get()).docs, tripChange);
    await apply((await this.db.collection("trips").where("driverUid", "==", uid).limit(2_000).get()).docs, tripChange);
    // Settle up (F45): the parent's side of each record becomes an initial,
    // an unfinished record ends, and it is kept for the other parent
    // (retention: purgeSettleUps). A retry finds nothing left (the parent
    // is no longer in `parties`).
    // Bounded: every pass takes the parent out of `parties` of each record
    // it read, so the next page is new records; a damaged record (the uid
    // in `parties` but neither payee nor payer) is taken out too, and the
    // page cap stops a loop that makes no progress (the step then fails
    // and is retried and reported by retentionDaily).
    for (let pass = 0; ; pass++) {
      if (pass >= SETTLE_UP_ANONYMISE_MAX_PAGES) throw new Error("settle-up anonymise: page cap reached; retried tomorrow");
      const page = await this.db.collection(SETTLE_UPS).where("parties", "array-contains", uid).limit(BATCH).get();
      for (const d of page.docs) {
        const next = anonymiseSettleUp(settleFromDoc(d.id, d.data()), uid, nowMs);
        if (next) await d.ref.set(settleToDoc(next));
        else await d.ref.update({ parties: FieldValue.arrayRemove(uid) });
      }
      if (page.size < BATCH) break;
    }
    // The carpools the parent was ever in (memberships of any status).
    const carpoolIds = new Set<string>();
    for (const m of (await this.db.collection("memberships").where("uid", "==", uid).limit(500).get()).docs) {
      const id = text(m.get("carpoolId"));
      if (id) carpoolIds.add(id);
    }
    for (const carpoolId of carpoolIds) {
      const carpool = this.db.collection("carpools").doc(carpoolId);
      const card = await carpool.get();
      if (card.exists) {
        const change = anonymiseCarpool(card.data() ?? {}, uid);
        if (change) await carpool.update(change);
      }
      for (const [sub, fn] of [
        ["schedule", anonymiseRun],
        ["swaps", anonymiseSwap],
        ["balances", anonymiseBalance],
      ] as const) {
        let last: QueryDocumentSnapshot | null = null;
        for (;;) {
          let q = carpool.collection(sub).orderBy(FieldPath.documentId()).limit(BATCH);
          if (last) q = q.startAfter(last);
          const page = await q.get();
          await apply(page.docs, fn);
          if (page.size < BATCH) break;
          last = page.docs[page.docs.length - 1];
        }
      }
    }
  }

  async runTarget(uid: string, target: Target): Promise<number> {
    switch (target.kind) {
      case "doc":
        await this.db.doc(pathFor(target.path, uid)).delete();
        return 1;
      case "where":
        return deleteQuery(this.db, this.db.collection(target.collection).where(target.field, target.op ?? "==", uid));
      case "subcollection":
        return deleteQuery(this.db, this.db.collection(pathFor(target.path, uid)));
      case "storage": {
        const [files] = await this.bucket.getFiles({ prefix: pathFor(target.prefix, uid) });
        for (const f of files) await f.delete({ ignoreNotFound: true });
        return files.length;
      }
    }
  }

  async runPurgeStep(uid: string, step: PurgeStep | EvidenceStep): Promise<void> {
    if (step === "trips") {
      // Owner answer 14 Nov 13:29: the trips this parent drove stay while
      // another participant's data is kept; this parent's part is anonymised.
      const trips = await this.db.collection("trips").where("driverUid", "==", uid).limit(2_000).get();
      if (trips.size === 2_000) throw new Error("trips page full; retried tomorrow");
      await applyTripRetention(this.db, trips.docs, Date.now(), new Set([uid]));
      return;
    }
    const snap = await this.db.collection(ROUTE_ARCHIVES).where("driverUid", "==", uid).limit(2_000).get();
    for (const d of snap.docs) {
      await this.bucket.file(text(d.get("path"))).delete({ ignoreNotFound: true });
      await d.ref.delete();
    }
  }
}

/** Active (users/{uid} exists), closed (closedAccounts/{uid}), or no record. */
async function accountStates(db: Firestore, uids: Iterable<string>): Promise<Map<string, AccountState>> {
  const out = new Map<string, AccountState>();
  for (const uid of uids) {
    if (out.has(uid)) continue;
    if ((await db.collection(USERS).doc(uid).get()).exists) {
      out.set(uid, { active: true });
      continue;
    }
    const closed = await db.collection(CLOSED_ACCOUNTS).doc(uid).get();
    if (closed.exists) out.set(uid, { active: false, closedAtMs: closed.get("closedAt") ? millis(closed.get("closedAt")) : null });
  }
  return out;
}

/**
 * Owner answer (14 Nov 2026, 13:29): each trip stays while any participant
 * is active + 1 year; expired parts are anonymised; a trip with nobody
 * left is deleted with its subcollections. Returns how many were deleted.
 */
async function applyTripRetention(db: Firestore, docs: QueryDocumentSnapshot[], nowMs: number, expired: ReadonlySet<string> = new Set()): Promise<number> {
  const states = await accountStates(db, docs.flatMap((d) => participantsOf(d.data())));
  let deleted = 0;
  for (const d of docs) {
    const plan = planTripRetention(d.data(), states, nowMs, expired);
    if (plan.action === "delete") {
      await db.recursiveDelete(d.ref);
      deleted += 1;
    } else if (plan.change) {
      await d.ref.update({ ...plan.change, updatedAt: ts(nowMs) });
    }
  }
  return deleted;
}

function closedFromDoc(uid: string, d: DocumentData): ClosedAccount {
  return {
    uid,
    parentId: text(d.parentId),
    closedAtMs: millis(d.closedAt),
    hold: d.hold === true,
    // A record written under the older rule (photos kept 1 year) has no
    // evidence date: its evidence is due since the closure, so the next
    // daily run deletes it (`deletions:reapply` makes that run find it).
    evidenceAtMs: d.evidenceAt ? millis(d.evidenceAt) : millis(d.closedAt),
    evidenceDoneAtMs: d.evidenceDoneAt ? millis(d.evidenceDoneAt) : null,
    purgeAtMs: d.recordsPurgeAt ? millis(d.recordsPurgeAt) : millis(d.purgeAt),
    banned: d.banned === true,
    failed: Array.isArray(d.failed) ? d.failed.filter((x: unknown): x is string => typeof x === "string") : [],
    purgedAtMs: d.purgedAt ? millis(d.purgedAt) : null,
  };
}

// --------------------------------------------------------------------------
// Retention job
// --------------------------------------------------------------------------

export class FirestoreRetentionStore implements RetentionStore {
  constructor(
    private readonly db: Firestore,
    private readonly bucket: Bucket,
  ) {}

  async closedAccountsToWork(nowMs: number, limit: number): Promise<ClosedAccount[]> {
    const failed = await this.db.collection(CLOSED_ACCOUNTS).where("failedCount", ">", 0).limit(limit).get();
    const due = await this.db.collection(CLOSED_ACCOUNTS).where("purged", "==", false).where("purgeAt", "<=", ts(nowMs)).limit(limit).get();
    const byId = new Map<string, ClosedAccount>();
    for (const d of [...failed.docs, ...due.docs]) byId.set(d.id, closedFromDoc(d.id, d.data()));
    return [...byId.values()];
  }

  async deleteRouteArchivesDue(nowMs: number, limit: number): Promise<number> {
    const snap = await this.db.collection(ROUTE_ARCHIVES).where("purgeAt", "<=", ts(nowMs)).limit(limit).get();
    for (const d of snap.docs) {
      await this.bucket.file(text(d.get("path"))).delete({ ignoreNotFound: true });
      await d.ref.delete();
    }
    return snap.size;
  }

  async endClosedCarpoolChats(nowMs: number, limit: number, freeze: (cid: string) => Promise<void>): Promise<number> {
    // Carpools closed in the last 30 days (the job runs daily; a missed
    // week still catches up; a chat already ended is skipped).
    const closed = await this.db.collection("carpools").where("status", "==", "closed").where("updatedAt", ">=", ts(nowMs - 30 * DAY_MS)).limit(limit).get();
    let ended = 0;
    for (const c of closed.docs) {
      const channels = await this.db.collection("chatChannels").where("kind", "==", "carpool").where("refId", "==", c.id).limit(1).get();
      for (const ch of channels.docs) {
        if (ch.get("endedAt")) continue;
        await freeze(ch.id);
        await ch.ref.update({ frozen: true, endedAt: ts(nowMs), updatedAt: ts(nowMs) });
        ended += 1;
      }
    }
    return ended;
  }

  async purgeClosedCarpoolsBefore(before: number, limit: number): Promise<number> {
    const closed = await this.db.collection("carpools").where("status", "==", "closed").where("updatedAt", "<=", ts(before)).limit(limit).get();
    for (const c of closed.docs) {
      // Owner answer 14 Nov 13:29: trips are NOT deleted with the carpool;
      // each stays while a participant is active + 1 year (trip_retention.ts).
      const trips = await this.db.collection("trips").where("carpoolId", "==", c.id).limit(2_000).get();
      if (trips.size === 2_000) throw new Error("trips page full; retried tomorrow");
      await applyTripRetention(this.db, trips.docs, Date.now());
      await deleteQuery(this.db, this.db.collection("memberships").where("carpoolId", "==", c.id));
      await deleteQuery(this.db, this.db.collection("carpoolInvites").where("carpoolId", "==", c.id));
      // Last: the card with members, requests, pickupPoints, schedule, swaps, balances, emergencies.
      await this.db.recursiveDelete(c.ref);
    }
    return closed.size;
  }

  async deleteOrphanTrips(nowMs: number, limit: number): Promise<number> {
    // Only trips whose last kept year is over (review finding 3: no
    // re-reading the same kept trips every day).
    const snap = await this.db.collection("trips").where("driverUid", "==", DELETED_ID).where("keptUntilMs", "<=", nowMs).limit(limit).get();
    return applyTripRetention(this.db, snap.docs, nowMs);
  }

  async purgeSettleUps(nowMs: number, limit: number): Promise<number> {
    const snap = await this.db.collection(SETTLE_UPS).where("keptUntilMs", "<=", nowMs).limit(limit).get();
    let deleted = 0;
    for (const d of snap.docs) {
      const r = settleFromDoc(d.id, d.data());
      const active = new Set<string>();
      for (const p of r.parties) if ((await this.db.collection(USERS).doc(p).get()).exists) active.add(p);
      const plan = planRetention(r, active, nowMs);
      if (plan === "delete") {
        await d.ref.delete();
        deleted += 1;
      } else if (plan === "clear") {
        await d.ref.update({ keptUntilMs: null });
      }
    }
    return deleted;
  }

  async endedChatsBefore(before: number, limit: number): Promise<string[]> {
    const snap = await this.db.collection("chatChannels").where("endedAt", "<=", ts(before)).limit(limit).get();
    return snap.docs.map((d) => d.id);
  }

  async deleteChatRecord(cid: string): Promise<void> {
    await this.db.collection("chatChannels").doc(cid).delete();
  }

  async clearReportContexts(before: number, limit: number): Promise<number> {
    const snap = await this.db.collection(REPORTS).where("status", "==", "handled").where("handledAt", "<=", ts(before)).limit(limit).get();
    let cleared = 0;
    for (const d of snap.docs) {
      const context = d.get("context");
      if (!Array.isArray(context) || context.length === 0) continue;
      await d.ref.update({ context: [], contextClearedAt: FieldValue.serverTimestamp() });
      cleared += 1;
    }
    return cleared;
  }

  async deleteTripStopsBefore(before: number, limit: number): Promise<number> {
    return deleteQuery(this.db, this.db.collection("tripStops").where("expiresAt", "<=", ts(before)), limit);
  }

  async deleteAuditBefore(before: number, limit: number): Promise<number> {
    return deleteQuery(this.db, this.db.collection("auditLog").where("time", "<", ts(before)), limit);
  }

  async deleteExportsBefore(before: number): Promise<number> {
    const [files] = await this.bucket.getFiles({ prefix: "exports/" });
    let deleted = 0;
    for (const f of files) {
      const created = Date.parse(String(f.metadata.timeCreated ?? ""));
      if (Number.isFinite(created) && created < before) {
        await f.delete({ ignoreNotFound: true });
        deleted += 1;
      }
    }
    return deleted;
  }

  async deleteHandledSecurityAlertsBefore(before: number, limit: number): Promise<number> {
    return deleteQuery(this.db, this.db.collection(SECURITY_ALERTS).where("status", "==", "handled").where("handledAt", "<=", ts(before)), limit);
  }

  async saveRun(report: RetentionReport): Promise<void> {
    await this.db.collection(RETENTION_RUNS).doc(report.date).set({ ...report, startedAt: ts(report.startedAtMs), expiresAt: ts(report.startedAtMs + 365 * DAY_MS) });
  }

  async raiseFailureAlert(report: RetentionReport): Promise<void> {
    await this.db.collection(SECURITY_ALERTS).doc(`retention_${report.date}`).set({
      uid: null,
      kind: "retentionFailed",
      count: report.failures.length,
      // Codes only (data type, step, uid): no personal data.
      failures: report.failures.slice(0, 50),
      status: "open",
      createdAt: ts(report.startedAtMs),
      handledAt: null,
      handledBy: null,
      outcome: null,
    });
  }
}

// --------------------------------------------------------------------------
// Privacy requests and consents
// --------------------------------------------------------------------------

export class FirestorePrivacyStore {
  constructor(private readonly db: Firestore) {}

  newId(): string {
    return this.db.collection(PRIVACY_REQUESTS).doc().id;
  }

  async putRequest(r: PrivacyRequest): Promise<void> {
    await this.db.collection(PRIVACY_REQUESTS).doc(r.id).set({
      uid: r.uid,
      kind: r.kind,
      subject: r.subject,
      status: r.status,
      reason: r.reason,
      createdAt: ts(r.createdAtMs),
      doneAt: r.doneAtMs === null ? null : ts(r.doneAtMs),
      expiresAt: ts(r.expiresAtMs),
      dueAt: ts(r.dueAtMs ?? responseDueAt(r.createdAtMs)),
    });
  }

  async requests(uid: string, limit: number): Promise<PrivacyRequest[]> {
    const snap = await this.db.collection(PRIVACY_REQUESTS).where("uid", "==", uid).orderBy("createdAt", "desc").limit(limit).get();
    return snap.docs.map((d) => requestFromDoc(d.id, d.data()));
  }

  async openRequests(limit: number): Promise<PrivacyRequest[]> {
    const snap = await this.db.collection(PRIVACY_REQUESTS).where("status", "==", "open").orderBy("createdAt", "asc").limit(limit).get();
    return snap.docs.map((d) => requestFromDoc(d.id, d.data()));
  }

  async request(id: string): Promise<PrivacyRequest | null> {
    const snap = await this.db.collection(PRIVACY_REQUESTS).doc(id).get();
    return snap.exists ? requestFromDoc(snap.id, snap.data() ?? {}) : null;
  }

  async consents(uid: string): Promise<ConsentRow[]> {
    const snap = await this.db.collection(USERS).doc(uid).collection("consents").limit(200).get();
    return snap.docs.map((d) => ({
      type: text(d.get("type")),
      version: text(d.get("version")) || null,
      acceptedAtMs: millis(d.get("acceptedAt")),
      withdrawnAtMs: d.get("withdrawnAt") ? millis(d.get("withdrawnAt")) : null,
    }));
  }

  /** A new consent record (given), or withdrawnAt on the open ones of [type] (withdrawn). */
  async setConsent(uid: string, type: string, version: string, granted: boolean, nowMs: number): Promise<void> {
    const consents = this.db.collection(USERS).doc(uid).collection("consents");
    if (granted) {
      await consents.doc().create({ type, version, acceptedAt: ts(nowMs), withdrawnAt: null, source: "privacy" });
      return;
    }
    const open = await consents.where("type", "==", type).where("withdrawnAt", "==", null).limit(20).get();
    if (open.empty) {
      // Default-on choices (analytics) have no record yet: record the withdrawal itself.
      await consents.doc().create({ type, version, acceptedAt: ts(nowMs), withdrawnAt: ts(nowMs), source: "privacy" });
      return;
    }
    const batch = this.db.batch();
    for (const d of open.docs) batch.update(d.ref, { withdrawnAt: ts(nowMs) });
    await batch.commit();
  }

  async showOnMap(uid: string): Promise<boolean> {
    const home = await this.db.collection("homes").doc(uid).get();
    return home.exists ? home.get("showOnMap") !== false : false;
  }
}

function requestFromDoc(id: string, d: DocumentData): PrivacyRequest {
  return {
    id,
    uid: text(d.uid),
    kind: d.kind as PrivacyRequest["kind"],
    subject: text(d.subject) || null,
    status: (["done", "open", "refused", "failed"].includes(text(d.status)) ? d.status : "open") as PrivacyRequest["status"],
    reason: text(d.reason) || null,
    createdAtMs: millis(d.createdAt),
    doneAtMs: d.doneAt ? millis(d.doneAt) : null,
    expiresAtMs: millis(d.expiresAt),
    dueAtMs: d.dueAt ? millis(d.dueAt) : responseDueAt(millis(d.createdAt)),
  };
}

// --------------------------------------------------------------------------
// Export
// --------------------------------------------------------------------------

const ACCOUNT_FIELDS = ["parentId", "status", "phone", "email", "emailVerified", "language", "firstName", "lastName", "idExpiry", "whatsappOptIn", "termsVersion", "termsAcceptedAt", "createdAt", "updatedAt"] as const;

export class FirestoreExportSource implements ExportSource {
  constructor(
    private readonly db: Firestore,
    private readonly bucket: Bucket,
    private readonly chat: ChatServer,
  ) {}

  private current: DataTypeId | null = null;
  private readonly cut = new Set<DataTypeId>();

  truncated(): DataTypeId[] {
    return [...this.cut];
  }

  /** query.limit(limit).get(), noting a section that reached the limit. */
  private async read(query: Query, limit: number): Promise<QuerySnapshot> {
    const snap = await query.limit(limit).get();
    if (snap.size >= limit && this.current) this.cut.add(this.current);
    return snap;
  }

  private async docs(query: Query, limit = 500): Promise<unknown[]> {
    const snap = await this.read(query, limit);
    return snap.docs.map((d) => ({ id: d.id, ...(plain(d.data()) as Record<string, unknown>) }));
  }

  /** The parent's carpools (memberships of any status). */
  private async carpoolIds(uid: string): Promise<string[]> {
    const m = await this.read(this.db.collection("memberships").where("uid", "==", uid), 200);
    const ids = new Set<string>();
    for (const d of m.docs) {
      const id = text(d.get("carpoolId"));
      if (id) ids.add(id);
    }
    return [...ids];
  }

  private async doc(path: string): Promise<unknown> {
    const snap = await this.db.doc(path).get();
    return snap.exists ? plain(snap.data()) : null;
  }

  private async files(prefix: string): Promise<Array<{ name: string; storedAt: string }>> {
    const [files] = await this.bucket.getFiles({ prefix });
    return files.map((f) => ({ name: f.name.slice(f.name.lastIndexOf("/") + 1), storedAt: String(f.metadata.timeCreated ?? "") }));
  }

  async section(uid: string, id: DataTypeId): Promise<unknown> {
    this.current = id;
    const db = this.db;
    switch (id) {
      case "account":
        return pick((await db.collection(USERS).doc(uid).get()).data(), ACCOUNT_FIELDS);
      case "consents":
        return {
          records: await this.docs(db.collection(USERS).doc(uid).collection("consents")),
          // Every privacy request (export, correction, deletion, consent change) and its answer.
          privacyRequests: (await this.docs(db.collection(PRIVACY_REQUESTS).where("uid", "==", uid), 500)).map((r) => pick(r as DocumentData, ["id", "kind", "subject", "status", "reason", "createdAt", "doneAt"])),
        };
      case "idPhotos": {
        const cases = await this.read(db.collection("verifications").where("uid", "==", uid), 50);
        return {
          note: "Photos are listed with their dates; ask for a copy from the privacy screen.",
          reviews: cases.docs.map((d) => ({ id: d.id, ...pick(d.data(), ["scope", "status", "submittedAt", "decidedAt", "reasonCode"]) })),
          photos: [
            ...(await this.files(`verification/${uid}/cases/`)),
            ...(await this.files(`faceRefs/${uid}/`)),
            ...(await this.files(`driverPhotos/${uid}/`)),
            ...(await this.files(`selfieArchive/${uid}/`)),
          ],
        };
      }
      case "children":
        return this.docs(db.collection("children").where("ownerUid", "==", uid));
      case "vehicle":
        return this.doc(`vehicles/${uid}`);
      case "home":
        return {
          exact: await this.doc(`homes/${uid}`),
          shownToOthers: await this.doc(`parentLocations/${uid}`),
          // F46: a typed "my district isn't listed" waiting for the admins.
          districtRequest: await this.doc(`placeRequests/${uid}`),
        };
      case "carpools": {
        const ids = await this.carpoolIds(uid);
        const perCarpool: unknown[] = [];
        for (const carpoolId of ids) {
          const c = db.collection("carpools").doc(carpoolId);
          perCarpool.push({
            carpoolId,
            joinRequest: await this.doc(`carpools/${carpoolId}/requests/${uid}`),
            // The exact pickup point shared with this carpool's members.
            pickupPoint: await this.doc(`carpools/${carpoolId}/pickupPoints/${uid}`),
            driverConsents: [
              ...(await this.docs(c.collection("driverConsents").where("parentUid", "==", uid), 100)),
              ...(await this.docs(c.collection("driverConsents").where("driverUid", "==", uid), 100)),
            ],
          });
        }
        return {
          memberships: await this.docs(db.collection("memberships").where("uid", "==", uid)),
          carpools: perCarpool,
          lookingForACarpool: await this.doc(`carpoolWanted/${uid}`),
        };
      }
      case "schedule": {
        const m = await this.read(db.collection("memberships").where("uid", "==", uid).where("status", "==", "approved"), 50);
        return m.docs.map((d) => ({ carpoolId: d.get("carpoolId"), drivingDays: d.get("drivingDays") ?? [] }));
      }
      case "trips": {
        const fields = ["carpoolId", "runId", "date", "direction", "status", "startedAt", "endedAt", "endReason"] as const;
        const drove = await this.read(db.collection("trips").where("driverUid", "==", uid), 500);
        const rode = await this.read(db.collection("trips").where("viewerUids", "array-contains", uid), 500);
        return {
          drove: drove.docs.map((d) => ({ id: d.id, ...pick(d.data(), fields), children: Array.isArray(d.get("stops")) ? (d.get("stops") as unknown[]).length : 0 })),
          childrenCarried: rode.docs.filter((d) => d.get("driverUid") !== uid).map((d) => ({ id: d.id, ...pick(d.data(), fields) })),
        };
      }
      case "liveLocation":
        return { note: "Live points are deleted within 24 hours of each run; none are kept for export." };
      case "routeArchive": {
        const snap = await this.read(db.collection(ROUTE_ARCHIVES).where("driverUid", "==", uid), 1_000);
        return {
          note: "Each run you drove is kept as one compressed route for 1 year, for safety investigations only (admins, logged reason).",
          runs: snap.docs.map((d) => ({ tripId: d.id, ...pick(d.data(), ["startedAt", "endedAt", "points", "purgeAt"]) })),
        };
      }
      case "chat": {
        const messages = await this.chat.userMessages(uid, 5_000);
        if (messages.length >= 5_000) this.cut.add("chat");
        return {
          messages,
          requestsSent: await this.docs(db.collection("chatRequests").where("fromUid", "==", uid)),
          requestsReceived: await this.docs(db.collection("chatRequests").where("toUid", "==", uid)),
          blocked: await this.docs(db.collection("chatBlocks").where("blockerUid", "==", uid)),
          muted: await this.docs(db.collection("chatMutes").where("uid", "==", uid)),
          settings: await this.doc(`chatSettings/${uid}`),
        };
      }
      case "ratings":
        return {
          given: await this.docs(db.collection("ratings").where("raterUid", "==", uid)),
          // Received: the summary only, so the raters stay private. Vouches
          // given are on each rating given (vouch: true); received: a count.
          received: await (async () => {
            const summary = (await db.collection("trustSummaries").doc(uid).get()).data();
            const vouchers = summary?.voucherUids;
            return summary ? { ...pick(summary, ["count", "sum", "updatedAt"]), vouches: Array.isArray(vouchers) ? vouchers.length : 0 } : null;
          })(),
        };
      case "familyLinks":
        return {
          asParent: await this.docs(db.collection("guardianLinks").where("ownerUid", "==", uid)),
          asGuardian: await this.docs(db.collection("guardianLinks").where("guardianUid", "==", uid)),
          requestsSent: await this.docs(db.collection("guardianRequests").where("ownerUid", "==", uid)),
          requestsReceived: await this.docs(db.collection("guardianRequests").where("guardianUid", "==", uid)),
        };
      case "handover":
        return this.docs(db.collection("handoverAdults").where("ownerUid", "==", uid));
      case "emergencyContact":
        return this.doc(`emergencyContacts/${uid}`);
      case "notifications":
        return {
          settings: await this.doc(`notificationSettings/${uid}`),
          recent: await this.docs(db.collection(USERS).doc(uid).collection("notifications").orderBy("createdAt", "desc"), 200),
        };
      case "devices":
        return {
          phones: await this.docs(db.collection(USERS).doc(uid).collection(DEVICES)),
          signIns: await this.docs(db.collection(USERS).doc(uid).collection(LOGINS).orderBy("at", "desc"), 50),
        };
      case "wallet": {
        const transfers = await this.read(db.collection("transfers").where("parties", "array-contains", uid), 1_000);
        const ids = transfers.docs.map((d) => d.id);
        const results = new Map<string, DocumentData>();
        for (let i = 0; i < ids.length; i += 100) {
          const refs = ids.slice(i, i + 100).map((x) => db.collection("transferResults").doc(x));
          if (refs.length === 0) continue;
          for (const r of await db.getAll(...refs)) if (r.exists) results.set(r.id, r.data() ?? {});
        }
        return {
          wallet: pick((await db.collection("wallets").doc(uid).get()).data(), ["status", "createdAt", "closedAt"]),
          transfers: transfers.docs.map((d) => ({
            id: d.id,
            ...pick(d.data(), ["kind", "amount", "currency", "note", "createdAt", "fromFirstName", "toFirstName"]),
            direction: d.get("fromUid") === uid ? "out" : "in",
            result: pick(results.get(d.id), ["status", "reason", "settledAt", "partnerRef"]),
          })),
        };
      }
      case "settleUp": {
        // The parent's own InstaPay address and their payment records. The
        // other parent appears by first name only; never their address.
        const records = await this.read(db.collection(SETTLE_UPS).where("parties", "array-contains", uid), 1_000);
        return {
          instaPayAddress: text((await db.collection(SETTLE_ADDRESSES).doc(uid).get()).get("address")) || null,
          records: records.docs.map((d) => {
            const r = settleFromDoc(d.id, d.data());
            const payee = r.payeeUid === uid;
            return {
              id: r.id,
              role: payee ? "payee" : "payer",
              otherFirstName: payee ? r.payerFirstName : r.payeeFirstName,
              amount: r.amount,
              currency: r.currency,
              reason: r.reason,
              note: r.note,
              status: r.status,
              createdAt: new Date(r.createdAtMs).toISOString(),
              history: r.events.map((e) => ({ type: e.type, by: e.by, at: new Date(e.atMs).toISOString() })),
            };
          }),
        };
      }
      case "reports": {
        const mine = await this.read(db.collection(REPORTS).where("reporterId", "==", uid), 200);
        const about = await this.read(db.collection(REPORTS).where("targetId", "==", uid).where("status", "==", "open"), 200);
        return {
          filedByYou: mine.docs.map((d) => ({ id: d.id, ...pick(d.data(), ["reason", "status", "createdAt", "handledAt", "outcome"]) })),
          // Never who reported or what they wrote.
          openAboutYou: about.size,
        };
      }
      case "analytics":
        return { note: "Usage statistics are not linked to your name, number or ID in our records; switch them off in Settings." };
      case "crashReports":
        return { note: "Error reports are sent with phone numbers, ID numbers, places and message text removed, and are kept 90 days." };
    }
  }
}

export { text as textOf };
