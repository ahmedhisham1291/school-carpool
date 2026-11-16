import { FieldValue, Timestamp } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { ADMIN_ERROR_CODES, AdminError } from "../admin_panel/errors";
import { AUDIT_LOG, auditDoc } from "../admin_panel/store";
import { ENFORCE_APP_CHECK } from "../config";
import { reportError } from "../sentry";
import { cachedTermMatcher, CHAT_MODERATION_DOC } from "./moderation";
import { getChatModeration, setChatModeration, type ModerationAdminDeps } from "./moderation_admin";

/**
 * The chat word filter's setting (config/chatModeration): read by the
 * message trigger through [chatTermMatcher], edited only here (admin
 * panel; firestore.rules close config/ to the app).
 */
export const chatTermMatcher = cachedTermMatcher(
  async () => (await adminDb().doc(CHAT_MODERATION_DOC).get()).data() ?? null,
  () => Date.now(),
);

function deps(): ModerationAdminDeps {
  const db = adminDb();
  return {
    store: {
      read: async () => (await db.doc(CHAT_MODERATION_DOC).get()).data() ?? null,
      write: async (terms, adminUid, nowMs, audit) => {
        const batch = db.batch();
        batch.set(db.doc(CHAT_MODERATION_DOC), {
          termsAr: terms.ar,
          termsEn: terms.en,
          updatedBy: adminUid,
          updatedAt: Timestamp.fromMillis(nowMs),
          serverUpdatedAt: FieldValue.serverTimestamp(),
        });
        batch.create(db.collection(AUDIT_LOG).doc(), auditDoc(audit));
        await batch.commit();
      },
    },
    now: () => Date.now(),
    changed: () => chatTermMatcher.clear(),
  };
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof AdminError) throw new HttpsError(ADMIN_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason });
    // Never the words: our own error text only.
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("internal", "Something went wrong.");
  }
}

const options = { enforceAppCheck: ENFORCE_APP_CHECK };

/** {} -> { termsAr, termsEn, usingDefaults, maxTerms, maxLength } (any admin). */
export const adminGetChatModeration = onCall(options, (request) =>
  run("adminGetChatModeration", async () => {
    await requireAdminCaller(request);
    return getChatModeration(deps());
  }),
);

/** { termsAr, termsEn } or { reset: true } -> the lists. Super admins only; audit log entry (counts only). */
export const adminSetChatModeration = onCall(options, (request) =>
  run("adminSetChatModeration", async () => {
    const caller = await requireAdminCaller(request, { superAdmin: true });
    return setChatModeration(deps(), caller, request.data, ipOf(request));
  }),
);
