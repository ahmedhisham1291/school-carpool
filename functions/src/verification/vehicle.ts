/**
 * The car a parent may drive with right now (Prompt 11: F17, spec section 3
 * "Re-verify when the car changes"), read from vehicles/{uid}.
 *
 * A parent who sends new driver details for THE SAME car (same plate, for
 * example after renewing a licence) keeps driving with the car as it was
 * approved until the reviewer decides: verification/store.ts keeps that
 * approval in `approved` while the new details wait. A NEW car (another
 * plate) has no such copy: no driving days until it is checked (seats and
 * licences included). Pure: no Firestore here, unit-tested.
 */

export interface UsableVehicle {
  /** "approved" when the parent may drive with it (also while a renewal of the same car waits). */
  status: string;
  seats: number;
  licenseExpiry: string;
  carLicenseExpiry: string;
  plate: string;
  model: string;
  color: string;
}

const text = (v: unknown): string => (typeof v === "string" ? v : "");
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

function fields(d: Record<string, unknown>, status: string): UsableVehicle {
  return {
    status,
    seats: num(d.seats),
    licenseExpiry: text(d.licenseExpiry),
    carLicenseExpiry: text(d.carLicenseExpiry),
    plate: text(d.plate),
    model: text(d.model),
    color: text(d.color),
  };
}

/** The usable car of a vehicles/{uid} document (null when there is none). */
export function usableVehicle(d: Record<string, unknown> | null | undefined): UsableVehicle | null {
  if (!d) return null;
  const status = text(d.status);
  if (status === "approved") return fields(d, status);
  const kept = d.approved;
  if (kept !== null && typeof kept === "object") return fields(kept as Record<string, unknown>, "approved");
  return fields(d, status);
}

/** Plates compare without spaces, dashes or letter case. */
export function samePlate(a: string, b: string): boolean {
  const norm = (p: string) => p.replace(/[\s\-_.]/g, "").toUpperCase();
  return norm(a).length > 0 && norm(a) === norm(b);
}

/**
 * What vehicles/{uid}.approved should hold when the parent sends new
 * driver details: the current approval when the car is the same (same
 * plate) and was usable, else null (a new car is checked first).
 */
export function keptApproval(existing: Record<string, unknown> | null | undefined, newPlate: string): Omit<UsableVehicle, "status"> | null {
  const current = usableVehicle(existing);
  if (!current || current.status !== "approved" || !samePlate(current.plate, newPlate)) return null;
  return {
    seats: current.seats,
    licenseExpiry: current.licenseExpiry,
    carLicenseExpiry: current.carLicenseExpiry,
    plate: current.plate,
    model: current.model,
    color: current.color,
  };
}
