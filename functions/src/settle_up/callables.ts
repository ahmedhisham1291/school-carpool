import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { FirestoreListsStore } from "../admin_panel/store";
import {
  ENFORCE_APP_CHECK,
  MIN_INSTANCES,
  SETTLE_UP_ADDRESS_CHANGES_PER_DAY,
  SETTLE_UP_ADDRESS_VIEWS_PER_HOUR,
  SETTLE_UP_CHANGES_PER_DAY,
  SETTLE_UP_REPORT_AFTER,
  SETTLE_UP_REQUESTS_PER_DAY,
} from "../config";
import { featureGatedCall, featureOffError, features, featureSessionCall, requireFeature } from "../features/gate";
import { FeatureOffError } from "../features/model";
import { accessReason } from "../privacy/photos";
import { reportError } from "../sentry";
import {
  adminListSettleUps as adminListFlow,
  contacts as contactsFlow,
  createSettleUp as createFlow,
  getAddressFor,
  getProfile,
  removeAddress,
  reportSettleUp as reportFlow,
  saveAddress,
  settleUpAction as actionFlow,
  type Caller,
  type SettleDeps,
} from "./flow";
import { DEFAULT_SETTLE_LIMITS, SETTLE_ERROR_CODES, SettleError, type SettleLimits } from "./model";
import { FirestoreSettleStore } from "./store";

/**
 * Settle up by InstaPay (F45): the pilot's payment feature. The app never
 * moves, holds or sees money and never asks for bank or card details: these
 * functions only record payment requests between two parents of a carpool
 * and show the payer the payee's InstaPay address. No fee, no commission.
 *
 * Every write of a record goes through here (App Check, rate limits, the
 * "settleUp" feature switch first). Logs carry the function name and the
 * error message only: never an InstaPay address, an amount, a name or a
 * note (the request data is never logged or sent to Sentry).
 */

const positive = (v: number, fallback: number): number => (Number.isInteger(v) && v >= 1 ? v : fallback);

function limits(): SettleLimits {
  return {
    requestsPerDay: positive(SETTLE_UP_REQUESTS_PER_DAY.value(), DEFAULT_SETTLE_LIMITS.requestsPerDay),
    changesPerDay: positive(SETTLE_UP_CHANGES_PER_DAY.value(), DEFAULT_SETTLE_LIMITS.changesPerDay),
    addressChangesPerDay: positive(SETTLE_UP_ADDRESS_CHANGES_PER_DAY.value(), DEFAULT_SETTLE_LIMITS.addressChangesPerDay),
    addressViewsPerHour: positive(SETTLE_UP_ADDRESS_VIEWS_PER_HOUR.value(), DEFAULT_SETTLE_LIMITS.addressViewsPerHour),
    reportAfter: positive(SETTLE_UP_REPORT_AFTER.value(), DEFAULT_SETTLE_LIMITS.reportAfter),
  };
}

export function settleDeps(): SettleDeps {
  const db = adminDb();
  const lists = new FirestoreListsStore(db);
  return { store: new FirestoreSettleStore(db, (entry) => lists.audit(entry)), now: () => Date.now(), limits: limits(), features };
}

function caller(request: CallableRequest): Caller {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return { uid, verifiedClaim: request.auth?.token?.verified === true };
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof FeatureOffError) throw featureOffError(error.feature);
    if (error instanceof SettleError) {
      throw new HttpsError(SETTLE_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason, ...error.details });
    }
    // Never the request data: it holds an address, an amount or a note.
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("unavailable", "settle-up-unavailable", { reason: "settle-up-unavailable" });
  }
}

const opts = { enforceAppCheck: ENFORCE_APP_CHECK, minInstances: MIN_INSTANCES };

/** {} -> { address, maxAmount, reportAfter }: the caller's own InstaPay address and the limits the form shows. */
export const getSettleUpProfile = featureGatedCall("settleUp", opts, (r) => run("getSettleUpProfile", () => getProfile(settleDeps(), caller(r))));

/** { address } -> { address }: saves the caller's InstaPay address (name@instapay). */
export const saveInstaPayAddress = featureGatedCall("settleUp", opts, (r) => run("saveInstaPayAddress", () => saveAddress(settleDeps(), caller(r), r.data)));

/** {} -> { removed } */
export const removeInstaPayAddress = featureGatedCall("settleUp", opts, (r) => run("removeInstaPayAddress", () => removeAddress(settleDeps(), caller(r))));

/** { carpoolId? } -> { contacts }: parents of my carpools. */
export const settleUpContacts = featureGatedCall("settleUp", opts, (r) => run("settleUpContacts", () => contactsFlow(settleDeps(), caller(r), r.data)));

/** { requestId, kind: request | paid, otherUid, carpoolId, amount, reason, note? } -> { record, created } */
export const createSettleUp = featureGatedCall("settleUp", opts, (r) => run("createSettleUp", () => createFlow(settleDeps(), caller(r), r.data)));

/**
 * { id, action: paid | received | notReceived | cancel | decline } -> { record }
 * Session check only (not the new-phone check): finishing a record that
 * exists never opens anything new.
 */
export const settleUpAction = featureSessionCall("settleUp", opts, (r) => run("settleUpAction", () => actionFlow(settleDeps(), caller(r), r.data)));

/** { id } -> { address }: the payee's address, for the payer of an open record only. */
export const getSettleUpAddress = featureGatedCall("settleUp", opts, (r) => run("getSettleUpAddress", () => getAddressFor(settleDeps(), caller(r), r.data)));

/** { id, note? } -> { reported }: to the admins' reports queue, after the record bounced enough times. */
export const reportSettleUp = featureSessionCall("settleUp", opts, (r) => run("reportSettleUp", () => reportFlow(settleDeps(), caller(r), r.data)));

/** { uid, reason } -> { records }: read-only, logged first with the reason. Never the address or the note. */
export const adminListSettleUps = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (r) =>
  run("adminListSettleUps", async () => {
    await requireFeature("settleUp");
    const admin = await requireAdminCaller(r);
    const raw = typeof r.data === "object" && r.data !== null ? (r.data as Record<string, unknown>) : {};
    const uid = typeof raw.uid === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(raw.uid) ? raw.uid : null;
    const reason = accessReason(raw.reason);
    if (!uid || !reason) throw new SettleError("invalid-request");
    return adminListFlow(settleDeps(), admin.uid, uid, reason, ipOf(r));
  }),
);
