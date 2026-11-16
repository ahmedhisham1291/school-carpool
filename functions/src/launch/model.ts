/**
 * Launch gate (recommended change R5 in docs/legal/answers.md 1.2; owner
 * decision 16 Nov 2026): production stays CLOSED to new real parents until
 * the three PDPC licences (controller, sensitive data, transfer abroad)
 * are granted. Law 151/2020 Art. 12 and Decree 816/2025 Arts. 16, 26, 36:
 * no processing of sensitive data before the licence; the PDPC's silence
 * is a refusal; there is no transitional rule.
 *
 * One server setting, config/launch.pdpcLicensed (closed to every client:
 * firestore.rules), written only by a super admin with a fresh sign-in
 * through adminSetLaunch (audited). A missing document or field reads as
 * false. Only prod is gated: dev and staging (fake data, testers) are
 * always open. While closed:
 * - a NEW phone number that signs in to prod gets "launch-closed" after its
 *   code is checked (no account is created; the app says "Opening soon");
 * - existing accounts (staff, testers made before) and the App Review demo
 *   phones keep signing in.
 *
 * Pure; unit-tested in test/launch.test.ts.
 */

export const LAUNCH_DOC = "config/launch";

export interface LaunchSettings {
  /** The PDPC granted the controller, sensitive-data and transfer licences. */
  pdpcLicensed: boolean;
  /** Who switched it and when (shown in the admin panel). */
  updatedBy: string | null;
  updatedAtMs: number | null;
}

export function launchFrom(doc: Record<string, unknown> | null | undefined, millis: (v: unknown) => number | null): LaunchSettings {
  return {
    pdpcLicensed: doc?.pdpcLicensed === true,
    updatedBy: typeof doc?.updatedBy === "string" ? doc.updatedBy : null,
    updatedAtMs: doc ? millis(doc.updatedAt) : null,
  };
}

/** New real parents may sign up: always outside prod; in prod only once the licences are granted. */
export function signUpOpen(env: string, settings: Pick<LaunchSettings, "pdpcLicensed">): boolean {
  return env !== "prod" || settings.pdpcLicensed;
}

export type LaunchErrorReason = "invalid-request";

export class LaunchError extends Error {
  constructor(readonly reason: LaunchErrorReason) {
    super(reason);
    this.name = "LaunchError";
  }
}

export const LAUNCH_ERROR_CODES: Readonly<Record<LaunchErrorReason, string>> = { "invalid-request": "invalid-argument" };

/** { pdpcLicensed: boolean, licenceRefs: string } from the admin panel. */
export function parseLaunchChange(data: unknown): { pdpcLicensed: boolean; licenceRefs: string } {
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : null;
  if (!raw || typeof raw.pdpcLicensed !== "boolean") throw new LaunchError("invalid-request");
  const refs = typeof raw.licenceRefs === "string" ? raw.licenceRefs.trim() : "";
  // Opening needs the licence numbers on record (audit); closing does not.
  if (raw.pdpcLicensed && !/^[\p{L}\p{N}][\p{L}\p{N} ,/.()_-]{2,119}$/u.test(refs)) throw new LaunchError("invalid-request");
  return { pdpcLicensed: raw.pdpcLicensed, licenceRefs: refs };
}
