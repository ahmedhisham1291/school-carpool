import { FieldValue, Timestamp } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { ADMIN_ERROR_CODES, AdminError } from "../admin_panel/errors";
import { AUDIT_LOG, auditDoc } from "../admin_panel/store";
import { ENFORCE_APP_CHECK } from "../config";
import { reportError } from "../sentry";
import { getFeatures, setFeature, type FeatureAdminDeps } from "./admin";
import { clearFeatureCache } from "./gate";
import { FEATURES_DOC } from "./model";

/**
 * Admin panel > Settings: the pilot feature switches (features/model.ts).
 * config/features is written ONLY here (firestore.rules: parents read it,
 * nobody writes it from an app).
 */

function deps(): FeatureAdminDeps {
  const db = adminDb();
  return {
    store: {
      read: async () => (await db.doc(FEATURES_DOC).get()).data() ?? null,
      write: async (feature, on, adminUid, nowMs, audit) => {
        // One batch: the switch and its audit entry, or neither.
        const batch = db.batch();
        batch.set(db.doc(FEATURES_DOC), { [feature]: on, updatedBy: adminUid, updatedAt: Timestamp.fromMillis(nowMs), serverUpdatedAt: FieldValue.serverTimestamp() }, { merge: true });
        batch.create(db.collection(AUDIT_LOG).doc(), auditDoc(audit));
        await batch.commit();
      },
    },
    now: () => Date.now(),
    changed: clearFeatureCache,
  };
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof AdminError) throw new HttpsError(ADMIN_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason });
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("internal", "Something went wrong.");
  }
}

const options = { enforceAppCheck: ENFORCE_APP_CHECK };

/** {} -> { features, defaults, keys } (any admin). */
export const adminGetFeatures = onCall(options, (request) =>
  run("adminGetFeatures", async () => {
    await requireAdminCaller(request);
    return getFeatures(deps());
  }),
);

/** { feature, on } -> { features, defaults, keys }. Super admins only; audit log entry. */
export const adminSetFeature = onCall(options, (request) =>
  run("adminSetFeature", async () => {
    const caller = await requireAdminCaller(request, { superAdmin: true, recentSignIn: true });
    return setFeature(deps(), caller, request.data, ipOf(request));
  }),
);
