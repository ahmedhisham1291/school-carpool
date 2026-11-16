import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminAuth, adminDb } from "../admin";
import { ADMIN_SEARCH_LIMIT, ENFORCE_APP_CHECK } from "../config";
import { reportError } from "../sentry";
import { FirebaseClaimsService } from "../verification/store";
import { ipOf, requireAdminCaller } from "./access";
import { createAdmin as createAdminFlow, listAdmins as listAdminsFlow, setAdminDisabled as setAdminDisabledFlow } from "./admins";
import { ADMIN_ERROR_CODES, AdminError } from "./errors";
import type { AdminCaller } from "./guard";
import { listAuditLog as listAuditFlow, listReports as listReportsFlow } from "./lists";
import { searchSchools as searchSchoolsFlow, type SchoolSearchDeps } from "./school_search";
import { FirestoreSchoolSearchStore } from "./school_search_store";
import {
  getReport as getReportFlow,
  liftDrivingPause as liftPauseFlow,
  removeReportedMember as removeMemberFlow,
  removeReportedMessage as removeMessageFlow,
  resolveReport as resolveReportFlow,
  type ChatAdminDeps,
} from "../chat/admin";
import { chatDeps } from "../chat/callables";
import { STREAM_API_SECRET } from "../config";
import {
  approveSchool as approveSchoolFlow,
  getSchool as getSchoolFlow,
  listSchools as listSchoolsFlow,
  mergeSchool as mergeSchoolFlow,
  saveArea as saveAreaFlow,
  saveSchool as saveSchoolFlow,
  type SchoolsDeps,
} from "./schools";
import {
  listAreas as listAreasFlow,
  listDistricts as listDistrictsFlow,
  listPlaceRequests as listPlaceRequestsFlow,
  mergePlaces as mergePlacesFlow,
  moveSchoolArea as moveSchoolAreaFlow,
  resolvePlaceRequest as resolvePlaceRequestFlow,
  saveArea as savePlaceAreaFlow,
  saveDistrict as saveDistrictFlow,
  setPlaceActive as setPlaceActiveFlow,
  type PlacesAdminDeps,
} from "../places/admin";
import { FirestorePlacesAdminStore } from "../places/admin_store";
import { FirestorePlaceLocator } from "../places/store";
import {
  FirebaseAdminAccounts,
  FirestoreAdminsStore,
  FirestoreListsStore,
  FirestoreSchoolsStore,
  FirestoreUsersStore,
} from "./store";
import {
  getUserDetail as getUserFlow,
  moderateUser as moderateFlow,
  SEARCH_WINDOW_MS,
  searchUsers as searchFlow,
  type UsersDeps,
} from "./users";
import { classesMapper, runCallable } from "../common/callable";

/**
 * Admin panel functions (F14). Every one requires an admin (claim, second
 * factor, fresh session: access.ts); the admin account functions require a
 * super admin. Every change and every view of a person's data is written
 * to the audit log by the flows. Errors carry details.reason.
 *
 * Verification review reuses Prompt 3's listVerificationQueue,
 * openVerificationCase and decideVerification.
 */

const options = { enforceAppCheck: ENFORCE_APP_CHECK };

function toHttpsError(error: unknown): HttpsError {
  if (error instanceof HttpsError) return error;
  if (error instanceof AdminError) {
    const code = ADMIN_ERROR_CODES[error.reason] as FunctionsErrorCode;
    return new HttpsError(code, error.reason, { reason: error.reason, ...error.details });
  }
  return new HttpsError("internal", "Something went wrong.");
}

function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  return runCallable(name, body, { map: [classesMapper([AdminError], toHttpsError)] });
}

/** Wraps an admin-only callable. */
function adminCall<T>(
  name: string,
  body: (caller: AdminCaller, request: CallableRequest) => Promise<T>,
  access: { superAdmin?: boolean; recentSignIn?: boolean } = {},
) {
  return onCall(options, (request) =>
    run(name, async () => body(await requireAdminCaller(request, access), request)),
  );
}

function usersDeps(): UsersDeps {
  return {
    store: new FirestoreUsersStore(adminDb()),
    claims: new FirebaseClaimsService(adminAuth(), adminDb()),
    now: () => Date.now(),
    searchLimit: ADMIN_SEARCH_LIMIT.value(),
    searchWindowMs: SEARCH_WINDOW_MS,
  };
}

function schoolsDeps(): SchoolsDeps {
  return { store: new FirestoreSchoolsStore(adminDb()), now: () => Date.now(), places: new FirestorePlaceLocator(adminDb()) };
}

function schoolSearchDeps(): SchoolSearchDeps {
  return {
    store: new FirestoreSchoolSearchStore(adminDb()),
    now: () => Date.now(),
    report: async (problem) => {
      logger.error(problem);
      await reportError(new Error(problem));
    },
  };
}

function placesDeps(): PlacesAdminDeps {
  return { store: new FirestorePlacesAdminStore(adminDb()) };
}

function adminsDeps() {
  return {
    store: new FirestoreAdminsStore(adminDb()),
    accounts: new FirebaseAdminAccounts(adminAuth()),
    now: () => Date.now(),
  };
}

// Users -----------------------------------------------------------------

/** { query } -> { users: [...] } (masked phones). Rate limited per admin. */
export const adminSearchUsers = adminCall("adminSearchUsers", (caller, request) =>
  searchFlow(usersDeps(), caller, request.data, ipOf(request)),
);

/** { uid } -> user with verification and moderation history. Logged. */
export const adminGetUser = adminCall("adminGetUser", (caller, request) =>
  getUserFlow(usersDeps(), caller, request.data, ipOf(request)),
);

/** { uid, action: suspend | unsuspend | ban, reasonCode, note? } -> { status } */
export const adminModerateUser = adminCall(
  "adminModerateUser",
  (caller, request) => moderateFlow(usersDeps(), caller, request.data, ipOf(request)),
  { recentSignIn: true },
);

// Schools and areas -----------------------------------------------------

/** { status?: active | awaiting_review, governorate?, placeAreaId?, afterId? } -> { schools, nextAfterId } */
export const adminListSchools = adminCall("adminListSchools", (_caller, request) => listSchoolsFlow(schoolsDeps(), request.data));

/**
 * Every school (hidden, sample, awaiting review and merged too), searched
 * by name (Arabic and English, spelling variants, small typos) and
 * filtered by City -> Area -> District, status, visibility and source.
 * Firestore only (school_search.ts explains why). Rate limited; the first
 * page of each search is in the audit log (kinds of filters, never the text).
 * { query?, includeAll?, status?, visibility?, governorate?, placeAreaId?, placeDistrictId?, source?, sort?, afterId? }
 * -> { schools, nextAfterId, total, totalExact, degraded }
 */
export const adminSearchSchools = adminCall("adminSearchSchools", (caller, request) =>
  searchSchoolsFlow(schoolSearchDeps(), caller, request.data, ipOf(request)),
);

/** { id } -> { school, areas } */
export const adminGetSchool = adminCall("adminGetSchool", (_caller, request) => getSchoolFlow(schoolsDeps(), request.data));

/** { id?, nameAr, nameEn, governorate, city, location: { lat, lng } } -> { id } */
export const adminSaveSchool = adminCall("adminSaveSchool", (caller, request) =>
  saveSchoolFlow(schoolsDeps(), caller, request.data, ipOf(request)),
);

/** { id?, schoolId, nameAr, nameEn, center: { lat, lng } } -> { id } */
export const adminSaveArea = adminCall("adminSaveArea", (caller, request) =>
  saveAreaFlow(schoolsDeps(), caller, request.data, ipOf(request)),
);

/** "Other" queue: { id, ...school fields } -> { id } */
export const adminApproveSchool = adminCall("adminApproveSchool", (caller, request) =>
  approveSchoolFlow(schoolsDeps(), caller, request.data, ipOf(request)),
);

/** "Other" queue: { schoolId, intoId } -> { id, childrenMoved } */
export const adminMergeSchool = adminCall("adminMergeSchool", (caller, request) =>
  mergeSchoolFlow(schoolsDeps(), caller, request.data, ipOf(request)),
);

// Places: City -> Area -> District (F4 grouping, F46 addresses) -----------

/** { governorate } -> { areas: [{ id, nameAr, nameEn, schoolCount, addressCount, active, hasShape, source }] } */
export const adminListPlaceAreas = adminCall("adminListPlaceAreas", (_caller, request) => listAreasFlow(placesDeps(), request.data));

/** { areaId } -> { districts } */
export const adminListPlaceDistricts = adminCall("adminListPlaceDistricts", (_caller, request) =>
  listDistrictsFlow(placesDeps(), request.data),
);

/** { id?, governorate, nameAr, nameEn } -> { id } (add or rename an area) */
export const adminSavePlaceArea = adminCall("adminSavePlaceArea", (caller, request) =>
  savePlaceAreaFlow(placesDeps(), caller, request.data, ipOf(request)),
);

/** { id?, areaId, nameAr, nameEn } -> { id } (add or rename a district) */
export const adminSavePlaceDistrict = adminCall("adminSavePlaceDistrict", (caller, request) =>
  saveDistrictFlow(placesDeps(), caller, request.data, ipOf(request)),
);

/** { kind: area | district, id, active } -> { id, active } */
export const adminSetPlaceActive = adminCall("adminSetPlaceActive", (caller, request) =>
  setPlaceActiveFlow(placesDeps(), caller, request.data, ipOf(request)),
);

/** { kind, fromId, intoId } -> { id, schoolsMoved } (duplicates) */
export const adminMergePlaces = adminCall("adminMergePlaces", (caller, request) =>
  mergePlacesFlow(placesDeps(), caller, request.data, ipOf(request)),
);

/** { schoolId, areaId, districtId? } -> { id } */
export const adminMoveSchoolArea = adminCall("adminMoveSchoolArea", (caller, request) =>
  moveSchoolAreaFlow(placesDeps(), caller, request.data, ipOf(request)),
);

/** {} -> { requests } ("my district isn't listed", F46) */
export const adminListPlaceRequests = adminCall("adminListPlaceRequests", () => listPlaceRequestsFlow(placesDeps()));

/** { id, action: create | map | dismiss, districtId?, nameAr?, nameEn? } -> { id, districtId } */
export const adminResolvePlaceRequest = adminCall("adminResolvePlaceRequest", (caller, request) =>
  resolvePlaceRequestFlow(placesDeps(), caller, request.data, ipOf(request)),
);

// Reports and audit log -------------------------------------------------

/** { status?: open | handled } -> { reports } */
export const adminListReports = adminCall("adminListReports", (_caller, request) =>
  listReportsFlow(new FirestoreListsStore(adminDb()), request.data),
);

/** { afterId? } -> { entries, nextAfterId }. IP addresses for super admins only. */
export const adminListAuditLog = adminCall("adminListAuditLog", (caller, request) =>
  listAuditFlow(new FirestoreListsStore(adminDb()), caller, request.data, ipOf(request)),
);

// Admin accounts (super admin only) ------------------------------------

/** { email, displayName, role: admin | superAdmin } -> { uid, setupLink } (link shown once). */
export const adminCreateAdmin = adminCall(
  "adminCreateAdmin",
  (caller, request) => createAdminFlow(adminsDeps(), caller, request.data, ipOf(request)),
  { superAdmin: true, recentSignIn: true },
);

/** {} -> { admins } */
export const adminListAdmins = adminCall(
  "adminListAdmins",
  (caller, request) => listAdminsFlow(adminsDeps(), caller, ipOf(request)),
  { superAdmin: true },
);

/**
 * {} -> { ok }. The panel calls it at most every few minutes while the admin
 * is active (clicks, keys, scrolling), so reading a long case does not
 * count as idle on the server (15 minutes, admin_panel/guard.ts).
 */
export const adminPing = adminCall("adminPing", async () => ({ ok: true }));

/** { uid, disabled } -> { disabled } */
export const adminSetAdminDisabled = adminCall(
  "adminSetAdminDisabled",
  (caller, request) => setAdminDisabledFlow(adminsDeps(), caller, request.data, ipOf(request)),
  { superAdmin: true, recentSignIn: true },
);

// Chat reports (Prompt 9: F13). The reported message with a little context
// only; admins never browse a chat. Every action is in the audit log.

function chatAdminDeps(): ChatAdminDeps {
  const lists = new FirestoreListsStore(adminDb());
  return { ...chatDeps(), audit: (entry) => lists.audit(entry) };
}

/** Wraps an admin-only callable that calls Stream (needs the Stream secret). */
function chatAdminCall<T>(name: string, body: (caller: AdminCaller, request: CallableRequest) => Promise<T>) {
  return onCall({ ...options, secrets: [STREAM_API_SECRET] }, (request) =>
    run(name, async () => body(await requireAdminCaller(request), request)),
  );
}

/** { reportId } -> the report with its context. Logged. */
export const adminGetReport = chatAdminCall("adminGetReport", (caller, request) =>
  getReportFlow(chatAdminDeps(), caller, request.data, ipOf(request)),
);

/** { reportId } -> the report, closed: the reported message is deleted on Stream. */
export const adminRemoveChatMessage = chatAdminCall("adminRemoveChatMessage", (caller, request) =>
  removeMessageFlow(chatAdminDeps(), caller, request.data, ipOf(request)),
);

/** { reportId } -> the report, closed: the reported parent leaves that chat for good. */
export const adminRemoveChatMember = chatAdminCall("adminRemoveChatMember", (caller, request) =>
  removeMemberFlow(chatAdminDeps(), caller, request.data, ipOf(request)),
);

/** { reportId, outcome } -> the report, closed. */
export const adminResolveReport = chatAdminCall("adminResolveReport", (caller, request) =>
  resolveReportFlow(chatAdminDeps(), caller, request.data, ipOf(request)),
);

/** { reportId } -> the report: the reported driver's driving pause is lifted. */
export const adminLiftDrivingPause = chatAdminCall("adminLiftDrivingPause", (caller, request) =>
  liftPauseFlow(chatAdminDeps(), caller, request.data, ipOf(request)),
);
