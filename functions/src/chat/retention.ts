import type { ChatServer } from "./server";
import type { ChatStore } from "./store";

/**
 * Chat retention (spec section 7: "chat after the chosen period", enforced
 * by a scheduled job). Every day each channel we created loses its
 * messages older than [retentionDays] (hard delete on Stream). Reports keep
 * their own short copy until handled (spec: a deleted account keeps open
 * reports). Works on Stream's free plan: no paid retention feature needed.
 */

export const MIN_RETENTION_DAYS = 30;
export const MAX_RETENTION_DAYS = 730;
export const DEFAULT_RETENTION_DAYS = 180;

export function retentionDays(value: number): number {
  return Number.isInteger(value) && value >= MIN_RETENTION_DAYS && value <= MAX_RETENTION_DAYS ? value : DEFAULT_RETENTION_DAYS;
}

export interface RetentionDeps {
  store: ChatStore;
  server: ChatServer;
  now: () => number;
}

export async function runChatRetention(deps: RetentionDeps, days: number, pageSize = 200, maxChannels = 5_000): Promise<{ channels: number; failed: number }> {
  const cutoff = deps.now() - retentionDays(days) * 86_400_000;
  let after: string | null = null;
  let channels = 0;
  let failed = 0;
  while (channels + failed < maxChannels) {
    const page = await deps.store.channelsPage(after, pageSize);
    if (page.length === 0) break;
    for (const c of page) {
      const at = c.cid.indexOf(":");
      try {
        await deps.server.truncateBefore(c.cid.slice(0, at), c.cid.slice(at + 1), cutoff);
        channels += 1;
      } catch {
        failed += 1;
      }
    }
    after = page[page.length - 1].cid;
    if (page.length < pageSize) break;
  }
  return { channels, failed };
}
