/**
 * Client IP for the per-IP limit on sign-in codes.
 *
 * Cloud Run (which runs 2nd gen functions) appends the address it sees to
 * X-Forwarded-For, so the trustworthy entry is counted from the END: a
 * caller can only add entries in front of it. `hopFromEnd` = 1 takes the
 * last entry (direct Cloud Run, our setup); 2 takes the one before it (for
 * a Google load balancer in front, which appends its own address). It is a
 * param (CLIENT_IP_HOP) so it can be corrected without a code change.
 *
 * To confirm on a deployed project: requestCode logs `ipKeyPrefix` (first
 * characters of the keyed hash, not the IP) outside prod. Calls from two
 * different networks must show different prefixes (SETUP.md 11.7).
 */
export function clientIp(
  headers: Record<string, string | string[] | undefined>,
  fallback?: string,
  hopFromEnd = 1,
): string {
  const raw = headers["x-forwarded-for"];
  const joined = Array.isArray(raw) ? raw.join(",") : (raw ?? "");
  const parts = joined
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
  const hop = Math.max(1, Math.floor(hopFromEnd));
  if (parts.length >= hop) return parts[parts.length - hop];
  return fallback ?? "unknown";
}
