import { FieldValue, type Firestore } from "firebase-admin/firestore";
import { USERS } from "./accounts";

/**
 * Consent records (spec section 9, "Consent record"; Law 151 of 2020).
 * One append-only record per accepted document, in users/{uid}/consents.
 * The versions must match lib/features/auth/legal_documents.dart; a newer
 * server version makes old app builds ask the parent to update.
 *
 * What the documents cover is confirmed by the lawyer (docs/DECISIONS.md,
 * 14 Nov 2026); a change to the final wording raises the version.
 */
export const CONSENT_VERSIONS = {
  // 16 Nov 2026 (legal review): free volunteer turns, no payments, Arabic
  // text prevails, liability wording within Egyptian civil law.
  terms: "2026-11-16",
  // 16 Nov 2026 (legal review): answer within 6 working days, data
  // protection contact, transfer abroad section, breach notice, no
  // financial data, sign-in history 180 days.
  // Also (owner, App Review 5.1.1): photos, messages, address and routes
  // are deleted with the account; usage statistics only with the parent's
  // yes. Deploy functions and app together.
  privacy: "2026-11-16",
  // App Review audit (guideline 1.2): no tolerance for objectionable content.
  conduct: "2026-11-16",
  whatsapp: "2026-11-13",
  /**
   * Separate, explicit consent to store and process data outside Egypt
   * (Google Cloud in Belgium and the processors listed in the privacy
   * policy). Law 151 of 2020, Arts. 14 to 16: a transfer abroad needs a PDPC
   * licence or permit; the data subject's explicit consent is one of the
   * Art. 15 exceptions. Safe side: ask for it on its own line, record it,
   * AND apply for the licence (docs/legal/owner-actions.md).
   */
  transferAbroad: "2026-11-16",
} as const;

export type ConsentType = keyof typeof CONSENT_VERSIONS;

export const REQUIRED_CONSENTS: readonly ConsentType[] = ["terms", "privacy", "conduct", "transferAbroad"];

export type ConsentErrorReason = "invalid-request" | "missing-consent" | "outdated-terms";

export class ConsentError extends Error {
  constructor(readonly reason: ConsentErrorReason) {
    super(reason);
    this.name = "ConsentError";
  }
}

export interface ConsentRequest {
  accepted: ConsentType[];
  whatsapp: boolean;
}

/** Validates { documents: { terms: version, ... }, whatsapp: boolean }. */
export function parseConsentRequest(data: unknown): ConsentRequest {
  if (typeof data !== "object" || data === null) throw new ConsentError("invalid-request");
  const { documents, whatsapp } = data as { documents?: unknown; whatsapp?: unknown };
  if (typeof documents !== "object" || documents === null || typeof whatsapp !== "boolean") {
    throw new ConsentError("invalid-request");
  }
  const versions = documents as Record<string, unknown>;
  for (const type of REQUIRED_CONSENTS) {
    if (versions[type] === undefined) throw new ConsentError("missing-consent");
    if (versions[type] !== CONSENT_VERSIONS[type]) throw new ConsentError("outdated-terms");
  }
  return {
    accepted: whatsapp ? [...REQUIRED_CONSENTS, "whatsapp"] : [...REQUIRED_CONSENTS],
    whatsapp,
  };
}

export async function recordConsents(db: Firestore, uid: string, request: ConsentRequest): Promise<void> {
  const userRef = db.collection(USERS).doc(uid);
  const batch = db.batch();
  for (const type of request.accepted) {
    batch.create(userRef.collection("consents").doc(), {
      type,
      version: CONSENT_VERSIONS[type],
      acceptedAt: FieldValue.serverTimestamp(),
      withdrawnAt: null,
      source: "signup",
    });
  }
  batch.update(userRef, {
    termsAcceptedAt: FieldValue.serverTimestamp(),
    termsVersion: CONSENT_VERSIONS.terms,
    whatsappOptIn: request.whatsapp,
    updatedAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();
}
