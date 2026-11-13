import { maskPhone, toEgyptE164 } from "../auth/phone";
import { normalizeText } from "../text/normalize";
import { AdminError, docId, optionalText, record } from "./errors";
import type { AdminCaller } from "./guard";
import type {
  AccountStatus,
  ActionHistoryItem,
  CaseHistoryItem,
  ModerationWrite,
  StoredUser,
  UserClaims,
  UsersStore,
} from "./types";

/**
 * Users in the admin panel (F14): server-side search by name, phone or
 * parent ID (rate limited per admin), a detail view with verification and
 * moderation history, and suspend / unsuspend / ban.
 *
 * PRIVACY: phone numbers leave the server masked (+20********01); emails
 * masked too. The search text is never logged (it may be a phone number):
 * the audit entry keeps only the kind of search and the result count.
 */

export interface UsersDeps {
  store: UsersStore;
  claims: UserClaims;
  now: () => number;
  searchLimit: number;
  searchWindowMs: number;
}

/** Defaults: 30 searches per 10 minutes per admin (params in config.ts). */
export const SEARCH_LIMIT = 30;
export const SEARCH_WINDOW_MS = 10 * 60 * 1000;
const MAX_RESULTS = 20;

/** Parent ID alphabet: no 0, O, 1 or I (CLAUDE.md, PARENT ID). */
const PARENT_ID = /^[2-9A-HJ-NP-Z]{8}$/;

export type SearchKind = "parentId" | "phone" | "name";

export interface SearchPlan {
  parentId: string | null;
  phone: string | null;
  name: string | null;
}

/** Works out what the admin typed. A text can be both a parent ID and a name. */
export function planSearch(raw: unknown): SearchPlan {
  if (typeof raw !== "string") throw new AdminError("invalid-request");
  const input = raw.trim();
  if (input.length < 2 || input.length > 60) throw new AdminError("invalid-request");
  const compact = input.replace(/[\s-]/g, "").toUpperCase();
  const parentId = PARENT_ID.test(compact) ? compact : null;
  const phone = toEgyptE164(input);
  const normalized = normalizeText(input);
  // Names have no digits, so "ABCD2345" is not also searched as a name.
  const name = !phone && /\p{L}/u.test(normalized) && !/\d/.test(normalized) && normalized.length >= 2 ? normalized : null;
  if (!parentId && !phone && !name) throw new AdminError("invalid-request");
  return { parentId, phone, name };
}

export function maskEmail(email: string | null): string | null {
  if (!email) return null;
  const at = email.indexOf("@");
  if (at < 1) return "***";
  return `${email[0]}***${email.slice(at)}`;
}

export interface UserSummary {
  uid: string;
  parentId: string;
  firstName: string | null;
  lastName: string | null;
  status: AccountStatus;
  banned: boolean;
  phone: string | null;
  createdAtMs: number;
}

export function present(user: StoredUser): UserSummary {
  return {
    uid: user.uid,
    parentId: user.parentId,
    firstName: user.firstName,
    lastName: user.lastName,
    status: user.status,
    banned: user.banned,
    phone: user.phone ? maskPhone(user.phone) : null,
    createdAtMs: user.createdAtMs,
  };
}

export async function searchUsers(
  deps: UsersDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ users: UserSummary[] }> {
  const plan = planSearch(record(data)?.query);
  const allowed = await deps.store.consumeSearchQuota(caller.uid, deps.now(), deps.searchLimit, deps.searchWindowMs);
  if (!allowed) throw new AdminError("rate-limited");

  const found = new Map<string, StoredUser>();
  if (plan.parentId) {
    const user = await deps.store.findByParentId(plan.parentId);
    if (user) found.set(user.uid, user);
  }
  if (plan.phone) for (const user of await deps.store.findByPhone(plan.phone)) found.set(user.uid, user);
  if (plan.name) for (const user of await deps.store.findByName(plan.name, MAX_RESULTS)) found.set(user.uid, user);

  const users = [...found.values()].slice(0, MAX_RESULTS).map(present);
  const kinds = (["parentId", "phone", "name"] as const).filter((kind) => plan[kind] !== null).join(",");
  await deps.store.audit({
    actorUid: caller.uid,
    action: "user.search",
    target: "users",
    details: { by: kinds, results: users.length },
    ip,
  });
  return { users };
}

export interface UserDetail extends UserSummary {
  email: string | null;
  cases: CaseHistoryItem[];
  actions: ActionHistoryItem[];
}

export async function getUserDetail(
  deps: UsersDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<UserDetail> {
  const uid = docId(record(data)?.uid);
  const user = await deps.store.getUser(uid);
  if (!user) throw new AdminError("not-found");
  const [cases, actions] = await Promise.all([deps.store.caseHistory(uid, 20), deps.store.actionHistory(uid, 20)]);
  await deps.store.audit({ actorUid: caller.uid, action: "user.view", target: `users/${uid}`, ip });
  return { ...present(user), email: maskEmail(user.email), cases, actions };
}

export const MODERATION_REASONS = [
  "reports",
  "fake_documents",
  "unsafe_driving",
  "harassment",
  "duplicate_account",
  "other",
] as const;
export type ModerationReason = (typeof MODERATION_REASONS)[number];

export interface ModerationRequest {
  uid: string;
  action: "suspend" | "unsuspend" | "ban";
  reasonCode: ModerationReason;
  note: string | null;
}

export function parseModeration(data: unknown): ModerationRequest {
  const raw = record(data);
  if (!raw) throw new AdminError("invalid-request");
  const uid = docId(raw.uid);
  const action = raw.action;
  if (action !== "suspend" && action !== "unsuspend" && action !== "ban") throw new AdminError("invalid-request");
  const reasonCode = raw.reasonCode as ModerationReason;
  if (!MODERATION_REASONS.includes(reasonCode)) throw new AdminError("invalid-request");
  const note = optionalText(raw.note, 500);
  if (reasonCode === "other" && note === null) throw new AdminError("invalid-request");
  return { uid, action, reasonCode, note };
}

/**
 * Suspend: no access (spec section 3), signed out everywhere, the
 * "verified" claim removed; the earlier status is kept for unsuspend.
 * Ban: a suspension that also puts the national ID hash on the ban list,
 * so the same ID cannot register again. A ban is not lifted here.
 * Admin accounts and the caller's own account are refused.
 */
export async function moderateUser(
  deps: UsersDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ status: AccountStatus }> {
  const request = parseModeration(data);
  if (request.uid === caller.uid) throw new AdminError("own-account");
  if (await deps.store.isAdmin(request.uid)) throw new AdminError("target-is-admin");
  const user = await deps.store.getUser(request.uid);
  if (!user) throw new AdminError("not-found");

  let write: Omit<ModerationWrite, "audit">;
  if (request.action === "unsuspend") {
    if (user.status !== "suspended" || user.banned) throw new AdminError("invalid-state");
    write = {
      uid: user.uid,
      action: "unsuspend",
      status: user.statusBeforeSuspension ?? "unverified",
      statusBeforeSuspension: null,
      banned: false,
      banNationalIdHash: null,
      reasonCode: request.reasonCode,
      note: request.note,
    };
  } else {
    if (user.banned) throw new AdminError("invalid-state");
    if (request.action === "suspend" && user.status === "suspended") throw new AdminError("invalid-state");
    const ban = request.action === "ban";
    write = {
      uid: user.uid,
      action: request.action,
      status: "suspended",
      statusBeforeSuspension: user.status === "suspended" ? user.statusBeforeSuspension : user.status,
      banned: ban,
      banNationalIdHash: ban ? await deps.store.nationalIdHashOf(user.uid) : null,
      reasonCode: request.reasonCode,
      note: request.note,
    };
  }

  await deps.store.applyModeration(
    {
      ...write,
      audit: {
        actorUid: caller.uid,
        action: `user.${request.action}`,
        target: `users/${user.uid}`,
        reasonCode: request.reasonCode,
        details: request.action === "ban" ? { idBanned: write.banNationalIdHash !== null } : undefined,
        ip,
      },
    },
    user.status,
  );

  if (write.status === "suspended") {
    await deps.claims.setVerified(user.uid, false);
    await deps.claims.revokeSessions(user.uid);
  } else if (write.status === "verified") {
    await deps.claims.setVerified(user.uid, true);
  }
  return { status: write.status };
}
