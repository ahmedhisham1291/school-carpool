import { createHash } from "node:crypto";

/**
 * Kept photos (owner decision, 14 Nov 2026; CLAUDE.md PRIVACY): the
 * private bucket (KMS key), kept while the account is active, deleted
 * with the account (owner decision 16 Nov 2026), and opened by admins ONLY through a callable that
 * needs a reason and writes the audit log. Small thumbnails for the admin
 * panel are made on the server (thumbs/{uid}/...), so a list never loads
 * full ID images. Pure; unit-tested.
 */

/** Why an admin opens a parent's photos. Fixed codes; free text goes to an optional note, never to logs. */
export const ACCESS_REASONS = ["review", "investigation", "report", "legalRequest", "parentRequest", "appeal"] as const;
export type AccessReason = (typeof ACCESS_REASONS)[number];

export function accessReason(value: unknown): AccessReason | null {
  return typeof value === "string" && (ACCESS_REASONS as readonly string[]).includes(value) ? (value as AccessReason) : null;
}

/** The long edge of an admin thumbnail (px) and its WebP quality. */
export const THUMB_EDGE = 320;
export const THUMB_QUALITY = 70;

/**
 * Paths that get a thumbnail: decided case images, the face reference,
 * the driver photo and the kept selfies. Never pending uploads or the
 * thumbnails themselves.
 */
const THUMBED = [
  /^verification\/([A-Za-z0-9_-]{1,128})\/cases\/[A-Za-z0-9]{1,40}\/[a-z0-9_]{1,40}\.jpg$/,
  /^faceRefs\/([A-Za-z0-9_-]{1,128})\/selfie\.jpg$/,
  /^driverPhotos\/([A-Za-z0-9_-]{1,128})\/photo\.jpg$/,
  /^selfieArchive\/([A-Za-z0-9_-]{1,128})\/[A-Za-z0-9_.-]{1,160}\.jpg$/,
];

/** The owner uid of a photo that gets a thumbnail, or null. */
export function thumbOwner(path: string): string | null {
  for (const re of THUMBED) {
    const m = re.exec(path);
    if (m) return m[1];
  }
  return null;
}

/** thumbs/{uid}/{sha256 of the path, 32 hex}.webp: the original's name is not in the path. */
export function thumbPath(path: string): string | null {
  const uid = thumbOwner(path);
  if (!uid) return null;
  return `thumbs/${uid}/${createHash("sha256").update(path).digest("hex").slice(0, 32)}.webp`;
}

/** Where a live selfie check is kept (owner decision: live selfie checks are kept). */
export function selfieArchivePath(uid: string, name: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(uid) || !/^[A-Za-z0-9_.-]{1,160}\.jpg$/.test(name)) throw new Error("bad selfie archive path");
  return `selfieArchive/${uid}/${name}`;
}
