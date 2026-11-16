import { randomBytes } from "node:crypto";
import { type CallableRequest } from "firebase-functions/v2/https";
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
import { featureOffError, featureOn } from "../features/gate";
import { FeatureOffError } from "../features/model";
import { FirestoreCarpoolStore } from "./store";
import { noteAbuse } from "../privacy/abuse_hook";
import { gatedCall, isReviewDemoCaller, demoAccountError, realParentCall } from "../privacy/device_gate";
import { callerOf, reasonErrorMapper, runCallable } from "../common/callable";

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
    contributionsOn: () => featureOn("contributions"),
  };
}

export function caller(request: CallableRequest): Caller {
  return callerOf(request);
}

export function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  return runCallable(name, body, {
    map: [
      // F25 "contributions" switch off (no money in the app, 16 Nov 2026).
      (error) => (error instanceof FeatureOffError ? featureOffError(error.feature) : undefined),
      reasonErrorMapper(CarpoolError, CARPOOL_ERROR_CODES, "retryAfter"),
    ],
  });
}

export const opts = { enforceAppCheck: ENFORCE_APP_CHECK };

/**
 * App Review demo parents (privacy/device_gate.ts) stay inside the demo
 * school: a school carpool is tied by the flows to the caller's own
 * approved children's school (the hidden demo school), while an activity
 * carpool is found by distance by any parent nearby. So for them only
 * kind "school" is allowed here, and joining another carpool, opening an
 * invite and posting "looking for a carpool" are refused (realParentCall).
 */
function schoolKindOnlyForReviewDemo(r: CallableRequest): void {
  if (!isReviewDemoCaller(r)) return;
  const kind = typeof r.data === "object" && r.data !== null ? (r.data as { kind?: unknown }).kind : undefined;
  // The search reads a missing kind as "school"; the create flow refuses it.
  if (kind !== "school" && kind !== undefined) throw demoAccountError();
}

/** F5, F25, F36, F39: { kind, schoolId|activity, areaId?, morning?, afternoon?, days, driveDays, seats, childIds, rules, contribution? } -> { carpoolId } */
export const createCarpool = gatedCall(opts, (r) =>
  run("createCarpool", () => {
    schoolKindOnlyForReviewDemo(r);
    return createFlow(deps(), caller(r), r.data);
  }),
);

/** F5, F6: { kind, schoolId?, areaId?, morning?, afternoon?, radiusKm?, parentUid? } -> { carpools } */
export const searchCarpools = gatedCall(opts, (r) =>
  run("searchCarpools", async () => {
    // Prompt 12: searching many schools and areas in an hour alerts the admins.
    schoolKindOnlyForReviewDemo(r);
    const q = typeof r.data === "object" && r.data !== null ? (r.data as { schoolId?: unknown; areaId?: unknown }) : {};
    await noteAbuse(caller(r).uid, "areaSearches", `${String(q.schoolId ?? "")}|${String(q.areaId ?? "")}`.slice(0, 64));
    return searchFlow(deps(), caller(r), r.data);
  }),
);

/** F6: { carpoolId, childIds, acceptRules, acceptContribution } -> { status } */
export const requestToJoinCarpool = realParentCall(opts, (r) => run("requestToJoinCarpool", () => requestToJoin(deps(), caller(r), r.data)));

/** F6: { carpoolId } -> { status } */
export const cancelJoinRequest = gatedCall(opts, (r) => run("cancelJoinRequest", () => cancelFlow(deps(), caller(r), r.data)));

/** F6: { carpoolId, uid, approve } -> { status } (carpool admin only) */
export const decideJoinRequest = gatedCall(opts, (r) => run("decideJoinRequest", () => decideFlow(deps(), caller(r), r.data)));

/** { carpoolId } -> { status } */
export const leaveCarpool = gatedCall(opts, (r) => run("leaveCarpool", () => leaveFlow(deps(), caller(r), r.data)));

/** F26: { carpoolId, driverUid, accept } -> the consent */
export const setDriverConsent = gatedCall(opts, (r) => run("setDriverConsent", () => consentFlow(deps(), caller(r), r.data)));

/** { carpoolId, share } -> { shared } */
export const setPickupSharing = gatedCall(opts, (r) => run("setPickupSharing", () => pickupFlow(deps(), caller(r), r.data)));

/** F31: { carpoolId } -> { code, url, expiresAtMs } */
export const createCarpoolInvite = gatedCall(opts, (r) => run("createCarpoolInvite", () => createInvite(deps(), caller(r), r.data)));

/** F31: { code } -> { carpoolId } (verified parents only) */
export const openCarpoolInvite = realParentCall(opts, (r) => run("openCarpoolInvite", () => openInvite(deps(), caller(r), r.data)));

/** F32: { schoolId, areaId?, morning?, afternoon?, days, childIds } -> the post */
export const saveCarpoolWanted = realParentCall(opts, (r) => run("saveCarpoolWanted", () => saveWanted(deps(), caller(r), r.data)));

/** F32: {} -> { deleted } */
export const deleteCarpoolWanted = gatedCall(opts, (r) => run("deleteCarpoolWanted", () => deleteWanted(deps(), caller(r))));

/** F32: { schoolId, areaId? } -> { posts, suggestion } */
export const listCarpoolWanted = gatedCall(opts, (r) => run("listCarpoolWanted", () => listWanted(deps(), caller(r), r.data)));
