import { Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import { onCall } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { reasonErrorMapper, runCallable } from "../common/callable";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { ADMIN_ERROR_CODES, AdminError } from "../admin_panel/errors";
import type { AdminCaller } from "../admin_panel/guard";
import { AUDIT_LOG, auditDoc } from "../admin_panel/store";
import type { AuditEntry } from "../admin_panel/types";
import { ENFORCE_APP_CHECK } from "../config";
import { applyBreachUpdate, BREACH_REGISTER, BreachError, breachView, newBreach, type BreachRecord } from "./breaches";

/**
 * Admin panel > Incidents: the personal data breach register (breaches.ts,
 * docs/legal/breach-runbook.md). Any admin reports an incident (the
 * 72-hour clock starts at "aware at") and records what happens next; every
 * call writes an audit entry in the same batch as the record. Only these
 * callables write breachRegister (firestore.rules deny every client).
 */

export interface BreachStore {
  newId(): string;
  get(id: string): Promise<BreachRecord | null>;
  /** The record and its audit entry together, or neither. */
  put(record: BreachRecord, audit: AuditEntry): Promise<void>;
  list(limit: number): Promise<BreachRecord[]>;
}

export interface BreachDeps {
  store: BreachStore;
  now: () => number;
}

const BREACH_ERROR_CODES: Record<string, string> = { "invalid-request": "invalid-argument", "not-found": "not-found", "invalid-state": "failed-precondition" };

export async function reportIncident(deps: BreachDeps, caller: AdminCaller, data: unknown, ip: string | null) {
  const nowMs = deps.now();
  const record = newBreach(deps.store.newId(), data, caller.uid, nowMs);
  await deps.store.put(record, {
    actorUid: caller.uid,
    action: "breach.report",
    target: `${BREACH_REGISTER}/${record.id}`,
    details: { sensitive: record.sensitive, nationalSecurity: record.nationalSecurity, approxPeople: record.approxPeople },
    ip,
  });
  return breachView(record, nowMs);
}

export async function updateIncident(deps: BreachDeps, caller: AdminCaller, data: unknown, ip: string | null) {
  const id = typeof data === "object" && data !== null ? (data as { id?: unknown }).id : undefined;
  if (typeof id !== "string" || !/^[A-Za-z0-9]{1,40}$/.test(id)) throw new BreachError("invalid-request");
  const current = await deps.store.get(id);
  if (!current) throw new BreachError("not-found");
  const nowMs = deps.now();
  const next = applyBreachUpdate(current, data, caller.uid, nowMs);
  const last = next.events[next.events.length - 1];
  await deps.store.put(next, { actorUid: caller.uid, action: `breach.${last.action}`, target: `${BREACH_REGISTER}/${id}`, ip });
  return breachView(next, nowMs);
}

export async function listIncidents(deps: BreachDeps) {
  const nowMs = deps.now();
  const items = (await deps.store.list(100)).map((r) => breachView(r, nowMs));
  return { incidents: items, open: items.filter((r) => r.status !== "closed").length };
}

// --------------------------------------------------------------------------
// Firestore
// --------------------------------------------------------------------------

function toDoc(r: BreachRecord): DocumentData {
  const ts = (ms: number | null) => (ms === null ? null : Timestamp.fromMillis(ms));
  return {
    ...r,
    awareAt: ts(r.awareAtMs),
    pdpcDueAt: ts(r.pdpcDueAtMs),
    pdpcNotifiedAt: ts(r.pdpcNotifiedAtMs),
    subjectsNotifiedAt: ts(r.subjectsNotifiedAtMs),
  };
}

function fromDoc(d: DocumentData): BreachRecord {
  // The numeric *Ms fields are stored next to the timestamps (the timestamps are for console queries).
  const { awareAt: _a, pdpcDueAt: _p, pdpcNotifiedAt: _n, subjectsNotifiedAt: _s, ...rest } = d;
  return rest as BreachRecord;
}

export class FirestoreBreachStore implements BreachStore {
  constructor(private readonly db: Firestore) {}

  newId(): string {
    return this.db.collection(BREACH_REGISTER).doc().id;
  }

  async get(id: string): Promise<BreachRecord | null> {
    const snap = await this.db.collection(BREACH_REGISTER).doc(id).get();
    return snap.exists ? fromDoc(snap.data() ?? {}) : null;
  }

  async put(record: BreachRecord, audit: AuditEntry): Promise<void> {
    // One batch: the register entry and its audit line, or neither.
    const batch = this.db.batch();
    batch.set(this.db.collection(BREACH_REGISTER).doc(record.id), toDoc(record));
    batch.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await batch.commit();
  }

  async list(limit: number): Promise<BreachRecord[]> {
    const snap = await this.db.collection(BREACH_REGISTER).orderBy("awareAtMs", "desc").limit(limit).get();
    return snap.docs.map((d) => fromDoc(d.data()));
  }
}

function deps(): BreachDeps {
  return { store: new FirestoreBreachStore(adminDb()), now: () => Date.now() };
}

function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  return runCallable(name, body, {
    map: [reasonErrorMapper(BreachError, BREACH_ERROR_CODES), reasonErrorMapper(AdminError, ADMIN_ERROR_CODES, "details")],
  });
}

const opts = { enforceAppCheck: ENFORCE_APP_CHECK };

/** { awareAtMs, occurredAtMs?, kind, categories, source, approxRecords, approxPeople, nationalSecurity, summary, effects?, measures? } -> the incident with its deadlines. */
export const adminReportIncident = onCall(opts, (r) =>
  run("adminReportIncident", async () => reportIncident(deps(), await requireAdminCaller(r), r.data, ipOf(r))),
);

/** { id, action: contained | pdpcNotified | subjectsNotified | note | closed, atMs?, reference?, text? } -> the incident. */
export const adminUpdateIncident = onCall(opts, (r) =>
  run("adminUpdateIncident", async () => updateIncident(deps(), await requireAdminCaller(r), r.data, ipOf(r))),
);

/** {} -> { incidents, open }: newest first, each with both deadlines and their state. */
export const adminListIncidents = onCall(opts, (r) =>
  run("adminListIncidents", async () => {
    await requireAdminCaller(r);
    return listIncidents(deps());
  }),
);
