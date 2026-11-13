import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Keyed hash (HMAC-SHA256, hex). The key is the OTP_HMAC_KEY secret, so a
 * leaked database cannot be brute-forced back to codes, phone numbers, device
 * IDs or IP addresses without it.
 */
export function hmacHex(key: string, message: string): string {
  return createHmac("sha256", key).update(message, "utf8").digest("hex");
}

/** Constant-time comparison of two hex digests. */
export function safeEqualHex(a: string, b: string): boolean {
  const left = Buffer.from(a, "hex");
  const right = Buffer.from(b, "hex");
  return left.length > 0 && left.length === right.length && timingSafeEqual(left, right);
}
