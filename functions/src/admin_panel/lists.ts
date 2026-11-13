import { AdminError, docId, record } from "./errors";
import type { AdminCaller } from "./guard";
import type { AuditItem, ListsStore, ReportItem } from "./types";

/**
 * Reports queue (the list only; handling comes with chat, Prompt 9) and
 * the audit log. The audit log is written only by Cloud Functions and is
 * never edited or deleted (firestore.rules); admins read it here.
 */

const REPORT_STATUSES = ["open", "handled"] as const;

export async function listReports(store: ListsStore, data: unknown): Promise<{ reports: ReportItem[] }> {
  const status = record(data)?.status ?? "open";
  if (!(REPORT_STATUSES as readonly unknown[]).includes(status)) throw new AdminError("invalid-request");
  return { reports: await store.listReports(status as string, 100) };
}

export interface AuditView extends Omit<AuditItem, "ip"> {
  actorName: string | null;
  /** Only super admins see IP addresses. */
  ip: string | null;
}

export async function listAuditLog(
  store: ListsStore,
  caller: AdminCaller,
  data: unknown,
  ip: string | null = null,
): Promise<{ entries: AuditView[]; nextAfterId: string | null }> {
  const raw = record(data) ?? {};
  const afterId = raw.afterId === undefined || raw.afterId === null ? null : docId(raw.afterId);
  // Lightweight: one entry per opening of the log, not per page.
  if (afterId === null) await store.audit({ actorUid: caller.uid, action: "audit.view", target: "auditLog", ip });
  const limit = 50;
  const items = await store.listAudit(afterId, limit);
  const names = await store.adminNames([...new Set(items.map((item) => item.actorUid))]);
  const entries = items.map((item) => ({
    ...item,
    actorName: names.get(item.actorUid) ?? null,
    ip: caller.role === "superAdmin" ? item.ip : null,
  }));
  return { entries, nextAfterId: items.length === limit ? items[items.length - 1].id : null };
}
