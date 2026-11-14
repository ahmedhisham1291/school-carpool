import { DAY_MS, PRIVACY_REQUEST_DAYS } from "./retention";

/**
 * Privacy requests and consents (spec section 7: "a privacy screen where a
 * parent can see, correct, export and delete their data and withdraw each
 * consent; log every request"). Every request, done at once or not, gets a
 * record in privacyRequests/{id} that the parent can read (rules) and that
 * is kept 3 years as proof (TTL on expiresAt).
 */

export const REQUEST_KINDS = ["export", "delete", "correct", "withdraw", "consent", "photoCopy"] as const;
export type RequestKind = (typeof REQUEST_KINDS)[number];

export type RequestStatus = "done" | "open" | "refused" | "failed";

export interface PrivacyRequest {
  id: string;
  uid: string;
  kind: RequestKind;
  /** The consent, field or section concerned (a fixed word, never free text). */
  subject: string | null;
  status: RequestStatus;
  /** Why it was refused or what is left (a fixed reason code). */
  reason: string | null;
  createdAtMs: number;
  doneAtMs: number | null;
  expiresAtMs: number;
}

export function newRequest(id: string, uid: string, kind: RequestKind, subject: string | null, nowMs: number): PrivacyRequest {
  return { id, uid, kind, subject, status: "open", reason: null, createdAtMs: nowMs, doneAtMs: null, expiresAtMs: nowMs + PRIVACY_REQUEST_DAYS * DAY_MS };
}

/**
 * The consents a parent sees and can withdraw (spec section 9 consent
 * types, Prompt 12 additions). What withdrawing does:
 * - whatsapp: no more WhatsApp messages (sign-in codes still come by WhatsApp).
 * - analytics: usage statistics stop on the phone (the app switches
 *   Analytics collection off) and the choice is recorded.
 * - showOnMap: the parent leaves the nearby map.
 * - walletTerms: the wallet closes; only when it is empty and settled.
 * - terms, privacy, conduct, id, face, childData: the app cannot work
 *   without them, so withdrawing them means deleting the account (or, for
 *   childData, removing the children). The answer says so; nothing is
 *   withdrawn half way.
 */
export const CONSENT_KINDS = ["terms", "privacy", "conduct", "whatsapp", "id", "face", "childData", "walletTerms", "analytics", "showOnMap"] as const;
export type ConsentKind = (typeof CONSENT_KINDS)[number];

export type WithdrawEffect = "whatsappOff" | "analyticsOff" | "hiddenFromMap" | "walletClosed" | "needsDeletion" | "needsChildRemoval";

export function withdrawEffect(kind: ConsentKind): WithdrawEffect {
  switch (kind) {
    case "whatsapp":
      return "whatsappOff";
    case "analytics":
      return "analyticsOff";
    case "showOnMap":
      return "hiddenFromMap";
    case "walletTerms":
      return "walletClosed";
    case "childData":
      return "needsChildRemoval";
    default:
      return "needsDeletion";
  }
}

export function consentKind(value: unknown): ConsentKind | null {
  return typeof value === "string" && (CONSENT_KINDS as readonly string[]).includes(value) ? (value as ConsentKind) : null;
}

/** Fields a parent corrects in the app itself, and those an admin must check (ID details). */
export const SELF_CORRECTED = ["email", "language", "children", "home", "vehicle", "emergencyContact", "handover"] as const;
export const ADMIN_CORRECTED = ["name", "nationalId", "birthDate", "other"] as const;
export type CorrectionField = (typeof SELF_CORRECTED)[number] | (typeof ADMIN_CORRECTED)[number];

export function correctionField(value: unknown): CorrectionField | null {
  const all: readonly string[] = [...SELF_CORRECTED, ...ADMIN_CORRECTED];
  return typeof value === "string" && all.includes(value) ? (value as CorrectionField) : null;
}

/** True when an admin must handle the correction (it changes what the ID check proved). */
export function needsAdmin(field: CorrectionField): boolean {
  return (ADMIN_CORRECTED as readonly string[]).includes(field);
}

/** One consent as the privacy screen shows it (latest record per kind). */
export interface ConsentView {
  kind: ConsentKind;
  version: string | null;
  acceptedAtMs: number | null;
  withdrawnAtMs: number | null;
  active: boolean;
}

export interface ConsentRow {
  type: string;
  version: string | null;
  acceptedAtMs: number;
  withdrawnAtMs: number | null;
}

/** The latest record of each kind wins; kinds never given show as not active. */
export function consentViews(rows: readonly ConsentRow[], extra: { showOnMap: boolean; analytics: boolean | null }): ConsentView[] {
  return CONSENT_KINDS.map((kind) => {
    if (kind === "showOnMap") return { kind, version: null, acceptedAtMs: null, withdrawnAtMs: null, active: extra.showOnMap };
    const latest = rows.filter((r) => r.type === kind).sort((a, b) => b.acceptedAtMs - a.acceptedAtMs)[0];
    if (kind === "analytics" && !latest) {
      // Default on (owner decision); off once the parent switches it off.
      return { kind, version: null, acceptedAtMs: null, withdrawnAtMs: null, active: extra.analytics ?? true };
    }
    if (!latest) return { kind, version: null, acceptedAtMs: null, withdrawnAtMs: null, active: false };
    return { kind, version: latest.version, acceptedAtMs: latest.acceptedAtMs, withdrawnAtMs: latest.withdrawnAtMs, active: latest.withdrawnAtMs === null };
  });
}
