import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onCall } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { ADMIN_ERROR_CODES, AdminError } from "../admin_panel/errors";
import { AUDIT_LOG, auditDoc } from "../admin_panel/store";
import { ENFORCE_APP_CHECK } from "../config";
import { getFeatures, setFeature, type FeatureAdminDeps } from "./admin";
import { clearFeatureCache } from "./gate";
import { FEATURES_DOC } from "./model";
import { reasonErrorMapper, runCallable } from "../common/callable";

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

function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  return runCallable(name, body, { map: [reasonErrorMapper(AdminError, ADMIN_ERROR_CODES)] });
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
    const caller = await requireAdminCaller(request, { superAdmin: true });
    return setFeature(deps(), caller, request.data, ipOf(request));
  }),
);
