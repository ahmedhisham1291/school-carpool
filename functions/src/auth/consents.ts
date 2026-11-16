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
  terms: "2026-11-13",
  // Prompt 12: new retention (photos kept while active + 1 year, route
  // archive, analytics, chat history) needs the new privacy policy.
  privacy: "2026-11-14",
  // App Review audit (guideline 1.2): no tolerance for objectionable content.
  conduct: "2026-11-16",
  whatsapp: "2026-11-13",
} as const;

export type ConsentType = keyof typeof CONSENT_VERSIONS;

export const REQUIRED_CONSENTS: readonly ConsentType[] = ["terms", "privacy", "conduct"];

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
