import { AdminError, docId, record } from "../admin_panel/errors";
import type { AdminCaller } from "../admin_panel/guard";
import type { AuditEntry } from "../admin_panel/types";
import { parseCid, type ReportRecord } from "./model";
import type { ChatServer } from "./server";
import type { ChatStore, DrivingPauser } from "./store";
import type { SyncDeps } from "./sync";

/**
 * Admin panel: chat reports (Prompt 9, F13 and F14).
 *
 * Admins see the reported message with a little context only (what the
 * report kept: a few messages around it, first names and parent IDs, text
 * cut short, never photos). They never browse a private chat (spec
 * section 5): there is no function that reads a channel's history. They
 * can remove the reported message, remove the reported parent from that
 * chat, close the report, and lift a driving pause. Every action is in the
 * audit log (no names, no text).
 */

export interface ChatAdminDeps extends SyncDeps {
  store: ChatStore;
  server: ChatServer;
  pauser: DrivingPauser;
  audit: (entry: AuditEntry) => Promise<void>;
}

export const REPORT_OUTCOMES = ["no-action", "warned", "message-removed", "member-removed", "suspended"] as const;

export interface ReportView {
  id: string;
  targetType: string;
  reason: string;
  urgent: boolean;
  status: string;
  kind: string;
  note: string;
  subjectUid: string | null;
  reporterUid: string;
  pausedDriving: boolean;
  outcome: string | null;
  createdAtMs: number;
  handledAtMs: number | null;
  context: Array<{ id: string; authorName: string; authorParentId: string; text: string; attachment: string | null; createdAtMs: number; reported: boolean }>;
}

function toView(r: ReportRecord): ReportView {
  return {
    id: r.id,
    targetType: r.targetType,
    reason: r.reason,
    urgent: r.urgent,
    status: r.status,
    kind: r.kind,
    note: r.note,
    subjectUid: r.subjectUid,
    reporterUid: r.reporterUid,
    pausedDriving: r.pausedDriving,
    outcome: r.outcome,
    createdAtMs: r.createdAtMs,
    handledAtMs: r.handledAtMs,
    context: r.context.map((m) => ({
      id: m.id,
      authorName: m.authorName,
      authorParentId: m.authorParentId,
      text: m.text,
      attachment: m.attachment,
      createdAtMs: m.createdAtMs,
      reported: m.reported,
    })),
  };
}

async function loadReport(deps: ChatAdminDeps, data: unknown): Promise<ReportRecord> {
  const raw = record(data);
  if (!raw) throw new AdminError("invalid-request");
  const report = await deps.store.report(docId(raw.reportId));
  if (!report) throw new AdminError("not-found");
  return report;
}

/** { reportId } -> the report with its context. Opening it is logged. */
export async function getReport(deps: ChatAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<ReportView> {
  const report = await loadReport(deps, data);
  await deps.audit({ actorUid: caller.uid, action: "report.view", target: `reports/${report.id}`, ip });
  return toView(report);
}

async function close(deps: ChatAdminDeps, caller: AdminCaller, report: ReportRecord, outcome: string): Promise<ReportView> {
  const next: ReportRecord = { ...report, status: "handled", outcome, handledBy: caller.uid, handledAtMs: deps.now() };
  await deps.store.putReport(next);
  return toView(next);
}

/** { reportId } -> the report, closed. Hard-deletes the reported message on Stream. */
export async function removeReportedMessage(deps: ChatAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<ReportView> {
  const report = await loadReport(deps, data);
  if (report.targetType !== "message") throw new AdminError("invalid-state");
  await deps.server.deleteMessage(report.targetId);
  await deps.audit({ actorUid: caller.uid, action: "chat.removeMessage", target: `reports/${report.id}`, details: { kind: report.kind }, ip });
  return close(deps, caller, report, "message-removed");
}

/**
 * { reportId } -> the report, closed. Removes the reported parent from that
 * chat and keeps them out (the automatic sync never adds them back).
 */
export async function removeReportedMember(deps: ChatAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<ReportView> {
  const report = await loadReport(deps, data);
  const uid = report.subjectUid;
  const ref = parseCid(report.cid);
  if (!uid || !ref) throw new AdminError("invalid-state");
  // One transaction: out of the members AND on the excluded list, so a sync
  // running in between can never add them back.
  const saved = await deps.store.updateChannel(ref.cid, (c) =>
    c ? { ...c, members: c.members.filter((u) => u !== uid), excluded: c.excluded.includes(uid) ? c.excluded : [...c.excluded, uid], updatedAtMs: deps.now() } : null,
  );
  if (saved) await deps.server.removeMembers(ref.type, ref.id, [uid]);
  await deps.audit({ actorUid: caller.uid, action: "chat.removeMember", target: `reports/${report.id}`, details: { kind: report.kind }, ip });
  return close(deps, caller, report, "member-removed");
}

/** { reportId, outcome } -> the report, closed with that outcome. */
export async function resolveReport(deps: ChatAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<ReportView> {
  const report = await loadReport(deps, data);
  const outcome = (record(data) ?? {}).outcome;
  if (typeof outcome !== "string" || !(REPORT_OUTCOMES as readonly string[]).includes(outcome)) throw new AdminError("invalid-request");
  await deps.audit({ actorUid: caller.uid, action: "report.resolve", target: `reports/${report.id}`, reasonCode: outcome, ip });
  return close(deps, caller, report, outcome);
}

/** { reportId } -> the report. The reported driver may drive again (after review). */
export async function liftDrivingPause(deps: ChatAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<ReportView> {
  const report = await loadReport(deps, data);
  if (!report.subjectUid || !report.pausedDriving) throw new AdminError("invalid-state");
  await deps.pauser.lift(report.subjectUid);
  const next: ReportRecord = { ...report, pausedDriving: false };
  await deps.store.putReport(next);
  await deps.audit({ actorUid: caller.uid, action: "driving.resume", target: `users/${report.subjectUid}`, ip });
  return toView(next);
}
