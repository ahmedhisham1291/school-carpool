import type { Bucket } from "../verification/store";
import { THUMB_EDGE, THUMB_QUALITY, thumbOwner, thumbPath } from "./photos";

/**
 * Admin thumbnails of kept photos (thumbs/{uid}/{hash}.webp). Each thumb
 * records the generation of the original it was made from, so a replaced
 * original (a new face reference, a new driver photo) gets a new thumb
 * instead of keeping the old face (Prompt 12 review: stale thumbnails).
 */

/** Metadata key on the thumb: the original's generation. */
export const SOURCE_GENERATION = "sourceGeneration";

/** "made", "current" (already up to date) or "skipped" (not a kept photo, or gone). */
export type ThumbOutcome = "made" | "current" | "skipped";

async function generationOf(bucket: Bucket, path: string): Promise<string | null> {
  const [exists] = await bucket.file(path).exists();
  if (!exists) return null;
  const [meta] = await bucket.file(path).getMetadata();
  return meta.generation === undefined || meta.generation === null ? null : String(meta.generation);
}

/** Makes (or remakes) the thumb of [path] when it is missing or older than the original. */
export async function ensureThumb(bucket: Bucket, path: string, generation: string | null): Promise<ThumbOutcome> {
  const target = thumbPath(path);
  if (!target || !thumbOwner(path)) return "skipped";
  const source = generation ?? (await generationOf(bucket, path));
  if (source === null) return "skipped";
  const file = bucket.file(target);
  const [exists] = await file.exists();
  if (exists) {
    const [meta] = await file.getMetadata();
    const made = (meta.metadata as Record<string, unknown> | undefined)?.[SOURCE_GENERATION];
    if (String(made ?? "") === source) return "current";
  }
  const [original] = await bucket.file(path).download();
  const sharp = (await import("sharp")).default;
  const thumb = await sharp(original).rotate().resize({ width: THUMB_EDGE, height: THUMB_EDGE, fit: "inside", withoutEnlargement: true }).webp({ quality: THUMB_QUALITY }).toBuffer();
  await file.save(thumb, { contentType: "image/webp", resumable: false, metadata: { metadata: { [SOURCE_GENERATION]: source } } });
  return "made";
}

/**
 * The original was deleted (a withdrawn case, the purge, a replaced file):
 * the thumb goes too, unless the original exists again (an overwrite sends
 * the delete of the old generation, possibly after the new thumb was made).
 */
export async function dropThumb(bucket: Bucket, path: string): Promise<boolean> {
  const target = thumbPath(path);
  if (!target) return false;
  if ((await generationOf(bucket, path)) !== null) return false;
  await bucket.file(target).delete({ ignoreNotFound: true });
  return true;
}

/** Prefixes of every kept photo (backfill script). */
export const THUMBED_PREFIXES = ["faceRefs/", "driverPhotos/", "selfieArchive/", "verification/"] as const;
