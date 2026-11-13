import { randomBytes as nodeRandomBytes } from "node:crypto";

/**
 * Public parent ID (F44, CLAUDE.md "PARENT ID"): 8 characters from letters
 * and digits that cannot be confused. No 0, O, 1 or I. 8 digits (2-9) plus
 * 24 letters = 32 symbols, so one random byte masked to 5 bits picks a symbol
 * with no bias (256 is a multiple of 32).
 *
 * The ID is random: never derived from the phone or the national ID number.
 * Only a Cloud Function creates it (accounts.ts), and uniqueness is enforced
 * by a reserved-ID document created in the same transaction as the user.
 */
export const PARENT_ID_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
export const PARENT_ID_LENGTH = 8;
export const PARENT_ID_PATTERN = /^[2-9A-HJ-NP-Z]{8}$/;

if (PARENT_ID_ALPHABET.length !== 32) {
  throw new Error("PARENT_ID_ALPHABET must have exactly 32 symbols");
}

/** Source of random bytes; tests inject a fixed sequence. */
export type RandomBytes = (size: number) => Buffer;

export function generateParentId(random: RandomBytes = nodeRandomBytes): string {
  const bytes = random(PARENT_ID_LENGTH);
  let id = "";
  for (let i = 0; i < PARENT_ID_LENGTH; i++) {
    id += PARENT_ID_ALPHABET[bytes[i] & 31];
  }
  return id;
}

export function isParentId(value: unknown): value is string {
  return typeof value === "string" && PARENT_ID_PATTERN.test(value);
}

/**
 * Picks an ID that `isTaken` says is free. With 32^8 (about 1.1 trillion)
 * possible IDs a second try is already rare; `maxTries` only guards against
 * a broken random source.
 */
export async function pickFreeParentId(
  isTaken: (id: string) => Promise<boolean>,
  random: RandomBytes = nodeRandomBytes,
  maxTries = 8,
): Promise<string> {
  for (let i = 0; i < maxTries; i++) {
    const id = generateParentId(random);
    if (!(await isTaken(id))) return id;
  }
  throw new Error(`No free parent ID after ${maxTries} tries`);
}
