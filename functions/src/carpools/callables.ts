import { randomBytes } from "node:crypto";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import {
  CARPOOL_CREATES_PER_DAY,
  CARPOOL_INVITE_OPENS_PER_HOUR,
  CARPOOL_INVITES_PER_DAY,
  CARPOOL_JOIN_REQUESTS_PER_DAY,
  CARPOOL_SEARCHES_PER_HOUR,
  CARPOOL_WANTED_LISTS_PER_HOUR,
  CARPOOL_WANTED_SAVES_PER_DAY,
  ENFORCE_APP_CHECK,
  INVITE_LINK_BASE,
  SCHEDULE_CHANGES_PER_DAY,
  SCHEDULE_CONFIRM_BY,
  SCHEDULE_LATE_LEAD_MIN,
  SCHEDULE_PLANS_PER_DAY,
} from "../config";
import { DEFAULT_DEADLINES, type DeadlineSettings } from "../schedule/model";
import { PARENT_ID_ALPHABET } from "../auth/parent_id";
import { reportError } from "../sentry";
import {
  cancelJoinRequest as cancelFlow,
  createCarpool as createFlow,
  createInvite,
  decideJoinRequest as decideFlow,
  deleteWanted,
  leaveCarpool as leaveFlow,
  listWanted,
  openInvite,
  requestToJoin,
  saveWanted,
  searchCarpools as searchFlow,
  setDriverConsent as consentFlow,
  setPickupSharing as pickupFlow,
  type Caller,
  type CarpoolDeps,
} from "./flow";
import { CARPOOL_ERROR_CODES, CarpoolError } from "./model";
import { FirestoreCarpoolStore } from "./store";

/**
 * Carpool callables (Prompt 6). Every membership, ownership and status
 * write happens here. Logs never contain names, children, times or
 * coordinates (CLAUDE.md, PRIVACY): only the error message.
 */

/** 10 characters from the parent ID alphabet (no 0, O, 1 or I): about 10^15 codes. */
export function newInviteCode(): string {
  const bytes = randomBytes(10);
  let code = "";
  for (const b of bytes) code += PARENT_ID_ALPHABET[b % PARENT_ID_ALPHABET.length];
  return code;
}

/** Confirm-by settings from params; a bad value falls back to the default (21:00, 60 minutes). */
export function deadlineSettings(confirmBy: string, lateLeadMin: number): DeadlineSettings {
  return {
    confirmBy: /^([01]\d|2[0-3]):[0-5]\d$/.test(confirmBy) ? confirmBy : DEFAULT_DEADLINES.confirmBy,
    lateLeadMin: Number.isInteger(lateLeadMin) && lateLeadMin >= 15 && lateLeadMin <= 240 ? lateLeadMin : DEFAULT_DEADLINES.lateLeadMin,
  };
}

export function deps(): CarpoolDeps {
  return {
    store: new FirestoreCarpoolStore(adminDb()),
    now: () => Date.now(),
    limits: {
      createsPerDay: CARPOOL_CREATES_PER_DAY.value(),
      searchesPerHour: CARPOOL_SEARCHES_PER_HOUR.value(),
      joinRequestsPerDay: CARPOOL_JOIN_REQUESTS_PER_DAY.value(),
      invitesPerDay: CARPOOL_INVITES_PER_DAY.value(),
      inviteOpensPerHour: CARPOOL_INVITE_OPENS_PER_HOUR.value(),
      wantedSavesPerDay: CARPOOL_WANTED_SAVES_PER_DAY.value(),
      wantedListsPerHour: CARPOOL_WANTED_LISTS_PER_HOUR.value(),
      plansPerDay: SCHEDULE_PLANS_PER_DAY.value(),
      scheduleChangesPerDay: SCHEDULE_CHANGES_PER_DAY.value(),
    },
    newCode: newInviteCode,
    linkBase: INVITE_LINK_BASE.value(),
    deadlines: deadlineSettings(SCHEDULE_CONFIRM_BY.value(), SCHEDULE_LATE_LEAD_MIN.value()),
  };
}

export function caller(request: CallableRequest): Caller {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return { uid, verifiedClaim: request.auth?.token?.verified === true };
}

export async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof CarpoolError) {
      throw new HttpsError(CARPOOL_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, {
        reason: error.reason,
        retryAfterSeconds: Math.ceil(error.retryAfterMs / 1000),
      });
    }
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("internal", "Something went wrong.");
  }
}

export const opts = { enforceAppCheck: ENFORCE_APP_CHECK };

/** F5, F25, F36, F39: { kind, schoolId|activity, areaId?, morning?, afternoon?, days, driveDays, seats, childIds, rules, contribution? } -> { carpoolId } */
export const createCarpool = onCall(opts, (r) => run("createCarpool", () => createFlow(deps(), caller(r), r.data)));

/** F5, F6: { kind, schoolId?, areaId?, morning?, afternoon?, radiusKm?, parentUid? } -> { carpools } */
export const searchCarpools = onCall(opts, (r) => run("searchCarpools", () => searchFlow(deps(), caller(r), r.data)));

/** F6: { carpoolId, childIds, acceptRules, acceptContribution } -> { status } */
export const requestToJoinCarpool = onCall(opts, (r) => run("requestToJoinCarpool", () => requestToJoin(deps(), caller(r), r.data)));

/** F6: { carpoolId } -> { status } */
export const cancelJoinRequest = onCall(opts, (r) => run("cancelJoinRequest", () => cancelFlow(deps(), caller(r), r.data)));

/** F6: { carpoolId, uid, approve } -> { status } (carpool admin only) */
export const decideJoinRequest = onCall(opts, (r) => run("decideJoinRequest", () => decideFlow(deps(), caller(r), r.data)));

/** { carpoolId } -> { status } */
export const leaveCarpool = onCall(opts, (r) => run("leaveCarpool", () => leaveFlow(deps(), caller(r), r.data)));

/** F26: { carpoolId, driverUid, accept } -> the consent */
export const setDriverConsent = onCall(opts, (r) => run("setDriverConsent", () => consentFlow(deps(), caller(r), r.data)));

/** { carpoolId, share } -> { shared } */
export const setPickupSharing = onCall(opts, (r) => run("setPickupSharing", () => pickupFlow(deps(), caller(r), r.data)));

/** F31: { carpoolId } -> { code, url, expiresAtMs } */
export const createCarpoolInvite = onCall(opts, (r) => run("createCarpoolInvite", () => createInvite(deps(), caller(r), r.data)));

/** F31: { code } -> { carpoolId } (verified parents only) */
export const openCarpoolInvite = onCall(opts, (r) => run("openCarpoolInvite", () => openInvite(deps(), caller(r), r.data)));

/** F32: { schoolId, areaId?, morning?, afternoon?, days, childIds } -> the post */
export const saveCarpoolWanted = onCall(opts, (r) => run("saveCarpoolWanted", () => saveWanted(deps(), caller(r), r.data)));

/** F32: {} -> { deleted } */
export const deleteCarpoolWanted = onCall(opts, (r) => run("deleteCarpoolWanted", () => deleteWanted(deps(), caller(r))));

/** F32: { schoolId, areaId? } -> { posts, suggestion } */
export const listCarpoolWanted = onCall(opts, (r) => run("listCarpoolWanted", () => listWanted(deps(), caller(r), r.data)));
