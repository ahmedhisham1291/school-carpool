import { continueDeletion, type ClosedAccount, type DeletionRunner } from "./account_deletion";
import { AUDIT_LOG_DAYS, CHAT_AFTER_END_DAYS, cutoff, EXPORT_FILE_DAYS, REPORT_CONTEXT_DAYS, SECURITY_ALERT_DAYS, TRIP_STOPS_DAYS } from "./retention";

/**
 * retentionDaily (spec section 7: "a retention schedule enforced by a
 * scheduled job"; Prompt 12: "for every data type, with a report when a
 * deletion fails"). One task per data type that is not deleted at once or
 * by a TTL (retention.ts lists them all). Every task runs even when another
 * fails; the run writes retentionRuns/{date} (counts only) and, when
 * anything failed, reports to Sentry and opens a security alert for the
 * admins. Pure orchestration over [RetentionStore]; unit-tested.
 */

export interface RetentionStore {
  /** Closed accounts with failed steps, or whose purge date passed and are not purged yet. */
  closedAccountsToWork(nowMs: number, limit: number): Promise<ClosedAccount[]>;
  /** Archived routes past their date: deletes the file and its record; returns how many. */
  deleteRouteArchivesDue(nowMs: number, limit: number): Promise<number>;
  /**
   * Marks the chats of carpools that closed as ended (frozen on Stream by
   * [freeze]); Prompt 9 review item 13. Returns how many.
   */
  endClosedCarpoolChats(nowMs: number, limit: number, freeze: (cid: string) => Promise<void>): Promise<number>;
  /** Chats that ended before [before]: IDs ("type:id"). */
  endedChatsBefore(before: number, limit: number): Promise<string[]>;
  deleteChatRecord(cid: string): Promise<void>;
  /** Handled reports older than [before] that still hold a copy of the messages: clears the copy. */
  clearReportContexts(before: number, limit: number): Promise<number>;
  /** Exact stop points of runs that ended before [before]. */
  deleteTripStopsBefore(before: number, limit: number): Promise<number>;
  deleteAuditBefore(before: number, limit: number): Promise<number>;
  deleteExportsBefore(before: number): Promise<number>;
  deleteHandledSecurityAlertsBefore(before: number, limit: number): Promise<number>;
  saveRun(report: RetentionReport): Promise<void>;
  /** A security alert for the admins (deletion failed). */
  raiseFailureAlert(report: RetentionReport): Promise<void>;
}

export interface RetentionDeps {
  store: RetentionStore;
  runner: DeletionRunner;
  /** Hard-deletes a Stream channel (chat ended a year ago). */
  deleteChannel(cid: string): Promise<void>;
  /** Freezes a Stream channel (no new messages; the history stays). */
  freezeChannel(cid: string): Promise<void>;
  now: () => number;
  /** Sentry (scrubbed); never the data itself. */
  reportError(error: unknown): void;
}

export interface TaskResult {
  deleted: number;
  failed: number;
}

export interface RetentionReport {
  date: string;
  startedAtMs: number;
  tasks: Record<string, TaskResult>;
  /** Short codes only, like "account:<uid>:flow:chat" or "routeArchives". */
  failures: string[];
}

const PAGE = 200;

export async function runRetention(deps: RetentionDeps): Promise<RetentionReport> {
  const nowMs = deps.now();
  const report: RetentionReport = { date: new Date(nowMs).toISOString().slice(0, 10), startedAtMs: nowMs, tasks: {}, failures: [] };
  const task = async (name: string, body: () => Promise<TaskResult>): Promise<void> => {
    try {
      report.tasks[name] = await body();
    } catch (error) {
      report.tasks[name] = { deleted: 0, failed: 1 };
      report.failures.push(name);
      deps.reportError(error);
    }
  };

  // Closed accounts: retry failed steps; purge photos, trips, consents, chat after 1 year.
  await task("closedAccounts", async () => {
    let deleted = 0;
    let failed = 0;
    for (const c of await deps.store.closedAccountsToWork(nowMs, PAGE)) {
      const r = await continueDeletion(deps.runner, c, nowMs, (step, error) => {
        report.failures.push(`account:${c.uid}:${step}`);
        deps.reportError(error);
      });
      if (r.purged) deleted += 1;
      if (r.failed.length > 0) failed += 1;
    }
    return { deleted, failed };
  });

  await task("routeArchives", async () => ({ deleted: await deps.store.deleteRouteArchivesDue(nowMs, PAGE), failed: 0 }));

  await task("closedCarpoolChats", async () => ({ deleted: await deps.store.endClosedCarpoolChats(nowMs, PAGE, (cid) => deps.freezeChannel(cid)), failed: 0 }));

  // Chat: life of the chat + 1 year (owner decision; was 180 days).
  await task("chats", async () => {
    let deleted = 0;
    let failed = 0;
    for (const cid of await deps.store.endedChatsBefore(cutoff(nowMs, CHAT_AFTER_END_DAYS), PAGE)) {
      try {
        await deps.deleteChannel(cid);
        await deps.store.deleteChatRecord(cid);
        deleted += 1;
      } catch (error) {
        failed += 1;
        report.failures.push(`chat:${cid}`);
        deps.reportError(error);
      }
    }
    return { deleted, failed };
  });

  await task("reportContexts", async () => ({ deleted: await deps.store.clearReportContexts(cutoff(nowMs, REPORT_CONTEXT_DAYS), PAGE), failed: 0 }));
  await task("tripStops", async () => ({ deleted: await deps.store.deleteTripStopsBefore(cutoff(nowMs, TRIP_STOPS_DAYS), PAGE), failed: 0 }));
  await task("auditLog", async () => ({ deleted: await deps.store.deleteAuditBefore(cutoff(nowMs, AUDIT_LOG_DAYS), PAGE), failed: 0 }));
  await task("exports", async () => ({ deleted: await deps.store.deleteExportsBefore(cutoff(nowMs, EXPORT_FILE_DAYS)), failed: 0 }));
  await task("securityAlerts", async () => ({ deleted: await deps.store.deleteHandledSecurityAlertsBefore(cutoff(nowMs, SECURITY_ALERT_DAYS), PAGE), failed: 0 }));

  await deps.store.saveRun(report);
  if (report.failures.length > 0) {
    deps.reportError(new Error(`retention: ${report.failures.length} failure(s): ${report.failures.slice(0, 10).join(", ")}`));
    await deps.store.raiseFailureAlert(report);
  }
  return report;
}
