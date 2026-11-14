/**
 * Makes the admin thumbnail of every kept photo that has none, or whose
 * thumbnail was made from an older version of the photo (Prompt 12 review:
 * stale thumbnails). Safe to run again: up-to-date thumbnails are skipped.
 * Prints counts only (never paths, names or uids).
 *
 *   GCLOUD_PROJECT=<project> npm --prefix functions run thumbs:backfill
 *
 * Run once after deploying Prompt 12, and after a restore from backup.
 */
import { initializeApp } from "firebase-admin/app";
import { getStorage } from "firebase-admin/storage";
import { ensureThumb, THUMBED_PREFIXES } from "../src/privacy/thumbs";

async function main(): Promise<void> {
  const projectId = process.env.GCLOUD_PROJECT ?? "";
  if (!projectId) {
    console.error("thumbs:backfill: GCLOUD_PROJECT is not set");
    process.exit(1);
  }
  initializeApp({ projectId });
  const bucket = getStorage().bucket();
  const counts = { made: 0, current: 0, skipped: 0, failed: 0 };
  for (const prefix of THUMBED_PREFIXES) {
    let pageToken: string | undefined;
    do {
      const [files, next] = await bucket.getFiles({ prefix, maxResults: 500, pageToken, autoPaginate: false });
      for (const f of files) {
        try {
          counts[await ensureThumb(bucket, f.name, f.metadata.generation === undefined ? null : String(f.metadata.generation))] += 1;
        } catch {
          counts.failed += 1;
        }
      }
      pageToken = (next as { pageToken?: string } | null | undefined)?.pageToken;
    } while (pageToken);
  }
  console.log("thumbs:backfill", counts);
  if (counts.failed > 0) process.exit(2);
}

void main();
